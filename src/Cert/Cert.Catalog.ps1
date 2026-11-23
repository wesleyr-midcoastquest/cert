# Cert.Catalog: scenario modules, where they come from, and keeping them current.
#
# A module is a folder with a module.yaml (docs/module-spec.md). Modules come
# from this repo's modules/ folder and from any extra sources in
# cert.config.yaml (git repos, cloned under sources/). Updating is always a
# fast-forward to a commit you've been shown and accepted: a module runs as a
# domain administrator on a Tier 0 machine, so nothing arrives unseen.

$script:Categories = @('ActiveDirectory', 'DNS', 'GroupPolicy', 'Replication', 'Time', 'Identity', 'Other')
$script:Selectors  = @('pdc', 'non-pdc-dc', 'any-dc', 'all-dcs', 'assessor')
$script:Access     = @('domain-admin', 'standard', 'none')

function Get-CertSources {
    # This repo first, then cert.config.yaml sources.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Config)
    [pscustomobject]@{ Name = 'cert'; Url = $null; Ref = $null; Root = $script:CertRoot; ModulePath = Join-Path $script:CertRoot 'modules' }
    foreach ($s in @($Config.sources | Where-Object { $_ })) {
        if ($s.name -notmatch '^[a-z0-9][a-z0-9-]{1,30}$' -or $s.name -eq 'cert') { Write-Warning "Source name '$($s.name)' isn't valid (lower case, digits, dashes; not 'cert'); skipped."; continue }
        $root = Join-Path $script:CertRoot "sources/$($s.name)"
        [pscustomobject]@{
            Name = [string] $s.name; Url = [string] $s.url; Ref = if ($s.ref) { [string] $s.ref } else { 'main' }
            Root = $root; ModulePath = Join-Path $root $(if ($s.path) { [string] $s.path } else { 'modules' })
        }
    }
}

function Compare-CertVersion {
    # -1 / 0 / 1 for dotted versions of any length ('1.5' vs '1.5.0' are equal).
    param([string] $A, [string] $B)
    $pa = @($A.Split('.') | ForEach-Object { [int] $_ }); $pb = @($B.Split('.') | ForEach-Object { [int] $_ })
    for ($i = 0; $i -lt [math]::Max($pa.Count, $pb.Count); $i++) {
        $x = if ($i -lt $pa.Count) { $pa[$i] } else { 0 }; $y = if ($i -lt $pb.Count) { $pb[$i] } else { 0 }
        if ($x -lt $y) { return -1 }; if ($x -gt $y) { return 1 }
    }
    0
}

function Test-CertRequirement {
    # '>=1.5' style; only >= is supported (a module states the oldest it needs).
    param([string] $Requirement, [string] $Have)
    if (-not $Requirement) { return $true }
    if ($Requirement -notmatch '^>=\s*(\d+(\.\d+){0,2})$') { throw "Unsupported requirement '$Requirement' (use >=x.y)." }
    (Compare-CertVersion $Have $Matches[1]) -ge 0
}

function Test-CertManifest {
    # Returns a list of problems (empty = valid). -Catalog: the lab's validation
    # IDs, to check expected_failures against.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Manifest, [Parameter(Mandatory)] [string] $Folder, [string[]] $Catalog)
    $e = [Collections.Generic.List[string]]::new()
    $m = $Manifest
    $leaf = Split-Path $Folder -Leaf
    if ($m.id -notmatch '^[a-z0-9][a-z0-9-]{2,48}$') { $e.Add("id '$($m.id)': lower case letters, digits and dashes, 3-49 characters") }
    elseif ($m.id -ne $leaf) { $e.Add("id '$($m.id)' must match its folder name '$leaf'") }
    if ($m.version -notmatch '^\d+\.\d+\.\d+$') { $e.Add("version '$($m.version)': use x.y.z") }
    foreach ($k in 'name', 'summary') { if (-not $m.$k) { $e.Add("$k is required") } }
    if ($m.summary -and $m.summary.Length -gt 100) { $e.Add('summary: 100 characters at most (it is one menu line)') }
    if ($m.category -notin $script:Categories) { $e.Add("category '$($m.category)': one of $($script:Categories -join ', ')") }
    if (-not ($m.difficulty -as [int]) -or [int] $m.difficulty -lt 1 -or [int] $m.difficulty -gt 5) { $e.Add('difficulty: 1 to 5') }
    if ($m.destructive -isnot [bool]) { $e.Add('destructive: true or false') }
    if (-not @($m.authors | Where-Object { $_ }).Count) { $e.Add('authors: at least one') }

    $r = $m.requires
    foreach ($k in 'cert', 'lab') {
        if ($r.$k) { try { Test-CertRequirement $r.$k '0' | Out-Null } catch { $e.Add("requires.${k}: $($_.Exception.Message)") } }
        else { $e.Add("requires.$k is required (e.g. '>=0.1')") }
    }
    if ($r.roles) {
        foreach ($p in $r.roles.PSObject.Properties) { if (-not ($p.Value -as [int]) -or [int] $p.Value -lt 1) { $e.Add("requires.roles.$($p.Name): a count of 1 or more") } }
    }

    $names = @()
    foreach ($t in @($m.targets)) {
        if (-not $t) { continue }
        if ($t.name -notmatch '^[a-z][a-z0-9_]{0,30}$') { $e.Add("target name '$($t.name)': lower case, starts with a letter") }
        if ($names -contains $t.name) { $e.Add("target '$($t.name)' is listed twice") }
        $names += $t.name
        if ($t.select -notin $script:Selectors -and $t.select -notmatch '^role:[A-Za-z0-9]+$') { $e.Add("target '$($t.name)' select '$($t.select)': one of $($script:Selectors -join ', ') or role:<ROLE>") }
        if ($t.select -eq 'assessor' -and -not $r.assessor) { $e.Add("target '$($t.name)' selects the assessor, so requires.assessor must be true") }
    }
    foreach ($x in @($m.exclude_from_validation | Where-Object { $_ })) { if ($names -notcontains $x) { $e.Add("exclude_from_validation '$x' isn't a target") } }

    $g = $m.engagement
    if ($g.access -notin $script:Access) { $e.Add("engagement.access '$($g.access)': one of $($script:Access -join ', ')") }
    foreach ($f in @(@('engagement.briefing', $g.briefing, $true), @('break', $m.break, $true), @('solution', $m.solution, $true), @('verify', $m.verify, $false))) {
        if (-not $f[1]) { if ($f[2]) { $e.Add("$($f[0]) is required") }; continue }
        if ($f[1] -match '[\\/]|\.\.') { $e.Add("$($f[0]) '$($f[1])': a file name in the module folder, not a path"); continue }
        if (-not (Test-Path (Join-Path $Folder $f[1]))) { $e.Add("$($f[0]) file '$($f[1])' is missing") }
    }
    foreach ($f in @($m.break, $m.verify) | Where-Object { $_ }) { if ($f -notmatch '\.ps1$') { $e.Add("'$f' must be a .ps1 script") } }

    $ids = @($m.expected_failures | Where-Object { $_ })
    if ($ids.Count -eq 0 -and -not $m.verify) { $e.Add('expected_failures or verify: a break has to be visible to at least one of them') }
    foreach ($id in $ids) {
        if ($id -notmatch '^[A-Z]+-\d{3}$') { $e.Add("expected_failures '$id': a validation ID like REPL-001") }
        elseif ($Catalog -and $Catalog -notcontains $id) { $e.Add("expected_failures '$id' isn't in the lab's validation catalog") }
    }

    # Scripts must parse (PowerShell 7 parser; guest script blocks inside are 5.1 code).
    foreach ($f in @($m.break, $m.verify) | Where-Object { $_ }) {
        $p = Join-Path $Folder $f
        if (Test-Path $p) {
            $tokens = $null; $errs = $null
            $ast = [Management.Automation.Language.Parser]::ParseFile($p, [ref] $tokens, [ref] $errs)
            foreach ($x in @($errs)) { $e.Add("${f}: line $($x.Extent.StartLineNumber): $($x.Message)") }
            foreach ($x in Find-CertNestedArgument -Ast $ast) { $e.Add("${f}: line ${x}: -ArgumentList wraps one of several values as (, `$x), so it arrives as an array inside an array; give it as it is") }
        }
    }
    $e.ToArray()   # callers wrap in @(): no output means valid
}

function Get-CertLabCatalogIds {
    # The lab's validation IDs (platform/validation/catalog.psd1), or @() if unreadable.
    [CmdletBinding()]
    param([string] $LabRoot)
    if (-not $LabRoot) { return @() }
    $p = Join-Path $LabRoot 'platform/validation/catalog.psd1'
    if (-not (Test-Path $p)) { return @() }
    try { @((Import-PowerShellDataFile -Path $p).Keys) } catch { @() }
}

function Find-CertNestedArgument {
    # Line numbers where -ArgumentList gives several values and wraps one of
    # them as (, $x). Each value already arrives as it is, so the wrapped one
    # arrives as an array inside an array (admin-passwords-changed 1.0.1).
    # Only a lone array argument needs (, $x).
    param([Parameter(Mandatory)] $Ast)
    $calls = $Ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in 'Invoke-CertTarget', 'Invoke-CertGuest', 'Invoke-Command' }, $true)
    foreach ($c in $calls) {
        $els = $c.CommandElements
        for ($k = 0; $k -lt $els.Count - 1; $k++) {
            if (-not ($els[$k] -is [Management.Automation.Language.CommandParameterAst] -and $els[$k].ParameterName -eq 'ArgumentList')) { continue }
            $v = $els[$k + 1]
            if (-not ($v -is [Management.Automation.Language.ArrayLiteralAst] -and $v.Elements.Count -gt 1)) { continue }
            foreach ($el in $v.Elements) {
                $inner = if ($el -is [Management.Automation.Language.ParenExpressionAst]) { @($el.Pipeline.PipelineElements)[0] } else { $null }
                # (, $x) parses as a one-element array literal.
                if ($inner -is [Management.Automation.Language.CommandExpressionAst] -and $inner.Expression -is [Management.Automation.Language.ArrayLiteralAst] -and
                    $inner.Expression.Elements.Count -eq 1) { $el.Extent.StartLineNumber }
            }
        }
    }
}

function Get-CertModules {
    # Every module from every source, valid or not (Problems lists why not).
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Config, [string] $LabRoot)
    $catalog = Get-CertLabCatalogIds -LabRoot $LabRoot
    foreach ($src in Get-CertSources -Config $Config) {
        if (-not (Test-Path $src.ModulePath)) { continue }
        foreach ($dir in Get-ChildItem -Path $src.ModulePath -Directory | Sort-Object Name) {
            $mf = Join-Path $dir.FullName 'module.yaml'
            if (-not (Test-Path $mf)) { continue }
            $problems = @(); $m = $null
            try { $m = Read-CertYaml -Path $mf } catch { $problems = @("module.yaml doesn't parse: $($_.Exception.Message)") }
            if ($m) { $problems = @(Test-CertManifest -Manifest $m -Folder $dir.FullName -Catalog $catalog) }
            $commit = $null
            if (Get-Command git -ErrorAction SilentlyContinue) { $commit = (& git -C $src.Root log -1 --format=%h -- $dir.FullName 2>$null) }
            [pscustomobject]@{
                Key        = "$($src.Name)/$($dir.Name)"
                Id         = if ($m) { [string] $m.id } else { $dir.Name }
                Version    = if ($m) { [string] $m.version } else { '?' }
                Name       = if ($m) { [string] $m.name } else { $dir.Name }
                Summary    = if ($m) { [string] $m.summary } else { '' }
                Category   = if ($m) { [string] $m.category } else { '' }
                Difficulty = if ($m) { [int] $m.difficulty } else { 0 }
                Source     = $src.Name
                Path       = $dir.FullName
                Commit     = $commit
                Manifest   = $m
                Problems   = $problems
                Valid      = ($problems.Count -eq 0)
            }
        }
    }
}

# ── Updating ──────────────────────────────────────────────────────────────

function Invoke-CertGit {
    param([Parameter(Mandatory)] [string] $Root, [Parameter(Mandatory)] [string[]] $Arguments)
    $out = & git -C $Root @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed in ${Root}: $($out -join ' ')" }
    $out
}

function Get-CertModuleVersionsAt {
    # id -> version for every module.yaml under a path, at a git revision.
    param([string] $Root, [string] $Rev, [string] $RelPath)
    $map = @{}
    $files = @(& git -C $Root ls-tree -r --name-only $Rev -- $RelPath 2>$null | Where-Object { $_ -match '/module\.yaml$' })
    foreach ($f in $files) {
        try {
            $m = ConvertFrom-Yaml -Yaml ((& git -C $Root show "${Rev}:$f" 2>$null) -join "`n")
            if ($m.id) { $map[[string] $m.id] = [string] $m.version }
        } catch { }
    }
    $map
}

function Get-CertUpdates {
    # What fetching each source would bring: commits, and modules added,
    # updated or removed. Fetches, never changes the working copy. A source
    # that isn't cloned yet is reported as new.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Config, [string[]] $Source)
    foreach ($src in Get-CertSources -Config $Config) {
        if ($Source -and $Source -notcontains $src.Name) { continue }
        $rel = [IO.Path]::GetRelativePath($src.Root, $src.ModulePath).Replace('\', '/')
        if (-not (Test-Path (Join-Path $src.Root '.git'))) {
            if ($src.Name -eq 'cert') { Write-Warning 'CERT itself is not a git clone; it can''t update itself. Clone it from GitHub instead of copying it.'; continue }
            [pscustomobject]@{ Source = $src.Name; State = 'not cloned'; Url = $src.Url; Ref = $src.Ref; Commits = @(); Changes = @(); Upstream = $null; Root = $src.Root }
            continue
        }
        try { Invoke-CertGit -Root $src.Root -Arguments @('fetch', '--quiet', 'origin') | Out-Null }
        catch {
            # One unreachable source doesn't stop the others.
            [pscustomobject]@{ Source = $src.Name; State = 'unreachable'; Url = $src.Url; Ref = $src.Ref; Commits = @(); Changes = @(); Upstream = $null; Root = $src.Root; Error = $_.Exception.Message }
            continue
        }
        $branch   = if ($src.Ref) { $src.Ref } else { (Invoke-CertGit -Root $src.Root -Arguments @('rev-parse', '--abbrev-ref', 'HEAD')).Trim() }
        $upstream = "origin/$branch"
        $ahead    = @(Invoke-CertGit -Root $src.Root -Arguments @('log', '--format=%h %an: %s', "HEAD..$upstream"))
        $before   = Get-CertModuleVersionsAt -Root $src.Root -Rev 'HEAD' -RelPath $rel
        $after    = Get-CertModuleVersionsAt -Root $src.Root -Rev $upstream -RelPath $rel
        $changes  = @(
            foreach ($id in $after.Keys | Sort-Object) {
                if (-not $before.ContainsKey($id)) { [pscustomobject]@{ Id = $id; Change = 'new'; From = $null; To = $after[$id] } }
                elseif ($before[$id] -ne $after[$id]) { [pscustomobject]@{ Id = $id; Change = 'updated'; From = $before[$id]; To = $after[$id] } }
            }
            foreach ($id in $before.Keys | Sort-Object) { if (-not $after.ContainsKey($id)) { [pscustomobject]@{ Id = $id; Change = 'removed'; From = $before[$id]; To = $null } } }
        )
        [pscustomobject]@{
            Source = $src.Name; State = if ($ahead.Count) { 'behind' } else { 'current' }; Url = $src.Url; Ref = $branch
            Commits = $ahead; Changes = $changes; Upstream = $upstream; Root = $src.Root
        }
    }
}

function Install-CertUpdate {
    # Applies one source's update: clone (new source) or fast-forward only.
    # Local edits in a source stop it; nothing is merged or overwritten.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Update)
    if ($Update.State -eq 'not cloned') {
        New-Item -ItemType Directory -Path (Split-Path $Update.Root -Parent) -Force | Out-Null
        $out = & git clone --quiet --branch $Update.Ref $Update.Url $Update.Root 2>&1
        if ($LASTEXITCODE -ne 0) { throw "git clone $($Update.Url) failed: $($out -join ' ')" }
        return "cloned $($Update.Source) ($($Update.Url) $($Update.Ref))"
    }
    if ($Update.State -ne 'behind') { return "$($Update.Source) is current" }
    if (Invoke-CertGit -Root $Update.Root -Arguments @('status', '--porcelain', '--untracked-files=no')) {
        throw "$($Update.Source) has local changes ($($Update.Root)); commit or discard them first (git status)."
    }
    Invoke-CertGit -Root $Update.Root -Arguments @('merge', '--ff-only', '--quiet', $Update.Upstream) | Out-Null
    "$($Update.Source) updated to $((Invoke-CertGit -Root $Update.Root -Arguments @('log', '-1', '--format=%h %s')))"
}
