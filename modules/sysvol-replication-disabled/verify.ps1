<#
.SYNOPSIS
    sysvol-replication-disabled: is SYSVOL replicating on the victim again,
    and does a new file written on the PDC arrive on it?
#>
param([Parameter(Mandatory)] $Context)

$victim = $Context.Targets.victim
$source = $Context.Targets.source

$st = Invoke-CertTarget -Context $Context -Instance $victim -ScriptBlock {
    Import-Module ActiveDirectory
    $dn = "CN=SYSVOL Subscription,CN=Domain System Volume,CN=DFSR-LocalSettings,$((Get-ADComputer $env:COMPUTERNAME).DistinguishedName)"
    $enabled = (Get-ADObject -Identity $dn -Properties 'msDFSR-Enabled' -Server localhost).'msDFSR-Enabled'
    $rf = Get-CimInstance -Namespace 'root\microsoftdfs' -ClassName DfsrReplicatedFolderInfo -Filter "ReplicatedFolderName='SYSVOL Share'" -ErrorAction SilentlyContinue
    $ready = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon\Parameters' -ErrorAction SilentlyContinue).SysvolReady
    [pscustomobject]@{ Enabled = [bool] $enabled; State = if ($rf) { [int] $rf.State } else { $null }; Ready = $ready }
}
New-CertCheck -On $victim.name -Name 'subscription-enabled' -Passed $st.Enabled -Detail "msDFSR-Enabled $($st.Enabled)"
New-CertCheck -On $victim.name -Name 'dfsr-state-normal' -Passed ($st.State -eq 4) -Detail "DFSR state $($st.State) (4 = Normal)"
New-CertCheck -On $victim.name -Name 'sysvol-ready' -Passed ($st.Ready -eq 1) -Detail "SysvolReady $($st.Ready)"

# End to end: write on the PDC, expect it on the victim within 3 minutes.
$name = "cert-canary-$((Get-Date).ToUniversalTime().ToString('HHmmss')).txt"
Invoke-CertTarget -Context $Context -Instance $source -ArgumentList $name -ScriptBlock {
    param($Name)
    Set-Content -Path "C:\Windows\SYSVOL\domain\scripts\$Name" -Value 'CERT replication check' -Encoding ASCII
} | Out-Null
$arrived = Invoke-CertTarget -Context $Context -Instance $victim -ArgumentList $name -TimeoutSeconds 60 -ScriptBlock {
    param($Name)
    & dfsrdiag.exe pollad 2>&1 | Out-Null
    $deadline = (Get-Date).AddMinutes(3)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path "C:\Windows\SYSVOL\domain\scripts\$Name") { return $true }
        Start-Sleep -Seconds 10
    }
    $false
}
New-CertCheck -On $victim.name -Name 'sysvol-change-arrives' -Passed ([bool] $arrived) -Detail $(if ($arrived) { "$name arrived from $($source.name)" } else { "$name did not arrive from $($source.name) within 3 minutes" })
Invoke-CertTarget -Context $Context -Instance $source -ArgumentList $name -ScriptBlock {
    param($Name)
    Remove-Item "C:\Windows\SYSVOL\domain\scripts\$Name" -Force -ErrorAction SilentlyContinue
} | Out-Null
