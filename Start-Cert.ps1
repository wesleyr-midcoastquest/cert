#Requires -Version 7.2
<#
.SYNOPSIS
    CERT control panel: update, choose and run break/fix scenarios against a MidCoast Lab.

.DESCRIPTION
    A menu on the lab's active MGMT. Without an open run: update modules, list
    them, start a scenario (or a surprise one), test the snapshot round trip,
    manage snapshot sets and look at past runs. With a run open: hand over,
    start the clock, record milestones, check the repair, revert.

    Run it from the account you use for the lab pipeline (your -a account),
    in PowerShell 7. It asks for the lab vault's master password when needed.

.PARAMETER ConfigPath
    A cert.config.yaml other than the one next to this script.

.EXAMPLE
    ./Start-Cert.ps1
#>
[CmdletBinding()]
param([string] $ConfigPath)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'src/Cert/Cert.psm1') -Force -DisableNameChecking

function Read-Choice([string] $Prompt) { (Read-Host $Prompt).Trim() }

function Confirm-Cert([string] $Question) {
    (Read-Host "$Question [y/N]").Trim() -match '^(y|yes)$'
}

function Show-Header($Config, $Lab, $Run) {
    Clear-Host
    Write-Host "CERT $(Get-CertVersion): break/fix scenarios" -ForegroundColor Cyan
    Write-Host "Lab:  $($Lab.Site), $($Lab.Release) (compatibility $($Lab.Version)); $(@(Get-CertActiveInstances -Lab $Lab).Count) active machines"
    $a = Get-CertAssessor -Config $Config -Lab $Lab
    $where = if (-not $a) { 'nowhere (no active MGMT in the ledger)' } elseif ($a.IsMgmt) { "MGMT, $($a.Name) ($($a.Address))$(if ($a.Fallback) { "; no active $($Config.assessor.role)" })" } else { "$($a.Name) ($($a.Address))" }
    Write-Host "Fixer works on: $where"
    if ($Run) {
        $what = if ($Run.blind) { '(hidden: blind run)' } else { "$($Run.module.name) [$($Run.module.id) $($Run.module.version)]" }
        Write-Host "Open run: $($Run.id), $what, $($Run.state)" -ForegroundColor Yellow
        $h = Get-CertRunEventTime -Run $Run -Event 'handed over'
        if ($h -and $Run.state -eq 'InProgress') { Write-Host "Clock: $(Format-CertDuration ((Get-Date).ToUniversalTime() - $h)) since handover" }
    }
    Write-Host ''
}

function Select-CertModule($Modules, [string] $Prompt = 'Module number') {
    $valid = @($Modules | Where-Object Valid)
    if (-not $valid) { Write-Warning 'No valid modules. Update modules, or see List for problems.'; return $null }
    $i = 1
    foreach ($m in $valid) { Write-Host ('  {0,2}. {1,-28} {2} (difficulty {3}) {4}' -f $i++, $m.Id, $m.Version, $m.Difficulty, $m.Summary) }
    $n = Read-Choice $Prompt
    if ($n -match '^\d+$' -and [int] $n -ge 1 -and [int] $n -le $valid.Count) { return $valid[[int] $n - 1] }
    $null
}

function Show-Handover($Config, $Lab, $Run, $Module) {
    Write-Host '── Tell the fixer ──────────────────────────────────────────' -ForegroundColor Cyan
    $b = Join-Path $Module.Path $Module.Manifest.engagement.briefing
    Get-Content -Path $b | ForEach-Object { Write-Host "  $_" }
    Write-Host ''
    if ($Run.assessor) { Write-Host "  Work from: $($Run.assessor.name) ($($Run.assessor.address)), by Remote Desktop" }
    if ($Run.assessor.is_mgmt) {
        Write-Host '  Note:      this is the lab''s management server. Its own settings, the'
        Write-Host '             C:\MidCoastLab folder and the pipeline are out of scope: leave them as they are.'
    }
    if ($Run.engagement.account) {
        Write-Host "  Account:   $($Run.engagement.account)  (UPN $($Run.engagement.upn))"
        Write-Host "  Password:  $($Run.engagement.password)"
        Write-Host "  Access:    $($Run.engagement.access)"
    } else { Write-Host '  Account:   none (the scenario hands over no account)' }
    Write-Host '────────────────────────────────────────────────────────────' -ForegroundColor Cyan
}

function Invoke-UpdateMenu($Config) {
    $ups = @(Get-CertUpdates -Config $Config)
    $any = $false
    foreach ($u in $ups) {
        Write-Host "$($u.Source): $($u.State)$(if ($u.Url) { " ($($u.Url) $($u.Ref))" })$(if ($u.Error) { " -- $($u.Error)" })"
        foreach ($c in $u.Commits) { Write-Host "    $c" }
        foreach ($c in $u.Changes) { Write-Host ("    {0,-8} {1} {2}" -f $c.Change, $c.Id, $(if ($c.Change -eq 'updated') { "$($c.From) -> $($c.To)" } elseif ($c.To) { $c.To } else { $c.From })) }
        if ($u.State -in 'behind', 'not cloned') { $any = $true }
    }
    if (-not $any) { Write-Host 'Everything is current.'; return $false }
    Write-Host ''
    Write-Host 'Modules run as a domain administrator in the lab. Take only sources you trust, and read what changed.' -ForegroundColor Yellow
    $changedSelf = $false
    foreach ($u in $ups | Where-Object { $_.State -in 'behind', 'not cloned' }) {
        if (Confirm-Cert "Take $($u.Source)?") { Write-Host (Install-CertUpdate -Update $u); if ($u.Source -eq 'cert') { $changedSelf = $true } }
    }
    $changedSelf
}

function Invoke-SnapshotMenu($Config, $Lab) {
    $sets = @(Get-CertSnapshotSets -Lab $Lab)
    if (-not $sets) { Write-Host 'No CERT snapshot sets.'; return }
    $runIds = @(Get-CertRuns -Config $Config | ForEach-Object id)
    $i = 1
    foreach ($s in $sets) {
        $match = if ($s.LedgerHash -and $Lab.LedgerHash.StartsWith($s.LedgerHash)) { 'matches the ledger' } else { 'ledger has changed since' }
        Write-Host ('  {0,2}. {1}  {2:yyyy-MM-dd HH:mm}Z  {3} VM(s){4}  {5}{6}' -f $i++, $s.Name, $s.Time, $s.Count, $(if ($s.Ram) { ' +RAM' } else { '' }), $match, $(if ($runIds -contains $s.Name) { '' } else { '  (no run record)' }))
    }
    $n = Read-Choice 'Number to remove (Enter: back)'
    if ($n -match '^\d+$' -and [int] $n -ge 1 -and [int] $n -le $sets.Count) {
        $s = $sets[[int] $n - 1]
        if (Confirm-Cert "Delete snapshot $($s.Name) from $($s.Count) VM(s)?") { Write-Host (Remove-CertSnapshotSet -Config $Config -Lab $Lab -Name $s.Name -Confirm:$false) }
    }
}

function Invoke-RunMenu($Config, $Lab, $Run, $Modules) {
    $module = @($Modules | Where-Object { $_.Key -eq $Run.module.key })[0]
    if (-not $module) { Write-Warning "Module $($Run.module.key) is no longer in the catalog; only Revert and Report are available." }
    if ($Run.state -eq 'BreakFailed') { Write-Warning "The break failed (8 writes the report with the reason). Revert the run (9), then start it again." }
    Write-Host '  1. Show the handover (briefing, account)'
    Write-Host '  2. Start the clock (handed over to the fixer)'
    Write-Host '  3. Check the break took'
    Write-Host '  4. Record: cause identified'
    Write-Host '  5. Add a note'
    Write-Host '  6. Check the repair'
    Write-Host '  7. Show the reference solution'
    Write-Host '  8. Write the report'
    Write-Host '  9. Revert the lab and end the run'
    Write-Host '  R. Reload    Q. Quit (the run stays open)'
    switch (Read-Choice 'Choice') {
        '1' { if ($Run.state -eq 'BreakFailed') { Write-Warning 'Nothing to hand over: the break failed.' } elseif ($module) { Show-Handover $Config $Lab $Run $module } }
        '2' { Start-CertClock -Config $Config -Run $Run -Fixer (Read-Host 'Fixer (name, optional)') }
        '3' { if ($module) { if (Test-CertBreak -Config $Config -Lab $Lab -Run $Run -Module $module) { Write-Host 'The break took.' } } }
        '4' { Add-CertRunNote -Config $Config -Run $Run -CauseIdentified -Text (Read-Host 'What the fixer identified') }
        '5' { $t = Read-Host 'Note'; if ($t) { $Run.notes = @($Run.notes) + "$((Get-Date).ToUniversalTime().ToString('HH:mm'))Z $t"; Add-CertRunNote -Config $Config -Run $Run -Text $t } }
        '6' {
            if ($module) {
                $r = Test-CertRepair -Config $Config -Lab $Lab -Run $Run -Module $module
                foreach ($x in @($r.Results | Where-Object { -not $_.passed })) { Write-Host ('  {0,-9} {1,-22} {2,-14} {3}' -f $x.severity, $x.id, $x.on, $x.detail) }
                Write-Host $(if ($r.Passed) { 'Repair check PASSED.' } else { 'Repair check failed (the list above; Critical and High block).' })
            }
        }
        '7' { if ($module -and (Confirm-Cert 'Show the reference solution? (not in front of the fixer)')) { Get-Content (Join-Path $module.Path $module.Manifest.solution) | Write-Host } }
        '8' { Write-Host "Report: $(Write-CertReport -Config $Config -Run $Run)" }
        '9' {
            $keep = -not (Confirm-Cert 'Also delete the snapshot set afterwards? (No keeps it, to run from the same point again)')
            if (Confirm-Cert "Revert $(@($Run.set).Count) VM(s) to $($Run.snapshot.name)? Everything since the snapshot is lost") {
                $null = Restore-CertRun -Config $Config -Lab $Lab -Run $Run -RemoveSnapshot:(-not $keep)
                Write-Host "Reverted. Report: $(Write-CertReport -Config $Config -Run $Run)"
            }
        }
        'r' { return 'reload' }
        'q' { return 'quit' }
    }
    $null
}

function Invoke-MainMenu($Config, $Lab, $Modules) {
    Write-Host '  1. Update modules (check every source for new or changed modules)'
    Write-Host "  2. List modules ($(@($Modules | Where-Object Valid).Count) valid, $(@($Modules | Where-Object { -not $_.Valid }).Count) with problems)"
    Write-Host '  3. Start a scenario'
    Write-Host '  4. Start a surprise scenario (random module, details hidden)'
    Write-Host '  5. Snapshot test (snapshot and revert, nothing broken)'
    Write-Host '  6. Snapshot sets'
    Write-Host '  7. Past runs'
    Write-Host '  8. Re-sync SYSVOL (authoritative, from the PDC emulator)'
    Write-Host '  R. Reload    Q. Quit'
    switch (Read-Choice 'Choice') {
        '1' { if (Invoke-UpdateMenu $Config) { return 'reimport' } }
        '2' {
            foreach ($m in $Modules) {
                Write-Host ('  {0,-34} {1,-7} {2,-15} d{3}  {4}' -f $m.Key, $m.Version, $m.Category, $m.Difficulty, $m.Summary)
                foreach ($p in $m.Problems) { Write-Host "      problem: $p" -ForegroundColor Red }
            }
        }
        '3' {
            $m = Select-CertModule $Modules
            if ($m) {
                Write-Host ''; Write-Host "$($m.Name): $($m.Summary)"
                Write-Host "Destructive: $($m.Manifest.destructive). Fixer access: $($m.Manifest.engagement.access)."
                if (Confirm-Cert 'Snapshot the lab and break it?') { $null = Start-CertRun -Config $Config -Lab $Lab -Module $m; return 'reload' }
            }
        }
        '4' {
            $max = Read-Choice 'Highest difficulty (1-5, Enter: any)'
            $pool = @($Modules | Where-Object { $_.Valid -and (-not ($max -match '^[1-5]$') -or $_.Difficulty -le [int] $max) })
            if (-not $pool) { Write-Warning 'No module fits.' }
            elseif (Confirm-Cert "Pick one of $($pool.Count) modules at random, snapshot the lab and break it?") {
                $null = Start-CertRun -Config $Config -Lab $Lab -Module ($pool | Get-Random) -Blind; return 'reload'
            }
        }
        '5' { if (Confirm-Cert 'Snapshot every lab VM except MGMT, then roll them back?') { Write-Host (Test-CertSnapshotRoundTrip -Config $Config -Lab $Lab) } }
        '6' { Invoke-SnapshotMenu $Config $Lab }
        '7' {
            $runs = @(Get-CertRuns -Config $Config)
            if (-not $runs) { Write-Host 'No runs yet.' }
            $i = 1
            foreach ($r in $runs) { $s = Get-CertRunSummary -Run $r; Write-Host ('  {0,2}. {1}  {2,-28} {3,-10} repair {4}' -f $i++, $r.id, $r.module.id, $r.state, $(if ($s.TimeToRepair) { $s.TimeToRepair } else { '-' })) }
            $n = Read-Choice 'Number for its report (Enter: back)'
            if ($n -match '^\d+$' -and [int] $n -ge 1 -and [int] $n -le $runs.Count) { Get-Content (Write-CertReport -Config $Config -Run $runs[[int] $n - 1]) | Write-Host }
        }
        '8' { if (Confirm-Cert 'Stop DFS Replication on every DC and re-sync SYSVOL from the PDC emulator?') { Write-Host (Repair-CertSysvol -Lab $Lab) } }
        'r' { return 'reload' }
        'q' { return 'quit' }
    }
    $null
}

# ── Loop ──────────────────────────────────────────────────────────────────
$config = if ($ConfigPath) { Get-CertConfig -Path $ConfigPath } else { Get-CertConfig }
while ($true) {
    $lab = Get-CertLab -Config $config
    $compat = Test-CertLabCompatibility -Lab $lab
    if (-not $compat.Ok) { throw $compat.Message }
    $modules = @(Get-CertModules -Config $config -LabRoot $lab.Root)
    $run = Get-CertActiveRun -Config $config
    Show-Header $config $lab $run
    try {
        $next = if ($run) { Invoke-RunMenu $config $lab $run $modules } else { Invoke-MainMenu $config $lab $modules }
    } catch {
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
        $next = $null
    }
    if ($next -eq 'quit') { break }
    if ($next -eq 'reimport') {
        Write-Host 'CERT itself was updated; restart Start-Cert.ps1 to load the new version.' -ForegroundColor Yellow
        break
    }
    if ($next -ne 'reload') { Read-Host 'Enter to continue' | Out-Null }
}
