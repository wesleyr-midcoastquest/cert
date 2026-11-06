<#
.SYNOPSIS
    dc-locator-records-deleted: does every DC's locator record resolve again,
    on every DC, and can the assessor find a DC?
#>
param([Parameter(Mandatory)] $Context)

$dcs = @($Context.Targets.dcs)
$domain = $Context.Lab.Inventory.identity.active_directory.domain
$names = @($dcs | ForEach-Object { "$($_.name).$domain".ToLower() })

foreach ($dc in $dcs) {
    $r = Invoke-CertTarget -Context $Context -Instance $dc -ArgumentList $domain -ScriptBlock {
        param($Domain)
        $q = [ordered]@{
            'dc-ldap'   = "_ldap._tcp.dc._msdcs.$Domain"
            'kerberos'  = "_kerberos._tcp.$Domain"
            'gc'        = "_gc._tcp.$Domain"
            'pdc'       = "_ldap._tcp.pdc._msdcs.$Domain"
            'kpasswd'   = "_kpasswd._tcp.$Domain"
        }
        $out = [ordered]@{}
        foreach ($k in $q.Keys) {
            $out[$k] = @(Resolve-DnsName -Name $q[$k] -Type SRV -Server 127.0.0.1 -DnsOnly -ErrorAction SilentlyContinue |
                Where-Object QueryType -eq 'SRV' | ForEach-Object { $_.NameTarget.ToLower() } | Sort-Object -Unique)
        }
        [pscustomobject] $out
    }
    foreach ($k in 'dc-ldap', 'kerberos', 'gc') {
        $missing = @($names | Where-Object { @($r.$k) -notcontains $_ })
        New-CertCheck -On $dc.name -Name "srv-$k" -Passed ($missing.Count -eq 0) -Detail $(if ($missing) { "missing: $($missing -join ', ')" } else { "$(@($r.$k).Count) target(s)" })
    }
    New-CertCheck -On $dc.name -Name 'srv-pdc' -Passed (@($r.pdc).Count -eq 1) -Detail "targets: $(@($r.pdc) -join ', ')"
    New-CertCheck -On $dc.name -Name 'srv-kpasswd' -Passed (@($r.kpasswd).Count -ge 1) -Detail "targets: $(@($r.kpasswd) -join ', ')" -Severity High
}

if ($Context.Assessor -and $Context.Assessor.Instance) {
    try {
        $found = Invoke-CertTarget -Context $Context -Instance $Context.Assessor.Instance -ArgumentList $domain -ScriptBlock {
            param($Domain)
            $o = & nltest.exe /dsgetdc:$Domain /force 2>&1 | Out-String
            if ($LASTEXITCODE -eq 0 -and $o -match 'DC: \\\\(\S+)') { $Matches[1] } else { $null }
        }
        New-CertCheck -On $Context.Assessor.Name -Name 'assessor-finds-dc' -Passed ([bool] $found) -Detail $(if ($found) { "found $found" } else { 'nltest /dsgetdc failed' })
    } catch { New-CertCheck -On $Context.Assessor.Name -Name 'assessor-finds-dc' -Passed $false -Detail $_.Exception.Message -Severity Medium }
}
