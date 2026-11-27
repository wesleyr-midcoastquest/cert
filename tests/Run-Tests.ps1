#Requires -Version 7.2
<#
.SYNOPSIS
    Offline tests for CERT: no Proxmox, no guests. Proxmox is a fake that
    records calls, so the snapshot and revert sequences can be checked.

.PARAMETER LabRoot
    A midcoast-labs clone (its lab.yaml, site.example.yaml, Lab.Inventory and
    validation catalog are used to build a fake lab).

.EXAMPLE
    ./tests/Run-Tests.ps1 -LabRoot ../midcoast-labs
#>
[CmdletBinding()]
param([Parameter(Mandatory)] [string] $LabRoot)
$ErrorActionPreference = 'Stop'
$certRoot = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $certRoot 'src/Cert/Cert.psm1') -Force -DisableNameChecking
$cert = Get-Module Cert

$script:failed = 0; $script:passed = 0
function Assert([string] $Name, [scriptblock] $Test) {
    try {
        if (& $Test) { $script:passed++; Write-Host "  ok    $Name" }
        else { $script:failed++; Write-Host "  FAIL  $Name" -ForegroundColor Red }
    } catch { $script:failed++; Write-Host "  FAIL  $Name : $($_.Exception.Message)" -ForegroundColor Red }
}
function Assert-Throws([string] $Name, [scriptblock] $Test, [string] $Like = '*') {
    try { & $Test; $script:failed++; Write-Host "  FAIL  $Name (no error)" -ForegroundColor Red }
    catch { if ($_.Exception.Message -like $Like) { $script:passed++; Write-Host "  ok    $Name" } else { $script:failed++; Write-Host "  FAIL  $Name : $($_.Exception.Message)" -ForegroundColor Red } }
}

# ── A fake lab on disk ────────────────────────────────────────────────────
$tmp = Join-Path ([IO.Path]::GetTempPath()) "cert-tests-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
$lab = Join-Path $tmp 'lab'
foreach ($d in 'inventory', 'platform/modules/Lab.Inventory', 'platform/validation') { New-Item -ItemType Directory -Path (Join-Path $lab $d) -Force | Out-Null }
Copy-Item (Join-Path $LabRoot 'inventory/lab.yaml') (Join-Path $lab 'inventory/lab.yaml')
Copy-Item (Join-Path $LabRoot 'inventory/site.example.yaml') (Join-Path $lab 'inventory/site.yaml')
Copy-Item (Join-Path $LabRoot 'platform/modules/Lab.Inventory/Lab.Inventory.psm1') (Join-Path $lab 'platform/modules/Lab.Inventory/')
Copy-Item (Join-Path $LabRoot 'platform/validation/catalog.psd1') (Join-Path $lab 'platform/validation/')
@'
instances:
- name: DC-261101-00
  role: DC
  sequence: '00'
  build_date: '261101'
  slot: A
  vmid: 100
  ipv4: 10.50.10.10
  state: active
- name: DC-261101-01
  role: DC
  sequence: '01'
  build_date: '261101'
  slot: B
  vmid: 101
  ipv4: 10.50.10.11
  state: active
- name: MGMT-261102-00
  role: MGMT
  sequence: '00'
  build_date: '261102'
  slot: B
  vmid: 121
  ipv4: 10.50.10.31
  state: active
- name: W11-261103-00
  role: W11
  sequence: '00'
  build_date: '261103'
  vmid: 140
  ipv4: 10.50.10.40
  state: active
templates: []
'@ | Set-Content (Join-Path $lab 'inventory/instances.yaml')

$cfgPath = Join-Path $tmp 'cert.config.yaml'
@"
lab_repo: $lab
runs_path: $(Join-Path $tmp 'runs')
lock_path: $(Join-Path $tmp 'CERT.lock')
snapshot:
  max_sets: 5
"@ | Set-Content $cfgPath

Write-Host 'Config and lab'
$config = Get-CertConfig -Path $cfgPath
Assert 'local config overrides a default' { $config.snapshot.max_sets -eq 5 }
Assert 'defaults kept beside an override' { $config.snapshot.include_ram -eq $true -and $config.snapshot.storage_warn_percent -eq 80 }
Assert 'arrays come from the defaults' { @($config.assessor.allow) -contains 'winrm-http' }
$L = Get-CertLab -Config $config
Assert 'lab resolves through the lab''s own Lab.Inventory' { $L.Inventory.identity.active_directory.domain -eq 'ad.example.com' -and $L.Inventory.proxmox.node -eq 'pve01' }
Assert 'ledger read' { @($L.Instances).Count -eq 4 }
Assert 'ledger hash ignores line endings' { $L.LedgerHash -eq (Get-CertTextHash -Text ((Get-Content (Join-Path $lab 'inventory/instances.yaml') -Raw) -replace "`n", "`r`n")) }
Assert 'compatibility of the lab this CERT targets' { (Test-CertLabCompatibility -Lab $L).Ok }
Assert 'another major is refused' { -not (Test-CertLabCompatibility -Lab ([pscustomobject]@{ Version = '2.0'; Release = 'x' })).Ok }
Assert 'another minor warns' { $c = Test-CertLabCompatibility -Lab ([pscustomobject]@{ Version = '1.7'; Release = 'x' }); $c.Ok -and $c.Message -like '*Expected to work*' }
$as = Get-CertAssessor -Config $config -Lab $L
Assert 'by default the fixer works on MGMT' { $as.IsMgmt -and $as.Address -eq '10.50.10.31' -and -not $as.Fallback }
$cfgW11 = Merge-CertObject -Base $config -Overlay ([pscustomobject]@{ assessor = [pscustomobject]@{ role = 'W11' } })
Assert 'assessor.role W11 picks the active W11' { $x = Get-CertAssessor -Config $cfgW11 -Lab $L; $x.Address -eq '10.50.10.40' -and -not $x.IsMgmt }
$Lnow11 = Get-CertLab -Config $config; $Lnow11.Instances = @($Lnow11.Instances | Where-Object role -ne 'W11')
Assert 'no W11: falls back to MGMT, and says so' { $x = Get-CertAssessor -Config $cfgW11 -Lab $Lnow11; $x.IsMgmt -and $x.Fallback }
$cfgAddr = Merge-CertObject -Base $config -Overlay ([pscustomobject]@{ assessor = [pscustomobject]@{ address = '10.50.10.77' } })
Assert 'a fixed address is used as given' { $x = Get-CertAssessor -Config $cfgAddr -Lab $L; $x.Address -eq '10.50.10.77' -and -not $x.IsMgmt }
$members = & $cert { param($c, $l) Get-CertSnapshotSetMembers -Config $c -Lab $l } $config $L
Assert 'the 1.6 per-site tag comes from the inventory' { (Get-CertLabTag -Lab $L) -eq 'midcoast-lab-example-lab' }
Assert 'snapshot set: every active VM except MGMT' { (@($members.name) -join ',') -eq 'DC-261101-00,DC-261101-01,W11-261103-00' }
$cfgNoMgmt = Merge-CertObject -Base $config -Overlay ([pscustomobject]@{ snapshot = [pscustomobject]@{ exclude_roles = @('W11') } })
$members2 = & $cert { param($c, $l) Get-CertSnapshotSetMembers -Config $c -Lab $l } $cfgNoMgmt $L
Assert 'MGMT stays out even when exclude_roles forgets it' { @($members2.name) -notcontains 'MGMT-261102-00' -and @($members2.name) -notcontains 'W11-261103-00' }

Write-Host 'Targets'
$mgmtTarget = [pscustomobject]@{ targets = @([pscustomobject]@{ name = 'victim'; select = 'role:MGMT' }) }
Assert-Throws 'a module can never target MGMT' { Resolve-CertTargets -Config $config -Lab $L -Manifest $mgmtTarget } "*isn't in the snapshot set*"
$dcTarget = [pscustomobject]@{ targets = @([pscustomobject]@{ name = 'all'; select = 'all-dcs' }) }
Assert 'all-dcs resolves to both DCs' { @((Resolve-CertTargets -Config $config -Lab $L -Manifest $dcTarget)['all']).Count -eq 2 }

Write-Host 'Versions and requirements'
Assert '1.5 = 1.5.0' { (Compare-CertVersion '1.5' '1.5.0') -eq 0 }
Assert '0.10 > 0.9' { (Compare-CertVersion '0.10' '0.9') -eq 1 }
Assert '>=0.1 met by 0.1.0' { Test-CertRequirement '>=0.1' '0.1.0' }
Assert '>=1.6 not met by 1.5' { -not (Test-CertRequirement '>=1.6' '1.5') }
Assert-Throws 'only >= is supported' { Test-CertRequirement '~1.5' '1.5' } '*Unsupported*'

Write-Host 'Modules'
$mods = @(Get-CertModules -Config $config -LabRoot $lab)
Assert 'seven built-in modules, all valid' { $mods.Count -eq 7 -and @($mods | Where-Object { -not $_.Valid }).Count -eq 0 }
$bad = Join-Path $tmp 'bad/Bad_Module'
New-Item -ItemType Directory -Path $bad -Force | Out-Null
@'
id: other-name
version: 1.0
name: x
summary: x
category: Weather
difficulty: 9
destructive: maybe
requires: { cert: "~0.1" }
targets:
  - { name: v, select: the-big-one }
engagement: { access: root, briefing: ../etc/passwd }
expected_failures: [repl-1, ZZZ-999]
break: break.sh
solution: solution.md
'@ | Set-Content (Join-Path $bad 'module.yaml')
Set-Content (Join-Path $bad 'break.sh') 'echo'
$p = @(Test-CertManifest -Manifest (Read-CertYaml (Join-Path $bad 'module.yaml')) -Folder $bad -Catalog (Get-CertLabCatalogIds -LabRoot $lab))
foreach ($want in "id 'other-name' must match", "version '", "category 'Weather'", 'difficulty', 'destructive', 'authors', "requires.cert: Unsupported", 'requires.lab is required',
                  "select 'the-big-one'", "engagement.access 'root'", 'a file name in the module folder', "'break.sh' must be a .ps1", "solution file 'solution.md' is missing", "'repl-1': a validation ID", "'ZZZ-999' isn't in the lab's validation catalog") {
    Assert "rejects: $want" { @($p | Where-Object { $_ -like "*$want*" }).Count -gt 0 }.GetNewClosure()
}
$broken = Join-Path $tmp 'parse/parse-error'
New-Item -ItemType Directory -Path $broken -Force | Out-Null
Copy-Item (Join-Path $certRoot 'modules/gpo-deleted/*') $broken
(Get-Content (Join-Path $broken 'module.yaml') -Raw).Replace('id: gpo-deleted', 'id: parse-error') | Set-Content (Join-Path $broken 'module.yaml')
Set-Content (Join-Path $broken 'break.ps1') 'param($Context) if ( {'
Assert 'a script that does not parse is a problem' { @(Test-CertManifest -Manifest (Read-CertYaml (Join-Path $broken 'module.yaml')) -Folder $broken) -like 'break.ps1: line*' }
Set-Content (Join-Path $broken 'break.ps1') @'
param($Context)
Invoke-CertTarget -Context $Context -Instance $x -ArgumentList (, $names), (, $more) -ScriptBlock { param($A, $B) }
Invoke-CertTarget -Context $Context -Instance $x -ArgumentList (, $names) -ScriptBlock { param($A) }
Invoke-CertTarget -Context $Context -Instance $x -ArgumentList $names, $more -ScriptBlock { param($A, $B) }
'@
$nested = @(Test-CertManifest -Manifest (Read-CertYaml (Join-Path $broken 'module.yaml')) -Folder $broken | Where-Object { $_ -like '*array inside an array*' })
Assert 'one of several arguments wrapped as (, $x) is a problem; a lone one is not' { $nested.Count -eq 2 -and @($nested -like 'break.ps1: line 2:*').Count -eq 2 }

Write-Host 'Options and fixtures'
Assert 'existing modules are scenarios with no options' { @($mods | Where-Object { $_.Id -ne 'password-pool' -and ($_.Kind -ne 'scenario' -or @($_.Manifest.options | Where-Object { $_ }).Count) }).Count -eq 0 }
$gpo = @($mods | Where-Object Id -eq 'gpo-deleted')[0]
$gp = Get-CertModulePlan -Module $gpo
Assert 'a module without options: an empty plan, no errors' { $gp.Options.Count -eq 0 -and $gp.Errors.Count -eq 0 -and $gp.Summary.Count -eq 0 }
Assert 'an option a module does not have is refused' { @((Get-CertModulePlan -Module $gpo -Options @{ total = 5 }).Errors -like "*has no option 'total'*").Count -eq 1 }
$intOpt = [pscustomobject]@{ name = 'total'; type = 'int'; min = 1; max = 5000 }
Assert 'int option: text is converted' { (ConvertTo-CertOptionValue -Option $intOpt -Value ' 42 ') -eq 42 }
Assert-Throws 'int option: not a number' { ConvertTo-CertOptionValue -Option $intOpt -Value 'lots' } '*whole number*'
Assert-Throws 'int option: out of range' { ConvertTo-CertOptionValue -Option $intOpt -Value 5001 } '*1 to 5000*'
Assert 'bool option: yes/no' { (ConvertTo-CertOptionValue -Option ([pscustomobject]@{ name = 'b'; type = 'bool' }) -Value 'Yes') -eq $true -and (ConvertTo-CertOptionValue -Option ([pscustomobject]@{ name = 'b'; type = 'bool' }) -Value 'n') -eq $false }
Assert 'empty input means not set' { $null -eq (ConvertTo-CertOptionValue -Option $intOpt -Value '') }
$optMod = Join-Path $tmp 'opts/opt-module'
New-Item -ItemType Directory -Path $optMod -Force | Out-Null
Copy-Item (Join-Path $certRoot 'modules/gpo-deleted/*') $optMod
$y = (Get-Content (Join-Path $optMod 'module.yaml') -Raw).Replace('id: gpo-deleted', 'id: opt-module')
Set-Content (Join-Path $optMod 'module.yaml') ($y + @'

options:
  - { name: Bad-Name, prompt: x, type: int }
  - { name: count, prompt: How many, type: int, default: 9, min: 1, max: 5 }
  - { name: count, prompt: again, type: int }
  - { name: colour, prompt: true, type: text }
  - { name: flag, prompt: '', type: bool, min: 1 }
options_check: missing.ps1
'@)
$op = @(Test-CertManifest -Manifest (Read-CertYaml (Join-Path $optMod 'module.yaml')) -Folder $optMod)
foreach ($want in "option name 'Bad-Name'", "option 'count' default: count must be 1 to 5", "option 'count' is listed twice", "option 'colour' type 'text'", "option 'flag' prompt", "option 'flag' min: only for type int", "options_check file 'missing.ps1' is missing") {
    Assert "rejects: $want" { @($op | Where-Object { $_ -like "*$want*" }).Count -gt 0 }.GetNewClosure()
}
$fixMod = Join-Path $tmp 'fix/fix-module'
New-Item -ItemType Directory -Path $fixMod -Force | Out-Null
Copy-Item (Join-Path $certRoot 'modules/gpo-deleted/*') $fixMod
$fy = (Get-Content (Join-Path $fixMod 'module.yaml') -Raw).Replace('id: gpo-deleted', 'id: fix-module') -replace '(?m)^verify:.*$', ''
Set-Content (Join-Path $fixMod 'module.yaml') ("kind: fixture`n" + $fy)
$fp = @(Test-CertManifest -Manifest (Read-CertYaml (Join-Path $fixMod 'module.yaml')) -Folder $fixMod -Catalog (Get-CertLabCatalogIds -LabRoot $lab))
Assert 'a fixture without verify is refused' { @($fp -like '*a fixture needs verify*').Count -eq 1 }
Assert 'a fixture with expected_failures is refused' { @($fp -like '*a fixture has no expected_failures*').Count -eq 1 }
Set-Content (Join-Path $fixMod 'module.yaml') ("kind: puzzle`n" + $fy)
Assert 'an unknown kind is refused' { @(Test-CertManifest -Manifest (Read-CertYaml (Join-Path $fixMod 'module.yaml')) -Folder $fixMod) -like "*kind 'puzzle'*" }
Set-Content (Join-Path $fixMod 'module.yaml') ($fy -replace '(?m)^expected_failures:\s*\n(\s+-.*\n)+', "expected_failures: []`n")
Assert 'scenario rule unchanged: no expected_failures and no verify is refused' { @(Test-CertManifest -Manifest (Read-CertYaml (Join-Path $fixMod 'module.yaml')) -Folder $fixMod) -like '*expected_failures or verify*' }

$pool = @($mods | Where-Object Id -eq 'password-pool')[0]
Assert 'password-pool is a valid fixture' { $pool.Valid -and $pool.Kind -eq 'fixture' }
$pp = Get-CertModulePlan -Module $pool -Lab $L
Assert 'defaults fill in: 50 users, 10/15/15, no seed' { $pp.Errors.Count -eq 0 -and $pp.Options.total -eq 50 -and $pp.Options.locked_percent -eq 10 -and $pp.Options.expired_percent -eq 15 -and $pp.Options.must_change_percent -eq 15 -and $pp.Options.never_expires_percent -eq 0 -and $null -eq $pp.Options.seed }
Assert 'the summary names the pool OU from the inventory' { @($pp.Summary -like "*OU=PasswordPool,OU=People,DC=ad,DC=example,DC=com*").Count -eq 1 }
Assert 'the summary gives the counts: 34 normal, 8 expired, 8 must change, 5 locked' { @($pp.Summary -like '*50: 34 normal*8 expired, 8 change at next logon*').Count -eq 1 -and @($pp.Summary -like '*5 locked out*').Count -eq 1 }
Assert 'options_check: expired + must change over 100% is refused' { @((Get-CertModulePlan -Module $pool -Options @{ expired_percent = 60; must_change_percent = 50 }).Errors -like '*110%*').Count -eq 1 }
Assert 'options_check: never expires counted in that 100% too' { @((Get-CertModulePlan -Module $pool -Options @{ expired_percent = 50; must_change_percent = 40; never_expires_percent = 20 }).Errors -like '*never expires is 110%*').Count -eq 1 }
Assert 'options_check: cannot-change needs users who are not must-change' { @((Get-CertModulePlan -Module $pool -Options @{ total = 10; expired_percent = 0; must_change_percent = 100; cannot_change_percent = 10 }).Errors -like '*Cannot change password*').Count -eq 1 }
Assert 'a range error is reported before options_check runs' { $e = @((Get-CertModulePlan -Module $pool -Options @{ total = 0 }).Errors); $e.Count -eq 1 -and $e[0] -like 'total must be 1 to 5000*' }
Assert-Throws 'Start-CertRun refuses invalid options before anything else' { Start-CertRun -Config $config -Lab $L -Module $pool -Options @{ total = 9999 } } "*options aren't valid, so nothing was done*"
Assert-Throws 'Start-CertRun refuses a blind fixture' { Start-CertRun -Config $config -Lab $L -Module $pool -Blind } '*is a fixture*blind*'

. (Join-Path $certRoot 'modules/password-pool/pool.ps1')
$plan50 = New-PoolPlan -Options $pp.Options -Seed 7
$byState = @{}; foreach ($u in $plan50.Users) { $byState[$u.State] = 1 + [int] $byState[$u.State] }
Assert 'pool: 50 at the defaults is exactly 34 normal, 8 expired, 8 must change' { $byState.Normal -eq 34 -and $byState.Expired -eq 8 -and $byState.MustChange -eq 8 -and -not $byState.NeverExpires }
Assert 'pool: exactly 5 locked' { @($plan50.Users | Where-Object Locked).Count -eq 5 }
Assert 'pool: normal users spread over the 3/30/180-day tiers' { (@($plan50.Users | Where-Object State -eq 'Normal' | Group-Object Tier | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ',') -eq 'Exp180=11,Exp3=12,Exp30=11' }
Assert 'pool: expired users in their own tier, must-change in Base' { -not @($plan50.Users | Where-Object { ($_.State -eq 'Expired' -and $_.Tier -ne 'Expired') -or ($_.State -eq 'MustChange' -and $_.Tier -ne 'Base') }) }
Assert 'pool: half of those who can sign in get a logon; no must-change user does' { @($plan50.Users | Where-Object LogOn).Count -eq 21 -and -not @($plan50.Users | Where-Object { $_.LogOn -and $_.State -eq 'MustChange' }) }
Assert 'pool: the same seed gives the same plan, another seed another' { ((New-PoolPlan -Options $pp.Options -Seed 7).Users | ConvertTo-Json) -eq ($plan50.Users | ConvertTo-Json) -and ((New-PoolPlan -Options $pp.Options -Seed 8).Users | ConvertTo-Json) -ne ($plan50.Users | ConvertTo-Json) }
$big = New-PoolPlan -Options ([ordered]@{ total = 5000; locked_percent = 10; expired_percent = 15; must_change_percent = 15; never_expires_percent = 5; cannot_change_percent = 20 }) -Seed 1
Assert 'pool: 5000 users, unique names of 20 characters at most' { @($big.Users.Sam | Sort-Object -Unique).Count -eq 5000 -and ($big.Users.Sam | ForEach-Object Length | Measure-Object -Maximum).Maximum -le 20 }
Assert 'pool: cannot-change users are never must-change; never-expires in Base' { @($big.Users | Where-Object CannotChange).Count -eq 1000 -and -not @($big.Users | Where-Object { $_.CannotChange -and $_.State -eq 'MustChange' }) -and -not @($big.Users | Where-Object { $_.State -eq 'NeverExpires' -and $_.Tier -ne 'Base' }) }
$c1 = Get-PoolCounts -Options ([ordered]@{ total = 1; locked_percent = 0; expired_percent = 50; must_change_percent = 50; never_expires_percent = 0; cannot_change_percent = 0 })
Assert 'pool: rounding never makes more users than asked for' { $c1.Expired + $c1.MustChange + $c1.Normal -eq 1 -and $c1.Normal -eq 0 }

Write-Host 'Updates from a source'
$origin = Join-Path $tmp 'origin.git'; $work = Join-Path $tmp 'work'
& git init --quiet --bare --initial-branch=main $origin
& git clone --quiet $origin $work 2>$null
& git -C $work config user.email t@example.com; & git -C $work config user.name test
New-Item -ItemType Directory -Path (Join-Path $work 'modules') -Force | Out-Null
Copy-Item (Join-Path $certRoot 'modules/gpo-deleted') (Join-Path $work 'modules/') -Recurse
& git -C $work add -A; & git -C $work commit --quiet -m one; & git -C $work push --quiet origin main 2>$null
$cfgSrc = Merge-CertObject -Base $config -Overlay ([pscustomobject]@{ sources = @([pscustomobject]@{ name = 'extra'; url = $origin; ref = 'main' }) })
$sourceRoot = Join-Path $certRoot 'sources/extra'
Remove-Item $sourceRoot -Recurse -Force -ErrorAction SilentlyContinue
try {
    $u = @(Get-CertUpdates -Config $cfgSrc -Source extra)[0]
    Assert 'a new source is reported as not cloned' { $u.State -eq 'not cloned' }
    Install-CertUpdate -Update $u | Out-Null
    Assert 'installing clones it' { Test-Path (Join-Path $sourceRoot 'modules/gpo-deleted/module.yaml') }
    Assert 'its modules join the catalog' { @(Get-CertModules -Config $cfgSrc | Where-Object Key -eq 'extra/gpo-deleted').Count -eq 1 }
    (Get-Content (Join-Path $work 'modules/gpo-deleted/module.yaml') -Raw).Replace('version: 1.0.1', 'version: 1.1.0') | Set-Content (Join-Path $work 'modules/gpo-deleted/module.yaml')
    Copy-Item (Join-Path $certRoot 'modules/dc-time-skew') (Join-Path $work 'modules/') -Recurse
    & git -C $work add -A; & git -C $work commit --quiet -m two; & git -C $work push --quiet origin main 2>$null
    $u = @(Get-CertUpdates -Config $cfgSrc -Source extra)[0]
    Assert 'behind, with the commit listed' { $u.State -eq 'behind' -and @($u.Commits).Count -eq 1 }
    Assert 'updated module shows old and new version' { @($u.Changes | Where-Object { $_.Id -eq 'gpo-deleted' -and $_.From -eq '1.0.1' -and $_.To -eq '1.1.0' }).Count -eq 1 }
    Assert 'new module shows as new' { @($u.Changes | Where-Object { $_.Id -eq 'dc-time-skew' -and $_.Change -eq 'new' }).Count -eq 1 }
    Assert 'fetching changed nothing yet' { (Read-CertYaml (Join-Path $sourceRoot 'modules/gpo-deleted/module.yaml')).version -eq '1.0.1' }
    Add-Content (Join-Path $sourceRoot 'modules/gpo-deleted/solution.md') 'local edit'
    Assert-Throws 'local edits stop an update' { Install-CertUpdate -Update $u } '*local changes*'
    & git -C $sourceRoot checkout --quiet -- .
    Install-CertUpdate -Update $u | Out-Null
    Assert 'fast-forwarded' { (Read-CertYaml (Join-Path $sourceRoot 'modules/gpo-deleted/module.yaml')).version -eq '1.1.0' }
} finally { Remove-Item $sourceRoot -Recurse -Force -ErrorAction SilentlyContinue; Remove-Item (Join-Path $certRoot 'sources') -Force -ErrorAction SilentlyContinue }

Write-Host 'Snapshot and revert sequences (fake Proxmox)'
& $cert { param($t, $p) $script:FakeTag = $t; $script:FakePool = $p } $L.Inventory.proxmox.tag $L.Inventory.proxmox.pool
& $cert {
    $script:PveCalls = [Collections.Generic.List[string]]::new()
    $script:PveSnaps = @{}
    $script:PveState = @{ 100 = 'running'; 101 = 'running'; 140 = 'running' }
    $script:PveLink  = @{ 100 = 'up'; 101 = 'up'; 140 = 'up' }
    $script:SnapLink = @{}
    $script:PveDesc  = @{}
    function script:Get-CertPveToken { 'fake' }
    function script:Wait-CertPveTask { }
    function script:Invoke-CertPve {
        param($Lab, $Method, $Path, $Body)
        $script:PveCalls.Add("$Method $Path")
        switch -Regex ("$Method $Path") {
            '^GET /cluster/resources' { return @(100, 101, 121, 140 | ForEach-Object { [pscustomobject]@{ vmid = $_; node = 'pve01'; status = $(if ($script:PveState[$_] -eq 'stopped') { 'stopped' } else { 'running' }); name = @{ 100 = 'DC-261101-00'; 101 = 'DC-261101-01'; 121 = 'MGMT-261102-00'; 140 = 'W11-261103-00' }[$_]; tags = $script:FakeTag; pool = $script:FakePool; maxmem = 4GB } }) }
            '^GET /nodes/\w+/qemu/(\d+)/snapshot$' { return @($script:PveSnaps[[int] $Matches[1]] | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ name = $_; vmstate = 1; snaptime = 1762400000; description = 'ledger=0123456789ab' } }) }
            '^POST /nodes/\w+/qemu/(\d+)/snapshot$' { $script:PveSnaps[[int] $Matches[1]] = @($script:PveSnaps[[int] $Matches[1]]) + $Body.snapname; $script:SnapLink[[int] $Matches[1]] = $script:PveLink[[int] $Matches[1]]; return 'UPID:pve01:x' }
            '^GET /nodes/\w+/qemu/(\d+)/config$' { $l = if ($script:PveLink[[int] $Matches[1]] -eq 'down') { ',link_down=1' } else { '' }; return [pscustomobject]@{ net0 = "virtio=BC:24:11:00:00:01,bridge=vmbr2$l"; description = $script:PveDesc[[int] $Matches[1]] } }
            '^PUT /nodes/\w+/qemu/(\d+)/config$' {
                $id = [int] $Matches[1]
                if ($Body.ContainsKey('net0')) { $script:PveLink[$id] = if ($Body.net0 -match 'link_down=1') { 'down' } else { 'up' } }
                if ($Body.ContainsKey('description')) { $script:PveDesc[$id] = $Body.description }
                if ($Body.delete -eq 'description') { $script:PveDesc.Remove($id) }
                return $null
            }
            '^POST /nodes/\w+/qemu/(\d+)/snapshot/[^/]+/rollback' { $script:PveState[[int] $Matches[1]] = 'running'; $script:PveLink[[int] $Matches[1]] = $script:SnapLink[[int] $Matches[1]]; return 'UPID:pve01:x' }
            '^DELETE /nodes/\w+/qemu/(\d+)/snapshot/(.+)$' { $script:PveSnaps[[int] $Matches[1]] = @($script:PveSnaps[[int] $Matches[1]] | Where-Object { $_ -ne $Matches[2] }); return 'UPID:pve01:x' }
            '^POST /nodes/\w+/qemu/(\d+)/status/(\w+)' { $script:PveState[[int] $Matches[1]] = @{ suspend = 'paused'; resume = 'running'; stop = 'stopped'; start = 'running' }[$Matches[2]]; return 'UPID:pve01:x' }
            '^GET /nodes/\w+/qemu/(\d+)/status/current' { $s = $script:PveState[[int] $Matches[1]]; return [pscustomobject]@{ status = if ($s -eq 'stopped') { 'stopped' } else { 'running' }; qmpstatus = $s } }
            '^GET /nodes/\w+/storage/[^/]+/status$' { return [pscustomobject]@{ used = [long] 918055550976; total = [long] 1836111101952 } }
            default { throw "fake Proxmox: unexpected $Method $Path" }
        }
    }
}
$vms = foreach ($i in $members) { [pscustomobject]@{ Instance = $i; Vm = (Get-CertPveVm -Lab $L -VmId ([int] $i.vmid)) } }
$snapName = New-CertSnapshotName -Lab $L -Vms @($vms.Vm)
Assert 'snapshot names: CERT-YYMMDD-HHMM-NN' { $snapName -match '^CERT-\d{6}-\d{4}-00$' }
New-CertSnapshotSet -Config $config -Lab $L -Vms $vms -Name $snapName -Purpose 'test' 6>$null
$calls = @(& $cert { $script:PveCalls })
$ops = @($calls | Where-Object { $_ -match '^(POST|PUT)' } | ForEach-Object { if ($_ -match '^PUT .*/config$') { "link:$(($_ -split '/')[4])" } elseif ($_ -match 'status/(\w+)') { "$($Matches[1]):$(($_ -split '/')[4])" } elseif ($_ -match '/snapshot$') { "snap:$(($_ -split '/')[4])" } })
Assert 'all unplugged before the first snapshot' { ($ops[0..2] -join ',') -eq 'link:100,link:101,link:140' }
Assert 'then each snapshotted, running (never paused)' { ($ops[3..5] -join ',') -eq 'snap:100,snap:101,snap:140' -and -not @($ops | Where-Object { $_ -like 'suspend*' }) }
Assert 'then all plugged back in' { ($ops[6..8] -join ',') -eq 'link:100,link:101,link:140' -and @(& $cert { $script:PveLink.Values } | Where-Object { $_ -ne 'up' }).Count -eq 0 }
Assert 'every snapshot recorded the VM unplugged' { @(& $cert { $script:SnapLink.Values } | Where-Object { $_ -ne 'down' }).Count -eq 0 }
Assert 'storage use of a 1.8 TB pool (past Int32)' { (Get-CertStorageUse -Lab $L -Nodes 'pve01').UsedPercent -eq 50 }
Assert 'MGMT never touched' { -not @($calls | Where-Object { $_ -match '/qemu/121/' -and $_ -notmatch '^GET' }) }
$sets = @(Get-CertSnapshotSets -Lab $L -Members $members)
Assert 'the set is listed once, on three VMs' { $sets.Count -eq 1 -and $sets[0].Count -eq 3 -and $sets[0].Name -eq $snapName }
Assert 'the next name in the same minute is -01' { (New-CertSnapshotName -Lab $L -Vms @($vms.Vm)) -like '*-01' }

& $cert { $script:PveCalls.Clear() }
Restore-CertSnapshotSet -Lab $L -Vms $vms -Name $snapName 6>$null
$calls = @(& $cert { $script:PveCalls } | Where-Object { $_ -match '^POST' })
$firstRollback = [array]::FindIndex([string[]] $calls, [Predicate[string]] { param($c) $c -match '/rollback' })
$lastStop = [array]::FindLastIndex([string[]] $calls, [Predicate[string]] { param($c) $c -match '/status/stop' })
Assert 'every VM stopped before any rollback' { @($calls | Where-Object { $_ -match '/status/stop' }).Count -eq 3 -and $lastStop -lt $firstRollback }
Assert 'every VM rolled back' { @($calls | Where-Object { $_ -match '/rollback' }).Count -eq 3 }
$allCalls = @(& $cert { $script:PveCalls })
$lastRollback = [array]::FindLastIndex([string[]] $allCalls, [Predicate[string]] { param($c) $c -match '/rollback' })
$firstPlug = [array]::FindIndex([string[]] $allCalls, [Predicate[string]] { param($c) $c -match '^PUT .*/config$' })
Assert 'plugged back in only after every rollback' { $firstPlug -gt $lastRollback -and @(& $cert { $script:PveLink.Values } | Where-Object { $_ -ne 'up' }).Count -eq 0 }
Assert-Throws 'a VM without the snapshot stops the revert before anything changes' { Restore-CertSnapshotSet -Lab $L -Vms $vms -Name 'CERT-000000-0000-00' } '*has no snapshot*'
Assert-Throws 'only CERT snapshots can be removed' { Remove-CertPveSnapshot -Lab $L -Vm $vms[0].Vm -Name 'before-upgrade' } '*Not a CERT snapshot*'

$openRun = [pscustomobject]@{ id = $snapName; state = 'Broken'; blind = $true; owner = 'tester'; created_utc = '2026-11-23T14:00:00Z'; module = [pscustomobject]@{ id = 'gpo-deleted' }; snapshot = [pscustomobject]@{ name = $snapName }; timeline = @(); updated_utc = $null }
Save-CertRun -Config $config -Run $openRun
& $cert { param($c, $r) Write-CertLock -Config $c -Run $r } $config $openRun
$lockJson = Get-Content $config.lock_path -Raw | ConvertFrom-Json
Assert 'the lock is JSON the lab can read' { $lockJson.run -eq $snapName -and $lockJson.snapshot -eq $snapName -and $lockJson.started }
Assert 'a blind run''s lock hides the scenario' { $lockJson.scenario -eq '(blind run)' }
Assert 'the open run is found from the JSON lock' { (Get-CertActiveRun -Config $config).id -eq $snapName }
Set-Content -Path $config.lock_path -Value $snapName
Assert 'and from a 0.1 plain lock' { (Get-CertActiveRun -Config $config).id -eq $snapName }
Assert-Throws "an open run's set can't be removed" { Remove-CertSnapshotSet -Config $config -Lab $L -Name $snapName -Confirm:$false } '*belongs to the open run*'
$pf = Test-CertPreflight -Config $config -Lab $L -SkipBaseline
Assert 'pre-flight refuses while a run is open' { -not $pf.Ok -and @($pf.Errors -like '*still open*').Count -eq 1 }
Remove-Item $config.lock_path
Assert 'with no run open, the set can be removed' { (Remove-CertSnapshotSet -Config $config -Lab $L -Name $snapName -Confirm:$false) -like 'Removed*' }

Write-Host 'Reaching guests (fake WinRM)'
$realCreds = & $cert { ${function:Get-CertCredentials} }
& $cert {
    $script:FakeTcp = $false; $script:FakeLogon = $null; $script:FakeMacs = @('', 'BC2411000001')
    function script:Get-CertCredentials { param($Lab) foreach ($u in 'LAB\Administrator', 'LAB\svc-labdeploy') { [pscredential]::new($u, (ConvertTo-SecureString 'x' -AsPlainText -Force)) } }
    function script:Test-Connection { param($TargetName, $TcpPort, $TimeoutSeconds, [switch] $Quiet) $script:FakeTcp }
    function script:New-PSSession { param($ComputerName, $Port, [switch] $UseSSL, $Authentication, $Credential, [ValidateNotNull()] $SessionOption, $ErrorAction) if ($script:FakeLogon) { throw $script:FakeLogon }; [pscustomobject]@{ Fake = $ComputerName } }
    $script:AskedPdc = [Collections.Generic.List[string]]::new()
    function script:Invoke-Command { param($Session, $ScriptBlock, $ArgumentList, $ErrorAction) if ($ScriptBlock.ToString() -match 'Get-NetAdapter') { $script:FakeMacs } elseif ($ScriptBlock.ToString() -match 'PDCEmulator') { $script:AskedPdc.Add($Session.Fake); 'DC-261101-01.lab.test' } elseif ($ScriptBlock.ToString() -match 'ran') { 'ran' } }
    function script:Remove-PSSession { param($Session, $ErrorAction) }
}
$dc0 = $L.Instances | Where-Object name -eq 'DC-261101-00'
$dc1 = $L.Instances | Where-Object name -eq 'DC-261101-01'
$s = Connect-CertGuest -Lab $L -Instance $dc0
$p = Get-CertConnectProblem
Assert 'a port that does not answer: no session, and the reason' { $null -eq $s -and $p -like "1 attempt(s) in * s: 10.50.10.10: port 5986 didn't answer" }
& $cert { $script:FakeTcp = $true; $script:FakeLogon = 'Access is denied.' }
$s = Connect-CertGuest -Lab $L -Instance $dc0
$p = Get-CertConnectProblem
Assert 'a refused logon: each account and the reason' { $null -eq $s -and $p -like '*LAB\Administrator @ 10.50.10.10: Access is denied.*' -and $p -like '*LAB\svc-labdeploy @ 10.50.10.10: Access is denied.*' }
& $cert { $script:FakeLogon = $null; $script:FakeMacs = @('AABBCCDDEEFF') }
$s = Connect-CertGuest -Lab $L -Instance $dc0 3>$null
Assert 'another machine at the address: says whose MAC' { $null -eq $s -and (Get-CertConnectProblem) -like "*answers, but it isn't DC-261101-00: its MACs are AABBCCDDEEFF, not BC2411000001*" }
& $cert { $script:FakeMacs = @('', 'BC2411000001') }
Assert 'the right machine (an adapter without a MAC, like Tailscale, is fine)' { $null -ne (Connect-CertGuest -Lab $L -Instance $dc0) }
Assert 'Invoke-CertTarget takes -TimeoutSeconds (sysvol verify uses it)' { (Invoke-CertTarget -Context ([pscustomobject]@{ Lab = $L }) -Instance $dc0 -TimeoutSeconds 1 -ScriptBlock { 'ran' }) -eq 'ran' }
Assert 'every target answering: how long each took' { (Wait-CertGuests -Lab $L -Instances @($dc0, $dc1) -TimeoutSeconds 0) -match '^DC-261101-00 \d+ s, DC-261101-01 \d+ s$' }
& $cert { $script:FakeTcp = $false }
Assert-Throws "Can't reach says why" { Invoke-CertGuest -Lab $L -Instance $dc0 -TimeoutSeconds 0 -ScriptBlock { 'ran' } } "*Can't reach DC-261101-00*port 5986 didn't answer*"
Assert-Throws 'a target that does not answer stops the wait, with the reason' { Wait-CertGuests -Lab $L -Instances @($dc0) -TimeoutSeconds 0 } "*DC-261101-00 (10.50.10.10) didn't answer*within 0 s*port 5986*"
$modScript = Join-Path $tmp 'module-script.ps1'
Set-Content -Path $modScript -Value @'
param($Context)
"version $(Get-CertVersion)"
Invoke-CertTarget -Context $Context -Instance $Context.Targets.dc -TimeoutSeconds 1 -ScriptBlock { 'ran' }
'@
& $cert { $script:FakeTcp = $true }
$ctx = [pscustomobject]@{ Lab = $L; Targets = [ordered]@{ dc = $dc0 } }
$out = @(Invoke-CertModuleScript -Path $modScript -Context $ctx)
Assert "a module script sees CERT's own state and reaches a guest" { $out[0] -eq "version $(Get-CertVersion)" -and $out[1] -eq 'ran' }
$trap = [Collections.Generic.List[object]]::new()
try { & $cert { param($p, $c) & $p -Context $c } $modScript $ctx 2>$null | ForEach-Object { $trap.Add($_) } } catch { $trap.Add("threw: $($_.Exception.Message)") }
Assert "run from inside the module it would not (the 0.2.5 bug): CERT's state looks empty" { $trap[0] -eq 'version ' -and $trap[1] -like 'threw:*' }
& $cert { $script:FakeTcp = $true; $script:PveState[100] = 'stopped' }
$pdcNow = Get-CertPdcInstance -Lab $L
Assert 'the PDC lookup asks a running DC, not the one switched off' { $pdcNow.name -eq 'DC-261101-01' -and (@(& $cert { $script:AskedPdc }) -join ',') -eq '10.50.10.11' }
& $cert { $script:PveState[100] = 'running'; $script:FakeTcp = $false }
$throwMod = Join-Path $tmp 'throwing-verify'
New-Item -ItemType Directory -Path $throwMod -Force | Out-Null
Set-Content (Join-Path $throwMod 'verify.ps1') "param(`$Context)`nthrow 'no route to the DC'"
$brokenRun = [pscustomobject]@{ id = 'CERT-261123-1854-00'; state = 'Broken'; blind = $false; targets = [pscustomobject]@{}; expected = @(); timeline = @(); updated_utc = $null }
$tm = [pscustomobject]@{ Manifest = [pscustomobject]@{ expected_failures = @(); verify = 'verify.ps1' }; Path = $throwMod }
$took = Test-CertBreak -Config $config -Lab $L -Run $brokenRun -Module $tm 6>$null
Assert "a verify.ps1 that throws doesn't prove the break" { -not $took -and $brokenRun.timeline[-1].detail -like "*couldn't check: verify.ps1 threw: no route to the DC*" }
$failedRun = [pscustomobject]@{ id = 'CERT-261123-1649-00'; state = 'BreakFailed'; blind = $false; timeline = @(); updated_utc = $null }
$timeMod = @($mods | Where-Object Id -eq 'dc-time-skew')[0]
Assert 'a failed break is not checked' { -not (Test-CertBreak -Config $config -Lab $L -Run $failedRun -Module $timeMod 3>$null) -and @($failedRun.timeline).Count -eq 0 }
Assert-Throws 'nor handed to the clock' { Start-CertClock -Config $config -Run $failedRun } '*BreakFailed*'
& $cert {
    param($c)
    foreach ($n in 'Test-Connection', 'New-PSSession', 'Invoke-Command', 'Remove-PSSession') { Remove-Item "function:$n" }
    Set-Item function:script:Get-CertCredentials $c
} $realCreds

Write-Host "The engagement account in MGMT's Notes (fake Proxmox)"
& $cert { $script:PveDesc[121] = "Lab MGMT. **Don't** edit by hand." }
$noteRun = [pscustomobject]@{ id = 'CERT-261123-1752-00'; engagement = [pscustomobject]@{ access = 'domain-admin'; account = 'LAB\eng-261123175200'; upn = 'eng-261123175200@example.test'; password = 'Ab3#_*x`y' } }
$where = Set-CertEngagementNote -Lab $L -Run $noteRun
$desc = & $cert { $script:PveDesc[121] }
Assert 'written to MGMT, which says where' { $where -eq 'MGMT-261102-00, Proxmox Notes' }
Assert 'account and password in a code block, after the Notes already there' { $desc.StartsWith("Lab MGMT. **Don't** edit by hand.`n`n--- CERT run CERT-261123-1752-00: begin") -and $desc -match '(?s)```\nAccount:  LAB\\eng-261123175200\n.*Password: Ab3#_\*x`y\n```' }
$null = Set-CertEngagementNote -Lab $L -Run $noteRun
Assert 'written twice, still one block' { ([regex]::Matches((& $cert { $script:PveDesc[121] }), 'CERT run CERT-261123-1752-00: begin')).Count -eq 1 }
Assert "another run's block is left alone" { (Remove-CertNoteBlock -Text "x`n--- CERT run CERT-1: begin (the revert removes this) ---`ny`n--- CERT run CERT-1: end ---" -RunId 'CERT-2') -like '*CERT run CERT-1: end ---' }
Assert 'the revert takes the block out, and only it' { (Clear-CertEngagementNote -Lab $L -Run $noteRun) -like 'removed from MGMT-261102-00*' -and (& $cert { $script:PveDesc[121] }) -eq "Lab MGMT. **Don't** edit by hand." }
Assert 'nothing to take out: no change' { $null -eq (Clear-CertEngagementNote -Lab $L -Run $noteRun) }
& $cert { $script:PveDesc.Remove(121) }
$null = Set-CertEngagementNote -Lab $L -Run $noteRun
$null = Clear-CertEngagementNote -Lab $L -Run $noteRun
Assert 'Notes that were empty are empty again' { -not (& $cert { $script:PveDesc.ContainsKey(121) }) }

Write-Host 'SYSVOL after a revert (fake guests)'
& $cert {
    $script:GuestLog = [Collections.Generic.List[string]]::new()
    $script:Sysvol = @{ 'DC-261101-00' = 2; 'DC-261101-01' = 2 }
    $script:Repl = @{ 'DC-261101-00' = [pscustomobject]@{ Ok = 3; Bad = @(); Left = @() }; 'DC-261101-01' = [pscustomobject]@{ Ok = 3; Bad = @(); Left = @() } }
    function script:Get-CertPdcInstance { param($Lab) @($Lab.Instances | Where-Object name -eq 'DC-261101-00')[0] }
    function script:Invoke-CertGuest {
        param($Lab, $Instance, [scriptblock] $ScriptBlock, [object[]] $ArgumentList = @(), [int] $TimeoutSeconds)
        $t = $ScriptBlock.ToString()
        $n = $Instance.name
        if ($t -match 'Stop-Service DFSR') { $script:GuestLog.Add("stop:$n"); return }
        if ($t -match 'Start-Service DFSR') { $script:GuestLog.Add("start:$n"); return }
        if ($t -match 'msDFSR-Enabled') { $script:GuestLog.Add("sub:$($ArgumentList[0]):$($ArgumentList[1]):$($ArgumentList[2])"); return }
        if ($t -match 'Get-ADReplicationPartnerMetadata') { $script:GuestLog.Add("sync:$n"); return $script:Repl[$n] }
        if ($t -match 'Get-ADUser -Identity \$Sid') { $script:GuestLog.Add("has:$n"); return $script:HasAccount[$n] }
        if ($t -match 'pollad') { $script:Sysvol[$n] = 4; $script:GuestLog.Add("wait:$n"); return 4 }
        return $script:Sysvol[$n]
    }
}
$r = Repair-CertSysvol -Lab $L 6>$null
$log = @(& $cert { $script:GuestLog })
Assert 'stuck SYSVOL: re-synced from the PDC' { $r -like 'SYSVOL re-synced from DC-261101-00*' }
Assert 'stops DFSR everywhere first' { ($log[0..1] -join ',') -eq 'stop:DC-261101-00,stop:DC-261101-01' }
Assert 'PDC marked authoritative, the other disabled, then every DC pulls' { ($log[2..5] -join ',') -eq 'sub:DC-261101-00:False:True,sub:DC-261101-01:False:False,sync:DC-261101-00,sync:DC-261101-01' }
Assert 'PDC back to Normal before the other starts' { [array]::IndexOf([string[]] $log, 'wait:DC-261101-00') -lt [array]::IndexOf([string[]] $log, 'start:DC-261101-01') }
Assert 'the other enabled and waited for' { $log -contains 'sub:DC-261101-01:True:False' -and $log[-1] -eq 'wait:DC-261101-01' }
& $cert { $script:GuestLog.Clear() }
Assert 'healthy SYSVOL: nothing touched' { (Repair-CertSysvol -Lab $L) -like '*already normal*' -and @(& $cert { $script:GuestLog }).Count -eq 0 }
Assert 'replication sync: every DC pulls, and says so' { (Sync-CertDcReplication -Lab $L) -eq 'DC-261101-00: 3 partition(s) pulled | DC-261101-01: 3 partition(s) pulled' -and (@(& $cert { $script:GuestLog }) -join ',') -eq 'sync:DC-261101-00,sync:DC-261101-01' }
& $cert { $script:Repl['DC-261101-00'] = [pscustomobject]@{ Ok = 2; Bad = @('DC=DomainDnsZones: error 8440'); Left = @('DC-261101-01 error 1256') } }
$sr = Sync-CertDcReplication -Lab $L
Assert 'a partition that fails, and a count still standing, are reported' { $sr -like '*DC-261101-00: 2 partition(s) pulled; failed: DC=DomainDnsZones: error 8440; still failing from DC-261101-01 error 1256 |*' }
$L1 = Get-CertLab -Config $config
$L1.Instances = @($L1.Instances | Where-Object name -ne 'DC-261101-01')
Assert 'one DC: nothing to replicate' { (Sync-CertDcReplication -Lab $L1) -like 'single DC*' }
& $cert { $script:Repl['DC-261101-00'] = [pscustomobject]@{ Ok = 3; Bad = @(); Left = @() }; $script:HasAccount = @{ 'DC-261101-00' = $true; 'DC-261101-01' = $true }; $script:GuestLog.Clear() }
Assert 'engagement account on every DC: replicated first, then found on each' { (Confirm-CertEngagementReplicated -Lab $L -Sid 'S-1-5-21-1-2-3-1150' -TimeoutSeconds 0) -like 'on DC-261101-00, DC-261101-01 after*' -and (@(& $cert { $script:GuestLog }) -join ',') -eq 'sync:DC-261101-00,sync:DC-261101-01,has:DC-261101-00,has:DC-261101-01' }
& $cert { $script:HasAccount['DC-261101-01'] = $false }
Assert-Throws 'a DC without it stops the run before the break' { Confirm-CertEngagementReplicated -Lab $L -Sid 'S-1-5-21-1-2-3-1150' -TimeoutSeconds 0 } "*isn't on DC-261101-01*"

Write-Host 'Pre-flight'
$pf = Test-CertPreflight -Config $config -Lab $L -SkipBaseline
Assert 'a healthy fake lab passes' { $pf.Ok }
$L2 = Get-CertLab -Config $config
$L2.Instances[1].state = 'retiring'
$pf = Test-CertPreflight -Config $config -Lab $L2 -SkipBaseline
Assert 'refuses mid-rotation' { -not $pf.Ok -and @($pf.Errors -like '*mid-change*').Count -eq 1 }
$m = @($mods | Where-Object Id -eq 'fsmo-holder-lost')[0]
$L3 = Get-CertLab -Config $config
$L3.Instances = @($L3.Instances | Where-Object name -ne 'DC-261101-01')
$pf = Test-CertPreflight -Config $config -Lab $L3 -Module $m -SkipBaseline
Assert 'refuses a module whose roles are missing' { -not $pf.Ok -and @($pf.Errors -like '*needs 2 active DC*').Count -eq 1 }

Write-Host 'Run records and reports'
$run = [pscustomobject]@{
    id = 'CERT-261106-1830-00'; cert = '0.1.0'; state = 'InProgress'; blind = $false; owner = 'tester'; created_utc = '2026-11-06T18:30:00Z'; updated_utc = $null
    module = [pscustomobject]@{ key = 'cert/gpo-deleted'; id = 'gpo-deleted'; version = '1.0.0'; name = 'GPO deleted'; source = 'cert'; commit = 'abc1234'; path = (Join-Path $certRoot 'modules/gpo-deleted') }
    lab = [pscustomobject]@{ site = 'example-lab'; release = 'LAB-261105-04'; version = '1.5'; ledger_hash = $L.LedgerHash }
    set = @([pscustomobject]@{ name = 'DC-261101-00'; role = 'DC'; vmid = 100; node = 'pve01' })
    targets = [pscustomobject]@{ dc = @('DC-261101-00') }; assessor = $null
    snapshot = [pscustomobject]@{ name = 'CERT-261106-1830-00'; ram = $true }; baseline = @(); engagement = $null
    expected = @([pscustomobject]@{ id = 'LAPS-002'; seen = $true; on = @('DC-261101-00') }); checks = @(); notes = @()
    timeline = @(
        [pscustomobject]@{ at = '2026-11-06T18:40:00Z'; event = 'handed over'; detail = $null }
        [pscustomobject]@{ at = '2026-11-06T18:52:30Z'; event = 'cause identified'; detail = 'GPO gone' }
        [pscustomobject]@{ at = '2026-11-06T19:15:05Z'; event = 'repaired'; detail = 'check passed' }
    )
}
Save-CertRun -Config $config -Run $run
$s = Get-CertRunSummary -Run (Get-CertRun -Config $config -Id $run.id)
Assert 'time to cause' { $s.TimeToCause -eq '12m 30s' }
Assert 'time to repair' { $s.TimeToRepair -eq '35m 05s' }
$rep = Get-Content (Write-CertReport -Config $config -Run $run) -Raw
Assert 'report has the module and timeline' { $rep -match 'gpo-deleted' -and $rep -match 'cause identified' -and $rep -match '\[x\] `LAPS-002`' }
Assert 'no solution in the report while the run is open' { $rep -notmatch 'Reference solution' }
$run.state = 'Reverted'
Assert 'solution included once reverted' { (Get-Content (Write-CertReport -Config $config -Run $run) -Raw) -match 'Reference solution' }

Write-Host 'Fixture runs'
$fixDir = Join-Path $tmp 'fixture-verify'
New-Item -ItemType Directory -Path $fixDir -Force | Out-Null
Set-Content (Join-Path $fixDir 'verify.ps1') @'
param($Context)
New-CertCheck -Name 'users' -Passed $true -Detail "total=$($Context.Options.total)" -Severity Medium
New-CertCheck -Name 'locked-out' -Passed ($Context.Options.total -ne 13) -Detail 'planned 5, actual 4' -Severity Medium
'@
$fm = [pscustomobject]@{ Manifest = [pscustomobject]@{ kind = 'fixture'; expected_failures = @(); verify = 'verify.ps1' }; Path = $fixDir }
$fixRun = [pscustomobject]@{ id = 'CERT-261127-2200-00'; state = 'Built'; blind = $false; targets = [pscustomobject]@{}; expected = @(); checks = @(); timeline = @(); updated_utc = $null; options = [pscustomobject]@{ total = 50 }
    module = [pscustomobject]@{ id = 'fix'; name = 'Fixture'; version = '1.0.0'; kind = 'fixture'; source = 'cert'; path = $fixDir }; lab = [pscustomobject]@{ site = 's'; release = 'r'; version = '1.6' }; set = @(); snapshot = [pscustomobject]@{ name = 'CERT-261127-2200-00' }; notes = @(); engagement = $null; assessor = $null; cert = '0.3.0'; owner = 't' }
Assert 'a fixture that reads back as planned passes, and the options reach verify' { (Test-CertBreak -Config $config -Lab $L -Run $fixRun -Module $fm 6>$null) -and $fixRun.timeline[-1].event -eq 'fixture checked' -and $fixRun.timeline[-1].detail -eq 'all 2 check(s) match' -and $fixRun.checks[-1].results[0].detail -eq 'total=50' }
$fixRun.options = [pscustomobject]@{ total = 13 }
Assert 'a mismatch is a warning, kept in the checks' { -not (Test-CertBreak -Config $config -Lab $L -Run $fixRun -Module $fm 6>$null 3>$null) -and $fixRun.timeline[-1].detail -like "1 of 2 check(s) don't match: locked-out" -and @($fixRun.checks).Count -eq 2 }
Assert-Throws 'a fixture has no repair to check' { Test-CertRepair -Config $config -Lab $L -Run $fixRun -Module $fm } '*is a fixture*no repair*'
Assert-Throws 'nor a clock' { Start-CertClock -Config $config -Run $fixRun } '*fixture*no clock*'
Save-CertRun -Config $config -Run $fixRun
Set-Content (Join-Path (Get-CertRunsPath -Config $config) "$($fixRun.id)/password-pool.csv") 'x'
$frep = Get-Content (Write-CertReport -Config $config -Run $fixRun) -Raw
Assert 'fixture report: no time to repair; a Fixture section with the last read-back and the file' { $frep -notmatch 'Time to repair' -and $frep -match '## Fixture' -and $frep -match '\| locked-out \| warning \| planned 5, actual 4 \|' -and $frep -match 'password-pool\.csv' -and $frep -match '\| Options \| total=13 \|' -and $frep -notmatch 'Last repair check' }
Assert 'a scenario report is unchanged: no Fixture section' { (Get-Content (Write-CertReport -Config $config -Run $run) -Raw) -notmatch '## Fixture' }

Write-Host 'Odds and ends'
$pw = 1..20 | ForEach-Object { New-CertPassword }
Assert 'passwords: 24 characters, every class' { @($pw | Where-Object { $_.Length -eq 24 -and $_ -cmatch '[A-Z]' -and $_ -cmatch '[a-z]' -and $_ -match '\d' -and $_ -match '[^A-Za-z0-9]' }).Count -eq 20 }
Assert 'passwords differ' { @($pw | Select-Object -Unique).Count -eq 20 }
Assert 'snapshot name rules' { (Test-CertSnapshotName 'CERT-261106-1830-00') -and -not (Test-CertSnapshotName '1abc') -and -not (Test-CertSnapshotName ('A' * 41)) }
Assert 'durations' { (Format-CertDuration ([timespan]::FromSeconds(42))) -eq '42s' -and (Format-CertDuration ([timespan]::FromMinutes(135))) -eq '2h 15m' }

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-Host "$script:passed passed, $script:failed failed"
if ($script:failed) { exit 1 }
