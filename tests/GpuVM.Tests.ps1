# Tests that need neither administrator rights nor Hyper-V. Run: Invoke-Pester ./tests
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'src\GpuVM\GpuVM.psd1') -Force

# Pester 3.4's Should Throw does not catch exceptions in PowerShell 7.
function global:Test-Throws([scriptblock]$Block) { try { & $Block | Out-Null; $false } catch { $true } }

InModuleScope GpuVM {
    Describe 'Profiles' {
        It 'max-performance inherits from balanced and base' {
            $p = Resolve-GpuVMProfile -Name 'max-performance'
            ($p['chain'] -join ',') | Should Be 'base,balanced,max-performance'
            $p['vm']['cpu']['reservePercent'] | Should Be 100
            $p['vm']['network']['switch'] | Should Be 'Default Switch'
            $p['backend'] | Should Be 'hyperv-gpup'
        }

        It 'the override wins without touching the rest' {
            $p = Resolve-GpuVMProfile -Name 'balanced' -Override @{ vm = @{ cpu = @{ count = 4 } } }
            $p['vm']['cpu']['count'] | Should Be 4
            $p['vm']['cpu']['relativeWeight'] | Should Be 100
        }

        It 'lists are replaced entirely' {
            $p = Resolve-GpuVMProfile -Name 'max-performance'
            $p['guest']['optimizations'] -contains 'power-plan-high' | Should Be $false
            $p['guest']['optimizations'] -contains 'power-plan-ultimate' | Should Be $true
        }

        It 'all profiles are valid on this machine' {
            $logical = [int](Get-CimInstance Win32_Processor | Select-Object -First 1).NumberOfLogicalProcessors
            $memGB = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB
            foreach ($name in 'balanced', 'max-performance') {
                $problems = Test-GpuVMProfileData -Config (Resolve-GpuVMProfile $name) -HostLogicalProcessors $logical -HostMemoryGB $memGB
                ($problems -join ' ') | Should Be ''
            }
        }

        It 'detects out-of-range values' {
            $p = Resolve-GpuVMProfile -Name 'balanced' -Override @{ vm = @{ cpu = @{ count = 64 }; memoryGB = 2 } }
            $problems = Test-GpuVMProfileData -Config $p -HostLogicalProcessors 12 -HostMemoryGB 16
            $problems.Count | Should Be 2
        }

        It 'detects circular inheritance' {
            $dir = Join-Path $TestDrive 'profiles'
            New-Item -ItemType Directory $dir | Out-Null
            '{"extends":"b"}' | Set-Content (Join-Path $dir 'a.json')
            '{"extends":"a"}' | Set-Content (Join-Path $dir 'b.json')
            Test-Throws { Resolve-GpuVMProfile -Name 'a' -ProfileDirectory $dir } | Should Be $true
        }

        It 'all profiles use optimizations that exist in the guest' {
            . (Join-Path $script:RepoRoot 'guest\optimizations.ps1')
            foreach ($file in Get-ChildItem (Get-ProfileDirectory) -Filter *.json) {
                $p = Resolve-GpuVMProfile -Name $file.BaseName
                foreach ($opt in $p['guest']['optimizations']) { $GpuVMOptimizations.Contains($opt) | Should Be $true }
            }
        }
    }

    Describe 'Code review' {
        It 'Write-Step works without the app sink (CLI with StrictMode)' {
            Remove-Variable -Name GpuVMProgressSink -Scope Global -ErrorAction Ignore
            Test-Throws { Write-Step 'hello' 6>$null } | Should Be $false
        }

        It 'changing settings keeps what was configured before (Moonlight and previous overrides)' {
            $config = Resolve-GpuVMProfile -Name 'balanced' -Override @{ vm = @{ memoryGB = 6 } }
            $config['streaming']['client']['resolution'] = '2560x1440'
            $state = @{ config = $config }
            Mock Get-CimInstance { [pscustomobject]@{ TotalPhysicalMemory = 16GB; NumberOfLogicalProcessors = 12 } }
            $new = Resolve-GpuVMSettings -State $state -Override @{ vm = @{ cpu = @{ count = 6 } } }
            $new['vm']['cpu']['count'] | Should Be 6
            $new['vm']['memoryGB'] | Should Be 6
            $new['streaming']['client']['resolution'] | Should Be '2560x1440'
        }

        It 'switching profile keeps disk, folder and Moonlight preferences' {
            $config = Resolve-GpuVMProfile -Name 'max-performance'
            $config['vm']['disk']['type'] = 'Fixed'
            $config['streaming']['client']['fps'] = 120
            Mock Get-CimInstance { [pscustomobject]@{ TotalPhysicalMemory = 16GB; NumberOfLogicalProcessors = 12 } }
            $new = Resolve-GpuVMSettings -State @{ config = $config } -Profile 'balanced'
            $new['vm']['disk']['type'] | Should Be 'Fixed'
            $new['streaming']['client']['fps'] | Should Be 120
            $new['vm']['cpu']['reservePercent'] | Should Be 0
        }

        It 'validates before applying: rejects memory that leaves no headroom for the host' {
            Mock Get-CimInstance { [pscustomobject]@{ TotalPhysicalMemory = 16GB; NumberOfLogicalProcessors = 12 } }
            Test-Throws { Resolve-GpuVMSettings -State @{ config = (Resolve-GpuVMProfile 'balanced') } -Override @{ vm = @{ memoryGB = 14 } } } | Should Be $true
        }

        It 'passes Moonlight latency settings only if the profile defines them' {
            $a = Get-MoonlightStreamArguments -Address '1.2.3.4' -Client @{ app = 'Desktop'; vsync = $false; performanceOverlay = $true; framePacing = $null; displayMode = 'fullscreen' }
            ($a -join ' ') | Should Be 'stream 1.2.3.4 "Desktop" --no-vsync --performance-overlay --display-mode fullscreen --capture-system-keys fullscreen'
        }

        It 'passes the mouse mode of the use (a free pointer for movies and work)' {
            $a = Get-MoonlightStreamArguments -Address '1.2.3.4' -Client @{ app = 'Desktop'; vsync = $true; framePacing = $true; mouse = 'absolute' }
            ($a -join ' ') | Should Match '--vsync --frame-pacing --absolute-mouse'
            $b = Get-MoonlightStreamArguments -Address '1.2.3.4' -Client @{ app = 'Desktop'; mouse = 'capture' }
            ($b -join ' ') | Should Match '--no-absolute-mouse'
            $c = Get-MoonlightStreamArguments -Address '1.2.3.4' -Client @{ app = 'Desktop'; mouse = 'x --y' }
            ($c -join ' ') | Should Not Match 'mouse'
        }

        It 'streams at the monitor refresh rate when fps is 0' {
            $hz = Resolve-GpuVMStreamFps 0
            ($hz -ge 30 -and $hz -le 240) | Should Be $true
            Resolve-GpuVMStreamFps 120 | Should Be 120
            $a = Get-MoonlightStreamArguments -Address '1.2.3.4' -Client @{ app = 'Desktop'; fps = 0 }
            ($a -join ' ') | Should Match "--fps $hz( |$)"
        }

        It 'streams at the rate of the monitor it opens on, and lists the monitors' {
            Resolve-GpuVMStreamFps 0 -Hz 165 | Should Be 165
            Resolve-GpuVMStreamFps 0 -Hz 500 | Should Be 240
            Resolve-GpuVMStreamFps 0 -Hz 24 | Should Be 60
            Resolve-GpuVMStreamFps 90 -Hz 165 | Should Be 90
            # Without a desktop session (CI) there may be no monitors to read.
            $monitors = @(Get-HostMonitor)
            if ($monitors) {
                @($monitors | Where-Object { $_['primary'] }).Count | Should Be 1
                $monitors | ForEach-Object { $_['id'] | Should Not BeNullOrEmpty; $_['width'] -gt 0 | Should Be $true }
                (Resolve-HostMonitor -Monitor 'not-connected')['primary'] | Should Be $true
                (Resolve-HostMonitor -Monitor $monitors[-1]['id'])['id'] | Should Be $monitors[-1]['id']
            }
        }

        It 'waits for Windows to sign in, saying when it installs updates or restarts' {
            $script:answers = [System.Collections.Generic.Queue[object]]::new([object[]]@('updating', 'restart', 'signing-in', 'ready'))
            $script:steps = @()
            Mock Invoke-Guest { $a = $script:answers.Dequeue(); if ($a -eq 'restart') { throw 'the VM restarted' }; $a }
            Mock Write-Step { $script:steps += $Message }
            Mock Start-Sleep { }
            Mock Wait-GuestReady { $script:steps += "ready:$BootMessage" }
            Mock Open-GuestSession { }
            Mock Close-GuestSession { }
            Wait-GuestSignIn -Name vm -Credential ([pscredential]::new('u', (ConvertTo-SecureString 'p' -AsPlainText -Force))) | Should Be $true
            ($script:steps -join '|') | Should Be 'Finishing updates|Windows is restarting|ready:Windows is restarting|Signing in to Windows'
        }

        It 'remembers pending updates when GpuVM shuts a VM down, and never fails the shutdown' {
            $script:saved = $null
            Mock Get-GpuVMState { @{ name = 'vm'; guest = @{ user = 'u' } } }
            Mock Get-GpuVMGuestCredential { [pscredential]::new('u', (ConvertTo-SecureString 'p' -AsPlainText -Force)) }
            Mock Get-VM { [pscustomobject]@{ State = 'Running' } }
            Mock Save-GpuVMState { $script:saved = $State }
            Mock Test-GuestUpdatePending { $true }
            Register-GuestUpdateBeforeShutdown -Name vm | Should Be $true
            $script:saved['updatesPending'] | Should Be $true
            Mock Test-GuestUpdatePending { $false }
            Register-GuestUpdateBeforeShutdown -Name vm | Should Be $false
            Mock Test-GuestUpdatePending { throw 'no connection' }
            Register-GuestUpdateBeforeShutdown -Name vm | Should Be $false
        }

        It 'gives up waiting for the sign-in with a warning instead of hanging' {
            Mock Invoke-Guest { 'signing-in' }
            Mock Write-Step { }
            Mock Start-Sleep { }
            Mock Write-Warning { $script:warned = $true }
            $script:warned = $false
            Wait-GuestSignIn -Name vm -Credential ([pscredential]::new('u', (ConvertTo-SecureString 'p' -AsPlainText -Force))) -TimeoutSec 0 | Should Be $false
            $script:warned | Should Be $true
        }

        It 'data lives outside the code when installed; in the repo, in the repo' {
            $script:DataRoot | Should Be $script:RepoRoot
        }

        It 'the GpuVM folder is only trusted if administrators own it and only they can write' {
            $new = {
                param($owner, $vmRights)
                $acl = [System.Security.AccessControl.DirectorySecurity]::new()
                $acl.SetAccessRuleProtection($true, $false)
                $acl.SetOwner([Security.Principal.SecurityIdentifier]$owner)
                foreach ($sid in 'S-1-5-32-544', 'S-1-5-18') {
                    $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]$sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
                }
                $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]'S-1-5-83-0', $vmRights, 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
                $acl
            }
            Test-GpuVMRootAcl -Acl (& $new 'S-1-5-32-544' 'ReadAndExecute') | Should Be $true
            Test-GpuVMRootAcl -Acl (& $new 'S-1-5-32-545' 'ReadAndExecute') | Should Be $false
            Test-GpuVMRootAcl -Acl (& $new 'S-1-5-18' 'FullControl') | Should Be $false
            $userWrite = & $new 'S-1-5-32-544' 'ReadAndExecute'
            $userWrite.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]'S-1-5-11', 'Modify', 'Allow'))
            Test-GpuVMRootAcl -Acl $userWrite | Should Be $false
        }

        It 'rejects a Moonlight app name with quotes' {
            Test-Throws { Get-MoonlightStreamArguments -Address '1.2.3.4' -Client @{ app = 'Desktop" --x "y' } } | Should Be $true
        }
    }

    Describe 'Unattend' {
        $password = ConvertTo-SecureString 'P&ss<word>' -AsPlainText -Force
        $xml = New-UnattendXml -ComputerName 'WIN11' -UserName 'gpuvm' -Password $password -UILanguage 'es-ES' -TimeZone 'SA Pacific Standard Time'
        $doc = [xml]$xml
        $ns = @{ u = 'urn:schemas-microsoft-com:unattend' }

        It 'generates valid XML and escapes the password' {
            $doc | Should Not BeNullOrEmpty
            $xml | Should Match 'P&amp;ss&lt;word&gt;'
        }

        It 'uses the administrators group of the image language' {
            (Select-Xml -Xml $doc -XPath '//u:LocalAccount/u:Group' -Namespace $ns).Node.InnerText | Should Be 'Administradores'
        }

        It 'includes automatic logon and the guest script' {
            (Select-Xml -Xml $doc -XPath '//u:AutoLogon/u:Enabled' -Namespace $ns).Node.InnerText | Should Be 'true'
            $xml | Should Match 'C:\\GpuVM\\setup.ps1'
        }

        It 'omits automatic logon when disabled' {
            $plain = New-UnattendXml -ComputerName 'WIN11' -UserName 'gpuvm' -Password $password -UILanguage 'en-US' -AutoLogon $false
            $plain | Should Not Match '<AutoLogon>'
        }

        It 'limits the computer name to 15 valid characters' {
            ConvertTo-ComputerName 'Café gaming rig 2026' | Should Be 'CAFE-GAMING-RIG'
        }
    }

    Describe 'GPU-P' {
        It 'at 100 % uses the maximum of each resource' {
            $s = Get-GpuPartitionSettings -Percent 100
            $s['MaxPartitionVRAM'] | Should Be 1000000000
            $s['MaxPartitionEncode'] | Should Be ([uint64]::MaxValue)
            $s.Count | Should Be 12
        }

        It 'at 50 % assigns half' {
            (Get-GpuPartitionSettings -Percent 50)['OptimalPartitionCompute'] | Should Be 500000000
        }

        It 'copies the DriverStore to HostDriverStore and loose files to the same path' {
            $store = Join-Path $TestDrive 'src\nv_dispi.inf_amd64_test'
            New-Item -ItemType Directory $store -Force | Out-Null
            'dll' | Set-Content (Join-Path $store 'nvldumdx.dll')
            $loose = Join-Path $TestDrive 'src\nvapi64.dll'
            'api' | Set-Content $loose
            $guest = Join-Path $TestDrive 'guest'
            New-Item -ItemType Directory (Join-Path $guest 'Windows\System32\HostDriverStore\FileRepository\viejo') -Force | Out-Null

            $r = Copy-GpuDriverToWindows -FileSet ([pscustomobject]@{ DriverStoreFolders = @($store); Files = @($loose) }) -WindowsRoot "$guest\"
            $r.Files | Should Be 1
            Test-Path (Join-Path $guest 'Windows\System32\HostDriverStore\FileRepository\nv_dispi.inf_amd64_test\nvldumdx.dll') | Should Be $true
            Test-Path (Join-Path $guest 'Windows\System32\HostDriverStore\FileRepository\viejo') | Should Be $false
            Test-Path (Join-Path $guest $loose.Substring(3)) | Should Be $true
        }

        It 'does not write the driver through a link the guest planted' {
            $loose = Join-Path $TestDrive 'src\nvapi64.dll'
            $hostTarget = Join-Path $TestDrive 'host-system'
            New-Item -ItemType Directory $hostTarget -Force | Out-Null
            $guest = Join-Path $TestDrive 'evil-guest'
            New-Item -ItemType Directory (Join-Path $guest 'Windows') -Force | Out-Null
            # Windows\System32 in the guest is a junction to a "host" folder.
            New-Item -ItemType Junction -Path (Join-Path $guest 'Windows\System32') -Target $hostTarget | Out-Null
            $set = [pscustomobject]@{ DriverStoreFolders = @(); Files = @($loose) }
            Test-Throws { Copy-GpuDriverToWindows -FileSet $set -WindowsRoot "$guest\" } | Should Be $true
            @(Get-ChildItem $hostTarget -Recurse -Force).Count | Should Be 0
        }

        It 'removes guest folders without following the links inside them' {
            $outside = Join-Path $TestDrive 'outside'
            New-Item -ItemType Directory $outside -Force | Out-Null
            'keep' | Set-Content (Join-Path $outside 'keep.txt')
            $dir = Join-Path $TestDrive 'guest-dir'
            New-Item -ItemType Directory $dir -Force | Out-Null
            New-Item -ItemType Junction -Path (Join-Path $dir 'link') -Target $outside | Out-Null
            Remove-GuestDirectory -Path $dir
            Test-Path $dir | Should Be $false
            Test-Path (Join-Path $outside 'keep.txt') | Should Be $true
        }

        It 'the hyperv-gpup backend implements every operation' {
            $b = Get-GpuVMBackend 'hyperv-gpup'
            foreach ($op in $script:BackendOperations) { $b.Operations.ContainsKey($op) | Should Be $true }
        }
    }

    Describe 'Labs' {
        $env:GPUVM_LABS_ROOT = Join-Path $TestDrive 'labs'

        It 'creates, records and compares' {
            $lab = New-GpuVMLab -Title 'CPU test' -Hypothesis 'More threads, more FPS'
            $lab.Id | Should Be '001-cpu-test'
            Add-GpuVMLabResult -Lab 001 -Variant baseline -Metric 'FPS' -Value 100 | Out-Null
            Add-GpuVMLabResult -Lab 001 -Variant baseline -Metric 'FPS' -Value 110 | Out-Null
            $m = Add-GpuVMLabResult -Lab 001 -Variant candidate -Metric 'FPS' -Value 126
            $m.Baseline | Should Be 105
            $m.DeltaPct | Should Be 20
            $m.Better | Should Be $true
        }

        It 'understands metrics where lower is better' {
            Add-GpuVMLabResult -Lab 001 -Variant baseline -Metric 'Latency' -Value 20 -Unit ms -LowerIsBetter | Out-Null
            $m = Add-GpuVMLabResult -Lab 001 -Variant candidate -Metric 'Latency' -Value 15 -Unit ms -LowerIsBetter
            $m.Better | Should Be $true
        }

        It 'numbers the next lab and refuses results on a closed one' {
            (New-GpuVMLab -Title 'Other' -Hypothesis 'x').Id | Should Be '002-other'
            Close-GpuVMLab -Lab 001 -Status rejected -Conclusion 'No improvement' | Out-Null
            Test-Throws { Add-GpuVMLabResult -Lab 001 -Variant baseline -Metric 'FPS' -Value 1 } | Should Be $true
        }

        $env:GPUVM_LABS_ROOT = $null
    }

    Describe 'Streaming components' {
        $env:GPUVM_CACHE_ROOT = Join-Path $TestDrive 'cache'

        It 'the manifest pins version, GitHub URL and SHA-256 of each component' {
            $m = Get-ComponentManifest
            foreach ($key in 'sunshine', 'vdd', 'nefcon', 'usbip') {
                $m[$key]['sha256'] | Should Match '^[0-9a-f]{64}$'
                $m[$key]['url'] | Should Match "^https://github.com/$([regex]::Escape($m[$key]['repo']))/releases/download/"
                $m[$key]['file'] | Should Match $m[$key]['assetPattern']
            }
        }

        It 'uses the cached copy if its hash matches, without downloading' {
            $dir = Join-Path $env:GPUVM_CACHE_ROOT 'demo\1.0'
            New-Item -ItemType Directory $dir -Force | Out-Null
            'content' | Set-Content (Join-Path $dir 'demo.zip')
            $manifest = @{ demo = @{ version = '1.0'; file = 'demo.zip'; url = 'https://invalid.example/demo.zip'; sha256 = (Get-FileSha256 (Join-Path $dir 'demo.zip')) } }
            Save-GpuVMComponent -Name demo -Manifest $manifest | Should Be (Join-Path $dir 'demo.zip')
        }

        It 'rejects a tampered cached copy' {
            $manifest = @{ demo = @{ version = '1.0'; file = 'demo.zip'; url = 'https://invalid.example/demo.zip'; sha256 = ('0' * 64) } }
            Test-Throws { Save-GpuVMComponent -Name demo -Manifest $manifest } | Should Be $true
        }

        It 'does not update a component on hold' {
            Mock Get-ComponentManifest { @{ usbip = @{ version = 'v.0.9.8.0'; repo = 'vadimgrn/usbip-win2'; hold = 'lab 012' } } }
            Mock Invoke-RestMethod { throw 'no debe consultar GitHub' }
            Mock Write-JsonFile { throw 'no debe escribir' }
            Update-GpuVMComponent -Name usbip 3>$null | Should BeNullOrEmpty
            Assert-MockCalled Invoke-RestMethod -Times 0 -Scope It
        }

        $env:GPUVM_CACHE_ROOT = $null
    }

    Describe 'Streaming' {
        It 'the base profile includes Sunshine with a virtual display' {
            $p = Resolve-GpuVMProfile -Name 'balanced'
            $p['streaming']['provider'] | Should Be 'sunshine'
            (Get-StreamingComponentNames $p['streaming']) -join ',' | Should Be 'sunshine,vdd,usbip,nefcon'
        }

        It 'refuses to disable the Hyper-V display without a virtual display' {
            $p = Resolve-GpuVMProfile -Name 'balanced' -Override @{ streaming = @{ virtualDisplay = $false } }
            ((Test-GpuVMProfileData -Config $p) -join ' ') | Should Match 'disableHyperVVideo'
        }

        It 'prepares files and credentials: plain for the guest, encrypted for the host' {
            Mock Save-GpuVMComponent { "C:\cache\$Name.bin" }
            $payload = New-StreamingPayload -Config (Resolve-GpuVMProfile -Name 'balanced')
            @($payload.GuestFiles).Count | Should Be 4
            $guest = $payload.GuestJson['streaming\streaming-config.json']
            $guest['password'].Length | Should Be 24
            $payload.State['password'] | Should Not Be $guest['password']
            (Get-SunshineCredential -State @{ streaming = $payload.State }).GetNetworkCredential().Password | Should Be $guest['password']
        }

        It 'audio needs only usbip-win2, not nefcon' {
            $p = Resolve-GpuVMProfile -Name 'balanced' -Override @{ streaming = @{ virtualDisplay = $false; disableHyperVVideo = $false } }
            (Get-StreamingComponentNames $p['streaming']) -join ',' | Should Be 'sunshine,usbip'
            $p = Resolve-GpuVMProfile -Name 'balanced' -Override @{ streaming = @{ audio = 'none' } }
            (Get-StreamingComponentNames $p['streaming']) -join ',' | Should Be 'sunshine,vdd,nefcon'
        }

        It 'VMs created with VB-CABLE get the USB speaker' {
            Test-GpuVMAudio @{ audio = 'vbcable' } | Should Be $true
            Test-GpuVMAudio @{ audio = 'usb' } | Should Be $true
            Test-GpuVMAudio @{ audio = 'none' } | Should Be $false
            $p = Resolve-GpuVMProfile -Name 'balanced' -Override @{ streaming = @{ audio = 'vbcable' } }
            ((Test-GpuVMProfileData -Config $p) -join ' ') | Should Not Match 'streaming.audio'
        }

        It 'rejects an unknown audio option' {
            $p = Resolve-GpuVMProfile -Name 'balanced' -Override @{ streaming = @{ audio = 'steam' } }
            ((Test-GpuVMProfileData -Config $p) -join ' ') | Should Match 'streaming.audio'
        }

        It 'prepares nothing without a provider' {
            New-StreamingPayload -Config (Resolve-GpuVMProfile -Name 'balanced' -Override @{ streaming = @{ provider = 'none' } }) | Should BeNullOrEmpty
        }

        It 'builds the Moonlight arguments' {
            $a = Get-MoonlightStreamArguments -Address '172.20.1.5' -Client @{ app = 'Desktop'; resolution = '2560x1440'; fps = 120; bitrateKbps = 0; codec = 'HEVC' }
            ($a -join ' ') | Should Be 'stream 172.20.1.5 "Desktop" --resolution 2560x1440 --fps 120 --video-codec HEVC --capture-system-keys fullscreen'
        }

        It 'pairs by sending Sunshine the same PIN Moonlight receives, with Moonlight unelevated' {
            $script:sent = $null
            $script:checks = 0
            Mock Start-UnelevatedProcess { $script:moonlightArgs = $ArgumentList; $script:keepTask = [bool]$KeepTask; 'task' }
            # Moonlight keeps running until the PIN is sent, then exits with 0.
            Mock Get-UnelevatedTaskState { [pscustomobject]@{ Running = -not $script:sent; Finished = [bool]$script:sent; ExitCode = 0 } }
            Mock Remove-UnelevatedTask { $script:removed = $TaskName }
            Mock Test-SunshineClientPaired { $true }
            Mock Invoke-SunshineApi {
                [pscustomobject]@{ pairings = @(
                    [pscustomobject]@{ id = ('b' * 32); name = 'roth'; address = '172.20.1.9' }
                    [pscustomobject]@{ id = ('a' * 32); name = 'roth'; address = '::ffff:172.20.1.1' }
                ) }
            } -ParameterFilter { $Method -ne 'POST' }
            Mock Invoke-SunshineApi { $script:sent = $Body; [pscustomobject]@{ status = $true } } -ParameterFilter { $Method -eq 'POST' }

            $cred = [pscredential]::new('gpuvm', (ConvertTo-SecureString 'x' -AsPlainText -Force))
            Register-MoonlightPairing -Address '172.20.1.5' -Credential $cred -MoonlightPath 'moonlight.exe' -ClientName 'HOST' -HostAddress '172.20.1.1'
            $script:sent['pairing_id'] | Should Be ('a' * 32)
            $script:sent['pin'] | Should Be $script:moonlightArgs[3]
            $script:sent['name'] | Should Be 'HOST'
            $script:keepTask | Should Be $true
            $script:removed | Should Be 'task'
        }

        It 'does not hand the PIN to a pairing request from another device' {
            $other = [pscustomobject]@{ id = '1'; name = 'HOST'; address = '172.20.1.9' }
            Select-MoonlightPairingRequest -Pending @($other) -HostAddress '172.20.1.1' -ClientName 'HOST' | Should BeNullOrEmpty
            $named = [pscustomobject]@{ id = '2'; name = 'HOST' }
            (Select-MoonlightPairingRequest -Pending @($named) -HostAddress '172.20.1.1' -ClientName 'HOST').id | Should Be '2'
            Select-MoonlightPairingRequest -Pending @([pscustomobject]@{ id = '3'; name = 'x' }) -HostAddress '172.20.1.1' -ClientName 'HOST' | Should BeNullOrEmpty
        }

        It 'only trusts a guest IP inside the subnet of the host adapter' {
            Test-GuestAddressInHostSubnet -Address '172.20.1.5' -HostAddress '172.20.0.1' -PrefixLength 20 | Should Be $true
            Test-GuestAddressInHostSubnet -Address '172.20.16.5' -HostAddress '172.20.0.1' -PrefixLength 20 | Should Be $false
            Test-GuestAddressInHostSubnet -Address '172.20.0.1' -HostAddress '172.20.0.1' -PrefixLength 20 | Should Be $false
            Test-GuestAddressInHostSubnet -Address '127.0.0.1' -HostAddress '172.20.0.1' -PrefixLength 20 | Should Be $false
            Test-GuestAddressInHostSubnet -Address '8.8.8.8' -HostAddress '172.20.0.1' -PrefixLength 20 | Should Be $false
            Test-GuestAddressInHostSubnet -Address '172.20.15.255' -HostAddress '172.20.0.1' -PrefixLength 20 | Should Be $false
            Test-GuestAddressInHostSubnet -Address '172.20.0.0' -HostAddress '172.20.0.1' -PrefixLength 20 | Should Be $false
            Test-GuestAddressInHostSubnet -Address '172.20.1.300' -HostAddress '172.20.0.1' -PrefixLength 20 | Should Be $false
            Test-GuestAddressInHostSubnet -Address 'fe80::1' -HostAddress '172.20.0.1' -PrefixLength 20 | Should Be $false
            Test-GuestAddressInHostSubnet -Address '192.168.1.20' -HostAddress '192.168.1.10' -PrefixLength 24 | Should Be $true
        }

        It 'refuses to connect when the guest reports an IP outside the host network' {
            Mock Get-GpuVMHostNetwork { [pscustomobject]@{ Address = '172.20.0.1'; PrefixLength = 20 } }
            Mock Get-VMNetworkAdapter { [pscustomobject]@{ IPAddresses = @('10.0.0.5', 'fe80::1') } }
            Test-Throws { Get-GpuVMEndpoint -Name 'vm' -TimeoutSec 1 } | Should Be $true
            Mock Get-VMNetworkAdapter { [pscustomobject]@{ IPAddresses = @('172.20.3.7') } }
            $e = Get-GpuVMEndpoint -Name 'vm' -TimeoutSec 1
            $e.Address | Should Be '172.20.3.7'
            $e.HostAddress | Should Be '172.20.0.1'
        }

        It 'reduces values from the guest to short strings' {
            ConvertTo-GuestString ('x' * 500) -MaxLength 10 | Should Be ('x' * 10)
            ConvertTo-GuestString "a`nb`e[31m" | Should Be 'a b [31m'
            ConvertTo-GuestString ([pscustomobject]@{ a = 1 }) | Should Be ''
            ConvertTo-GuestString $null | Should Be ''
        }

        It 'updates sunshine.conf through the API only when a value changes, keeping the other keys' {
            $cred = [pscredential]::new('gpuvm', (ConvertTo-SecureString 'x' -AsPlainText -Force))
            Mock Invoke-SunshineApi { [pscustomobject]@{ encoder = 'nvenc'; virtual_sink = 'Altavoces (VB-Audio Virtual Cable)'; version = '1' } } -ParameterFilter { $Method -ne 'POST' }
            Mock Invoke-SunshineApi { if ($Path -eq '/api/config') { $script:posted = $Body } } -ParameterFilter { $Method -eq 'POST' }
            Mock Wait-SunshineReady { }
            Mock Start-Sleep { }
            $script:posted = $null
            Update-SunshineConfig -Address '172.20.1.5' -Credential $cred -Settings ([ordered]@{ virtual_sink = 'Altavoces (VB-Audio Virtual Cable)' }) | Should Be $false
            $script:posted | Should Be $null
            Update-SunshineConfig -Address '172.20.1.5' -Credential $cred -Settings ([ordered]@{ output_name = '{d54a}' }) | Should Be $true
            $script:posted['output_name'] | Should Be '{d54a}'
            $script:posted['encoder'] | Should Be 'nvenc'
            $script:posted.Contains('version') | Should Be $false
        }

        It 'finds the virtual display in the Sunshine log' {
            $log = @(
                '[2026-10-26 23:12:31.210]: Info: Currently available display devices:'
                '['
                '  { "device_id": "{c16d}", "display_name": "\\\\.\\DISPLAY1", "edid": null, "info": { "primary": true } },'
                '  { "device_id": "{d54a}", "display_name": "\\\\.\\DISPLAY2", "edid": { "manufacturer_id": "MTT" }, "info": { "primary": false } }'
                ']'
                '[2026-10-26 23:12:31.300]: Info: something else'
            )
            $devices = ConvertFrom-SunshineDisplayLog -Lines $log
            $devices.Count | Should Be 2
            ($devices | Where-Object { $_.edid -and $_.edid.manufacturer_id -eq 'MTT' }).device_id | Should Be '{d54a}'
        }

        It 'installs the guest speaker only when it is missing or its server changed' {
            $cred = [pscredential]::new('gpuvm', (ConvertTo-SecureString 'x' -AsPlainText -Force))
            Mock Invoke-Command { 'ok' }
            Mock Save-GpuVMComponent { throw 'must not download' }
            Install-GuestAudio -Name 'vm' -Credential $cred | Should Be $false
            Assert-MockCalled Save-GpuVMComponent -Times 0 -Scope It

            Mock Invoke-Command { 'error: the GpuVM Audio output doesn''t show up' }
            Test-Throws { Install-GuestAudio -Name 'vm' -Credential $cred } | Should Be $true

            Mock Invoke-Command { 'install' } -ParameterFilter { $VMName }
            Mock Invoke-Command { 'ok' } -ParameterFilter { $Session }
            Mock Save-GpuVMComponent { 'C:\cache\usbip\USBip-0.9.8.0-x64.exe' }
            Mock New-PSSession { [Runtime.Serialization.FormatterServices]::GetUninitializedObject([System.Management.Automation.Runspaces.PSSession]) }
            Mock Copy-Item { $script:copied += @($LiteralPath) }
            Mock Remove-PSSession { }
            Mock Write-Step { }
            $script:copied = @()
            Install-GuestAudio -Name 'vm' -Credential $cred | Should Be $true
            ($script:copied | Split-Path -Leaf) -join ',' | Should Be 'USBip-0.9.8.0-x64.exe,UsbAudioServer.cs'
        }

        It 'the guest server only listens on loopback and caps what a client can send' {
            $source = Get-Content -Raw (Join-Path $script:RepoRoot 'guest\audio\UsbAudioServer.cs')
            $source | Should Match 'new TcpListener\(IPAddress\.Loopback'
            $source | Should Not Match 'IPAddress\.Any'
            $source | Should Match 'oversized request'
        }

        It 'sunshine.conf: replaces existing keys and appends new ones' {
            . (Join-Path $script:RepoRoot 'guest\streaming.ps1')
            $conf = Join-Path $TestDrive 'sunshine.conf'
            "encoder = software`r`nport = 47989" | Set-Content $conf
            Set-SunshineConfig -Path $conf -Settings ([ordered]@{ encoder = 'nvenc'; adapter_name = 'NVIDIA GeForce RTX 4060' })
            $lines = Get-Content $conf
            $lines | Should Be @('encoder = nvenc', 'port = 47989', 'adapter_name = NVIDIA GeForce RTX 4060')
        }
    }

    Describe 'User profiles, ISO library and apps' {
        $originalData = $script:DataRoot
        $script:DataRoot = Join-Path $TestDrive 'data'
        New-Item -ItemType Directory $script:DataRoot | Out-Null

        It 'saves a user profile on top of a built-in one and resolves it' {
            Save-GpuVMProfile -Name 'juegos' -Settings @{ cpu = 6; memoryGB = 6; diskGB = 250; apps = @('steam'); displayMode = 'windowed'; iso = 'D:\ISOs\win10.iso' } | Out-Null
            $p = Resolve-GpuVMProfile -Name 'juegos'
            ($p['chain'] -join ',') | Should Be 'base,balanced,max-performance,juegos'
            $p['vm']['disk']['sizeGB'] | Should Be 250
            $p['vm']['disk']['type'] | Should Be 'Dynamic'
            $p['guest']['apps'] | Should Be @('steam')
            $s = ConvertTo-ProfileSettings $p
            $s['displayMode'] | Should Be 'windowed'
            $s['iso'] | Should Be 'D:\ISOs\win10.iso'
            (Get-GpuVMProfile | Where-Object Name -eq 'juegos').BuiltIn | Should Be $false
        }

        It 'rejects built-in names, unknown apps and invalid values' {
            Test-Throws { Save-GpuVMProfile -Name 'balanced' -Settings @{ cpu = 4 } } | Should Be $true
            Test-Throws { Save-GpuVMProfile -Name 'x' -Settings @{ apps = @('nope') } } | Should Be $true
            Test-Throws { Save-GpuVMProfile -Name 'x' -Settings @{ memoryGB = 2 } } | Should Be $true
        }

        It 'renames and deletes user profiles, but not built-in ones' {
            Save-GpuVMProfile -Name 'juegos-2' -Previous 'juegos' -Settings @{ cpu = 6 } | Out-Null
            Test-Path (Join-Path (Get-UserProfileDirectory) 'juegos.json') | Should Be $false
            Remove-GpuVMProfile -Name 'juegos-2'
            Test-Throws { Remove-GpuVMProfile -Name 'balanced' } | Should Be $true
        }

        It 'remembers used ISOs first and forgets them without deleting the file' {
            $iso = Join-Path $TestDrive 'Win10.iso'
            'x' | Set-Content $iso
            Register-GpuVMIsoUse -Path $iso -VMName 'win10'
            $first = @(Get-GpuVMIsoList)[0]
            $first['name'] | Should Be 'Win10.iso'
            $first['remembered'] | Should Be $true
            $first['usedBy'] | Should Be @('win10')
            Remove-GpuVMIso -Path $iso
            @(Read-IsoLibrary).Count | Should Be 0
            Test-Path $iso | Should Be $true
        }

        It 'every catalog app has a download URL, a signer or hash, a known category and an install check' {
            $categories = Get-AppCategory
            foreach ($app in Get-GpuVMApp) {
                $entry = (Get-AppCatalog)[$app['id']]
                $entry['url'] | Should Match '^https://'
                [bool]($entry['signer'] -or $entry['sha256'] -match '^[0-9A-Fa-f]{64}$') | Should Be $true
                $categories.Contains($entry['category']) | Should Be $true
                $app['categoryName'] | Should Not BeNullOrEmpty
                $entry['installed'] | Should Not BeNullOrEmpty
                # Uninstall finds the app in Windows' list of programs and runs its uninstaller silently, or opens it.
                $entry['uninstall']['match'] | Should Not BeNullOrEmpty
                [regex]::new($entry['uninstall']['match']) | Should Not BeNullOrEmpty
                [bool]($entry['uninstall']['interactive'] -or $entry['uninstall'].Contains('args')) | Should Be $true
            }
        }

        It 'remembers installed apps per VM and keeps the list when it changes' {
            $state = [ordered]@{ statePath = Join-Path $TestDrive 'apps-state.json' }
            Mock Get-GpuVMState { $s = Read-JsonFile $state['statePath']; $s['statePath'] = $state['statePath']; $s }
            Write-JsonFile -Path $state['statePath'] -Data ([ordered]@{ installedApps = @('steam') })
            Update-InstalledAppState -Name vm -Installed discord, steam
            @((Read-JsonFile $state['statePath'])['installedApps']) -join ',' | Should Be 'steam,discord'
            Update-InstalledAppState -Name vm -Removed steam
            @((Read-JsonFile $state['statePath'])['installedApps']) -join ',' | Should Be 'discord'
            Update-InstalledAppState -Name vm -Installed chrome -Replace
            @((Read-JsonFile $state['statePath'])['installedApps']) -join ',' | Should Be 'chrome'
        }

        It 'reinstall does not install over an app whose uninstall failed' {
            Mock Start-GuestForApp { [pscredential]::new('u', (ConvertTo-SecureString 'p' -AsPlainText -Force)) }
            Mock Assert-Admin { }
            Mock Uninstall-GuestApp { foreach ($id in $App) { [ordered]@{ app = $id; status = $(if ($id -eq 'steam') { 'failed' } else { 'uninstalled' }) } } }
            Mock Install-GuestApp { foreach ($id in $App) { [ordered]@{ app = $id; status = 'installed' } } }
            $results = @(Install-GpuVMApp -Name vm -App steam, discord -Reinstall)
            Assert-MockCalled Install-GuestApp -Times 1 -ParameterFilter { ($App -join ',') -eq 'discord' }
            ($results | ForEach-Object { "$($_['app'])=$($_['status'])" }) -join ',' | Should Be 'steam=failed,discord=installed'
        }

        It 'every cleanup item has a known level, a description and something to do' {
            . (Get-RepoPath 'guest\cleanup.ps1')
            foreach ($name in $GpuVMCleanup.Keys) {
                $item = $GpuVMCleanup[$name]
                @('privacy', 'apps', 'minimal') -contains $item['Level'] | Should Be $true
                $item['Description'] | Should Not BeNullOrEmpty
                [bool]($item['Registry'] -or $item['Services'] -or $item['Packages'] -or $item['Script']) | Should Be $true
            }
        }

        It 'cleanup never touches Defender, Windows Update, SmartScreen, UAC, the firewall or the Store' {
            . (Get-RepoPath 'guest\cleanup.ps1')
            $text = ($GpuVMCleanup.Values | ForEach-Object {
                    @($_['Registry'] | Where-Object { $_ } | ForEach-Object { "$($_['Path'])\$($_['Name'])" }) + @($_['Services'] | Where-Object { $_ } | ForEach-Object { $_['Name'] }) + @($_['Packages']) + "$($_['Script'])"
                }) -join "`n"
            $text | Should Not Match 'Defender|WinDefend|wuauserv|WindowsUpdate|UsoSvc|SmartScreen|EnableLUA|MpsSvc|Firewall|SecHealth|WindowsStore|DesktopAppInstaller|GamingApp|Xbox'
        }

        It 'lists the cleanup levels in order, each with its items' {
            $levels = @(Get-GpuVMCleanup)
            ($levels | ForEach-Object { $_['id'] }) -join ',' | Should Be 'none,privacy,apps,minimal'
            $levels[0]['items'].Count | Should Be 0
            foreach ($level in $levels[1..3]) { $level['items'].Count | Should BeGreaterThan 0 }
        }

        $script:DataRoot = $originalData
    }

    Describe 'Network isolation' {
        $acl = { param($w, $action, $dir, $ip, $proto = 'ANY', $local = 'ANY', $remote = 'ANY', $stateful = $false)
            [pscustomobject]@{ Weight = $w; Action = $action; Direction = $dir; RemoteIPAddress = $ip; Protocol = $proto; LocalPort = $local; RemotePort = $remote; Stateful = $stateful } }
        # What Hyper-V returns after the rules for a host at $ip were applied from weight $base.
        $applied = { param($ip, $base)
            $rules = @(Get-GpuVMIsolationRules -HostAddress $ip)
            $w = $base + $rules.Count
            foreach ($r in $rules) {
                $p = if ($r.Contains('Protocol')) { $r['Protocol'] } else { 'ANY' }
                $l = if ($r.Contains('LocalPort')) { $r['LocalPort'] } else { 'ANY' }
                $rp = if ($r.Contains('RemotePort')) { $r['RemotePort'] } else { 'ANY' }
                & $acl $w $r['Action'] $r['Direction'] $r['RemoteIPAddress'] $p $l $rp ([bool]$r['Stateful'])
                $w--
            }
        }
        $state = @{ config = @{ vm = @{ network = @{ switch = 'Default Switch' } } } }

        It 'is on unless it was turned off explicitly' {
            Get-GpuVMNetworkIsolation -State $state | Should Be $true
            Get-GpuVMNetworkIsolation -State @{ config = @{ vm = @{} } } | Should Be $true
            Get-GpuVMNetworkIsolation -State @{ config = @{ vm = @{ network = @{ isolation = $false } } } } | Should Be $false
        }

        It 'blocks private networks, multicast and IPv6, and lets only DHCP, DNS and Moonlight replies reach the host' {
            $rules = @(Get-GpuVMIsolationRules -HostAddress '172.29.96.1')
            $deny = @($rules | Where-Object { $_['Action'] -eq 'Deny' })
            foreach ($range in '10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '169.254.0.0/16', '100.64.0.0/10', '224.0.0.0/4', '::/0') {
                @($deny | Where-Object { $_['RemoteIPAddress'] -eq $range -and $_['Direction'] -eq 'Outbound' }).Count | Should Be 1
            }
            $allow = @($rules | Where-Object { $_['Action'] -eq 'Allow' })
            @($allow | Where-Object { $_['RemoteIPAddress'] -ne '172.29.96.1' }).Count | Should Be 0
            # From the VM, only DHCP and DNS; anything else toward the host has to be a reply to Moonlight.
            (@($allow | Where-Object { $_['Direction'] -eq 'Outbound' } | ForEach-Object { $_['RemotePort'] } | Sort-Object -Unique) -join ',') | Should Be '53,67'
            @($allow | Where-Object { $_['Direction'] -eq 'Inbound' -and -not $_['Stateful'] }).Count | Should Be 0
            # Allows get the higher weights.
            $rules[0]['Action'] | Should Be 'Allow'
            $rules[-1]['Action'] | Should Be 'Deny'
        }

        It 'does nothing when the rules already match the host address' {
            Mock Get-VMNetworkAdapterExtendedAcl { & $applied '172.29.96.1' 20000 }
            Mock Get-VMNetworkAdapter { [pscustomobject]@{ SwitchName = 'Default Switch' } }
            Mock Get-VMSwitch { [pscustomobject]@{ SwitchType = 'Internal' } }
            Mock Get-GpuVMHostNetwork { [pscustomobject]@{ Address = '172.29.96.1'; PrefixLength = 20 } }
            Mock Add-VMNetworkAdapterExtendedAcl {}
            Mock Remove-VMNetworkAdapterExtendedAcl {}
            Update-GpuVMNetworkIsolation -Name 'vm' -State $state
            Assert-MockCalled Add-VMNetworkAdapterExtendedAcl -Times 0 -Exactly -Scope It
            Assert-MockCalled Remove-VMNetworkAdapterExtendedAcl -Times 0 -Exactly -Scope It
        }

        It 'adds the new rules in the free block before removing the old ones when the host address changed' {
            $script:calls = [System.Collections.Generic.List[string]]::new()
            Mock Get-VMNetworkAdapterExtendedAcl { & $applied '172.29.96.1' 20000 }
            Mock Get-VMNetworkAdapter { [pscustomobject]@{ SwitchName = 'Default Switch' } }
            Mock Get-VMSwitch { [pscustomobject]@{ SwitchType = 'Internal' } }
            Mock Get-GpuVMHostNetwork { [pscustomobject]@{ Address = '172.18.0.1'; PrefixLength = 20 } }
            Mock Add-VMNetworkAdapterExtendedAcl { $script:calls.Add("add $Weight $RemoteIPAddress") }
            Mock Remove-VMNetworkAdapterExtendedAcl { $script:calls.Add('remove') }
            Update-GpuVMNetworkIsolation -Name 'vm' -State $state
            $adds = @($script:calls | Where-Object { $_ -like 'add *' })
            $adds.Count | Should Be 12
            @($adds | Where-Object { [int]($_ -split ' ')[1] -lt 20100 }).Count | Should Be 0
            @($adds | Where-Object { $_ -like '*172.29.96.1' }).Count | Should Be 0
            $script:calls.IndexOf('remove') | Should BeGreaterThan $script:calls.LastIndexOf($adds[-1])
        }

        It 'removes its rules, and only its own, when turned off or on an external switch' {
            Mock Get-VMNetworkAdapterExtendedAcl { @(& $applied '172.29.96.1' 20000) + @(& $acl 500 'Deny' 'Outbound' '8.8.8.8') }
            Mock Remove-VMNetworkAdapterExtendedAcl {}
            Mock Add-VMNetworkAdapterExtendedAcl {}
            Update-GpuVMNetworkIsolation -Name 'vm' -State @{ config = @{ vm = @{ network = @{ isolation = $false } } } }
            Assert-MockCalled Remove-VMNetworkAdapterExtendedAcl -Times 12 -Exactly -Scope It -ParameterFilter { $Weight -ge 20000 }
            Assert-MockCalled Remove-VMNetworkAdapterExtendedAcl -Times 0 -Exactly -Scope It -ParameterFilter { $Weight -eq 500 }

            Mock Get-VMNetworkAdapter { [pscustomobject]@{ SwitchName = 'LAN' } }
            Mock Get-VMSwitch { [pscustomobject]@{ SwitchType = 'External' } }
            Update-GpuVMNetworkIsolation -Name 'vm' -State $state -WarningAction SilentlyContinue
            Assert-MockCalled Add-VMNetworkAdapterExtendedAcl -Times 0 -Exactly -Scope It
        }

        It 'without the host address it still applies the blocks' {
            Mock Get-VMNetworkAdapterExtendedAcl { @() }
            Mock Get-VMNetworkAdapter { [pscustomobject]@{ SwitchName = 'Default Switch' } }
            Mock Get-VMSwitch { [pscustomobject]@{ SwitchType = 'Internal' } }
            Mock Get-GpuVMHostNetwork { throw 'no address' }
            Mock Add-VMNetworkAdapterExtendedAcl {}
            Update-GpuVMNetworkIsolation -Name 'vm' -State $state -WarningAction SilentlyContinue
            Assert-MockCalled Add-VMNetworkAdapterExtendedAcl -Times 7 -Exactly -Scope It -ParameterFilter { $Action -eq 'Deny' }
            Assert-MockCalled Add-VMNetworkAdapterExtendedAcl -Times 0 -Exactly -Scope It -ParameterFilter { $Action -eq 'Allow' }
        }
    }

    Describe 'Templates and shared disks' {
        It 'gives a copy its own Sunshine identity, keeping the web credentials' {
            $root = Join-Path $TestDrive 'clone'
            $config = Join-Path $root 'Program Files\Sunshine\config'
            New-Item -ItemType Directory -Path (Join-Path $config 'credentials') -Force | Out-Null
            '{"username":"gpuvm","salt":"s","password":"p","root":{"uniqueid":"ABC","named_devices":[{"name":"host"}]}}' |
                Set-Content -LiteralPath (Join-Path $config 'sunshine_state.json')
            'cert' | Set-Content -LiteralPath (Join-Path $config 'credentials\cacert.pem')
            'key' | Set-Content -LiteralPath (Join-Path $config 'credentials\cakey.pem')
            Reset-ClonedGuestIdentity -WindowsRoot $root
            $state = Get-Content -Raw -LiteralPath (Join-Path $config 'sunshine_state.json') | ConvertFrom-Json -AsHashtable
            $state.Contains('root') | Should Be $false
            $state['username'] | Should Be 'gpuvm'
            $state['password'] | Should Be 'p'
            Test-Path (Join-Path $config 'credentials\cacert.pem') | Should Be $false
            Test-Path (Join-Path $config 'credentials\cakey.pem') | Should Be $false
        }

        It 'never follows a link planted in the copy towards the host' {
            $root = Join-Path $TestDrive 'clone-link'
            $outside = Join-Path $TestDrive 'host-files'
            New-Item -ItemType Directory -Path (Join-Path $outside 'credentials') -Force | Out-Null
            'host' | Set-Content -LiteralPath (Join-Path $outside 'credentials\cacert.pem')
            New-Item -ItemType Directory -Path (Join-Path $root 'Program Files\Sunshine') -Force | Out-Null
            New-Item -ItemType Junction -Path (Join-Path $root 'Program Files\Sunshine\config') -Target $outside | Out-Null
            Test-Throws { Reset-ClonedGuestIdentity -WindowsRoot $root } | Should Be $true
            Test-Path (Join-Path $outside 'credentials\cacert.pem') | Should Be $true
        }

        It 'keeps shared disk labels within NTFS limits and rejects bad names' {
            Get-SharedDiskLabel 'juegos' | Should Be 'juegos'
            (Get-SharedDiskLabel ('a' * 40)).Length | Should Be 32
            Test-Throws { Get-SharedDiskPath -Name '..\fuera' } | Should Be $true
            Test-Throws { Get-TemplateDirectory -Name 'a b' } | Should Be $true
        }

        It 'keeps templates and shared disks out of the VM folders' {
            Mock Get-GpuVMDefaultRoot { 'C:\GpuVM' }
            Get-TemplateRoot | Should Be 'C:\GpuVM\.templates'
            Get-SharedDiskRoot | Should Be 'C:\GpuVM\.shared'
            # A VM name can't start with a dot, so no VM folder can be one of these.
            '.templates' -match '^[\w-]{1,40}$' | Should Be $false
            '.shared' -match '^[\w-]{1,40}$' | Should Be $false
        }

        It 'builds a copy with the profile hardware and the template Windows, at the template size' {
            $config = Resolve-GpuVMProfile 'max-performance'
            $template = @{ sizeGB = 200; config = @{ guest = @{ userName = 'gpuvm'; apps = @('steam'); cleanup = 'privacy' } } }
            $clone = New-TemplateCloneConfig -Config $config -Template $template
            $clone['vm']['cpu']['count'] | Should Be 8
            $clone['vm']['disk']['sizeGB'] | Should Be 200
            $clone['vm']['disk']['type'] | Should Be 'Differencing'
            $clone['guest']['cleanup'] | Should Be 'privacy'
            $clone.Contains('iso') | Should Be $false
            (Test-GpuVMProfileData -Config $clone -HostLogicalProcessors 12 -HostMemoryGB 16).Count | Should Be 0
        }

        It 'refuses to import GpuVM, Windows or anything that contains them' {
            Mock Get-GpuVMDefaultRoot { 'C:\GpuVM' }
            Test-Throws { Assert-ImportableFolder -Path 'C:\' } | Should Be $true
            Test-Throws { Assert-ImportableFolder -Path 'C:\GpuVM\win10' } | Should Be $true
            Test-Throws { Assert-ImportableFolder -Path $env:SystemRoot } | Should Be $true
            Test-Throws { Assert-ImportableFolder -Path (Split-Path ([Environment]::GetFolderPath('UserProfile')) -Parent) } | Should Be $true
            Test-Throws { Assert-ImportableFolder -Path 'D:\Juegos\SteamLibrary' } | Should Be $false
            Test-Throws { Assert-ImportableFolder -Path (Join-Path ${env:ProgramFiles(x86)} 'Steam') } | Should Be $false
        }

        It 'stops an import at any link below the target, however deep' {
            $root = Join-Path $TestDrive 'shared'
            $deep = Join-Path $root 'SteamLibrary\steamapps\common\Foo'
            New-Item -ItemType Directory -Path $deep -Force | Out-Null
            Test-Throws { Assert-NoReparsePointBelow -Root $root -Path (Join-Path $root 'SteamLibrary') } | Should Be $false
            $outside = Join-Path $TestDrive 'host-startup'
            New-Item -ItemType Directory -Path $outside -Force | Out-Null
            New-Item -ItemType Junction -Path (Join-Path $deep 'bin') -Target $outside | Out-Null
            Test-Throws { Assert-NoReparsePointBelow -Root $root -Path (Join-Path $root 'SteamLibrary') } | Should Be $true
        }
    }
}

InModuleScope GpuVM {
    Describe 'Low priority' {
        It 'quotes arguments the way Windows programs read them' {
            ConvertTo-CommandLineArgument '/Index:1' | Should Be '/Index:1'
            ConvertTo-CommandLineArgument 'C:\a b\' | Should Be '"C:\a b\\"'
            ConvertTo-CommandLineArgument 'say "hi"' | Should Be '"say \"hi\""'
            ConvertTo-CommandLineArgument '' | Should Be '""'
        }

        It 'returns the exit code and runs everything it starts at idle priority with low I/O' {
            Invoke-LowPriority -FilePath "$env:SystemRoot\System32\cmd.exe" -ArgumentList '/c', 'exit 7' | Should Be 7
            $out = Join-Path $TestDrive 'priority.txt'
            # A child of a child: the priority must reach processes it starts, as DISM starts DismHost.
            $script = "Set-Content -LiteralPath '$out' -Value (Get-Process -Id `$PID).PriorityClass"
            $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
            $null = Invoke-LowPriority -FilePath "$env:SystemRoot\System32\cmd.exe" -ArgumentList '/c', 'powershell', '-NoProfile', '-EncodedCommand', $encoded
            (Get-Content $out).Trim() | Should Be 'Idle'
        }

        It 'copies a file exactly, in several chunks and with an odd size, without its read-only mark' {
            $src = Join-Path $TestDrive 'base.vhdx'; $dst = Join-Path $TestDrive 'vm.vhdx'
            $bytes = [byte[]]::new(9MB + 123); [Random]::new(3).NextBytes($bytes)
            [IO.File]::WriteAllBytes($src, $bytes)
            (Get-Item $src).IsReadOnly = $true
            $stats = Copy-PacedFile -Source $src -Destination $dst
            $stats.Count | Should Be 3
            (Get-FileHash $dst).Hash | Should Be (Get-FileHash $src).Hash
            (Get-Item $dst).IsReadOnly | Should Be $false
            Test-Throws { Copy-PacedFile -Source $src -Destination $dst } | Should Be $true
            Test-Path $dst | Should Be $true
        }
    }
}

InModuleScope GpuVM {
    Describe 'Remembered GPU driver files' {
        $saved = $script:DataRoot
        $script:DataRoot = $TestDrive
        $folder = (Get-ChildItem (Join-Path $env:windir 'System32\DriverStore\FileRepository') -Directory | Select-Object -First 1).FullName
        $file = Join-Path $env:windir 'System32\kernel32.dll'

        It 'is used for the same device and driver version' {
            Save-GpuDriverFileSetCache -PnpDeviceId 'PCI\X' -DriverVersion '1.0' -Set ([pscustomobject]@{ DriverStoreFolders = @($folder); Files = @($file) })
            (Read-GpuDriverFileSetCache -PnpDeviceId 'PCI\X' -DriverVersion '1.0').Files | Should Be $file
            Read-GpuDriverFileSetCache -PnpDeviceId 'PCI\X' -DriverVersion '2.0' | Should Be $null
        }

        It 'is ignored when a path leaves the places drivers live' {
            foreach ($bad in @("$env:USERPROFILE\secret.txt", "$env:windir\System32\..\..\Users\x.dll", "$env:windir\INF\oem1.inf")) {
                Save-GpuDriverFileSetCache -PnpDeviceId 'PCI\X' -DriverVersion '1.0' -Set ([pscustomobject]@{ DriverStoreFolders = @($folder); Files = @($bad) })
                Read-GpuDriverFileSetCache -PnpDeviceId 'PCI\X' -DriverVersion '1.0' | Should Be $null
            }
            Save-GpuDriverFileSetCache -PnpDeviceId 'PCI\X' -DriverVersion '1.0' -Set ([pscustomobject]@{ DriverStoreFolders = @("$env:windir\System32"); Files = @($file) })
            Read-GpuDriverFileSetCache -PnpDeviceId 'PCI\X' -DriverVersion '1.0' | Should Be $null
        }

        $script:DataRoot = $saved
    }

    Describe 'Disk room' {
        It 'counts what the other VMs disks can still grow into, its own unwritten part and the host margin' {
            Mock Get-VMDiskUsage {
                [pscustomobject]@{ VM = 'a'; Path = 'C:\vm\a.vhdx'; Drive = 'C:'; SizeGB = 128; FileGB = 40; GrowthGB = 88; Type = 'Dynamic' }
                [pscustomobject]@{ VM = 'b'; Path = 'C:\vm\b.vhdx'; Drive = 'C:'; SizeGB = 200; FileGB = 200; GrowthGB = 0; Type = 'Fixed' }
                [pscustomobject]@{ VM = 'c'; Path = 'D:\vm\c.vhdx'; Drive = 'D:'; SizeGB = 500; FileGB = 10; GrowthGB = 490; Type = 'Dynamic' }
            }
            $free = [math]::Round(([IO.DriveInfo]::new('C:')).AvailableFreeSpace / 1GB, 1)
            $new = Get-GpuVMDiskBudget -Root 'C:\GpuVM'
            $new['promisedGB'] | Should Be 88
            $new['availableGB'] | Should Be ([math]::Max(0, [math]::Floor($free - 88 - $script:DiskMarginGB)))
            $a = Get-GpuVMDiskBudget -Root 'C:\GpuVM' -VMName 'a'
            $a['promisedGB'] | Should Be 0
            $a['usedGB'] | Should Be 40
            $a['maxGB'] | Should Be ([math]::Floor(128 + [math]::Max(0, [math]::Floor($free - 0 - 88 - $script:DiskMarginGB))))
        }
    }
}

InModuleScope GpuVM {
    Describe 'Rename' {
        $global:RenameTestId = [guid]'6b0a8f1e-3c55-4c1e-9a7a-1f2d3e4c5b6a'

        # A VM folder as Hyper-V and GpuVM leave it: configuration, disk named after the VM and gpuvm.json.
        function New-RenameFixture {
            $root = [IO.Path]::GetFullPath((Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))))
            $dir = Join-Path $root 'win10'
            New-Item -ItemType Directory (Join-Path $dir 'Virtual Machines'), (Join-Path $dir 'Virtual Hard Disks') | Out-Null
            'config' | Set-Content (Join-Path $dir "Virtual Machines\$global:RenameTestId.vmcx")
            'disk' | Set-Content (Join-Path $dir 'Virtual Hard Disks\win10.vhdx')
            $state = [ordered]@{
                name         = 'win10'
                backend      = 'hyperv-gpup'
                vmDir        = $dir
                vhdPath      = Join-Path $dir 'Virtual Hard Disks\win10.vhdx'
                lastOpenedAt = '2026-11-01T10:00:00.0000000-05:00'
                streaming    = [ordered]@{ user = 'gpuvm'; password = 'x'; pairedClient = 'HOST-PC' }
                config       = [ordered]@{ streaming = [ordered]@{ client = [ordered]@{ fps = 120; monitor = 'primary' } } }
                statePath    = Join-Path $dir 'gpuvm.json'
            }
            Save-GpuVMState $state
            [pscustomobject]@{ Root = $root; Dir = $dir; State = $state }
        }

        function Set-HyperVMocks([string]$Dir) {
            $global:RenameTestDir = $Dir
            Mock Get-VM { [pscustomobject]@{ Name = 'win10'; Id = $global:RenameTestId; State = 'Off'; ConfigurationLocation = $global:RenameTestDir
                    SnapshotFileLocation = $global:RenameTestDir; SmartPagingFilePath = $global:RenameTestDir } }
            Mock Rename-VM { }
            # Hyper-V moves the configuration folder itself.
            Mock Move-VMStorage {
                $from = @(Get-ChildItem (Split-Path $VirtualMachinePath -Parent) -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'Virtual Machines') })[0]
                Move-Item (Join-Path $from.FullName 'Virtual Machines') (Join-Path $VirtualMachinePath 'Virtual Machines')
            }
            Mock Get-VMHardDiskDrive {
                [pscustomobject]@{ Path = Join-Path $global:RenameTestDir 'Virtual Hard Disks\win10.vhdx'; ControllerType = 'SCSI'; ControllerNumber = 0; ControllerLocation = 0 }
                [pscustomobject]@{ Path = 'C:\GpuVM\.shared\juegos.vhdx'; ControllerType = 'SCSI'; ControllerNumber = 0; ControllerLocation = 1 }
            }
            Mock Set-VMHardDiskDrive { }
        }

        It 'renames the VM, its folder, disk and state, keeping pairing, client settings and last opened' {
            $f = New-RenameFixture
            Set-HyperVMocks $f.Dir
            $new = Rename-HyperVGpuPVM -Name 'win10' -NewName 'juegos' -State $f.State 6>$null
            $newDir = Join-Path $f.Root 'juegos'
            $new['vmDir'] | Should Be $newDir
            $new['vhdPath'] | Should Be (Join-Path $newDir 'Virtual Hard Disks\juegos.vhdx')
            Test-Path $f.Dir | Should Be $false
            Test-Path $new['vhdPath'] | Should Be $true
            Test-Path (Join-Path $newDir "Virtual Machines\$global:RenameTestId.vmcx") | Should Be $true
            $saved = Read-JsonFile (Join-Path $newDir 'gpuvm.json')
            $saved['name'] | Should Be 'juegos'
            $saved['vhdPath'] | Should Be $new['vhdPath']
            $saved['streaming']['pairedClient'] | Should Be 'HOST-PC'
            $saved['config']['streaming']['client']['fps'] | Should Be 120
            $saved['lastOpenedAt'] | Should Not BeNullOrEmpty
            Assert-MockCalled Rename-VM -Times 1 -Exactly -Scope It -ParameterFilter { $NewName -eq 'juegos' }
            Assert-MockCalled Move-VMStorage -Times 1 -Exactly -Scope It -ParameterFilter { $VirtualMachinePath -eq $newDir -and $SnapshotFilePath -eq $newDir }
            # The shared disk lives outside the VM folder: it stays attached where it is.
            Assert-MockCalled Set-VMHardDiskDrive -Times 1 -Exactly -Scope It -ParameterFilter { $VMName -eq 'juegos' -and $Path -eq $new['vhdPath'] }
        }

        It 'undoes every step when one fails, leaving the VM as it was' {
            $f = New-RenameFixture
            Set-HyperVMocks $f.Dir
            $before = Get-Content -Raw $f.State['statePath']
            Mock Set-VMHardDiskDrive { throw 'disk busy' } -ParameterFilter { $Path -like '*juegos.vhdx' }
            $message = try { Rename-HyperVGpuPVM -Name 'win10' -NewName 'juegos' -State $f.State 6>$null; '' } catch { $_.Exception.Message }
            $message | Should Match 'disk busy'
            $message | Should Match 'left as it was'
            Test-Path (Join-Path $f.Root 'juegos') | Should Be $false
            Test-Path (Join-Path $f.Dir 'Virtual Hard Disks\win10.vhdx') | Should Be $true
            Get-Content -Raw $f.State['statePath'] | Should Be $before
            Assert-MockCalled Rename-VM -Times 1 -Exactly -Scope It -ParameterFilter { $NewName -eq 'win10' }
            Assert-MockCalled Move-VMStorage -Times 2 -Exactly -Scope It
        }

        It 'only changes the name when it differs in case, keeping the folder' {
            $f = New-RenameFixture
            Set-HyperVMocks $f.Dir
            $new = Rename-HyperVGpuPVM -Name 'win10' -NewName 'Win10' -State $f.State 6>$null
            $new['vmDir'] | Should Be $f.Dir
            (Read-JsonFile $f.State['statePath'])['name'] | Should Be 'Win10'
            Assert-MockCalled Move-VMStorage -Times 0 -Exactly -Scope It
        }

        It 'validates the new name as creating does and only renames a VM that is off' {
            $f = New-RenameFixture
            Mock Assert-Admin { }
            Mock Get-GpuVMState { $f.State }
            Mock Get-VMSnapshot { }
            Mock Invoke-GpuVMBackend { }
            Mock Get-VM { }
            Mock Get-VM { [pscustomobject]@{ Name = 'win10'; Id = $global:RenameTestId; State = 'Off' } } -ParameterFilter { $Name -eq 'win10' }
            Mock Get-VM { [pscustomobject]@{ Name = 'otra'; Id = [guid]::NewGuid(); State = 'Off' } } -ParameterFilter { $Name -eq 'otra' }
            Test-Throws { Rename-GpuVM -Name 'win10' -NewName 'con espacio' } | Should Be $true
            Test-Throws { Rename-GpuVM -Name 'win10' -NewName ('x' * 41) } | Should Be $true
            Test-Throws { Rename-GpuVM -Name 'win10' -NewName 'otra' } | Should Be $true
            New-Item -ItemType Directory (Join-Path $f.Root 'sobra') | Out-Null
            Test-Throws { Rename-GpuVM -Name 'win10' -NewName 'sobra' } | Should Be $true
            Mock Get-VM { [pscustomobject]@{ Name = 'win10'; Id = $global:RenameTestId; State = 'Running' } } -ParameterFilter { $Name -eq 'win10' }
            Test-Throws { Rename-GpuVM -Name 'win10' -NewName 'juegos' } | Should Be $true
            Assert-MockCalled Invoke-GpuVMBackend -Times 0 -Exactly -Scope It
        }

        It 'keeps the renamed VM in the ISO list' {
            $saved = $script:DataRoot
            $script:DataRoot = Join-Path $TestDrive 'iso-data'
            New-Item -ItemType Directory $script:DataRoot | Out-Null
            $iso = Join-Path $TestDrive 'Win11.iso'
            'x' | Set-Content $iso
            Register-GpuVMIsoUse -Path $iso -VMName 'win10'
            Register-GpuVMIsoUse -Path $iso -VMName 'otra'
            Rename-GpuVMIsoUse -Name 'win10' -NewName 'juegos'
            @(Read-IsoLibrary)[0]['usedBy'] | Should Be @('juegos', 'otra')
            $script:DataRoot = $saved
        }
    }

    Describe 'Administrator prompts' {
        It 'escapes the host item it sends to the guest' {
            $xml = [xml](ConvertTo-KvpItemText -Key 'GpuVMAdminPromptAnswer' -Value '{"a":"<b>&"}')
            $xml.SelectSingleNode("/INSTANCE/PROPERTY[@NAME='Data']/VALUE").InnerText | Should Be '{"a":"<b>&"}'
            $xml.SelectSingleNode("/INSTANCE/PROPERTY[@NAME='Source']/VALUE").InnerText | Should Be '0'
        }

        It 'reads a prompt from a watcher with or without a one-time code' {
            Mock Get-VM { [pscustomobject]@{ State = 'Running'; Id = [guid]::NewGuid() } }
            Mock Get-GuestKvpJson { [pscustomobject]@{ open = $true; id = 42; app = 'cmd'; publisher = 'Microsoft Windows' } }
            $p = Get-GuestAdminPromptState -Name 'vm'
            $p.id | Should Be 42
            $p.nonce | Should Be $null
            $p.reading | Should Be $false
            Mock Get-GuestKvpJson { [pscustomobject]@{ open = $true; id = 42; nonce = ('a' * 32); reading = $true } }
            $p = Get-GuestAdminPromptState -Name 'vm'
            $p.nonce | Should Be ('a' * 32)
            $p.reading | Should Be $true
            # The code never reaches the app.
            (Get-GuestAdminPrompt -Name 'vm').PSObject.Properties['nonce'] | Should Be $null
        }

        It 'ignores what the guest sends out of shape' {
            Mock Get-VM { [pscustomobject]@{ State = 'Running'; Id = [guid]::NewGuid() } }
            Mock Get-GuestKvpJson { [pscustomobject]@{ open = $true; id = 'x' } }
            Get-GuestAdminPromptState -Name 'vm' | Should Be $null
            Mock Get-GuestKvpJson { [pscustomobject]@{ open = $true; id = 7; nonce = 'NOT-HEX'; app = ('z' * 500) } }
            $p = Get-GuestAdminPromptState -Name 'vm'
            $p.nonce | Should Be $null
            $p.app.Length | Should Be 80
            Mock Get-GuestKvpJson { 'text' }
            Get-GuestAdminPromptState -Name 'vm' | Should Be $null
        }

        It 'answers through the data exchange when the prompt has a code, and refuses another prompt' {
            Mock Get-GuestAdminPromptState { [pscustomobject]@{ id = 42; nonce = ('b' * 32); reading = $false } }
            Mock Send-GuestAdminPromptAnswer { $script:sent = "$Answer $PromptId $Nonce"; 'done' }
            Mock Invoke-GuestAdminPromptAnswer { throw 'no debe usar PowerShell Direct' }
            (Resolve-GpuVMAdminPrompt -Name 'vm' -Answer Allow -PromptId 42)['answer'] | Should Be 'Allow'
            $script:sent | Should Be "yes 42 $('b' * 32)"
            Test-Throws { Resolve-GpuVMAdminPrompt -Name 'vm' -Answer Allow -PromptId 43 } | Should Be $true
        }

        It 'falls back to PowerShell Direct for a watcher without a code' {
            Mock Get-GuestAdminPromptState { [pscustomobject]@{ id = 42; nonce = $null; reading = $false } }
            Mock Send-GuestAdminPromptAnswer { throw 'no debe usar la KVP' }
            Mock Get-GpuVMState { @{ name = 'vm'; guest = @{ user = 'u' } } }
            Mock Get-GpuVMGuestCredential { [pscredential]::new('u', (ConvertTo-SecureString 'p' -AsPlainText -Force)) }
            Mock Invoke-GuestAdminPromptAnswer { 'done' }
            (Resolve-GpuVMAdminPrompt -Name 'vm' -Answer Deny -PromptId 42)['answer'] | Should Be 'Deny'
        }

        It 'counts the watched machines for notices-only mode' {
            Mock Get-VM { @([pscustomobject]@{ Name = 'a'; State = 'Running' }, [pscustomobject]@{ Name = 'b'; State = 'Running' }) }
            Mock Get-GpuVMState { @{ streaming = @{ x = 1 } } }
            Mock Get-GpuVMCaptureMode { 'wgc' }
            Mock Get-GuestAdminPrompt { if ($Name -eq 'b') { [pscustomobject]@{ id = 5; app = 'cmd'; publisher = 'p'; reading = $false } } }
            $r = Get-GpuVMAdminPrompt -WithWatched
            $r['watched'] | Should Be 2
            @($r['prompts']).Count | Should Be 1
            @($r['prompts'])[0]['name'] | Should Be 'b'
        }
    }
}

InModuleScope GpuVM {
    Describe 'File transfers' {
        It 'sends only plain files and folders of this PC, never GpuVM, Windows or what contains them' {
            Mock Get-GpuVMDefaultRoot { 'C:\GpuVM' }
            $file = Join-Path $TestDrive 'foto.png'; 'x' | Set-Content $file
            Test-Throws { Assert-SendablePath -Path $file } | Should Be $false
            Test-Throws { Assert-SendablePath -Path $TestDrive } | Should Be $false
            Test-Throws { Assert-SendablePath -Path 'foto.png' } | Should Be $true
            Test-Throws { Assert-SendablePath -Path "$TestDrive\..\x" } | Should Be $true
            Test-Throws { Assert-SendablePath -Path 'C:\' } | Should Be $true
            Test-Throws { Assert-SendablePath -Path (Join-Path $env:SystemRoot 'System32\drivers\etc\hosts') } | Should Be $true
            Test-Throws { Assert-SendablePath -Path 'C:\GpuVM\win10\gpuvm.json' } | Should Be $true
            $link = Join-Path $TestDrive 'enlace'
            New-Item -ItemType Junction -Path $link -Target $env:SystemRoot | Out-Null
            Test-Throws { Assert-SendablePath -Path $link } | Should Be $true
        }

        It 'skips links inside a folder and keeps two items with the same name apart' {
            $a = Join-Path $TestDrive 'a\Proyecto'; $b = Join-Path $TestDrive 'b\Proyecto'
            New-Item -ItemType Directory -Force (Join-Path $a 'sub'), $b | Out-Null
            'uno' | Set-Content (Join-Path $a 'sub\uno.txt'); 'dos' | Set-Content (Join-Path $b 'dos.txt')
            New-Item -ItemType Junction -Path (Join-Path $a 'fuera') -Target $env:SystemRoot | Out-Null
            $list = Get-HostTransferEntries -Path $a, $b
            $list.Skipped | Should Be 1
            @($list.Entries.Rel) -contains 'Proyecto\sub\uno.txt' | Should Be $true
            @($list.Entries.Rel) -contains 'Proyecto (2)\dos.txt' | Should Be $true
            @($list.Entries | Where-Object { $_.Rel -like '*fuera*' }).Count | Should Be 0
        }

        It 'refuses names from a guest that would leave the folder' {
            foreach ($bad in '..\Windows\x', 'a\..\..\b', 'C:\x', 'a:b', 'a\\b', '', ('x' * 300), 'con. ', "a`tb") {
                Test-Throws { Assert-TransferName -Name $bad } | Should Be $true
            }
            Test-Throws { Assert-TransferName -Name 'Fotos\año 2026\canción.txt' } | Should Be $false
        }

        It 'writes a tar that Windows reads back with every name' {
            $tar = Join-Path $TestDrive 't.tar'
            $fs = [IO.File]::Create($tar)
            foreach ($e in @(@{ n = 'Carpeta ñ'; d = $true; b = '' }, @{ n = "Carpeta ñ\$('n' * 120).txt"; d = $false; b = 'largo' }, @{ n = 'Carpeta ñ\😀.txt'; d = $false; b = 'x' })) {
                if ($e.d) { $h = New-TarHeader -Name $e.n -Directory; $fs.Write($h, 0, $h.Length); continue }
                $data = [Text.Encoding]::UTF8.GetBytes($e.b)
                $h = New-TarHeader -Name $e.n -Size $data.Length; $fs.Write($h, 0, $h.Length); $fs.Write($data, 0, $data.Length)
                $pad = (512 - $data.Length % 512) % 512; $fs.Write([byte[]]::new($pad), 0, $pad)
            }
            $fs.Write([byte[]]::new(1024), 0, 1024); $fs.Dispose()
            $out = Join-Path $TestDrive 'x'; New-Item -ItemType Directory $out | Out-Null
            & "$env:SystemRoot\System32\tar.exe" -x -f $tar -C $out
            $LASTEXITCODE | Should Be 0
            Get-Content -Raw (Join-Path $out "Carpeta ñ\$('n' * 120).txt") | Should Be 'largo'
            Test-Path -LiteralPath (Join-Path $out 'Carpeta ñ\😀.txt') | Should Be $true
        }
    }
}


# Front 4: restore points, disposable machines, export/import (pure logic; the disk work is proven in labs/045-disks).
InModuleScope GpuVM {
    Describe 'Restore points' {
        It 'accepts only ids GpuVM makes' {
            $s = @{ vhdPath = 'C:\GpuVM\a\Virtual Hard Disks\a.vhdx' }
            (Get-RestorePointPath -State $s -Id '20261118-101500-a1b2') | Should Be 'C:\GpuVM\a\Virtual Hard Disks\points\20261118-101500-a1b2.vhdx'
            Test-Throws { Get-RestorePointPath -State $s -Id '..\..\x' } | Should Be $true
            Test-Throws { Get-RestorePointPath -State $s -Id '20261118-101500-a1b2\..' } | Should Be $true
        }
        It 'new ids have the expected shape' {
            (New-RestorePointId) -match '^[0-9]{8}-[0-9]{6}-[0-9a-f]{4}$' | Should Be $true
        }
        It 'an empty or single list is still a list' {
            @(Get-GpuVMRestorePointList -State @{}).Count | Should Be 0
            @(Get-GpuVMRestorePointList -State @{ restorePoints = @(@{ id = 'x' }) }).Count | Should Be 1
        }
    }

    Describe 'Disposable machines' {
        It 'a machine without the mark is never disposable' {
            Test-GpuVMDisposableDone -State @{ name = 'a' } -VMState 'Off' | Should Be $false
            Test-GpuVMDisposableDone -State @{ disposable = $true } -VMState 'Off' | Should Be $false
        }
        It 'a running disposable machine is kept' {
            Test-GpuVMDisposableDone -State @{ disposable = @{ createdAt = '2020-01-01T00:00:00Z'; startedAt = '2020-01-01T00:01:00Z' } } -VMState 'Running' | Should Be $false
        }
        It 'off after it ran, it goes' {
            Test-GpuVMDisposableDone -State @{ disposable = @{ createdAt = (Get-Date).ToString('o'); startedAt = (Get-Date).ToString('o') } } -VMState 'Off' | Should Be $true
        }
        It 'never started: kept during the grace period, then it goes' {
            Test-GpuVMDisposableDone -State @{ disposable = @{ createdAt = (Get-Date).ToString('o'); startedAt = $null } } -VMState 'Off' | Should Be $false
            Test-GpuVMDisposableDone -State @{ disposable = @{ createdAt = (Get-Date).AddHours(-1).ToString('o'); startedAt = $null } } -VMState 'Off' | Should Be $true
        }
    }

    Describe 'Export manifest' {
        $good = [ordered]@{ format = 1; kind = 'gpuvm-machine'; name = 'win10'; edition = 'Windows 10 Pro'; user = 'gpuvm'
            installedApps = @('vlc', 'steam'); disk = @{ bytes = 1024; sha256 = ('a' * 64) } }
        It 'reads a valid manifest' {
            $m = Read-TransferManifest -Text ($good | ConvertTo-Json -Depth 5)
            $m['name'] | Should Be 'win10'
            ($m['installedApps'] -join ',') | Should Be 'vlc,steam'
            $m['disk']['bytes'] | Should Be 1024
        }
        It 'drops values that are not what they claim' {
            $bad = Merge-Hashtable -Base $good -Override @{ name = '..\..\Windows'; user = 'a b;c'; installedApps = @('ok', '../x', @{ a = 1 }) }
            $m = Read-TransferManifest -Text ($bad | ConvertTo-Json -Depth 5)
            $m['name'] | Should Be $null
            $m['user'] | Should Be $null
            ($m['installedApps'] -join ',') | Should Be 'ok'
        }
        It 'refuses files that are not GpuVM machines or lack the fingerprint' {
            Test-Throws { Read-TransferManifest -Text 'not json' } | Should Be $true
            Test-Throws { Read-TransferManifest -Text '{"kind":"other","format":1}' } | Should Be $true
            Test-Throws { Read-TransferManifest -Text ((Merge-Hashtable -Base $good -Override @{ disk = @{ bytes = 1; sha256 = 'xyz' } }) | ConvertTo-Json -Depth 5) } | Should Be $true
        }
        It 'refuses a newer format' {
            Test-Throws { Read-TransferManifest -Text ((Merge-Hashtable -Base $good -Override @{ format = 99 }) | ConvertTo-Json -Depth 5) } | Should Be $true
        }
        It 'a new manifest carries no secrets' {
            $state = [ordered]@{ name = 'w'; edition = 'e'; profile = 'balanced'; guest = @{ user = 'gpuvm'; password = 'BLOB' }
                streaming = @{ password = 'BLOB2'; pairedClient = 'x' }; config = @{ guest = @{ cleanup = 'none' } }; gpu = @{ driverVersion = '1.2' } }
            $text = New-TransferManifest -State $state -SizeBytes 10 | ConvertTo-Json -Depth 5
            $text -match 'BLOB|pairedClient|password' | Should Be $false
        }
    }
}

InModuleScope GpuVM {
    Describe 'Export destination' {
        It 'never writes inside Windows, the programs, ProgramData or GpuVM folders' {
            Test-Throws { Assert-GpuVMExportPath -Path (Join-Path $env:windir 'x.gpuvm') } | Should Be $true
            Test-Throws { Assert-GpuVMExportPath -Path (Join-Path $env:ProgramFiles 'x.gpuvm') } | Should Be $true
            Test-Throws { Assert-GpuVMExportPath -Path (Join-Path $env:ProgramData 'x.gpuvm') } | Should Be $true
            Test-Throws { Assert-GpuVMExportPath -Path (Join-Path (Get-GpuVMDefaultRoot) 'x.gpuvm') } | Should Be $true
            Test-Throws { Assert-GpuVMExportPath -Path '\\server\share\x.gpuvm' } | Should Be $true
        }
        It 'accepts a plain folder of the user' {
            $p = Join-Path $env:TEMP 'x.gpuvm'
            Assert-GpuVMExportPath -Path $p | Should Be ([IO.Path]::GetFullPath($p))
        }
    }
}

InModuleScope GpuVM {
    Describe 'Disposable disk room' {
        It 'a disposable machine is promised only its fixed reserve; the others their whole disk' {
            Mock Get-VM { @([pscustomobject]@{ Name = 'tmp' }, [pscustomobject]@{ Name = 'keep' }) }
            Mock Get-VMHardDiskDrive { [pscustomobject]@{ Path = "C:\GpuVM\$VMName\d.vhdx" } }
            Mock Get-VHD { [pscustomobject]@{ Size = 64GB; FileSize = 5GB; VhdType = 'Differencing' } }
            Mock Get-GpuVMState { if ($Name -eq 'tmp') { @{ disposable = @{ createdAt = 'x' } } } else { @{ name = 'keep' } } }
            $script:DiskCache = $null
            $usage = @(Get-VMDiskUsage)
            ($usage | Where-Object VM -eq 'tmp').GrowthGB | Should Be ($script:DisposableReserveGB - 5)
            ($usage | Where-Object VM -eq 'keep').GrowthGB | Should Be 59
            $script:DiskCache = $null
        }
    }
}
InModuleScope GpuVM {
    Describe 'Files of this PC read with the person''s rights' {
        Initialize-UserFiles
        $elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        function global:Get-InnerError([scriptblock]$Block) { try { & $Block | Out-Null; '' } catch { $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }; $e.Message } }

        It 'lists and reads a plain folder, skipping links' {
            $top = Join-Path $TestDrive 'uf1\Proyecto'
            New-Item -ItemType Directory -Force (Join-Path $top 'sub') | Out-Null
            'hola' | Set-Content (Join-Path $top 'sub\a.txt')
            New-Item -ItemType Junction -Path (Join-Path $top 'fuera') -Target $env:SystemRoot | Out-Null
            $root = [GpuVM.UserFiles]::Root($top, $true)
            $links = 0
            $list = [GpuVM.UserFiles]::List($top, 'Proyecto', $root, [ref]$links)
            $links | Should Be 1
            @($list | ForEach-Object Rel) -contains 'Proyecto\sub\a.txt' | Should Be $true
            $s = [GpuVM.UserFiles]::OpenFile((Join-Path $top 'sub\a.txt'), $root)
            try { [IO.StreamReader]::new($s).ReadToEnd().Trim() | Should Be 'hola' } finally { $s.Dispose() }
        }

        It 'refuses a folder swapped for a junction after the listing' {
            $top = Join-Path $TestDrive 'uf2\Proyecto'
            $outside = Join-Path $TestDrive 'uf2-admin'
            New-Item -ItemType Directory -Force (Join-Path $top 'sub'), $outside | Out-Null
            'mio' | Set-Content (Join-Path $top 'sub\a.txt')
            'secreto' | Set-Content (Join-Path $outside 'a.txt')
            $root = [GpuVM.UserFiles]::Root($top, $true)
            $links = 0
            $null = [GpuVM.UserFiles]::List($top, 'Proyecto', $root, [ref]$links)
            # The swap: sub becomes a junction to another folder, keeping the same names below it.
            Remove-Item (Join-Path $top 'sub') -Recurse -Force
            New-Item -ItemType Junction -Path (Join-Path $top 'sub') -Target $outside | Out-Null
            Get-InnerError { [GpuVM.UserFiles]::OpenFile((Join-Path $top 'sub\a.txt'), $root) } | Should Match 'outside the chosen folder'
        }

        It 'refuses a chosen item that is a link or goes through one' {
            $real = Join-Path $TestDrive 'uf3-real'; New-Item -ItemType Directory -Force $real | Out-Null
            $link = Join-Path $TestDrive 'uf3-link'; New-Item -ItemType Junction -Path $link -Target $real | Out-Null
            'x' | Set-Content (Join-Path $real 'b.txt')
            Get-InnerError { [GpuVM.UserFiles]::Root($link, $true) } | Should Not Be ''
            Get-InnerError { [GpuVM.UserFiles]::Root((Join-Path $link 'b.txt'), $false) } | Should Match 'link'
        }

        It 'refuses a file or a folder only administrators can read, even from an elevated bridge' {
            if (-not $elevated) { Set-ItResult -Inconclusive -Because 'needs an elevated shell to make an admin-only file'; return }
            $top = Join-Path $TestDrive 'uf4\Proyecto'
            New-Item -ItemType Directory -Force (Join-Path $top 'cerrada') | Out-Null
            $secret = Join-Path $top 'gpuvm.json'; 'clave' | Set-Content $secret
            'x' | Set-Content (Join-Path $top 'cerrada\c.txt')
            foreach ($target in $secret, (Join-Path $top 'cerrada')) {
                $acl = Get-Acl $target
                $acl.SetAccessRuleProtection($true, $false)
                @($acl.Access) | ForEach-Object { $null = $acl.RemoveAccessRule($_) }
                foreach ($sid in 'S-1-5-32-544', 'S-1-5-18') {
                    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]$sid, 'FullControl', 'Allow'))
                }
                Set-Acl $target $acl
            }
            # The elevated process itself can read it (that was the hole).
            [IO.File]::ReadAllText($secret).Trim() | Should Be 'clave'
            $root = [GpuVM.UserFiles]::Root($top, $true)
            Get-InnerError { [GpuVM.UserFiles]::OpenFile($secret, $root) } | Should Match "can't access"
            $links = 0
            Get-InnerError { [GpuVM.UserFiles]::List($top, 'Proyecto', $root, [ref]$links) } | Should Match "can't access|couldn't be read"
            # Back to inherited rights, so the test drive can be deleted afterwards.
            $null = icacls $top /reset /T /Q
        }
    }
}

InModuleScope GpuVM {
    Describe 'Names of a copy' {
        It 'gives two chosen items of another VM with the same name " (2)", and keeps what is under each with it' {
            Mock Get-GuestRawEntries { @{ skipped = 0; entries = @(
                @{ rel = 'x.txt'; full = 'C:\a\x.txt'; size = [int64]1; dir = $false }
                @{ rel = 'x.txt'; full = 'C:\b\x.txt'; size = [int64]2; dir = $false }
                @{ rel = 'Fotos'; full = 'C:\a\Fotos'; size = [int64]0; dir = $true }
                @{ rel = 'Fotos\1.jpg'; full = 'C:\a\Fotos\1.jpg'; size = [int64]3; dir = $false }
                @{ rel = 'Fotos'; full = 'C:\b\Fotos'; size = [int64]0; dir = $true }
                @{ rel = 'Fotos\1.jpg'; full = 'C:\b\Fotos\1.jpg'; size = [int64]4; dir = $false }
            ) } }
            $list = Get-GuestTransferEntries -Session 'sesion-de-prueba' -Path 'C:\a\x.txt', 'C:\b\x.txt'
            ($list.Entries | ForEach-Object Rel) -join '|' | Should Be 'x.txt|x (2).txt|Fotos|Fotos\1.jpg|Fotos (2)|Fotos (2)\1.jpg'
        }

        It 'refuses a destination folder that is "." or "..", or ends in a dot or space' {
            foreach ($bad in '.', '..', 'Received.', 'Received ', 'a\b') {
                Test-Throws { Send-GpuVMFile -Name x -Path 'C:\x' -Folder $bad } | Should Be $true
                Test-Throws { Send-GpuVMClipboard -Name x -Files 'C:\x' -Folder $bad } | Should Be $true
            }
            Mock Assert-Admin { throw 'reached' }
            (Get-InnerError { Send-GpuVMFile -Name x -Path 'C:\x' -Folder 'Received' }) | Should Be 'reached'
        }
    }
}


InModuleScope GpuVM {
    Describe 'Disposable machines are protected' {
        It 'points, export and templates refuse a disposable machine' {
            Test-Throws { Assert-GpuVMNotDisposable -State @{ disposable = @{ createdAt = 'x' } } -Action 'exportar' } | Should Be $true
            Test-Throws { Assert-GpuVMNotDisposable -State @{ name = 'normal' } -Action 'exportar' } | Should Be $false
        }
        It 'the sweep deletes nothing when Hyper-V does not answer' {
            Mock Assert-Admin { }
            Mock Get-GpuVMDefaultRoot { 'C:\GpuVM-test-root' }
            Mock Get-DriveFreeGB { 500 }
            Mock Get-VM { throw 'Hyper-V is busy' }
            Mock Remove-Item { throw 'nothing may be deleted' }
            Mock Get-ChildItem { throw 'no folder may be listed' }
            @(Remove-GpuVMDisposable -Confirm:$false -WarningAction SilentlyContinue).Count | Should Be 0
            Assert-MockCalled Remove-Item -Times 0
            Assert-MockCalled Get-ChildItem -Times 0
        }
    }
}

InModuleScope GpuVM {
    Describe 'Agent broker commands' {
        It 'module commands send exactly the names and arguments the service accepts' {
            # The service's list (app/host/src/agent.rs COMMANDS) is the contract: exact case, no extra arguments.
            $source = Get-Content -Raw (Get-RepoPath 'app\host\src\agent.rs')
            $accepted = @{}
            foreach ($m in [regex]::Matches($source, '\("([A-Za-z-]+)", &\[([^\]]*)\]\)')) {
                $accepted[$m.Groups[1].Value] = @([regex]::Matches($m.Groups[2].Value, '"(\w+)"') | ForEach-Object { $_.Groups[1].Value })
            }
            $accepted.Count | Should BeGreaterThan 10
            $common = [System.Management.Automation.Cmdlet]::CommonParameters + [System.Management.Automation.Cmdlet]::OptionalCommonParameters
            $wrappers = 'Get-GpuVMAgent', 'Get-GpuVMAgentBroker', 'Invoke-GpuVMAgent', 'Suspend-GpuVMAgent', 'Resume-GpuVMAgent',
                'Stop-GpuVMAgentClient', 'New-GpuVMAgentOffer', 'Get-GpuVMAgentOffer', 'Resolve-GpuVMAgentOffer'
            foreach ($name in $wrappers) {
                $accepted.ContainsKey($name) | Should Be $true
                foreach ($p in (Get-Command $name).Parameters.Keys | Where-Object { $_ -notin $common -and $_ -ne 'BlobPath' }) {
                    "$name $p $($accepted[$name] -ccontains $p)" | Should Be "$name $p True"
                }
            }
        }
        It 'wrappers drop common parameters and send switches as booleans' {
            Mock Invoke-AgentBroker { [pscustomobject]@{ Command = $Command; Arguments = $Arguments } }
            $r = Stop-GpuVMAgentClient -All -Verbose:$false
            $r.Command | Should Be 'Stop-GpuVMAgentClient'
            $r.Arguments['All'] | Should Be $true
            $r.Arguments.ContainsKey('Verbose') | Should Be $false
            $r = Resolve-GpuVMAgentOffer -Id 'ab' -Answer approve
            $r.Arguments['Answer'] | Should BeExactly 'approve'
            Test-Throws { Resolve-GpuVMAgentOffer -Id 'ab' -Answer 'yes' } | Should Be $true
        }
        It 'Invoke-GpuVMAgent sends a host file as base64 and refuses big ones' {
            Mock Invoke-AgentBroker { $Arguments }
            $f = Join-Path $TestDrive 'a.bin'
            [IO.File]::WriteAllBytes($f, [byte[]](1, 2, 3))
            $a = Invoke-GpuVMAgent -Name vm -Method files.write -Params @{ path = 'C:\Users\agent\x' } -BlobPath $f
            $a['Blob'] | Should Be 'AQID'
            $a['TimeoutSec'] | Should Be 30
            $big = Join-Path $TestDrive 'big.bin'
            $s = [IO.File]::Create($big); $s.SetLength(16MB + 1); $s.Dispose()
            Test-Throws { Invoke-GpuVMAgent -Name vm -Method files.write -BlobPath $big } | Should Be $true
        }
        It 'a registration is removed only inside the agents folder' {
            Mock Get-GpuVMAgentRoot { Join-Path $TestDrive 'agents' }
            $id = '0B5D1F53-1E33-4B7E-9F0A-2C4D6E8F0A1B'
            $dir = Join-Path $TestDrive "agents\$($id.ToLowerInvariant())"
            New-Item -ItemType Directory $dir -Force | Out-Null
            Remove-GpuVMAgentRegistration -VMId $id
            Test-Path $dir | Should Be $false
        }
        It 'the secret file is DPAPI-protected and readable by SYSTEM only' {
            $dir = Join-Path $TestDrive 'secret-test'
            New-Item -ItemType Directory $dir -Force | Out-Null
            Write-AgentSecret -Folder $dir -Secret ([byte[]](1..32))
            $acl = Get-Acl (Join-Path $dir 'secret')
            $acl.AreAccessRulesProtected | Should Be $true
            $sids = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | ForEach-Object { $_.IdentityReference.Value })
            ($sids -join ',') | Should Be 'S-1-5-18'
            Test-Path (Join-Path $dir 'secret.new') | Should Be $false
        }
    }

    Describe 'Install-GpuVMAgent' {
        BeforeEach {
            $script:copied = [System.Collections.Generic.List[string]]::new()
            $script:gsi = [System.Collections.Generic.List[string]]::new()
            Mock Assert-Admin { }
            Mock Get-GpuVMState { @{ statePath = 'D:\GpuVM\vm1\gpuvm.json'; guest = @{ user = 'u' } } }
            Mock Get-VM { [pscustomobject]@{ State = 'Running'; Id = [guid]'0b5d1f53-1e33-4b7e-9f0a-2c4d6e8f0a1b' } }
            Mock Get-GpuVMGuestCredential { [pscredential]::new('u', (ConvertTo-SecureString 'p' -AsPlainText -Force)) }
            Mock Get-GpuVMAgentRoot { Join-Path $TestDrive 'agents' }
            Mock Initialize-AgentFolder { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
            Mock Get-AgentPackage {
                $dist = Join-Path $TestDrive 'dist'
                New-Item -ItemType Directory "$dist\sub" -Force | Out-Null
                [IO.File]::WriteAllText("$dist\agent.exe", 'x'); [IO.File]::WriteAllText("$dist\sub\lib.dll", 'yyy')
                [pscustomobject]@{ Install = 'install.ps1'; Dist = $dist; Files = @(Get-ChildItem $dist -File -Recurse); Version = '1.0.0' }
            }
            Mock Get-GuestServiceInterface { [pscustomobject]@{ Name = 'Guest Service Interface'; Enabled = $false } }
            Mock Enable-VMIntegrationService { $script:gsi.Add('on') }
            Mock Disable-VMIntegrationService { $script:gsi.Add('off') }
            Mock Copy-AgentFileToGuest { $script:copied.Add("$Destination|$((Get-Item $Source).Length)") }
            Mock Invoke-Command { if ($FilePath) { [pscustomobject]@{ password = 'S3cret!'; version = '1.2.3' } } }
            Mock Write-AgentSecret { }
            Mock Save-GpuVMState { $script:saved = $State }
            Mock Write-JsonFile { $script:registration = $Data }
            Mock Write-Step { }
        }
        It 'copies the secret and the files, turns the Guest Service Interface off again and saves the password encrypted' {
            $r = Install-GpuVMAgent -Name vm1
            $r.vmId | Should Be '0b5d1f53-1e33-4b7e-9f0a-2c4d6e8f0a1b'
            $r.version | Should Be '1.2.3'
            ($script:gsi -join ',') | Should Be 'on,off'
            $script:copied[0] | Should Be 'C:\ProgramData\GpuVM\Agent\secret|32'
            $script:copied -contains 'C:\ProgramData\GpuVM\Agent\staging\sub\lib.dll|3' | Should Be $true
            Assert-MockCalled Write-AgentSecret -Times 1 -Scope It -ParameterFilter { $Secret.Length -eq 32 }
            $script:saved['agent']['password'] | Should Not Be 'S3cret!'
            (ConvertTo-SecureString $script:saved['agent']['password'] | ConvertFrom-SecureString -AsPlainText) | Should Be 'S3cret!'
            $script:registration['name'] | Should Be 'vm1'
            $script:registration['folder'] | Should Be 'D:\GpuVM\vm1'
            # The plain copy of the secret doesn't stay behind.
            @(Get-ChildItem (Join-Path $TestDrive 'agents') -Recurse -File -Filter 'copy-*').Count | Should Be 0
        }
        It 'a failed copy keeps the old secret and still turns the Guest Service Interface off' {
            Mock Copy-AgentFileToGuest { throw 'copy failed' }
            Test-Throws { Install-GpuVMAgent -Name vm1 } | Should Be $true
            ($script:gsi -join ',') | Should Be 'on,off'
            Assert-MockCalled Write-AgentSecret -Times 0 -Scope It
            @(Get-ChildItem (Join-Path $TestDrive 'agents') -Recurse -File -Filter 'copy-*').Count | Should Be 0
        }
        It 'leaves the Guest Service Interface on when it already was' {
            Mock Get-GuestServiceInterface { [pscustomobject]@{ Name = 'Guest Service Interface'; Enabled = $true } }
            Install-GpuVMAgent -Name vm1 | Out-Null
            $script:gsi.Count | Should Be 0
        }
        It 'refuses a machine that is off' {
            Mock Get-VM { [pscustomobject]@{ State = 'Off'; Id = [guid]::NewGuid() } }
            Test-Throws { Install-GpuVMAgent -Name vm1 } | Should Be $true
            Assert-MockCalled Copy-AgentFileToGuest -Times 0 -Scope It
        }
    }
}
