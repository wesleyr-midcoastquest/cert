# Cert.Guest: WinRM/HTTPS sessions to lab guests, from MGMT.
#
# Same rules as the lab's orchestrator: HTTPS on 5986, Negotiate, and a
# session is only used if the guest has the VM's MAC address (an address can
# belong to another machine). Script blocks run in the guest's Windows
# PowerShell 5.1.

$known = (Get-Command New-PSSessionOption).Parameters.Keys
$opt = @{}
foreach ($kv in @{ SkipCACheck = $true; SkipCNCheck = $true; SkipRevocationCheck = $true; OperationTimeout = 300000; OpenTimeout = 30000 }.GetEnumerator()) {
    if ($known -contains $kv.Key) { $opt[$kv.Key] = $kv.Value }
}
$script:CertSessionOption = New-PSSessionOption @opt

function Connect-CertGuest {
    # A session to a ledger instance, or $null if none of its addresses and
    # none of CERT's credentials work. Why it failed (a port that didn't
    # answer, a refused logon, another machine's MAC) is kept for the caller:
    # Get-CertConnectProblem.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Lab,
        [Parameter(Mandatory)] $Instance,
        [int] $TimeoutSeconds = 0
    )
    $script:ConnectProblem = $null
    $problems = [ordered]@{}
    $note = { param($Text) if ($problems.Contains($Text)) { $problems[$Text]++ } else { $problems[$Text] = 1 } }
    $vm   = Get-CertPveVm -Lab $Lab -VmId ([int] $Instance.vmid)
    if (-not $vm) { $script:ConnectProblem = "VM $($Instance.vmid) isn't on Proxmox, or the token can't see it"; return $null }
    $want = @(Get-CertPveVmMac -Lab $Lab -Vm $vm)
    $started = Get-Date
    $deadline = $started.AddSeconds($TimeoutSeconds)
    $tries = 0
    do {
        $tries++
        $addresses = @(@($Instance.ipv4) + @(Get-CertPveVmAddress -Lab $Lab -Vm $vm) | Where-Object { $_ } | Select-Object -Unique)
        if (-not $addresses) { & $note 'no address, in the ledger or from the guest agent' }
        # MGMT reaching itself (the assessor is MGMT): loopback first. The lab's
        # WinRM rule allows MGMT's own addresses, but loopback needs no rule at all.
        if ($Instance.name -eq $env:COMPUTERNAME) { $addresses = @('localhost') + $addresses }
        foreach ($a in $addresses) {
            if (-not (Test-Connection -TargetName $a -TcpPort 5986 -TimeoutSeconds 3 -Quiet)) { & $note "${a}: port 5986 didn't answer"; continue }
            # The credential that worked last goes first: a scenario may have
            # changed the other's password, and every failed try counts
            # towards a lockout.
            $creds = @(Get-CertCredentials -Lab $Lab)
            $creds = @($creds | Where-Object { $_.UserName -eq $script:LastGoodUser }) + @($creds | Where-Object { $_.UserName -ne $script:LastGoodUser })
            foreach ($c in $creds) {
                $s = $null
                try {
                    $s = New-PSSession -ComputerName $a -Port 5986 -UseSSL -Authentication Negotiate -Credential $c `
                        -SessionOption $script:CertSessionOption -ErrorAction Stop
                } catch {
                    $msg = [string] (([string] $_.Exception.Message) -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
                    if ($msg.Length -gt 240) { $msg = $msg.Substring(0, 240) + '...' }
                    & $note "$($c.UserName) @ ${a}: $($msg.Trim())"
                    continue
                }
                Invoke-Command -Session $s -ScriptBlock { Set-ExecutionPolicy -Scope Process Bypass -Force -ErrorAction SilentlyContinue } -ErrorAction SilentlyContinue
                $have = @(Invoke-Command -Session $s -ScriptBlock {
                    Get-NetAdapter -ErrorAction SilentlyContinue | ForEach-Object { ($_.MacAddress -replace '[-:]', '').ToUpperInvariant() }
                } -ErrorAction SilentlyContinue)
                if ($want.Count -eq 0 -or @($have | Where-Object { $want -contains $_ }).Count -gt 0) { $script:LastGoodUser = $c.UserName; return $s }
                Remove-PSSession $s -ErrorAction SilentlyContinue
                & $note "${a} answers, but it isn't $($Instance.name): its MACs are $(@($have | Where-Object { $_ }) -join ','), not $($want -join ',')"
                Write-Warning "$a answers, but it isn't $($Instance.name) (MAC mismatch); ignoring it."
                break
            }
        }
        if ((Get-Date) -lt $deadline) { Start-Sleep -Seconds 15 }
    } while ((Get-Date) -lt $deadline)
    $seen = @($problems.GetEnumerator() | ForEach-Object { if ($_.Value -gt 1) { "$($_.Key) ($($_.Value) times)" } else { $_.Key } })
    $script:ConnectProblem = "$tries attempt(s) in $([int] ((Get-Date) - $started).TotalSeconds) s: $($seen -join '; ')"
    $null
}

function Get-CertConnectProblem {
    # Why the last Connect-CertGuest that returned $null failed.
    $script:ConnectProblem
}

function Wait-CertGuests {
    # Waits until every instance answers over WinRM/HTTPS. Returns how long
    # each took; throws with the reason when one doesn't answer in time.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Lab, [Parameter(Mandatory)] [object[]] $Instances, [int] $TimeoutSeconds = 300)
    $took = foreach ($i in $Instances) {
        $t0 = Get-Date
        $s = Connect-CertGuest -Lab $Lab -Instance $i -TimeoutSeconds $TimeoutSeconds
        if (-not $s) { throw "$($i.name) ($($i.ipv4)) didn't answer over WinRM/HTTPS within $TimeoutSeconds s ($(Get-CertConnectProblem))." }
        Remove-PSSession $s -ErrorAction SilentlyContinue
        "$($i.name) $([int] ((Get-Date) - $t0).TotalSeconds) s"
    }
    @($took) -join ', '
}

function Invoke-CertGuest {
    # Runs a script block on an instance and returns its output. Throws if the
    # instance can't be reached.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Lab,
        [Parameter(Mandatory)] $Instance,
        [Parameter(Mandatory)] [scriptblock] $ScriptBlock,
        [object[]] $ArgumentList = @(),
        [int] $TimeoutSeconds = 60
    )
    $s = Connect-CertGuest -Lab $Lab -Instance $Instance -TimeoutSeconds $TimeoutSeconds
    if (-not $s) { throw "Can't reach $($Instance.name) ($($Instance.ipv4)) over WinRM/HTTPS with the lab's credentials ($(Get-CertConnectProblem))." }
    try { Invoke-Command -Session $s -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList -ErrorAction Stop }
    finally { Remove-PSSession $s -ErrorAction SilentlyContinue }
}

function Test-CertGuestReachable {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Lab, [Parameter(Mandatory)] $Instance)
    $s = Connect-CertGuest -Lab $Lab -Instance $Instance
    if ($s) { Remove-PSSession $s; return $true }
    $false
}

function Invoke-CertLabValidation {
    # Runs the lab's own role validation on an instance (as SYSTEM, through the
    # same scheduled task the lab uses) and returns its report, or $null if the
    # machine has no lab validation (no validate.ps1) or can't be reached.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Lab, [Parameter(Mandatory)] $Instance, [int] $TimeoutSeconds = 900)
    $s = Connect-CertGuest -Lab $Lab -Instance $Instance
    if (-not $s) { return $null }
    try {
        Invoke-Command -Session $s -ArgumentList $TimeoutSeconds -ErrorAction Stop -ScriptBlock {
            param($TimeoutSeconds)
            $ErrorActionPreference = 'Stop'
            $script = 'C:\ProgramData\MidCoastLab\Platform\validate.ps1'
            if (-not (Test-Path $script)) { return $null }
            $task   = 'MidCoastLab-Validate'
            $latest = 'C:\ProgramData\MidCoastLab\Logs\Validation\latest.json'
            $before = if (Test-Path $latest) { (Get-Item $latest).LastWriteTimeUtc } else { [datetime]::MinValue }
            $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$script`""
            $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
            $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -MultipleInstances IgnoreNew
            Register-ScheduledTask -TaskName $task -Action $action -Principal $principal -Settings $settings -Force | Out-Null
            Start-ScheduledTask -TaskName $task
            $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
            do {
                Start-Sleep -Seconds 10
                $running = (Get-ScheduledTask -TaskName $task).State -eq 'Running'
                $fresh   = (Test-Path $latest) -and ((Get-Item $latest).LastWriteTimeUtc -gt $before)
            } while (($running -or -not $fresh) -and (Get-Date) -lt $deadline)
            if (-not $fresh) { throw "Validation did not produce a new report within $TimeoutSeconds s." }
            Get-Content -Path $latest -Raw | ConvertFrom-Json
        }
    } finally { Remove-PSSession $s -ErrorAction SilentlyContinue }
}

function Sync-CertGuestTime {
    # After a rollback a guest's clock is the snapshot's: set it from MGMT's
    # clock, then let w32time take over (the PDC emulator from its NTP source,
    # the others from the domain hierarchy).
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Lab, [Parameter(Mandatory)] $Instance)
    $utc = (Get-Date).ToUniversalTime().ToString('o')
    Invoke-CertGuest -Lab $Lab -Instance $Instance -TimeoutSeconds 300 -ArgumentList $utc -ScriptBlock {
        param($Utc)
        Set-Date -Date ([datetime]::Parse($Utc).ToLocalTime()) | Out-Null
        & w32tm.exe /resync /force 2>&1 | Out-Null
        "clock set to $((Get-Date).ToUniversalTime().ToString('u'))"
    }
}
