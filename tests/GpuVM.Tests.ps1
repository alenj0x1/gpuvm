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
        # An elevated module ignores the variable (by design), so the folder is also redirected here: an elevated run
        # never writes labs into the repository.
        Mock Get-LabRoot { Join-Path $TestDrive 'labs' }

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
        # Elevated, the module ignores the variable (by design): the cache is redirected here as well.
        Mock Get-ComponentCacheRoot { Join-Path $TestDrive 'cache' }

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
            Mock Get-SunshineForkFiles {
                [pscustomobject]@{ Key = 'sunshine.exe'; Path = 'C:\b\sunshine.exe'; Hash = 'H1' }
                [pscustomobject]@{ Key = 'tools\sunshine_wgc_capture.exe'; Path = 'C:\b\tools\sunshine_wgc_capture.exe'; Hash = 'H2' }
            }
            $payload = New-StreamingPayload -Config (Resolve-GpuVMProfile -Name 'balanced')
            # The four components plus GpuVM's Sunshine fork, which goes over the official install.
            @($payload.GuestFiles).Count | Should Be 6
            $fork = @($payload.GuestFiles | Where-Object { $_.Source -like 'C:\b\*' })
            ($fork | Where-Object Sha256 -eq 'H2').Destination | Should Be 'streaming\fork\tools'
            ($fork | Where-Object Sha256 -eq 'H1').Destination.TrimEnd('\') | Should Be 'streaming\fork'
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
            Mock Copy-Item { $script:copied += @($LiteralPath); $script:into += @($Destination) }
            Mock Remove-PSSession { }
            Mock Write-Step { }
            Mock New-GuestAdminFolder { 'C:\Windows\Temp\GpuVM-audio-1' }
            Mock Remove-GuestAdminFolder { $script:removed = $Path }
            $script:copied = @(); $script:into = @(); $script:removed = $null
            Install-GuestAudio -Name 'vm' -Credential $cred | Should Be $true
            ($script:copied | Split-Path -Leaf) -join ',' | Should Be 'USBip-0.9.8.0-x64.exe,UsbAudioServer.cs'
            # Into a folder of this run only administrators can open, not C:\GpuVM (security review 2026-11-21).
            ($script:into -join ',') | Should Be 'C:\Windows\Temp\GpuVM-audio-1\streaming,C:\Windows\Temp\GpuVM-audio-1\audio'
            $script:removed | Should Be 'C:\Windows\Temp\GpuVM-audio-1'
        }

        It 'checks and runs the gamepad driver''s installer from a folder only administrators can open' {
            $cred = [pscredential]::new('gpuvm', (ConvertTo-SecureString 'x' -AsPlainText -Force))
            Mock Invoke-Guest { $false }
            Mock Write-Step { }
            Mock Save-GpuVMComponent { 'C:\cache\vigembus\ViGEmBus_1.22.0_x64_x86_arm64.exe' }
            Mock Get-ComponentManifest { @{ vigembus = @{ sha256 = 'ABC' } } }
            Mock New-PSSession { [Runtime.Serialization.FormatterServices]::GetUninitializedObject([System.Management.Automation.Runspaces.PSSession]) }
            Mock Remove-PSSession { }
            Mock New-GuestAdminFolder { 'C:\Windows\Temp\GpuVM-gamepad-1' }
            Mock Remove-GuestAdminFolder { $script:removed = $Path }
            Mock Copy-Item { $script:into = $Destination }
            Mock Invoke-Command { $script:ran = $ArgumentList[0]; 'ok' } -ParameterFilter { $Session }
            Install-GuestGamepad -Name 'vm' -Credential $cred | Should Be $true
            $script:into | Should Be 'C:\Windows\Temp\GpuVM-gamepad-1'
            $script:ran | Should Be 'C:\Windows\Temp\GpuVM-gamepad-1\ViGEmBus_1.22.0_x64_x86_arm64.exe'
            $script:removed | Should Be 'C:\Windows\Temp\GpuVM-gamepad-1'
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
        It 'works with no other VM on the drive (no disks at all, or only its own)' {
            $free = [math]::Round(([IO.DriveInfo]::new('C:')).AvailableFreeSpace / 1GB, 1)
            Mock Get-VMDiskUsage { }
            $none = Get-GpuVMDiskBudget -Root 'C:\GpuVM'
            $none['promisedGB'] | Should Be 0
            $none['availableGB'] | Should Be ([math]::Max(0, [math]::Floor($free - $script:DiskMarginGB)))
            @($none['others']).Count | Should Be 0
            Mock Get-VMDiskUsage { [pscustomobject]@{ VM = 'a'; Path = 'C:\vm\a.vhdx'; Drive = 'C:'; SizeGB = 64; FileGB = 14; GrowthGB = 50; Type = 'Dynamic' } }
            (Get-GpuVMDiskBudget -Root 'C:\GpuVM' -VMName 'a')['promisedGB'] | Should Be 0
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
                'Stop-GpuVMAgentClient', 'New-GpuVMAgentOffer', 'Get-GpuVMAgentOffer', 'Resolve-GpuVMAgentOffer', 'Get-GpuVMAgentClient',
                'Get-GpuVMAgentCapture', 'Get-GpuVMAgentRequest', 'Resolve-GpuVMAgentRequest', 'Get-GpuVMAgentSettings', 'Set-GpuVMAgentSettings',
                'Set-GpuVMAgentClient'
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
            $r = Resolve-GpuVMAgentOffer -Id 'ab' -Accept $true
            $r.Arguments['Accept'] | Should Be $true
            $r = Suspend-GpuVMAgent -Connection '*' -Reason control
            $r.Arguments['Reason'] | Should BeExactly 'control'
            Test-Throws { Suspend-GpuVMAgent -Name x -Reason 'nap' } | Should Be $true
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
        It 'a registration is removed by the service (its secret is SYSTEM-only); unreachable is a warning' {
            Mock Get-GpuVMAgentRoot { Join-Path $TestDrive 'agents' }
            Mock Invoke-AgentBroker { $script:sent = @{ Command = $Command; Arguments = $Arguments } }
            $id = '0B5D1F53-1E33-4B7E-9F0A-2C4D6E8F0A1B'
            $script:sent = $null
            Remove-GpuVMAgentRegistration -VMId $id
            $script:sent | Should Be $null
            New-Item -ItemType Directory (Join-Path $TestDrive "agents\$($id.ToLowerInvariant())") -Force | Out-Null
            Remove-GpuVMAgentRegistration -VMId $id
            $script:sent.Command | Should Be 'Remove-GpuVMAgentRegistration'
            $script:sent.Arguments['VmId'] | Should Be '0b5d1f53-1e33-4b7e-9f0a-2c4d6e8f0a1b'
            Mock Invoke-AgentBroker { throw 'no service' }
            $w = Remove-GpuVMAgentRegistration -VMId $id 3>&1
            ($w | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }).Message | Should Match 'within the hour'
        }
        It 'the secret goes to the service, which stores it as SYSTEM' {
            Mock Invoke-AgentBroker { $script:sent = @{ Command = $Command; Arguments = $Arguments } }
            Write-AgentSecret -Folder 'C:\ProgramData\GpuVM\agents\0b5d1f53-1e33-4b7e-9f0a-2c4d6e8f0a1b' -Secret ([byte[]](1..32))
            $script:sent.Command | Should Be 'Set-GpuVMAgentSecret'
            $script:sent.Arguments['VmId'] | Should Be '0b5d1f53-1e33-4b7e-9f0a-2c4d6e8f0a1b'
            ([Convert]::FromBase64String($script:sent.Arguments['Secret'])).Length | Should Be 32
        }
    }

    Describe 'Install-GpuVMAgent' {
        BeforeEach {
            $script:calls = [System.Collections.Generic.List[string]]::new()
            $script:sentSecret = $null
            $script:sameBuild = $false
            Mock Assert-Admin { }
            Mock Get-GpuVMState { @{ statePath = 'D:\GpuVM\vm1\gpuvm.json'; guest = @{ user = 'u' } } }
            Mock Get-VM { [pscustomobject]@{ State = 'Running'; Id = [guid]'0b5d1f53-1e33-4b7e-9f0a-2c4d6e8f0a1b' } }
            Mock Get-GpuVMGuestCredential { [pscredential]::new('u', (ConvertTo-SecureString 'p' -AsPlainText -Force)) }
            Mock Get-GpuVMAgentRoot { Join-Path $TestDrive 'agents' }
            Mock Initialize-AgentFolder { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
            Mock Get-AgentPackage {
                [IO.File]::WriteAllText("$TestDrive\install.ps1", 'param($Source, $Secret) "installed"')
                [IO.File]::WriteAllText("$TestDrive\gpuvm-agent.exe", 'x'); [IO.File]::WriteAllText("$TestDrive\VERSION", '0.1.0')
                [pscustomobject]@{ Install = "$TestDrive\install.ps1"; Exe = "$TestDrive\gpuvm-agent.exe"; Version = '0.1.0'; Hash = 'ABC'
                    Files = @(Get-Item "$TestDrive\gpuvm-agent.exe", "$TestDrive\VERSION") }
            }
            Mock New-PSSession { [pscustomobject]@{ Name = 'fake' } }
            Mock Close-AgentSession { }
            Mock Wait-GuestReady { }
            Mock Assert-AgentSwitch { $script:calls.Add('switch checked') }
            Mock Enable-GuestHyperVVideo { $script:calls.Add('video on'); 'ok' }
            Mock Restart-GpuVMCold { $script:calls.Add('restart') }
            Mock Update-GpuVMNetworkIsolation { $script:calls.Add('isolated') }
            Mock Sync-GuestAgentDisplayMode { $script:calls.Add('mode') }
            Mock Copy-ToAgentSession { $script:calls.Add("copy-to-session $Destination") }
            # Which guest call it is, by its arguments: setup (hash), fast-path copy (2 paths), installer (text, dir,
            # secret), cleanup (dir), restart (none).
            Mock Invoke-InAgentSession { Invoke-FakeGuest $ArgumentList }
            Mock Invoke-Command { Invoke-FakeGuest $ArgumentList }
            function script:Invoke-FakeGuest($ArgumentList) {
                $a = @($ArgumentList)
                if ($a.Count -eq 1 -and $a[0] -eq 'ABC') {
                    $script:calls.Add('setup')
                    return [pscustomobject]@{ Dir = 'C:\Windows\Temp\GpuVMAgentSetup-1'; Same = $script:sameBuild; Installed = 'C:\Program Files\GpuVM Agent\gpuvm-agent.exe' }
                }
                if ($a.Count -eq 4) {
                    $script:calls.Add('install')
                    $script:sentSecret = [byte[]]$a[2].Clone()   # over PowerShell Direct it is a copy
                    return [pscustomobject]@{ ok = $true; password = 'S3cret!'; version = '0.1.0'; rebootNeeded = $true }
                }
                if ($a.Count -eq 3) { $script:calls.Add('fast-copy'); return }
                if ($a.Count -eq 1) { $script:calls.Add('cleanup'); return }
                $script:calls.Add('restart')
            }
            Mock Write-AgentSecret { $script:storedSecret = [byte[]]$Secret.Clone() }
            Mock Save-GpuVMState { $script:saved = $State }
            Mock Write-JsonFile { $script:registration = $Data }
            Mock Write-Step { }
            Mock Install-GuestWinget { $script:calls.Add('winget'); 'current' }
        }
        It 'sends the exe and a new 32-byte secret, keeps the password encrypted and restarts Windows from inside' {
            $r = Install-GpuVMAgent -Name vm1
            $r.vmId | Should Be '0b5d1f53-1e33-4b7e-9f0a-2c4d6e8f0a1b'
            $r.exeSent | Should Be $true
            ($script:calls -join ',') | Should Be 'switch checked,video on,setup,copy-to-session C:\Windows\Temp\GpuVMAgentSetup-1\gpuvm-agent.exe,copy-to-session C:\Windows\Temp\GpuVMAgentSetup-1\VERSION,install,cleanup,winget,isolated,restart'
            $r.winget | Should Be 'current'
            $script:sentSecret.GetType().Name | Should Be 'Byte[]'
            $script:sentSecret.Length | Should Be 32
            Assert-MockCalled Write-AgentSecret -Times 1 -Scope It
            # The host keeps exactly what the guest got (the local copy is wiped afterwards).
            ([Convert]::ToBase64String($script:storedSecret)) | Should Be ([Convert]::ToBase64String($script:sentSecret))
            $script:saved['agent']['password'] | Should Not Be 'S3cret!'
            (ConvertTo-SecureString $script:saved['agent']['password'] | ConvertFrom-SecureString -AsPlainText) | Should Be 'S3cret!'
            $script:registration['name'] | Should Be 'vm1'
            $script:registration['folder'] | Should Be 'D:\GpuVM\vm1'
        }
        It 'a copy of a template with the same build skips sending the exe' {
            $script:sameBuild = $true
            $r = Install-GpuVMAgent -Name vm1
            $r.exeSent | Should Be $false
            ($script:calls -join ',') | Should Be 'switch checked,video on,setup,fast-copy,install,cleanup,winget,isolated,restart'
        }
        It 'a failed winget install leaves the agent installed and says so' {
            Mock Install-GuestWinget { throw 'no room' }
            $r = Install-GpuVMAgent -Name vm1 3>$null
            $r.winget | Should Be 'failed'
            Assert-MockCalled Write-AgentSecret -Times 1 -Scope It
        }
        It 'a failed install keeps the old secret' {
            Mock Copy-ToAgentSession { throw 'copy failed' }
            Test-Throws { Install-GpuVMAgent -Name vm1 } | Should Be $true
            Assert-MockCalled Write-AgentSecret -Times 0 -Scope It
            $script:calls -contains 'cleanup' | Should Be $true
        }
        It 'refuses a machine that is off' {
            Mock Get-VM { [pscustomobject]@{ State = 'Off'; Id = [guid]::NewGuid() } }
            Test-Throws { Install-GpuVMAgent -Name vm1 } | Should Be $true
            Assert-MockCalled New-PSSession -Times 0 -Scope It
        }
    }

    Describe 'Templates never carry an agent secret' {
        It 'removes the secret from a mounted guest disk and refuses a planted link' {
            $root = Join-Path $TestDrive 'win'
            New-Item -ItemType Directory "$root\ProgramData\GpuVM\Agent" -Force | Out-Null
            [IO.File]::WriteAllBytes("$root\ProgramData\GpuVM\Agent\secret", [byte[]](1..32))
            Remove-GuestAgentSecret -WindowsRoot $root
            Test-Path "$root\ProgramData\GpuVM\Agent\secret" | Should Be $false
            Remove-GuestAgentSecret -WindowsRoot $root   # nothing there: no error
        }
    }

    Describe 'Template layers' {
        BeforeEach {
            Mock Get-GpuVMDefaultRoot { Join-Path $TestDrive 'root' }
            $script:dir = Join-Path $TestDrive 'root\.templates\tpl'
            New-Item -ItemType Directory $script:dir -Force | Out-Null
            'x' | Set-Content (Join-Path $script:dir 'tpl.vhdx')
        }
        It 'a template without layers is its one disk; with layers, copies sit on the last one' {
            Write-JsonFile -Path (Join-Path $script:dir 'template.json') -Data @{ sizeGB = 64 }
            $t = Read-GpuVMTemplate -Name tpl
            $t['vhdPath'] | Should Be (Join-Path $script:dir 'tpl.vhdx')
            @($t['layerPaths']).Count | Should Be 1
            'x' | Set-Content (Join-Path $script:dir 'tpl.1.vhdx')
            Write-JsonFile -Path (Join-Path $script:dir 'template.json') -Data @{ sizeGB = 64; layers = @('tpl.vhdx', 'tpl.1.vhdx') }
            $t = Read-GpuVMTemplate -Name tpl
            $t['vhdPath'] | Should Be (Join-Path $script:dir 'tpl.1.vhdx')
            @($t['layerPaths']).Count | Should Be 2
        }
        It 'refuses a layer outside its folder or missing' {
            Write-JsonFile -Path (Join-Path $script:dir 'template.json') -Data @{ layers = @('tpl.vhdx', '..\..\x.vhdx') }
            Test-Throws { Read-GpuVMTemplate -Name tpl } | Should Be $true
            Write-JsonFile -Path (Join-Path $script:dir 'template.json') -Data @{ layers = @('tpl.vhdx', 'tpl.9.vhdx') }
            Test-Throws { Read-GpuVMTemplate -Name tpl } | Should Be $true
        }
        It 'a template is stale without stamps or when GpuVM''s Sunshine (or an agent template''s agent) differs' {
            $b = [ordered]@{ 'Program Files\GpuVM Agent\gpuvm-agent.exe' = 'A1'; 'Program Files\Sunshine\sunshine.exe' = 'S1' }
            $s = @{ provider = 'sunshine' }
            Test-GpuVMTemplateStale -Template @{ use = 'agent'; streaming = $s } -Bundled $b | Should Be $true
            Test-GpuVMTemplateStale -Template @{ use = 'agent'; streaming = $s; components = @{ 'Program Files\GpuVM Agent\gpuvm-agent.exe' = 'A1'; 'Program Files\Sunshine\sunshine.exe' = 'S0' } } -Bundled $b | Should Be $true
            Test-GpuVMTemplateStale -Template @{ use = 'agent'; streaming = $s; gamepad = 'vigembus'; components = @{ 'Program Files\GpuVM Agent\gpuvm-agent.exe' = 'A1'; 'Program Files\Sunshine\sunshine.exe' = 'S1' } } -Bundled $b | Should Be $false
            # A normal machine's template: only Sunshine counts.
            Test-GpuVMTemplateStale -Template @{ streaming = $s; components = @{ 'Program Files\Sunshine\sunshine.exe' = 'S0' } } -Bundled $b | Should Be $true
            Test-GpuVMTemplateStale -Template @{ streaming = $s; gamepad = 'vigembus'; components = @{ 'Program Files\Sunshine\sunshine.exe' = 'S1' } } -Bundled $b | Should Be $false
            # ...and the controllers' driver: a template without it is stale (its copies would install it on every first open).
            Test-GpuVMTemplateStale -Template @{ streaming = $s; components = @{ 'Program Files\Sunshine\sunshine.exe' = 'S1' } } -Bundled $b | Should Be $true
            # No streaming and no agent: nothing of GpuVM's to keep current.
            Test-GpuVMTemplateStale -Template @{ use = $null } -Bundled $b | Should Be $false
        }
        It 'reads the stamp from a mounted Windows and refuses a planted link' {
            $root = Join-Path $TestDrive 'win2'
            New-Item -ItemType Directory "$root\Program Files\Sunshine" -Force | Out-Null
            [IO.File]::WriteAllText("$root\Program Files\Sunshine\sunshine.exe", 'abc')
            $s = Get-GuestComponentStamp -WindowsRoot $root -Keys 'Program Files\Sunshine\sunshine.exe', 'Program Files\GpuVM Agent\gpuvm-agent.exe'
            $s['Program Files\Sunshine\sunshine.exe'] | Should Be 'BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD'
            $s['Program Files\GpuVM Agent\gpuvm-agent.exe'] | Should Be $null
            New-Item -ItemType Junction -Path "$root\Program Files\GpuVM Agent" -Target $TestDrive | Out-Null
            Test-Throws { Get-GuestComponentStamp -WindowsRoot $root -Keys 'Program Files\GpuVM Agent\gpuvm-agent.exe' } | Should Be $true
        }
        It 'an update marker counts only while its process lives and for an hour' {
            $t = @{ dir = $script:dir }
            Test-TemplateUpdating -Template $t | Should Be $false
            Write-JsonFile -Path (Join-Path $script:dir 'updating.json') -Data @{ pid = $PID; startedAt = (Get-Date).ToUniversalTime().ToString('o') }
            Test-TemplateUpdating -Template $t | Should Be $true
            Write-JsonFile -Path (Join-Path $script:dir 'updating.json') -Data @{ pid = $PID; startedAt = (Get-Date).AddHours(-2).ToUniversalTime().ToString('o') }
            Test-TemplateUpdating -Template $t | Should Be $false
        }
        It 'Update-GpuVMTemplate -Stale leaves current templates and ones without streaming alone' {
            Mock Assert-Admin { }
            $k = 'Program Files\Sunshine\sunshine.exe'
            Mock Get-BundledComponentStamp { [ordered]@{ 'Program Files\Sunshine\sunshine.exe' = 'v' } }
            Mock Add-TemplateLayer { @{ name = $Template['name'] } }
            Write-JsonFile -Path (Join-Path $script:dir 'template.json') -Data @{ streaming = @{ provider = 'sunshine' }; gamepad = 'vigembus'; components = @{ $k = 'v' } }
            Update-GpuVMTemplate -Stale -Confirm:$false
            Assert-MockCalled Add-TemplateLayer -Times 0 -Scope It
            Write-JsonFile -Path (Join-Path $script:dir 'template.json') -Data @{ streaming = @{ provider = 'sunshine' }; components = @{ $k = 'old' } }
            (Update-GpuVMTemplate -Stale -Confirm:$false).name | Should Be 'tpl'
            Write-JsonFile -Path (Join-Path $script:dir 'template.json') -Data @{ use = $null }
            Update-GpuVMTemplate -Stale -Confirm:$false
            Assert-MockCalled Add-TemplateLayer -Times 1 -Scope It
        }
        It 'a failed update waits a day before -Stale tries it again; naming the template tries at once' {
            Mock Assert-Admin { }
            Mock Get-BundledComponentStamp { [ordered]@{ 'Program Files\Sunshine\sunshine.exe' = 'v' } }
            Mock Add-TemplateLayer { @{ name = $Template['name'] } }
            Write-JsonFile -Path (Join-Path $script:dir 'template.json') -Data @{ streaming = @{ provider = 'sunshine' } }
            Write-JsonFile -Path (Join-Path $script:dir 'update-failed.json') -Data @{ at = (Get-Date).ToUniversalTime().AddHours(-2).ToString('o'); message = 'x' }
            Update-GpuVMTemplate -Stale -Confirm:$false
            Assert-MockCalled Add-TemplateLayer -Times 0 -Scope It
            (Update-GpuVMTemplate -Name tpl -Confirm:$false).name | Should Be 'tpl'
            Write-JsonFile -Path (Join-Path $script:dir 'update-failed.json') -Data @{ at = (Get-Date).ToUniversalTime().AddDays(-2).ToString('o'); message = 'x' }
            (Update-GpuVMTemplate -Stale -Confirm:$false).name | Should Be 'tpl'
        }
        It 'writes JSON whole: a failed write leaves the old file' {
            $p = Join-Path $TestDrive 'atomic.json'
            Write-JsonFile -Path $p -Data @{ a = 1 }
            Write-JsonFile -Path $p -Data @{ a = 2 }
            (Read-JsonFile $p)['a'] | Should Be 2
            Mock ConvertTo-Json { throw 'the write failed' }
            Test-Throws { Write-JsonFile -Path $p -Data @{ a = 3 } } | Should Be $true
            (Read-JsonFile $p)['a'] | Should Be 2
            @(Get-ChildItem $TestDrive -Filter 'atomic.json.*.tmp').Count | Should Be 0
        }
    }

    Describe 'winget for the agent''s user' {
        It 'the manifest pins one release of Microsoft''s winget-cli for the bundle, its frameworks and its license' {
            $m = Get-ComponentManifest
            $keys = 'winget', 'winget-dependencies', 'winget-license'
            foreach ($key in $keys) {
                $m[$key]['repo'] | Should Be 'microsoft/winget-cli'
                $m[$key]['sha256'] | Should Match '^[0-9a-f]{64}$'
                $m[$key]['url'] | Should Be "https://github.com/microsoft/winget-cli/releases/download/$($m[$key]['version'])/$($m[$key]['file'])"
                $m[$key]['file'] | Should Match $m[$key]['assetPattern']
            }
            @($keys | ForEach-Object { $m[$_]['version'] } | Select-Object -Unique).Count | Should Be 1
        }
        It 'the stamp names every file''s hash and the policies, and its hash is what a template''s disk would read' {
            $m = @{ winget = @{ sha256 = 'a' }; 'winget-dependencies' = @{ sha256 = 'b' }; 'winget-license' = @{ sha256 = 'c' } }
            Get-WingetStampText -Manifest $m | Should Be "winget=a;winget-dependencies=b;winget-license=c;policy=$script:WingetPolicyVersion"
            $file = Join-Path $TestDrive 'winget-stamp'
            [IO.File]::WriteAllText($file, (Get-WingetStampText -Manifest $m))
            Get-WingetStampHash -Manifest $m | Should Be (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
            $m['winget']['sha256'] = 'z'
            Get-WingetStampHash -Manifest $m | Should Not Be (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
            Get-WingetStampText -Manifest @{ winget = @{ sha256 = 'a' } } | Should BeNullOrEmpty
        }
        It 'locks the settings a user could turn on and drops the Store source (its agreement prompt)' {
            foreach ($name in 'EnableMicrosoftStoreSource', 'EnableHashOverride', 'EnableLocalManifestFiles', 'EnableLocalArchiveMalwareScanOverride', 'EnableBypassCertificatePinningForMicrosoftStore', 'EnableMSAppInstallerProtocol') {
                $script:WingetPolicies[$name] | Should Be 0
            }
        }
        It 'an agent template must carry winget; a template that only streams doesn''t' {
            $b = [ordered]@{ 'Program Files\GpuVM Agent\gpuvm-agent.exe' = 'A1'; $script:WingetStampKey = 'W1'; 'Program Files\Sunshine\sunshine.exe' = 'S1' }
            $s = @{ provider = 'sunshine' }
            @(Get-TemplateComponentKeys -Template @{ use = 'agent'; streaming = $s } -Bundled $b) -contains $script:WingetStampKey | Should Be $true
            @(Get-TemplateComponentKeys -Template @{ streaming = $s } -Bundled $b) -contains $script:WingetStampKey | Should Be $false
            $have = @{ 'Program Files\GpuVM Agent\gpuvm-agent.exe' = 'A1'; 'Program Files\Sunshine\sunshine.exe' = 'S1' }
            Test-GpuVMTemplateStale -Template @{ use = 'agent'; streaming = $s; gamepad = 'vigembus'; components = $have } -Bundled $b | Should Be $true
            $have[$script:WingetStampKey] = 'W1'
            Test-GpuVMTemplateStale -Template @{ use = 'agent'; streaming = $s; gamepad = 'vigembus'; components = $have } -Bundled $b | Should Be $false
        }
        It 'this build''s stamp lists winget only when it carries the agent' {
            Mock Get-SunshineForkFiles { @() }
            Mock Get-AgentPackage { [pscustomobject]@{ Hash = 'A1' } }
            (Get-BundledComponentStamp)[$script:WingetStampKey] | Should Be (Get-WingetStampHash)
            Mock Get-AgentPackage { throw 'no agent in this build' }
            (Get-BundledComponentStamp).Contains($script:WingetStampKey) | Should Be $false
        }
        Context 'Install-GuestWinget' {
            BeforeEach {
                $script:calls = [System.Collections.Generic.List[string]]::new()
                $script:guestStamp = ''
                Mock Write-Step { }
                Mock Get-WingetPackage {
                    $script:calls.Add('package')
                    [pscustomobject]@{ Stamp = (Get-WingetStampText); Version = 'v1'; Files = @(
                        [pscustomobject]@{ Path = 'C:\cache\b.msixbundle'; Name = 'b.msixbundle'; Sha256 = 'B'; Role = 'bundle' }
                        [pscustomobject]@{ Path = 'C:\cache\l.xml'; Name = 'l.xml'; Sha256 = 'L'; Role = 'license' }) }
                }
                Mock Copy-ToAgentSession { $script:calls.Add("copy $Destination") }
                # By arguments: stamp read (its path), folder (none), provisioning (5), cleanup (the folder).
                Mock Invoke-InAgentSession {
                    $a = @($ArgumentList)
                    if ($a.Count -eq 0) { $script:calls.Add('folder'); return 'C:\Windows\Temp\GpuVMWinget-1' }
                    if ($a.Count -eq 5) { $script:calls.Add('provision'); if ($script:provisionFails) { throw 'Add-AppxProvisionedPackage failed' }; return '1.29.380.0' }
                    if ($a[0] -like '*\GpuVMWinget-*') { $script:calls.Add('cleanup'); return }
                    $script:calls.Add('read stamp'); $script:guestStamp
                }
                $script:provisionFails = $false
            }
            It 'a machine with this release only reads its stamp' {
                $script:guestStamp = Get-WingetStampText
                Install-GuestWinget -Session 'fake' | Should Be 'current'
                ($script:calls -join ',') | Should Be 'read stamp'
            }
            It 'otherwise sends the verified files into an administrators-only folder, provisions them and cleans up' {
                $script:guestStamp = 'winget=old'
                Install-GuestWinget -Session 'fake' | Should Be 'installed'
                ($script:calls -join ',') | Should Be 'read stamp,package,folder,copy C:\Windows\Temp\GpuVMWinget-1\b.msixbundle,copy C:\Windows\Temp\GpuVMWinget-1\l.xml,provision,cleanup'
            }
            It 'a failed provisioning still removes the files' {
                $script:provisionFails = $true
                Test-Throws { Install-GuestWinget -Session 'fake' } | Should Be $true
                $script:calls[-1] | Should Be 'cleanup'
            }
        }
        Context 'Get-WingetPackage' {
            BeforeEach {
                $script:cache = Join-Path $TestDrive 'wg'
                New-Item -ItemType Directory $script:cache -Force | Out-Null
                Add-Type -AssemblyName System.IO.Compression.FileSystem
                $src = Join-Path $TestDrive 'zipsrc'
                New-Item -ItemType Directory "$src\x64", "$src\arm64" -Force | Out-Null
                'v' | Set-Content "$src\x64\Microsoft.VCLibs.140.00_14.0_x64.appx"
                'a' | Set-Content "$src\arm64\Microsoft.VCLibs.140.00_14.0_arm64.appx"
                $zip = Join-Path $script:cache 'deps.zip'
                Remove-Item $zip -ErrorAction SilentlyContinue
                [IO.Compression.ZipFile]::CreateFromDirectory($src, $zip)
                'b' | Set-Content (Join-Path $script:cache 'b.msixbundle')
                'l' | Set-Content (Join-Path $script:cache 'l.xml')
                Mock Save-GpuVMComponent { Join-Path $script:cache @{ winget = 'b.msixbundle'; 'winget-license' = 'l.xml'; 'winget-dependencies' = 'deps.zip' }[$Name] }
                Mock Test-MicrosoftSignature { $true }
            }
            It 'takes only the x64 frameworks out of the zip and hashes every file' {
                $p = Get-WingetPackage
                @($p.Files | Where-Object Role -eq 'dependency').Name | Should Be 'Microsoft.VCLibs.140.00_14.0_x64.appx'
                @($p.Files).Count | Should Be 3
                ($p.Files | Where-Object Role -eq 'bundle').Sha256 | Should Be (Get-FileHash (Join-Path $script:cache 'b.msixbundle')).Hash
            }
            It 'refuses a package without Microsoft''s signature' {
                Mock Test-MicrosoftSignature { $Path -notlike '*.msixbundle' }
                Test-Throws { Get-WingetPackage } | Should Be $true
                Mock Test-MicrosoftSignature { $Path -notlike '*.appx' }
                Test-Throws { Get-WingetPackage } | Should Be $true
            }
            It 'refuses components from different releases' {
                $script:mixed = Get-ComponentManifest
                $script:mixed['winget-license']['version'] = 'v0.0.1'
                Mock Get-ComponentManifest { $script:mixed }
                Test-Throws { Get-WingetPackage } | Should Be $true
            }
        }
    }
}

InModuleScope GpuVM {
    Describe 'Set-GpuVMUse' {
        BeforeEach {
            $script:st = @{ statePath = 'D:\GpuVM\vm1\gpuvm.json'; config = @{ vm = @{ network = @{ isolation = $false } } } }
            Mock Assert-Admin { }
            Mock Get-GpuVMState { $script:st }
            Mock Save-GpuVMState { $script:st = $State }
            Mock Update-GpuVMNetworkIsolation { }
            Mock Install-GpuVMAgent { [pscustomobject]@{ restarted = $true; user = $User } }
            Mock Uninstall-GpuVMAgent { }
            Mock Write-Warning { }
        }
        It 'an agent machine is always isolated; off, the agent waits for the next start' {
            Mock Get-VM { [pscustomobject]@{ State = 'Off' } }
            $r = Set-GpuVMUse -Name vm1 -Use agent
            $r.pending | Should Be $true
            $script:st['use'] | Should Be 'agent'
            $script:st['config']['vm']['network']['isolation'] | Should Be $true
            $script:st['agent']['pending'] | Should Be $true
            Assert-MockCalled Update-GpuVMNetworkIsolation -Times 1 -Scope It
            Assert-MockCalled Install-GpuVMAgent -Times 0 -Scope It
        }
        It 'running, it installs the agent with the chosen sign-in user and leaves the display to the agent' {
            Mock Get-VM { [pscustomobject]@{ State = 'Running' } }
            Mock Set-GuestDisplayResolution { throw 'the agent keeps its own display' }
            $script:st['agent'] = @{ signInAs = 'own' }
            $r = Set-GpuVMUse -Name vm1 -Use agent
            Assert-MockCalled Install-GpuVMAgent -Times 1 -Scope It -ParameterFilter { $User -eq 'own' }
            Assert-MockCalled Set-GuestDisplayResolution -Times 0 -Scope It
            $r.Contains('display') | Should Be $false
        }
        It 'none removes the agent and the use' {
            $script:st['use'] = 'agent'; $script:st['agent'] = @{ version = '0.3.0' }
            Set-GpuVMUse -Name vm1 -Use none | Out-Null
            Assert-MockCalled Uninstall-GpuVMAgent -Times 1 -Scope It
            $script:st.Contains('use') | Should Be $false
        }
    }
}

InModuleScope GpuVM {
    Describe 'Home says "not paired" only where the person pairs' {
        BeforeEach {
            Mock Assert-Admin { }
            Mock Get-CimInstance { [pscustomobject]@{ FreePhysicalMemory = 8MB; TotalVisibleMemorySize = 16MB } }
            Mock Get-GpuVMDefaultRoot { 'D:\GpuVM' }
            Mock Get-DriveFreeGB { 500 }
            Mock Get-FittingMemoryGB { 4 }
            Mock Get-HostGpu { $null }
            Mock Get-Process { @() }
            Mock Get-VM { @([pscustomobject]@{ Name = 'own'; State = 'Off'; MemoryStartup = 4GB }, [pscustomobject]@{ Name = 'agent1'; State = 'Off'; MemoryStartup = 4GB },
                    [pscustomobject]@{ Name = 'copy1'; State = 'Off'; MemoryStartup = 4GB }) }
            Mock Test-GpuVMDisposable { $State['disposable'] -ne $null }
            Mock Get-GpuVMState {
                $s = @{ guest = @{ user = 'u' }; streaming = @{ pairedClient = $null }; config = @{ gpu = @{ match = 'x' } } }
                if ($Name -eq 'agent1') { $s['use'] = 'agent' }
                if ($Name -eq 'copy1') { $s['disposable'] = @{ createdAt = (Get-Date).ToString('o') } }
                $s
            }
        }
        It 'warns on the person''s machine, never on agent machines or disposable copies (GpuVM pairs those itself)' {
            $pairing = @((Get-GpuVMHome).attention | Where-Object { $_['kind'] -eq 'pairing' })
            $pairing.Count | Should Be 1
            $pairing[0]['vm'] | Should Be 'own'
        }
    }
}

InModuleScope GpuVM {
    Describe 'Disposable machines just created' {
        It 'keeps a machine created a moment ago, whatever form its date has after reading the JSON' {
            $now = Get-Date
            foreach ($created in @($now, $now.ToString('o'), (Get-Date).ToUniversalTime().ToString('o'))) {
                $state = @{ disposable = @{ createdAt = $created } }
                Mock Test-GpuVMDisposable { $true }
                Test-GpuVMDisposableDone -State $state -VMState 'Off' | Should Be $false
            }
        }
        It 'keeps a machine whose date can''t be read' {
            Mock Test-GpuVMDisposable { $true }
            Test-GpuVMDisposableDone -State @{ disposable = @{ createdAt = 'not a date' } } -VMState 'Off' | Should Be $false
        }
        It 'deletes one that already ran and is off' {
            Mock Test-GpuVMDisposable { $true }
            Test-GpuVMDisposableDone -State @{ disposable = @{ createdAt = (Get-Date).ToString('o'); startedAt = (Get-Date).ToString('o') } } -VMState 'Off' | Should Be $true
        }
    }
}

InModuleScope GpuVM {
    Describe 'A new machine that can''t turn on' {
        It 'says why, with the memory figures, in fields the MCP reads (not only a warning)' {
            Mock Assert-VMCanStart { throw 'The VM needs 8.3 GB free and there are 7.3 GB. Close programs or lower its memory to 7 GB in Options.' }
            Mock Start-VM { }
            Mock Write-Warning { }
            $s = Start-NewGpuVM -Name vm1
            $s.started | Should Be $false
            $s.neededGB | Should Be 8.3
            $s.freeGB | Should Be 7.3
            $s.startError | Should Match 'needs 8.3 GB'
            Assert-MockCalled Start-VM -Times 0 -Scope It
            Assert-MockCalled Write-Warning -Times 1 -Scope It
            $info = Add-StartResult -Info ([pscustomobject]@{ Name = 'vm1' }) -Start $s
            ($info | ConvertTo-Json -Compress) | Should Match '"started":false,"startError":"The VM needs 8.3 GB'
            ($info | ConvertTo-Json -Compress) | Should Match '"neededGB":8.3,"freeGB":7.3'
            (Add-StartResult -Info ([pscustomobject]@{ Name = 'vm1' }) -Start $null).PSObject.Properties['started'] | Should Be $null
        }
        It 'any other reason has no figures' {
            Mock Assert-VMCanStart { }
            Mock Start-VM { throw 'GPU partition unavailable' }
            Mock Write-Warning { }
            $s = Start-NewGpuVM -Name vm1
            "$($s.started) $($s.startError) $($s.neededGB)" | Should Be 'False GPU partition unavailable '
        }
        It 'started, and a disposable copy marked as started' {
            Mock Assert-VMCanStart { }
            Mock Start-VM { }
            Mock Set-GpuVMDisposableStarted { }
            (Start-NewGpuVM -Name vm1 -State @{ disposable = @{} }).started | Should Be $true
            Assert-MockCalled Set-GpuVMDisposableStarted -Times 1 -Scope It
        }
    }
}

InModuleScope GpuVM {
    Describe 'Remove-GpuVMDisposable -Name' {
        BeforeEach {
            Mock Assert-Admin { }
            Mock Write-Step { }
            Mock Get-VM { [pscustomobject]@{ Name = $Name; State = 'Off' } }
            Mock Get-GpuVMState { @{ backend = 'hyperv-gpup'; disposable = @{ createdAt = 'x'; startedAt = $null } } }
            Mock Invoke-GpuVMBackend { }
        }
        It 'deletes that disposable machine at once when it is off (no grace for a never-started copy)' {
            Remove-GpuVMDisposable -Name copy1 -Confirm:$false | Should Be 'copy1'
            Assert-MockCalled Invoke-GpuVMBackend -Times 1 -Scope It -ParameterFilter { $Operation -eq 'Remove' -and $Arguments[0] -eq 'copy1' -and $Arguments[2] -eq $true }
        }
        It 'refuses a machine that isn''t disposable' {
            Mock Get-GpuVMState { @{ backend = 'hyperv-gpup' } }
            Test-Throws { Remove-GpuVMDisposable -Name win-gpu -Confirm:$false } | Should Be $true
            Assert-MockCalled Invoke-GpuVMBackend -Times 0 -Scope It
        }
        It 'refuses a running one' {
            Mock Get-VM { [pscustomobject]@{ Name = $Name; State = 'Running' } }
            Test-Throws { Remove-GpuVMDisposable -Name copy1 -Confirm:$false } | Should Be $true
            Assert-MockCalled Invoke-GpuVMBackend -Times 0 -Scope It
        }
        It 'refuses a name that isn''t a machine' {
            Mock Get-VM { $null }
            Test-Throws { Remove-GpuVMDisposable -Name nope -Confirm:$false } | Should Be $true
            Test-Throws { Remove-GpuVMDisposable -Name '..\x' -Confirm:$false } | Should Be $true
            Assert-MockCalled Invoke-GpuVMBackend -Times 0 -Scope It
        }
    }
}

InModuleScope GpuVM {
    Describe 'Where a copy lands and that it arrived' {
        It 'finds the signed-in person''s desktop without expanding variables with this session''s own' {
            $key = 'HKCU:\Software\GpuVM-test-desktop'
            New-Item -Path $key -Force | Out-Null
            try {
                $k = Get-Item $key
                $w = $k.OpenSubKey('', $true)
                $w.SetValue('Desktop', '%USERPROFILE%\Desktop', [Microsoft.Win32.RegistryValueKind]::ExpandString); $w.Close()
                & $script:GuestDesktopResolver $key 'C:\Users\agent' | Should Be 'C:\Users\agent\Desktop'
                (Get-ItemProperty $key).Desktop | Should Be (Join-Path $env:USERPROFILE 'Desktop')
                $w = (Get-Item $key).OpenSubKey('', $true)
                $w.SetValue('Desktop', '%OneDrive%\Desktop', [Microsoft.Win32.RegistryValueKind]::ExpandString); $w.Close()
                & $script:GuestDesktopResolver $key 'C:\Users\agent' | Should Be 'C:\Users\agent\Desktop'
                $w = (Get-Item $key).OpenSubKey('', $true)
                $w.SetValue('Desktop', 'D:\Escritorio', [Microsoft.Win32.RegistryValueKind]::String); $w.Close()
                & $script:GuestDesktopResolver $key 'C:\Users\agent' | Should Be 'D:\Escritorio'
                & $script:GuestDesktopResolver 'HKCU:\Software\GpuVM-test-missing' 'C:\Users\agent' | Should Be 'C:\Users\agent\Desktop'
            }
            finally { Remove-Item $key -Recurse -Force }
        }

        # Security review 2026-11-21: the guest's administrator writes into a folder `agent` owns.
        It 'uses the destination only under the profile and with no junction on the way' {
            . ([scriptblock]::Create($script:GuestFolderCode))
            $profilePath = Join-Path $TestDrive 'Users\agent'
            $desktop = Join-Path $profilePath 'Desktop'
            New-Item -ItemType Directory -Path $desktop -Force | Out-Null
            $guard = Enter-GpuVMDestination -ProfilePath $profilePath -Desktop $desktop -Folder 'Received' -Id 'a1' -Create
            try {
                $guard.Dest | Should Be ([IO.Path]::GetFullPath((Join-Path $desktop 'Received')))
                Test-Path -LiteralPath $guard.Dest -PathType Container | Should Be $true
                # Held: the folder (and the desktop above it) can't be renamed away and swapped for a junction.
                Test-Throws { [IO.Directory]::Move($guard.Dest, "$($guard.Dest)-x") } | Should Be $true
                Test-Throws { [IO.Directory]::Move($desktop, "$desktop-x") } | Should Be $true
            }
            finally { & $guard.Close }
            @(Get-ChildItem -LiteralPath $guard.Dest -Force).Count | Should Be 0
            [IO.Directory]::Move($guard.Dest, "$($guard.Dest)-x"); [IO.Directory]::Move("$($guard.Dest)-x", $guard.Dest)

            # Outside the profile (the registry value is the user's own), or out of it with "..".
            Test-Throws { Enter-GpuVMDestination -ProfilePath $profilePath -Desktop (Join-Path $TestDrive 'Windows') -Folder 'Received' -Id 'a2' -Create } | Should Be $true
            Test-Throws { Enter-GpuVMDestination -ProfilePath $profilePath -Desktop "$profilePath\..\Administrator\Desktop" -Folder 'Received' -Id 'a3' -Create } | Should Be $true

            # Received, or a folder above it, turned into a junction to somewhere else.
            $elsewhere = Join-Path $TestDrive 'System32'
            New-Item -ItemType Directory -Path $elsewhere -Force | Out-Null
            Remove-Item -LiteralPath $guard.Dest -Force
            New-Item -ItemType Junction -Path $guard.Dest -Target $elsewhere | Out-Null
            Test-Throws { Enter-GpuVMDestination -ProfilePath $profilePath -Desktop $desktop -Folder 'Received' -Id 'a4' -Create } | Should Be $true
            [IO.Directory]::Delete($guard.Dest)
            $other = Join-Path $profilePath 'OneDesk'
            New-Item -ItemType Junction -Path $other -Target $elsewhere | Out-Null
            Test-Throws { Enter-GpuVMDestination -ProfilePath $profilePath -Desktop $other -Folder 'Received' -Id 'a5' -Create } | Should Be $true
            @(Get-ChildItem -LiteralPath $elsewhere -Force).Count | Should Be 0
        }

        It 'deletes a folder without going into a junction inside it' {
            . ([scriptblock]::Create($script:GuestFolderCode))
            $staging = Join-Path $TestDrive 'staging'
            $target = Join-Path $TestDrive 'precious'
            New-Item -ItemType Directory -Path (Join-Path $staging 'sub'), $target -Force | Out-Null
            'keep' | Set-Content -LiteralPath (Join-Path $target 'keep.txt')
            'x' | Set-Content -LiteralPath (Join-Path $staging 'sub\x.txt')
            New-Item -ItemType Junction -Path (Join-Path $staging 'sub\link') -Target $target | Out-Null
            Remove-GpuVMFolder -Path $staging
            Test-Path -LiteralPath $staging | Should Be $false
            Test-Path -LiteralPath (Join-Path $target 'keep.txt') | Should Be $true
        }

        It 'gives its own folders to Administrators and SYSTEM only, inheriting nothing' {
            . ([scriptblock]::Create($script:GuestFolderCode))
            $security = New-GpuVMFolderSecurity
            $security.AreAccessRulesProtected | Should Be $true
            $security.GetOwner([Security.Principal.SecurityIdentifier]).Value | Should Be 'S-1-5-32-544'
            $rules = @($security.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
            ($rules | ForEach-Object { $_.IdentityReference.Value } | Sort-Object) -join ',' | Should Be 'S-1-5-18,S-1-5-32-544'
            Test-GpuVMLockedAcl -Acl $security | Should Be $true
            # C:\GpuVM: Users may read and run what is there, never change it.
            Test-GpuVMLockedAcl -Acl (New-GpuVMFolderSecurity -Extra @(, @('S-1-5-32-545', 'ReadAndExecute'))) | Should Be $true
            Test-GpuVMLockedAcl -Acl (New-GpuVMFolderSecurity -Extra @(, @('S-1-5-32-545', 'Modify'))) | Should Be $false
        }

        It 'reports a copy done only when the destination holds every file and byte' {
            $ok = [pscustomobject]@{ Ok = $true; Error = ''; Dest = 'C:\Users\agent\Desktop\Received'; Bytes = [int64]106697424; Files = 1 }
            Test-Throws { Assert-TransferArrived -Done $ok -Bytes 106697424 -Files 1 -Name vm } | Should Be $false
            Test-Throws { Assert-TransferArrived -Done ([pscustomobject]@{ Ok = $true; Error = ''; Dest = 'x'; Bytes = [int64]0; Files = 0 }) -Bytes 106697424 -Files 1 -Name vm } | Should Be $true
            Test-Throws { Assert-TransferArrived -Done ([pscustomobject]@{ Ok = $true; Error = ''; Dest = 'x'; Bytes = [int64]106697424; Files = 2 }) -Bytes 106697424 -Files 1 -Name vm } | Should Be $true
            Test-Throws { Assert-TransferArrived -Done ([pscustomobject]@{ Ok = $false; Error = 'tar 1'; Dest = 'x'; Bytes = [int64]106697424; Files = 1 }) -Bytes 106697424 -Files 1 -Name vm } | Should Be $true
        }
    }
}

InModuleScope GpuVM {
    Describe 'New-GpuVM -Template returns how the start went' {
        It 'a copy that starts, and one that can''t (the -Start switch and the result are separate variables)' {
            Mock Assert-Admin { }
            Mock Assert-GpuVMNameFree { }
            Mock Read-GpuVMTemplate { @{ name = 't'; sizeGB = 64; edition = 'Pro'; streaming = @{}; guest = @{}; vhdPath = 'x' } }
            Mock Test-GpuVMHost { @() }
            Mock Resolve-GpuVMProfile { @{ backend = 'hyperv-gpup' } }
            Mock New-TemplateCloneConfig { @{ backend = 'hyperv-gpup' } }
            Mock Invoke-GpuVMBackend { [ordered]@{ name = 'copy1' } }
            Mock Save-GpuVMState { }
            Mock Write-Step { }
            Mock Get-GpuVM { [pscustomobject]@{ Name = 'copy1' } }
            Mock Start-NewGpuVM { @{ started = $true; startError = $null; neededGB = $null; freeGB = $null } }
            (New-GpuVM -Name copy1 -Template t -Start -Confirm:$false).started | Should Be $true
            Mock Start-NewGpuVM { @{ started = $false; startError = 'no memory'; neededGB = 8.3; freeGB = 7.3 } }
            $r = New-GpuVM -Name copy1 -Template t -Start -Confirm:$false
            "$($r.started) $($r.startError) $($r.neededGB)" | Should Be 'False no memory 8.3'
            # Without -Start nothing about starting is added.
            (New-GpuVM -Name copy1 -Template t -Confirm:$false).PSObject.Properties['started'] | Should Be $null
        }
    }
}

InModuleScope GpuVM {
    Describe 'Memory of template copies and agent machines' {
        It 'a copy keeps the template''s memory and processors; the override wins' {
            $tpl = @{ config = @{ vm = @{ memoryGB = 4; cpu = @{ count = 4; reservePercent = 0 } } } }
            $o = Get-TemplateMachineOverride -Template $tpl -Override $null
            "$($o.vm.memoryGB) $($o.vm.cpu.count)" | Should Be '4 4'
            $o = Get-TemplateMachineOverride -Template $tpl -Override @{ vm = @{ memoryGB = 6 } }
            "$($o.vm.memoryGB) $($o.vm.cpu.count)" | Should Be '6 4'
            $o = Get-TemplateMachineOverride -Template $tpl -Override @{ vm = @{ cpu = @{ count = 2 } }; guest = @{ x = 1 } }
            "$($o.vm.memoryGB) $($o.vm.cpu.count) $($o.guest.x)" | Should Be '4 2 1'
            # A template without the figures changes nothing.
            (Get-TemplateMachineOverride -Template @{ config = @{ vm = @{} } } -Override $null).vm.Count | Should Be 0
        }
        It 'an agent machine gets 4 GB unless memory is chosen' {
            (Add-DefaultMemory -Override $null -MemoryGB 4).vm.memoryGB | Should Be 4
            (Add-DefaultMemory -Override @{ vm = @{ memoryGB = 8 } } -MemoryGB 4).vm.memoryGB | Should Be 8
            $o = Add-DefaultMemory -Override @{ vm = @{ cpu = @{ count = 2 } } } -MemoryGB 4
            "$($o.vm.memoryGB) $($o.vm.cpu.count)" | Should Be '4 2'
        }
        It 'New-GpuVM -Template asks the profile for the template''s memory unless a profile is named' {
            Mock Assert-Admin { }
            Mock Assert-GpuVMNameFree { }
            Mock Read-GpuVMTemplate { @{ name = 't'; sizeGB = 64; edition = 'Pro'; streaming = @{}; guest = @{}; vhdPath = 'x'; config = @{ vm = @{ memoryGB = 4; cpu = @{ count = 4 } } } } }
            Mock Test-GpuVMHost { @() }
            Mock Resolve-GpuVMProfile { $script:asked = $Override; @{ backend = 'hyperv-gpup' } }
            Mock New-TemplateCloneConfig { @{ backend = 'hyperv-gpup' } }
            Mock Invoke-GpuVMBackend { [ordered]@{ name = 'copy1' } }
            Mock Save-GpuVMState { }
            Mock Write-Step { }
            Mock Get-GpuVM { [pscustomobject]@{ Name = 'copy1' } }
            New-GpuVM -Name copy1 -Template t -Confirm:$false | Out-Null
            $script:asked.vm.memoryGB | Should Be 4
            New-GpuVM -Name copy1 -Template t -Profile max-performance -Confirm:$false | Out-Null
            ($script:asked -and $script:asked['vm'] -and $script:asked['vm'].Contains('memoryGB')) | Should Be $false
            New-GpuVM -Name copy1 -Template t -Override @{ vm = @{ memoryGB = 6 } } -Confirm:$false | Out-Null
            $script:asked.vm.memoryGB | Should Be 6
        }
    }
}

InModuleScope GpuVM {
    Describe 'An agent machine gets this build''s agent when it is opened' {
        It 'stale means pending, unknown or older than the bundled agent; never for other machines' {
            Test-GpuVMAgentStale -State @{ use = 'agent'; agent = @{ version = '0.3.2' } } -BundledVersion '0.3.5' | Should Be $true
            Test-GpuVMAgentStale -State @{ use = 'agent'; agent = @{ version = '0.3.5' } } -BundledVersion '0.3.5' | Should Be $false
            Test-GpuVMAgentStale -State @{ use = 'agent'; agent = @{ version = '0.4.0' } } -BundledVersion '0.3.5' | Should Be $false
            Test-GpuVMAgentStale -State @{ use = 'agent'; agent = @{ version = '0.3.10' } } -BundledVersion '0.3.9' | Should Be $false
            Test-GpuVMAgentStale -State @{ use = 'agent'; agent = @{ pending = $true; signInAs = 'agent' } } -BundledVersion '0.3.5' | Should Be $true
            Test-GpuVMAgentStale -State @{ use = 'agent'; agent = @{} } -BundledVersion '0.3.5' | Should Be $true
            Test-GpuVMAgentStale -State @{ use = 'agent' } -BundledVersion '0.3.5' | Should Be $true
            Test-GpuVMAgentStale -State @{ agent = @{ version = '0.3.2' } } -BundledVersion '0.3.5' | Should Be $false
            Test-GpuVMAgentStale -State @{ use = 'agent'; agent = @{ version = '0.3.5' } } -BundledVersion $null | Should Be $false
        }
        It 'installs only when stale, waits for the restart it asked for, and a failure is a warning' {
            $cred = [pscredential]::new('u', (ConvertTo-SecureString 'p' -AsPlainText -Force))
            Mock Get-AgentPackage { [pscustomobject]@{ Version = '0.3.5' } }
            Mock Write-Step { }
            Mock Start-Sleep { }
            Mock Get-GpuVMState { @{ use = 'agent'; agent = @{ version = '0.3.5'; signInAs = 'agent' } } }
            Mock Install-GpuVMAgent { [ordered]@{ restarted = $false } }
            Update-GpuVMAgentIfStale -Name c -Credential $cred | Should Be $false
            Assert-MockCalled Install-GpuVMAgent -Times 0 -Exactly -Scope It

            Mock Get-GpuVMState { @{ use = 'agent'; agent = @{ version = '0.3.2'; signInAs = 'own' } } }
            Mock Get-GuestBootTime { '100' }
            Update-GpuVMAgentIfStale -Name c -Credential $cred | Should Be $false
            Assert-MockCalled Install-GpuVMAgent -Times 1 -Exactly -Scope It -ParameterFilter { $Name -eq 'c' -and $User -eq 'own' }

            # Windows restarts: back only once the boot time changed.
            Mock Install-GpuVMAgent { [ordered]@{ restarted = $true } }
            $script:boots = [System.Collections.Generic.Queue[object]]::new([object[]]@('100', '100', $null, '200'))
            Mock Get-GuestBootTime { $b = $script:boots.Dequeue(); if ($null -eq $b) { throw 'not up' }; $b }
            Update-GpuVMAgentIfStale -Name c -Credential $cred | Should Be $true
            $script:boots.Count | Should Be 0

            Mock Install-GpuVMAgent { throw 'no session' }
            Mock Get-GuestBootTime { '100' }
            $w = Update-GpuVMAgentIfStale -Name c -Credential $cred 3>&1
            ($w | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }).Message | Should Match 'no session'

            # Not an agent machine, or a build without the agent: nothing.
            Mock Get-GpuVMState { @{ agent = @{ version = '0.3.2' } } }
            Update-GpuVMAgentIfStale -Name c -Credential $cred | Should Be $false
            Mock Get-GpuVMState { @{ use = 'agent'; agent = @{ version = '0.3.2' } } }
            Mock Get-AgentPackage { throw 'no dist' }
            Update-GpuVMAgentIfStale -Name c -Credential $cred | Should Be $false
            Assert-MockCalled Install-GpuVMAgent -Times 3 -Exactly -Scope It -ParameterFilter { $Name -eq 'c' -and $User -eq 'own' }
        }
    }
}

InModuleScope GpuVM {
    Describe 'Sunshine is the service and GpuVM''s fork on every machine' {
        It 'a guest without the fork''s helper says so; the capture is set only when it changed' {
            $cred = [pscredential]::new('u', (ConvertTo-SecureString 'p' -AsPlainText -Force))
            Mock Write-Step { }
            Mock Write-Warning { }
            Mock Invoke-Guest { 'nofork-changed' }
            Set-GuestCaptureMode -Name a -Credential $cred | Should Be $true
            Assert-MockCalled Write-Warning -Times 1
            Mock Invoke-Guest { 'changed' }
            Set-GuestCaptureMode -Name a -Credential $cred | Should Be $true
            Mock Invoke-Guest { 'unchanged' }
            Set-GuestCaptureMode -Name a -Credential $cred | Should Be $false
        }
        It 'the guest script captures one way: no mode to choose any more' {
            $code = Get-Content -Raw -LiteralPath (Get-RepoPath 'guest\capture-mode.ps1')
            $code | Should Not Match "ValidateSet\('ddx'"
            $code.Contains('capture = $want') | Should Be $true
        }
        It 'opening installs the fork only when the machine''s state doesn''t name this build''s' {
            $cred = [pscredential]::new('u', (ConvertTo-SecureString 'p' -AsPlainText -Force))
            Mock Get-SunshineForkFiles { [pscustomobject]@{ Key = 'sunshine.exe'; Path = 'x'; Hash = 'H1' } }
            Mock Install-GuestSunshineCapture { 'installed' }
            Mock Get-GpuVMState { @{ sunshineFork = 'sunshine.exe=H1;setup=2' } }
            Sync-GuestSunshineFork -Name a -Credential $cred | Should Be 'current'
            Mock Get-GpuVMState { @{ sunshineFork = 'sunshine.exe=H0' } }
            Sync-GuestSunshineFork -Name a -Credential $cred | Should Be 'installed'
            Mock Get-GpuVMState { @{} }
            Sync-GuestSunshineFork -Name a -Credential $cred | Should Be 'installed'
            Assert-MockCalled Install-GuestSunshineCapture -Times 2 -Exactly -Scope It
        }
    }
}

InModuleScope GpuVM {
    Describe 'A template of an agent machine makes agent machines' {
        It 'the template records the use and who signs in' {
            (Get-TemplateAgentUse -State @{ use = 'agent'; agent = @{ signInAs = 'own' } }).agentSignInAs | Should Be 'own'
            (Get-TemplateAgentUse -State @{ use = 'agent'; agent = @{ version = '0.3.7' } }).agentSignInAs | Should Be 'agent'
            (Get-TemplateAgentUse -State @{ use = 'agent' }).use | Should Be 'agent'
            (Get-TemplateAgentUse -State @{ agent = @{ signInAs = 'agent' } }).use | Should Be $null
        }
        It 'a copy is born an agent machine, isolated, with its agent pending; other copies are untouched' {
            Mock Assert-Admin { }
            Mock Assert-GpuVMNameFree { }
            Mock Test-GpuVMHost { @() }
            Mock Resolve-GpuVMProfile { @{ backend = 'hyperv-gpup' } }
            Mock New-TemplateCloneConfig { @{ backend = 'hyperv-gpup'; vm = @{ network = @{ isolation = $false } } } }
            Mock Invoke-GpuVMBackend { $script:cloneConfig = $Arguments[0].Config; [ordered]@{ name = 'copy1' } }
            Mock Save-GpuVMState { $script:saved = $State }
            Mock Write-Step { }
            Mock Get-GpuVM { [pscustomobject]@{ Name = 'copy1' } }
            Mock Read-GpuVMTemplate { @{ name = 't'; sizeGB = 64; edition = 'Pro'; streaming = @{}; guest = @{}; vhdPath = 'x'; config = @{ vm = @{} }; use = 'agent'; agentSignInAs = 'agent' } }
            New-GpuVM -Name copy1 -Template t -Confirm:$false | Out-Null
            $script:saved['use'] | Should Be 'agent'
            $script:saved['agent']['pending'] | Should Be $true
            $script:saved['agent']['signInAs'] | Should Be 'agent'
            $script:cloneConfig['vm']['network']['isolation'] | Should Be $true

            Mock Read-GpuVMTemplate { @{ name = 't'; sizeGB = 64; edition = 'Pro'; streaming = @{}; guest = @{}; vhdPath = 'x'; config = @{ vm = @{} } } }
            New-GpuVM -Name copy1 -Template t -Confirm:$false | Out-Null
            $script:saved.Contains('use') | Should Be $false
            $script:cloneConfig['vm']['network']['isolation'] | Should Be $false
        }
    }
}

InModuleScope GpuVM {
    Describe 'Deleting a machine never stops half-way on its agent registration' {
        It 'the VM and its folder go even when the registration can''t be removed; a warning says so' {
            New-Item -ItemType Directory (Join-Path $TestDrive 'GpuVM') -Force | Out-Null
            # The long form of the path (TestDrive can be an 8.3 short path; the backend compares full paths).
            $script:testRoot = (Get-Item -LiteralPath (Join-Path $TestDrive 'GpuVM')).FullName
            $script:testRoot = (New-Object -ComObject Scripting.FileSystemObject).GetFolder($script:testRoot).Path
            $script:testRoot = [IO.Path]::GetFullPath($script:testRoot)
            $dir = Join-Path $script:testRoot 'copy1'
            New-Item -ItemType Directory $dir -Force | Out-Null
            Set-Content (Join-Path $dir 'copy1.vhdx') 'disk'
            Set-Content (Join-Path $dir 'gpuvm.json') '{}'
            Mock Get-GpuVMDefaultRoot { $script:testRoot }
            Mock Get-VM { [pscustomobject]@{ State = 'Off'; Id = [guid]'0b5d1f53-1e33-4b7e-9f0a-2c4d6e8f0a1b' } }
            Mock Stop-VM { }
            Mock Remove-VM { $script:vmRemoved = $true }
            Mock Remove-GpuVMAgentRegistration { throw 'Access to the path secret is denied.' }
            $script:vmRemoved = $false
            $w = Invoke-GpuVMBackend -Backend 'hyperv-gpup' -Operation Remove -Arguments 'copy1', @{ vmDir = $dir }, $true 3>&1
            $script:vmRemoved | Should Be $true
            Test-Path $dir | Should Be $false
            ($w | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }).Message | Should Match 'within the hour'
            Assert-MockCalled Remove-GpuVMAgentRegistration -Times 1 -Exactly -Scope It
        }
    }
}

InModuleScope GpuVM {
    Describe 'Agent machines are always isolated' {
        It 'an agent machine counts as isolated whatever its config says' {
            Get-GpuVMNetworkIsolation -State @{ use = 'agent'; config = @{ vm = @{ network = @{ isolation = $false } } } } | Should Be $true
            Get-GpuVMNetworkIsolation -State @{ config = @{ vm = @{ network = @{ isolation = $false } } } } | Should Be $false
        }
        It 'an agent machine refuses a switch where it can''t be isolated' {
            Mock Get-VMNetworkAdapter { [pscustomobject]@{ SwitchName = 'LAN' } }
            Mock Get-VMSwitch { [pscustomobject]@{ Name = 'LAN'; SwitchType = 'External' } }
            Test-Throws { Assert-AgentSwitch -Name a } | Should Be $true
            Mock Get-VMSwitch { [pscustomobject]@{ Name = 'Default Switch'; SwitchType = 'Internal' } }
            Assert-AgentSwitch -Name a
            Mock Get-VMSwitch { $null }
            Test-Throws { Assert-AgentSwitch -Name a } | Should Be $true
        }
        It 'an agent machine is checked on every adapter, not only the first (security review 2026-11-21)' {
            Mock Get-VMNetworkAdapter { [pscustomobject]@{ SwitchName = 'Default Switch' }; [pscustomobject]@{ SwitchName = 'LAN' } }
            Mock Get-VMSwitch { [pscustomobject]@{ Name = $Name; SwitchType = $(if ($Name -eq 'LAN') { 'External' } else { 'Internal' }) } }
            Mock Get-VMNetworkAdapterExtendedAcl { @() }
            Mock Get-GpuVMHostNetwork { [pscustomobject]@{ Address = '172.29.96.1'; PrefixLength = 20 } }
            Mock Add-VMNetworkAdapterExtendedAcl { }
            Mock Remove-VMNetworkAdapterExtendedAcl { }
            Test-Throws { Update-GpuVMNetworkIsolation -Name a -State @{ use = 'agent'; config = @{ vm = @{} } } } | Should Be $true
            Assert-MockCalled Add-VMNetworkAdapterExtendedAcl -Times 0 -Scope It
            # A person's machine keeps going (its isolation follows the first connected adapter, as before).
            Update-GpuVMNetworkIsolation -Name a -State @{ config = @{ vm = @{} } } -WarningAction SilentlyContinue
            Assert-MockCalled Add-VMNetworkAdapterExtendedAcl -Times 12 -Exactly -Scope It
        }
        It 'a disconnected first adapter doesn''t leave the others without rules' {
            Mock Get-VMNetworkAdapter { [pscustomobject]@{ SwitchName = '' }; [pscustomobject]@{ SwitchName = 'Default Switch' } }
            Mock Get-VMSwitch { [pscustomobject]@{ Name = 'Default Switch'; SwitchType = 'Internal' } }
            Mock Get-VMNetworkAdapterExtendedAcl { @() }
            Mock Get-GpuVMHostNetwork { [pscustomobject]@{ Address = '172.29.96.1'; PrefixLength = 20 } }
            Mock Add-VMNetworkAdapterExtendedAcl { }
            Update-GpuVMNetworkIsolation -Name a -State @{ use = 'agent'; config = @{ vm = @{} } }
            Assert-MockCalled Add-VMNetworkAdapterExtendedAcl -Times 12 -Exactly -Scope It
        }
        It 'the module''s Start-VM and Restart-VM refuse an agent machine on a LAN switch, whoever calls them' {
            Mock Get-GpuVMState { @{ use = 'agent'; config = @{ vm = @{} } } }
            Mock Get-VMNetworkAdapter { [pscustomobject]@{ SwitchName = 'Default Switch' }; [pscustomobject]@{ SwitchName = 'LAN' } }
            Mock Get-VMSwitch { [pscustomobject]@{ Name = $Name; SwitchType = $(if ($Name -eq 'LAN') { 'External' } else { 'Internal' }) } }
            Mock Invoke-GpuPowerTransition { $script:powered = $true }
            $script:powered = $false
            Test-Throws { Start-VM -Name a } | Should Be $true
            Test-Throws { Restart-VM -Name a -Force } | Should Be $true
            $script:powered | Should Be $false
            Mock Get-GpuVMState { @{ config = @{ vm = @{} } } }
            Start-VM -Name a
            $script:powered | Should Be $true
            Mock Get-GpuVMState { throw 'not a GpuVM machine' }
            $script:powered = $false
            Start-VM -Name a
            $script:powered | Should Be $true
        }
        It 'an agent session copies only a template made for agents' {
            Mock Assert-Admin { }
            Mock Assert-GpuVMNameFree { }
            Mock Test-GpuVMHost { @() }
            Mock Resolve-GpuVMProfile { @{ backend = 'hyperv-gpup' } }
            Mock New-TemplateCloneConfig { @{ backend = 'hyperv-gpup'; vm = @{} } }
            Mock Invoke-GpuVMBackend { [ordered]@{ name = 'copy1' } }
            Mock Save-GpuVMState { $script:saved = $State }
            Mock Write-Step { }
            Mock Get-GpuVM { [pscustomobject]@{ Name = 'copy1' } }
            Mock Get-GpuVMDiskBudget { @{ availableGB = 500; drive = 'C:' } }
            Mock Start-NewGpuVM { @{ started = $true } }
            Mock Read-GpuVMTemplate { @{ name = 't'; sizeGB = 64; edition = 'Pro'; streaming = @{}; guest = @{}; vhdPath = 'x'; config = @{ vm = @{} } } }
            Test-Throws { New-GpuVM -Name copy1 -Template t -Disposable -ForAgent -Confirm:$false } | Should Be $true
            Assert-MockCalled Invoke-GpuVMBackend -Times 0 -Scope It
            Mock Read-GpuVMTemplate { @{ name = 't'; sizeGB = 64; edition = 'Pro'; streaming = @{}; guest = @{}; vhdPath = 'x'; config = @{ vm = @{} }; use = 'agent' } }
            New-GpuVM -Name copy1 -Template t -Disposable -ForAgent -Confirm:$false | Out-Null
            $script:saved['use'] | Should Be 'agent'
            Test-Throws { New-GpuVM -Name copy1 -ForAgent -Confirm:$false } | Should Be $true
        }
    }
}

InModuleScope GpuVM {
    Describe 'Removing the agent finishes and leaves an ordinary machine' {
        BeforeEach {
            $script:st = @{ use = 'agent'; agent = @{ version = '0.3.7' }; statePath = 'D:\GpuVM\vm1\gpuvm.json' }
            Mock Assert-Admin { }
            Mock Get-GpuVMState { $script:st }
            Mock Save-GpuVMState { $script:st = $State }
            Mock Remove-GpuVMAgentRegistration { }
            Mock Write-Step { }
            Set-Content (Join-Path $TestDrive 'install.ps1') '"x"'
            Mock Get-RepoPath { Join-Path $TestDrive 'install.ps1' }
            Mock Get-GpuVMGuestCredential { [pscredential]::new('u', (ConvertTo-SecureString 'p' -AsPlainText -Force)) }
            Mock Get-GuestBootTime { '100' }
            Mock Invoke-Command { }
        }
        It 'off: the use goes and the removal waits for the next open' {
            Mock Get-VM { [pscustomobject]@{ State = 'Off'; Id = [guid]'0b5d1f53-1e33-4b7e-9f0a-2c4d6e8f0a1b' } }
            Mock Write-Warning { }
            (Uninstall-GpuVMAgent -Name vm1).removalPending | Should Be $true
            $script:st.Contains('use') | Should Be $false
            $script:st.Contains('agent') | Should Be $false
            $script:st['agentRemovalPending'] | Should Be $true
        }
        It 'running with `agent` signed in: restarts and removes the user afterwards' {
            Mock Get-VM { [pscustomobject]@{ State = 'Running'; Id = [guid]'0b5d1f53-1e33-4b7e-9f0a-2c4d6e8f0a1b' } }
            $script:runs = 0
            Mock Invoke-GuestAgentRemoval {
                $script:runs++
                if ($script:runs -eq 1) { [pscustomobject]@{ ok = $true; rebootNeeded = $true; notes = @('the agent user is signed in: its profile is removed after a restart and a new run of -Uninstall -RemoveUser') } }
                else { [pscustomobject]@{ ok = $true; rebootNeeded = $false; notes = @() } }
            }
            $script:boots = [System.Collections.Generic.Queue[object]]::new([object[]]@('100', '100', '200'))
            Mock Get-GuestBootTime { $script:boots.Dequeue() }
            Mock Wait-GuestReady { }
            Mock Start-Sleep { }
            (Uninstall-GpuVMAgent -Name vm1).removalPending | Should Be $false
            $script:runs | Should Be 2
            $script:st.Contains('use') | Should Be $false
            $script:st.Contains('agentRemovalPending') | Should Be $false
        }
        It 'a leftover staging folder holding a link is never deleted through it' {
            $root = Join-Path $TestDrive 'win2'
            $staging = "$root\ProgramData\GpuVM\Agent\staging"
            New-Item -ItemType Directory "$staging\sub" -Force | Out-Null
            $target = Join-Path $TestDrive 'precious'
            New-Item -ItemType Directory $target -Force | Out-Null
            Set-Content (Join-Path $target 'keep.txt') 'x'
            cmd /c mklink /J "$staging\sub\j" "$target" | Out-Null
            Test-Throws { Remove-GuestAgentSecret -WindowsRoot $root } | Should Be $true
            Test-Path (Join-Path $target 'keep.txt') | Should Be $true
        }
    }
}

InModuleScope GpuVM {
    Describe 'A new machine says its VM id' {
        It 'the service keys an agent''s copies by it' {
            Mock Get-VM { [pscustomobject]@{ Id = [guid]'3A4B5C6D-7E8F-4A1B-9C2D-3E4F5A6B7C8D' } }
            (Add-StartResult -Info ([pscustomobject]@{ Name = 'copy1' }) -Start $null).vmId | Should Be '3a4b5c6d-7e8f-4a1b-9c2d-3e4f5a6b7c8d'
            Mock Get-VM { throw 'gone' }
            (Add-StartResult -Info ([pscustomobject]@{ Name = 'copy1' }) -Start $null).PSObject.Properties['vmId'] | Should Be $null
        }
    }
}

InModuleScope GpuVM {
    Describe 'An agent machine keeps its Hyper-V display' {
        It 'turns it back on when it is off, and leaves it when it is on' {
            Mock Invoke-Command { & $ScriptBlock }
            Mock Get-PnpDevice { @([pscustomobject]@{ FriendlyName = 'Microsoft Hyper-V Video'; Status = 'Error'; InstanceId = 'VMBUSx' }) }
            Mock Enable-PnpDevice { $script:enabled = $true }
            $cred = [pscredential]::new('u', (ConvertTo-SecureString 'p' -AsPlainText -Force))
            $script:enabled = $false
            Enable-GuestHyperVVideo -Name a -Credential $cred | Should Be 'enabled'
            $script:enabled | Should Be $true
            Mock Get-PnpDevice { @([pscustomobject]@{ FriendlyName = 'Microsoft Hyper-V Video'; Status = 'OK' }) }
            Enable-GuestHyperVVideo -Name a -Credential $cred | Should Be 'ok'
        }
        It 'its copies and new agent machines never have it turned off by their setup' {
            $c = @{ streaming = @{ disableHyperVVideo = $true; virtualDisplay = $true } }
            Set-AgentKeepsHyperVVideo -Config $c
            $c['streaming']['disableHyperVVideo'] | Should Be $false
        }
    }
}

InModuleScope GpuVM {
    Describe 'Off and on, never a restart' {
        BeforeEach {
            # Never the real ProgramData\GpuVM\power.log.
            Mock Write-PowerLog { }
            $script:st = @{ disposable = @{ createdAt = (Get-Date).AddHours(-1).ToString('o'); startedAt = (Get-Date).ToString('o') } }
            Mock Get-GpuVMState { $script:st }
            Mock Save-GpuVMState { $script:st = $State; $script:saved.Add(($State['disposable'].Contains('cyclingUntil'))) }
            Mock Write-Step { }
            Mock Start-Sleep { }
            Mock Update-GpuVMNetworkIsolation { }
            Mock Start-VM { $script:calls.Add('start') }
            Mock Remove-Job { }
            Mock Wait-Job { }
            $script:calls = [System.Collections.Generic.List[string]]::new()
            $script:saved = [System.Collections.Generic.List[bool]]::new()
        }
        It 'shuts Windows down, waits until off, starts it, and the sweep leaves a disposable copy alone meanwhile' {
            Mock Stop-VM { $script:calls.Add("stop $([bool]$TurnOff)"); $script:sweepSaw = Test-GpuVMDisposableDone -State $script:st -VMState 'Off'; [pscustomobject]@{ State = 'Completed' } }
            $script:states = [System.Collections.Generic.Queue[string]]::new([string[]]@('Running', 'Off', 'Off'))
            Mock Get-VM { [pscustomobject]@{ State = $script:states.Dequeue() } }
            Restart-GpuVMCold -Name c
            ($script:calls -join ',') | Should Be 'stop False,start'
            $script:sweepSaw | Should Be $false
            $script:saved -join ',' | Should Be 'True,False'
            Test-GpuVMDisposableDone -State $script:st -VMState 'Off' | Should Be $true
        }
        It 'removes a finished stop job, and leaves one Hyper-V hasn''t completed (removing it ends the process)' {
            $script:removed = [System.Collections.Generic.List[string]]::new()
            Mock Remove-Job { foreach ($j in @($Job)) { if ($j) { $script:removed.Add("$($j.State)") } } }
            # Real jobs (Remove-Job only takes those): one already finished, one still going.
            $done = Start-ThreadJob { 1 }
            $null = $done | Microsoft.PowerShell.Core\Wait-Job
            $going = Start-ThreadJob { Start-Sleep -Seconds 30 }
            foreach ($script:jobNow in $done, $going) {
                Mock Stop-VM { $script:jobNow }
                $script:states = [System.Collections.Generic.Queue[string]]::new([string[]]@('Running', 'Off', 'Off'))
                Mock Get-VM { [pscustomobject]@{ State = $script:states.Dequeue() } }
                Stop-GpuVMBounded -Name c
            }
            $seen = $script:removed -join ','
            $going | Stop-Job; $done, $going | Microsoft.PowerShell.Core\Remove-Job -Force
            $seen | Should Be 'Completed'
        }
        It 'turns it off when Windows doesn''t shut down in time' {
            Mock Write-Warning { }
            Mock Stop-VM { $script:calls.Add("stop $([bool]$TurnOff)"); if ($TurnOff) { $script:offNow = $true }; [pscustomobject]@{ State = 'Completed' } }
            $script:offNow = $false
            Mock Get-VM { [pscustomobject]@{ State = $(if ($script:offNow) { 'Off' } else { 'Running' }); Id = [guid]::Empty } }
            Restart-GpuVMCold -Name c -ShutdownTimeoutSec 0
            ($script:calls -join ',') | Should Be 'stop False,stop True,start'
        }
        It 'ends its worker process when Hyper-V won''t turn it off, and says so when even that fails' {
            Mock Write-Warning { }
            Mock Stop-VM { $script:calls.Add("stop $([bool]$TurnOff)"); [pscustomobject]@{ State = 'Running' } }
            $script:offNow = $false
            $script:vmId = [guid]'12039a8d-294d-4b80-a677-40d70914339e'
            Mock Get-VM { [pscustomobject]@{ State = $(if ($script:offNow) { 'Off' } else { 'Running' }); Id = $script:vmId } }
            Mock Get-CimInstance { @([pscustomobject]@{ ProcessId = 42; CommandLine = "vmwp.exe 12039a8d-294d-4b80-a677-40d70914339e" }, [pscustomobject]@{ ProcessId = 7; CommandLine = 'vmwp.exe another' }) }
            Mock Stop-Process { $script:calls.Add("kill $Id"); $script:offNow = $true }
            Restart-GpuVMCold -Name c -ShutdownTimeoutSec 0 -TurnOffTimeoutSec 0
            ($script:calls -join ',') | Should Be 'stop False,stop True,kill 42,start'
            Mock Stop-Process { }
            $script:offNow = $false
            $script:calls.Clear()
            Test-Throws { Restart-GpuVMCold -Name c -ShutdownTimeoutSec 0 -TurnOffTimeoutSec 0 } | Should Be $true
            $script:calls -contains 'start' | Should Be $false
            Test-GpuVMDisposableDone -State $script:st -VMState 'Off' | Should Be $true # the mark is cleared even then
        }
    }
}

InModuleScope GpuVM {
    Describe 'One GPU machine changes power at a time' {
        BeforeEach {
            $script:GpuPowerMutexName = "Global\GpuVM.GpuPower.Test.$([guid]::NewGuid().ToString('n'))"
            Mock Write-PowerLog { }
        }
        It 'waits while another process holds the GPU power lock' {
            Mock Test-GpuPartitioned { $true }
            $name = $script:GpuPowerMutexName
            $job = Start-ThreadJob -ArgumentList $name {
                param($n)
                $m = [Threading.Mutex]::new($false, $n)
                [void]$m.WaitOne()
                Start-Sleep -Milliseconds 1500
                $m.ReleaseMutex()
            }
            Start-Sleep -Milliseconds 300
            $w = [Diagnostics.Stopwatch]::StartNew()
            Invoke-GpuPowerTransition -Name a -Do { $script:ran = $true }
            $w.Elapsed.TotalMilliseconds | Should BeGreaterThan 900
            $script:ran | Should Be $true
            $job | Wait-Job | Remove-Job
        }
        It 'a machine without a GPU partition never waits' {
            Mock Test-GpuPartitioned { $false }
            $m = [Threading.Mutex]::new($true, $script:GpuPowerMutexName)
            $w = [Diagnostics.Stopwatch]::StartNew()
            Invoke-GpuPowerTransition -Name a -Do { 1 } | Should Be 1
            $w.Elapsed.TotalMilliseconds | Should BeLessThan 500
            $m.ReleaseMutex(); $m.Dispose()
        }
        It 'a start keeps the lock until Windows answers' {
            Mock Test-GpuPartitioned { $true }
            Mock Get-VM { [pscustomobject]@{ State = 'Running' } }
            $script:beats = 0
            Mock Test-GuestHeartbeat { $script:beats++; $script:beats -ge 3 }
            Mock Start-Sleep { }
            Invoke-GpuPowerTransition -Name a -UntilUp -Do { }
            $script:beats | Should Be 3
        }
    }
}

InModuleScope GpuVM {
    Describe 'The agent knows the viewer''s display mode from boot' {
        It 'the mode is the client''s resolution at its fps, or the monitor''s rate' {
            Get-GpuVMStreamMode -State @{ config = @{ streaming = @{ client = @{ resolution = '1920x1080'; fps = 60 } } } } | Should Be '1920x1080@60'
            Mock Resolve-HostMonitor { @{ hz = 180 } }
            Get-GpuVMStreamMode -State @{ config = @{ streaming = @{ client = @{ resolution = '2560x1440'; fps = 0 } } } } | Should Be '2560x1440@180'
        }
        It 'writes StreamMode only when it changes, and only a mode the agent accepts' {
            $cred = [pscredential]::new('u', (ConvertTo-SecureString 'p' -AsPlainText -Force))
            $script:st = @{ }
            Mock Get-GpuVMState { $script:st }
            Mock Save-GpuVMState { $script:st = $State }
            Mock Invoke-Command { $script:written = $ArgumentList[0] }
            $script:written = $null
            Sync-GuestAgentDisplayMode -Name a -Credential $cred -Mode '1920x1080@180' | Should Be $true
            $script:written | Should Be '1920x1080@180'
            $script:st['agentDisplayMode'] | Should Be '1920x1080@180'
            $script:written = $null
            Sync-GuestAgentDisplayMode -Name a -Credential $cred -Mode '1920x1080@180' | Should Be $false
            $script:written | Should Be $null
            foreach ($bad in '800x600@60', '1920x1080@600', '1920x1080', 'x; rm', '99999x1080@60') {
                Sync-GuestAgentDisplayMode -Name a -Credential $cred -Mode $bad | Should Be $false
            }
            $script:written | Should Be $null
        }
    }
}

InModuleScope GpuVM {
    Describe 'Install-GpuVMAgent gives the virtual display the viewer''s rate before the agent''s first boot' {
        It 'adds a rate the display lacks, then writes StreamMode' {
            $script:steps = [System.Collections.Generic.List[string]]::new()
            Mock Get-GpuVMStreamMode { '1920x1080@180' }
            Mock Add-GuestRefreshRate { $script:steps.Add("rate $Hz"); $true }
            Mock Sync-GuestAgentDisplayMode { $script:steps.Add("mode $Mode"); $true }
            Mock Set-GuestVddPreferredMode { $script:steps.Add("boot ${Width}x${Height}@$Hz"); $true }
            Mock Initialize-GuestStreamingForAgent { $script:steps.Add('sunshine') }
            $state = @{ streaming = @{ x = 1 }; config = @{ streaming = @{ virtualDisplay = $true } } }
            $credential = [pscredential]::new('u', (ConvertTo-SecureString 'p' -AsPlainText -Force))
            $Name = 'a'
            # The block Install-GpuVMAgent runs (taken from its source, so the test follows it).
            $src = Get-Content -Raw (Join-Path (Get-Module GpuVM).ModuleBase 'Public\Install-GpuVMAgent.ps1')
            $block = [regex]::Match($src, "(?s)    if \(\`$state\['streaming'\].*?\r?\n    \}\r?\n").Value
            $block | Should Not BeNullOrEmpty
            Invoke-Expression $block
            ($script:steps -join ',') | Should Be 'rate 180,mode 1920x1080@180,boot 1920x1080@180,sunshine'
            Mock Get-GpuVMStreamMode { '1920x1080@60' }
            $script:steps.Clear()
            Invoke-Expression $block
            ($script:steps -join ',') | Should Be 'mode 1920x1080@60,boot 1920x1080@60,sunshine'
        }
    }
}

InModuleScope GpuVM {
    Describe 'The virtual display boots in the viewer''s mode' {
        It 'puts that mode first in the driver''s list, once, with nothing else lost' {
            $cred = [pscredential]::new('u', (ConvertTo-SecureString 'p' -AsPlainText -Force))
            $script:vdd = Join-Path $TestDrive 'vdd_settings.xml'
            Set-Content -LiteralPath $script:vdd -Value ('<vdd_settings><resolutions>' +
                '<resolution><width>800</width><height>600</height><refresh_rate>30</refresh_rate></resolution>' +
                '<resolution><width>1920</width><height>1080</height><refresh_rate>30</refresh_rate></resolution>' +
                '<resolution><width>2560</width><height>1440</height><refresh_rate>30</refresh_rate></resolution>' +
                '</resolutions><global><g_refresh_rate>60</g_refresh_rate></global></vdd_settings>')
            # The guest's script, run here against a copy of the driver's settings.
            Mock Invoke-Guest {
                $code = $ScriptBlock.ToString().Replace('C:\VirtualDisplayDriver\vdd_settings.xml', $script:vdd)
                & ([scriptblock]::Create($code)) @ArgumentList
            }
            Set-GuestVddPreferredMode -Name a -Credential $cred -Width 1920 -Height 1080 -Hz 180 | Should Be $true
            [xml]$x = Get-Content -Raw -LiteralPath $script:vdd
            $list = @($x.vdd_settings.resolutions.resolution)
            "$($list[0].width)x$($list[0].height)@$($list[0].refresh_rate)" | Should Be '1920x1080@180'
            $list.Count | Should Be 3
            @($list | Where-Object { $_.width -eq '1920' }).Count | Should Be 1
            @($list | Where-Object { $_.width -eq '800' }).Count | Should Be 1
            $x.vdd_settings.global.g_refresh_rate | Should Be '60'
            Set-GuestVddPreferredMode -Name a -Credential $cred -Width 1920 -Height 1080 -Hz 180 | Should Be $false
            Remove-Item -LiteralPath $script:vdd
            Set-GuestVddPreferredMode -Name a -Credential $cred -Width 1920 -Height 1080 -Hz 180 | Should Be $false
        }
    }
}

InModuleScope GpuVM {
    Describe 'Sunshine is set up for an agent machine while its agent is installed' {
        It 'capture and the virtual display, waiting for Sunshine around each change' {
            $cred = [pscredential]::new('u', (ConvertTo-SecureString 'p' -AsPlainText -Force))
            $script:steps = [System.Collections.Generic.List[string]]::new()
            Mock Get-GpuVMState { @{ use = 'agent'; streaming = @{ x = 1 }; config = @{ streaming = @{ virtualDisplay = $true } } } }
            Mock Get-GpuVMAddress { '172.17.0.2' }
            Mock Get-SunshineCredential { $cred }
            Mock Wait-SunshineReady { $script:steps.Add('ready') }
            Mock Set-GuestCaptureMode { $script:steps.Add("capture wgc") }
            Mock Set-SunshineVirtualDisplay { $script:steps.Add("display $([bool]$OnlyDisplay)") }
            Mock Install-GuestSunshineCapture { $script:steps.Add('fork'); 'installed' }
            Initialize-GuestStreamingForAgent -Name a -Credential $cred
            ($script:steps -join ',') | Should Be 'fork,ready,capture wgc,ready,display True'
            # A failed copy of the fork warns and goes on (the guest falls back to ddx).
            Mock Install-GuestSunshineCapture { throw 'no session' }
            Mock Write-Warning { }
            $script:steps.Clear()
            Initialize-GuestStreamingForAgent -Name a -Credential $cred
            ($script:steps -join ',') | Should Be 'ready,capture wgc,ready,display True'
            # A copy of a current template: nothing changes, so Sunshine's start isn't waited for; the mark is used once.
            $script:saved = $null
            Mock Get-GpuVMState { @{ use = 'agent'; streamingFromTemplate = $true; streaming = @{ x = 1 }; config = @{ streaming = @{ virtualDisplay = $true } } } }
            Mock Save-GpuVMState { $script:saved = $State }
            Mock Install-GuestSunshineCapture { $script:steps.Add('fork'); 'unchanged' }
            Mock Set-GuestCaptureMode { $script:steps.Add("capture wgc"); $false }
            $script:steps.Clear()
            Initialize-GuestStreamingForAgent -Name a -Credential $cred
            ($script:steps -join ',') | Should Be 'fork,capture wgc'
            $script:saved.Contains('streamingFromTemplate') | Should Be $false
            # The mode had to change after all: the full setup follows.
            Mock Set-GuestCaptureMode { $script:steps.Add("capture wgc"); $true }
            $script:steps.Clear()
            Initialize-GuestStreamingForAgent -Name a -Credential $cred
            ($script:steps -join ',') | Should Be 'fork,capture wgc,ready,capture wgc,ready,display True'
            Mock Get-GpuVMState { @{ use = 'agent'; streaming = @{ x = 1 }; config = @{ streaming = @{ virtualDisplay = $true } } } }
            Mock Get-GpuVMState { @{ use = 'agent'; config = @{ streaming = @{} } } }
            $script:steps.Clear()
            Initialize-GuestStreamingForAgent -Name a -Credential $cred
            $script:steps.Count | Should Be 0
        }
    }
}
