# Extended port ACLs on the VM's vSwitch port are enforced by the host, so a guest cannot lift them.

# GpuVM's rules live in two weight blocks: the new one is filled before the old is removed. Other weights are the user's.
$script:IsolationWeightBlocks = @(20000, 20100)
$script:IsolationBlockSize = 100

function Get-GpuVMNetworkIsolation {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$State)
    # An agent machine is always isolated, whatever its config says.
    if ([string]$State['use'] -eq 'agent') { return $true }
    $network = $State['config']['vm']['network']
    # VMs created before this option are isolated too: only an explicit false turns it off.
    -not ($network -and $network.Contains('isolation') -and $network['isolation'] -eq $false)
}

function Get-GpuVMIsolationRules {
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$HostAddress)
    foreach ($address in $HostAddress) {
        # Moonlight on the host opens these; the replies are allowed by the flow it started.
        @{ Action = 'Allow'; Direction = 'Inbound'; RemoteIPAddress = $address; Protocol = 'TCP'; LocalPort = '47984-48010'; Stateful = $true }
        @{ Action = 'Allow'; Direction = 'Inbound'; RemoteIPAddress = $address; Protocol = 'UDP'; LocalPort = '47998-48010'; Stateful = $true }
        @{ Action = 'Allow'; Direction = 'Outbound'; RemoteIPAddress = $address; Protocol = 'UDP'; RemotePort = '67' }
        @{ Action = 'Allow'; Direction = 'Outbound'; RemoteIPAddress = $address; Protocol = 'UDP'; RemotePort = '53' }
        @{ Action = 'Allow'; Direction = 'Outbound'; RemoteIPAddress = $address; Protocol = 'TCP'; RemotePort = '53' }
    }
    # Private networks, link-local, CGNAT, multicast and all of IPv6 (the Default Switch only routes IPv4).
    foreach ($range in '10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '169.254.0.0/16', '100.64.0.0/10', '224.0.0.0/4', '::/0') {
        @{ Action = 'Deny'; Direction = 'Outbound'; RemoteIPAddress = $range }
    }
}

function Get-IsolationRuleKey {
    param([Parameter(Mandatory)]$Rule)
    $get = { param($n, $default) if ($Rule -is [System.Collections.IDictionary]) { if ($Rule.Contains($n)) { $Rule[$n] } else { $default } } else { $Rule.$n } }
    $port = { param($v) if (-not $v -or [string]$v -eq 'ANY') { 'ANY' } else { [string]$v } }
    $address = [string](& $get 'RemoteIPAddress' '') -replace '/32$', ''
    '{0}|{1}|{2}|{3}|{4}|{5}|{6}' -f (& $get 'Action' ''), (& $get 'Direction' ''), $address, ([string](& $get 'Protocol' 'ANY')).ToUpperInvariant(),
        (& $port (& $get 'LocalPort' $null)), (& $port (& $get 'RemotePort' $null)), [bool](& $get 'Stateful' $false)
}

function Get-GpuVMIsolationAcl {
    param([Parameter(Mandatory)][string]$Name)
    $low = $script:IsolationWeightBlocks[0]
    $high = $script:IsolationWeightBlocks[-1] + $script:IsolationBlockSize
    @(Get-VMNetworkAdapterExtendedAcl -VMName $Name | Where-Object { $_.Weight -ge $low -and $_.Weight -lt $high })
}

function Remove-GpuVMIsolationAcl {
    param([Parameter(Mandatory)][string]$Name, [object[]]$Acl)
    foreach ($rule in $Acl) { Remove-VMNetworkAdapterExtendedAcl -VMName $Name -Weight $rule.Weight -Direction $rule.Direction }
}

# The Default Switch changes the host's address on every host restart: called before every start.
function Update-GpuVMNetworkIsolation {
    param(
        [Parameter(Mandatory)][string]$Name,
        [System.Collections.IDictionary]$State
    )
    if (-not $State) { $State = Get-GpuVMState -Name $Name }
    # Every adapter of an agent machine: one on an external or private switch would put the guest on the LAN.
    if ([string]$State['use'] -eq 'agent') { Assert-AgentSwitch -Name $Name }
    $current = @(Get-GpuVMIsolationAcl -Name $Name)
    if (-not (Get-GpuVMNetworkIsolation -State $State)) {
        if ($current) { Remove-GpuVMIsolationAcl -Name $Name -Acl $current }
        return
    }

    # The first connected adapter: a disconnected first adapter left the others without rules.
    $connected = @(Get-VMNetworkAdapter -VMName $Name | Where-Object { $_.SwitchName })
    $switchName = if ($connected) { $connected[0].SwitchName } else { $null }
    if (-not $switchName) { return }
    # On an external switch the DHCP and DNS servers are on the LAN, which these rules block.
    $switch = Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue
    if ($switch -and $switch.SwitchType -ne 'Internal') {
        if ($current) { Remove-GpuVMIsolationAcl -Name $Name -Acl $current }
        Write-Warning "The VM '$Name' uses the external switch '$switchName': network isolation only works with the Default Switch or an internal one."
        return
    }
    # Without the host's address only the blocks apply: no network until the next start, rather than the LAN.
    $hostAddresses = @(try { (Get-GpuVMHostNetwork -Name $Name).Address } catch { Write-Warning $_.Exception.Message })
    $rules = @(Get-GpuVMIsolationRules -HostAddress $hostAddresses)

    $wanted = @($rules | ForEach-Object { Get-IsolationRuleKey $_ } | Sort-Object)
    $have = @($current | ForEach-Object { Get-IsolationRuleKey $_ } | Sort-Object)
    if ($current.Count -eq $rules.Count -and -not (Compare-Object $wanted $have)) { return }

    $free = @($script:IsolationWeightBlocks | Where-Object {
        $block = $_
        -not @($current | Where-Object { $_.Weight -ge $block -and $_.Weight -lt $block + $script:IsolationBlockSize }).Count
    })
    # Both blocks in use only after an interrupted update: start over.
    if (-not $free) {
        Remove-GpuVMIsolationAcl -Name $Name -Acl $current
        $current = @()
        $free = $script:IsolationWeightBlocks
    }
    $base = $free[0]
    # Higher weight wins: the allows go above the blocks.
    $weight = $base + $rules.Count
    foreach ($rule in $rules) {
        Add-VMNetworkAdapterExtendedAcl -VMName $Name -Weight $weight @rule
        $weight--
    }
    if ($current) { Remove-GpuVMIsolationAcl -Name $Name -Acl $current }
}

# Checked by the module's Start-VM and Restart-VM (GpuPower.ps1), so every way GpuVM turns a machine on checks it.
function Assert-AgentMachineSwitch {
    param([Parameter(Mandatory)][string]$Name)
    $state = try { Get-GpuVMState -Name $Name } catch { $null }
    if ($state -and [string]$state['use'] -eq 'agent') { Assert-AgentSwitch -Name $Name }
}

# An external or private switch would put the untrusted guest on the LAN or leave it unisolated.
function Assert-AgentSwitch {
    param([Parameter(Mandatory)][string]$Name)
    foreach ($adapter in @(Get-VMNetworkAdapter -VMName $Name)) {
        if (-not $adapter.SwitchName) { continue }
        $switch = Get-VMSwitch -Name $adapter.SwitchName -ErrorAction SilentlyContinue
        if (-not $switch -or $switch.SwitchType -ne 'Internal') {
            throw "'$Name' is an agent machine and its network adapter uses the switch '$($adapter.SwitchName)': agent machines only use the Default Switch or an internal one, where GpuVM isolates them."
        }
    }
}
