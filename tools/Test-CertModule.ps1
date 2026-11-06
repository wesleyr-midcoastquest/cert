#Requires -Version 7.2
<#
.SYNOPSIS
    Checks scenario modules: manifest, files, and that every script parses.

.DESCRIPTION
    For contributors and CI; needs no lab. With -LabRoot (a midcoast-labs
    clone), expected_failures are also checked against the lab's validation
    catalog. Exits 1 if any module has a problem.

.PARAMETER Path
    A module folder, or a folder of modules (default: this repo's modules/).

.PARAMETER LabRoot
    A midcoast-labs clone, to check validation IDs against.

.EXAMPLE
    ./tools/Test-CertModule.ps1
.EXAMPLE
    ./tools/Test-CertModule.ps1 -Path ./modules/gpo-deleted -LabRoot ../midcoast-labs
#>
[CmdletBinding()]
param(
    [string] $Path = (Join-Path (Split-Path $PSScriptRoot -Parent) 'modules'),
    [string] $LabRoot
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'src/Cert/Cert.psm1') -Force -DisableNameChecking

$catalog = if ($LabRoot) { @(Get-CertLabCatalogIds -LabRoot $LabRoot) } else { @() }
if ($LabRoot -and -not $catalog) { throw "No validation catalog under $LabRoot (platform/validation/catalog.psd1)." }
$folders = if (Test-Path (Join-Path $Path 'module.yaml')) { @(Get-Item $Path) } else { @(Get-ChildItem -Path $Path -Directory | Sort-Object Name) }

$bad = 0
$ids = @{}
foreach ($f in $folders) {
    $mf = Join-Path $f.FullName 'module.yaml'
    if (-not (Test-Path $mf)) { Write-Host "SKIP  $($f.Name) (no module.yaml)"; continue }
    try { $m = Read-CertYaml -Path $mf; $problems = @(Test-CertManifest -Manifest $m -Folder $f.FullName -Catalog $catalog) }
    catch { $problems = @("module.yaml doesn't parse: $($_.Exception.Message)") }
    if ($m.id -and $ids.ContainsKey($m.id)) { $problems += "id $($m.id) is also used by $($ids[$m.id])" } elseif ($m.id) { $ids[$m.id] = $f.Name }
    if ($problems) {
        $bad++
        Write-Host "FAIL  $($f.Name)" -ForegroundColor Red
        foreach ($p in $problems) { Write-Host "      $p" }
    } else { Write-Host "OK    $($f.Name) $($m.version)" }
}
"{0} module(s), {1} with problems" -f $folders.Count, $bad
if ($bad) { exit 1 }
