#Requires -Version 7.2
# CERT: break/fix scenarios for a MidCoast Lab.
#
# Runs on the lab's active MGMT (PowerShell 7). Reads the lab's own inventory
# (lab.yaml + site.yaml, merged by the lab's Lab.Inventory module) and ledger
# (instances.yaml); never writes to the lab repo.
#
# Requires: powershell-yaml, Microsoft.PowerShell.SecretManagement and the lab's
# KeePass vault (both already on every MGMT), git on PATH.

$script:CertVersion = '0.2.3'
$script:CertRoot    = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
# The lab release CERT was written against: the lab's compatibility number
# (lab.yaml version). Another minor is allowed with a warning; another major is refused.
$script:LabCompatibility = '1.6'

Import-Module powershell-yaml -ErrorAction Stop

foreach ($part in 'Config', 'Pve', 'Guest', 'Catalog', 'Run', 'Report') {
    . (Join-Path $PSScriptRoot "Cert.$part.ps1")
}

function Get-CertVersion { $script:CertVersion }
function Get-CertRoot    { $script:CertRoot }

Export-ModuleMember -Function *-Cert*
