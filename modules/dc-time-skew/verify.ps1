<#
.SYNOPSIS
    dc-time-skew: is the DC's clock within a few seconds of the PDC emulator,
    syncing from the domain hierarchy, and replicating again?
#>
param([Parameter(Mandatory)] $Context)

$victim = $Context.Targets.victim
$pdc = Get-CertPdcInstance -Lab $Context.Lab
$domain = $Context.Lab.Inventory.identity.active_directory.domain

$r = Invoke-CertTarget -Context $Context -Instance $victim -ArgumentList "$($pdc.name).$domain" -ScriptBlock {
    param($Pdc)
    $type = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters').Type
    $source = (& w32tm.exe /query /source 2>&1 | Out-String).Trim()
    $line = @(& w32tm.exe /stripchart /computer:$Pdc /samples:1 /dataonly 2>&1 | Where-Object { $_ -match ',\s*[+-]?\d' })[-1]
    $offset = if ($line -match ',\s*([+-]?\d+(\.\d+)?)s') { [double] $Matches[1] } else { $null }
    $fail = @(Get-ADReplicationFailure -Target $env:COMPUTERNAME -Scope Server -ErrorAction SilentlyContinue | Where-Object { $_.FailureCount -gt 0 })
    [pscustomobject]@{ Type = $type; Source = $source; Offset = $offset; ReplFailures = $fail.Count }
}
New-CertCheck -On $victim.name -Name 'clock-offset' -Passed ($null -ne $r.Offset -and [math]::Abs($r.Offset) -lt 5) -Detail "offset from $($pdc.name): $(if ($null -ne $r.Offset) { "$($r.Offset) s" } else { 'unknown (stripchart failed)' })"
New-CertCheck -On $victim.name -Name 'w32time-domain-hierarchy' -Passed ($r.Type -eq 'NT5DS') -Detail "Type $($r.Type); source '$($r.Source)'"
New-CertCheck -On $victim.name -Name 'replicating' -Passed ($r.ReplFailures -eq 0) -Detail "partners with failures: $($r.ReplFailures)"
