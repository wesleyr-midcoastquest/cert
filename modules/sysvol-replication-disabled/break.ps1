<#
.SYNOPSIS
    sysvol-replication-disabled: sets msDFSR-Enabled to FALSE on one DC's
    SYSVOL subscription, makes DFSR read it, and then changes a GPO on the PDC
    so the two DCs' SYSVOL differ.
#>
param([Parameter(Mandatory)] $Context)

$victim = $Context.Targets.victim
$source = $Context.Targets.source

$out = Invoke-CertTarget -Context $Context -Instance $victim -ScriptBlock {
    Import-Module ActiveDirectory
    $dn = "CN=SYSVOL Subscription,CN=Domain System Volume,CN=DFSR-LocalSettings,$((Get-ADComputer $env:COMPUTERNAME).DistinguishedName)"
    Set-ADObject -Identity $dn -Replace @{ 'msDFSR-Enabled' = $false } -Server localhost
    & dfsrdiag.exe pollad 2>&1 | Out-Null
    "SYSVOL subscription disabled on $env:COMPUTERNAME"
}
# Make the difference visible: a change in SYSVOL that the victim will never get.
$canary = Invoke-CertTarget -Context $Context -Instance $source -ArgumentList $Context.Run.id -ScriptBlock {
    param($RunId)
    $p = "C:\Windows\SYSVOL\domain\scripts\logon-notice.txt"
    Set-Content -Path $p -Value "Updated $((Get-Date).ToUniversalTime().ToString('u')) ($RunId)" -Encoding ASCII
    "\\$env:COMPUTERNAME\NETLOGON\logon-notice.txt changed"
}
Save-CertModuleState -Context $Context -State @{ victim = $victim.name }
@($out, $canary)
