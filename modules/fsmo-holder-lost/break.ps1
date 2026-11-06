<#
.SYNOPSIS
    fsmo-holder-lost: pulls the plug on the PDC emulator and its network cable.
.DESCRIPTION
    The VM is powered off hard and its network link set down, so it can't come
    back by itself. It isn't deleted: the revert brings it back.
#>
param([Parameter(Mandatory)] $Context)

$victim = $Context.Targets.victim
$roles = Invoke-CertTarget -Context $Context -Instance $victim -ScriptBlock {
    $f = Get-ADForest; $d = Get-ADDomain
    @($f.SchemaMaster, $f.DomainNamingMaster, $d.PDCEmulator, $d.RIDMaster, $d.InfrastructureMaster) -join ','
}
Save-CertModuleState -Context $Context -State @{ victim = $victim.name; roles_before = $roles }
Stop-CertTarget -Context $Context -Instance $victim
Set-CertTargetLink -Context $Context -Instance $victim -Up $false
