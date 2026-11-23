#Requires -Version 7.2
<#
.SYNOPSIS
    Offline tests for CERT: no Proxmox, no guests. Proxmox is a fake that
    records calls, so the snapshot and revert sequences can be checked.

.PARAMETER LabRoot
    A midcoast-labs clone (its lab.yaml, site.example.yaml, Lab.Inventory and
    validation catalog are used to build a fake lab).

.EXAMPLE
    ./tests/Run-Tests.ps1 -LabRoot ../midcoast-labs
#>
[CmdletBinding()]
param([Parameter(Mandatory)] [string] $LabRoot)
$ErrorActionPreference = 'Stop'
$certRoot = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $certRoot 'src/Cert/Cert.psm1') -Force -DisableNameChecking
$cert = Get-Module Cert

$script:failed = 0; $script:passed = 0
function Assert([string] $Name, [scriptblock] $Test) {
    try {
        if (& $Test) { $script:passed++; Write-Host "  ok    $Name" }
        else { $script:failed++; Write-Host "  FAIL  $Name" -ForegroundColor Red }
    } catch { $script:failed++; Write-Host "  FAIL  $Name : $($_.Exception.Message)" -ForegroundColor Red }
}
function Assert-Throws([string] $Name, [scriptblock] $Test, [string] $Like = '*') {
    try { & $Test; $script:failed++; Write-Host "  FAIL  $Name (no error)" -ForegroundColor Red }
    catch { if ($_.Exception.Message -like $Like) { $script:passed++; Write-Host "  ok    $Name" } else { $script:failed++; Write-Host "  FAIL  $Name : $($_.Exception.Message)" -ForegroundColor Red } }
}

# ── A fake lab on disk ────────────────────────────────────────────────────
$tmp = Join-Path ([IO.Path]::GetTempPath()) "cert-tests-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
$lab = Join-Path $tmp 'lab'
foreach ($d in 'inventory', 'platform/modules/Lab.Inventory', 'platform/validation') { New-Item -ItemType Directory -Path (Join-Path $lab $d) -Force | Out-Null }
Copy-Item (Join-Path $LabRoot 'inventory/lab.yaml') (Join-Path $lab 'inventory/lab.yaml')
Copy-Item (Join-Path $LabRoot 'inventory/site.example.yaml') (Join-Path $lab 'inventory/site.yaml')
Copy-Item (Join-Path $LabRoot 'platform/modules/Lab.Inventory/Lab.Inventory.psm1') (Join-Path $lab 'platform/modules/Lab.Inventory/')
Copy-Item (Join-Path $LabRoot 'platform/validation/catalog.psd1') (Join-Path $lab 'platform/validation/')
@'
instances:
- name: DC-261101-00
  role: DC
  sequence: '00'
  build_date: '261101'
  slot: A
  vmid: 100
  ipv4: 10.50.10.10
  state: active
- name: DC-261101-01
  role: DC
  sequence: '01'
  build_date: '261101'
  slot: B
  vmid: 101
  ipv4: 10.50.10.11
  state: active
- name: MGMT-261102-00
  role: MGMT
  sequence: '00'
  build_date: '261102'
  slot: B
  vmid: 121
  ipv4: 10.50.10.31
  state: active
- name: W11-261103-00
  role: W11
  sequence: '00'
  build_date: '261103'
  vmid: 140
  ipv4: 10.50.10.40
  state: active
templates: []
'@ | Set-Content (Join-Path $lab 'inventory/instances.yaml')

$cfgPath = Join-Path $tmp 'cert.config.yaml'
@"
lab_repo: $lab
runs_path: $(Join-Path $tmp 'runs')
lock_path: $(Join-Path $tmp 'CERT.lock')
snapshot:
  max_sets: 5
"@ | Set-Content $cfgPath

Write-Host 'Config and lab'
$config = Get-CertConfig -Path $cfgPath
Assert 'local config overrides a default' { $config.snapshot.max_sets -eq 5 }
Assert 'defaults kept beside an override' { $config.snapshot.include_ram -eq $true -and $config.snapshot.storage_warn_percent -eq 80 }
Assert 'arrays come from the defaults' { @($config.assessor.allow) -contains 'winrm-http' }
$L = Get-CertLab -Config $config
Assert 'lab resolves through the lab''s own Lab.Inventory' { $L.Inventory.identity.active_directory.domain -eq 'ad.example.com' -and $L.Inventory.proxmox.node -eq 'pve01' }
Assert 'ledger read' { @($L.Instances).Count -eq 4 }
Assert 'ledger hash ignores line endings' { $L.LedgerHash -eq (Get-CertTextHash -Text ((Get-Content (Join-Path $lab 'inventory/instances.yaml') -Raw) -replace "`n", "`r`n")) }
Assert 'compatibility of the lab this CERT targets' { (Test-CertLabCompatibility -Lab $L).Ok }
Assert 'another major is refused' { -not (Test-CertLabCompatibility -Lab ([pscustomobject]@{ Version = '2.0'; Release = 'x' })).Ok }
Assert 'another minor warns' { $c = Test-CertLabCompatibility -Lab ([pscustomobject]@{ Version = '1.7'; Release = 'x' }); $c.Ok -and $c.Message -like '*Expected to work*' }
$as = Get-CertAssessor -Config $config -Lab $L
Assert 'by default the fixer works on MGMT' { $as.IsMgmt -and $as.Address -eq '10.50.10.31' -and -not $as.Fallback }
$cfgW11 = Merge-CertObject -Base $config -Overlay ([pscustomobject]@{ assessor = [pscustomobject]@{ role = 'W11' } })
Assert 'assessor.role W11 picks the active W11' { $x = Get-CertAssessor -Config $cfgW11 -Lab $L; $x.Address -eq '10.50.10.40' -and -not $x.IsMgmt }
$Lnow11 = Get-CertLab -Config $config; $Lnow11.Instances = @($Lnow11.Instances | Where-Object role -ne 'W11')
Assert 'no W11: falls back to MGMT, and says so' { $x = Get-CertAssessor -Config $cfgW11 -Lab $Lnow11; $x.IsMgmt -and $x.Fallback }
$cfgAddr = Merge-CertObject -Base $config -Overlay ([pscustomobject]@{ assessor = [pscustomobject]@{ address = '10.50.10.77' } })
Assert 'a fixed address is used as given' { $x = Get-CertAssessor -Config $cfgAddr -Lab $L; $x.Address -eq '10.50.10.77' -and -not $x.IsMgmt }
$members = & $cert { param($c, $l) Get-CertSnapshotSetMembers -Config $c -Lab $l } $config $L
Assert 'the 1.6 per-site tag comes from the inventory' { (Get-CertLabTag -Lab $L) -eq 'midcoast-lab-example-lab' }
Assert 'snapshot set: every active VM except MGMT' { (@($members.name) -join ',') -eq 'DC-261101-00,DC-261101-01,W11-261103-00' }
$cfgNoMgmt = Merge-CertObject -Base $config -Overlay ([pscustomobject]@{ snapshot = [pscustomobject]@{ exclude_roles = @('W11') } })
$members2 = & $cert { param($c, $l) Get-CertSnapshotSetMembers -Config $c -Lab $l } $cfgNoMgmt $L
Assert 'MGMT stays out even when exclude_roles forgets it' { @($members2.name) -notcontains 'MGMT-261102-00' -and @($members2.name) -notcontains 'W11-261103-00' }

Write-Host 'Targets'
$mgmtTarget = [pscustomobject]@{ targets = @([pscustomobject]@{ name = 'victim'; select = 'role:MGMT' }) }
Assert-Throws 'a module can never target MGMT' { Resolve-CertTargets -Config $config -Lab $L -Manifest $mgmtTarget } "*isn't in the snapshot set*"
$dcTarget = [pscustomobject]@{ targets = @([pscustomobject]@{ name = 'all'; select = 'all-dcs' }) }
Assert 'all-dcs resolves to both DCs' { @((Resolve-CertTargets -Config $config -Lab $L -Manifest $dcTarget)['all']).Count -eq 2 }

Write-Host 'Versions and requirements'
Assert '1.5 = 1.5.0' { (Compare-CertVersion '1.5' '1.5.0') -eq 0 }
Assert '0.10 > 0.9' { (Compare-CertVersion '0.10' '0.9') -eq 1 }
Assert '>=0.1 met by 0.1.0' { Test-CertRequirement '>=0.1' '0.1.0' }
Assert '>=1.6 not met by 1.5' { -not (Test-CertRequirement '>=1.6' '1.5') }
Assert-Throws 'only >= is supported' { Test-CertRequirement '~1.5' '1.5' } '*Unsupported*'

Write-Host 'Modules'
$mods = @(Get-CertModules -Config $config -LabRoot $lab)
Assert 'six built-in modules, all valid' { $mods.Count -eq 6 -and @($mods | Where-Object { -not $_.Valid }).Count -eq 0 }
$bad = Join-Path $tmp 'bad/Bad_Module'
New-Item -ItemType Directory -Path $bad -Force | Out-Null
@'
id: other-name
version: 1.0
name: x
summary: x
category: Weather
difficulty: 9
destructive: maybe
requires: { cert: "~0.1" }
targets:
  - { name: v, select: the-big-one }
engagement: { access: root, briefing: ../etc/passwd }
expected_failures: [repl-1, ZZZ-999]
break: break.sh
solution: solution.md
'@ | Set-Content (Join-Path $bad 'module.yaml')
Set-Content (Join-Path $bad 'break.sh') 'echo'
$p = @(Test-CertManifest -Manifest (Read-CertYaml (Join-Path $bad 'module.yaml')) -Folder $bad -Catalog (Get-CertLabCatalogIds -LabRoot $lab))
foreach ($want in "id 'other-name' must match", "version '", "category 'Weather'", 'difficulty', 'destructive', 'authors', "requires.cert: Unsupported", 'requires.lab is required',
                  "select 'the-big-one'", "engagement.access 'root'", 'a file name in the module folder', "'break.sh' must be a .ps1", "solution file 'solution.md' is missing", "'repl-1': a validation ID", "'ZZZ-999' isn't in the lab's validation catalog") {
    Assert "rejects: $want" { @($p | Where-Object { $_ -like "*$want*" }).Count -gt 0 }.GetNewClosure()
}
$broken = Join-Path $tmp 'parse/parse-error'
New-Item -ItemType Directory -Path $broken -Force | Out-Null
Copy-Item (Join-Path $certRoot 'modules/gpo-deleted/*') $broken
(Get-Content (Join-Path $broken 'module.yaml') -Raw).Replace('id: gpo-deleted', 'id: parse-error') | Set-Content (Join-Path $broken 'module.yaml')
Set-Content (Join-Path $broken 'break.ps1') 'param($Context) if ( {'
Assert 'a script that does not parse is a problem' { @(Test-CertManifest -Manifest (Read-CertYaml (Join-Path $broken 'module.yaml')) -Folder $broken) -like 'break.ps1: line*' }

Write-Host 'Updates from a source'
$origin = Join-Path $tmp 'origin.git'; $work = Join-Path $tmp 'work'
& git init --quiet --bare --initial-branch=main $origin
& git clone --quiet $origin $work 2>$null
& git -C $work config user.email t@example.com; & git -C $work config user.name test
New-Item -ItemType Directory -Path (Join-Path $work 'modules') -Force | Out-Null
Copy-Item (Join-Path $certRoot 'modules/gpo-deleted') (Join-Path $work 'modules/') -Recurse
& git -C $work add -A; & git -C $work commit --quiet -m one; & git -C $work push --quiet origin main 2>$null
$cfgSrc = Merge-CertObject -Base $config -Overlay ([pscustomobject]@{ sources = @([pscustomobject]@{ name = 'extra'; url = $origin; ref = 'main' }) })
$sourceRoot = Join-Path $certRoot 'sources/extra'
Remove-Item $sourceRoot -Recurse -Force -ErrorAction SilentlyContinue
try {
    $u = @(Get-CertUpdates -Config $cfgSrc -Source extra)[0]
    Assert 'a new source is reported as not cloned' { $u.State -eq 'not cloned' }
    Install-CertUpdate -Update $u | Out-Null
    Assert 'installing clones it' { Test-Path (Join-Path $sourceRoot 'modules/gpo-deleted/module.yaml') }
    Assert 'its modules join the catalog' { @(Get-CertModules -Config $cfgSrc | Where-Object Key -eq 'extra/gpo-deleted').Count -eq 1 }
    (Get-Content (Join-Path $work 'modules/gpo-deleted/module.yaml') -Raw).Replace('version: 1.0.1', 'version: 1.1.0') | Set-Content (Join-Path $work 'modules/gpo-deleted/module.yaml')
    Copy-Item (Join-Path $certRoot 'modules/dc-time-skew') (Join-Path $work 'modules/') -Recurse
    & git -C $work add -A; & git -C $work commit --quiet -m two; & git -C $work push --quiet origin main 2>$null
    $u = @(Get-CertUpdates -Config $cfgSrc -Source extra)[0]
    Assert 'behind, with the commit listed' { $u.State -eq 'behind' -and @($u.Commits).Count -eq 1 }
    Assert 'updated module shows old and new version' { @($u.Changes | Where-Object { $_.Id -eq 'gpo-deleted' -and $_.From -eq '1.0.1' -and $_.To -eq '1.1.0' }).Count -eq 1 }
    Assert 'new module shows as new' { @($u.Changes | Where-Object { $_.Id -eq 'dc-time-skew' -and $_.Change -eq 'new' }).Count -eq 1 }
    Assert 'fetching changed nothing yet' { (Read-CertYaml (Join-Path $sourceRoot 'modules/gpo-deleted/module.yaml')).version -eq '1.0.1' }
    Add-Content (Join-Path $sourceRoot 'modules/gpo-deleted/solution.md') 'local edit'
    Assert-Throws 'local edits stop an update' { Install-CertUpdate -Update $u } '*local changes*'
    & git -C $sourceRoot checkout --quiet -- .
    Install-CertUpdate -Update $u | Out-Null
    Assert 'fast-forwarded' { (Read-CertYaml (Join-Path $sourceRoot 'modules/gpo-deleted/module.yaml')).version -eq '1.1.0' }
} finally { Remove-Item $sourceRoot -Recurse -Force -ErrorAction SilentlyContinue; Remove-Item (Join-Path $certRoot 'sources') -Force -ErrorAction SilentlyContinue }

Write-Host 'Snapshot and revert sequences (fake Proxmox)'
& $cert { param($t, $p) $script:FakeTag = $t; $script:FakePool = $p } $L.Inventory.proxmox.tag $L.Inventory.proxmox.pool
& $cert {
    $script:PveCalls = [Collections.Generic.List[string]]::new()
    $script:PveSnaps = @{}
    $script:PveState = @{ 100 = 'running'; 101 = 'running'; 140 = 'running' }
    $script:PveLink  = @{ 100 = 'up'; 101 = 'up'; 140 = 'up' }
    $script:SnapLink = @{}
    function script:Get-CertPveToken { 'fake' }
    function script:Wait-CertPveTask { }
    function script:Invoke-CertPve {
        param($Lab, $Method, $Path, $Body)
        $script:PveCalls.Add("$Method $Path")
        switch -Regex ("$Method $Path") {
            '^GET /cluster/resources' { return @(100, 101, 121, 140 | ForEach-Object { [pscustomobject]@{ vmid = $_; node = 'pve01'; status = 'running'; name = @{ 100 = 'DC-261101-00'; 101 = 'DC-261101-01'; 121 = 'MGMT-261102-00'; 140 = 'W11-261103-00' }[$_]; tags = $script:FakeTag; pool = $script:FakePool; maxmem = 4GB } }) }
            '^GET /nodes/\w+/qemu/(\d+)/snapshot$' { return @($script:PveSnaps[[int] $Matches[1]] | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ name = $_; vmstate = 1; snaptime = 1762400000; description = 'ledger=0123456789ab' } }) }
            '^POST /nodes/\w+/qemu/(\d+)/snapshot$' { $script:PveSnaps[[int] $Matches[1]] = @($script:PveSnaps[[int] $Matches[1]]) + $Body.snapname; $script:SnapLink[[int] $Matches[1]] = $script:PveLink[[int] $Matches[1]]; return 'UPID:pve01:x' }
            '^GET /nodes/\w+/qemu/(\d+)/config$' { $l = if ($script:PveLink[[int] $Matches[1]] -eq 'down') { ',link_down=1' } else { '' }; return [pscustomobject]@{ net0 = "virtio=BC:24:11:00:00:01,bridge=vmbr2$l" } }
            '^PUT /nodes/\w+/qemu/(\d+)/config$' { $id = [int] $Matches[1]; $script:PveLink[$id] = if ($Body.net0 -match 'link_down=1') { 'down' } else { 'up' }; return $null }
            '^POST /nodes/\w+/qemu/(\d+)/snapshot/[^/]+/rollback' { $script:PveState[[int] $Matches[1]] = 'running'; $script:PveLink[[int] $Matches[1]] = $script:SnapLink[[int] $Matches[1]]; return 'UPID:pve01:x' }
            '^DELETE /nodes/\w+/qemu/(\d+)/snapshot/(.+)$' { $script:PveSnaps[[int] $Matches[1]] = @($script:PveSnaps[[int] $Matches[1]] | Where-Object { $_ -ne $Matches[2] }); return 'UPID:pve01:x' }
            '^POST /nodes/\w+/qemu/(\d+)/status/(\w+)' { $script:PveState[[int] $Matches[1]] = @{ suspend = 'paused'; resume = 'running'; stop = 'stopped'; start = 'running' }[$Matches[2]]; return 'UPID:pve01:x' }
            '^GET /nodes/\w+/qemu/(\d+)/status/current' { $s = $script:PveState[[int] $Matches[1]]; return [pscustomobject]@{ status = if ($s -eq 'stopped') { 'stopped' } else { 'running' }; qmpstatus = $s } }
            '^GET /nodes/\w+/storage/[^/]+/status$' { return [pscustomobject]@{ used = [long] 918055550976; total = [long] 1836111101952 } }
            default { throw "fake Proxmox: unexpected $Method $Path" }
        }
    }
}
$vms = foreach ($i in $members) { [pscustomobject]@{ Instance = $i; Vm = (Get-CertPveVm -Lab $L -VmId ([int] $i.vmid)) } }
$snapName = New-CertSnapshotName -Lab $L -Vms @($vms.Vm)
Assert 'snapshot names: CERT-YYMMDD-HHMM-NN' { $snapName -match '^CERT-\d{6}-\d{4}-00$' }
New-CertSnapshotSet -Config $config -Lab $L -Vms $vms -Name $snapName -Purpose 'test' 6>$null
$calls = @(& $cert { $script:PveCalls })
$ops = @($calls | Where-Object { $_ -match '^(POST|PUT)' } | ForEach-Object { if ($_ -match '^PUT .*/config$') { "link:$(($_ -split '/')[4])" } elseif ($_ -match 'status/(\w+)') { "$($Matches[1]):$(($_ -split '/')[4])" } elseif ($_ -match '/snapshot$') { "snap:$(($_ -split '/')[4])" } })
Assert 'all unplugged before the first snapshot' { ($ops[0..2] -join ',') -eq 'link:100,link:101,link:140' }
Assert 'then each snapshotted, running (never paused)' { ($ops[3..5] -join ',') -eq 'snap:100,snap:101,snap:140' -and -not @($ops | Where-Object { $_ -like 'suspend*' }) }
Assert 'then all plugged back in' { ($ops[6..8] -join ',') -eq 'link:100,link:101,link:140' -and @(& $cert { $script:PveLink.Values } | Where-Object { $_ -ne 'up' }).Count -eq 0 }
Assert 'every snapshot recorded the VM unplugged' { @(& $cert { $script:SnapLink.Values } | Where-Object { $_ -ne 'down' }).Count -eq 0 }
Assert 'storage use of a 1.8 TB pool (past Int32)' { (Get-CertStorageUse -Lab $L -Nodes 'pve01').UsedPercent -eq 50 }
Assert 'MGMT never touched' { -not @($calls | Where-Object { $_ -match '/qemu/121/' -and $_ -notmatch '^GET' }) }
$sets = @(Get-CertSnapshotSets -Lab $L -Members $members)
Assert 'the set is listed once, on three VMs' { $sets.Count -eq 1 -and $sets[0].Count -eq 3 -and $sets[0].Name -eq $snapName }
Assert 'the next name in the same minute is -01' { (New-CertSnapshotName -Lab $L -Vms @($vms.Vm)) -like '*-01' }

& $cert { $script:PveCalls.Clear() }
Restore-CertSnapshotSet -Lab $L -Vms $vms -Name $snapName 6>$null
$calls = @(& $cert { $script:PveCalls } | Where-Object { $_ -match '^POST' })
$firstRollback = [array]::FindIndex([string[]] $calls, [Predicate[string]] { param($c) $c -match '/rollback' })
$lastStop = [array]::FindLastIndex([string[]] $calls, [Predicate[string]] { param($c) $c -match '/status/stop' })
Assert 'every VM stopped before any rollback' { @($calls | Where-Object { $_ -match '/status/stop' }).Count -eq 3 -and $lastStop -lt $firstRollback }
Assert 'every VM rolled back' { @($calls | Where-Object { $_ -match '/rollback' }).Count -eq 3 }
$allCalls = @(& $cert { $script:PveCalls })
$lastRollback = [array]::FindLastIndex([string[]] $allCalls, [Predicate[string]] { param($c) $c -match '/rollback' })
$firstPlug = [array]::FindIndex([string[]] $allCalls, [Predicate[string]] { param($c) $c -match '^PUT .*/config$' })
Assert 'plugged back in only after every rollback' { $firstPlug -gt $lastRollback -and @(& $cert { $script:PveLink.Values } | Where-Object { $_ -ne 'up' }).Count -eq 0 }
Assert-Throws 'a VM without the snapshot stops the revert before anything changes' { Restore-CertSnapshotSet -Lab $L -Vms $vms -Name 'CERT-000000-0000-00' } '*has no snapshot*'
Assert-Throws 'only CERT snapshots can be removed' { Remove-CertPveSnapshot -Lab $L -Vm $vms[0].Vm -Name 'before-upgrade' } '*Not a CERT snapshot*'

$openRun = [pscustomobject]@{ id = $snapName; state = 'Broken'; blind = $true; owner = 'tester'; created_utc = '2026-11-23T14:00:00Z'; module = [pscustomobject]@{ id = 'gpo-deleted' }; snapshot = [pscustomobject]@{ name = $snapName }; timeline = @(); updated_utc = $null }
Save-CertRun -Config $config -Run $openRun
& $cert { param($c, $r) Write-CertLock -Config $c -Run $r } $config $openRun
$lockJson = Get-Content $config.lock_path -Raw | ConvertFrom-Json
Assert 'the lock is JSON the lab can read' { $lockJson.run -eq $snapName -and $lockJson.snapshot -eq $snapName -and $lockJson.started }
Assert 'a blind run''s lock hides the scenario' { $lockJson.scenario -eq '(blind run)' }
Assert 'the open run is found from the JSON lock' { (Get-CertActiveRun -Config $config).id -eq $snapName }
Set-Content -Path $config.lock_path -Value $snapName
Assert 'and from a 0.1 plain lock' { (Get-CertActiveRun -Config $config).id -eq $snapName }
Assert-Throws "an open run's set can't be removed" { Remove-CertSnapshotSet -Config $config -Lab $L -Name $snapName -Confirm:$false } '*belongs to the open run*'
$pf = Test-CertPreflight -Config $config -Lab $L -SkipBaseline
Assert 'pre-flight refuses while a run is open' { -not $pf.Ok -and @($pf.Errors -like '*still open*').Count -eq 1 }
Remove-Item $config.lock_path
Assert 'with no run open, the set can be removed' { (Remove-CertSnapshotSet -Config $config -Lab $L -Name $snapName -Confirm:$false) -like 'Removed*' }

Write-Host 'Pre-flight'
$pf = Test-CertPreflight -Config $config -Lab $L -SkipBaseline
Assert 'a healthy fake lab passes' { $pf.Ok }
$L2 = Get-CertLab -Config $config
$L2.Instances[1].state = 'retiring'
$pf = Test-CertPreflight -Config $config -Lab $L2 -SkipBaseline
Assert 'refuses mid-rotation' { -not $pf.Ok -and @($pf.Errors -like '*mid-change*').Count -eq 1 }
$m = @($mods | Where-Object Id -eq 'fsmo-holder-lost')[0]
$L3 = Get-CertLab -Config $config
$L3.Instances = @($L3.Instances | Where-Object name -ne 'DC-261101-01')
$pf = Test-CertPreflight -Config $config -Lab $L3 -Module $m -SkipBaseline
Assert 'refuses a module whose roles are missing' { -not $pf.Ok -and @($pf.Errors -like '*needs 2 active DC*').Count -eq 1 }

Write-Host 'Run records and reports'
$run = [pscustomobject]@{
    id = 'CERT-261106-1830-00'; cert = '0.1.0'; state = 'InProgress'; blind = $false; owner = 'tester'; created_utc = '2026-11-06T18:30:00Z'; updated_utc = $null
    module = [pscustomobject]@{ key = 'cert/gpo-deleted'; id = 'gpo-deleted'; version = '1.0.0'; name = 'GPO deleted'; source = 'cert'; commit = 'abc1234'; path = (Join-Path $certRoot 'modules/gpo-deleted') }
    lab = [pscustomobject]@{ site = 'example-lab'; release = 'LAB-261105-04'; version = '1.5'; ledger_hash = $L.LedgerHash }
    set = @([pscustomobject]@{ name = 'DC-261101-00'; role = 'DC'; vmid = 100; node = 'pve01' })
    targets = [pscustomobject]@{ dc = @('DC-261101-00') }; assessor = $null
    snapshot = [pscustomobject]@{ name = 'CERT-261106-1830-00'; ram = $true }; baseline = @(); engagement = $null
    expected = @([pscustomobject]@{ id = 'LAPS-002'; seen = $true; on = @('DC-261101-00') }); checks = @(); notes = @()
    timeline = @(
        [pscustomobject]@{ at = '2026-11-06T18:40:00Z'; event = 'handed over'; detail = $null }
        [pscustomobject]@{ at = '2026-11-06T18:52:30Z'; event = 'cause identified'; detail = 'GPO gone' }
        [pscustomobject]@{ at = '2026-11-06T19:15:05Z'; event = 'repaired'; detail = 'check passed' }
    )
}
Save-CertRun -Config $config -Run $run
$s = Get-CertRunSummary -Run (Get-CertRun -Config $config -Id $run.id)
Assert 'time to cause' { $s.TimeToCause -eq '12m 30s' }
Assert 'time to repair' { $s.TimeToRepair -eq '35m 05s' }
$rep = Get-Content (Write-CertReport -Config $config -Run $run) -Raw
Assert 'report has the module and timeline' { $rep -match 'gpo-deleted' -and $rep -match 'cause identified' -and $rep -match '\[x\] `LAPS-002`' }
Assert 'no solution in the report while the run is open' { $rep -notmatch 'Reference solution' }
$run.state = 'Reverted'
Assert 'solution included once reverted' { (Get-Content (Write-CertReport -Config $config -Run $run) -Raw) -match 'Reference solution' }

Write-Host 'Odds and ends'
$pw = 1..20 | ForEach-Object { New-CertPassword }
Assert 'passwords: 24 characters, every class' { @($pw | Where-Object { $_.Length -eq 24 -and $_ -cmatch '[A-Z]' -and $_ -cmatch '[a-z]' -and $_ -match '\d' -and $_ -match '[^A-Za-z0-9]' }).Count -eq 20 }
Assert 'passwords differ' { @($pw | Select-Object -Unique).Count -eq 20 }
Assert 'snapshot name rules' { (Test-CertSnapshotName 'CERT-261106-1830-00') -and -not (Test-CertSnapshotName '1abc') -and -not (Test-CertSnapshotName ('A' * 41)) }
Assert 'durations' { (Format-CertDuration ([timespan]::FromSeconds(42))) -eq '42s' -and (Format-CertDuration ([timespan]::FromMinutes(135))) -eq '2h 15m' }

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-Host "$script:passed passed, $script:failed failed"
if ($script:failed) { exit 1 }
