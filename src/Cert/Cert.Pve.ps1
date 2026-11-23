# Cert.Pve: the Proxmox API, with the lab's own provisioning token.
#
# CERT only ever snapshots, rolls back, powers and (link up/down) re-cables lab
# VMs. It has no function that deletes a VM or a disk, and modules must not add
# one: a deleted VM can't be rolled back.

$script:SnapshotPrefix = 'CERT'
$script:SnapshotRightsIssue = 'https://github.com/wesleyr-midcoastquest/midcoast-labs/issues/23'

function Get-CertPveToken {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Lab)
    if ($script:PveTokenCache -and $script:PveTokenSite -eq $Lab.Site) { return $script:PveTokenCache }
    $sa = $Lab.Inventory.proxmox.service_account
    $secret = Get-CertSecretText -Lab $Lab -Name $Lab.Inventory.secrets.entries.proxmox_terraform_token
    $script:PveTokenCache = "$($sa.user)!$($sa.token_name)=$secret"
    $script:PveTokenSite  = $Lab.Site
    $script:PveTokenCache
}

function Invoke-CertPve {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Lab,
        [Parameter(Mandatory)] [ValidateSet('GET', 'POST', 'PUT', 'DELETE')] [string] $Method,
        [Parameter(Mandatory)] [string] $Path,
        [hashtable] $Body
    )
    $token = Get-CertPveToken -Lab $Lab
    $p = @{
        Method               = $Method
        Uri                  = $Lab.Inventory.proxmox.endpoint.TrimEnd('/') + '/api2/json' + $Path
        Headers              = @{ Authorization = "PVEAPIToken=$token" }
        SkipHeaderValidation = $true
        SkipCertificateCheck = [bool] $Lab.Inventory.proxmox.insecure_tls
        ErrorAction          = 'Stop'
    }
    if ($Body) { $p.Body = $Body }
    try { (Invoke-RestMethod @p).data }
    catch {
        $secret = ($token -split '=', 2)[-1]
        $msg = "$($_.Exception.Message) $($_.ErrorDetails.Message)".Replace($secret, '<redacted>')
        if ($msg -match '403|Permission check failed' -and $Path -match '/snapshot') {
            throw "Proxmox refused a snapshot call ($Method $Path): the lab's provisioning role needs VM.Snapshot and VM.Snapshot.Rollback. See README, 'Proxmox rights', and $script:SnapshotRightsIssue."
        }
        throw "Proxmox API $Method $Path failed: $msg"
    }
}

function Wait-CertPveTask {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Lab, $Upid, [int] $TimeoutSeconds = 1800)
    if (-not $Upid -or "$Upid" -notmatch '^UPID:([^:]+):') { return }
    $node = $Matches[1]
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $s = Invoke-CertPve -Lab $Lab -Method GET -Path "/nodes/$node/tasks/$([uri]::EscapeDataString($Upid))/status"
        if ($s.status -eq 'stopped') {
            if ($s.exitstatus -ne 'OK' -and $s.exitstatus -notlike 'WARNINGS*') { throw "Proxmox task failed: $($s.exitstatus) ($Upid)" }
            return
        }
        Start-Sleep -Seconds 3
    }
    throw "Proxmox task timed out: $Upid"
}

function Get-CertPveVm {
    # The VM as the cluster sees it: node, status, name, tags, pool. $null if
    # the token can't see it.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Lab, [Parameter(Mandatory)] [int] $VmId)
    $all = Invoke-CertPve -Lab $Lab -Method GET -Path '/cluster/resources?type=vm'
    $v = @($all | Where-Object { [int] $_.vmid -eq $VmId })[0]
    if (-not $v) { return $null }
    [pscustomobject]@{
        VmId   = [int] $v.vmid
        Node   = [string] $v.node
        Name   = [string] $v.name
        Status = [string] $v.status
        Tags   = @(([string] $v.tags) -split '[;,\s]+' | Where-Object { $_ })
        Pool   = [string] $v.pool
        MaxMem = [long] $v.maxmem
    }
}

function Get-CertLabTag {
    # The tag the lab puts on its VMs. A lab release that names it in the
    # inventory (midcoast-labs#24) wins; today it's fixed.
    param([Parameter(Mandatory)] $Lab)
    if ($Lab.Inventory.proxmox.tag) { [string] $Lab.Inventory.proxmox.tag } else { 'midcoast-lab' }
}

function Assert-CertLabVm {
    # Refuses to touch a VM that isn't this lab's (tag or pool), or whose name
    # isn't the one the ledger has for that VMID.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Lab, [Parameter(Mandatory)] $Instance)
    $vm = Get-CertPveVm -Lab $Lab -VmId ([int] $Instance.vmid)
    if (-not $vm) { throw "VM $($Instance.vmid) ($($Instance.name)) isn't visible to the lab's Proxmox token." }
    $tag = Get-CertLabTag -Lab $Lab
    if (($vm.Tags -notcontains $tag) -and ($vm.Pool -ne $Lab.Inventory.proxmox.pool)) {
        throw "VM $($vm.VmId) isn't tagged $tag or in pool $($Lab.Inventory.proxmox.pool); not touching it."
    }
    if ($vm.Name -and $vm.Name -ne $Instance.name) {
        throw "VM $($vm.VmId) is named $($vm.Name) on Proxmox, but the ledger says $($Instance.name); not touching it."
    }
    $vm
}

function Invoke-CertPveVmAction {
    # Power actions: suspend (pause) | resume | stop (hard) | start | shutdown.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Lab,
        [Parameter(Mandatory)] $Vm,
        [Parameter(Mandatory)] [ValidateSet('suspend', 'resume', 'stop', 'start', 'shutdown')] [string] $Action
    )
    $upid = Invoke-CertPve -Lab $Lab -Method POST -Path "/nodes/$($Vm.Node)/qemu/$($Vm.VmId)/status/$Action"
    Wait-CertPveTask -Lab $Lab -Upid $upid -TimeoutSeconds 600
}

function Get-CertPveVmStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Lab, [Parameter(Mandatory)] $Vm)
    $s = Invoke-CertPve -Lab $Lab -Method GET -Path "/nodes/$($Vm.Node)/qemu/$($Vm.VmId)/status/current"
    # status: running | stopped; qmpstatus: running | paused | ...
    [pscustomobject]@{ Status = [string] $s.status; Qmp = [string] $s.qmpstatus }
}

function Set-CertPveVmLink {
    # Cable in or out: every network device's link_down flag. The config is part
    # of the snapshot, so a rollback restores it either way.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Lab, [Parameter(Mandatory)] $Vm, [Parameter(Mandatory)] [bool] $Up)
    $cfg = Invoke-CertPve -Lab $Lab -Method GET -Path "/nodes/$($Vm.Node)/qemu/$($Vm.VmId)/config"
    $body = @{}
    foreach ($p in $cfg.PSObject.Properties | Where-Object Name -match '^net\d+$') {
        $parts = @(([string] $p.Value) -split ',' | Where-Object { $_ -notmatch '^link_down=' })
        if (-not $Up) { $parts += 'link_down=1' }
        $body[$p.Name] = $parts -join ','
    }
    if ($body.Count -eq 0) { return }
    Invoke-CertPve -Lab $Lab -Method PUT -Path "/nodes/$($Vm.Node)/qemu/$($Vm.VmId)/config" -Body $body | Out-Null
}

function Get-CertPveVmMac {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Lab, [Parameter(Mandatory)] $Vm)
    $cfg = Invoke-CertPve -Lab $Lab -Method GET -Path "/nodes/$($Vm.Node)/qemu/$($Vm.VmId)/config"
    @($cfg.PSObject.Properties | Where-Object Name -match '^net\d+$' | ForEach-Object {
        if ([string] $_.Value -match '([0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5})') { $Matches[1].Replace(':', '').ToUpperInvariant() }
    })
}

function Get-CertPveVmAddress {
    # IPv4 addresses the guest agent reports (no loopback, link-local or tailnet).
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Lab, [Parameter(Mandatory)] $Vm)
    try {
        $r = Invoke-CertPve -Lab $Lab -Method GET -Path "/nodes/$($Vm.Node)/qemu/$($Vm.VmId)/agent/network-get-interfaces"
        @(@($r.result) | ForEach-Object { @($_.'ip-addresses') } |
            Where-Object { $_.'ip-address-type' -eq 'ipv4' -and $_.'ip-address' -notmatch '^(127\.|169\.254\.|100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.)' } |
            ForEach-Object { $_.'ip-address' })
    } catch { @() }
}

# ── Snapshots ─────────────────────────────────────────────────────────────

function Test-CertSnapshotName {
    # Proxmox: starts with a letter, letters/digits/_/-, at most 40 characters.
    param([string] $Name)
    $Name -match '^[A-Za-z][A-Za-z0-9_-]{1,39}$'
}

function New-CertSnapshotName {
    # CERT-<YYMMDD>-<HHMM>-<NN>, UTC, like the lab's own names.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Lab, [Parameter(Mandatory)] [object[]] $Vms)
    $stamp = (Get-Date).ToUniversalTime().ToString('yyMMdd-HHmm')
    $taken = @($Vms | ForEach-Object { Get-CertPveSnapshots -Lab $Lab -Vm $_ } | ForEach-Object name)
    for ($n = 0; $n -lt 100; $n++) {
        $name = '{0}-{1}-{2:D2}' -f $script:SnapshotPrefix, $stamp, $n
        if ($taken -notcontains $name) { return $name }
    }
    throw 'No free snapshot name.'
}

function Get-CertPveSnapshots {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Lab, [Parameter(Mandatory)] $Vm)
    @(Invoke-CertPve -Lab $Lab -Method GET -Path "/nodes/$($Vm.Node)/qemu/$($Vm.VmId)/snapshot" |
        Where-Object { $_.name -ne 'current' })
}

function New-CertPveSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Lab, [Parameter(Mandatory)] $Vm,
        [Parameter(Mandatory)] [string] $Name, [string] $Description, [bool] $IncludeRam = $true
    )
    if (-not (Test-CertSnapshotName $Name)) { throw "Invalid snapshot name: $Name" }
    $body = @{ snapname = $Name; description = $Description }
    if ($IncludeRam) { $body.vmstate = 1 }
    $upid = Invoke-CertPve -Lab $Lab -Method POST -Path "/nodes/$($Vm.Node)/qemu/$($Vm.VmId)/snapshot" -Body $body
    Wait-CertPveTask -Lab $Lab -Upid $upid -TimeoutSeconds 3600
}

function Restore-CertPveSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Lab, [Parameter(Mandatory)] $Vm, [Parameter(Mandatory)] [string] $Name)
    $upid = Invoke-CertPve -Lab $Lab -Method POST -Path "/nodes/$($Vm.Node)/qemu/$($Vm.VmId)/snapshot/$Name/rollback"
    Wait-CertPveTask -Lab $Lab -Upid $upid -TimeoutSeconds 3600
}

function Remove-CertPveSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Lab, [Parameter(Mandatory)] $Vm, [Parameter(Mandatory)] [string] $Name)
    if ($Name -notlike "$script:SnapshotPrefix-*") { throw "Not a CERT snapshot: $Name" }
    $upid = Invoke-CertPve -Lab $Lab -Method DELETE -Path "/nodes/$($Vm.Node)/qemu/$($Vm.VmId)/snapshot/$Name"
    Wait-CertPveTask -Lab $Lab -Upid $upid -TimeoutSeconds 3600
}

function Get-CertStorageUse {
    # Percent used of the lab's VM storage on each node in use; warns early,
    # because thin storage that runs out takes every VM on it down.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Lab, [Parameter(Mandatory)] [string[]] $Nodes)
    $storage = $Lab.Inventory.proxmox.storage.virtual_machines
    foreach ($n in $Nodes | Select-Object -Unique) {
        try {
            $s = Invoke-CertPve -Lab $Lab -Method GET -Path "/nodes/$n/storage/$storage/status"
            [pscustomobject]@{ Node = $n; Storage = $storage; UsedPercent = [math]::Round(100.0 * $s.used / [math]::Max([double] 1, [double] $s.total), 1); FreeGB = [math]::Round(($s.total - $s.used) / 1GB, 1) }
        } catch { [pscustomobject]@{ Node = $n; Storage = $storage; UsedPercent = $null; FreeGB = $null; Error = $_.Exception.Message } }
    }
}
