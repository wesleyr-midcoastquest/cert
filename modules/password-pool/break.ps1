<#
.SYNOPSIS
    password-pool: builds a pool of AD users in known password and account
    states, for checking what a reporting tool says about them.
.DESCRIPTION
    Ported from New-LabPasswordPool.ps1. The plan (names, states, tiers) is
    made on MGMT from the seed (pool.ps1); everything else runs on the PDC
    emulator in one call, in this order:
      1. the pool OU (under the lab's standard-users OU), if it's missing
      2. one pool group and one PSO per tier; every PSO has the same lockout
         threshold, so any pool user can be locked
      3. the users, each with a random password the DC makes and keeps in
         memory only; must-change, never-expires and cannot-change flags
      4. group membership for everyone but the expired users
      5. one real logon for the users the plan picked (dates option C)
      6. the expired users into the Expired group: their PSO's tiny maximum
         age ages their password out
      7. bad-password binds until each planned user is locked out
    The Default Domain Policy is never touched. The revert is the cleanup.
#>
param([Parameter(Mandatory)] $Context)

. (Join-Path $Context.ModulePath 'pool.ps1')

$opts = $Context.Options
$seed = if ($null -ne $opts.seed) { [int] $opts.seed } else { [Random]::new().Next(0, [int]::MaxValue) }
$plan = New-PoolPlan -Options $opts -Seed $seed
$inv = $Context.Lab.Inventory
$ouDn = Get-PoolOUPath -Inventory $inv
$upnSuffix = if ($inv.identity.entra.tenant_domain) { [string] $inv.identity.entra.tenant_domain } else { [string] $inv.identity.active_directory.domain }
$settings = @{
    GroupPrefix      = $PoolGroupPrefix
    PsoPrefix        = $PoolPsoPrefix
    UpnSuffix        = $upnSuffix
    LockoutThreshold = 3
    Description      = 'Password pool test user (CERT password-pool)'
    RunId            = [string] $Context.Run.id
}
$users = @($plan.Users | ForEach-Object { [pscustomobject]@{ Sam = $_.Sam; First = $_.First; Last = $_.Last; State = $_.State; Tier = $_.Tier; Locked = $_.Locked; CannotChange = $_.CannotChange; LogOn = $_.LogOn } })
$tiers = @($plan.Tiers)

$r = Invoke-CertTarget -Context $Context -Instance $Context.Targets.dc -ArgumentList $ouDn, $users, $tiers, $settings -ScriptBlock {
    param($OuDn, $Users, $Tiers, $S)
    $ErrorActionPreference = 'Stop'
    Import-Module ActiveDirectory
    $domain = Get-ADDomain
    $pdc = $domain.PDCEmulator
    $warnings = New-Object System.Collections.Generic.List[string]
    function Say([string] $Text) { Write-Host "    $Text" }

    # 1. Pool OU
    $ouName = ($OuDn -split ',', 2)[0] -replace '^OU=', ''
    $parent = ($OuDn -split ',', 2)[1]
    try { $null = Get-ADOrganizationalUnit -Identity $parent -Server $pdc }
    catch { throw "The lab's standard-users OU $parent isn't there, so the pool OU can't be made under it." }
    try { $null = Get-ADOrganizationalUnit -Identity $OuDn -Server $pdc; Say "pool OU $OuDn already there" }
    catch { New-ADOrganizationalUnit -Name $ouName -Path $parent -ProtectedFromAccidentalDeletion $false -Server $pdc; Say "created $OuDn" }

    # 2. Groups and PSOs. Lockout: locked until an admin unlocks, if a PSO
    # takes it (msDS-LockoutDuration 0x8000000000000000, "forever"); if not,
    # the longest the cmdlets accept (99999 minutes, about 69 days).
    $longLock = New-TimeSpan -Minutes 99999
    $window = New-TimeSpan -Minutes 30
    $forever = $null
    $expiredAge = $null
    $groups = @{}
    $i = 0
    foreach ($t in $Tiers) {
        $groupName = "$($S.GroupPrefix)-$($t.Key)"
        $psoName = "$($S.PsoPrefix)-$($t.Key)"
        $group = Get-ADGroup -Filter "Name -eq '$groupName'" -Server $pdc
        if (-not $group) {
            $group = New-ADGroup -Name $groupName -SamAccountName $groupName -GroupScope Global -GroupCategory Security `
                -Path $OuDn -Description "Password pool: PSO $psoName" -Server $pdc -PassThru
        }
        $groups[$t.Key] = $group

        $ages = if ($t.Key -eq 'Expired') {
            # The smallest maximum age a PSO accepts: try the shortest first.
            @((New-TimeSpan -Minutes 1), (New-TimeSpan -Minutes 5), (New-TimeSpan -Hours 1), (New-TimeSpan -Days 1))
        } else { @(New-TimeSpan -Days $t.MaxAgeDays) }
        $pso = Get-ADFineGrainedPasswordPolicy -Filter "Name -eq '$psoName'" -Server $pdc
        $set = $null; $refused = @()
        foreach ($age in $ages) {
            $p = @{
                MaxPasswordAge = $age; MinPasswordAge = [TimeSpan]::Zero; MinPasswordLength = 8; PasswordHistoryCount = 0
                ComplexityEnabled = $true; ReversibleEncryptionEnabled = $false
                LockoutThreshold = $S.LockoutThreshold; LockoutDuration = $longLock; LockoutObservationWindow = $window
            }
            try {
                if ($pso) { Set-ADFineGrainedPasswordPolicy -Identity $pso @p -Server $pdc }
                else { $pso = New-ADFineGrainedPasswordPolicy -Name $psoName -Precedence (900 + $i) @p -ProtectedFromAccidentalDeletion $false -Server $pdc -PassThru }
                $set = $age; break
            } catch { $refused += "$age ($($_.Exception.Message))" }
        }
        if (-not $set) { throw "PSO $psoName refused every maximum age tried: $($refused -join '; ')" }
        if ($t.Key -eq 'Expired') { $expiredAge = [pscustomobject]@{ Used = $set.ToString(); Refused = $refused } }
        if ($null -eq $forever -or $forever) {
            try { Set-ADObject -Identity $pso.DistinguishedName -Replace @{ 'msDS-LockoutDuration' = [long]::MinValue } -Server $pdc; $forever = $true }
            catch { if ($null -eq $forever) { $warnings.Add("A PSO doesn't take 'locked until an admin unlocks' ($($_.Exception.Message)); accounts unlock on their own after 99999 minutes.") }; $forever = $false }
        }
        $applies = @((Get-ADFineGrainedPasswordPolicy -Identity $pso -Server $pdc).AppliesTo)
        if ($applies -notcontains $group.DistinguishedName) { Add-ADFineGrainedPasswordPolicySubject -Identity $pso -Subjects $group -Server $pdc }
        Say "group $groupName -> PSO $psoName (max age $set)"
        $i++
    }

    # 3. Users. A name another account already has (outside the pool) gets a number.
    $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    function New-PoolPassword {
        $sets = 'ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnpqrstuvwxyz', '23456789', '!#%+=?-_'
        $all = -join $sets
        $b = New-Object byte[] 64; $rng.GetBytes($b)
        $chars = @(for ($k = 0; $k -lt 4; $k++) { $sets[$k][$b[$k] % $sets[$k].Length] })
        $chars += @(for ($k = 4; $k -lt 24; $k++) { $all[$b[$k] % $all.Length] })
        -join ($chars | Sort-Object { Get-Random })
    }
    $passwords = @{}
    $poolSams = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($u in @(Get-ADUser -SearchBase $OuDn -SearchScope OneLevel -Filter * -Server $pdc)) { $null = $poolSams.Add($u.SamAccountName) }
    $taken = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($u in $Users) { $null = $taken.Add($u.Sam) }
    $created = 0; $reset = 0; $n = 0
    foreach ($u in $Users) {
        $n++
        if (-not $poolSams.Contains($u.Sam) -and (Get-ADUser -Filter "SamAccountName -eq '$($u.Sam)'" -Server $pdc)) {
            # The first number that's free, or already this pool's (a run
            # again from the same snapshot reuses it).
            $k = 2
            while ($taken.Contains("$($u.Sam)$k") -or (-not $poolSams.Contains("$($u.Sam)$k") -and (Get-ADUser -Filter "SamAccountName -eq '$($u.Sam)$k'" -Server $pdc))) { $k++ }
            $warnings.Add("$($u.Sam) is already used outside the pool; this user is $($u.Sam)$k.")
            $u.Sam = "$($u.Sam)$k"; $null = $taken.Add($u.Sam)
        }
        $pw = New-PoolPassword
        $passwords[$u.Sam] = $pw
        $secure = ConvertTo-SecureString $pw -AsPlainText -Force
        $never = ($u.State -eq 'NeverExpires')
        $must = ($u.State -eq 'MustChange')
        if ($poolSams.Contains($u.Sam)) {
            # Idempotent: an existing pool user is reset to its planned state.
            Set-ADAccountPassword -Identity $u.Sam -Reset -NewPassword $secure -Server $pdc
            Set-ADUser -Identity $u.Sam -Enabled $true -PasswordNeverExpires $never -CannotChangePassword ([bool] $u.CannotChange) `
                -GivenName $u.First -Surname $u.Last -DisplayName "$($u.First) $($u.Last)" -Server $pdc
            Set-ADUser -Identity $u.Sam -ChangePasswordAtLogon $must -Server $pdc
            Unlock-ADAccount -Identity $u.Sam -Server $pdc
            $reset++
        } else {
            New-ADUser -Name $u.Sam -SamAccountName $u.Sam -UserPrincipalName "$($u.Sam)@$($S.UpnSuffix)" `
                -GivenName $u.First -Surname $u.Last -DisplayName "$($u.First) $($u.Last)" `
                -Path $OuDn -AccountPassword $secure -Enabled $true -Description $S.Description `
                -PasswordNeverExpires $never -ChangePasswordAtLogon $must -CannotChangePassword ([bool] $u.CannotChange) -Server $pdc
            $created++
        }
        if ($n % 250 -eq 0) { Say "users: $n of $($Users.Count)" }
    }
    Say "users: $created created, $reset reset"

    # 4. Membership: each user in exactly one pool group. Expired users wait (6).
    function Set-PoolMembers($Key, $Members) {
        $g = $groups[$Key]
        $now = @(Get-ADGroupMember -Identity $g -Server $pdc | ForEach-Object SamAccountName)
        $add = @($Members | Where-Object { $now -notcontains $_ })
        for ($k = 0; $k -lt $add.Count; $k += 500) { Add-ADGroupMember -Identity $g -Members $add[$k..([math]::Min($k + 499, $add.Count - 1))] -Server $pdc }
    }
    $planned = @{}
    foreach ($u in $Users) { $planned[$u.Sam] = $u.Tier }
    foreach ($t in $Tiers) {
        # Pool users this plan puts in another tier leave this group first.
        $out = @(Get-ADGroupMember -Identity $groups[$t.Key] -Server $pdc | ForEach-Object SamAccountName | Where-Object { $planned.ContainsKey($_) -and $planned[$_] -ne $t.Key })
        if ($out) { Remove-ADGroupMember -Identity $groups[$t.Key] -Members $out -Server $pdc -Confirm:$false }
    }
    foreach ($t in $Tiers | Where-Object Key -ne 'Expired') { Set-PoolMembers $t.Key @($Users | Where-Object Tier -eq $t.Key | ForEach-Object Sam) }

    # 5. Real logons (dates option C): a successful bind on the PDC sets
    # lastLogon and, for an account that never had one, lastLogonTimestamp.
    # The bind is a plain .NET LdapConnection, not a DirectoryEntry: Windows
    # PowerShell's ADSI adapter binds again for any member called on a
    # DirectoryEntry, Dispose() included, so a wrong password threw a second
    # time from the finally block and stopped the whole build. A failed bind
    # here is a result with the reason (e.g. "data 52e" bad password, "773"
    # must change, "532" expired), never an error.
    Add-Type -AssemblyName System.DirectoryServices.Protocols
    $netbios = $domain.NetBIOSName
    function Test-PoolBind([string] $Sam, [string] $Password) {
        $c = $null
        try {
            $c = New-Object System.DirectoryServices.Protocols.LdapConnection($pdc)
            $c.AuthType = [System.DirectoryServices.Protocols.AuthType]::Negotiate
            $c.Bind((New-Object System.Net.NetworkCredential($Sam, $Password, $netbios)))
            [pscustomobject]@{ Ok = $true; Reason = $null }
        } catch {
            # PowerShell wraps .NET method errors; find the LdapException inside.
            $e = $_.Exception
            while ($e -and $e.GetType().FullName -ne 'System.DirectoryServices.Protocols.LdapException') { $e = $e.InnerException }
            if ($e) {
                $msg = if ($e.ServerErrorMessage) { $e.ServerErrorMessage } else { $e.Message }
                [pscustomobject]@{ Ok = $false; Reason = ("$($e.ErrorCode) $msg").Trim() }
            }
            else { [pscustomobject]@{ Ok = $false; Reason = $_.Exception.Message } }
        } finally { if ($null -ne $c) { try { $c.Dispose() } catch { } } }
    }
    $logons = 0
    foreach ($u in @($Users | Where-Object LogOn)) {
        $b = Test-PoolBind $u.Sam $passwords[$u.Sam]
        if ($b.Ok) { $logons++ } else { $warnings.Add("$($u.Sam): the planned logon failed: $($b.Reason)") }
    }
    Say "real logons: $logons"

    # 6. Expired users into their group: from now on their PSO ages them out.
    $expiredSams = @($Users | Where-Object Tier -eq 'Expired' | ForEach-Object Sam)
    if ($expiredSams) { Set-PoolMembers 'Expired' $expiredSams; Say "expired tier: $($expiredSams.Count) users" }

    # 7. Lockouts, last, with every membership in place. One account that
    # misbehaves is a warning, not a failed build.
    $locked = 0
    foreach ($u in @($Users | Where-Object Locked)) {
        try {
            $bad = 'Wrong-' + [guid]::NewGuid().ToString('N')
            $ok = $false
            for ($k = 1; $k -le ($S.LockoutThreshold * 3); $k++) {
                $null = Test-PoolBind $u.Sam $bad
                if ((Get-ADUser -Identity $u.Sam -Properties LockedOut -Server $pdc).LockedOut) { $ok = $true; break }
            }
            if ($ok) { $locked++ } else { $warnings.Add("$($u.Sam) did not lock out after $($S.LockoutThreshold * 3) bad passwords.") }
        } catch { $warnings.Add("$($u.Sam): locking it out failed: $($_.Exception.Message)") }
    }
    Say "locked out: $locked"
    $passwords.Clear()

    # When the last expired password ages out (msDS-UserPasswordExpiryTimeComputed).
    $expiresAt = $null
    if ($expiredSams) {
        $latest = 0L
        foreach ($s in $expiredSams) {
            $v = [long] (Get-ADUser -Identity $s -Properties 'msDS-UserPasswordExpiryTimeComputed' -Server $pdc).'msDS-UserPasswordExpiryTimeComputed'
            if ($v -gt $latest -and $v -ne [long]::MaxValue) { $latest = $v }
        }
        if ($latest -gt 0) { $expiresAt = [DateTime]::FromFileTimeUtc($latest).ToString('o') }
    }
    [pscustomobject]@{
        Sams       = @($Users | ForEach-Object Sam)
        Created    = $created; Reset = $reset; LogOns = $logons; Locked = $locked
        ExpiredAge = $expiredAge; LockForever = [bool] $forever
        ExpiresAt  = $expiresAt
        Warnings   = $warnings.ToArray()
        At         = (Get-Date).ToUniversalTime().ToString('o')
        Pdc        = $pdc
    }
}

$r = @($r | Where-Object { $_ -and $_.PSObject.Properties['Sams'] })[-1]
if (-not $r) { throw 'The PDC returned no result for the build.' }
# Names the DC had to change (taken outside the pool).
$sams = @($r.Sams)
for ($k = 0; $k -lt $users.Count -and $k -lt $sams.Count; $k++) { $users[$k].Sam = $sams[$k] }

# A short expired-tier age (minutes) is waited out, so the first read-back
# already sees those passwords expired; a long one is reported as "expires at".
$expiresAt = if ($r.ExpiresAt) { [datetime]::Parse($r.ExpiresAt).ToUniversalTime() } else { $null }
$waited = $null
if ($expiresAt) {
    $wait = $expiresAt - (Get-Date).ToUniversalTime()
    if ($wait.TotalMinutes -le 6 -and $wait.TotalSeconds -gt 0) {
        Write-Host "  waiting $([int] $wait.TotalSeconds + 15) s for the expired users' passwords to age out..."
        Start-Sleep -Seconds ([int] $wait.TotalSeconds + 15)
        $waited = $true
    }
}

$c = $plan.Counts
Save-CertModuleState -Context $Context -State @{
    seed = $seed; ou = $ouDn; at = $r.At; pdc = $r.Pdc
    counts = $c
    tiers = @($tiers | ForEach-Object { @{ key = $_.Key; max_age_days = $_.MaxAgeDays } })
    pso_prefix = $PoolPsoPrefix
    expired_max_age = if ($r.ExpiredAge) { $r.ExpiredAge.Used } else { $null }
    expired_ages_refused = if ($r.ExpiredAge) { @($r.ExpiredAge.Refused) } else { @() }
    expires_at = $r.ExpiresAt
    lock_forever = $r.LockForever
    users = @($users | ForEach-Object { @{ sam = $_.Sam; first = $_.First; last = $_.Last; state = $_.State; tier = $_.Tier; locked = $_.Locked; cannot_change = $_.CannotChange; logon = $_.LogOn } })
}

"pool $ouDn, seed ${seed}: $($c.Total) users ($($r.Created) created, $($r.Reset) reset): $($c.Normal) normal, $($c.Expired) expired, $($c.MustChange) must change$(if ($c.NeverExpires) { ", $($c.NeverExpires) never expire" }); $($r.Locked) of $($c.Locked) locked; $(if ($c.CannotChange) { "$($c.CannotChange) cannot change; " })$($r.LogOns) real logons"
if ($r.ExpiredAge) {
    "expired tier: PSO max age $($r.ExpiredAge.Used)$(if (@($r.ExpiredAge.Refused).Count) { " (refused: $(@($r.ExpiredAge.Refused | ForEach-Object { ($_ -split ' ', 2)[0] }) -join ', '))" }); $(if ($waited) { 'aged out before the read-back' } elseif ($expiresAt -and $expiresAt -gt (Get-Date).ToUniversalTime()) { "expires at $($expiresAt.ToString('yyyy-MM-dd HH:mm'))Z; re-read after then" } else { 'aged out' })"
}
"lockout: $(if ($r.LockForever) { 'until an admin unlocks' } else { 'unlocks on its own after 99999 minutes' })"
foreach ($w in @($r.Warnings)) { Write-Warning $w; "warning: $w" }
