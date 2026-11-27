<#
.SYNOPSIS
    password-pool: checks the options together and writes the summary shown
    before "Snapshot the lab and build the fixture?". Runs on MGMT, no lab access.
#>
param([Parameter(Mandatory)] $Options, $Inventory)

. (Join-Path $PSScriptRoot 'pool.ps1')

$errors = @(Test-PoolOptions -Options $Options)
if ($errors) { return @{ Errors = $errors; Summary = @() } }

$c = Get-PoolCounts -Options $Options
$tiers = @(Get-PoolTiers -Counts $c)
$psos = @(foreach ($t in $tiers) {
    $age = switch ($t.Key) { 'Base' { '365 days (must-change and never-expires users)' } 'Expired' { 'the smallest a PSO accepts, found at build time (expired users)' } default { "$($t.MaxAgeDays) days (normal users)" } }
    "$PoolPsoPrefix-$($t.Key): max password age $age"
})
$seed = if ($null -ne $Options.seed) { "seed $($Options.seed) (repeatable)" } else { 'no seed: a random one is picked and recorded in the timeline, to repeat the run' }

@{
    Errors  = @()
    Summary = @(
        "Pool OU:   $(Get-PoolOUPath -Inventory $Inventory) (created if missing)"
        "Users:     $($c.Total): $($c.Normal) normal (spread over $(@($tiers | Where-Object { $_.Key -match '^Exp\d+$' } | ForEach-Object { $_.MaxAgeDays }) -join '/')-day expiry), $($c.Expired) expired, $($c.MustChange) change at next logon$(if ($c.NeverExpires) { ", $($c.NeverExpires) never expire" })"
        "           $($c.Locked) locked out (any state)$(if ($c.CannotChange) { "; $($c.CannotChange) cannot change their password" })"
        @(for ($k = 0; $k -lt [math]::Max(1, $psos.Count); $k++) { "$(if ($k) { '           ' } else { 'PSOs:      ' })$(if ($psos) { $psos[$k] } else { 'none' })" })
        "           every pool PSO: lockout after 3 bad passwords, locked until an admin unlocks (or the longest a PSO accepts)"
        "Dates:     real logons only (option C): $($c.LogOn) users sign in once after their password is set; the rest never sign in"
        "Passwords: random per user, never written anywhere"
        "Seed:      $seed"
        'The Default Domain Policy is not changed. The report is password-pool.csv in the run folder.'
    )
}
