# Cert.Run: one scenario run, from snapshot to revert.
#
#   Prepared -> Snapshotted -> Broken -> InProgress -> (Repaired) -> Reverted
#
# A run's record lives in runs_path/<run id>/run.json; the run id is the
# snapshot set's name (CERT-<YYMMDD>-<HHMM>-<NN>). While a run is open, the lock
# file (lock_path) names it: one run at a time, and the lab pipeline should
# leave the lab alone (midcoast-labs#23).
#
# Everything a run changes in the lab happens after the snapshot, so a revert
# undoes all of it: the break, the assessor's extra access, the engagement account.
# MGMT is the exception: it's never in the snapshot. When the fixer works on
# MGMT (the default assessor), CERT changes nothing there but the engagement
# account's sign-in, and the revert removes that itself.

# ── Records ───────────────────────────────────────────────────────────────

function Get-CertRunsPath {
    param([Parameter(Mandatory)] $Config)
    $p = [string] $Config.runs_path
    if (-not [IO.Path]::IsPathRooted($p)) { $p = Join-Path $script:CertRoot $p }
    New-Item -ItemType Directory -Path $p -Force | Out-Null
    $p
}

function Get-CertLockPath {
    param([Parameter(Mandatory)] $Config)
    $p = [string] $Config.lock_path
    if (-not [IO.Path]::IsPathRooted($p)) { $p = Join-Path $script:CertRoot $p }
    $p
}

function Save-CertRun {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Config, [Parameter(Mandatory)] $Run)
    $dir = Join-Path (Get-CertRunsPath -Config $Config) $Run.id
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null; Protect-CertRunFolder -Path $dir }
    $Run.updated_utc = (Get-Date).ToUniversalTime().ToString('o')
    $Run | ConvertTo-Json -Depth 20 | Set-Content -Path (Join-Path $dir 'run.json') -Encoding utf8NoBOM
}

function Protect-CertRunFolder {
    # A run folder holds the engagement password and, for a blind run, which
    # scenario it is. When the fixer works on MGMT, keep it to the account
    # running CERT and SYSTEM. (An administrator can still take it over, but
    # not by browsing.)
    param([Parameter(Mandatory)] [string] $Path)
    if (-not $IsWindows) { return }
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    & icacls.exe $Path /inheritance:r /grant:r "${me}:(OI)(CI)F" '*S-1-5-18:(OI)(CI)F' 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Warning "Couldn't restrict $Path to $me; anyone with access to the runs folder can read it." }
}

function Write-CertLock {
    # The lock file the lab's pipeline checks (lab.yaml handover.cert_lock_path,
    # lab 1.6+). JSON; a blind run doesn't name its scenario.
    param([Parameter(Mandatory)] $Config, [Parameter(Mandatory)] $Run)
    [pscustomobject]@{
        scenario = if ($Run.blind) { '(blind run)' } else { $Run.module.id }
        started  = $Run.created_utc
        snapshot = $Run.snapshot.name
        run      = $Run.id
        by       = $Run.owner
    } | ConvertTo-Json | Set-Content -Path (Get-CertLockPath -Config $Config) -Encoding utf8NoBOM
}

function Get-CertRun {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Config, [Parameter(Mandatory)] [string] $Id)
    $p = Join-Path (Get-CertRunsPath -Config $Config) "$Id/run.json"
    if (-not (Test-Path $p)) { throw "No run record $Id ($p)." }
    Get-Content -Path $p -Raw | ConvertFrom-Json
}

function Get-CertRuns {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Config)
    Get-ChildItem -Path (Get-CertRunsPath -Config $Config) -Directory | Sort-Object Name | ForEach-Object {
        $p = Join-Path $_.FullName 'run.json'
        if (Test-Path $p) { Get-Content -Path $p -Raw | ConvertFrom-Json }
    }
}

function Get-CertActiveRun {
    # The run named in the lock file, or $null.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Config)
    $lock = Get-CertLockPath -Config $Config
    if (-not (Test-Path $lock)) { return $null }
    $raw = (Get-Content -Path $lock -Raw).Trim()
    # JSON since 0.2 (the lab reads it too); a bare run id before.
    $id = try { ($raw | ConvertFrom-Json -ErrorAction Stop).run } catch { $raw }
    if (-not $id) { $id = $raw }
    try { Get-CertRun -Config $Config -Id $id } catch { Write-Warning "Lock file $lock names run '$id', which has no record. Remove the lock file once you're sure no run is open."; $null }
}

function Add-CertRunEvent {
    # Appends to the run's timeline (and echoes it).
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Config, [Parameter(Mandatory)] $Run, [Parameter(Mandatory)] [string] $Event, [string] $Detail)
    $e = [pscustomobject]@{ at = (Get-Date).ToUniversalTime().ToString('o'); event = $Event; detail = $Detail }
    $Run.timeline = @($Run.timeline) + $e
    Save-CertRun -Config $Config -Run $Run
    Write-Host ("  [{0:HH:mm:ss}] {1}{2}" -f (Get-Date), $Event, $(if ($Detail) { ": $Detail" } else { '' }))
}

function Get-CertRunEventTime {
    param($Run, [string] $Event, [switch] $Last)
    $all = @($Run.timeline | Where-Object event -eq $Event)
    $e = if ($Last) { $all[-1] } else { $all[0] }
    if ($e) { [datetime]::Parse($e.at).ToUniversalTime() } else { $null }
}

# ── Pre-flight ────────────────────────────────────────────────────────────

function Get-CertSnapshotSetMembers {
    # Every active lab instance except the excluded roles (MGMT by default).
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Config, [Parameter(Mandatory)] $Lab)
    $exclude = @($Config.snapshot.exclude_roles | Where-Object { $_ })
    if ($exclude -notcontains 'MGMT') { $exclude += 'MGMT' }   # never MGMT: it holds the run, the vault and the ledger
    @(Get-CertActiveInstances -Lab $Lab | Where-Object { $exclude -notcontains $_.role })
}

function Test-CertPreflight {
    # Everything that must be true before a run starts. Returns
    # @{ Ok; Errors; Warnings; Members; Vms; Baseline }. -SkipBaseline skips the
    # lab validation (only for a snapshot test).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Config, [Parameter(Mandatory)] $Lab, $Module,
        [switch] $SkipBaseline
    )
    $err = [Collections.Generic.List[string]]::new()
    $warn = [Collections.Generic.List[string]]::new()

    $active = Get-CertActiveRun -Config $Config
    if ($active) { $err.Add("Run $($active.id) is still open ($($active.state)). Revert it first.") }

    $c = Test-CertLabCompatibility -Lab $Lab
    if (-not $c.Ok) { $err.Add($c.Message) } elseif ($c.Message -match 'Expected to work') { $warn.Add($c.Message) }

    $mgmt = Get-LabRoleDefinition -Inventory $Lab.Inventory -Role 'MGMT'
    if ($mgmt.handover.lock_path -and (Test-Path $mgmt.handover.lock_path)) { $err.Add("This MGMT has handed over ($($mgmt.handover.lock_path)); run CERT on the active MGMT.") }
    if ($mgmt.handover.cert_lock_path -and $mgmt.handover.cert_lock_path -ne (Get-CertLockPath -Config $Config)) {
        $warn.Add("The lab expects CERT's lock at $($mgmt.handover.cert_lock_path), but cert.config.yaml says $(Get-CertLockPath -Config $Config): the pipeline won't see an open run. Make them the same.")
    }
    $a = Get-CertAssessor -Config $Config -Lab $Lab
    if ($a -and $a.Fallback) { $warn.Add("No active $($Config.assessor.role); the fixer works on MGMT ($($a.Name)) instead.") }

    $busy = @($Lab.Instances | Where-Object { $_.state -ne 'active' })
    if ($busy) { $err.Add("The lab is mid-change: $(($busy | ForEach-Object { "$($_.name) is $($_.state)" }) -join '; '). Finish or abort the rotation first.") }

    if ($Module) {
        if (-not $Module.Valid) { $err.Add("Module $($Module.Key) isn't valid: $($Module.Problems -join '; ')") }
        else {
            $m = $Module.Manifest
            if (-not (Test-CertRequirement $m.requires.cert $script:CertVersion)) { $err.Add("$($m.id) needs CERT $($m.requires.cert); this is $script:CertVersion.") }
            if (-not (Test-CertRequirement $m.requires.lab $Lab.Version)) { $err.Add("$($m.id) needs lab $($m.requires.lab); this lab is $($Lab.Version).") }
            if ($m.requires.roles) {
                foreach ($p in $m.requires.roles.PSObject.Properties) {
                    $n = @(Get-CertActiveInstances -Lab $Lab -Role $p.Name).Count
                    if ($n -lt [int] $p.Value) { $err.Add("$($m.id) needs $($p.Value) active $($p.Name); the lab has $n.") }
                }
            }
            if ($m.requires.assessor -and -not (Get-CertAssessor -Config $Config -Lab $Lab)) {
                $err.Add("$($m.id) needs somewhere for the fixer to work, and there's none: no active MGMT in the ledger, and no assessor.address in cert.config.yaml.")
            }
        }
    }

    $members = @(Get-CertSnapshotSetMembers -Config $Config -Lab $Lab)
    if ($members.Count -eq 0) { $err.Add('No lab VMs to snapshot (no active instances besides MGMT).') }
    $vms = @()
    foreach ($i in $members) {
        try {
            $vm = Assert-CertLabVm -Lab $Lab -Instance $i
            if ($vm.Status -ne 'running') { $err.Add("$($i.name) is $($vm.Status); every VM in the set must be running.") }
            $vms += [pscustomobject]@{ Instance = $i; Vm = $vm }
        } catch { $err.Add($_.Exception.Message) }
    }
    if ($vms) {
        foreach ($s in Get-CertStorageUse -Lab $Lab -Nodes @($vms.Vm.Node)) {
            if ($null -eq $s.UsedPercent) { $warn.Add("Couldn't read the use of $($s.Storage) on $($s.Node)$(if ($s.Error) { ": $($s.Error)" }).") }
            elseif ($s.UsedPercent -ge [double] $Config.snapshot.storage_warn_percent) {
                $warn.Add("$($s.Storage) on $($s.Node) is $($s.UsedPercent)% used ($($s.FreeGB) GB free). Snapshots, and RAM snapshots most of all, need room; thin storage that fills up stops every VM on it.")
            }
        }
        $ramGb = [math]::Round((($vms.Vm | Measure-Object MaxMem -Sum).Sum) / 1GB, 1)
        if ($Config.snapshot.include_ram) { $warn.Add("RAM is included: about $ramGb GB of extra space on top of the disk changes.") }
    }
    $existing = @(Get-CertSnapshotSets -Lab $Lab -Members $members)
    if ($existing.Count -ge [int] $Config.snapshot.max_sets) {
        $err.Add("$($existing.Count) CERT snapshot sets already exist (max_sets $($Config.snapshot.max_sets)). Remove some first (menu: Snapshots).")
    }

    $baseline = @()
    if (-not $SkipBaseline -and $err.Count -eq 0) {
        foreach ($v in $vms) {
            if (-not (Test-CertGuestReachable -Lab $Lab -Instance $v.Instance)) { $err.Add("Can't reach $($v.Instance.name) over WinRM/HTTPS."); continue }
            $rep = Invoke-CertLabValidation -Lab $Lab -Instance $v.Instance
            if (-not $rep) { $baseline += [pscustomobject]@{ name = $v.Instance.name; status = 'no lab validation'; failed = @() }; continue }
            $failed = @($rep.results | Where-Object { -not $_.passed })
            $baseline += [pscustomobject]@{ name = $v.Instance.name; status = $rep.status; failed = @($failed | ForEach-Object { "$($_.id) ($($_.severity))" }) }
            if ($rep.status -eq 'Failed') { $err.Add("$($v.Instance.name) fails lab validation before anything is broken: $(@($failed | Where-Object severity -eq 'Critical' | ForEach-Object id) -join ', '). A scenario has to start from a working lab.") }
            elseif ($failed) { $warn.Add("$($v.Instance.name) starts with warnings: $(@($failed | ForEach-Object id) -join ', ').") }
        }
    }
    @{ Ok = ($err.Count -eq 0); Errors = $err.ToArray(); Warnings = $warn.ToArray(); Members = $members; Vms = $vms; Baseline = $baseline }
}

# ── Targets ───────────────────────────────────────────────────────────────

function Get-CertPdcInstance {
    # The DC holding the PDC emulator, asked of any reachable active DC.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Lab)
    foreach ($dc in Get-CertActiveInstances -Lab $Lab -Role 'DC') {
        try {
            $pdc = Invoke-CertGuest -Lab $Lab -Instance $dc -ScriptBlock { (Get-ADDomain).PDCEmulator }
            $short = ([string] $pdc).Split('.')[0]
            $inst = @(Get-CertActiveInstances -Lab $Lab -Role 'DC' | Where-Object { $_.name -eq $short })[0]
            if ($inst) { return $inst }
            throw "The PDC emulator is $pdc, which isn't an active DC in the ledger."
        } catch { $last = $_.Exception.Message }
    }
    throw "Couldn't find the PDC emulator: $last"
}

function Resolve-CertTargets {
    # Module targets -> ledger instances (all-dcs -> an array).
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Config, [Parameter(Mandatory)] $Lab, [Parameter(Mandatory)] $Manifest)
    $t = [ordered]@{}
    $dcs = @(Get-CertActiveInstances -Lab $Lab -Role 'DC')
    foreach ($x in @($Manifest.targets | Where-Object { $_ })) {
        $t[$x.name] = switch -Regex ($x.select) {
            '^pdc$'        { Get-CertPdcInstance -Lab $Lab }
            '^non-pdc-dc$' { $pdc = Get-CertPdcInstance -Lab $Lab; $o = @($dcs | Where-Object name -ne $pdc.name); if (-not $o) { throw 'No DC other than the PDC emulator.' }; $o[0] }
            '^any-dc$'     { if (-not $dcs) { throw 'No active DC.' }; $dcs | Get-Random }
            '^all-dcs$'    { , $dcs }
            '^assessor$'   { $a = Get-CertAssessor -Config $Config -Lab $Lab; if (-not $a.Instance) { throw 'The assessor isn''t a lab instance, so it can''t be a target.' }; $a.Instance }
            '^role:(.+)$'  { $r = @(Get-CertActiveInstances -Lab $Lab -Role $Matches[1])[0]; if (-not $r) { throw "No active $($Matches[1])." }; $r }
        }
    }
    # A module may only break what the revert restores: never MGMT, never
    # anything outside the snapshot set.
    $set = @((Get-CertSnapshotSetMembers -Config $Config -Lab $Lab).name)
    foreach ($k in @($t.Keys)) {
        foreach ($i in @($t[$k])) {
            if ($set -notcontains $i.name) { throw "Target '$k' is $($i.name), which isn't in the snapshot set (MGMT never is), so a revert couldn't undo the break." }
        }
    }
    $t
}

# ── Snapshot sets ─────────────────────────────────────────────────────────

function Get-CertSnapshotSets {
    # CERT snapshots on the lab's VMs, grouped by name: which VMs have each.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Lab, [object[]] $Members)
    if (-not $Members) { $Members = @(Get-CertActiveInstances -Lab $Lab | Where-Object role -ne 'MGMT') }
    $rows = foreach ($i in $Members) {
        $vm = Get-CertPveVm -Lab $Lab -VmId ([int] $i.vmid)
        if (-not $vm) { continue }
        foreach ($s in Get-CertPveSnapshots -Lab $Lab -Vm $vm | Where-Object { $_.name -like "$script:SnapshotPrefix-*" }) {
            [pscustomobject]@{ Name = $s.name; Instance = $i.name; VmId = $vm.VmId; Ram = [bool] $s.vmstate; Time = if ($s.snaptime) { [DateTimeOffset]::FromUnixTimeSeconds([long] $s.snaptime).UtcDateTime } else { $null }; Description = [string] $s.description }
        }
    }
    $rows | Group-Object Name | Sort-Object Name | ForEach-Object {
        $first = $_.Group[0]
        $ledger = if ($first.Description -match 'ledger=([0-9a-f]{12})') { $Matches[1] } else { $null }
        [pscustomobject]@{ Name = $_.Name; Vms = @($_.Group); Count = $_.Count; Time = $first.Time; Ram = $first.Ram; LedgerHash = $ledger; Description = $first.Description }
    }
}

function New-CertSnapshotSet {
    # Unplugs every VM in the set from the network, snapshots each with RAM
    # while it runs, then plugs them all back in. Unplugged, no DC can
    # replicate a change another DC's snapshot missed, so the set is one
    # consistent moment of the lab even though the snapshots are taken one
    # after another. (Pausing the VMs instead doesn't work with RAM: QEMU
    # can't continue a VM whose RAM was saved while it was paused.)
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Config, [Parameter(Mandatory)] $Lab,
        [Parameter(Mandatory)] [object[]] $Vms, [Parameter(Mandatory)] [string] $Name, [string] $Purpose
    )
    $ram  = [bool] $Config.snapshot.include_ram
    $desc = "CERT snapshot set $Name. $Purpose site=$($Lab.Site) release=$($Lab.Release) ledger=$($Lab.LedgerHash.Substring(0, 12)) vms=$(@($Vms.Instance.name) -join ',') by=$env:USERNAME"
    $unplugged = @()
    try {
        foreach ($v in $Vms) { Set-CertPveVmLink -Lab $Lab -Vm $v.Vm -Up $false; $unplugged += $v }
        foreach ($v in $Vms) {
            Write-Host "    snapshot $($v.Instance.name) ($($v.Vm.VmId))$(if ($ram) { ' with RAM' })"
            New-CertPveSnapshot -Lab $Lab -Vm $v.Vm -Name $Name -Description $desc -IncludeRam $ram
        }
    } catch {
        # A partial set is no use: remove what was made.
        $failure = $_
        foreach ($v in $Vms) { try { if (Get-CertPveSnapshots -Lab $Lab -Vm $v.Vm | Where-Object name -eq $Name) { Remove-CertPveSnapshot -Lab $Lab -Vm $v.Vm -Name $Name } } catch { Write-Warning "Couldn't remove partial snapshot $Name from $($v.Instance.name): $($_.Exception.Message)" } }
        throw $failure
    } finally {
        foreach ($v in $unplugged) {
            try { Set-CertPveVmLink -Lab $Lab -Vm $v.Vm -Up $true }
            catch { Write-Warning "Couldn't plug $($v.Instance.name) back in: $($_.Exception.Message). On Proxmox, remove link_down=1 from its network device (Hardware > Network Device > Disconnect)." }
        }
    }
}

function Restore-CertSnapshotSet {
    # Stops every VM in the set, then rolls each back. All stopped first, so a
    # rolled-back DC can't replicate from one still holding the broken state.
    # The snapshots were taken unplugged, so the VMs come back unplugged; once
    # all are back, they're plugged in together. RAM snapshots come back
    # running; disk-only ones are started.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Lab, [Parameter(Mandatory)] [object[]] $Vms, [Parameter(Mandatory)] [string] $Name)
    foreach ($v in $Vms) {
        if (-not (Get-CertPveSnapshots -Lab $Lab -Vm $v.Vm | Where-Object name -eq $Name)) { throw "$($v.Instance.name) has no snapshot $Name; nothing was changed." }
    }
    foreach ($v in $Vms) {
        $st = Get-CertPveVmStatus -Lab $Lab -Vm $v.Vm
        if ($st.Status -ne 'stopped') { Write-Host "    stop $($v.Instance.name)"; Invoke-CertPveVmAction -Lab $Lab -Vm $v.Vm -Action stop }
    }
    foreach ($v in $Vms) { Write-Host "    roll back $($v.Instance.name)"; Restore-CertPveSnapshot -Lab $Lab -Vm $v.Vm -Name $Name }
    foreach ($v in $Vms) {
        $st = Get-CertPveVmStatus -Lab $Lab -Vm $v.Vm
        if ($st.Status -eq 'stopped') { Invoke-CertPveVmAction -Lab $Lab -Vm $v.Vm -Action start }
        elseif ($st.Qmp -ne 'running') { Invoke-CertPveVmAction -Lab $Lab -Vm $v.Vm -Action resume }
    }
    foreach ($v in $Vms) { Write-Host "    plug in $($v.Instance.name)"; Set-CertPveVmLink -Lab $Lab -Vm $v.Vm -Up $true }
}

function Repair-CertSysvol {
    # An authoritative SYSVOL sync from the PDC emulator, after a revert.
    #
    # Why: rolling a DC back to a snapshot gives it a new VM-Generation ID.
    # Windows takes that as "this DC was restored": AD protects itself (new
    # invocation ID), and DFS Replication starts a non-authoritative initial
    # sync of SYSVOL, waiting for a partner to copy from. When every DC was
    # rolled back, every DC waits for another: SYSVOL stays in state 2 (event
    # 4614) for good. The way out is Microsoft's authoritative SYSVOL restore
    # (KB 2218556): the PDC emulator's copy is declared the master, the others
    # copy from it. After a CERT revert all copies are the same snapshot, so
    # nothing is lost.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Lab, [int] $TimeoutSeconds = 900)
    $dcs = @(Get-CertActiveInstances -Lab $Lab -Role 'DC')
    if (-not $dcs) { return 'no DCs' }
    $auth = Get-CertPdcInstance -Lab $Lab
    $others = @($dcs | Where-Object name -ne $auth.name)

    $state = {
        $rf = Get-CimInstance -Namespace root\microsoftdfs -ClassName DfsrReplicatedFolderInfo -Filter "ReplicatedFolderName='SYSVOL Share'" -ErrorAction SilentlyContinue
        if ($rf) { [int] $rf.State } else { -1 }
    }
    # Already healthy everywhere: nothing to do.
    $states = @{}
    foreach ($d in $dcs) { $states[$d.name] = Invoke-CertGuest -Lab $Lab -Instance $d -ScriptBlock $state -TimeoutSeconds 300 }
    if (@($states.Values | Where-Object { $_ -ne 4 }).Count -eq 0) { return 'SYSVOL already normal on every DC' }
    Write-Host "    SYSVOL states: $(($states.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', '); authoritative sync from $($auth.name)"

    # Sets a DC's SYSVOL subscription in AD, on the authoritative DC.
    $setSub = {
        param($Computer, $Enabled, $Authoritative)
        Import-Module ActiveDirectory
        $dn = "CN=SYSVOL Subscription,CN=Domain System Volume,CN=DFSR-LocalSettings,$((Get-ADComputer $Computer -Server localhost).DistinguishedName)"
        $r = @{ 'msDFSR-Enabled' = [bool] $Enabled }
        if ($Authoritative) { $r['msDFSR-Options'] = 1 }
        Set-ADObject -Identity $dn -Replace $r -Server localhost
    }
    $sync = { & repadmin.exe /syncall /AdeP 2>&1 | Out-Null }
    $wait = {
        param($Want, $Seconds)
        $deadline = (Get-Date).AddSeconds($Seconds)
        do {
            & dfsrdiag.exe pollad 2>&1 | Out-Null
            Start-Sleep -Seconds 15
            $rf = Get-CimInstance -Namespace root\microsoftdfs -ClassName DfsrReplicatedFolderInfo -Filter "ReplicatedFolderName='SYSVOL Share'" -ErrorAction SilentlyContinue
            $s = if ($rf) { [int] $rf.State } else { -1 }
        } while ($s -ne $Want -and (Get-Date) -lt $deadline)
        $s
    }

    # 1. Stop DFS Replication everywhere; mark the PDC authoritative and
    #    every subscription disabled; replicate that to all DCs.
    foreach ($d in $dcs) { Invoke-CertGuest -Lab $Lab -Instance $d -ScriptBlock { Stop-Service DFSR -Force } | Out-Null }
    Invoke-CertGuest -Lab $Lab -Instance $auth -ScriptBlock $setSub -ArgumentList $auth.name, $false, $true | Out-Null
    foreach ($d in $others) { Invoke-CertGuest -Lab $Lab -Instance $auth -ScriptBlock $setSub -ArgumentList $d.name, $false, $false | Out-Null }
    Invoke-CertGuest -Lab $Lab -Instance $auth -ScriptBlock $sync | Out-Null

    # 2. The PDC first: start, enable, wait for Normal (event 4602).
    Invoke-CertGuest -Lab $Lab -Instance $auth -ScriptBlock { Start-Service DFSR } | Out-Null
    Start-Sleep -Seconds 20
    Invoke-CertGuest -Lab $Lab -Instance $auth -ScriptBlock $setSub -ArgumentList $auth.name, $true, $false | Out-Null
    Invoke-CertGuest -Lab $Lab -Instance $auth -ScriptBlock $sync | Out-Null
    $s = Invoke-CertGuest -Lab $Lab -Instance $auth -ScriptBlock $wait -ArgumentList 4, $TimeoutSeconds
    if ($s -ne 4) { throw "SYSVOL on $($auth.name) didn't reach Normal (state $s) after the authoritative sync. Check its DFS Replication log (event 4602 expected)." }

    # 3. The others: start, enable, copy from the PDC (events 4614, 4604).
    foreach ($d in $others) { Invoke-CertGuest -Lab $Lab -Instance $d -ScriptBlock { Start-Service DFSR } | Out-Null }
    Start-Sleep -Seconds 20
    foreach ($d in $others) { Invoke-CertGuest -Lab $Lab -Instance $auth -ScriptBlock $setSub -ArgumentList $d.name, $true, $false | Out-Null }
    Invoke-CertGuest -Lab $Lab -Instance $auth -ScriptBlock $sync | Out-Null
    $bad = @()
    foreach ($d in $others) {
        $s = Invoke-CertGuest -Lab $Lab -Instance $d -ScriptBlock $wait -ArgumentList 4, $TimeoutSeconds
        if ($s -ne 4) { $bad += "$($d.name) (state $s)" }
    }
    if ($bad) { throw "SYSVOL didn't reach Normal on $($bad -join ', ') after the authoritative sync from $($auth.name). Check their DFS Replication logs (event 4604 expected)." }
    "SYSVOL re-synced from $($auth.name) to $(if ($others) { ($others.name -join ', ') } else { 'no other DC' })"
}

function Remove-CertSnapshotSet {
    # Deletes a CERT snapshot set from every lab VM that has it. Refuses the
    # set of an open run.
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)] $Config, [Parameter(Mandatory)] $Lab, [Parameter(Mandatory)] [string] $Name)
    $active = Get-CertActiveRun -Config $Config
    if ($active -and $active.snapshot.name -eq $Name) { throw "$Name belongs to the open run $($active.id); revert it first." }
    $set = @(Get-CertSnapshotSets -Lab $Lab | Where-Object Name -eq $Name)[0]
    if (-not $set) { return "No snapshot set $Name." }
    foreach ($row in $set.Vms) {
        $vm = Get-CertPveVm -Lab $Lab -VmId $row.VmId
        if ($PSCmdlet.ShouldProcess("$($row.Instance) ($($row.VmId))", "delete snapshot $Name")) { Remove-CertPveSnapshot -Lab $Lab -Vm $vm -Name $Name }
    }
    "Removed $Name from $($set.Count) VM(s)."
}

# ── Assessor access and the engagement account ──────────────────────────

function Enable-CertAssessorAccess {
    # Lets the assessor reach every machine in the set the way a fixer
    # would need to: WinRM (HTTPS and HTTP), Remote Desktop, ping. The lab
    # normally allows WinRM from MGMT only. Undone by the revert.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Config, [Parameter(Mandatory)] $Lab, [Parameter(Mandatory)] $Run, [Parameter(Mandatory)] [object[]] $Members)
    $a = Get-CertAssessor -Config $Config -Lab $Lab
    if (-not $a) { return 'no assessor; no access opened' }
    $allow = @($Config.assessor.allow | Where-Object { $_ })
    $rdpFrom = @($Config.assessor.rdp_from | Where-Object { $_ })
    $out = @()
    foreach ($i in $Members) {
        $isAssessor = ($i.ipv4 -eq $a.Address)
        $r = Invoke-CertGuest -Lab $Lab -Instance $i -ArgumentList $a.Address, $allow, $isAssessor, $rdpFrom -ScriptBlock {
            param($From, $Allow, $IsAssessor, $RdpFrom)
            $done = @()
            if ($IsAssessor) {
                if ($RdpFrom) {
                    Set-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0
                    New-NetFirewallRule -Name 'CERT-Fixer-RDP' -DisplayName 'CERT: Remote Desktop for the fixer' -Direction Inbound -Protocol TCP -LocalPort 3389 -RemoteAddress $RdpFrom -Action Allow -Profile Any -ErrorAction SilentlyContinue | Out-Null
                    $done += "rdp from $($RdpFrom -join ',')"
                }
                return ($done -join ', ')
            }
            if ($Allow -contains 'winrm-https') {
                New-NetFirewallRule -Name 'CERT-Assessor-WinRM-HTTPS' -DisplayName 'CERT: WinRM HTTPS from the assessor' -Direction Inbound -Protocol TCP -LocalPort 5986 -RemoteAddress $From -Action Allow -Profile Any -ErrorAction SilentlyContinue | Out-Null
                $done += 'winrm-https'
            }
            if ($Allow -contains 'winrm-http') {
                # Kerberos/Negotiate still encrypts the session; this is the
                # port Enter-PSSession and most tools use by default.
                if (-not (Get-ChildItem WSMan:\localhost\Listener | Where-Object { $_.Keys -contains 'Transport=HTTP' })) {
                    New-Item -Path WSMan:\localhost\Listener -Transport HTTP -Address * -Force | Out-Null
                }
                New-NetFirewallRule -Name 'CERT-Assessor-WinRM-HTTP' -DisplayName 'CERT: WinRM HTTP from the assessor' -Direction Inbound -Protocol TCP -LocalPort 5985 -RemoteAddress $From -Action Allow -Profile Any -ErrorAction SilentlyContinue | Out-Null
                $done += 'winrm-http'
            }
            if ($Allow -contains 'rdp') {
                Set-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0
                New-NetFirewallRule -Name 'CERT-Assessor-RDP' -DisplayName 'CERT: Remote Desktop from the assessor' -Direction Inbound -Protocol TCP -LocalPort 3389 -RemoteAddress $From -Action Allow -Profile Any -ErrorAction SilentlyContinue | Out-Null
                $done += 'rdp'
            }
            if ($Allow -contains 'icmp') {
                New-NetFirewallRule -Name 'CERT-Assessor-ICMP' -DisplayName 'CERT: ping from the assessor' -Direction Inbound -Protocol ICMPv4 -IcmpType 8 -RemoteAddress $From -Action Allow -Profile Any -ErrorAction SilentlyContinue | Out-Null
                $done += 'icmp'
            }
            $done -join ', '
        }
        $out += "$($i.name): $r"
    }
    $out -join '; '
}

function New-CertPassword {
    # 24 characters from every class, no look-alikes.
    $sets = 'ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnpqrstuvwxyz', '23456789', '!@#%+=?'
    $chars = foreach ($s in $sets) { $s[[Security.Cryptography.RandomNumberGenerator]::GetInt32($s.Length)] }
    $all = -join $sets
    $chars += 1..20 | ForEach-Object { $all[[Security.Cryptography.RandomNumberGenerator]::GetInt32($all.Length)] }
    -join ($chars | Sort-Object { [Security.Cryptography.RandomNumberGenerator]::GetInt32(1000) })
}

function New-CertEngagement {
    # The account the impacted owner hands to the fixer, per the module's
    # engagement.access: domain-admin (Tier 0, in the lab's domain admins
    # group), standard (an ordinary user in People) or none.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Config, [Parameter(Mandatory)] $Lab, [Parameter(Mandatory)] $Run, [Parameter(Mandatory)] [string] $Access)
    if ($Access -eq 'none') { return [pscustomobject]@{ access = 'none'; account = $null; upn = $null; password = $null } }
    $inv  = $Lab.Inventory
    $dn   = Get-LabDomainDN -Inventory $inv
    $ou   = if ($Access -eq 'domain-admin') { Get-LabTierOU -Inventory $inv -Tier 0 -Kind Accounts } else { if ($inv.placement.standard_users) { $inv.placement.standard_users } else { 'People' } }
    $ouDn = ConvertTo-LabOUDistinguishedName -OUPath $ou -DomainDN $dn
    $group = if ($Access -eq 'domain-admin') { @(Get-LabGroupNames -Inventory $inv | Where-Object { $_ -like '*DomainAdmins*' })[0] } else { $null }
    $sam  = 'eng-' + ($Run.id -replace '^CERT-', '' -replace '-', '')   # eng-YYMMDDHHMMNN, 16 characters
    $upn  = "$sam@$($inv.identity.entra.tenant_domain)"
    $pw   = New-CertPassword
    $dc   = @(Get-CertActiveInstances -Lab $Lab -Role 'DC')[0]
    $sid = Invoke-CertGuest -Lab $Lab -Instance $dc -ArgumentList $sam, $upn, $pw, $ouDn, $group, $Run.id -ScriptBlock {
        param($Sam, $Upn, $Pw, $OuDn, $Group, $RunId)
        Import-Module ActiveDirectory
        New-ADUser -Name $Sam -SamAccountName $Sam -UserPrincipalName $Upn -Path $OuDn -Enabled $true `
            -AccountPassword (ConvertTo-SecureString $Pw -AsPlainText -Force) -PasswordNeverExpires $true `
            -Description "CERT engagement account for run $RunId (removed by the revert)"
        if ($Group) { Add-ADGroupMember -Identity $Group -Members $Sam }
        (Get-ADUser -Identity $Sam).SID.Value
    }
    $account = "$($inv.identity.active_directory.netbios)\$sam"
    $e = [pscustomobject]@{ access = $Access; account = $account; upn = $upn; password = $pw; group = $group; sid = [string] $sid; mgmt_rdp_granted = $false }
    # On MGMT, Remote Desktop is for the Tier 0 group only (the lab grants it to
    # SG-ROLE-DomainAdmins). A standard account needs it for this run; the
    # revert takes it away again, since MGMT isn't rolled back.
    $a = Get-CertAssessor -Config $Config -Lab $Lab
    if ($Access -eq 'standard' -and $a -and $a.IsMgmt) {
        Invoke-CertGuest -Lab $Lab -Instance $a.Instance -ArgumentList $account -ScriptBlock {
            param($Account)
            Add-LocalGroupMember -Group (Get-LocalGroup -SID 'S-1-5-32-555') -Member $Account -ErrorAction Stop
        } | Out-Null
        $e.mgmt_rdp_granted = $true
    }
    $e
}

function Clear-CertMgmtEngagement {
    # After a revert: the engagement account no longer exists in AD, but MGMT
    # isn't rolled back, so its traces there are CERT's to remove: any session
    # still signed in, the Remote Desktop grant, and its profile.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Config, [Parameter(Mandatory)] $Lab, [Parameter(Mandatory)] $Run)
    $e = $Run.engagement
    if (-not $e -or -not $e.account) { return 'no engagement account' }
    $mgmt = Get-CertMgmtInstance -Lab $Lab
    if (-not $mgmt) { return 'no active MGMT in the ledger' }
    Invoke-CertGuest -Lab $Lab -Instance $mgmt -ArgumentList $e.account, $e.sid, [bool] $e.mgmt_rdp_granted -ScriptBlock {
        param($Account, $Sid, $Granted)
        $done = @()
        $sam = ($Account -split '\\')[-1]
        foreach ($line in @(& quser.exe 2>$null | Select-Object -Skip 1)) {
            $f = ($line.Trim() -replace '^>', '') -split '\s+'
            if ($f[0] -eq $sam) {
                $id = @($f | Where-Object { $_ -match '^\d+$' })[0]
                if ($id) { & logoff.exe $id 2>$null; $done += "signed out session $id" }
            }
        }
        if ($Granted) {
            $g = Get-LocalGroup -SID 'S-1-5-32-555'
            $m = @(Get-LocalGroupMember -Group $g -ErrorAction SilentlyContinue | Where-Object { $_.SID.Value -eq $Sid -or $_.Name -eq $Account })
            foreach ($x in $m) { Remove-LocalGroupMember -Group $g -Member $x.SID -ErrorAction SilentlyContinue; $done += 'Remote Desktop grant removed' }
        }
        if ($Sid) {
            Start-Sleep -Seconds 3
            $p = Get-CimInstance -ClassName Win32_UserProfile -Filter "SID='$Sid'" -ErrorAction SilentlyContinue
            if ($p) {
                try { $p | Remove-CimInstance -ErrorAction Stop; $done += "profile $($p.LocalPath) removed" }
                catch { $done += "profile $($p.LocalPath) still in use; remove it later (System Properties > User Profiles)" }
            }
        }
        if (-not $done) { 'nothing left on MGMT' } else { $done -join '; ' }
    }
}

# ── The run ───────────────────────────────────────────────────────────────

function Start-CertRun {
    # Pre-flight, snapshot, assessor access, engagement account, break, and the
    # first check that the break took. Returns the run record. Anything that
    # fails after the snapshot leaves the run open so you can revert it.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Config, [Parameter(Mandatory)] $Lab, [Parameter(Mandatory)] $Module,
        [switch] $Blind, [switch] $Force
    )
    $m = $Module.Manifest
    Write-Host "Pre-flight for $($m.id) $($m.version)..."
    $pf = Test-CertPreflight -Config $Config -Lab $Lab -Module $Module
    foreach ($w in $pf.Warnings) { Write-Warning $w }
    if (-not $pf.Ok) { throw "Pre-flight failed:`n  - $($pf.Errors -join "`n  - ")" }

    $targets = Resolve-CertTargets -Config $Config -Lab $Lab -Manifest $m
    $name = New-CertSnapshotName -Lab $Lab -Vms @($pf.Vms.Vm)
    $assessor = Get-CertAssessor -Config $Config -Lab $Lab
    $run = [pscustomobject]@{
        id          = $name
        cert        = $script:CertVersion
        state       = 'Prepared'
        blind       = [bool] $Blind
        owner       = $env:USERNAME
        created_utc = (Get-Date).ToUniversalTime().ToString('o')
        updated_utc = $null
        module      = [pscustomobject]@{ key = $Module.Key; id = $m.id; version = $m.version; name = $m.name; source = $Module.Source; commit = $Module.Commit; path = $Module.Path }
        lab         = [pscustomobject]@{ site = $Lab.Site; release = $Lab.Release; version = $Lab.Version; ledger_hash = $Lab.LedgerHash }
        set         = @($pf.Vms | ForEach-Object { [pscustomobject]@{ name = $_.Instance.name; role = $_.Instance.role; vmid = $_.Vm.VmId; node = $_.Vm.Node } })
        targets     = [pscustomobject] @{}
        assessor    = if ($assessor) { [pscustomobject]@{ name = $assessor.Name; address = $assessor.Address; is_mgmt = $assessor.IsMgmt } } else { $null }
        snapshot    = [pscustomobject]@{ name = $name; ram = [bool] $Config.snapshot.include_ram }
        baseline    = $pf.Baseline
        engagement  = $null
        expected    = @()
        checks      = @()
        timeline    = @()
        notes       = @()
    }
    foreach ($k in $targets.Keys) { $run.targets | Add-Member -NotePropertyName $k -NotePropertyValue @(@($targets[$k]) | ForEach-Object name) }

    Save-CertRun -Config $Config -Run $run
    Write-CertLock -Config $Config -Run $run
    Add-CertRunEvent -Config $Config -Run $run -Event 'prepared' -Detail "$($m.id) $($m.version) against $($run.set.name -join ', ')"

    Write-Host "Snapshot set $name..."
    try { New-CertSnapshotSet -Config $Config -Lab $Lab -Vms $pf.Vms -Name $name -Purpose "Run $name, module $($m.id) $($m.version)." }
    catch {
        Remove-Item (Get-CertLockPath -Config $Config) -Force -ErrorAction SilentlyContinue
        $run.state = 'Failed'; Add-CertRunEvent -Config $Config -Run $run -Event 'snapshot failed' -Detail $_.Exception.Message
        throw
    }
    $run.state = 'Snapshotted'
    Add-CertRunEvent -Config $Config -Run $run -Event 'snapshotted' -Detail "$name on $($pf.Vms.Count) VM(s)$(if ($run.snapshot.ram) { ', with RAM' })"

    try {
        # Resumed VMs need a moment before WinRM answers again.
        foreach ($i in $pf.Members) {
            $s = Connect-CertGuest -Lab $Lab -Instance $i -TimeoutSeconds 300
            if (-not $s) { throw "$($i.name) ($($i.ipv4)) doesn't answer over WinRM/HTTPS since the snapshot. Check on Proxmox that it's running, not paused (qm status <vmid> --verbose)." }
            Remove-PSSession $s
        }
        Add-CertRunEvent -Config $Config -Run $run -Event 'assessor access' -Detail (Enable-CertAssessorAccess -Config $Config -Lab $Lab -Run $run -Members $pf.Members)
        $run.engagement = New-CertEngagement -Config $Config -Lab $Lab -Run $run -Access ([string] $m.engagement.access)
        Save-CertRun -Config $Config -Run $run
        Add-CertRunEvent -Config $Config -Run $run -Event 'engagement' -Detail $(if ($run.engagement.account) { "$($run.engagement.account) ($($run.engagement.access))" } else { 'no account handed over' })
        if ($run.engagement.account) {
            $where = try { Set-CertEngagementNote -Lab $Lab -Run $run } catch { Write-Warning "Couldn't put the engagement account in MGMT's Proxmox Notes: $($_.Exception.Message)"; "not written: $($_.Exception.Message)" }
            Add-CertRunEvent -Config $Config -Run $run -Event 'account in notes' -Detail $where
        }
    } catch {
        Add-CertRunEvent -Config $Config -Run $run -Event 'setup failed' -Detail $_.Exception.Message
        throw "Run $($run.id) is open, but setting up after the snapshot failed: $($_.Exception.Message) Nothing has been broken. Revert the run (menu 9) to clean up."
    }

    # Setup changes every machine's firewall, and a machine can stop answering
    # WinRM for a while afterwards (a DC running Tailscale did, for at least a
    # minute; why isn't known). Wait until every target answers before breaking.
    Write-Host 'Waiting for the targets to answer...'
    $targetInstances = @($targets.Values | ForEach-Object { @($_) } | Where-Object { $_ } | Sort-Object name -Unique)
    try {
        $ready = Wait-CertGuests -Lab $Lab -Instances $targetInstances -TimeoutSeconds 300
        Add-CertRunEvent -Config $Config -Run $run -Event 'targets ready' -Detail $(if ($Blind) { 'every target answers' } else { $ready })
    } catch {
        $run.state = 'BreakFailed'
        Add-CertRunEvent -Config $Config -Run $run -Event 'break failed' -Detail "Nothing was broken: $($_.Exception.Message)"
        Write-Warning 'Nothing was broken. Revert the run (menu 9), then start it again.'
        return $run
    }

    Write-Host 'Breaking...'
    $ctx = [pscustomobject]@{ Lab = $Lab; Config = $Config; Run = $run; Targets = $targets; Assessor = $assessor; ModulePath = $Module.Path; ConnectTimeoutSeconds = 300 }
    try {
        $out = Invoke-CertModuleScript -Path (Join-Path $Module.Path $m.break) -Context $ctx
        $run.state = 'Broken'
        Add-CertRunEvent -Config $Config -Run $run -Event 'broken' -Detail $(if ($Blind) { 'details hidden (blind run)' } else { (@($out) | ForEach-Object { "$_" }) -join '; ' })
    } catch {
        $run.state = 'BreakFailed'
        Add-CertRunEvent -Config $Config -Run $run -Event 'break failed' -Detail $_.Exception.Message
        Write-Warning 'The break failed, perhaps part-way: the lab may be half-broken. Revert the run (menu 9).'
        return $run
    }

    $settle = if ($m.settle_seconds) { [int] $m.settle_seconds } else { 60 }
    Write-Host "Waiting $settle s for the break to show, then checking it took..."
    Start-Sleep -Seconds $settle
    Test-CertBreak -Config $Config -Lab $Lab -Run $run -Module $Module | Out-Null
    $run
}

function Get-CertValidationSet {
    # Instances to validate: the set, minus targets the module excludes
    # (a DC it switched off can't validate itself).
    param($Lab, $Run, $Manifest)
    $skip = @(foreach ($t in @($Manifest.exclude_from_validation | Where-Object { $_ })) { @($Run.targets.$t) })
    @($Lab.Instances | Where-Object { @($Run.set.name) -contains $_.name -and $skip -notcontains $_.name })
}

function Invoke-CertVerify {
    # Runs the module's verify.ps1 and returns its checks (with a severity:
    # Critical unless the module says otherwise). @() if it has none.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Config, [Parameter(Mandatory)] $Lab, [Parameter(Mandatory)] $Run, [Parameter(Mandatory)] $Module)
    $m = $Module.Manifest
    if (-not $m.verify) { return @() }
    $targets = [ordered]@{}
    foreach ($p in $Run.targets.PSObject.Properties) {
        $inst = @($Lab.Instances | Where-Object { @($p.Value) -contains $_.name })
        $multi = @($m.targets | Where-Object { $_.name -eq $p.Name -and $_.select -eq 'all-dcs' }).Count -gt 0
        $targets[$p.Name] = if ($multi) { , $inst } else { $inst[0] }
    }
    $ctx = [pscustomobject]@{ Lab = $Lab; Config = $Config; Run = $Run; Targets = $targets; Assessor = (Get-CertAssessor -Config $Config -Lab $Lab); ModulePath = $Module.Path }
    try {
        @(Invoke-CertModuleScript -Path (Join-Path $Module.Path $m.verify) -Context $ctx) | Where-Object { $_ } | ForEach-Object {
            $sev = if ($_.Passed) { 'Pass' } elseif ($_.Severity) { [string] $_.Severity } else { 'Critical' }
            [pscustomobject]@{ source = 'module'; on = $_.On; id = $_.Name; passed = [bool] $_.Passed; severity = $sev; detail = $_.Detail }
        }
    } catch { [pscustomobject]@{ source = 'module'; on = $null; id = 'verify'; passed = $false; severity = 'Critical'; detail = "verify.ps1 threw: $($_.Exception.Message)" } }
}

function Test-CertBreak {
    # Did the break show up as the module said it would? Each expected lab
    # validation failure is looked for, and the module's own verify.ps1 should
    # now fail at least one blocking check. Returns $true when both hold.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Config, [Parameter(Mandatory)] $Lab, [Parameter(Mandatory)] $Run, [Parameter(Mandatory)] $Module)
    if ($Run.state -eq 'BreakFailed') {
        Write-Warning "The break failed (see the run's timeline), so there's nothing to check. Revert the run (menu 9), then start it again."
        return $false
    }
    $m = $Module.Manifest
    $seen = @{}
    if (@($m.expected_failures | Where-Object { $_ }).Count) {
        foreach ($i in Get-CertValidationSet -Lab $Lab -Run $Run -Manifest $m) {
            $rep = Invoke-CertLabValidation -Lab $Lab -Instance $i
            if (-not $rep) { continue }
            foreach ($r in @($rep.results | Where-Object { -not $_.passed })) { $seen[$r.id] = @(@($seen[$r.id]) + $i.name | Where-Object { $_ }) }
        }
    }
    $Run.expected = @(foreach ($id in @($m.expected_failures | Where-Object { $_ })) {
        [pscustomobject]@{ id = $id; seen = $seen.ContainsKey($id); on = @($seen[$id]) }
    })
    $missing = @($Run.expected | Where-Object { -not $_.seen } | ForEach-Object id)
    $verifyOk = $true
    if ($m.verify) {
        $failing = @(Invoke-CertVerify -Config $Config -Lab $Lab -Run $Run -Module $Module | Where-Object { -not $_.passed -and $_.severity -in 'Critical', 'High' })
        $verifyOk = $failing.Count -gt 0
        if (-not $verifyOk) { $missing += "the module's own checks (verify.ps1 still passes)" }
    }
    $detail = if ($missing) { "not seen yet: $($missing -join ', ') (some show only after a while; check again before handing over)" } else { 'every expected failure seen' }
    Add-CertRunEvent -Config $Config -Run $Run -Event 'break checked' -Detail $(if ($Run.blind) { if ($missing) { 'not everything expected is visible yet' } else { 'the break took' } } else { $detail })
    $missing.Count -eq 0
}

function Start-CertClock {
    # The impacted owner has handed over to the fixer.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Config, [Parameter(Mandatory)] $Run, [string] $Fixer)
    if ($Run.state -notin 'Broken', 'InProgress') { throw "Run $($Run.id) is $($Run.state); the clock starts after the break." }
    $Run.state = 'InProgress'
    Add-CertRunEvent -Config $Config -Run $Run -Event 'handed over' -Detail $(if ($Fixer) { "to $Fixer" } else { $null })
}

function Add-CertRunNote {
    # Milestones (cause identified, ...) or free notes, timestamped.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Config, [Parameter(Mandatory)] $Run, [Parameter(Mandatory)] [string] $Text, [switch] $CauseIdentified)
    if ($CauseIdentified) { Add-CertRunEvent -Config $Config -Run $Run -Event 'cause identified' -Detail $Text }
    else { Add-CertRunEvent -Config $Config -Run $Run -Event 'note' -Detail $Text }
}

function Test-CertRepair {
    # The fixer says it's fixed: lab validation on the set (minus excluded
    # targets) must have no Critical or High failure, and the module's own
    # verify.ps1 (when it has one) must pass every check.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Config, [Parameter(Mandatory)] $Lab, [Parameter(Mandatory)] $Run, [Parameter(Mandatory)] $Module)
    $m = $Module.Manifest
    $results = @()
    foreach ($i in Get-CertValidationSet -Lab $Lab -Run $Run -Manifest $m) {
        $rep = Invoke-CertLabValidation -Lab $Lab -Instance $i
        if (-not $rep) {
            $reach = Test-CertGuestReachable -Lab $Lab -Instance $i
            $results += [pscustomobject]@{ source = 'lab'; on = $i.name; id = 'REACH'; passed = $reach; severity = if ($reach) { 'Pass' } else { 'Critical' }; detail = if ($reach) { 'no lab validation on this machine' } else { 'CERT cannot reach it over WinRM/HTTPS' } }
            continue
        }
        foreach ($r in @($rep.results)) { $results += [pscustomobject]@{ source = 'lab'; on = $i.name; id = $r.id; passed = [bool] $r.passed; severity = $r.severity; detail = $r.detail } }
    }
    $results += @(Invoke-CertVerify -Config $Config -Lab $Lab -Run $Run -Module $Module)
    $blocking = @($results | Where-Object { -not $_.passed -and $_.severity -in 'Critical', 'High' })
    $ok = ($blocking.Count -eq 0)
    $Run.checks = @($Run.checks) + [pscustomobject]@{ at = (Get-Date).ToUniversalTime().ToString('o'); passed = $ok; results = $results }
    if ($ok) {
        $Run.state = 'Repaired'
        $start = Get-CertRunEventTime -Run $Run -Event 'handed over'
        $took = if ($start) { ' after ' + (Format-CertDuration ((Get-Date).ToUniversalTime() - $start)) } else { '' }
        Add-CertRunEvent -Config $Config -Run $Run -Event 'repaired' -Detail "check passed$took"
    } else {
        Add-CertRunEvent -Config $Config -Run $Run -Event 'check failed' -Detail "$($blocking.Count) blocking: $(@($blocking | Select-Object -First 6 | ForEach-Object { "$($_.id)@$($_.on)" }) -join ', ')"
    }
    [pscustomobject]@{ Passed = $ok; Results = $results }
}

function Restore-CertRun {
    # Ends a run: every VM in the set back to the snapshot, clocks set, the
    # lock removed. -RemoveSnapshot also deletes the set (default: keep it, so
    # the same starting point can be used again).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Config, [Parameter(Mandatory)] $Lab, [Parameter(Mandatory)] $Run,
        [switch] $RemoveSnapshot, [switch] $Force
    )
    if ($Run.state -eq 'Reverted') { throw "Run $($Run.id) is already reverted." }
    if ($Lab.LedgerHash -ne $Run.lab.ledger_hash -and -not $Force) {
        throw "The lab's ledger changed since run $($Run.id) took its snapshot (a rotation or phase ran). Rolling back would bring back machines the ledger no longer lists. Sort the ledger out first, or use -Force if you're sure."
    }
    $vms = foreach ($s in $Run.set) {
        $inst = @($Lab.Instances | Where-Object name -eq $s.name)[0]
        if (-not $inst) { $inst = [pscustomobject]@{ name = $s.name; vmid = $s.vmid; role = $s.role; ipv4 = $null } }
        [pscustomobject]@{ Instance = $inst; Vm = (Assert-CertLabVm -Lab $Lab -Instance $inst) }
    }
    Add-CertRunEvent -Config $Config -Run $Run -Event 'reverting' -Detail "to $($Run.snapshot.name)"
    Restore-CertSnapshotSet -Lab $Lab -Vms @($vms) -Name $Run.snapshot.name

    # Clocks: the PDC emulator first (it's the domain's time source), then the rest.
    $pdcFirst = @($vms | Sort-Object { if ($_.Instance.role -eq 'DC') { 0 } else { 1 } })
    foreach ($v in $pdcFirst) {
        try { $null = Sync-CertGuestTime -Lab $Lab -Instance $v.Instance }
        catch { Write-Warning "Couldn't set the clock on $($v.Instance.name): $($_.Exception.Message)" }
    }
    if (@($vms | Where-Object { $_.Instance.role -eq 'DC' }).Count) {
        $r = try { Repair-CertSysvol -Lab $Lab } catch { Write-Warning $_.Exception.Message; "failed: $($_.Exception.Message)" }
        Add-CertRunEvent -Config $Config -Run $Run -Event 'SYSVOL' -Detail $r
    }
    if ($Run.engagement -and $Run.engagement.account) {
        $c = try { Clear-CertMgmtEngagement -Config $Config -Lab $Lab -Run $Run } catch { "couldn't clean up: $($_.Exception.Message)" }
        Add-CertRunEvent -Config $Config -Run $Run -Event 'MGMT cleaned up' -Detail $c
    }
    $n = try { Clear-CertEngagementNote -Lab $Lab -Run $Run } catch { Write-Warning "Couldn't remove the engagement account from MGMT's Proxmox Notes: $($_.Exception.Message)"; "couldn't: $($_.Exception.Message)" }
    if ($n) { Add-CertRunEvent -Config $Config -Run $Run -Event 'notes cleared' -Detail $n }
    $Run.state = 'Reverted'
    Add-CertRunEvent -Config $Config -Run $Run -Event 'reverted' -Detail "clocks set from MGMT"
    Remove-Item (Get-CertLockPath -Config $Config) -Force -ErrorAction SilentlyContinue
    if ($RemoveSnapshot) {
        Add-CertRunEvent -Config $Config -Run $Run -Event 'snapshot removed' -Detail (Remove-CertSnapshotSet -Config $Config -Lab $Lab -Name $Run.snapshot.name -Confirm:$false)
    }
    $Run
}

function Test-CertSnapshotRoundTrip {
    # Snapshot and revert with nothing broken: proves the Proxmox rights, the
    # storage and the timings before a real scenario depends on them.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Config, [Parameter(Mandatory)] $Lab)
    $pf = Test-CertPreflight -Config $Config -Lab $Lab -SkipBaseline
    foreach ($w in $pf.Warnings) { Write-Warning $w }
    if (-not $pf.Ok) { throw "Pre-flight failed:`n  - $($pf.Errors -join "`n  - ")" }
    $name = New-CertSnapshotName -Lab $Lab -Vms @($pf.Vms.Vm)
    $t0 = Get-Date
    New-CertSnapshotSet -Config $Config -Lab $Lab -Vms $pf.Vms -Name $name -Purpose 'Snapshot test (nothing broken).'
    $t1 = Get-Date
    Restore-CertSnapshotSet -Lab $Lab -Vms $pf.Vms -Name $name
    foreach ($v in $pf.Vms) { try { $null = Sync-CertGuestTime -Lab $Lab -Instance $v.Instance } catch { Write-Warning "Clock on $($v.Instance.name): $($_.Exception.Message)" } }
    $sysvol = if (@($pf.Vms | Where-Object { $_.Instance.role -eq 'DC' }).Count) { try { Repair-CertSysvol -Lab $Lab } catch { Write-Warning $_.Exception.Message; 'SYSVOL sync failed' } } else { 'no DCs' }
    $t2 = Get-Date
    foreach ($v in $pf.Vms) { Remove-CertPveSnapshot -Lab $Lab -Vm $v.Vm -Name $name }
    "Snapshot of $($pf.Vms.Count) VM(s) took $(Format-CertDuration ($t1 - $t0)); revert, clocks and SYSVOL $(Format-CertDuration ($t2 - $t1)) ($sysvol). Test set removed."
}

function Format-CertDuration {
    param([TimeSpan] $Span)
    if ($Span.TotalHours -ge 1) { '{0}h {1:D2}m' -f [int][math]::Floor($Span.TotalHours), $Span.Minutes }
    elseif ($Span.TotalMinutes -ge 1) { '{0}m {1:D2}s' -f $Span.Minutes, $Span.Seconds }
    else { '{0}s' -f [int] $Span.TotalSeconds }
}

# ── Helpers for module scripts ────────────────────────────────────────────

function Stop-CertTarget {
    # Powers a target off hard (pulled plug). The VM stays; the revert brings it back.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Context, [Parameter(Mandatory)] $Instance)
    $vm = Assert-CertLabVm -Lab $Context.Lab -Instance $Instance
    Invoke-CertPveVmAction -Lab $Context.Lab -Vm $vm -Action stop
    "$($Instance.name) powered off"
}

function Set-CertTargetLink {
    # Cable a target's network in or out.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Context, [Parameter(Mandatory)] $Instance, [Parameter(Mandatory)] [bool] $Up)
    $vm = Assert-CertLabVm -Lab $Context.Lab -Instance $Instance
    Set-CertPveVmLink -Lab $Context.Lab -Vm $vm -Up $Up
    "$($Instance.name) network $(if ($Up) { 'connected' } else { 'disconnected' })"
}

function Set-CertEngagementNote {
    # The engagement account and its password in MGMT's Proxmox Notes, so an
    # admin who loses their session (a scenario may change their password) can
    # still find them, with their Proxmox login. Removed by the revert.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Lab, [Parameter(Mandatory)] $Run)
    $mgmt = Get-CertMgmtInstance -Lab $Lab
    if (-not $mgmt) { throw 'no active MGMT in the ledger' }
    $vm = Assert-CertLabVm -Lab $Lab -Instance $mgmt
    $e = $Run.engagement
    Add-CertPveVmNote -Lab $Lab -Vm $vm -RunId $Run.id -Lines @(
        "Engagement account for this CERT run ($($e.access)):", '', '```', "Account:  $($e.account)", "UPN:      $($e.upn)", "Password: $($e.password)", '```')
    "$($mgmt.name), Proxmox Notes"
}

function Clear-CertEngagementNote {
    # Takes the run's block out of MGMT's Proxmox Notes. Returns what it did,
    # or $null when there was nothing to remove.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Lab, [Parameter(Mandatory)] $Run)
    $mgmt = Get-CertMgmtInstance -Lab $Lab
    if (-not $mgmt) { return $null }
    $vm = Assert-CertLabVm -Lab $Lab -Instance $mgmt
    if (Remove-CertPveVmNote -Lab $Lab -Vm $vm -RunId $Run.id) { "removed from $($mgmt.name)'s Proxmox Notes" } else { $null }
}

function Invoke-CertModuleScript {
    # Runs a module's break.ps1 or verify.ps1 in a scope of its own, outside
    # CERT's module. Run from inside it (`& $path`), the script gets a new
    # script scope in CERT's session state, and every CERT function it calls
    # then looks up its $script: variables there: the WinRM session option,
    # cached credentials and tokens all came back $null, so no module could
    # reach a guest (0.2.5 and before). The script still sees every exported
    # CERT function, and the lab's (imported -Global).
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] $Context)
    $own = [psmoduleinfo]::new($true)
    & $own { param($ScriptPath, $ScriptContext) & $ScriptPath -Context $ScriptContext } $Path $Context
}

function Invoke-CertTarget {
    # Runs a script block (Windows PowerShell 5.1) on a target. -TimeoutSeconds:
    # how long to keep trying to connect (default: 300 during the break, else 60).
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Context, [Parameter(Mandatory)] $Instance, [Parameter(Mandatory)] [scriptblock] $ScriptBlock, [object[]] $ArgumentList = @(), [int] $TimeoutSeconds = 0)
    if (-not $TimeoutSeconds) { $TimeoutSeconds = if ($Context.PSObject.Properties['ConnectTimeoutSeconds'] -and $Context.ConnectTimeoutSeconds) { [int] $Context.ConnectTimeoutSeconds } else { 60 } }
    Invoke-CertGuest -Lab $Context.Lab -Instance $Instance -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList -TimeoutSeconds $TimeoutSeconds
}

function New-CertCheck {
    # One verify.ps1 result. -Severity: what a failure counts as (Critical or
    # High block the repair; Medium or Low are reported only).
    param(
        [Parameter(Mandatory)] [string] $Name, [Parameter(Mandatory)] [bool] $Passed, [string] $Detail, [string] $On,
        [ValidateSet('Critical', 'High', 'Medium', 'Low')] [string] $Severity = 'Critical'
    )
    [pscustomobject]@{ Name = $Name; Passed = $Passed; Detail = $Detail; On = $On; Severity = $Severity }
}

function Save-CertModuleState {
    # What a break needs to remember for its verify (a time, a GUID, the
    # accounts it changed): module-state.json in the run folder, on MGMT only.
    param([Parameter(Mandatory)] $Context, [Parameter(Mandatory)] $State)
    $p = Join-Path (Get-CertRunsPath -Config $Context.Config) "$($Context.Run.id)/module-state.json"
    $State | ConvertTo-Json -Depth 10 | Set-Content -Path $p -Encoding utf8NoBOM
}

function Get-CertModuleState {
    param([Parameter(Mandatory)] $Context)
    $p = Join-Path (Get-CertRunsPath -Config $Context.Config) "$($Context.Run.id)/module-state.json"
    if (Test-Path $p) { Get-Content -Path $p -Raw | ConvertFrom-Json } else { $null }
}
