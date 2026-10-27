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
            ($a -join ' ') | Should Be 'stream 1.2.3.4 "Desktop" --no-vsync --performance-overlay --display-mode fullscreen'
        }

        It 'data lives outside the code when installed; in the repo, in the repo' {
            $script:DataRoot | Should Be $script:RepoRoot
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
            $m['vbcable']['sha256'] | Should Match '^[0-9a-f]{64}$'
            $m['vbcable']['url'] | Should Match '^https://download\.vb-audio\.com/'
            foreach ($key in 'sunshine', 'vdd', 'nefcon') {
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

        $env:GPUVM_CACHE_ROOT = $null
    }

    Describe 'Streaming' {
        It 'the base profile includes Sunshine with a virtual display' {
            $p = Resolve-GpuVMProfile -Name 'balanced'
            $p['streaming']['provider'] | Should Be 'sunshine'
            (Get-StreamingComponentNames $p['streaming']) -join ',' | Should Be 'sunshine,vdd,vbcable,nefcon'
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

        It 'without a virtual display it still includes nefcon for audio' {
            $p = Resolve-GpuVMProfile -Name 'balanced' -Override @{ streaming = @{ virtualDisplay = $false; disableHyperVVideo = $false } }
            (Get-StreamingComponentNames $p['streaming']) -join ',' | Should Be 'sunshine,vbcable,nefcon'
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
            ($a -join ' ') | Should Be 'stream 172.20.1.5 "Desktop" --resolution 2560x1440 --fps 120 --video-codec HEVC'
        }

        It 'pairs by sending Sunshine the same PIN Moonlight receives' {
            $script:sent = $null
            Mock Start-Process {
                $script:moonlightArgs = $ArgumentList
                $p = [pscustomobject]@{ HasExited = $false; ExitCode = 0 }
                $p | Add-Member ScriptMethod WaitForExit { param($ms) $true }
                $p
            }
            Mock Invoke-SunshineApi { [pscustomobject]@{ pairings = @([pscustomobject]@{ id = ('a' * 32); name = 'x'; address = '172.20.1.1' }) } } -ParameterFilter { $Method -ne 'POST' }
            Mock Invoke-SunshineApi { $script:sent = $Body; [pscustomobject]@{ status = $true } } -ParameterFilter { $Method -eq 'POST' }

            $cred = [pscredential]::new('gpuvm', (ConvertTo-SecureString 'x' -AsPlainText -Force))
            Register-MoonlightPairing -Address '172.20.1.5' -Credential $cred -MoonlightPath 'moonlight.exe' -ClientName 'HOST'
            $script:sent['pairing_id'] | Should Be ('a' * 32)
            $script:sent['pin'] | Should Be $script:moonlightArgs[3]
            $script:sent['name'] | Should Be 'HOST'
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

        It 'sunshine.conf: replaces existing keys and appends new ones' {
            . (Join-Path $script:RepoRoot 'guest\streaming.ps1')
            $conf = Join-Path $TestDrive 'sunshine.conf'
            "encoder = software`r`nport = 47989" | Set-Content $conf
            Set-SunshineConfig -Path $conf -Settings ([ordered]@{ encoder = 'nvenc'; adapter_name = 'NVIDIA GeForce RTX 4060' })
            $lines = Get-Content $conf
            $lines | Should Be @('encoder = nvenc', 'port = 47989', 'adapter_name = NVIDIA GeForce RTX 4060')
        }
    }
}
