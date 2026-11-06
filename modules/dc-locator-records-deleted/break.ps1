<#
.SYNOPSIS
    dc-locator-records-deleted: deletes every SRV record under the _msdcs zone
    and the domain zone's _tcp, _udp and _sites records.
.DESCRIPTION
    Runs on one DC; the zones are AD-integrated, so the deletion replicates.
    Netlogon puts the records back on its own only when it restarts or at its
    next periodic registration (24 hours), so the lab stays broken for the run.
#>
param([Parameter(Mandatory)] $Context)

$dc = @($Context.Targets.dcs)[0]
$domain = $Context.Lab.Inventory.identity.active_directory.domain
Invoke-CertTarget -Context $Context -Instance $dc -ArgumentList $domain -ScriptBlock {
    param($Domain)
    $removed = 0
    $zones = @(
        @{ Zone = "_msdcs.$Domain"; Filter = { $true } },
        @{ Zone = $Domain;          Filter = { $_.HostName -like '_*' } }   # _ldap._tcp, _kerberos._udp, ..._sites
    )
    foreach ($z in $zones) {
        $recs = @(Get-DnsServerResourceRecord -ZoneName $z.Zone -RRType Srv -ErrorAction Stop | Where-Object $z.Filter)
        foreach ($r in $recs) { $r | Remove-DnsServerResourceRecord -ZoneName $z.Zone -Force; $removed++ }
    }
    "$removed SRV records deleted"
}
