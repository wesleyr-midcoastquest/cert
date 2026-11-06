# Cert.Config: CERT's own settings, and the lab it runs against.

function ConvertTo-CertObject {
    # YAML -> the same PSCustomObject shape the lab uses (round-trip through JSON).
    param($Yaml)
    if ($null -eq $Yaml) { return $null }
    $Yaml | ConvertTo-Json -Depth 30 | ConvertFrom-Json
}

function Read-CertYaml {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)
    if (-not (Test-Path $Path)) { throw "Not found: $Path" }
    ConvertTo-CertObject (ConvertFrom-Yaml -Yaml (Get-Content -Path $Path -Raw -Encoding UTF8))
}

function Get-CertConfig {
    # cert.config.yaml (this MGMT's settings, gitignored), on top of the
    # defaults in cert.config.example.yaml. A missing file means all defaults.
    [CmdletBinding()]
    param([string] $Path = (Join-Path $script:CertRoot 'cert.config.yaml'))
    $defaults = Read-CertYaml -Path (Join-Path $script:CertRoot 'cert.config.example.yaml')
    if (-not (Test-Path $Path)) { return $defaults }
    $local = Read-CertYaml -Path $Path
    Merge-CertObject -Base $defaults -Overlay $local
}

function Merge-CertObject {
    # Overlay wins; nested objects merge key by key; arrays are replaced whole.
    param($Base, $Overlay)
    if ($null -eq $Overlay) { return $Base }
    if ($null -eq $Base -or $Base -isnot [pscustomobject] -or $Overlay -isnot [pscustomobject]) { return $Overlay }
    $r = $Base | ConvertTo-Json -Depth 30 | ConvertFrom-Json
    foreach ($p in $Overlay.PSObject.Properties) {
        $cur = $r.PSObject.Properties[$p.Name]
        $val = if ($cur) { Merge-CertObject -Base $cur.Value -Overlay $p.Value } else { $p.Value }
        $r | Add-Member -NotePropertyName $p.Name -NotePropertyValue $val -Force
    }
    $r
}

# ── The lab ───────────────────────────────────────────────────────────────

function Get-CertLab {
    # The lab as CERT sees it: resolved inventory, ledger and its hash, release.
    # Read-only: CERT never writes to the lab repo.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Config)
    $root = [string] $Config.lab_repo
    $product = Join-Path $root 'inventory/lab.yaml'
    $site    = Join-Path $root 'inventory/site.yaml'
    $ledger  = Join-Path $root 'inventory/instances.yaml'
    foreach ($f in $product, $site, $ledger) {
        if (-not (Test-Path $f)) { throw "Lab file not found: $f. Set lab_repo in cert.config.yaml to the lab repo on this MGMT." }
    }
    # The lab's own resolver: the one place lab.yaml and site.yaml are merged.
    $invModule = Join-Path $root 'platform/modules/Lab.Inventory/Lab.Inventory.psm1'
    Import-Module $invModule -Force -DisableNameChecking -Global -ErrorAction Stop
    $inventory = Import-LabInventory -ProductPath $product -SitePath $site
    $raw = Get-Content -Path $ledger -Raw -Encoding UTF8
    [pscustomobject]@{
        Root          = $root
        Inventory     = $inventory
        Instances     = @(Get-LabInstances -Path $ledger)
        LedgerPath    = $ledger
        LedgerHash    = Get-CertTextHash -Text $raw
        Version       = [string] $inventory.version
        Release       = [string] $inventory.release
        Site          = [string] $inventory.site.name
    }
}

function Get-CertTextHash {
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)
    # Line endings and trailing whitespace don't count: git may rewrite them.
    $norm = (($Text -replace "`r", '') -split "`n" | ForEach-Object { $_.TrimEnd() }) -join "`n"
    $bytes = [Text.Encoding]::UTF8.GetBytes($norm.Trim())
    ([BitConverter]::ToString([Security.Cryptography.SHA256]::HashData($bytes)) -replace '-', '').ToLowerInvariant()
}

function Test-CertLabCompatibility {
    # Returns @{ Ok; Message }. Same major as LabCompatibility: OK (another
    # minor warns); another major: refused, CERT has to be updated first.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Lab)
    $want = [version] "$script:LabCompatibility.0"
    $have = $null
    if (-not [version]::TryParse("$($Lab.Version).0", [ref] $have)) {
        return @{ Ok = $false; Message = "Lab version '$($Lab.Version)' isn't a version number." }
    }
    if ($have.Major -ne $want.Major) {
        return @{ Ok = $false; Message = "Lab compatibility $($Lab.Version) is a different major version from the one CERT supports ($script:LabCompatibility). Update CERT first." }
    }
    if ($have.Minor -ne $want.Minor) {
        return @{ Ok = $true; Message = "Lab compatibility $($Lab.Version); CERT was written for $script:LabCompatibility. Expected to work; report anything that doesn't." }
    }
    @{ Ok = $true; Message = "Lab compatibility $($Lab.Version) ($($Lab.Release))" }
}

function Get-CertActiveInstances {
    # Active pipeline-tracked instances, optionally of one role.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Lab, [string] $Role)
    @($Lab.Instances | Where-Object { $_.state -eq 'active' -and (-not $Role -or $_.role -eq $Role) } |
        Sort-Object role, build_date, sequence)
}

function Get-CertAssessor {
    # The machine the fixer works from: the active instance of assessor.role, or
    # a fixed assessor.address for a machine the lab doesn't build. $null if neither.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Config, [Parameter(Mandatory)] $Lab)
    $a = $Config.assessor
    if ($a.address) {
        $inst = @($Lab.Instances | Where-Object { $_.ipv4 -eq $a.address })[0]
        return [pscustomobject]@{ Address = [string] $a.address; Instance = $inst; Name = if ($inst) { $inst.name } else { [string] $a.address } }
    }
    if ($a.role) {
        $inst = @(Get-CertActiveInstances -Lab $Lab -Role $a.role)[0]
        if ($inst) { return [pscustomobject]@{ Address = [string] $inst.ipv4; Instance = $inst; Name = $inst.name } }
    }
    $null
}

# ── Secrets (the lab's KeePass vault) ─────────────────────────────────────

function Get-CertSecretText {
    # Reads a vault entry; if the vault is locked, asks for its master password once.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Lab, [Parameter(Mandatory)] [string] $Name)
    $vault = $Lab.Inventory.secrets.vault
    try { $v = Get-Secret -Vault $vault -Name $Name -AsPlainText -ErrorAction Stop }
    catch {
        $first = $_.Exception.Message
        if (-not [Environment]::UserInteractive) { throw "Couldn't read '$Name' from vault $vault ($first). Run  Unlock-SecretVault -Name $vault  first." }
        Unlock-SecretVault -Name $vault -Password (Read-Host "KeePass master password for vault $vault" -AsSecureString)
        try { $v = Get-Secret -Vault $vault -Name $Name -AsPlainText -ErrorAction Stop }
        catch { throw "Couldn't read '$Name' from vault $vault after unlocking it: $($_.Exception.Message)" }
    }
    if ($v -is [pscredential]) { $v = $v.GetNetworkCredential().Password }
    if (-not $v) { throw "Vault entry '$Name' is empty." }
    [string] $v
}

function Get-CertCredentials {
    # Credentials CERT tries on a guest, in order. Two different Tier 0
    # accounts, so a scenario that changes one doesn't lock CERT out.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Lab)
    if ($script:CredCache -and $script:CredCacheSite -eq $Lab.Site) { return $script:CredCache }
    $inv = $Lab.Inventory
    $nb  = $inv.identity.active_directory.netbios
    $out = @()
    foreach ($pair in @(
            @("$nb\Administrator", $inv.secrets.entries.domain_administrator),
            @("$nb\svc-labdeploy", 'svc-labdeploy'))) {
        try {
            $pw = ConvertTo-SecureString (Get-CertSecretText -Lab $Lab -Name $pair[1]) -AsPlainText -Force
            $out += [pscredential]::new($pair[0], $pw)
        } catch { Write-Warning "Vault entry $($pair[1]): $($_.Exception.Message)" }
    }
    if ($out.Count -eq 0) { throw 'No usable guest credentials in the vault.' }
    $script:CredCache = $out
    $script:CredCacheSite = $Lab.Site
    $out
}
