# Network isolation (labs/010): extended port ACLs on the VM's vSwitch port, enforced by the host, so a guest
# cannot lift them. The VM keeps internet, but reaches neither the LAN nor the host, except for the host's DHCP
# and DNS (Default Switch NAT) and the replies to the connections Moonlight opens to Sunshine (stateful rules).

# GpuVM's rules live in two weight blocks; new rules go into the free one before the old ones are removed,
# so the VM is never left without rules while it is running. Other weights belong to the user.
$script:IsolationWeightBlocks = @(20000, 20100)
$script:IsolationBlockSize = 100

function Get-GpuVMNetworkIsolation {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$State)
    $network = $State['config']['vm']['network']
    # VMs created before this option are isolated too: only an explicit false turns it off.
    -not ($network -and $network.Contains('isolation') -and $network['isolation'] -eq $false)
}

# The rules for a host reachable at the given IPv4 addresses on the VM's switch, highest priority first.
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

# One comparable line per rule, the same for a rule to add and one read back from Hyper-V.
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

# Applies (or removes) the isolation to match the VM's settings and the host's current address on its switch,
# which the Default Switch changes on every host restart. Called before every start, and when the option changes.
function Update-GpuVMNetworkIsolation {
    param(
        [Parameter(Mandatory)][string]$Name,
        [System.Collections.IDictionary]$State
    )
    if (-not $State) { $State = Get-GpuVMState -Name $Name }
    $current = @(Get-GpuVMIsolationAcl -Name $Name)
    if (-not (Get-GpuVMNetworkIsolation -State $State)) {
        if ($current) { Remove-GpuVMIsolationAcl -Name $Name -Acl $current }
        return
    }

    $switchName = (Get-VMNetworkAdapter -VMName $Name | Select-Object -First 1).SwitchName
    if (-not $switchName) { return }
    # On an external switch the DHCP and DNS servers are on the LAN, which these rules block.
    $switch = Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue
    if ($switch -and $switch.SwitchType -ne 'Internal') {
        if ($current) { Remove-GpuVMIsolationAcl -Name $Name -Acl $current }
        Write-Warning "La VM '$Name' usa el conmutador externo '$switchName': el aislamiento de red solo funciona con el Default Switch o uno interno."
        return
    }
    # Without the host's address there is nothing to allow: the blocks alone are applied (the VM gets no network
    # until the next start finds it, instead of reaching the LAN).
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
