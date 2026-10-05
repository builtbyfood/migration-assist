# Offline tests for Invoke-VMwareToVirtio.ps1 1.4.0 (runs on pwsh 7, Windows or Linux; mocks registry and NetTCPIP).
$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot 'Invoke-VMwareToVirtio.ps1'
$pass = 0; $fail = 0
function Check($name, $cond) { if ($cond) { $script:pass++; "PASS  $name" } else { $script:fail++; "FAIL  $name" } }

# 1. Parse the whole script
$tokens = $null; $errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$tokens, [ref]$errs)
Check "script parses with no syntax errors ($($errs.Count))" ($errs.Count -eq 0)
$errs | ForEach-Object { "      $($_.Extent.StartLineNumber): $($_.Message)" }

# 2. Nothing newer than Windows PowerShell 5.1 syntax
$ps7 = $tokens | Where-Object { $_.Kind -in 'AndAnd','OrOr','QuestionQuestion','QuestionQuestionEquals','QuestionDot','QuestionLBracket' }
Check 'no PS7-only operators (&&, ||, ??, ?.)' (-not $ps7)
$tern = $ast.FindAll({ $args[0].GetType().Name -eq 'TernaryExpressionAst' }, $true)
Check 'no ternary operator' ($tern.Count -eq 0)
$bad = Select-String -Path $script -Pattern '\$\{|<%' 
Check 'no ${ or <% (Morpheus template collisions)' (-not $bad)

# 3. C# compiles at C# 5 (what Windows PowerShell 5.1 / .NET 4 csc supports)
$hs = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $args[0].Value -match 'namespace VmwToVirtio' }, $true) | Select-Object -First 1
try {
    Add-Type -TypeDefinition $hs.Value -CompilerOptions '-langversion:5'
    Check 'native helper compiles as C# 5' $true
} catch { Check "native helper compiles as C# 5: $($_.Exception.Message)" $false }
Check 'ListDevices / RemoveDevice / DeleteAtReboot exported' (
    [VmwToVirtio.Native].GetMethod('ListDevices') -and [VmwToVirtio.Native].GetMethod('RemoveDevice') -and [VmwToVirtio.Native].GetMethod('DeleteAtReboot'))

# 4. Load every function from the script without running the main body
$script:LogLines = New-Object System.Collections.Generic.List[string]
foreach ($f in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    . ([scriptblock]::Create($f.Extent.Text))
}
function Log([string]$Message, [string]$Level = 'INFO') { $script:LogLines.Add("[$Level] $Message") }
$env:SystemRoot = 'C:\Windows'
# Run state the script initialises at startup (1.2.0 change tracking)
$script:Did = @{ VirtIO = 'not checked'; Ghosts = 0; Services = 0; Packages = 0; Files = 0; RegKeys = 0; Filters = 0; Nics = @() }
$script:NeedsReboot = $false; $script:Leftovers = @()

# Resolve-ImagePath
Check 'ImagePath \SystemRoot\...'  ((Resolve-ImagePath '\SystemRoot\system32\DRIVERS\vmci.sys') -eq 'C:\Windows\system32\DRIVERS\vmci.sys')
Check 'ImagePath System32\...'     ((Resolve-ImagePath 'System32\drivers\vmmouse.sys') -eq 'C:\Windows\System32\drivers\vmmouse.sys')
Check 'ImagePath quoted with args' ((Resolve-ImagePath '"C:\Program Files\VMware\VMware Tools\vmtoolsd.exe" -n vmusr') -eq 'C:\Program Files\VMware\VMware Tools\vmtoolsd.exe')
Check 'ImagePath \??\ prefix'      ((Resolve-ImagePath '\??\C:\Windows\system32\drivers\vsock.sys') -eq 'C:\Windows\system32\drivers\vsock.sys')

# Squashed GUID (independent reference value)
Check 'squashed GUID' ((ConvertTo-SquashedGuid '{12345678-ABCD-EF01-2345-6789ABCDEF01}') -eq '87654321DCBA10FE32547698BADCFE10')

# VirtIO device naming
Check 'virtio-net modern id'   ((Get-VirtioDeviceType 'PCI\VEN_1AF4&DEV_1041&SUBSYS_11001AF4&REV_01\3&267A616A&0&18') -eq 'Network (netkvm)')
Check 'balloon legacy id'      ((Get-VirtioDeviceType 'PCI\VEN_1AF4&DEV_1002&SUBSYS_00051AF4&REV_00\3&1') -eq 'Memory balloon (balloon)')
Check 'pvpanic'                ((Get-VirtioDeviceType 'PCI\VEN_1B36&DEV_0011&SUBSYS_11001AF4\3&1') -eq 'PV panic (pvpanic)')
Check 'fw_cfg'                 ((Get-VirtioDeviceType 'ACPI\QEMU0002\0') -eq 'FW cfg (fwcfg)')

# Ghost selection with devices shaped like a real migrated 2012 R2 / 2022 guest
$mk = { param($id,$fn,$desc,$mfg,$cls,$drv,$present) [pscustomobject]@{InstanceId=$id;FriendlyName=$fn;Description=$desc;Manufacturer=$mfg;Class=$cls;Driver=$drv;Present=$present} }
$devs = @(
  (& $mk 'PCI\VEN_15AD&DEV_07B0&SUBSYS_07B015AD&REV_01\FF565000F8D2C7FE00' 'vmxnet3 Ethernet Adapter' 'vmxnet3 Ethernet Adapter' 'VMware, Inc.' 'Net' '{4d36e972-e325-11ce-bfc1-08002be10318}\0007' $false)
  (& $mk 'PCI\VEN_8086&DEV_100F&SUBSYS_075015AD&REV_01\4&B70F118&0&0888' $null 'Intel(R) PRO/1000 MT Network Connection' 'Intel' 'Net' '{4d36e972-e325-11ce-bfc1-08002be10318}\0001' $false)
  (& $mk 'PCI\VEN_1AF4&DEV_1041&SUBSYS_11001AF4&REV_01\3&267A616A&0&18' 'Red Hat VirtIO Ethernet Adapter' 'Red Hat VirtIO Ethernet Adapter' 'Red Hat, Inc.' 'Net' '{4d36e972-e325-11ce-bfc1-08002be10318}\0010' $true)
  (& $mk 'PCI\VEN_15AD&DEV_0405&SUBSYS_040515AD&REV_00\3&61AAA01&0&78' 'VMware SVGA 3D' 'VMware SVGA 3D' 'VMware, Inc.' 'Display' '{4d36e968-e325-11ce-bfc1-08002be10318}\0000' $false)
  (& $mk 'SCSI\DISK&VEN_VMWARE&PROD_VIRTUAL_DISK\5&1EC51BF7&0&000000' 'VMware Virtual disk SCSI Disk Device' 'Disk drive' '(Standard disk drives)' 'DiskDrive' $null $false)
  (& $mk 'ROOT\KDNIC\0000' $null 'Microsoft Kernel Debug Network Adapter' 'Microsoft' 'Net' $null $false)
  (& $mk 'SWD\MSRRAS\MS_NDISWANIP' 'WAN Miniport (IP)' 'WAN Miniport (IP)' 'Microsoft' 'Net' $null $true)
  (& $mk 'ACPI\PNP0303\4&1' 'Standard PS/2 Keyboard' 'Standard PS/2 Keyboard' '(Standard keyboards)' 'Keyboard' $null $true)
)
$g = Select-GhostDevices $devs
$ids = @($g | ForEach-Object InstanceId)
Check 'ghost vmxnet3 selected'          ($ids -contains $devs[0].InstanceId)
Check 'ghost e1000 selected'            ($ids -contains $devs[1].InstanceId)
Check 'present virtio NIC NOT selected' ($ids -notcontains $devs[2].InstanceId)
Check 'ghost VMware SVGA selected'      ($ids -contains $devs[3].InstanceId)
Check 'ghost VMware disk selected'      ($ids -contains $devs[4].InstanceId)
Check 'ghost kernel-debug NIC skipped'  ($ids -notcontains $devs[5].InstanceId)
Check 'present software NIC skipped'    ($ids -notcontains $devs[6].InstanceId)
Check 'exactly 4 selected'              ($g.Count -eq 4)
Check 'empty input returns empty array' ((Select-GhostDevices @()).Count -eq 0)

# Registry chain for ghost NIC settings, with Get-ItemProperty mocked (functions win over cmdlets)
$fakeReg = @{
  'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}\0007' = @{ NetCfgInstanceId = '{AAAA1111-0000-0000-0000-000000000001}' }
  'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\{AAAA1111-0000-0000-0000-000000000001}' = @{ EnableDHCP = 0; IPAddress = [string[]]@('10.20.30.40'); SubnetMask = [string[]]@('255.255.255.0'); DefaultGateway = [string[]]@('10.20.30.1'); NameServer = '10.20.1.10,10.20.1.11' }
  'HKLM:\SYSTEM\CurrentControlSet\Control\Network\{4D36E972-E325-11CE-BFC1-08002BE10318}\{AAAA1111-0000-0000-0000-000000000001}\Connection' = @{ Name = 'Ethernet0' }
  'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}\0001' = @{ NetCfgInstanceId = '{BBBB2222-0000-0000-0000-000000000002}' }
  'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\{BBBB2222-0000-0000-0000-000000000002}' = @{ EnableDHCP = 1; IPAddress = $null; SubnetMask = $null; DefaultGateway = $null; NameServer = '' }
}
function Get-ItemProperty { param([string]$LiteralPath, [string]$Name, $ErrorAction)
  if ($fakeReg.ContainsKey($LiteralPath)) { [pscustomobject]$fakeReg[$LiteralPath] } }

$c = Get-NicTcpip $devs[0].Driver
Check 'static NIC: IP'         ($c.IPAddress -eq '10.20.30.40')
Check 'static NIC: mask/gw'    ($c.SubnetMask -eq '255.255.255.0' -and $c.Gateway -eq '10.20.30.1')
Check 'static NIC: DNS'        ($c.DNS -eq '10.20.1.10,10.20.1.11')
Check 'static NIC: DHCP false' ($c.DHCP -eq $false)
Check 'static NIC: conn name'  ($c.Connection -eq 'Ethernet0')
Check 'DHCP NIC flagged DHCP'  ((Get-NicTcpip $devs[1].Driver).DHCP -eq $true)
Check 'missing driver key -> null'    ($null -eq (Get-NicTcpip $null))
Check 'unknown driver key -> null'    ($null -eq (Get-NicTcpip '{4d36e972-e325-11ce-bfc1-08002be10318}\0099'))

$out = Join-Path ([IO.Path]::GetTempPath()) 'ghost-test.txt'; Remove-Item $out -ErrorAction SilentlyContinue
$caps = Save-GhostNicConfig $g $out
Check 'capture returns 2 NICs' ($caps.Count -eq 2)
$txt = Get-Content $out -Raw
Check 'report has static line' ($txt -match "vmxnet3 Ethernet Adapter' \(connection 'Ethernet0', MAC 00-50-56-C7-D2-F8 or 00-50-56-F8-D2-C7 decoded from device ID\): DHCP=False IP=10\.20\.30\.40 Mask=255\.255\.255\.0 GW=10\.20\.30\.1 DNS=10\.20\.1\.10,10\.20\.1\.11")
Check 'e1000 labelled by desc' ($txt -match 'Intel\(R\) PRO/1000 MT')
Check 'no NICs -> empty array' ((Save-GhostNicConfig @() '').Count -eq 0)

# VirtIO gap logic
$inv = [pscustomobject]@{ Suite=@(); GuestAgent=$false; Missing=@([pscustomobject]@{Type='Memory balloon (balloon)'}); Core=@([pscustomobject]@{Name='netkvm';Staged=$false}) }
$gaps = Get-VirtioGaps $inv
Check 'injector-only VM: 4 gaps' ($gaps.Count -eq 4)
$inv2 = [pscustomobject]@{ Suite=@([pscustomobject]@{DisplayName='Virtio-win-guest-tools'}); GuestAgent=$true; Missing=@(); Core=@([pscustomobject]@{Name='netkvm';Staged=$true}) }
Check 'complete VM: 0 gaps' ((Get-VirtioGaps $inv2).Count -eq 0)


# ---------------- MAC decode, prefix, matching
$m = Get-MacFromInstanceId 'PCI\VEN_15AD&DEV_07B0&SUBSYS_07B015AD&REV_01\FF565000F8D2C7FE00'
Check 'vmxnet3 MAC decoded (2 byte-order candidates)' ($m.Count -eq 2 -and $m -contains '00-50-56-C7-D2-F8' -and $m -contains '00-50-56-F8-D2-C7')
$m2 = Get-MacFromInstanceId 'PCI\VEN_15AD&DEV_07B0&SUBSYS_07B015AD&REV_01\FF290C00A1B2C3FE00'
Check 'ESXi-generated 00:0C:29 MAC decoded' ($m2 -contains '00-0C-29-C3-B2-A1')
Check 'e1000 location id -> no MAC' ((Get-MacFromInstanceId 'PCI\VEN_8086&DEV_100F&SUBSYS_075015AD&REV_01\4&B70F118&0&0888').Count -eq 0)
Check 'caps carry decoded MAC'      ($caps[0].MacCandidates -contains '00-50-56-C7-D2-F8')
Check '/24' ((ConvertTo-PrefixLength '255.255.255.0') -eq 24)
Check '/22' ((ConvertTo-PrefixLength '255.255.252.0') -eq 22)
Check '/32' ((ConvertTo-PrefixLength '255.255.255.255') -eq 32)
Check '/0'  ((ConvertTo-PrefixLength '0.0.0.0') -eq 0)

$ad = { param($i,$n,$mac) [pscustomobject]@{ ifIndex=$i; Name=$n; MacAddress=$mac; InterfaceDescription='Red Hat VirtIO Ethernet Adapter'; Status='Up' } }
$A1 = & $ad 11 'Ethernet 2' '00-50-56-F8-D2-C7'   # preserved MAC of the vmxnet3
$A2 = & $ad 12 'Ethernet 3' '52-54-00-11-22-33'
$r = Resolve-NicMatches $caps @($A1, $A2)
$vm = $r | Where-Object { $_.Capture.Label -like 'vmxnet3*' }
$e1 = $r | Where-Object { $_.Capture.Label -like 'Intel*' }
Check 'vmxnet3 matched by MAC to Ethernet 2' ($vm.Adapter.ifIndex -eq 11 -and $vm.Method -eq 'MAC')
Check 'e1000 takes the only remaining NIC'   ($e1.Adapter.ifIndex -eq 12 -and $e1.Method -eq 'only remaining NIC')
$r = Resolve-NicMatches @($caps[0]) @($A2)
Check 'single NIC, MAC not preserved -> 1:1' ($r[0].Adapter.ifIndex -eq 12 -and $r[0].Method -eq 'only remaining NIC')
$A3 = & $ad 13 'Ethernet 4' '52-54-00-44-55-66'
$r = Resolve-NicMatches @($caps[1]) @($A2, $A3)
Check 'no MAC + 2 NICs -> unmatched (no guessing)' ($null -eq $r[0].Adapter -and $r[0].Method -eq 'unmatched')
$r = Resolve-NicMatches @($caps[0], $caps[1]) @($A2, $A3)
Check 'MAC not found + 2/2 -> both unmatched' (@($r | Where-Object Adapter).Count -eq 0)

# JSON round trip used for re-runs (PS 5.1 serialises the same way)
$j = ConvertTo-Json -InputObject @($caps[0]) -Depth 4
$back = @($j | ConvertFrom-Json | ForEach-Object { $_ })
Check 'json keeps single capture as array' ($j.TrimStart().StartsWith('[') -and $back.Count -eq 1)
Check 'json keeps MAC list and DHCP flag'  ($back[0].MacCandidates -contains '00-50-56-C7-D2-F8' -and $back[0].DHCP -eq $false)
Check 'reloaded capture still matches by MAC' ((Resolve-NicMatches $back @($A1,$A2))[0].Adapter.ifIndex -eq 11)

# ---------------- Apply path with NetTCPIP / DnsClient cmdlets mocked
$script:calls = New-Object System.Collections.Generic.List[string]
$script:addrState = 'Preferred'; $script:existing = @(); $script:dhcpState = 'Enabled'; $script:arpOk = $true
function Get-NetIPAddress { param($InterfaceIndex,$AddressFamily,$IPAddress,$ErrorAction)
  if ($IPAddress) { [pscustomobject]@{ IPAddress=$IPAddress; AddressState=$script:addrState } } else { $script:existing | ForEach-Object { [pscustomobject]@{IPAddress=$_} } } }
function Get-NetIPInterface { param($InterfaceIndex,$AddressFamily,$ErrorAction) [pscustomobject]@{ Dhcp=$script:dhcpState } }
function Set-NetIPInterface { param($InterfaceIndex,$AddressFamily,$Dhcp,$ErrorAction) $script:calls.Add("Set-NetIPInterface dhcp=$Dhcp") }
function Get-NetRoute { param($InterfaceIndex,$DestinationPrefix,$ErrorAction) }
function Remove-NetRoute { param([Parameter(ValueFromPipeline)]$x,$Confirm) }
function Remove-NetIPAddress { param([Parameter(ValueFromPipeline)]$x,$Confirm) process { if ($x) { $script:calls.Add("Remove-NetIPAddress $($x.IPAddress)") } } }
function New-NetIPAddress { param($InterfaceIndex,$AddressFamily,$IPAddress,$PrefixLength,$DefaultGateway,$ErrorAction) $script:calls.Add("New-NetIPAddress $IPAddress/$PrefixLength gw=$DefaultGateway") }
function New-NetRoute { param($InterfaceIndex,$DestinationPrefix,$NextHop,$RouteMetric,$ErrorAction) $script:calls.Add("New-NetRoute $NextHop") }
function Set-DnsClientServerAddress { param($InterfaceIndex,$ServerAddresses,[switch]$ResetServerAddresses,$ErrorAction) $script:calls.Add("DNS " + $(if ($ResetServerAddresses) {'reset'} else {$ServerAddresses -join ','})) }
function Set-DnsClient { param($InterfaceIndex,$ConnectionSpecificSuffix,$ErrorAction) $script:calls.Add("Suffix $ConnectionSpecificSuffix") }
function Test-Connection { param($ComputerName,$Count,[switch]$Quiet,$ErrorAction) $true }
function Get-NetNeighbor { param($InterfaceIndex,$IPAddress,$ErrorAction) if ($script:arpOk) { [pscustomobject]@{LinkLayerAddress='00-11-22-33-44-55';State='Reachable'} } else { [pscustomobject]@{LinkLayerAddress='00-00-00-00-00-00';State='Unreachable'} } }
function Rename-NetAdapter { param($Name,$NewName,$ErrorAction) $script:calls.Add("Rename $Name -> $NewName") }
function Start-Sleep { param($Seconds) }
$script:Failures = New-Object System.Collections.Generic.List[string]
function Fail([string]$Message) { $script:Failures.Add($Message) }
$RollbackIfUnreachable = $true

$res = Set-NicFromCapture $caps[0] $A1
Check 'static capture applied'          ($res -eq 'applied')
Check 'DHCP disabled first'             ($calls[0] -eq 'Set-NetIPInterface dhcp=Disabled')
Check 'IP /24 with gateway'             ($calls -contains 'New-NetIPAddress 10.20.30.40/24 gw=10.20.30.1')
Check 'both DNS servers set'            ($calls -contains 'DNS 10.20.1.10,10.20.1.11')
Check 'adapter renamed to Ethernet0'    ($calls -contains 'Rename Ethernet 2 -> Ethernet0')
Check 'no failures recorded'            ($script:Failures.Count -eq 0)

$calls.Clear(); $script:existing = @('10.20.30.40')
Check 're-run: already applied -> no changes' ((Set-NicFromCapture $caps[0] $A1) -eq 'present' -and $calls.Count -eq 0)

$calls.Clear(); $script:existing = @('192.168.5.5'); $script:dhcpState = 'Disabled'
Check 'different static IP -> not overwritten' ((Set-NicFromCapture $caps[0] $A1) -eq 'conflict' -and $calls.Count -eq 0)

$calls.Clear(); $script:existing = @('169.254.10.10'); $script:dhcpState = 'Enabled'
Check 'DHCP capture -> nothing applied' ((Set-NicFromCapture $caps[1] $A2) -eq 'dhcp' -and $calls.Count -eq 0)

$calls.Clear(); $script:addrState = 'Duplicate'
$res = Set-NicFromCapture $caps[0] $A1
Check 'duplicate IP -> rolled back'         ($res -eq 'rolled back')
Check 'rollback re-enables DHCP + resets DNS' ($calls -contains 'Set-NetIPInterface dhcp=Enabled' -and $calls -contains 'DNS reset')
Check 'duplicate reported as failure'       ($script:Failures[-1] -match 'already in use')
Check 'no rename after rollback'            (-not ($calls -match '^Rename'))

$calls.Clear(); $script:addrState = 'Preferred'; $script:arpOk = $false; $script:Failures.Clear()
Check 'gateway silent -> rolled back'       ((Set-NicFromCapture $caps[0] $A1) -eq 'rolled back' -and $script:Failures[-1] -match 'did not answer ARP')

$calls.Clear(); $RollbackIfUnreachable = $false
Check 'rollback off -> left applied'        ((Set-NicFromCapture $caps[0] $A1) -eq 'applied' -and -not ($calls -contains 'Set-NetIPInterface dhcp=Enabled'))
$RollbackIfUnreachable = $true; $script:arpOk = $true

$multi = $caps[0].PSObject.Copy(); $multi.IPAddress = '10.20.30.40,10.20.30.41'; $multi.SubnetMask = '255.255.255.0,255.255.255.128'; $multi.Gateway = '10.20.30.1,10.20.30.2'
$calls.Clear()
$null = Set-NicFromCapture $multi $A1
Check 'multi-IP: second address, own mask, no gw' ($calls -contains 'New-NetIPAddress 10.20.30.41/25 gw=')
Check 'multi-gateway: extra default route'        ($calls -contains 'New-NetRoute 10.20.30.2')

# ---------------- 1.0.1: never delete non-VMware files under the Windows directory
& {
    $company = @{ 'C:\Windows\system32\dllhost.exe' = 'Microsoft Corporation'; 'C:\Windows\system32\svchost.exe' = 'Microsoft Corporation'
                  'C:\Windows\System32\drivers\vmci.sys' = 'VMware, Inc.'; 'C:\Windows\System32\drivers\pvscsii.sys' = 'VMware, Inc.' }
    function Get-CompanyName([string]$File) { $company[$File] }
    function Test-Path { param([string]$LiteralPath, $PathType)
        if ($PathType -eq 'Container') { return $LiteralPath -in 'C:\Windows\System32', 'C:\Program Files\VMware' }
        return $true }
    $script:removed = New-Object System.Collections.Generic.List[string]
    function Remove-Item { param([string]$LiteralPath, [switch]$Recurse, [switch]$Force, $ErrorAction) $script:removed.Add($LiteralPath) }
    $script:LogLines.Clear()

    Check 'dllhost.exe (Microsoft) is not safe to delete' (-not (Test-SafeToDelete 'C:\Windows\system32\dllhost.exe'))
    Check 'svchost.exe (Microsoft) is not safe to delete' (-not (Test-SafeToDelete 'C:\Windows\system32\svchost.exe'))
    Check 'unknown-publisher file under Windows refused'  (-not (Test-SafeToDelete 'C:\Windows\System32\mystery.sys'))
    Check 'a folder under Windows is never deleted'       (-not (Test-SafeToDelete 'C:\Windows\System32'))
    Check 'VMware driver under Windows is allowed'        (Test-SafeToDelete 'C:\Windows\System32\drivers\vmci.sys')
    Check 'VMware Program Files folder is allowed'        (Test-SafeToDelete 'C:\Program Files\VMware')

    Remove-PathOrSchedule 'C:\Windows\system32\dllhost.exe'
    Check 'Remove-PathOrSchedule never touches dllhost.exe' ($script:removed.Count -eq 0 -and ($script:LogLines -match 'Refusing to delete C:\\Windows\\system32\\dllhost.exe'))
    Remove-PathOrSchedule 'C:\Windows\System32\drivers\vmci.sys'
    Check 'Remove-PathOrSchedule deletes the VMware driver' ($script:removed -contains 'C:\Windows\System32\drivers\vmci.sys')
}

# The service-binary filter used in phase 2d (same expression as the script)
& {
    function Get-CompanyName([string]$File) { @{ 'C:\Windows\system32\dllhost.exe' = 'Microsoft Corporation'; 'C:\Windows\system32\drivers\vmci.sys' = 'VMware, Inc.' }[$File] }
    $line = (Select-String -Path $script -Pattern "-and \(Get-CompanyName \`$t.Image\) -match 'VMware\|Broadcom'").Line
    Check 'phase 2d only queues VMware-published service binaries' ([bool]$line)
    $queue = { param($img) $img -and $img -notmatch '\\VMware\\' -and (Get-CompanyName $img) -match 'VMware' }
    Check 'vmvss -> dllhost.exe NOT queued' (-not (& $queue 'C:\Windows\system32\dllhost.exe'))
    Check 'vmci  -> vmci.sys queued'        (& $queue 'C:\Windows\system32\drivers\vmci.sys')
}
Check 'DeleteAtReboot now returns a Win32 error code' ([VmwToVirtio.Native].GetMethod('DeleteAtReboot').ReturnType -eq [int])

# ---------------- 1.1.0: pre-migration capture -> exact MAC for location-based vmxnet3 IDs (real ID from a migrated VM)
$realId = 'PCI\VEN_15AD&DEV_07B0&SUBSYS_07B015AD&REV_01\3&218E0F40&0&08'
Check 'real-world location-based vmxnet3 ID carries no MAC' ((Get-MacFromInstanceId $realId).Count -eq 0)
Check 'Get-TcpipByGuid(null) -> null' ($null -eq (Get-TcpipByGuid $null))

# On VMware: capture GUID -> MAC + IPv4 (adapter cmdlet mocked)
function Get-TargetAdapters { ,@([pscustomobject]@{ Name='Ethernet0'; InterfaceDescription='vmxnet3 Ethernet Adapter'; MacAddress='00-50-56-9A-4B-21'; InterfaceGuid='{AAAA1111-0000-0000-0000-000000000001}'; ifIndex=7 }) }
$preFile = Join-Path ([IO.Path]::GetTempPath()) 'nic-premigration-test.json'; Remove-Item $preFile -ErrorAction SilentlyContinue
$pre = Save-PreMigrationNics $preFile
Check 'pre-migration: 1 NIC captured'             ($pre.Count -eq 1)
Check 'pre-migration: MAC + static IP recorded'   ($pre[0].MacAddress -eq '00-50-56-9A-4B-21' -and $pre[0].IPAddress -eq '10.20.30.40' -and $pre[0].DHCP -eq $false)
Check 'pre-migration: JSON written'               (Test-Path $preFile)

# After migration: reload exactly as the script does, then capture the ghost with the real-world ID
$script:PreMig = @(Get-Content -Path $preFile -Raw | ConvertFrom-Json | ForEach-Object { $_ })
$ghostReal = [pscustomobject]@{ InstanceId=$realId; FriendlyName='vmxnet3 Ethernet Adapter'; Description='vmxnet3 Ethernet Adapter'; Manufacturer='VMware, Inc.'; Class='Net'; Driver='{4d36e972-e325-11ce-bfc1-08002be10318}\0007'; Present=$false }
$script:LogLines.Clear()
$c2 = Save-GhostNicConfig @($ghostReal) ''
Check 'ghost gets exact MAC via interface GUID'   ($c2.Count -eq 1 -and @($c2[0].MacCandidates).Count -eq 1 -and $c2[0].MacCandidates[0] -eq '00-50-56-9A-4B-21')
Check 'log says MAC came from pre-migration'      (($script:LogLines -join "`n") -match '00-50-56-9A-4B-21 from pre-migration capture')

# Two virtio NICs: only the preserved MAC may win, regardless of order
$vA = [pscustomobject]@{ ifIndex=21; Name='Ethernet 2'; MacAddress='52-54-00-AA-BB-CC'; InterfaceDescription='Red Hat VirtIO Ethernet Adapter'; Status='Up' }
$vB = [pscustomobject]@{ ifIndex=22; Name='Ethernet 3'; MacAddress='00-50-56-9A-4B-21'; InterfaceDescription='Red Hat VirtIO Ethernet Adapter #2'; Status='Up' }
$r1 = Resolve-NicMatches $c2 @($vA, $vB); $r2 = Resolve-NicMatches $c2 @($vB, $vA)
Check 'multi-NIC: matched to preserved MAC by MAC' ($r1[0].Adapter.ifIndex -eq 22 -and $r1[0].Method -eq 'MAC' -and $r2[0].Adapter.ifIndex -eq 22)

# Same VM without a pre-migration capture: must refuse to guess between two NICs
$script:PreMig = @()
$c3 = Save-GhostNicConfig @($ghostReal) ''
Check 'no capture: MAC unknown'                   (@($c3[0].MacCandidates).Count -eq 0)
Check 'no capture + 2 NICs: unmatched, not guessed' ((Resolve-NicMatches $c3 @($vA, $vB))[0].Method -eq 'unmatched')
Check 'no capture + 1 NIC: 1:1 still works'       ((Resolve-NicMatches $c3 @($vB))[0].Method -eq 'only remaining NIC')

# ---------------- 1.2.0: change tracking, honest summary, reboot only when needed, optional Private profile
function Reset-Run { $script:Did = @{ VirtIO = 'not checked'; Ghosts = 0; Services = 0; Packages = 0; Files = 0; RegKeys = 0; Filters = 0; Nics = @() }
                     $script:NeedsReboot = $false; $script:Failures.Clear(); $script:Leftovers = @(); $script:LogLines.Clear() }

# Already-clean VM (the 08:34 run): nothing marked -> no reboot, summary says so
Reset-Run
$script:Did.VirtIO = 'already complete, nothing installed'
$script:Did.Nics += Get-NicResultText 'Ethernet' 'dhcp' ([pscustomobject]@{ IPAddress = '' })
Write-RunSummary
$sum = $script:LogLines -join "`n"
Check 'clean VM: no reboot needed'                   (-not $script:NeedsReboot)
Check 'clean VM: VirtIO reported as already complete' ($sum -match 'VirtIO\s+: already complete, nothing installed')
Check 'clean VM: VMware Tools "none found"'           ($sum -match 'VMware Tools : none found, nothing removed')
Check 'clean VM: NIC left on DHCP'                    ($sum -match 'NIC\s+: Ethernet: old NIC used DHCP, left on DHCP')
Check 'clean VM: no false "installed and removed"'    ($sum -notmatch 'VirtIO tools installed and VMware Tools removed')

# Fresh migrated VM (the 22:40 run): counts add up and a reboot is required
Reset-Run
1..10 | ForEach-Object { Mark 'Ghosts' }
1..19 | ForEach-Object { Mark 'Services' -Reboot }
1..6  | ForEach-Object { Mark 'Packages' -Reboot }
Mark 'Filters' -Reboot
1..21 | ForEach-Object { Mark 'Files' }
1..7  | ForEach-Object { Mark 'RegKeys' }
$script:Did.VirtIO = 'already complete, nothing installed'
Write-RunSummary
$sum = $script:LogLines -join "`n"
Check 'fresh VM: reboot needed'           ($script:NeedsReboot)
Check 'fresh VM: counts in summary'       ($sum -match 'removed - 10 ghost device\(s\), 19 service\(s\)/driver\(s\), 6 driver package\(s\), 21 file/folder\(s\), 7 registry item\(s\), 1 filter/provider')

# Things that change state but do not need a reboot
Reset-Run; Mark 'Ghosts'; Mark 'Files'; Mark 'RegKeys'
Check 'ghost/file/registry-only changes: no reboot' (-not $script:NeedsReboot)
Reset-Run; Mark 'Files' -Reboot
Check 'file queued for boot-time delete: reboot'   ($script:NeedsReboot)
Reset-Run; Mark '' -Reboot
Check 'VirtIO install / MSI success: reboot, no counter touched' ($script:NeedsReboot -and ($script:Did.Values | Where-Object { $_ -is [int] } | Measure-Object -Sum).Sum -eq 0)

# NIC result wording
$cap = [pscustomobject]@{ IPAddress = '10.20.30.40' }
Check 'applied wording'     ((Get-NicResultText 'Ethernet0' 'applied' $cap) -eq 'Ethernet0: old static settings applied and verified (10.20.30.40)')
Check 'rolled back wording' ((Get-NicResultText 'Ethernet0' 'rolled back' $cap) -match 'reverted to DHCP')
Check 'conflict wording'    ((Get-NicResultText 'Ethernet0' 'conflict' $cap) -match 'left unchanged')

# Failures and leftovers still surface
Reset-Run; $script:Failures.Add('VirtIO installer exit code 1603'); $script:Leftovers = @('x (error 5)'); Write-RunSummary
$sum = $script:LogLines -join "`n"
Check 'failure listed as ERROR'  ($sum -match '\[ERROR\]  - VirtIO installer exit code 1603')
Check 'leftovers ask for re-run' ($sum -match 'run the script again after the reboot')

# SetPrivateProfile (Windows networking cmdlets mocked)
& {
    $script:pcalls = New-Object System.Collections.Generic.List[string]
    $script:domain = $false
    function Get-CimInstance { param($ClassName) [pscustomobject]@{ PartOfDomain = $script:domain } }
    function Get-NetConnectionProfile { param($ErrorAction) [pscustomobject]@{ Name='Network 3'; InterfaceAlias='Ethernet'; InterfaceIndex=7; NetworkCategory='Public' }
                                        [pscustomobject]@{ Name='Mgmt'; InterfaceAlias='Ethernet 2'; InterfaceIndex=8; NetworkCategory='Private' } }
    function Set-NetConnectionProfile { param($InterfaceIndex, $NetworkCategory, $ErrorAction) $script:pcalls.Add("profile $InterfaceIndex $NetworkCategory") }
    function Get-NetFirewallRule { param($Name, $ErrorAction) [pscustomobject]@{ Name = $Name; Enabled = 'False' } }
    function Enable-NetFirewallRule { param($Name, $ErrorAction) $script:pcalls.Add("enable $Name") }

    $SetPrivateProfile = $false; Reset-Run; Set-PrivateProfile
    Check 'SetPrivateProfile off: nothing touched'          ($script:pcalls.Count -eq 0)
    $SetPrivateProfile = $true;  Reset-Run; Set-PrivateProfile
    Check 'workgroup: only the Public NIC moved to Private' ($script:pcalls -contains 'profile 7 Private' -and -not ($script:pcalls -contains 'profile 8 Private'))
    Check 'workgroup: WinRM rule enabled'                   ($script:pcalls -contains 'enable WINRM-HTTP-In-TCP')
    Check 'profile change shows in summary NIC lines'       ($script:Did.Nics -contains 'Ethernet: network profile Public -> Private')
    Check 'profile change does not force a reboot'          (-not $script:NeedsReboot)
    $script:pcalls.Clear(); $script:domain = $true; Reset-Run; Set-PrivateProfile
    Check 'domain-joined: profiles left alone'              ($script:pcalls.Count -eq 0 -and ($script:LogLines -match 'left to the domain'))
}

# Reboot decision in the main body is driven by NeedsReboot, and the runner's --wait-reboot keys on this text
$body = Get-Content $script -Raw
Check 'main body reboots only if NeedsReboot'         ($body -match '(?s)if \(\$script:NeedsReboot\) \{.*?Invoke-ScheduledReboot.*?\} else \{\s*Log ''Reboot not needed')
Check 'reboot log text unchanged for vme-guest-run'   ($body -match 'Reboot scheduled in \$RebootDelaySeconds seconds')

# ---------------- 1.3.0: Morpheus NIC map (by IP) and gateway probe; no pre-migration run in the guest
# Morpheus API shape seen on the real appliance: colon MACs, one ipAddress per interface
$script:PreMig = @()
$script:NicMap = @(
    [pscustomobject]@{ MacAddress='00:0c:29:cc:76:6d'; IPAddress='10.20.30.40'; Name='eth0'; Source="morpheus server 123 'app01'" }
    [pscustomobject]@{ MacAddress='00:0c:29:cc:76:77'; IPAddress='172.16.5.20'; Name='eth1'; Source="morpheus server 123 'app01'" }
)
Check 'map: IP -> MAC, normalised to dashes'   ((Find-NicMapMac '10.20.30.40') -eq '00-0C-29-CC-76-6D')
Check 'map: second NIC'                        ((Find-NicMapMac '172.16.5.20') -eq '00-0C-29-CC-76-77')
Check 'map: multi-IP ghost matches on any IP'  ((Find-NicMapMac '10.99.0.1,172.16.5.20') -eq '00-0C-29-CC-76-77')
Check 'map: unknown IP -> no MAC'              ($null -eq (Find-NicMapMac '192.168.9.9'))
Check 'map: empty/DHCP ghost -> no MAC'        ($null -eq (Find-NicMapMac ''))
$script:NicMap += [pscustomobject]@{ MacAddress='00:0c:29:00:00:01'; IPAddress='10.20.30.40' }
Check 'map: same IP on two MACs -> refuse'     ($null -eq (Find-NicMapMac '10.20.30.40'))
$script:NicMap = $script:NicMap[0..1]

# Two location-ID vmxnet3 ghosts (like the real VM), registry mocked, MACs come from the map
$fakeReg['HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}\0008'] = @{ NetCfgInstanceId = '{CCCC3333-0000-0000-0000-000000000003}' }
$fakeReg['HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\{CCCC3333-0000-0000-0000-000000000003}'] = @{ EnableDHCP = 0; IPAddress = [string[]]@('172.16.5.20'); SubnetMask = [string[]]@('255.255.255.0'); DefaultGateway = [string[]]@('172.16.5.1'); NameServer = '' }
$g1 = [pscustomobject]@{ InstanceId='PCI\VEN_15AD&DEV_07B0&SUBSYS_07B015AD&REV_01\3&218E0F40&0&08'; FriendlyName='vmxnet3 Ethernet Adapter';    Description=''; Manufacturer='VMware, Inc.'; Class='Net'; Driver='{4d36e972-e325-11ce-bfc1-08002be10318}\0007'; Present=$false }
$g2 = [pscustomobject]@{ InstanceId='PCI\VEN_15AD&DEV_07B0&SUBSYS_07B015AD&REV_01\3&218E0F40&0&10'; FriendlyName='vmxnet3 Ethernet Adapter #2'; Description=''; Manufacturer='VMware, Inc.'; Class='Net'; Driver='{4d36e972-e325-11ce-bfc1-08002be10318}\0008'; Present=$false }
$script:LogLines.Clear()
$mc = Save-GhostNicConfig @($g1, $g2) ''
Check 'ghost 1 MAC from Morpheus map'          ($mc[0].MacCandidates[0] -eq '00-0C-29-CC-76-6D')
Check 'ghost 2 MAC from Morpheus map'          ($mc[1].MacCandidates[0] -eq '00-0C-29-CC-76-77')
Check 'log names the source'                   (($script:LogLines -join "`n") -match 'from Morpheus NIC map')
$nA = [pscustomobject]@{ ifIndex=31; Name='Ethernet';   MacAddress='00-0C-29-CC-76-77'; InterfaceDescription='Red Hat VirtIO Ethernet Adapter';    Status='Up' }
$nB = [pscustomobject]@{ ifIndex=32; Name='Ethernet 2'; MacAddress='00-0C-29-CC-76-6D'; InterfaceDescription='Red Hat VirtIO Ethernet Adapter #2'; Status='Up' }
$rm = Resolve-NicMatches $mc @($nA, $nB)
Check 'both matched by MAC, crossed order handled' ((@($rm | Where-Object { $_.Method -eq 'MAC' }).Count -eq 2) -and
    ($rm | Where-Object { $_.Capture.IPAddress -eq '10.20.30.40' }).Adapter.ifIndex -eq 32 -and
    ($rm | Where-Object { $_.Capture.IPAddress -eq '172.16.5.20' }).Adapter.ifIndex -eq 31)

# Gateway probe: no map, two NICs, the old gateway only answers on the second one in slot order
$ProbeUnmatchedNics = $true   # CONFIG default in the script

# Regression: pre-migration capture with TWO NICs must give two records (1.1.0 folded them into one)
function Get-TargetAdapters { ,@(
    [pscustomobject]@{ Name='Ethernet0'; InterfaceDescription='vmxnet3 Ethernet Adapter';    MacAddress='00-50-56-9A-4B-21'; InterfaceGuid='{AAAA1111-0000-0000-0000-000000000001}'; ifIndex=7 }
    [pscustomobject]@{ Name='Ethernet1'; InterfaceDescription='vmxnet3 Ethernet Adapter #2'; MacAddress='00-50-56-9A-4B-22'; InterfaceGuid='{CCCC3333-0000-0000-0000-000000000003}'; ifIndex=8 }) }
$pre2 = Save-PreMigrationNics (Join-Path ([IO.Path]::GetTempPath()) 'pre2.json')
Check 'pre-migration, 2 NICs -> 2 records'          ($pre2.Count -eq 2)
Check 'pre-migration, each record has its own MAC'  ($pre2[0].MacAddress -eq '00-50-56-9A-4B-21' -and $pre2[1].MacAddress -eq '00-50-56-9A-4B-22')
Check 'pre-migration, each record has its own IP'   ($pre2[0].IPAddress -eq '10.20.30.40' -and $pre2[1].IPAddress -eq '172.16.5.20')
& {
    function Get-NetAdapterHardwareInfo { param($ErrorAction) [pscustomobject]@{ Name='Ethernet';   Bus=0; Device=3; Function=0 }
                                                             [pscustomobject]@{ Name='Ethernet 2'; Bus=0; Device=8; Function=0 } }
    Check 'slot order: device 3 before device 8' ((Get-AdaptersInSlotOrder @($nB, $nA))[0].Name -eq 'Ethernet')

    $script:tried = New-Object System.Collections.Generic.List[string]
    function Set-NicFromCapture($Capture, $Adapter, [switch]$Probe) {
        $script:tried.Add("$($Adapter.Name) probe=$([bool]$Probe)")
        if ($Probe -and $Adapter.Name -eq 'Ethernet') { return 'probe failed' }
        return 'applied'
    }
    $static = [pscustomobject]@{ Label='vmxnet3 Ethernet Adapter'; MacCandidates=@(); DHCP=$false; IPAddress='10.20.30.40'; SubnetMask='255.255.255.0'; Gateway='10.20.30.1'; DNS=''; Connection='Ethernet0' }
    $dhcp   = [pscustomobject]@{ Label='vmxnet3 Ethernet Adapter #2'; MacCandidates=@(); DHCP=$true; IPAddress=''; SubnetMask=''; Gateway=''; DNS=''; Connection='Ethernet1' }
    $script:Did.Nics = @(); $script:Failures.Clear()
    Invoke-NicRestore @($static, $dhcp) @($nB, $nA)
    Check 'probe tried slot 1 then slot 2'          (($script:tried -join ',') -eq 'Ethernet probe=True,Ethernet 2 probe=True')
    Check 'probe placed it on the answering NIC'    (($script:Did.Nics -join "`n") -match 'Ethernet 2: old static settings applied and verified \(10\.20\.30\.40\) - found by gateway probe')
    Check 'probe success is not a failure'          ($script:Failures.Count -eq 0)

    # switch off -> no probing at all
    $ProbeUnmatchedNics = $false; $script:tried.Clear(); $script:Failures.Clear()
    Invoke-NicRestore @($static, $dhcp) @($nB, $nA)
    Check 'ProbeUnmatchedNics off -> never probes'  ($script:tried.Count -eq 0 -and $script:Failures.Count -eq 1)
    $ProbeUnmatchedNics = $true

    # nobody answers -> reported, not guessed
    function Set-NicFromCapture($Capture, $Adapter, [switch]$Probe) { if ($Probe) { 'probe failed' } else { 'applied' } }
    $script:Did.Nics = @(); $script:Failures.Clear()
    Invoke-NicRestore @($static, $dhcp) @($nB, $nA)
    Check 'no answer -> failure, NOT applied'       ($script:Failures.Count -eq 1 -and ($script:Did.Nics -join "`n") -match 'no confident match, NOT applied')

    # no gateway in the old config -> never probe (nothing to verify against)
    $nogw = $static.PSObject.Copy(); $nogw.Gateway = ''
    $script:tried.Clear(); $script:Failures.Clear()
    function Set-NicFromCapture($Capture, $Adapter, [switch]$Probe) { $script:tried.Add('x'); 'applied' }
    Invoke-NicRestore @($nogw, $dhcp) @($nB, $nA)
    Check 'no gateway -> no probe, reported'        ($script:tried.Count -eq 0 -and $script:Failures.Count -eq 1)
}

# Probe mode inside the real Set-NicFromCapture: quiet revert, no failure, no rename
$script:addrState = 'Preferred'; $script:existing = @(); $script:dhcpState = 'Enabled'; $script:arpOk = $false
$calls.Clear(); $script:Failures.Clear()
$pr = Set-NicFromCapture $caps[0] $A1 -Probe
Check 'probe miss returns "probe failed"'       ($pr -eq 'probe failed')
Check 'probe miss reverts to DHCP'               ($calls -contains 'Set-NetIPInterface dhcp=Enabled')
Check 'probe miss is not recorded as a failure'  ($script:Failures.Count -eq 0)
Check 'probe miss does not rename'               (-not ($calls -match '^Rename'))
$script:arpOk = $true; $calls.Clear()
Check 'probe hit applies and renames'            ((Set-NicFromCapture $caps[0] $A1 -Probe) -eq 'applied' -and ($calls -match '^Rename'))


# ---------------------------------------------------------------- 1.4.0: scope, inventory, result.json
Check 'version is 1.4.0' ((Select-String -Path $script -Pattern "^\`$ScriptVersion = '1.4.0'").Count -eq 1)
Check 'default RemoveScope is ToolsOnly' ((Select-String -Path $script -Pattern "^\`$RemoveScope\s+= 'ToolsOnly'").Count -eq 1)

# product classification
Check 'Tools classified as tools'          ((Get-ProductClass 'VMware Tools' 'VMware, Inc.') -eq 'tools')
Check 'Horizon agent classified as other'  ((Get-ProductClass 'VMware Horizon Agent' 'VMware, Inc.') -eq 'other')
Check 'Omnissa agent classified as other'  ((Get-ProductClass 'Omnissa Horizon Agent' 'Omnissa, LLC') -eq 'other')
Check 'Carbon Black is protected'          ((Get-ProductClass 'Carbon Black Cloud Sensor 64-bit' 'Broadcom Inc.') -eq 'protected')
Check 'Cb Defense is protected'            ((Get-ProductClass 'Cb Defense Sensor 64-bit' 'Carbon Black, Inc.') -eq 'protected')

# inventory only picks vendor software, deduplicated
& {
    function Get-UninstallEntries([string]$Pattern) {
        @([pscustomobject]@{ DisplayName = 'VMware Tools'; DisplayVersion = '12.4.0'; Publisher = 'VMware, Inc.'; PSChildName = '{11111111-1111-1111-1111-111111111111}'; QuietUninstallString = ''; InstallLocation = '' },
          [pscustomobject]@{ DisplayName = 'VMware Horizon Agent'; DisplayVersion = '8.12'; Publisher = 'VMware, Inc.'; PSChildName = '{22222222-2222-2222-2222-222222222222}'; QuietUninstallString = ''; InstallLocation = '' },
          [pscustomobject]@{ DisplayName = 'Carbon Black Cloud Sensor 64-bit'; DisplayVersion = '4.0'; Publisher = 'Broadcom Inc.'; PSChildName = '{33333333-3333-3333-3333-333333333333}'; QuietUninstallString = ''; InstallLocation = '' },
          [pscustomobject]@{ DisplayName = 'Notepad++'; DisplayVersion = '8'; Publisher = 'Notepad++ Team'; PSChildName = 'Notepad++'; QuietUninstallString = ''; InstallLocation = '' },
          [pscustomobject]@{ DisplayName = 'VMware Tools'; DisplayVersion = '12.4.0'; Publisher = 'VMware, Inc.'; PSChildName = '{11111111-1111-1111-1111-111111111111}'; QuietUninstallString = ''; InstallLocation = '' })
    }
    $inv = @(Get-VendorInventory)
    Check 'inventory finds 3 vendor products, skips others' ($inv.Count -eq 3)
    Check 'inventory classes' ((@($inv | Where-Object Class -eq 'tools').Count -eq 1) -and (@($inv | Where-Object Class -eq 'protected').Count -eq 1) -and (@($inv | Where-Object Class -eq 'other').Count -eq 1))
}

# Tools-owned file test
$script:ToolsFileNames = @('vmci', 'vsock', 'vmtoolsd', 'vmxnet3ndis6')
Check 'tools tree path is tools-owned'   (Test-ToolsOwned 'C:\Program Files\VMware\VMware Tools\vmtoolsd.exe')
Check 'tools driver name is tools-owned' (Test-ToolsOwned 'C:\Windows\System32\drivers\vmci.sys')
Check 'Horizon binary is not tools-owned' (-not (Test-ToolsOwned 'C:\Program Files\VMware\VMware View\Agent\bin\wsnm.exe'))
Check 'Horizon driver is not tools-owned' (-not (Test-ToolsOwned 'C:\Windows\System32\drivers\vmwvaudio.sys'))

# run-config.json overrides
& {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) "rc-$([guid]::NewGuid()).json"
    '{"Mode":"Inventory","RemoveScope":"Selected","RemoveProducts":["{22222222-2222-2222-2222-222222222222}"],"RebootWhenDone":false}' | Set-Content $tmp
    $script:Mode = 'Run'; $script:RemoveScope = 'ToolsOnly'; $script:RemoveProducts = @(); $script:RebootWhenDone = $true
    $null = Import-RunConfig $tmp
    Check 'run-config sets Mode'            ($script:Mode -eq 'Inventory')
    Check 'run-config sets RemoveScope'     ($script:RemoveScope -eq 'Selected')
    Check 'run-config sets RemoveProducts'  (@($script:RemoveProducts).Count -eq 1)
    Check 'run-config sets RebootWhenDone'  ($script:RebootWhenDone -eq $false)
    Remove-Item $tmp -Force
    Check 'missing run-config is ignored'   ($null -eq (Import-RunConfig 'C:\nope\run-config.json'))
    $script:Mode = 'Run'; $script:RemoveScope = 'ToolsOnly'; $script:RebootWhenDone = $true
}

# result.json
& {
    $script:ResultFile = Join-Path ([IO.Path]::GetTempPath()) "res-$([guid]::NewGuid()).json"
    $script:Failures = New-Object System.Collections.Generic.List[string]; $script:Failures.Add('x')
    $ScriptVersion = '1.4.0'; $Mode = 'Run'; $RemoveScope = 'ToolsOnly'; $LogFile = 'C:\log'
    Write-Result 'attention' @{ vmwareToolsRemoved = $true; nics = @('Ethernet0 -> Ethernet 2') }
    $r = Get-Content $script:ResultFile -Raw | ConvertFrom-Json
    Check 'result.json written with status/version/failures' ($r.status -eq 'attention' -and $r.version -eq '1.4.0' -and @($r.failures).Count -eq 1 -and $r.vmwareToolsRemoved -eq $true)
    Remove-Item $script:ResultFile -Force
}

# the whole-tree / whole-key / everything-VMware sweeps only run under AllVMware
$txt = Get-Content $script -Raw
Check 'whole VMware, Inc. key only under AllVMware' ($txt -match "if \(\`$RemoveScope -eq 'AllVMware'\) \{ Remove-RegKey \`$base; continue \}")
Check 'whole Program Files\VMware tree only under AllVMware' ($txt.Contains('if ($RemoveScope -ne ''AllVMware'') {' + [Environment]::NewLine + '    $folders = @("$env:ProgramFiles\VMware\VMware Tools"') -or $txt.Contains("if (`$RemoveScope -ne 'AllVMware') {`n    `$folders = @(`"`$env:ProgramFiles\VMware\VMware Tools`""))
Check 'driver store limited to Tools INFs outside AllVMware' ($txt -match '\$vmwDrivers = @\(\$vmwDrivers \| Where-Object \{ \[IO.Path\]::GetFileName\(\$_.OriginalFileName\) -match \$toolsInfPattern \}\)')
Check 'services by name/publisher need Tools ownership outside AllVMware' ($txt -match "elseif \(Test-ToolsOwned \`$img\)")
Check 'phase 2 removal is gated on phase 1' (($txt -match 'if \(-not \$script:SkipRemoval\) \{') -and ($txt -match '\$script:SkipRemoval = \$SkipRemovalIfVirtioFailed -and'))
Check 'stale connection name freed before rename' ($txt -match 'Clear-StaleConnectionName \$Capture.Connection [^\r\n]+\r?\n\s+try\s+\{ Rename-NetAdapter')
Check 'uploaded installer in work folder is used first' ($txt -match "Using VirtIO installer already in")
Check 'protected products are never uninstalled' ($txt -match "if \(\`$pr.Class -eq 'protected'\) \{ Log `"Not uninstalling")
Check 'publisher match includes Broadcom' ((Select-String -Path $script -Pattern "-match 'VMware\|Broadcom'").Count -ge 3)

"`n$pass passed, $fail failed"
if ($fail) { exit 1 }
