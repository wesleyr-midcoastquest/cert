# Cert.Options: settings a module asks for before it runs, and module kinds.
#
# A module may list options in module.yaml (docs/module-spec.md). The menu
# prompts for each one before the snapshot; Start-CertRun -Options takes them
# from a script. Either way they're checked before anything in the lab
# changes, stored in the run record, and reach break.ps1 and verify.ps1 as
# $Context.Options. An optional options_check script (MGMT only, no lab
# access) holds the rules that span several options and writes the summary
# shown before "Snapshot the lab ...?". Get-CertModulePlan returns that
# summary without touching the lab: the module's -WhatIf.
#
# kind: scenario (the default) is a break/fix module. kind: fixture builds
# something in the lab to be looked at, not repaired: its verify.ps1 should
# pass right after the build, and there's no clock, cause or repair.

$script:Kinds       = @('scenario', 'fixture')
$script:OptionTypes = @('int', 'bool', 'string')

function Get-CertModuleKind {
    # 'scenario' or 'fixture', from a manifest (or a run record's module).
    param($Manifest)
    if ($Manifest -and $Manifest.PSObject.Properties['kind'] -and $Manifest.kind) { [string] $Manifest.kind } else { 'scenario' }
}

function Test-CertOptionManifest {
    # Problems with a manifest's options and options_check (empty = valid).
    param([Parameter(Mandatory)] $Manifest, [Parameter(Mandatory)] [string] $Folder)
    $e = [Collections.Generic.List[string]]::new()
    $names = @()
    foreach ($o in @($Manifest.options)) {
        if (-not $o) { continue }
        $n = [string] $o.name
        if ($n -notmatch '^[a-z][a-z0-9_]{0,30}$') { $e.Add("option name '$n': lower case, digits and underscores, starts with a letter"); continue }
        if ($names -contains $n) { $e.Add("option '$n' is listed twice") }
        $names += $n
        if ($o.type -notin $script:OptionTypes) { $e.Add("option '$n' type '$($o.type)': one of $($script:OptionTypes -join ', ')"); continue }
        $p = $o.PSObject.Properties['prompt']
        if (-not $p -or ($p.Value -is [bool] -and $p.Value) -or ($p.Value -isnot [bool] -and -not ([string] $p.Value).Trim())) { $e.Add("option '$n' prompt: the question to ask, or false for an option that is a parameter only") }
        foreach ($k in 'min', 'max') {
            if ($o.PSObject.Properties[$k] -and $null -ne $o.$k) {
                if ($o.type -ne 'int') { $e.Add("option '$n' ${k}: only for type int") }
                elseif ($o.$k -isnot [long] -and $o.$k -isnot [int]) { $e.Add("option '$n' ${k}: a whole number") }
            }
        }
        if ($o.type -eq 'int' -and $null -ne $o.min -and $null -ne $o.max -and $o.min -gt $o.max) { $e.Add("option '$n': min is more than max") }
        if ($o.PSObject.Properties['default'] -and $null -ne $o.default) {
            try { $null = ConvertTo-CertOptionValue -Option $o -Value $o.default } catch { $e.Add("option '$n' default: $($_.Exception.Message)") }
        }
    }
    $c = $Manifest.PSObject.Properties['options_check']
    if ($c -and $c.Value) {
        $f = [string] $c.Value
        if ($f -match '[\\/]|\.\.') { $e.Add("options_check '$f': a file name in the module folder, not a path") }
        elseif ($f -notmatch '\.ps1$') { $e.Add("'$f' must be a .ps1 script") }
        elseif (-not (Test-Path (Join-Path $Folder $f))) { $e.Add("options_check file '$f' is missing") }
        if (-not $names) { $e.Add('options_check without options: nothing to check') }
    }
    $e.ToArray()
}

function ConvertTo-CertOptionValue {
    # One option's value, typed and range-checked; throws a message a person
    # can act on. Text from a prompt and values from a script both come here.
    param([Parameter(Mandatory)] $Option, [AllowNull()] $Value)
    $n = $Option.name
    if ($null -eq $Value -or ($Value -is [string] -and $Value.Trim() -eq '')) { return $null }
    switch ([string] $Option.type) {
        'int' {
            $s = ([string] $Value).Trim()
            if ($Value -is [bool] -or $s -notmatch '^-?\d{1,10}$') { throw "$n must be a whole number, not '$Value'" }
            $v = [long] $s
            if ($v -gt [int]::MaxValue -or $v -lt [int]::MinValue) { throw "$n is too large" }
            $min = $Option.PSObject.Properties['min']; $max = $Option.PSObject.Properties['max']
            $lo = if ($min -and $null -ne $min.Value) { [long] $min.Value } else { $null }
            $hi = if ($max -and $null -ne $max.Value) { [long] $max.Value } else { $null }
            if (($null -ne $lo -and $v -lt $lo) -or ($null -ne $hi -and $v -gt $hi)) {
                $range = if ($null -ne $lo -and $null -ne $hi) { "$lo to $hi" } elseif ($null -ne $lo) { "$lo or more" } else { "$hi or less" }
                throw "$n must be $range, not $v"
            }
            return [int] $v
        }
        'bool' {
            if ($Value -is [bool]) { return $Value }
            $s = ([string] $Value).Trim()
            if ($s -match '^(y|yes|true|1)$') { return $true }
            if ($s -match '^(n|no|false|0)$') { return $false }
            throw "$n must be yes or no, not '$Value'"
        }
        default { return [string] $Value }
    }
}

function ConvertTo-CertOptionTable {
    # A run record's options (a PSCustomObject once read back from JSON) as
    # the ordered hashtable modules get in $Context.Options.
    param($Options)
    $t = [ordered]@{}
    if ($null -eq $Options) { return $t }
    if ($Options -is [Collections.IDictionary]) { foreach ($k in $Options.Keys) { $t[[string] $k] = $Options[$k] }; return $t }
    foreach ($p in $Options.PSObject.Properties) { $t[$p.Name] = $p.Value }
    $t
}

function Get-CertModulePlan {
    # A module's options with defaults filled in and every rule checked, and
    # the summary its options_check writes. Touches nothing in the lab; this
    # is how to see what a module would do (-WhatIf). -Lab is optional: with
    # it, the summary can name the lab's own OUs and domain.
    # Returns @{ Options (ordered hashtable); Errors; Summary }.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Module, [hashtable] $Options = @{}, $Lab)
    $m = $Module.Manifest
    $errors = [Collections.Generic.List[string]]::new()
    $known = @($m.options | Where-Object { $_ })
    foreach ($k in $Options.Keys) { if (@($known.name) -notcontains $k) { $errors.Add("$($m.id) has no option '$k'$(if ($known) { " (it has: $(@($known.name) -join ', '))" } else { '' })") } }
    $resolved = [ordered]@{}
    foreach ($o in $known) {
        $raw = if ($Options.ContainsKey($o.name)) { $Options[$o.name] } else { $o.default }
        try { $resolved[$o.name] = ConvertTo-CertOptionValue -Option $o -Value $raw } catch { $errors.Add($_.Exception.Message); $resolved[$o.name] = $null }
    }
    $summary = @()
    $check = if ($m.PSObject.Properties['options_check']) { [string] $m.options_check } else { $null }
    if ($check -and -not $errors.Count) {
        $inv = if ($Lab) { $Lab.Inventory } else { $null }
        $own = [psmoduleinfo]::new($true)
        try {
            $r = & $own { param($p, $o, $i) & $p -Options $o -Inventory $i } (Join-Path $Module.Path $check) $resolved $inv
            $r = @($r | Where-Object { $null -ne $_ })[-1]
            if ($r) {
                foreach ($x in @($r.Errors | Where-Object { $_ })) { $errors.Add([string] $x) }
                $summary = @($r.Summary | Where-Object { $null -ne $_ } | ForEach-Object { [string] $_ })
            }
        } catch { $errors.Add("$check threw: $($_.Exception.Message)") }
    }
    [pscustomobject]@{ Options = $resolved; Errors = $errors.ToArray(); Summary = $summary }
}

function Format-CertOptions {
    # name=value, ... for the timeline.
    param($Options)
    $t = ConvertTo-CertOptionTable $Options
    @($t.Keys | ForEach-Object { "$_=$(if ($null -eq $t[$_]) { '(not set)' } else { $t[$_] })" }) -join ', '
}
