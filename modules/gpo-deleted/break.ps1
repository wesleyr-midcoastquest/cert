<#
.SYNOPSIS
    gpo-deleted: backs up every GPO to C:\GPO-Backups on the PDC (the "nightly
    backup"), then deletes MidCoast-LAPS-DSRM, links and all.
#>
param([Parameter(Mandatory)] $Context)

$gpo = 'MidCoast-LAPS-DSRM'
$r = Invoke-CertTarget -Context $Context -Instance $Context.Targets.dc -ArgumentList $gpo -ScriptBlock {
    param($Gpo)
    Import-Module GroupPolicy
    $g = Get-GPO -Name $Gpo -ErrorAction Stop
    $dir = Join-Path 'C:\GPO-Backups' ((Get-Date).AddHours(-7).ToString('yyyy-MM-dd'))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Backup-GPO -All -Path $dir -Comment 'Nightly GPO backup' | Out-Null
    Remove-GPO -Guid $g.Id -Confirm:$false
    [pscustomobject]@{ Guid = $g.Id.ToString(); Backup = $dir }
}
Save-CertModuleState -Context $Context -State @{ gpo = $gpo; guid = $r.Guid; backup = $r.Backup }
"deleted $gpo ($($r.Guid)); backup in $($r.Backup) on $($Context.Targets.dc.name)"
