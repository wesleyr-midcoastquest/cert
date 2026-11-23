# Cert.Report: the run's report, report.md next to run.json.

function Get-CertRunSummary {
    # The numbers a report leads with: time to cause, time to repair, checks.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Run)
    $handed = Get-CertRunEventTime -Run $Run -Event 'handed over'
    $cause  = Get-CertRunEventTime -Run $Run -Event 'cause identified'
    $fixed  = Get-CertRunEventTime -Run $Run -Event 'repaired'
    [pscustomobject]@{
        HandedOver    = $handed
        TimeToCause   = if ($handed -and $cause) { Format-CertDuration ($cause - $handed) } else { $null }
        TimeToRepair  = if ($handed -and $fixed) { Format-CertDuration ($fixed - $handed) } else { $null }
        CheckAttempts = @($Run.checks).Count
        Repaired      = [bool] $fixed
    }
}

function Write-CertReport {
    # Writes report.md for a run and returns its path. Includes the reference
    # solution only after the run is over (or with -IncludeSolution).
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Config, [Parameter(Mandatory)] $Run, [switch] $IncludeSolution)
    $s = Get-CertRunSummary -Run $Run
    $L = [Collections.Generic.List[string]]::new()
    $L.Add("# CERT run $($Run.id): $($Run.module.name)")
    $L.Add('')
    $L.Add("| | |")
    $L.Add("|---|---|")
    $L.Add("| Module | ``$($Run.module.id)`` $($Run.module.version) ($($Run.module.source)$(if ($Run.module.commit) { ", $($Run.module.commit)" })) |")
    $L.Add("| Lab | $($Run.lab.site), $($Run.lab.release) (compatibility $($Run.lab.version)) |")
    $L.Add("| CERT | $($Run.cert) |")
    $L.Add("| Mode | $(if ($Run.blind) { 'blind (the fixer was not told the scenario)' } else { 'open' }) |")
    $L.Add("| Run by | $($Run.owner) |")
    $L.Add("| State | $($Run.state) |")
    $L.Add("| Time to cause | $(if ($s.TimeToCause) { $s.TimeToCause } else { 'not recorded' }) |")
    $L.Add("| Time to repair | $(if ($s.TimeToRepair) { $s.TimeToRepair } elseif ($s.HandedOver) { 'not repaired' } else { 'not handed over' }) |")
    $L.Add("| Repair checks | $($s.CheckAttempts) |")
    $L.Add('')
    $L.Add('## Lab')
    $L.Add('')
    $L.Add("Snapshot set ``$($Run.snapshot.name)``$(if ($Run.snapshot.ram) { ' (with RAM)' }): $(@($Run.set | ForEach-Object { "$($_.name) ($($_.role), $($_.vmid))" }) -join ', ').")
    if ($Run.assessor) { $L.Add("The fixer worked on $($Run.assessor.name) ($($Run.assessor.address))$(if ($Run.assessor.is_mgmt) { ', the lab''s MGMT' }).") }
    if ($Run.engagement -and $Run.engagement.account) { $L.Add("Engagement account: ``$($Run.engagement.account)`` ($($Run.engagement.access)).") }
    $L.Add('')
    $L.Add('Targets: ' + (@($Run.targets.PSObject.Properties | ForEach-Object { "$($_.Name) = $(@($_.Value) -join ', ')" }) -join '; ') + '.')
    $L.Add('')
    $L.Add('## Did the break take?')
    $L.Add('')
    foreach ($e in @($Run.expected)) { $L.Add("- $(if ($e.seen) { '[x]' } else { '[ ]' }) ``$($e.id)``$(if ($e.seen) { " on $(@($e.on) -join ', ')" } else { ' not seen' })") }
    if (-not @($Run.expected).Count) { $L.Add('Not checked.') }
    $L.Add('')
    $L.Add('## Timeline (UTC)')
    $L.Add('')
    foreach ($e in @($Run.timeline)) {
        $t = ([datetime]::Parse($e.at).ToUniversalTime()).ToString('yyyy-MM-dd HH:mm:ss')
        $L.Add("- $t **$($e.event)**$(if ($e.detail) { ': ' + $e.detail })")
    }
    $last = @($Run.checks)[-1]
    if ($last) {
        $L.Add('')
        $L.Add("## Last repair check ($(if ($last.passed) { 'passed' } else { 'failed' }))")
        $L.Add('')
        $L.Add('| On | Check | Result | Detail |')
        $L.Add('|---|---|---|---|')
        foreach ($r in @($last.results | Sort-Object passed, on, id)) {
            $L.Add("| $($r.on) | $($r.id) | $(if ($r.passed) { 'pass' } else { $r.severity }) | $(([string] $r.detail) -replace '\|', '/') |")
        }
    }
    if (@($Run.notes).Count) { $L.Add(''); $L.Add('## Notes'); foreach ($n in $Run.notes) { $L.Add("- $n") } }
    if ($IncludeSolution -or $Run.state -eq 'Reverted') {
        $m = Read-CertYaml -Path (Join-Path $Run.module.path 'module.yaml')
        $sol = Join-Path $Run.module.path $m.solution
        if (Test-Path $sol) { $L.Add(''); $L.Add('## Reference solution'); $L.Add(''); $L.Add((Get-Content -Path $sol -Raw).Trim()) }
    }
    $path = Join-Path (Get-CertRunsPath -Config $Config) "$($Run.id)/report.md"
    Set-Content -Path $path -Value ($L -join "`n") -Encoding utf8NoBOM
    $path
}
