<#
.SYNOPSIS
    gpo-deleted: is the policy back, with its settings, and linked to the
    Domain Controllers OU again?
#>
param([Parameter(Mandatory)] $Context)

$state = Get-CertModuleState -Context $Context
$dn = Get-LabDomainDN -Inventory $Context.Lab.Inventory
$r = Invoke-CertTarget -Context $Context -Instance $Context.Targets.dc -ArgumentList $state.gpo, "OU=Domain Controllers,$dn" -ScriptBlock {
    param($Gpo, $DcOu)
    Import-Module GroupPolicy
    $g = Get-GPO -Name $Gpo -ErrorAction SilentlyContinue
    $key = 'HKLM\Software\Microsoft\Windows\CurrentVersion\Policies\LAPS'
    $bd = if ($g) { (Get-GPRegistryValue -Name $Gpo -Key $key -ValueName 'BackupDirectory' -ErrorAction SilentlyContinue).Value } else { $null }
    $ds = if ($g) { (Get-GPRegistryValue -Name $Gpo -Key $key -ValueName 'ADBackupDSRMPassword' -ErrorAction SilentlyContinue).Value } else { $null }
    $link = @((Get-GPInheritance -Target $DcOu).GpoLinks | Where-Object DisplayName -eq $Gpo)[0]
    [pscustomobject]@{
        Exists = [bool] $g; Guid = if ($g) { $g.Id.ToString() } else { $null }; Status = if ($g) { [string] $g.GpoStatus } else { $null }
        BackupDirectory = $bd; Dsrm = $ds; Linked = [bool] $link; LinkEnabled = [bool] ($link -and $link.Enabled)
    }
}
$on = $Context.Targets.dc.name
New-CertCheck -On $on -Name 'gpo-exists' -Passed $r.Exists -Detail $(if ($r.Exists) { "$($state.gpo) $($r.Guid), $($r.Status)" } else { "$($state.gpo) not found" })
New-CertCheck -On $on -Name 'gpo-settings' -Passed ($r.BackupDirectory -eq 2 -and $r.Dsrm -eq 1) -Detail "BackupDirectory $($r.BackupDirectory), ADBackupDSRMPassword $($r.Dsrm)"
New-CertCheck -On $on -Name 'gpo-linked-to-dcs' -Passed ($r.Linked -and $r.LinkEnabled) -Detail "linked to Domain Controllers: $($r.Linked); link enabled: $($r.LinkEnabled)"
New-CertCheck -On $on -Name 'gpo-enabled' -Passed ($r.Status -in 'AllSettingsEnabled', 'UserSettingsDisabled') -Detail "status $($r.Status)" -Severity High
New-CertCheck -On $on -Name 'restored-not-recreated' -Passed ($r.Guid -eq $state.guid) -Detail "GUID $($r.Guid); before the incident $($state.guid)" -Severity Low
