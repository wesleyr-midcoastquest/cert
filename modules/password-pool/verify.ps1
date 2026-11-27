<#
.SYNOPSIS
    password-pool: the read-back. Reads every pool account from the PDC,
    writes password-pool.csv to the run folder (the answer key), and compares
    each state's planned and actual counts.
.DESCRIPTION
    A fixture's verify should pass. A check that doesn't is a warning
    (Medium): the pool isn't quite what was planned, and the CSV says how.
    Re-read (menu 3) rewrites the CSV, for example after the expired users'
    passwords have aged out.
#>
param([Parameter(Mandatory)] $Context)

$state = Get-CertModuleState -Context $Context
if (-not $state) { New-CertCheck -Name 'module-state' -Passed $false -Severity Medium -Detail 'No record of what the build planned.'; return }
$dc = $Context.Targets.dc

$rows = Invoke-CertTarget -Context $Context -Instance $dc -ArgumentList $state.ou -ScriptBlock {
    param($OuDn)
    $ErrorActionPreference = 'Stop'
    Import-Module ActiveDirectory
    $pdc = (Get-ADDomain).PDCEmulator
    $props = 'UserPrincipalName', 'DisplayName', 'Enabled', 'LockedOut', 'PasswordExpired', 'PasswordNeverExpires', 'CannotChangePassword',
             'pwdLastSet', 'msDS-UserPasswordExpiryTimeComputed', 'msDS-ResultantPSO', 'lastLogon', 'LastLogonDate', 'PasswordLastSet'
    function Iso($d) { if ($d) { ([datetime] $d).ToUniversalTime().ToString('o') } else { $null } }
    foreach ($u in @(Get-ADUser -SearchBase $OuDn -SearchScope OneLevel -Filter * -Properties $props -Server $pdc)) {
        $raw = [long] $u.'msDS-UserPasswordExpiryTimeComputed'
        $ll = [long] $u.lastLogon
        [pscustomobject]@{
            Sam = $u.SamAccountName; Upn = $u.UserPrincipalName; DisplayName = $u.DisplayName; Enabled = [bool] $u.Enabled
            LockedOut = [bool] $u.LockedOut; PasswordExpired = [bool] $u.PasswordExpired; PasswordNeverExpires = [bool] $u.PasswordNeverExpires
            CannotChangePassword = [bool] $u.CannotChangePassword; MustChange = ([long] $u.pwdLastSet -eq 0)
            ExpiryRaw = $raw; Expiry = if ($raw -gt 0 -and $raw -ne [long]::MaxValue) { [DateTime]::FromFileTimeUtc($raw).ToString('o') } else { $null }
            ResultantPso = if ($u.'msDS-ResultantPSO') { (($u.'msDS-ResultantPSO' -split ',')[0] -replace '^CN=', '') } else { '' }
            LastLogon = if ($ll -gt 0) { [DateTime]::FromFileTimeUtc($ll).ToString('o') } else { $null }
            LastLogonDate = Iso $u.LastLogonDate
            PasswordLastSet = Iso $u.PasswordLastSet
        }
    }
}
$rows = @($rows | Where-Object { $_ -and $_.PSObject.Properties['Sam'] })
$now = (Get-Date).ToUniversalTime()
function Format-PoolTime($Iso) { if ($Iso) { ([datetime]::Parse($Iso).ToUniversalTime()).ToString('yyyy-MM-dd HH:mm:ss') + 'Z' } else { '' } }

$planBySam = @{}
foreach ($p in @($state.users)) { $planBySam[$p.sam] = $p }
$actual = @{}
foreach ($a in $rows) { $actual[$a.Sam] = $a }

# The answer key. No passwords: they were never kept.
$csv = foreach ($a in $rows | Sort-Object Sam) {
    $p = $planBySam[$a.Sam]
    [pscustomobject][ordered]@{
        SamAccountName        = $a.Sam
        UserPrincipalName     = $a.Upn
        DisplayName           = $a.DisplayName
        PlannedState          = if ($p) { $p.state } else { '(not in this plan)' }
        PlannedLockedOut      = if ($p) { [bool] $p.locked } else { '' }
        PlannedCannotChange   = if ($p) { [bool] $p.cannot_change } else { '' }
        PasswordExpires       = if ($a.MustChange) { 'Must change now' } elseif ($a.ExpiryRaw -eq [long]::MaxValue -or $a.PasswordNeverExpires) { 'Never' } else { Format-PoolTime $a.Expiry }
        PasswordExpired       = $a.PasswordExpired
        ChangePasswordAtLogon = $a.MustChange
        PasswordNeverExpires  = $a.PasswordNeverExpires
        CannotChangePassword  = $a.CannotChangePassword
        LockedOut             = $a.LockedOut
        Enabled               = $a.Enabled
        ResultantPSO          = $a.ResultantPso
        LastLogon             = if ($a.LastLogon) { "real logon $(Format-PoolTime $a.LastLogon)" } else { 'never' }
        LastLogonDate         = if ($a.LastLogonDate) { "real logon $(Format-PoolTime $a.LastLogonDate)" } else { 'never' }
        PasswordLastSet       = if ($a.MustChange) { 'not set (must change)' } else { "real $(Format-PoolTime $a.PasswordLastSet)" }
    }
}
$path = Join-Path (Get-CertRunsPath -Config $Context.Config) "$($Context.Run.id)/password-pool.csv"
@($csv) | Export-Csv -Path $path -Encoding utf8NoBOM

# Planned vs actual, per state.
function Test-PoolState([string] $Name, [string[]] $Planned, [scriptblock] $Is, [string] $Note) {
    $have = @($rows | Where-Object $Is | ForEach-Object Sam)
    $missing = @($Planned | Where-Object { $have -notcontains $_ })
    $extra = @($have | Where-Object { $Planned -notcontains $_ })
    $d = "planned $($Planned.Count), actual $($have.Count)"
    if ($missing) { $d += "; not as planned: $(@($missing | Select-Object -First 8) -join ', ')$(if ($missing.Count -gt 8) { ", +$($missing.Count - 8) more" })" }
    if ($extra) { $d += "; unexpected: $(@($extra | Select-Object -First 8) -join ', ')$(if ($extra.Count -gt 8) { ", +$($extra.Count - 8) more" })" }
    if ($Note) { $d += "; $Note" }
    New-CertCheck -On $dc.name -Name $Name -Severity Medium -Passed (-not $missing -and -not $extra) -Detail $d
}
$plan = @($state.users)
$sams = { param($f) @($plan | Where-Object $f | ForEach-Object { $_.sam }) }

$missingUsers = @($plan | Where-Object { -not $actual.ContainsKey($_.sam) } | ForEach-Object sam)
New-CertCheck -On $dc.name -Name 'users' -Severity Medium -Passed ($missingUsers.Count -eq 0 -and $rows.Count -eq $plan.Count) `
    -Detail "planned $($plan.Count), in the pool OU $($rows.Count)$(if ($missingUsers) { "; missing: $(@($missingUsers | Select-Object -First 8) -join ', ')" })"

# Expired: by age, not the reset flag. If the PSO's smallest age is long,
# they haven't aged out yet: that's as planned, and the detail says when.
$plannedExpired = & $sams { $_.state -eq 'Expired' }
$expiredPso = "$($state.pso_prefix)-Expired"
$notYet = @($rows | Where-Object { $plannedExpired -contains $_.Sam -and -not $_.PasswordExpired -and -not $_.MustChange -and $_.ResultantPso -eq $expiredPso -and $_.Expiry -and [datetime]::Parse($_.Expiry).ToUniversalTime() -gt $now })

Test-PoolState 'normal' (& $sams { $_.state -eq 'Normal' }) { -not $_.MustChange -and -not $_.PasswordExpired -and -not $_.PasswordNeverExpires -and $_.Expiry -and [datetime]::Parse($_.Expiry).ToUniversalTime() -gt $now -and @($notYet.Sam) -notcontains $_.Sam }
Test-PoolState 'must-change' (& $sams { $_.state -eq 'MustChange' }) { $_.MustChange }

if ($plannedExpired.Count) {
    if ($notYet) {
        $when = ($notYet | ForEach-Object { [datetime]::Parse($_.Expiry).ToUniversalTime() } | Sort-Object)[-1]
        $note = "$($notYet.Count) not aged out yet: PSO max age $($state.expired_max_age); expires at $($when.ToString('yyyy-MM-dd HH:mm'))Z; re-read after then"
        Test-PoolState 'expired' $plannedExpired { (-not $_.MustChange) -and ($_.PasswordExpired -or (@($notYet.Sam) -contains $_.Sam)) } $note
    } else {
        Test-PoolState 'expired' $plannedExpired { $_.PasswordExpired -and -not $_.MustChange } "PSO max age $($state.expired_max_age)"
    }
} else { Test-PoolState 'expired' @() { $_.PasswordExpired -and -not $_.MustChange } }

if ([int] $state.counts.NeverExpires -or @($rows | Where-Object PasswordNeverExpires).Count) { Test-PoolState 'never-expires' (& $sams { $_.state -eq 'NeverExpires' }) { $_.PasswordNeverExpires } }
Test-PoolState 'locked-out' (& $sams { $_.locked }) { $_.LockedOut } $(if ($state.lock_forever) { 'locked until an admin unlocks' } else { 'unlocks on its own after 99999 minutes' })
if ([int] $state.counts.CannotChange -or @($rows | Where-Object CannotChangePassword).Count) { Test-PoolState 'cannot-change' (& $sams { $_.cannot_change }) { $_.CannotChangePassword } }

# Each user's resultant PSO is its own tier's.
$wrongPso = @($rows | Where-Object { $planBySam[$_.Sam] -and $_.ResultantPso -ne "$($state.pso_prefix)-$($planBySam[$_.Sam].tier)" } | ForEach-Object Sam)
New-CertCheck -On $dc.name -Name 'resultant-pso' -Severity Medium -Passed ($wrongPso.Count -eq 0) `
    -Detail $(if ($wrongPso) { "not their tier's PSO: $(@($wrongPso | Select-Object -First 8) -join ', ')" } else { 'every user gets its own tier''s PSO' })

$logons = @($rows | Where-Object LastLogon).Count
New-CertCheck -On $dc.name -Name 'report' -Severity Low -Passed $true -Detail "$(@($csv).Count) users written to $path; $logons with a real logon, $($rows.Count - $logons) never signed in"
