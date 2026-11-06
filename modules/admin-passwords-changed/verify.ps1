<#
.SYNOPSIS
    admin-passwords-changed: has every changed account been given a new
    password and been unlocked, and is the intruder's account out of every
    privileged group (or disabled)?
#>
param([Parameter(Mandatory)] $Context)

$state = Get-CertModuleState -Context $Context
if (-not $state) { New-CertCheck -Name 'module-state' -Passed $false -Detail 'No record of what the break changed.'; return }
$eng = ($Context.Run.engagement.account -split '\\')[-1]

$r = Invoke-CertTarget -Context $Context -Instance $Context.Targets.dc -ArgumentList (, @($state.changed)), $state.rogue, $state.at, (, @($state.domain_admins_before)), $eng -ScriptBlock {
    param($Changed, $Rogue, $At, $Before, $Eng)
    Import-Module ActiveDirectory
    $since = [datetime]::Parse($At).ToUniversalTime().AddSeconds(5)
    $accounts = foreach ($a in $Changed) {
        $u = Get-ADUser -Identity $a -Properties pwdLastSet, LockedOut, Enabled
        [pscustomobject]@{ Name = $a; Reset = ([datetime]::FromFileTimeUtc($u.pwdLastSet) -gt $since); Enabled = $u.Enabled; Locked = $u.LockedOut }
    }
    $ru = Get-ADUser -Filter "SamAccountName -eq '$Rogue'" -Properties MemberOf, Enabled
    $privileged = 'Domain Admins', 'Enterprise Admins', 'Schema Admins', 'Administrators', 'Account Operators', 'Backup Operators'
    $rogueIn = @()
    foreach ($g in $privileged) {
        if ($ru -and @(Get-ADGroupMember -Identity $g -Recursive -ErrorAction SilentlyContinue | ForEach-Object SamAccountName) -contains $Rogue) { $rogueIn += $g }
    }
    $now = @(Get-ADGroupMember -Identity 'Domain Admins' -Recursive | ForEach-Object SamAccountName)
    $extra = @($now | Where-Object { $Before -notcontains $_ -and $_ -ne $Eng -and $_ -ne $Rogue })
    [pscustomobject]@{
        Accounts = @($accounts); RogueExists = [bool] $ru; RogueEnabled = [bool] ($ru -and $ru.Enabled); RogueIn = $rogueIn; Extra = $extra
    }
}
foreach ($a in @($r.Accounts)) {
    New-CertCheck -On $Context.Targets.dc.name -Name "access-restored:$($a.Name)" -Passed ($a.Reset -and $a.Enabled -and -not $a.Locked) `
        -Detail "password reset since the incident: $($a.Reset); enabled: $($a.Enabled); locked out: $($a.Locked)"
}
$rogueOk = (-not $r.RogueExists) -or (-not $r.RogueEnabled -and $r.RogueIn.Count -eq 0)
New-CertCheck -On $Context.Targets.dc.name -Name 'intruder-account-removed' -Passed $rogueOk `
    -Detail $(if (-not $r.RogueExists) { "$($state.rogue) deleted" } else { "$($state.rogue) enabled: $($r.RogueEnabled); in: $(if ($r.RogueIn) { $r.RogueIn -join ', ' } else { 'no privileged group' })" })
New-CertCheck -On $Context.Targets.dc.name -Name 'no-new-domain-admins' -Passed ($r.Extra.Count -eq 0) -Detail $(if ($r.Extra) { "new since the incident: $($r.Extra -join ', ')" } else { 'none' }) -Severity High
