<#
.SYNOPSIS
    fsmo-holder-lost: are all roles on a live DC, and is the lost DC gone from AD and DNS?
#>
param([Parameter(Mandatory)] $Context)

$victim = $Context.Targets.victim
$survivors = @(Get-CertActiveInstances -Lab $Context.Lab -Role 'DC' | Where-Object name -ne $victim.name)
$domain = $Context.Lab.Inventory.identity.active_directory.domain

foreach ($dc in $survivors) {
    $r = Invoke-CertTarget -Context $Context -Instance $dc -ArgumentList $victim.name, $domain -ScriptBlock {
        param($Victim, $Domain)
        $f = Get-ADForest -Server localhost; $d = Get-ADDomain -Server localhost
        $holders = @($f.SchemaMaster, $f.DomainNamingMaster, $d.PDCEmulator, $d.RIDMaster, $d.InfrastructureMaster)
        $onVictim = @($holders | Where-Object { $_ -like "$Victim.*" })
        $dcs = @(Get-ADDomainController -Filter * -Server localhost | ForEach-Object Name)
        $computer = Get-ADComputer -Filter "Name -eq '$Victim'" -Server localhost
        $ntds = Get-ADObject -SearchBase (Get-ADRootDSE -Server localhost).configurationNamingContext -LDAPFilter "(&(objectClass=server)(cn=$Victim))" -Server localhost
        $dns = @()
        foreach ($q in @("$Victim.$Domain", "_ldap._tcp.dc._msdcs.$Domain", "_kerberos._tcp.$Domain", "_ldap._tcp.pdc._msdcs.$Domain", $Domain)) {
            $type = if ($q -like '_*') { 'SRV' } elseif ($q -eq $Domain) { 'NS' } else { 'A' }
            $ans = @(Resolve-DnsName -Name $q -Type $type -Server 127.0.0.1 -DnsOnly -ErrorAction SilentlyContinue)
            $hit = @($ans | Where-Object { ($_.NameTarget -like "$Victim.*") -or ($_.NameHost -like "$Victim.*") -or ($q -eq "$Victim.$Domain" -and $_.IPAddress) })
            if ($hit) { $dns += "$q ($type)" }
        }
        [pscustomobject]@{
            OnVictim = $onVictim.Count; Holders = ($holders | Sort-Object -Unique) -join ', '
            VictimIsDc = ($dcs -contains $Victim); Computer = [bool] $computer; Server = [bool] $ntds
            Dns = $dns; Gc = (Get-ADDomainController -Identity $env:COMPUTERNAME -Server localhost).IsGlobalCatalog
        }
    }
    New-CertCheck -On $dc.name -Name 'fsmo-roles-live' -Passed ($r.OnVictim -eq 0) -Detail "holders: $($r.Holders)"
    New-CertCheck -On $dc.name -Name 'lost-dc-metadata-removed' -Passed (-not $r.VictimIsDc -and -not $r.Server) -Detail "still a DC in AD: $($r.VictimIsDc); server object in Sites: $($r.Server)"
    New-CertCheck -On $dc.name -Name 'lost-dc-computer-removed' -Passed (-not $r.Computer) -Detail "computer object present: $($r.Computer)" -Severity High
    New-CertCheck -On $dc.name -Name 'lost-dc-dns-removed' -Passed ($r.Dns.Count -eq 0) -Detail $(if ($r.Dns) { "still in DNS: $($r.Dns -join '; ')" } else { 'no records left' }) -Severity High
    New-CertCheck -On $dc.name -Name 'survivor-is-gc' -Passed ([bool] $r.Gc) -Detail "global catalog: $($r.Gc)"
}

# The PDC emulator is the domain's time source: it must sync from outside now.
$pdc = Get-CertPdcInstance -Lab $Context.Lab
$src = Invoke-CertTarget -Context $Context -Instance $pdc -ScriptBlock { (& w32tm.exe /query /source 2>&1 | Out-String).Trim() }
New-CertCheck -On $pdc.name -Name 'new-pdc-time-source' -Passed ($src -notmatch 'Local CMOS Clock|Free-running|VM IC' -and $src -notlike "$($victim.name)*") -Detail "source '$src'" -Severity High
