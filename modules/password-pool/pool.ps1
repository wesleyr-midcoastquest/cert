<#
.SYNOPSIS
    password-pool: the plan, worked out on MGMT with no lab access. Dot-sourced
    by options.ps1 (the checks and summary before the snapshot) and break.ps1.
.DESCRIPTION
    Password states don't overlap: Expired, MustChange, NeverExpires or Normal.
    Locked out and cannot-change are independent of them, with two exclusions
    kept from New-LabPasswordPool.ps1: never-expires users are never expired
    or must-change (they are a state of their own), and cannot-change users
    are never must-change (they would be stuck).

    Counts are assigned, not rolled: each state gets its share of the total
    rounded half up, and Normal gets the rest, so 50 users at the defaults
    are exactly 5 locked, 8 expired, 8 must-change and 34 normal. When the
    rounding would make more users than there are (1 user at 50% + 50%), the
    state rounded up the most gives one back.
#>

# PSO tiers: one pool group and one PSO each. Normal users are spread over the
# Exp tiers; the Expired tier gets the smallest MaxPasswordAge a PSO accepts.
$PoolNormalDays = @(3, 30, 180)
$PoolGroupPrefix = 'SG-LAB-PwPool'
$PoolPsoPrefix = 'PSO-LAB-PwPool'
# Share of the users who can sign in (everyone but must-change) given one real
# logon (dates option C). The rest never sign in.
$PoolLogonPercent = 50

function Get-PoolRound([double] $X) { [int] [math]::Floor($X + 0.5) }

function Get-PoolCounts {
    param([Parameter(Mandatory)] $Options)
    $total = [int] $Options.total
    $want = [ordered]@{
        Expired      = $total * [int] $Options.expired_percent / 100.0
        MustChange   = $total * [int] $Options.must_change_percent / 100.0
        NeverExpires = $total * [int] $Options.never_expires_percent / 100.0
    }
    $n = [ordered]@{}
    foreach ($k in $want.Keys) { $n[$k] = Get-PoolRound $want[$k] }
    while (($n.Values | Measure-Object -Sum).Sum -gt $total) {
        $k = @($want.Keys | Where-Object { $n[$_] -gt 0 } | Sort-Object { $n[$_] - $want[$_] } -Descending)[0]
        $n[$k]--
    }
    $normal = [int] ($total - ($n.Values | Measure-Object -Sum).Sum)
    $canLogOn = $total - $n.MustChange
    [pscustomobject]@{
        Total        = $total
        Expired      = $n.Expired
        MustChange   = $n.MustChange
        NeverExpires = $n.NeverExpires
        Normal       = $normal
        Locked       = [math]::Min($total, (Get-PoolRound ($total * [int] $Options.locked_percent / 100.0)))
        CannotChange = [math]::Min($canLogOn, (Get-PoolRound ($total * [int] $Options.cannot_change_percent / 100.0)))
        LogOn        = Get-PoolRound ($canLogOn * $PoolLogonPercent / 100.0)
    }
}

function Test-PoolOptions {
    # The rules that span several options. Returns the problems (none = fine).
    param([Parameter(Mandatory)] $Options)
    $o = $Options
    $e = @()
    if ([int] $o.expired_percent + [int] $o.must_change_percent -gt 100) {
        $e += "Expired ($($o.expired_percent)%) + change at next logon ($($o.must_change_percent)%) is $([int] $o.expired_percent + [int] $o.must_change_percent)%: a user has one password state, so together they can't be more than 100%."
    }
    elseif ([int] $o.expired_percent + [int] $o.must_change_percent + [int] $o.never_expires_percent -gt 100) {
        $e += "Expired + change at next logon + never expires is $([int] $o.expired_percent + [int] $o.must_change_percent + [int] $o.never_expires_percent)%: never-expires users are never expired or must-change, so the three can't be more than 100%."
    }
    if ($e) { return $e }
    $c = Get-PoolCounts -Options $o
    $wantCannot = Get-PoolRound ($c.Total * [int] $o.cannot_change_percent / 100.0)
    if ($wantCannot -gt $c.CannotChange) {
        $e += "Cannot change password ($($o.cannot_change_percent)% = $wantCannot users) is more than the $($c.Total - $c.MustChange) users who don't have to change it at next logon (cannot-change users never must-change)."
    }
    $e
}

function Get-PoolTiers {
    # The tiers this plan uses, in PSO precedence order.
    param([Parameter(Mandatory)] $Counts)
    $t = @()
    if ($Counts.MustChange + $Counts.NeverExpires -gt 0) { $t += [pscustomobject]@{ Key = 'Base'; MaxAgeDays = 365 } }
    if ($Counts.Expired -gt 0) { $t += [pscustomobject]@{ Key = 'Expired'; MaxAgeDays = 0 } }
    $normalTiers = [math]::Min($PoolNormalDays.Count, $Counts.Normal)
    for ($i = 0; $i -lt $normalTiers; $i++) { $t += [pscustomobject]@{ Key = "Exp$($PoolNormalDays[$i])"; MaxAgeDays = $PoolNormalDays[$i] } }
    $t
}

function Get-PoolShuffled {
    # Fisher-Yates with the plan's own Random, so a seed repeats exactly.
    param([Parameter(Mandatory)] [Random] $Rng, [Parameter(Mandatory)] [int] $Count)
    if ($Count -le 0) { return @() }
    $a = [int[]] (0..($Count - 1))
    for ($i = $Count - 1; $i -gt 0; $i--) { $j = $Rng.Next($i + 1); $x = $a[$i]; $a[$i] = $a[$j]; $a[$j] = $x }
    $a
}

function New-PoolPlan {
    # One entry per user: name, password state, tier, locked, cannot change,
    # gets a real logon. Passwords are not part of the plan: the DC makes them.
    param([Parameter(Mandatory)] $Options, [Parameter(Mandatory)] [int] $Seed)
    $rng = [Random]::new($Seed)
    $c = Get-PoolCounts -Options $Options
    $first = 'Ava', 'Ben', 'Cara', 'Dev', 'Elena', 'Finn', 'Grace', 'Hugo', 'Iris', 'Jonah', 'Kira', 'Leo',
             'Maya', 'Noah', 'Olive', 'Pablo', 'Quinn', 'Rosa', 'Sam', 'Tara', 'Uma', 'Victor', 'Wren',
             'Xavier', 'Yara', 'Zane', 'Nadia', 'Omar', 'Priya', 'Rhys'
    $last  = 'Adams', 'Baker', 'Chen', 'Diaz', 'Evans', 'Foster', 'Garcia', 'Hayes', 'Ito', 'Jensen',
             'Khan', 'Lopez', 'Morgan', 'Nguyen', 'Ortiz', 'Patel', 'Reed', 'Silva', 'Turner', 'Vance',
             'Walsh', 'Young', 'Brooks', 'Castillo', 'Doyle', 'Ellis', 'Flores', 'Gray', 'Holt', 'Kim'

    $states = @(@('Expired') * $c.Expired) + @(@('MustChange') * $c.MustChange) + @(@('NeverExpires') * $c.NeverExpires) + @(@('Normal') * $c.Normal)
    $order = @(Get-PoolShuffled -Rng $rng -Count $c.Total)
    $used = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $users = [Collections.Generic.List[object]]::new()
    $normalSeen = 0
    $normalTiers = [math]::Min($PoolNormalDays.Count, $c.Normal)
    for ($i = 0; $i -lt $c.Total; $i++) {
        $f = $first[$rng.Next($first.Count)]; $l = $last[$rng.Next($last.Count)]
        $base = "$f.$l".ToLowerInvariant()
        $sam = $base; $k = 1
        while (-not $used.Add($sam)) { $k++; $sam = "$base$k" }
        $state = $states[$order[$i]]
        $tier = switch ($state) {
            'Expired' { 'Expired' }
            'Normal' { "Exp$($PoolNormalDays[$normalSeen++ % $normalTiers])" }
            default { 'Base' }
        }
        $users.Add([pscustomobject]@{ Sam = $sam; First = $f; Last = $l; State = $state; Tier = $tier; Locked = $false; CannotChange = $false; LogOn = $false })
    }
    foreach ($i in @(Get-PoolShuffled -Rng $rng -Count $c.Total) | Select-Object -First $c.Locked) { $users[$i].Locked = $true }
    $canLogOn = @(for ($i = 0; $i -lt $c.Total; $i++) { if ($users[$i].State -ne 'MustChange') { $i } })
    if ($canLogOn.Count) {
        $pick = @(Get-PoolShuffled -Rng $rng -Count $canLogOn.Count)
        foreach ($j in $pick | Select-Object -First $c.CannotChange) { $users[$canLogOn[$j]].CannotChange = $true }
        $pick = @(Get-PoolShuffled -Rng $rng -Count $canLogOn.Count)
        foreach ($j in $pick | Select-Object -First $c.LogOn) { $users[$canLogOn[$j]].LogOn = $true }
    }
    [pscustomobject]@{ Seed = $Seed; Counts = $c; Tiers = @(Get-PoolTiers -Counts $c); Users = $users.ToArray() }
}

function Get-PoolOUPath {
    # The pool OU as an inventory path (People/PasswordPool), and as a DN when
    # the inventory is there to say the domain.
    param($Inventory)
    $parent = if ($Inventory -and $Inventory.placement.standard_users) { [string] $Inventory.placement.standard_users } else { 'People' }
    $path = "$parent/PasswordPool"
    if ($Inventory -and (Get-Command Get-LabDomainDN -ErrorAction SilentlyContinue)) {
        ConvertTo-LabOUDistinguishedName -OUPath $path -DomainDN (Get-LabDomainDN -Inventory $Inventory)
    } else { $path }
}
