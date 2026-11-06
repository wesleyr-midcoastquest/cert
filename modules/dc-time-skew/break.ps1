<#
.SYNOPSIS
    dc-time-skew: stops a DC syncing time and sets its clock 17 minutes fast.
.DESCRIPTION
    17 minutes is well past Kerberos' 5-minute tolerance, and not a round
    number, so it doesn't look like a time zone mistake. CERT reaches the DC by
    IP address, which uses NTLM, so CERT itself isn't locked out.
#>
param([Parameter(Mandatory)] $Context)

$victim = $Context.Targets.victim
Invoke-CertTarget -Context $Context -Instance $victim -ScriptBlock {
    & w32tm.exe /config /syncfromflags:NO /update | Out-Null
    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters' -Name Type -Value 'NoSync'
    Restart-Service W32Time -Force
    Set-Date -Date (Get-Date).AddMinutes(17) | Out-Null
    "clock now $((Get-Date).ToUniversalTime().ToString('u')), w32time NoSync"
}
