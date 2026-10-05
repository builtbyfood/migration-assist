<#
.SYNOPSIS
    Post-migration cleanup for Windows guests moved from VMware to KVM (HPE Morpheus VM Essentials / HVM):
    completes the VirtIO install, removes VMware Tools, and puts the old static IPs back on the virtio NICs.

.DESCRIPTION
    Built for VMs where the migration injected only the basic boot/network virtio drivers.

    Phase 0  Pre-flight
               - relaunches in 64-bit PowerShell if started 32-bit (from file, -Command or a hosted runspace)
               - requires elevation and FullLanguage mode (fails fast under AppLocker/WDAC constrained mode)
               - requires 2012 R2 / 8.1 or newer (PowerShell 4+, DISM module)
               - on VMware hardware: pre-migration capture only (each NIC's interface GUID, MAC and IPv4
                 settings to nic-premigration.json), then exit 0. Run the same task before and after migration.
                 With $SetPrivateProfile it also moves Public NICs to Private there (workgroup VMs only).

    Phase 1  VirtIO check / install
               - inventory: guest tools product, Red Hat driver packages, viostor/vioscsi/netkvm services
                 (and whether they're staged), virtio/QEMU devices with no driver, QEMU-GA/balloon/SPICE services
               - $VirtioCheckOnly: also lists ghost devices, the old NIC settings and the planned NIC matches,
                 then exits without changing anything (exit 1 if gaps or VMware Tools remain)
               - if the last run hasn't been followed by a reboot yet: schedule the reboot and exit
               - installs the full suite only when something is missing (/repair if the same version is registered)
               - pre-trusts the Red Hat driver publisher (2012 R2/2016) so no "trust this publisher?" prompt
                 can stall the silent install in session 0; tolerates an unverifiable chain on an intact,
                 Red Hat-signed installer (offline boxes), still refuses unsigned or altered files
               - inventories again and logs added/updated packages and anything still missing

    Phase 2  VMware Tools removal (aligned with Broadcom KB 315629, plus what it leaves behind)
               2a  MSI uninstall attempt (usually 1603 off VMware; the sweep below does the real work)
               2b  network snapshot: Tcpip interfaces .reg export and ipconfig /all
               2c  ghost devices: capture each ghost NIC's IPv4 settings, connection name and decoded vmxnet3 MAC
                   (log, text report, nic-capture.json), then remove ghost VMware devices and stale PCI NICs.
                   The MAC comes from nic-premigration.json by interface GUID; decoding the device ID is a fallback.
               2d  VMware services and kernel drivers (known names, display name, or VMware-signed binary)
               2e  vmmouse etc. out of class Upper/LowerFilters; vmhgfs out of the NetworkProvider order
               2f  VMware packages out of the driver store
               2g  files: VMware drivers in System32/SysWOW64, Program Files (both), Common Files (both),
                   ProgramData, every profile's AppData\Local|Roaming\VMware (locked files deleted at reboot)
               2h  registry: VMware, Inc. keys, Uninstall entries, Windows Installer product registration, Run keys
               2i  verify nothing VMware Tools-related is still registered

    Phase 3  Restore NIC settings ($ApplyNicConfig)
               - captures from 2c, or nic-capture.json from an earlier run if the ghosts are already gone
               - MAC for each ghost NIC, first source that answers: pre-migration capture (optional, by GUID),
                 Morpheus NIC map (nic-map.json, by IP), device-ID decode
               - match old NIC -> virtio NIC by that preserved MAC, else 1:1 when exactly one of each is left,
                 else gateway probe ($ProbeUnmatchedNics): try the static config on each free NIC in PCI slot
                 order, keep it on the one whose old gateway answers ARP, revert the others;
                 anything else is reported, never guessed
               - apply IPs/masks, default gateway(s), DNS and suffix, then rename to the old connection name
               - verify: address passes duplicate detection and the gateway answers ARP, otherwise revert that NIC
                 to DHCP ($RollbackIfUnreachable) so the agent can still reach Morpheus
               - skips NICs that already have the address, already have a different static IP, or were DHCP

               - $SetPrivateProfile (off by default): on workgroup VMs move Public NICs to Private and enable
                 the WinRM firewall rule, so Morpheus can reach the VM over WinRM afterwards

    Phase 4  Wrap-up
               - summary of what was actually done: VirtIO, VMware Tools items removed (with counts), each NIC
               - reboots only if something needing it changed (drivers installed, services/filters/packages
                 removed, files queued for boot); on an already-clean VM it says so and does not reboot
               - records the run so a re-run before that reboot doesn't repeat the work

.NOTES
    Version       : 1.3.0 (2026-10-04)
    Changelog     : 1.3.0  no per-VM pre-migration run needed: ghost NICs are joined to their MAC through
                           nic-map.json (built by vme-guest-run.py from the source VM's Morpheus record, matched
                           by IP); gateway-probe fallback places unmatched multi-NIC static configs on the NIC
                           whose network answers the old gateway; fixes the 1.1.0 pre-migration capture on
                           multi-NIC VMs (all NICs were folded into one record)
                    1.2.0  reboots only when the run changed something that needs it (no reboot on an already-clean
                           VM); summary reports what was actually done per area with counts; optional
                           SetPrivateProfile for workgroup VMs (pre-migration on VMware and post-migration)
                    1.1.0  on VMware hardware the script now does a pre-migration NIC capture (GUID -> MAC + IPv4)
                           instead of refusing; post-migration it maps each ghost NIC to its exact MAC through
                           that capture. Device-ID MAC decoding is now a fallback: a real migrated vmxnet3 had a
                           location-based ID with no MAC in it.
                    1.0.1  never deletes non-VMware files under the Windows directory (1.0.0 queued dllhost.exe,
                           which hosts VMware's snapshot provider service); takes ownership of TrustedInstaller-owned
                           VMware driver files so they can be removed; logs Win32 error codes for failed deletes;
                           summary says when a second pass is needed; ghost NIC report includes the device ID
                    1.0.0  first tagged release: VirtIO check/install, VMware Tools removal (KB 315629+),
                           ghost NIC capture with vmxnet3 MAC decode, NIC restore with verify/rollback,
                           headless hardening for the Morpheus agent
    Morpheus task : Type "PowerShell Script", Execute Target "Resource", run elevated. The VM it runs on is
                    the one the task is executed against (instance Actions > Run Task, task Execute, workflow, API).
    Access        : SYSTEM via the Morpheus agent, or local admin over WinRM. Over WinRM the session drops when
                    Phase 3 changes the IP; the work still finishes, so check the log rather than the task status.
    Output        : C:\ProgramData\VMwareToVirtio\
                      run-<stamp>.log                  full log
                      ghost-nic-config-<stamp>.txt     old NIC settings, human readable
                      nic-capture.json                 old NIC settings, used by re-runs
                      nic-premigration.json            optional, written on VMware: interface GUID -> MAC + IPv4
                      nic-map.json                     dropped in by vme-guest-run.py: MAC -> IP from Morpheus
                      tcpip-interfaces-<stamp>.reg     raw backup of all interface settings
                      ipconfig-<stamp>.txt             ipconfig /all before any change
                      virtio-install-<stamp>.log / vmtools-msi-uninstall-<stamp>.log
    Exit codes    : 0 = done (reboot scheduled or required); 1 = something needs attention, see the log.
    Re-runs       : safe; completed steps are skipped and a run before the pending reboot just reschedules it.
    Headless      : never prompts ($ConfirmPreference = None, unattended switches on every installer/tool);
                    logging falls back to the console stream if the agent's host has no UI; the log file
                    is always written. No proxy is configured for SYSTEM, so attach the virtio ISO or set
                    $VirtioSource on VMs without direct internet.
    Templating    : keep Morpheus template markers out of this file except in the CONFIG block.
    Tests         : Test-VMwareToVirtio.ps1 (offline, mocks registry and NetTCPIP).
#>

$ScriptVersion = '1.4.0'
$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'
$ConfirmPreference     = 'None'       # headless: no cmdlet may stop to ask for confirmation

# ============================== CONFIG ==============================
# '' = auto: use a mounted virtio-win ISO if one is attached, otherwise download $VirtioUrl.
# Or set a local path / UNC path (file or folder) / http(s) URL to virtio-win-guest-tools.exe.
$VirtioSource          = ''
$VirtioUrl             = 'https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win-guest-tools.exe'
$VirtioCheckOnly       = $false      # report VirtIO / VMware Tools state and exit without changing anything
$ForceVirtioInstall    = $false      # run the guest tools installer even if the full suite already looks complete
$RemoveGhostDevices    = $true       # remove non-present VMware devices and non-present PCI NICs
$RebootWhenDone        = $true
$RebootDelaySeconds    = 60
$SetPrivateProfile     = $false      # workgroup VMs: Public NICs -> Private + WinRM rule on (for Morpheus WinRM access)
$Force                 = $false      # on VMware hardware, run the full cleanup instead of the pre-migration capture
$IgnorePendingReboot   = $false      # re-run the full cleanup even if the last run hasn't been followed by a reboot yet
$ApplyNicConfig        = $true       # put the old static IPv4 settings onto the matching virtio NIC
$ProbeUnmatchedNics    = $true       # multi-NIC with no MAC match: find the NIC whose network answers the old gateway
$RollbackIfUnreachable = $true       # revert that NIC to DHCP if the address is a duplicate or the gateway doesn't answer
$Mode                  = 'Run'       # Run | Inventory (report VMware/Broadcom/Omnissa software to result.json and exit)
$RemoveScope           = 'ToolsOnly' # ToolsOnly | Selected | AllVMware
                                     #   ToolsOnly: VMware Tools and its own drivers/services/files only; any other
                                     #              VMware/Broadcom product is reported and left in place
                                     #   Selected : ToolsOnly, plus uninstall the products listed in $RemoveProducts
                                     #   AllVMware: the 1.3.0 behaviour (everything VMware-published; KB 315629 whole-tree sweep)
$RemoveProducts        = @()         # uninstall entry names or product codes, for RemoveScope = Selected
$SkipRemovalIfVirtioFailed = $true   # do not touch VMware Tools when Phase 1 could not complete the VirtIO set
# Settings above can be overridden by run-config.json in the work folder (written by Migration Assist), e.g.
#   {"Mode":"Inventory"}   {"RemoveScope":"Selected","RemoveProducts":["{GUID}","VMware Horizon Agent"]}
# ====================================================================

$WorkDir = Join-Path $env:ProgramData 'VMwareToVirtio'
New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
$Stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$LogFile = Join-Path $WorkDir "run-$Stamp.log"
$ResultFile = Join-Path $WorkDir 'result.json'
$script:Failures = New-Object System.Collections.Generic.List[string]
$script:Leftovers = @()
# What this run actually did. Drives the summary and whether a reboot is needed.
$script:Did = @{ VirtIO = 'not checked'; Ghosts = 0; Services = 0; Packages = 0; Files = 0; RegKeys = 0; Filters = 0; Nics = @() }
$script:NeedsReboot = $false
function Mark([string]$What, [int]$Count = 1, [switch]$Reboot) {
    if ($What) { $script:Did[$What] += $Count }
    if ($Reboot) { $script:NeedsReboot = $true }
}

function Log([string]$Message, [string]$Level = 'INFO') {
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    # Write-Host reaches stdout under powershell.exe; fall back to the console stream if the agent's host has no UI.
    try { Write-Host $line } catch { try { [Console]::Out.WriteLine($line) } catch { } }
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
}
function Fail([string]$Message) { Log $Message 'ERROR'; $script:Failures.Add($Message) }

# ---------------------------------------------------------------- native helpers
if (-not ('VmwToVirtio.Native' -as [type])) {
# Plain SetupAPI / cfgmgr32 calls (C# 5, no PnpDevice module), so this works the same on 2008 R2 through 2025.
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
namespace VmwToVirtio {
    public class DeviceEntry {
        public string InstanceId;
        public string FriendlyName;
        public string Description;
        public string Manufacturer;
        public string Class;
        public string Driver;
        public bool Present;
    }

    public static class Native {
        [StructLayout(LayoutKind.Sequential)]
        public struct SP_DEVINFO_DATA { public uint cbSize; public Guid ClassGuid; public uint DevInst; public IntPtr Reserved; }

        const int DIGCF_ALLCLASSES = 0x4;
        const uint SPDRP_DEVICEDESC = 0x0, SPDRP_CLASS = 0x7, SPDRP_DRIVER = 0x9, SPDRP_MFG = 0xB, SPDRP_FRIENDLYNAME = 0xC;

        [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "SetupDiGetClassDevsW")]
        static extern IntPtr SetupDiGetClassDevs(IntPtr classGuid, string enumerator, IntPtr hwnd, int flags);
        [DllImport("setupapi.dll", SetLastError = true)]
        static extern bool SetupDiEnumDeviceInfo(IntPtr set, uint index, ref SP_DEVINFO_DATA data);
        [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "SetupDiGetDeviceInstanceIdW")]
        static extern bool SetupDiGetDeviceInstanceId(IntPtr set, ref SP_DEVINFO_DATA data, StringBuilder id, int size, out int required);
        [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "SetupDiGetDeviceRegistryPropertyW")]
        static extern bool SetupDiGetDeviceRegistryProperty(IntPtr set, ref SP_DEVINFO_DATA data, uint property, out uint regType, byte[] buffer, uint size, out uint required);
        [DllImport("setupapi.dll", SetLastError = true)]
        static extern IntPtr SetupDiCreateDeviceInfoList(IntPtr classGuid, IntPtr hwndParent);
        [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "SetupDiOpenDeviceInfoW")]
        static extern bool SetupDiOpenDeviceInfo(IntPtr set, string instanceId, IntPtr hwnd, uint flags, ref SP_DEVINFO_DATA data);
        [DllImport("setupapi.dll", SetLastError = true)]
        static extern bool SetupDiRemoveDevice(IntPtr set, ref SP_DEVINFO_DATA data);
        [DllImport("setupapi.dll", SetLastError = true)]
        static extern bool SetupDiDestroyDeviceInfoList(IntPtr set);
        [DllImport("cfgmgr32.dll")]
        static extern int CM_Get_DevNode_Status(out uint status, out uint problem, uint devInst, int flags);
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "MoveFileExW")]
        static extern bool MoveFileEx(string existing, string newName, int flags);

        static bool IsInvalid(IntPtr h) { return h == IntPtr.Zero || h.ToInt64() == -1; }

        static string Prop(IntPtr set, ref SP_DEVINFO_DATA d, uint property) {
            uint regType, required;
            byte[] buf = new byte[4096];
            if (!SetupDiGetDeviceRegistryProperty(set, ref d, property, out regType, buf, (uint)buf.Length, out required)) return null;
            string s = Encoding.Unicode.GetString(buf, 0, (int)Math.Min(required, (uint)buf.Length)).TrimEnd('\0');
            // Unresolved resource form "@oem12.inf,%vmware%;VMware, Inc." -> "VMware, Inc."
            if (s.StartsWith("@") && s.IndexOf(';') >= 0) s = s.Substring(s.LastIndexOf(';') + 1);
            return s;
        }

        // Every device Windows knows about, present or not (what Device Manager shows with "show hidden devices").
        public static DeviceEntry[] ListDevices() {
            List<DeviceEntry> list = new List<DeviceEntry>();
            IntPtr set = SetupDiGetClassDevs(IntPtr.Zero, null, IntPtr.Zero, DIGCF_ALLCLASSES);
            if (IsInvalid(set)) return list.ToArray();
            try {
                SP_DEVINFO_DATA d = new SP_DEVINFO_DATA();
                d.cbSize = (uint)Marshal.SizeOf(typeof(SP_DEVINFO_DATA));
                for (uint i = 0; SetupDiEnumDeviceInfo(set, i, ref d); i++) {
                    StringBuilder sb = new StringBuilder(1024);
                    int required;
                    if (!SetupDiGetDeviceInstanceId(set, ref d, sb, sb.Capacity, out required)) continue;
                    uint status, problem;
                    DeviceEntry e = new DeviceEntry();
                    e.InstanceId   = sb.ToString();
                    e.FriendlyName = Prop(set, ref d, SPDRP_FRIENDLYNAME);
                    e.Description  = Prop(set, ref d, SPDRP_DEVICEDESC);
                    e.Manufacturer = Prop(set, ref d, SPDRP_MFG);
                    e.Class        = Prop(set, ref d, SPDRP_CLASS);
                    e.Driver       = Prop(set, ref d, SPDRP_DRIVER);
                    // A non-present (ghost) devnode has no live status: CR_NO_SUCH_DEVINST
                    e.Present      = CM_Get_DevNode_Status(out status, out problem, d.DevInst, 0) == 0;
                    list.Add(e);
                }
            } finally { SetupDiDestroyDeviceInfoList(set); }
            return list.ToArray();
        }

        public static bool RemoveDevice(string instanceId) {
            IntPtr set = SetupDiCreateDeviceInfoList(IntPtr.Zero, IntPtr.Zero);
            if (IsInvalid(set)) return false;
            try {
                SP_DEVINFO_DATA d = new SP_DEVINFO_DATA();
                d.cbSize = (uint)Marshal.SizeOf(typeof(SP_DEVINFO_DATA));
                if (!SetupDiOpenDeviceInfo(set, instanceId, IntPtr.Zero, 0, ref d)) return false;
                return SetupDiRemoveDevice(set, ref d);
            } finally { SetupDiDestroyDeviceInfoList(set); }
        }

        // MOVEFILE_DELAY_UNTIL_REBOOT with a null target = delete at next boot.
        // Returns 0 on success, otherwise the Win32 error code.
        public static int DeleteAtReboot(string path) { return MoveFileEx(path, null, 4) ? 0 : Marshal.GetLastWin32Error(); }
    }
}
'@
}

# ---------------------------------------------------------------- helpers
function Get-UninstallEntries([string]$Pattern) {
    $roots = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
             'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    foreach ($r in $roots) {
        if (-not (Test-Path $r)) { continue }
        foreach ($k in Get-ChildItem $r -ErrorAction SilentlyContinue) {
            $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
            if ($p.DisplayName -like $Pattern) { $p }
        }
    }
}

function Remove-RegKey([string]$Path) {
    if (Test-Path -LiteralPath $Path) {
        try   { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop; Log "Removed registry key $Path"; Mark 'RegKeys' }
        catch { Log "Could not remove $Path : $($_.Exception.Message)" 'WARN' }
    }
}

# Safety rule: inside the Windows directory only VMware-published files may be deleted, never folders.
# (1.0.0 queued dllhost.exe because VMware's snapshot provider service runs inside it.)
function Test-SafeToDelete([string]$Path) {
    $win = $env:SystemRoot.TrimEnd('\') + '\'
    if (-not $Path.StartsWith($win, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    if (Test-Path -LiteralPath $Path -PathType Container) { return $false }
    return ((Get-CompanyName $Path) -match 'VMware')
}

function Remove-PathOrSchedule([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    if (-not (Test-SafeToDelete $Path)) { Log "Refusing to delete $Path (not a VMware file)" 'WARN'; return }
    try { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop; Log "Deleted $Path"; Mark 'Files'; return } catch { }

    # VMware driver files under System32 are often owned by TrustedInstaller, so even an admin can't delete them.
    # They passed the VMware-publisher check above, so take ownership of just that file and try again.
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        & takeown.exe /f $Path /a 2>&1 | Out-Null
        & icacls.exe $Path /grant '*S-1-5-32-544:F' 2>&1 | Out-Null
        try { Remove-Item -LiteralPath $Path -Force -ErrorAction Stop; Log "Deleted $Path (after taking ownership)"; Mark 'Files'; return } catch { }
    }

    $left = @()
    if (Test-Path -LiteralPath $Path -PathType Container) {
        $left += Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue | ForEach-Object FullName
        $left += Get-ChildItem -LiteralPath $Path -Recurse -Force -Directory -ErrorAction SilentlyContinue |
                 Sort-Object { $_.FullName.Length } -Descending | ForEach-Object FullName
    }
    $left += $Path
    $errors = @()
    foreach ($f in $left) { $rc = [VmwToVirtio.Native]::DeleteAtReboot($f); if ($rc) { $errors += "$f (error $rc)" } }
    if ($errors.Count -lt $left.Count) {
        Log "In use, scheduled $($left.Count - $errors.Count) item(s) for delete at reboot: $Path" 'WARN'
        Mark 'Files' -Reboot
    }
    foreach ($e in $errors) { Log "  Could not delete or schedule: $e" 'WARN'; $script:Leftovers += $e }
}

function Resolve-ImagePath([string]$ImagePath) {
    if (-not $ImagePath) { return $null }
    $p = [Environment]::ExpandEnvironmentVariables($ImagePath.Trim())
    if ($p.StartsWith('"')) { $p = $p.Substring(1, $p.IndexOf('"', 1) - 1) }
    elseif ($p -match '^(.+?\.(exe|sys|dll))(\s|$)') { $p = $Matches[1] }
    $p = $p -replace '^\\\?\?\\', ''
    $p = $p -replace '^\\SystemRoot\\', ($env:SystemRoot + '\')
    if ($p -match '^system32\\') { $p = $env:SystemRoot + '\' + $p }
    return $p
}

function Get-CompanyName([string]$File) {
    try { if ($File -and (Test-Path -LiteralPath $File -PathType Leaf)) { return (Get-Item -LiteralPath $File).VersionInfo.CompanyName } } catch { }
    return $null
}

function ConvertTo-SquashedGuid([string]$Guid) {
    $h = $Guid.Trim('{}').Replace('-', '').ToUpper()
    if ($h.Length -ne 32) { return $null }
    $r  = -join ($h.Substring(0, 8).ToCharArray()[7..0])
    $r += -join ($h.Substring(8, 4).ToCharArray()[3..0])
    $r += -join ($h.Substring(12, 4).ToCharArray()[3..0])
    for ($i = 16; $i -lt 32; $i += 2) { $r += $h[$i + 1]; $r += $h[$i] }
    return $r
}

function Get-NicTcpip([string]$DriverKey) {
    if (-not $DriverKey) { return $null }
    $cfg = (Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Control\Class\$DriverKey" -Name NetCfgInstanceId -ErrorAction SilentlyContinue).NetCfgInstanceId
    return (Get-TcpipByGuid $cfg)
}

function Get-TcpipByGuid([string]$cfg) {
    if (-not $cfg) { return $null }
    $t = Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$cfg" -ErrorAction SilentlyContinue
    if (-not $t) { return $null }
    $conn = (Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Control\Network\{4D36E972-E325-11CE-BFC1-08002BE10318}\$cfg\Connection" -Name Name -ErrorAction SilentlyContinue).Name
    [pscustomobject]@{
        Connection    = $conn
        InterfaceGuid = $cfg
        DHCP          = [bool]$t.EnableDHCP
        IPAddress     = ($t.IPAddress -join ',')
        SubnetMask    = ($t.SubnetMask -join ',')
        Gateway       = ($t.DefaultGateway -join ',')
        DNS           = $t.NameServer
        Domain        = $t.Domain
    }
}

function Get-DeviceLabel($Device) {
    if ($Device.FriendlyName) { return $Device.FriendlyName }
    if ($Device.Description)  { return $Device.Description }
    return $Device.InstanceId
}

# Non-present VMware devices plus any non-present PCI NIC (old vmxnet3 / e1000 left behind by the migration)
function Select-GhostDevices($Devices) {
    return ,@($Devices | Where-Object {
        -not $_.Present -and (
            $_.Manufacturer -match 'VMware' -or
            "$($_.FriendlyName) $($_.Description)" -match 'VMware|vmxnet' -or
            $_.InstanceId -match 'VEN_15AD' -or
            ($_.Class -eq 'Net' -and $_.InstanceId -like 'PCI\*'))
    })
}

function Get-GhostDevices {
    $all = @([VmwToVirtio.Native]::ListDevices())
    if (-not $all.Count) { Log 'Device enumeration returned nothing (SetupAPI failure?)' 'WARN' }
    return (Select-GhostDevices $all)
}

# Logs (and optionally saves) the IPv4 settings still attached to ghost NICs. Returns the captured settings.
function Save-GhostNicConfig($Ghosts, [string]$Path) {
    $captures = @()
    foreach ($g in @($Ghosts | Where-Object { $_.Class -eq 'Net' })) {
        $cfg = Get-NicTcpip $g.Driver
        if (-not $cfg) { Log "Ghost NIC '$(Get-DeviceLabel $g)': no TCP/IP settings left in the registry" 'WARN'; continue }
        $macs = @(); $macSource = ''
        $pm = @($script:PreMig | Where-Object { $_.InterfaceGuid -eq $cfg.InterfaceGuid }) | Select-Object -First 1
        if ($pm -and $pm.MacAddress) { $macs = @("$($pm.MacAddress)"); $macSource = ' from pre-migration capture' }
        if (-not $macs.Count) {
            $mapMac = Find-NicMapMac $cfg.IPAddress
            if ($mapMac) { $macs = @($mapMac); $macSource = ' from Morpheus NIC map' }
        }
        if (-not $macs.Count) { $macs = Get-MacFromInstanceId $g.InstanceId; if ($macs.Count) { $macSource = ' decoded from device ID' } }
        $line = "Ghost NIC '{0}' (connection '{1}', MAC {2}): DHCP={3} IP={4} Mask={5} GW={6} DNS={7} [{8}]" -f `
                (Get-DeviceLabel $g), $cfg.Connection, $(if ($macs.Count) { ($macs -join ' or ') + $macSource } else { 'unknown - no pre-migration capture' }),
                $cfg.DHCP, $cfg.IPAddress, $cfg.SubnetMask, $cfg.Gateway, $cfg.DNS, $g.InstanceId
        Log $line
        if ($Path) { Add-Content -Path $Path -Value $line }
        $captures += [pscustomobject]@{
            Label = Get-DeviceLabel $g; InstanceId = $g.InstanceId; MacCandidates = $macs
            Connection = $cfg.Connection; DHCP = $cfg.DHCP; IPAddress = $cfg.IPAddress; SubnetMask = $cfg.SubnetMask
            Gateway = $cfg.Gateway; DNS = $cfg.DNS; Domain = $cfg.Domain
        }
    }
    if (-not $captures.Count) { Log 'No ghost NICs with saved TCP/IP settings found' }
    return ,$captures
}

# Fallback only. Some vmxnet3 instance IDs end in a PCI Device Serial Number built from the MAC in EUI-64 form;
# others are location-based (e.g. ...\3&218E0F40&0&08, seen on a real migrated VM) and carry no MAC at all.
# The pre-migration capture is the reliable source. For serial-number IDs,
# e.g. ...\FF565000F8D2C7FE00 -> bytes 00 50 56 FF FE .. .. ..  Both byte orders of the NIC-specific half
# are returned; the caller only accepts a match that hits exactly one present adapter.
function Get-MacFromInstanceId([string]$InstanceId) {
    $tail = ($InstanceId -split '\\')[-1]
    if ($tail -notmatch '^([0-9A-Fa-f]{8})([0-9A-Fa-f]{8})00$') { return ,@() }
    $b = @()
    foreach ($dw in $Matches[1].ToUpper(), $Matches[2].ToUpper()) { for ($i = 6; $i -ge 0; $i -= 2) { $b += $dw.Substring($i, 2) } }
    if ($b[3] -ne 'FF' -or $b[4] -ne 'FE') { return ,@() }
    return ,@(@((($b[0..2] + $b[5..7]) -join '-'), (($b[0..2] + $b[7..5]) -join '-')) | Select-Object -Unique)
}

# nic-map.json (written into the guest by vme-guest-run.py from the source VM's Morpheus record):
# [{"MacAddress":"00:0c:29:cc:76:6d","IPAddress":"10.20.30.40", ...}]. Joins a ghost NIC to its MAC by IP.
# Returns the MAC only when exactly one map entry carries one of the ghost's IPs.
function Find-NicMapMac([string]$IpList) {
    $ips = @("$IpList" -split '[,\s]+' | Where-Object { $_ -and $_ -ne '0.0.0.0' })
    if (-not $ips.Count) { return $null }
    $hits = @()
    foreach ($e in @($script:NicMap)) {
        $eips = @("$($e.IPAddress)" -split '[,\s]+' | Where-Object { $_ })
        if (@($eips | Where-Object { $ips -contains $_ }).Count -and $e.MacAddress) { $hits += (ConvertTo-NormalMac "$($e.MacAddress)") }
    }
    $hits = @($hits | Select-Object -Unique)
    if ($hits.Count -eq 1) {
        $h = $hits[0]
        return ('{0}-{1}-{2}-{3}-{4}-{5}' -f $h.Substring(0,2), $h.Substring(2,2), $h.Substring(4,2), $h.Substring(6,2), $h.Substring(8,2), $h.Substring(10,2))
    }
    return $null
}

# Present adapters in PCI bus/device/function order (the order the gateway probe tries them in)
function Get-AdaptersInSlotOrder($Adapters) {
    $hw = @{}
    if (Get-Command Get-NetAdapterHardwareInfo -ErrorAction SilentlyContinue) {
        foreach ($h in @(Get-NetAdapterHardwareInfo -ErrorAction SilentlyContinue)) {
            $hw["$($h.Name)"] = '{0:D4}{1:D4}{2:D4}' -f [int]$h.Bus, [int]$h.Device, [int]$h.Function
        }
    }
    return ,@($Adapters | Sort-Object { if ($hw.ContainsKey("$($_.Name)")) { $hw["$($_.Name)"] } else { '9999' + ('{0:D8}' -f [int]$_.ifIndex) } })
}

function ConvertTo-NormalMac([string]$Mac) { return ($Mac -replace '[^0-9A-Fa-f]', '').ToUpper() }

function ConvertTo-PrefixLength([string]$Mask) {
    $bits = ($Mask.Trim() -split '\.' | ForEach-Object { [Convert]::ToString([int]$_, 2).PadLeft(8, '0') }) -join ''
    $zero = $bits.IndexOf('0')
    if ($zero -lt 0) { return 32 }
    return $zero
}

# Pair captured ghost NIC settings with present adapters: by decoded MAC first, then 1:1 if exactly one of each is left.
function Resolve-NicMatches($Captures, $Adapters) {
    $result = @(); $usedAdapters = @{}; $matchedCaps = @{}
    for ($i = 0; $i -lt $Captures.Count; $i++) {
        $c = $Captures[$i]
        $cands = @($c.MacCandidates | ForEach-Object { ConvertTo-NormalMac $_ })
        if (-not $cands.Count) { continue }
        $hits = @($Adapters | Where-Object { $cands -contains (ConvertTo-NormalMac $_.MacAddress) })
        if ($hits.Count -eq 1 -and -not $usedAdapters.ContainsKey($hits[0].ifIndex)) {
            $result += [pscustomobject]@{ Capture = $c; Adapter = $hits[0]; Method = 'MAC' }
            $usedAdapters[$hits[0].ifIndex] = $true; $matchedCaps[$i] = $true
        }
    }
    $leftCaps = @(for ($i = 0; $i -lt $Captures.Count; $i++) { if (-not $matchedCaps.ContainsKey($i)) { $Captures[$i] } })
    $leftAdapters = @($Adapters | Where-Object { -not $usedAdapters.ContainsKey($_.ifIndex) })
    if ($leftCaps.Count -eq 1 -and $leftAdapters.Count -eq 1) {
        $result += [pscustomobject]@{ Capture = $leftCaps[0]; Adapter = $leftAdapters[0]; Method = 'only remaining NIC' }
        $leftCaps = @()
    }
    foreach ($c in $leftCaps) { $result += [pscustomobject]@{ Capture = $c; Adapter = $null; Method = 'unmatched' } }
    return ,$result
}

function Get-TargetAdapters {
    if (-not (Get-Command Get-NetAdapter -ErrorAction SilentlyContinue)) { return ,@() }
    return ,@(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -ne 'Disabled' })
}

function Reset-NicToDhcp([int]$Index) {
    Get-NetRoute -InterfaceIndex $Index -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
    Get-NetIPAddress -InterfaceIndex $Index -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
    Set-NetIPInterface -InterfaceIndex $Index -AddressFamily IPv4 -Dhcp Enabled -ErrorAction SilentlyContinue
    Set-DnsClientServerAddress -InterfaceIndex $Index -ResetServerAddresses -ErrorAction SilentlyContinue
}

# Waits out duplicate address detection, then checks the gateway answers ARP (works even when ICMP is blocked).
function Test-AppliedNic([int]$Index, [string]$Ip, [string]$Gateway) {
    $state = $null
    for ($t = 0; $t -lt 10; $t++) {
        $state = "$((Get-NetIPAddress -InterfaceIndex $Index -IPAddress $Ip -ErrorAction SilentlyContinue).AddressState)"
        if ($state -ne 'Tentative') { break }
        Start-Sleep -Seconds 1
    }
    if ($state -eq 'Duplicate') { return "address $Ip is already in use on the network (is the source VM still powered on?)" }
    if ($state -ne 'Preferred') { return "address $Ip ended in state '$state'" }
    if (-not $Gateway) { return $null }
    for ($t = 0; $t -lt 3; $t++) {
        $null = Test-Connection -ComputerName $Gateway -Count 1 -Quiet -ErrorAction SilentlyContinue
        $n = Get-NetNeighbor -InterfaceIndex $Index -IPAddress $Gateway -ErrorAction SilentlyContinue
        if ($n -and $n.LinkLayerAddress -and $n.LinkLayerAddress -notmatch '^(00-){5}00$' -and "$($n.State)" -ne 'Unreachable') { return $null }
        Start-Sleep -Seconds 2
    }
    return "gateway $Gateway did not answer ARP"
}

function Set-NicFromCapture($Capture, $Adapter, [switch]$Probe) {
    $idx  = [int]$Adapter.ifIndex
    $name = "$($Adapter.Name) [$($Adapter.InterfaceDescription), $($Adapter.MacAddress)]"
    $ips   = @("$($Capture.IPAddress)" -split ',' | Where-Object { $_ -and $_ -ne '0.0.0.0' })
    $masks = @("$($Capture.SubnetMask)" -split ',')
    $gws   = @("$($Capture.Gateway)" -split ',' | Where-Object { $_ })
    $dns   = @("$($Capture.DNS)" -split '[,\s]+' | Where-Object { $_ })
    if ($Capture.DHCP -or -not $ips.Count) { Log "  $name : old NIC used DHCP, nothing to apply"; return 'dhcp' }

    $current = @(Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object IPAddress)
    if ($current -contains $ips[0]) { Log "  $name : already has $($ips[0])"; return 'present' }
    $ipIf = Get-NetIPInterface -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue
    if ($ipIf -and "$($ipIf.Dhcp)" -eq 'Disabled' -and @($current | Where-Object { $_ -notlike '169.254.*' }).Count) {
        Log "  $name : already has a different static address ($($current -join ',')); not overwriting" 'WARN'
        return 'conflict'
    }

    Log "  $name : applying IP=$($ips -join ',') GW=$($gws -join ',') DNS=$($dns -join ',')"
    try {
        Set-NetIPInterface -InterfaceIndex $idx -AddressFamily IPv4 -Dhcp Disabled -ErrorAction Stop
        Get-NetRoute -InterfaceIndex $idx -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
        Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
        for ($i = 0; $i -lt $ips.Count; $i++) {
            $mask = $masks[[Math]::Min($i, $masks.Count - 1)]
            $p = @{ InterfaceIndex = $idx; AddressFamily = 'IPv4'; IPAddress = $ips[$i]; PrefixLength = [int](ConvertTo-PrefixLength $mask); ErrorAction = 'Stop' }
            if ($i -eq 0 -and $gws.Count) { $p.DefaultGateway = $gws[0] }
            New-NetIPAddress @p | Out-Null
        }
        for ($i = 1; $i -lt $gws.Count; $i++) {
            New-NetRoute -InterfaceIndex $idx -DestinationPrefix '0.0.0.0/0' -NextHop $gws[$i] -RouteMetric (256 + $i) -ErrorAction SilentlyContinue | Out-Null
        }
        if ($dns.Count) { Set-DnsClientServerAddress -InterfaceIndex $idx -ServerAddresses $dns -ErrorAction Stop }
        if ($Capture.Domain) { Set-DnsClient -InterfaceIndex $idx -ConnectionSpecificSuffix $Capture.Domain -ErrorAction SilentlyContinue }
    } catch {
        Reset-NicToDhcp $idx
        if ($Probe) { Log "  $name : probe could not apply ($($_.Exception.Message)); reverted, trying next NIC" 'WARN'; return 'probe failed' }
        Fail "  $name : applying settings failed ($($_.Exception.Message)); reverted to DHCP"
        return 'failed'
    }

    $problem = Test-AppliedNic $idx $ips[0] $(if ($gws.Count) { $gws[0] } else { '' })
    if ($problem -and $Probe) {
        Log "  $name : probe - $problem; reverted, trying next NIC"
        Reset-NicToDhcp $idx
        return 'probe failed'
    }
    if ($problem) {
        if ($RollbackIfUnreachable) {
            Fail "  $name : $problem; reverted to DHCP so the agent can still reach Morpheus. Settings are in the ghost-nic-config file."
            Reset-NicToDhcp $idx
            return 'rolled back'
        }
        Log "  $name : $problem (left applied; RollbackIfUnreachable is off)" 'WARN'
    } else {
        Log "  $name : verified (address preferred, gateway reachable)"
    }

    if ($Capture.Connection -and $Adapter.Name -ne $Capture.Connection) {
        Clear-StaleConnectionName $Capture.Connection "$($Adapter.InterfaceGuid)"
        try   { Rename-NetAdapter -Name $Adapter.Name -NewName $Capture.Connection -ErrorAction Stop; Log "  Renamed '$($Adapter.Name)' -> '$($Capture.Connection)'" }
        catch { Log "  Could not rename '$($Adapter.Name)' to '$($Capture.Connection)' yet ($($_.Exception.Message)); retry after reboot" 'WARN' }
    }
    return 'applied'
}

function Get-Download([string]$Url, [string]$Dest) {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Log "Downloading $Url"
        Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing -TimeoutSec 900
        if ((Get-Item $Dest).Length -lt 1MB) { throw 'downloaded file is suspiciously small' }
        return $Dest
    } catch { Fail "VirtIO download failed: $($_.Exception.Message)"; return $null }
}

function Resolve-VirtioInstaller {
    $name = 'virtio-win-guest-tools.exe'
    $dest = Join-Path $WorkDir $name
    if (-not $VirtioSource -and (Test-Path -LiteralPath $dest) -and (Get-Item -LiteralPath $dest).Length -ge 1MB) {
        Log "Using VirtIO installer already in $WorkDir (uploaded before the run)"
        return $dest
    }
    if ($VirtioSource) {
        if ($VirtioSource -match '^https?://') { return (Get-Download $VirtioSource $dest) }
        $src = $VirtioSource
        if (Test-Path -LiteralPath $src -PathType Container) { $src = Join-Path $src $name }
        if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination $dest -Force; Log "Using VirtIO installer from $src"; return $dest }
        Fail "VirtioSource not found: $VirtioSource"
        return $null
    }
    foreach ($d in Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=5' -ErrorAction SilentlyContinue) {
        $c = Join-Path ($d.DeviceID + '\') $name
        if (Test-Path -LiteralPath $c) { Log "Using VirtIO installer from mounted media $($d.DeviceID)"; $script:VirtioMedia = $d.DeviceID + '\'; return $c }
    }
    return (Get-Download $VirtioUrl $dest)
}

# ---------------------------------------------------------------- VirtIO inventory
function Get-VirtioDeviceType([string]$Id) {
    switch -Regex ($Id) {
        'VEN_1AF4&DEV_(1000|1041)' { return 'Network (netkvm)' }
        'VEN_1AF4&DEV_(1001|1042)' { return 'Block storage (viostor)' }
        'VEN_1AF4&DEV_(1002|1045)' { return 'Memory balloon (balloon)' }
        'VEN_1AF4&DEV_(1003|1043)' { return 'Serial / guest agent channel (vioser)' }
        'VEN_1AF4&DEV_(1004|1048)' { return 'SCSI storage (vioscsi)' }
        'VEN_1AF4&DEV_(1005|1044)' { return 'RNG (viorng)' }
        'VEN_1AF4&DEV_1050'        { return 'GPU (viogpudo)' }
        'VEN_1AF4&DEV_1052'        { return 'Input (vioinput)' }
        'VEN_1AF4&DEV_105A'        { return 'Shared FS (viofs)' }
        'VEN_1B36&DEV_0011'        { return 'PV panic (pvpanic)' }
        'VEN_1B36&DEV_000[2-4]'    { return 'PCI serial (qemupciserial)' }
        'QEMU0002'                 { return 'FW cfg (fwcfg)' }
        'VEN_1AF4'                 { return 'Other virtio device' }
        default                    { return 'QEMU device' }
    }
}

function Get-VirtioInventory {
    $drivers = @(Get-WindowsDriver -Online -ErrorAction SilentlyContinue)
    $script:AllDrivers = $drivers

    $packages = @($drivers | Where-Object { $_.ProviderName -match 'Red Hat' } | ForEach-Object {
        [pscustomobject]@{ Inf = [IO.Path]::GetFileNameWithoutExtension($_.OriginalFileName); Version = "$($_.Version)"; Class = $_.ClassName; Published = $_.Driver }
    } | Sort-Object Inf, Version)

    # Boot/network drivers an injector may have dropped in as services without staging a store package
    $core = @(foreach ($s in 'viostor', 'vioscsi', 'netkvm') {
        $p = Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\$s" -ErrorAction SilentlyContinue
        if (-not $p) { continue }
        $img = Resolve-ImagePath $p.ImagePath
        if (-not $img) { $img = "$env:SystemRoot\System32\drivers\$s.sys" }
        $ver = $null
        if (Test-Path -LiteralPath $img) { $ver = (Get-Item -LiteralPath $img).VersionInfo.FileVersion }
        [pscustomobject]@{ Name = $s; Start = $p.Start; FileVersion = $ver; Staged = [bool]($packages | Where-Object { $_.Inf -eq $s }) }
    })

    $devices = @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
        Where-Object { $_.DeviceID -match 'VEN_1AF4|VEN_1B36&DEV_(0011|000[2-4])|QEMU0002' } | ForEach-Object {
            [pscustomobject]@{ Type = Get-VirtioDeviceType $_.DeviceID; Name = $_.Name; Id = $_.DeviceID; ErrorCode = [int]$_.ConfigManagerErrorCode }
        })

    $services = @(foreach ($n in 'QEMU-GA', 'BalloonService', 'spice-agent', 'VirtioFsSvc') {
        $s = Get-Service -Name $n -ErrorAction SilentlyContinue
        if ($s) { [pscustomobject]@{ Name = $n; Status = "$($s.Status)" } }
    })

    [pscustomobject]@{
        Suite      = @(Get-UninstallEntries 'Virtio-win*')
        Packages   = $packages
        Core       = $core
        Devices    = $devices
        Missing    = @($devices | Where-Object { $_.ErrorCode -ne 0 })
        Services   = $services
        GuestAgent = [bool]($services | Where-Object { $_.Name -eq 'QEMU-GA' })
    }
}

function Write-VirtioInventory($Inv, [string]$Label) {
    Log "--- VirtIO inventory ($Label) ---"
    if ($Inv.Suite.Count) { foreach ($s in $Inv.Suite) { Log "  Installed product : $($s.DisplayName) $($s.DisplayVersion)" } }
    else                  { Log '  Installed product : none (no virtio-win guest tools / driver installer)' }
    if ($Inv.Packages.Count) {
        foreach ($p in $Inv.Packages) { Log ('  Driver package    : {0,-14} {1,-16} {2,-18} {3}' -f $p.Inf, $p.Version, $p.Class, $p.Published) }
    } else { Log '  Driver package    : none from Red Hat in the driver store' }
    foreach ($c in $Inv.Core) {
        Log ('  Boot/net service  : {0,-8} start={1} file={2} staged={3}' -f $c.Name, $c.Start, $c.FileVersion, $c.Staged)
    }
    foreach ($d in $Inv.Devices) {
        $state = 'OK'
        if ($d.ErrorCode -eq 28) { $state = 'NO DRIVER' } elseif ($d.ErrorCode -ne 0) { $state = "ERROR $($d.ErrorCode)" }
        Log ('  Device            : {0,-38} {1}' -f $d.Type, $state)
    }
    if (-not $Inv.Devices.Count) { Log '  Device            : no virtio/QEMU PCI devices detected' }
    if ($Inv.Services.Count) { foreach ($s in $Inv.Services) { Log "  Service           : $($s.Name) ($($s.Status))" } }
    else                     { Log '  Service           : no QEMU-GA / balloon / SPICE / virtiofs services' }
}

function Get-VirtioGaps($Inv) {
    $gaps = @()
    if (-not $Inv.Suite.Count) { $gaps += 'full guest tools suite not installed' }
    if (-not $Inv.GuestAgent)  { $gaps += 'QEMU guest agent missing' }
    foreach ($m in $Inv.Missing) { $gaps += "no working driver for $($m.Type)" }
    foreach ($c in $Inv.Core | Where-Object { -not $_.Staged }) { $gaps += "$($c.Name) present as a service but not staged in the driver store" }
    return ,$gaps
}

function Invoke-ScheduledReboot {
    & shutdown.exe /r /t $RebootDelaySeconds /c 'VMware Tools removal / VirtIO install (Morpheus task)' /d p:4:2 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0)        { Log "Reboot scheduled in $RebootDelaySeconds seconds" }
    elseif ($LASTEXITCODE -eq 1190) { Log 'A reboot is already scheduled' }
    else                            { Log "shutdown.exe returned $LASTEXITCODE; reboot the VM manually" 'WARN' }
}

# 2012 R2 / 2016 get Red Hat-signed (not Microsoft-attested) drivers. Windows asks "trust this publisher?" for those,
# and in session 0 with no UI that prompt can stall or fail the silent install. Pre-trust the publisher from the
# catalogs already on the box (injected drivers) or on the virtio ISO. Microsoft-signed catalogs are ignored.
function Import-RedHatPublisher {
    $cats = @()
    foreach ($d in @($script:AllDrivers | Where-Object { $_.ProviderName -match 'Red Hat' })) {
        $cats += @(Get-ChildItem -LiteralPath (Split-Path $d.OriginalFileName) -Filter *.cat -ErrorAction SilentlyContinue)
    }
    if ($script:VirtioMedia) {
        $cats += @(Get-ChildItem -Path $script:VirtioMedia -Filter *.cat -Recurse -ErrorAction SilentlyContinue | Select-Object -First 60)
    }
    $certs = @{}
    foreach ($c in $cats) {
        $sc = (Get-AuthenticodeSignature -FilePath $c.FullName -ErrorAction SilentlyContinue).SignerCertificate
        if ($sc -and $sc.Subject -match 'Red Hat' -and -not $certs.ContainsKey($sc.Thumbprint)) { $certs[$sc.Thumbprint] = $sc }
    }
    if (-not $certs.Count) { Log 'No Red Hat-signed driver catalogs found to pre-trust (normal when drivers are Microsoft-attested, 2019+)'; return }
    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store('TrustedPublisher', 'LocalMachine')
    try {
        $store.Open('ReadWrite')
        foreach ($c in $certs.Values) {
            if (@($store.Certificates | Where-Object { $_.Thumbprint -eq $c.Thumbprint }).Count) { continue }
            $store.Add($c)
            Log "Added Red Hat driver publisher to TrustedPublisher: $($c.Subject) [$($c.Thumbprint)]"
        }
    } catch { Log "Could not update TrustedPublisher: $($_.Exception.Message)" 'WARN' }
    finally { $store.Close() }
}

# Run on VMware, before migration: records each NIC's interface GUID, MAC and IPv4 settings. The disk carries this
# file across the migration; afterwards each ghost NIC's GUID maps back to its exact MAC, and the preserved MAC
# finds its virtio replacement.
function Save-PreMigrationNics([string]$Path) {
    $out = @()
    foreach ($a in (Get-TargetAdapters)) {      # no @(): the function already returns a flat array
        $guid = "$($a.InterfaceGuid)"
        $cfg  = Get-TcpipByGuid $guid
        $rec  = [pscustomobject]@{
            InterfaceGuid = $guid; MacAddress = "$($a.MacAddress)"; Name = "$($a.Name)"; Description = "$($a.InterfaceDescription)"
            DHCP = $(if ($cfg) { $cfg.DHCP } else { $null }); IPAddress = $(if ($cfg) { $cfg.IPAddress } else { '' })
            SubnetMask = $(if ($cfg) { $cfg.SubnetMask } else { '' }); Gateway = $(if ($cfg) { $cfg.Gateway } else { '' })
            DNS = $(if ($cfg) { $cfg.DNS } else { '' }); CapturedUtc = [DateTime]::UtcNow.ToString('o')
        }
        Log "  $($rec.Name) [$($rec.Description)] MAC $($rec.MacAddress) $guid DHCP=$($rec.DHCP) IP=$($rec.IPAddress) GW=$($rec.Gateway)"
        $out += $rec
    }
    if ($out.Count) { ConvertTo-Json -InputObject $out -Depth 4 | Set-Content -Path $Path }
    return ,$out
}

function Get-NicResultText([string]$Name, [string]$Result, $Capture) {
    switch ($Result) {
        'applied'     { return "$($Name): old static settings applied and verified ($($Capture.IPAddress))" }
        'present'     { return "$($Name): already has $($Capture.IPAddress), unchanged" }
        'dhcp'        { return "$($Name): old NIC used DHCP, left on DHCP" }
        'conflict'    { return "$($Name): already has a different static IP, left unchanged" }
        'rolled back' { return "$($Name): settings failed verification, reverted to DHCP" }
        'failed'      { return "$($Name): applying settings failed, reverted to DHCP" }
        default       { return "$($Name): $Result" }
    }
}

# Optional (SetPrivateProfile): on a workgroup VM, a new or migrated NIC usually lands on the Public profile, where
# the WinRM rule only allows the local subnet. Moving it to Private lets Morpheus reach the VM over WinRM.
# Private relaxes the firewall for that network; leave this off where that matters.
function Set-PrivateProfile {
    if (-not $SetPrivateProfile) { return }
    if ((Get-CimInstance Win32_ComputerSystem).PartOfDomain) { Log 'Domain-joined: network profiles are left to the domain'; return }
    if (-not (Get-Command Get-NetConnectionProfile -ErrorAction SilentlyContinue)) { return }
    foreach ($np in @(Get-NetConnectionProfile -ErrorAction SilentlyContinue | Where-Object { "$($_.NetworkCategory)" -eq 'Public' })) {
        try {
            Set-NetConnectionProfile -InterfaceIndex $np.InterfaceIndex -NetworkCategory Private -ErrorAction Stop
            Log "Network '$($np.Name)' on $($np.InterfaceAlias): Public -> Private"
            $script:Did.Nics += "$($np.InterfaceAlias): network profile Public -> Private"
        } catch { Log "Could not set $($np.InterfaceAlias) to Private: $($_.Exception.Message)" 'WARN' }
    }
    $rule = Get-NetFirewallRule -Name 'WINRM-HTTP-In-TCP' -ErrorAction SilentlyContinue
    if ($rule -and "$($rule.Enabled)" -ne 'True') {
        Enable-NetFirewallRule -Name 'WINRM-HTTP-In-TCP' -ErrorAction SilentlyContinue
        Log 'Enabled firewall rule WINRM-HTTP-In-TCP'
    }
}

# ---------------------------------------------------------------- 1.4.0: run config, vendor inventory, result.json

function Import-RunConfig([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { $c = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json } catch { Log "run-config.json unreadable: $($_.Exception.Message)" 'WARN'; return $null }
    foreach ($n in 'Mode', 'RemoveScope', 'VirtioSource', 'RebootWhenDone', 'SetPrivateProfile', 'ApplyNicConfig', 'ForceVirtioInstall', 'SkipRemovalIfVirtioFailed') {
        if ($c.PSObject.Properties.Name -contains $n -and $null -ne $c.$n) { Set-Variable -Scope Script -Name $n -Value $c.$n }
    }
    if ($c.PSObject.Properties.Name -contains 'RemoveProducts' -and $c.RemoveProducts) { $script:RemoveProducts = @($c.RemoveProducts) }
    return $c
}

function Get-ProductClass([string]$Name, [string]$Publisher) {
    $t = "$Name $Publisher"
    if ($Name -like 'VMware Tools*')            { return 'tools' }
    if ($t -match 'Carbon ?Black|\bCb (Defense|Protection|Response)\b|Endpoint Standard|App Control') { return 'protected' }
    return 'other'
}

function Get-VendorInventory {
    $products = @()
    foreach ($e in Get-UninstallEntries '*') {
        $t = "$($e.DisplayName) $($e.Publisher)"
        if ($t -notmatch 'VMware|Broadcom|Omnissa|Carbon ?Black|\bCb (Defense|Protection|Response)\b') { continue }
        $products += [pscustomobject]@{
            Name = "$($e.DisplayName)"; Version = "$($e.DisplayVersion)"; Publisher = "$($e.Publisher)"
            Code = "$($e.PSChildName)"; Class = (Get-ProductClass "$($e.DisplayName)" "$($e.Publisher)")
            Uninstall = "$($e.QuietUninstallString)"; InstallLocation = "$($e.InstallLocation)"
        }
    }
    $products = @($products | Sort-Object Code -Unique | Sort-Object Class, Name)
    return $products
}

function Test-ToolsOwned([string]$Path) {
    # Inside the VMware Tools install tree, or a VMware Tools driver/service file name
    if (-not $Path) { return $false }
    if ($Path -match '\\VMware\\VMware Tools\\') { return $true }
    $leaf = ($Path -split '[\\/]')[-1]
    $base = ($leaf -replace '\.[^.]+$', '').ToLower()
    return (@($script:ToolsFileNames) -contains $base)
}

function Write-Result([string]$Status, [hashtable]$Extra) {
    $r = [ordered]@{
        version    = $ScriptVersion; mode = $Mode; status = $Status; finishedAt = (Get-Date).ToUniversalTime().ToString('o')
        host       = $env:COMPUTERNAME; scope = $RemoveScope; failures = @($script:Failures); log = $LogFile
    }
    if ($Extra) { foreach ($k in $Extra.Keys) { $r[$k] = $Extra[$k] } }
    try { ConvertTo-Json -InputObject $r -Depth 6 | Set-Content -LiteralPath $ResultFile -Encoding UTF8 } catch { Log "could not write result.json: $($_.Exception.Message)" 'WARN' }
}

function Clear-StaleConnectionName([string]$Name, [string]$KeepGuid) {
    # A removed ghost NIC keeps its Control\Network\{class}\{guid}\Connection Name, which blocks
    # Rename-NetAdapter to that name. Rename the stale entry out of the way.
    $root = 'HKLM:\SYSTEM\CurrentControlSet\Control\Network\{4D36E972-E325-11CE-BFC1-08002BE10318}'
    $present = @()
    try { $present = @(Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue | Where-Object { $_.Status -ne 'Not Present' } | ForEach-Object { "$($_.InterfaceGuid)".ToUpper() }) } catch { }
    foreach ($k in Get-ChildItem $root -ErrorAction SilentlyContinue) {
        $guid = $k.PSChildName.ToUpper()
        if ($KeepGuid -and $guid -eq $KeepGuid.ToUpper()) { continue }
        if ($present -contains $guid) { continue }
        $ck = Join-Path $k.PSPath 'Connection'
        $n = (Get-ItemProperty -LiteralPath $ck -Name Name -ErrorAction SilentlyContinue).Name
        if ($n -and $n -eq $Name) {
            $new = "$Name (removed $Stamp)"
            Set-ItemProperty -LiteralPath $ck -Name Name -Value $new -ErrorAction SilentlyContinue
            Log "  Freed connection name '$Name' from removed adapter $guid (now '$new')"
        }
    }
}

function Write-RunSummary {
    $d = $script:Did
    Log '=== Summary ==='
    Log "  VirtIO       : $($d.VirtIO)"
    $removed = $d.Ghosts + $d.Services + $d.Packages + $d.Files + $d.RegKeys + $d.Filters
    if ($removed) {
        Log ("  VMware Tools : removed - {0} ghost device(s), {1} service(s)/driver(s), {2} driver package(s), {3} file/folder(s), {4} registry item(s), {5} filter/provider entr(ies)" -f `
             $d.Ghosts, $d.Services, $d.Packages, $d.Files, $d.RegKeys, $d.Filters)
    } else {
        Log '  VMware Tools : none found, nothing removed'
    }
    if ($d.Nics.Count) { foreach ($n in $d.Nics) { Log "  NIC          : $n" } }
    else               { Log '  NIC          : no old NIC settings to restore' }
    foreach ($f in $script:Failures) { Log " - $f" 'ERROR' }
    if ($script:Leftovers.Count) {
        Log "$($script:Leftovers.Count) VMware file(s) could not be removed this pass; run the script again after the reboot to finish" 'WARN'
    }
}

# Phase 3 placement: MAC/1:1 matches first, then the gateway probe for static configs still without a NIC
function Invoke-NicRestore($Captures, $Adapters) {
    $nicMatches = Resolve-NicMatches $Captures $Adapters
    $usedIdx = @{}
    foreach ($m in $nicMatches) { if ($m.Adapter) { $usedIdx[[int]$m.Adapter.ifIndex] = $true } }
    foreach ($m in $nicMatches) {
        if ($m.Adapter) {
            Log "Old NIC '$($m.Capture.Label)' -> '$($m.Adapter.Name)' (matched by $($m.Method))"
            $res = Set-NicFromCapture $m.Capture $m.Adapter
            $script:Did.Nics += Get-NicResultText $m.Adapter.Name $res $m.Capture
            continue
        }
        if ($m.Capture.DHCP -or -not "$($m.Capture.IPAddress)") { continue }   # DHCP: nothing to place
        $label = "old NIC '$($m.Capture.Label)' ($($m.Capture.IPAddress))"
        $cands = Get-AdaptersInSlotOrder @($Adapters | Where-Object { -not $usedIdx.ContainsKey([int]$_.ifIndex) })   # no @() around it
        $won = $null
        if ($ProbeUnmatchedNics -and $cands.Count -and "$($m.Capture.Gateway)") {
            # Only the NIC on the right network/VLAN gets an ARP reply from the old gateway
            Log "No MAC match for $label; probing $($cands.Count) NIC(s) for gateway $($m.Capture.Gateway)"
            foreach ($c in $cands) {
                $r = Set-NicFromCapture $m.Capture $c -Probe
                if ($r -eq 'applied' -or $r -eq 'present') { $won = $c; break }
            }
        }
        if ($won) {
            $usedIdx[[int]$won.ifIndex] = $true
            $script:Did.Nics += (Get-NicResultText $won.Name 'applied' $m.Capture) + ' - found by gateway probe'
        } else {
            Fail "No confident match for $label; apply it by hand (settings are in the ghost-nic-config file)"
            $script:Did.Nics += "$($label): no confident match, NOT applied"
        }
    }
}

# ================================================================ Phase 0: pre-flight
Log "=== Invoke-VMwareToVirtio $ScriptVersion ==="
Log '=== Phase 0: pre-flight ==='
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    $self = $PSCommandPath
    if (-not $self) {
        # Started via -Command / -EncodedCommand / an in-process runspace: write our own text out and run that
        $text = $null
        try { $text = $MyInvocation.MyCommand.ScriptBlock.ToString() } catch { }
        if ($text -and $text -match 'Phase 4: wrap-up') {
            $self = Join-Path $WorkDir 'relaunch-x64.ps1'
            Set-Content -Path $self -Value $text -Encoding UTF8
        }
    }
    if ($self) {
        Log 'Relaunching in 64-bit PowerShell'
        & "$env:WINDIR\sysnative\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $self
        exit $LASTEXITCODE
    }
    Log 'Running in 32-bit PowerShell on a 64-bit OS and could not recover the script text to relaunch 64-bit. Aborting.' 'ERROR'
    exit 1
}
if ("$($ExecutionContext.SessionState.LanguageMode)" -ne 'FullLanguage') {
    Log "PowerShell is in $($ExecutionContext.SessionState.LanguageMode) mode (AppLocker/WDAC); this script needs FullLanguage for its native helpers." 'ERROR'
    exit 1
}
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Log "Not elevated (running as $($id.Name)). Enable elevation on the Morpheus task." 'ERROR'
    exit 1
}
if ($PSVersionTable.PSVersion.Major -lt 4 -or -not (Get-Command Get-WindowsDriver -ErrorAction SilentlyContinue)) {
    Log "Needs Windows Server 2012 R2 / Windows 8.1 or newer (PowerShell 4+, DISM module). Found PowerShell $($PSVersionTable.PSVersion)." 'ERROR'
    exit 1
}
$cs = Get-CimInstance Win32_ComputerSystem
$os = Get-CimInstance Win32_OperatingSystem
Log "Host $env:COMPUTERNAME | $($os.Caption) build $($os.BuildNumber) | $($cs.Manufacturer) / $($cs.Model) | as $($id.Name)"
Remove-Item -LiteralPath $ResultFile -Force -ErrorAction SilentlyContinue   # never leave an old result behind for this run
$runCfg = Import-RunConfig (Join-Path $WorkDir 'run-config.json')
if ($runCfg) { Log "run-config.json: Mode=$Mode RemoveScope=$RemoveScope RemoveProducts=$(@($RemoveProducts) -join ', ')" }
if (@('ToolsOnly', 'Selected', 'AllVMware') -notcontains $RemoveScope) { Log "Unknown RemoveScope '$RemoveScope'; using ToolsOnly" 'WARN'; $RemoveScope = 'ToolsOnly' }
$script:Inventory = @(Get-VendorInventory)
Log "VMware/Broadcom/Omnissa software installed: $($script:Inventory.Count)"
foreach ($pr in $script:Inventory) { Log ("  [{0}] {1} {2} ({3}) {4}" -f $pr.Class, $pr.Name, $pr.Version, $pr.Publisher, $pr.Code) }
if ($Mode -eq 'Inventory') {
    $onVmware = "$($cs.Manufacturer) $($cs.Model)" -match 'VMware'
    Write-Result 'ok' @{ products = $script:Inventory; onVmware = $onVmware; hardware = "$($cs.Manufacturer) / $($cs.Model)" }
    Log "Inventory written to $ResultFile"
    exit 0
}
$preJson = Join-Path $WorkDir 'nic-premigration.json'
if ("$($cs.Manufacturer) $($cs.Model)" -match 'VMware' -and -not $Force) {
    if ($SetPrivateProfile) { Log 'Running on VMware: pre-migration capture, plus SetPrivateProfile. Nothing else is changed on this VM.' }
    else                    { Log 'Running on VMware: pre-migration capture only. Nothing else is changed on this VM.' }
    $pre = Save-PreMigrationNics $preJson
    Set-PrivateProfile
    if ($pre.Count) { Log "Saved $($pre.Count) NIC(s) to $preJson. Run this script again after the VM is on KVM." }
    else { Log 'No network adapters found to capture' 'WARN'; Write-Result 'attention' @{ premigrationCapture = 0; products = $script:Inventory }; exit 1 }
    Write-Result 'ok' @{ premigrationCapture = $pre.Count; products = $script:Inventory; onVmware = $true }
    exit 0
}
$script:PreMig = @()
if (Test-Path $preJson) {
    $script:PreMig = @(Get-Content -Path $preJson -Raw | ConvertFrom-Json | ForEach-Object { $_ })
    Log "Pre-migration NIC capture found: $($script:PreMig.Count) NIC(s) ($preJson)"
} else {
    Log 'No pre-migration NIC capture (optional)'
}
$script:NicMap = @()
$nicMapJson = Join-Path $WorkDir 'nic-map.json'
if (Test-Path $nicMapJson) {
    $script:NicMap = @(Get-Content -Path $nicMapJson -Raw | ConvertFrom-Json | ForEach-Object { $_ })
    Log "Morpheus NIC map found: $($script:NicMap.Count) NIC(s) ($nicMapJson)"
    foreach ($e in $script:NicMap) { Log "  map: $($e.MacAddress) -> $($e.IPAddress) $($e.Source)" }
} elseif (-not $script:PreMig.Count) {
    Log 'No NIC map (vme-guest-run.py --source-server-id); multi-NIC VMs fall back to the gateway probe' 'WARN'
}

# ================================================================ Phase 1: VirtIO check / install
Log '=== Phase 1: VirtIO check / install ==='
$phase1FailStart = $script:Failures.Count
$virtioBefore = Get-VirtioInventory
Write-VirtioInventory $virtioBefore 'before'
$gaps = Get-VirtioGaps $virtioBefore
if ($gaps.Count) { foreach ($g in $gaps) { Log "  Gap: $g" 'WARN' } } else { Log '  Full VirtIO suite already in place' }

$vmtPresent = @(Get-UninstallEntries 'VMware Tools*').Count -or [bool](Get-Service -Name 'VMTools' -ErrorAction SilentlyContinue)
Log "VMware Tools present: $vmtPresent"

if ($VirtioCheckOnly) {
    $checkGhosts = Get-GhostDevices
    Log "Ghost VMware devices / stale NICs present: $($checkGhosts.Count)"
    foreach ($g in $checkGhosts) { Log "  Ghost: $(Get-DeviceLabel $g) [$($g.Class)] $($g.InstanceId)" }
    $checkCaps = Save-GhostNicConfig $checkGhosts ''
    if ($checkCaps.Count) {
        $checkAdapters = Get-TargetAdapters
        foreach ($a in $checkAdapters) { Log "  Present NIC: $($a.Name) [$($a.InterfaceDescription)] MAC $($a.MacAddress)" }
        foreach ($m in Resolve-NicMatches $checkCaps $checkAdapters) {
            if ($m.Adapter) { Log "  Plan: '$($m.Capture.Label)' ($($m.Capture.IPAddress)) -> '$($m.Adapter.Name)' by $($m.Method)" }
            else            { Log "  Plan: '$($m.Capture.Label)' ($($m.Capture.IPAddress)) -> no confident match, would be logged only" 'WARN' }
        }
    }
    Log 'Check-only mode: no changes made.'
    Log "Full log: $LogFile"
    if ($gaps.Count -or $vmtPresent) { exit 1 } else { exit 0 }
}

# A completed run that hasn't been followed by a reboot yet: services are only marked for deletion and
# locked files are queued, so repeating everything adds nothing. Finish it with the reboot instead.
$marker = Join-Path $WorkDir 'last-run.ticks'
if ((Test-Path $marker) -and -not $IgnorePendingReboot) {
    $lastTicks = 0L
    [void][long]::TryParse((Get-Content $marker -TotalCount 1), [ref]$lastTicks)
    if ($os.LastBootUpTime.ToUniversalTime().Ticks -lt $lastTicks) {
        Log ('Previous run completed at {0:u} and the VM has not rebooted since; nothing to redo.' -f (New-Object DateTime $lastTicks, ([DateTimeKind]::Utc))) 'WARN'
        Write-Result 'pending-reboot' @{ reboot = [bool]$RebootWhenDone; rebootDelaySeconds = $RebootDelaySeconds }
        if ($RebootWhenDone) { Invoke-ScheduledReboot } else { Log 'Reboot the VM to finish the previous run (or set $IgnorePendingReboot = $true)' 'WARN' }
        exit 0
    }
    Remove-Item $marker -Force -ErrorAction SilentlyContinue
}

if ($gaps.Count -or $ForceVirtioInstall) {
    if (-not $gaps.Count) { Log 'ForceVirtioInstall set; reinstalling anyway' }
    $inst = Resolve-VirtioInstaller
    if ($inst) {
        $sig = Get-AuthenticodeSignature -FilePath $inst
        Log "Installer signature: $($sig.Status) | $($sig.SignerCertificate.Subject)"
        $sigOk = $sig.Status -eq 'Valid'
        if (-not $sigOk -and @('HashMismatch', 'NotSigned', 'Incompatible') -notcontains "$($sig.Status)" -and $sig.SignerCertificate.Subject -match 'Red Hat') {
            # Typical on an offline 2012 R2/2016 box missing a newer root: signature intact, chain unverifiable
            Log "Signature status $($sig.Status) but the file is intact and signed by Red Hat; continuing" 'WARN'
            $sigOk = $true
        }
        if (-not $sigOk) {
            Fail 'VirtIO installer signature is missing or the file was altered; refusing to run it'
        } else {
            Import-RedHatPublisher
            $vi = (Get-Item -LiteralPath $inst).VersionInfo
            Log "Installer version: $($vi.ProductVersion)"
            # Same bundle version already registered: /install would no-op, so repair it to restore missing pieces
            $mode = '/install'
            $bundle = @($virtioBefore.Suite | Where-Object { $_.DisplayName -like 'Virtio-win-guest-tools*' }) | Select-Object -First 1
            if ($bundle) {
                try { if ([version]$bundle.DisplayVersion -eq [version]$vi.ProductVersion) { $mode = '/repair' } } catch { }
            }
            Log "Running installer with $mode"
            $vlog = Join-Path $WorkDir "virtio-install-$Stamp.log"
            $p = Start-Process -FilePath $inst -ArgumentList @($mode, '/quiet', '/norestart', '/log', "`"$vlog`"") -PassThru
            $null = $p.Handle
            if (-not $p.WaitForExit(1800000)) {
                Fail "VirtIO installer timed out after 30 min (log: $vlog)"
            } elseif (@(0, 3010, 1641) -contains $p.ExitCode) {
                Log "VirtIO guest tools installer finished (exit $($p.ExitCode))"
                $script:Did.VirtIO = "installed ($mode, exit $($p.ExitCode)); was missing: $($gaps -join '; ')"
                Mark '' -Reboot
            } else {
                Fail "VirtIO installer exit code $($p.ExitCode) (log: $vlog)"
                $script:Did.VirtIO = "install FAILED (exit $($p.ExitCode))"
            }
        }
    }
} else {
    Log 'Skipping VirtIO install (nothing missing)'
    $script:Did.VirtIO = 'already complete, nothing installed'
}

$ga = Get-Service -Name 'QEMU-GA' -ErrorAction SilentlyContinue
if ($ga) {
    Set-Service -Name 'QEMU-GA' -StartupType Automatic -ErrorAction SilentlyContinue
    if ($ga.Status -ne 'Running') { Start-Service -Name 'QEMU-GA' -ErrorAction SilentlyContinue }
}

$virtioAfter = Get-VirtioInventory
Write-VirtioInventory $virtioAfter 'after'
$before = @{}
foreach ($pk in $virtioBefore.Packages) { $before[$pk.Inf] = $pk.Version }
foreach ($pk in $virtioAfter.Packages) {
    if (-not $before.ContainsKey($pk.Inf))      { Log "  Added   : $($pk.Inf) $($pk.Version)" }
    elseif ($before[$pk.Inf] -ne $pk.Version)   { Log "  Updated : $($pk.Inf) $($before[$pk.Inf]) -> $($pk.Version)" }
}
$gapsAfter = Get-VirtioGaps $virtioAfter
foreach ($g in $gapsAfter) {
    if ($g -like 'QEMU guest agent*' -or $g -like 'full guest tools*' -or $g -like 'no working driver*') { Fail "VirtIO after install: $g" }
    else { Log "VirtIO after install: $g" 'WARN' }
}
$gaNow = Get-Service -Name 'QEMU-GA' -ErrorAction SilentlyContinue
if ($gaNow -and $gaNow.Status -ne 'Running') {
    Log 'QEMU-GA installed but not running; check the VM has the org.qemu.guest_agent.0 virtio-serial channel' 'WARN'
}

# ================================================================ Phase 2: VMware Tools
Log "=== Phase 2: VMware Tools removal (scope: $RemoveScope) ==="
$phase1Failed = $script:Failures.Count -gt $phase1FailStart
$noDriver = @($gapsAfter | Where-Object { $_ -like 'no working driver*' }).Count -gt 0
$script:SkipRemoval = $SkipRemovalIfVirtioFailed -and ($phase1Failed -or $noDriver)
if ($script:SkipRemoval) {
    Fail 'Phase 1 did not complete the VirtIO set; VMware Tools is left installed so the VM keeps working drivers. Fix the VirtIO install (upload virtio-win-guest-tools.exe or attach the ISO) and run again.'
}
$script:LeftInPlace = @($script:Inventory | Where-Object { $_.Class -ne 'tools' } | ForEach-Object { "$($_.Name) $($_.Version)" })

# --- 2-pre. Selected products (their own uninstallers; protected products are never forced)
if (-not $script:SkipRemoval -and $RemoveScope -eq 'Selected' -and @($RemoveProducts).Count) {
    foreach ($pr in $script:Inventory) {
        if ($pr.Class -eq 'tools') { continue }
        if (-not (@($RemoveProducts) | Where-Object { $_ -eq $pr.Code -or $_ -eq $pr.Name })) { continue }
        if ($pr.Class -eq 'protected') { Log "Not uninstalling $($pr.Name): tamper-protected security product; remove it from its own console" 'WARN'; continue }
        $plog = Join-Path $WorkDir ("uninstall-{0}-$Stamp.log" -f ($pr.Name -replace '[^A-Za-z0-9]', ''))
        if ($pr.Code -match '^\{[0-9A-Fa-f\-]{36}\}$') {
            Log "Uninstalling $($pr.Name) $($pr.Version) (msiexec /x $($pr.Code))"
            $p = Start-Process msiexec.exe -ArgumentList "/x $($pr.Code) /qn /norestart REBOOT=ReallySuppress /l*v `"$plog`"" -PassThru
        } elseif ($pr.Uninstall) {
            Log "Uninstalling $($pr.Name) $($pr.Version) ($($pr.Uninstall))"
            $p = Start-Process cmd.exe -ArgumentList "/c $($pr.Uninstall)" -PassThru
        } else { Log "No silent uninstaller for $($pr.Name); left in place" 'WARN'; continue }
        $null = $p.Handle
        if (-not $p.WaitForExit(900000)) { try { $p.Kill() } catch { }; Fail "Uninstall of $($pr.Name) still running after 15 min" }
        elseif (@(0, 3010, 1641) -contains $p.ExitCode) { Log "  removed (exit $($p.ExitCode))"; Mark '' -Reboot; $script:LeftInPlace = @($script:LeftInPlace | Where-Object { $_ -notlike "$($pr.Name)*" }) }
        else { Fail "Uninstall of $($pr.Name) exit $($p.ExitCode) (log: $plog). Products like this are best removed before migration, while the VM is still on VMware." }
    }
}
if ($script:LeftInPlace.Count -and $RemoveScope -ne 'AllVMware') {
    foreach ($l in $script:LeftInPlace) { Log "Left in place (not VMware Tools): $l" }
}

$toolsInfPattern = '^(vmxnet3|vmxnet|pvscsi|vmci|vsock|vmmouse|vmusbmouse|vmmemctl|vm3d|vmhgfs|vmaudio|vmrawdsk|vsepflt|vnetwfp|vmgencounter|vmkbd|vmusb|efifw|vmrawdisk)'

# --- 2a. MSI uninstall attempt
$productCodes = @()
if (-not $script:SkipRemoval) {
$vmtEntries = @(Get-UninstallEntries 'VMware Tools*')
foreach ($e in $vmtEntries) {
    $code = $e.PSChildName
    if ($code -notmatch '^\{[0-9A-Fa-f\-]{36}\}$') { continue }
    $productCodes += $code
    Log "MSI uninstall: $($e.DisplayName) $($e.DisplayVersion) $code"
    $mlog = Join-Path $WorkDir "vmtools-msi-uninstall-$Stamp.log"
    $p = Start-Process msiexec.exe -ArgumentList "/x $code /qn /norestart REBOOT=ReallySuppress /l*v `"$mlog`"" -PassThru
    $null = $p.Handle
    if (-not $p.WaitForExit(300000)) {
        try { $p.Kill() } catch { }
        Log 'msiexec still running after 5 min; killed it, continuing with manual cleanup' 'WARN'
    } else {
        Log "msiexec exit $($p.ExitCode) (1603 is expected off VMware; manual sweep follows either way)"
        if (@(0, 3010, 1641) -contains $p.ExitCode) { Mark '' -Reboot }
    }
}
if (-not $vmtEntries.Count) { Log 'No VMware Tools uninstall entry found; sweeping remnants only' }
}

# --- 2b. Network snapshot (before ghost NICs are removed)
& reg.exe export 'HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces' (Join-Path $WorkDir "tcpip-interfaces-$Stamp.reg") /y 2>&1 | Out-Null
ipconfig /all 2>&1 | Out-File (Join-Path $WorkDir "ipconfig-$Stamp.txt")
Log "Network snapshot saved to $WorkDir"

# --- 2c. Ghost devices (capture NIC settings first, then remove)
$ghosts = Get-GhostDevices
Log "Ghost devices matched: $($ghosts.Count)"
$nicReport = Join-Path $WorkDir "ghost-nic-config-$Stamp.txt"
$nicCaptures = Save-GhostNicConfig $ghosts $nicReport
$nicJson = Join-Path $WorkDir 'nic-capture.json'
if ($nicCaptures.Count) { ConvertTo-Json -InputObject $nicCaptures -Depth 4 | Set-Content -Path $nicJson }
if ($RemoveGhostDevices) {
    foreach ($g in $ghosts) {
        if ([VmwToVirtio.Native]::RemoveDevice($g.InstanceId)) { Log "Removed ghost device: $(Get-DeviceLabel $g) [$($g.InstanceId)]"; Mark 'Ghosts' }
        else { Log "Could not remove ghost device: $(Get-DeviceLabel $g) [$($g.InstanceId)]" 'WARN' }
    }
} elseif ($ghosts.Count) {
    Log 'RemoveGhostDevices is off; ghost devices left in place' 'WARN'
}

# --- 2d. Services and kernel drivers
$svcRoot  = 'HKLM:\SYSTEM\CurrentControlSet\Services'
if (-not $script:SkipRemoval) {
$knownSvc = @('VMTools', 'VGAuthService', 'vm3dservice', 'VMwareCAFCommAmqpListener', 'VMwareCAFManagementAgentHost',
              'vmvss', 'vmStatsProvider', 'GISvc', 'VMUSBArbService', 'vmci', 'vsock', 'vmhgfs', 'VMMemCtl', 'vmmouse',
              'vmusbmouse', 'vmrawdsk', 'vsepflt', 'vnetWFP', 'vmxnet3ndis6', 'vmxnet', 'vm3dmp', 'vm3dmp_loader',
              'vm3dmp-debug', 'vm3dmp-stats', 'vmaudio', 'vmgencounter', 'vmkbd', 'VMRawDisk')
# Wildcards from the Broadcom KB 315629 list (VMwareCAF*, physical disk helper)
$knownSvcPatterns = @('VMwareCAF*', 'VMwarePhysicalDisk*', 'vmrawd*')
$script:ToolsFileNames = @(@($knownSvc | ForEach-Object { $_.ToLower() }) + @('vmtoolsd', 'vmtools', 'vmguestlib', 'vmguestlibjava', 'vmhgfs', 'vmmemctl', 'vmx_svga',
                          'vmx_fb', 'vmxnet3n61x64', 'vmxnet3n61x86', 'pvscsi', 'vmci', 'vsock', 'vsockdll', 'vsocklib', 'vmGuestLib'.ToLower()) | Sort-Object -Unique)
$targets = @{}
foreach ($k in Get-ChildItem $svcRoot -ErrorAction SilentlyContinue) {
    $name = $k.PSChildName
    if ($name -match 'morpheus') { continue }
    $p   = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
    $img = Resolve-ImagePath $p.ImagePath
    $why = $null
    if ($knownSvc -contains $name)            { $why = 'known VMware service' }
    elseif (@($knownSvcPatterns | Where-Object { $name -like $_ }).Count) { $why = 'known VMware service pattern' }
    elseif ($p.DisplayName -match 'VMware|Broadcom' -or (Get-CompanyName $img) -match 'VMware|Broadcom') {
        if ($RemoveScope -eq 'AllVMware')  { $why = "VMware/Broadcom service ($($p.DisplayName))" }
        elseif (Test-ToolsOwned $img)      { $why = "VMware Tools binary ($img)" }
        else                               { Log "Left in place (not VMware Tools): service '$name' $($p.DisplayName) [$img]" }
    }
    if ($why) { $targets[$name] = [pscustomobject]@{ Name = $name; Image = $img; Why = $why } }
}

foreach ($t in $targets.Values) { & sc.exe stop $t.Name 2>&1 | Out-Null }
Start-Sleep -Seconds 3
$procNames = 'vmtoolsd', 'VGAuthService', 'vm3dservice', 'VMwareResolutionSet', 'vmacthlp', 'ManagementAgentHost', 'CommAmqpListener'
Get-Process -ErrorAction SilentlyContinue | Where-Object {
    ($procNames -contains $_.Name) -or ($_.Path -and $_.Path -match '\\VMware\\VMware Tools\\')
} | ForEach-Object {
    Log "Stopping process $($_.Name) ($($_.Id))"
    Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
}

$filesToRemove = New-Object System.Collections.Generic.List[string]
foreach ($t in $targets.Values) {
    Log "Removing service '$($t.Name)' [$($t.Why)]"
    Mark 'Services' -Reboot      # kernel drivers stay loaded until the next boot
    & sc.exe delete $t.Name 2>&1 | Out-Null
    $key = Join-Path $svcRoot $t.Name
    if (Test-Path -LiteralPath $key) {
        Set-ItemProperty -LiteralPath $key -Name Start -Value 4 -ErrorAction SilentlyContinue
        Remove-RegKey $key
    }
    # Only the service's own binary, and only if VMware published it (svchost/dllhost-hosted services are skipped)
    if ($t.Image -and $t.Image -notmatch '\\VMware\\' -and (Get-CompanyName $t.Image) -match 'VMware|Broadcom') { $filesToRemove.Add($t.Image) }
}
if (-not $targets.Count) { Log 'No VMware services or drivers found' }

# --- 2e. Class filters and network provider order
# Known names are always included: if an earlier run deleted the services but stopped before this step,
# the services are gone (so not in $targets) but their filter / provider entries would still be dangling.
$removed = @(@($targets.Keys) + $knownSvc | Sort-Object -Unique)
if ($removed.Count) {
    foreach ($c in Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Control\Class' -ErrorAction SilentlyContinue) {
        foreach ($vn in 'UpperFilters', 'LowerFilters') {
            $val = (Get-ItemProperty -LiteralPath $c.PSPath -Name $vn -ErrorAction SilentlyContinue).$vn
            if (-not $val) { continue }
            $val  = @($val)
            $keep = @($val | Where-Object { $removed -notcontains $_ })
            if ($keep.Count -ne $val.Count) {
                $gone = ($val | Where-Object { $removed -contains $_ }) -join ','
                Log "Removing '$gone' from $vn on class $($c.PSChildName)"
                Mark 'Filters' -Reboot
                if ($keep.Count) { [Microsoft.Win32.Registry]::SetValue($c.Name, $vn, [string[]]$keep, [Microsoft.Win32.RegistryValueKind]::MultiString) }
                else             { Remove-ItemProperty -LiteralPath $c.PSPath -Name $vn -ErrorAction SilentlyContinue }
            }
        }
    }
    foreach ($orderKey in 'HKLM:\SYSTEM\CurrentControlSet\Control\NetworkProvider\Order',
                          'HKLM:\SYSTEM\CurrentControlSet\Control\NetworkProvider\HwOrder') {
        $po = (Get-ItemProperty -LiteralPath $orderKey -Name ProviderOrder -ErrorAction SilentlyContinue).ProviderOrder
        if (-not $po) { continue }
        $parts = $po -split ','
        $keep  = @($parts | Where-Object { $removed -notcontains $_.Trim() })
        if ($keep.Count -ne $parts.Count) {
            Set-ItemProperty -LiteralPath $orderKey -Name ProviderOrder -Value ($keep -join ',')
            Log "Cleaned ProviderOrder in $orderKey -> $($keep -join ',')"
            Mark 'Filters' -Reboot
        }
    }
}

# --- 2f. Driver store
$vmwDrivers = @($script:AllDrivers | Where-Object { $_.ProviderName -match 'VMware|Broadcom' })
if ($RemoveScope -ne 'AllVMware') {
    foreach ($d in @($vmwDrivers | Where-Object { [IO.Path]::GetFileName($_.OriginalFileName) -notmatch $toolsInfPattern })) {
        Log "Left in place (not a VMware Tools driver): $($d.Driver) $([IO.Path]::GetFileName($d.OriginalFileName)) $($d.ClassName)"
    }
    $vmwDrivers = @($vmwDrivers | Where-Object { [IO.Path]::GetFileName($_.OriginalFileName) -match $toolsInfPattern })
}
foreach ($d in $vmwDrivers) {
    Log "Deleting driver package $($d.Driver) ($([IO.Path]::GetFileName($d.OriginalFileName)), $($d.ClassName), $($d.Version))"
    $out = & pnputil.exe /delete-driver $d.Driver /uninstall /force 2>&1
    if (@(0, 3010) -notcontains $LASTEXITCODE) { $out = & pnputil.exe -f -d $d.Driver 2>&1 }
    if (@(0, 3010) -notcontains $LASTEXITCODE) { Log "pnputil could not delete $($d.Driver): $($out -join ' ')" 'WARN' }
    else { Mark 'Packages' -Reboot }
}
if (-not $vmwDrivers.Count) { Log 'No VMware driver packages in the driver store' }

# --- 2g. Files
foreach ($dir in "$env:SystemRoot\System32\drivers", "$env:SystemRoot\System32", "$env:SystemRoot\SysWOW64") {
    if (-not (Test-Path $dir)) { continue }
    Get-ChildItem -Path (Join-Path $dir '*') -File -Force -ErrorAction SilentlyContinue -Include 'vm*', 'vsock*', 'vsep*', 'vnetwfp*', 'pvscsi*' |
        Where-Object { $_.Extension -match '^\.(sys|dll|exe)$' -and (Get-CompanyName $_.FullName) -match 'VMware|Broadcom' -and ($RemoveScope -eq 'AllVMware' -or (Test-ToolsOwned $_.FullName)) } |
        ForEach-Object { $filesToRemove.Add($_.FullName) }
}
$filesToRemove | Sort-Object -Unique | ForEach-Object { Remove-PathOrSchedule $_ }

# Broadcom KB 315629 step 3: whole VMware trees (AllVMware), or only the VMware Tools parts of them
$pf86 = [Environment]::GetFolderPath('ProgramFilesX86')
if ($RemoveScope -ne 'AllVMware') {
    $folders = @("$env:ProgramFiles\VMware\VMware Tools", "$env:ProgramData\VMware\VMware Tools", "$env:ProgramData\VMware\VMware CAF",
                 "$env:ProgramData\VMware\VMware VGAuth", "$env:ProgramFiles\Common Files\VMware\Drivers",
                 "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\VMware\VMware Tools")
    foreach ($f in $folders) { Remove-PathOrSchedule $f }
    # parents only when nothing else lives there
    foreach ($par in "$env:ProgramFiles\VMware", "$env:ProgramFiles\Common Files\VMware", "$env:ProgramData\VMware", "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\VMware") {
        if ((Test-Path -LiteralPath $par) -and -not @(Get-ChildItem -LiteralPath $par -Force -ErrorAction SilentlyContinue).Count) { Remove-PathOrSchedule $par }
        elseif (Test-Path -LiteralPath $par) { Log "Kept $par (other VMware/Broadcom software lives there)" }
    }
} else {
$folders = @(
    "$env:ProgramFiles\VMware",
    "$env:ProgramFiles\Common Files\VMware",
    "$env:ProgramData\VMware",
    "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\VMware"
)
if ($pf86 -and $pf86 -ne $env:ProgramFiles) {
    $folders += "$pf86\VMware"
    $folders += "$pf86\Common Files\VMware"
}
foreach ($prof in Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -ErrorAction SilentlyContinue) {
    $profPath = (Get-ItemProperty -LiteralPath $prof.PSPath -Name ProfileImagePath -ErrorAction SilentlyContinue).ProfileImagePath
    if (-not $profPath) { continue }
    $profPath = [Environment]::ExpandEnvironmentVariables($profPath)
    $folders += "$profPath\AppData\Local\VMware"
    $folders += "$profPath\AppData\Roaming\VMware"
}
foreach ($f in $folders) { Remove-PathOrSchedule $f }
}

# --- 2h. Registry
# Broadcom KB 315629 step 6: the whole VMware, Inc. key (AllVMware), or only its VMware Tools subkeys
foreach ($base in 'HKLM:\SOFTWARE\VMware, Inc.', 'HKLM:\SOFTWARE\WOW6432Node\VMware, Inc.') {
    if ($RemoveScope -eq 'AllVMware') { Remove-RegKey $base; continue }
    foreach ($sub in 'VMware Tools', 'VMware CAF', 'VMware VGAuth', 'VMware Drivers') { Remove-RegKey (Join-Path $base $sub) }
    if ((Test-Path -LiteralPath $base) -and -not @(Get-ChildItem -LiteralPath $base -ErrorAction SilentlyContinue).Count) { Remove-RegKey $base }
}

foreach ($e in @(Get-UninstallEntries 'VMware Tools*')) { Remove-RegKey $e.PSPath }

$squashed = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($c in $productCodes) { $s = ConvertTo-SquashedGuid $c; if ($s) { [void]$squashed.Add($s) } }
foreach ($k in Get-ChildItem 'HKLM:\SOFTWARE\Classes\Installer\Products' -ErrorAction SilentlyContinue) {
    if ((Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue).ProductName -like 'VMware Tools*') { [void]$squashed.Add($k.PSChildName) }
}
foreach ($s in $squashed) {
    Remove-RegKey "HKLM:\SOFTWARE\Classes\Installer\Products\$s"
    Remove-RegKey "HKLM:\SOFTWARE\Classes\Installer\Features\$s"
    Remove-RegKey "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products\$s"
}
if ($squashed.Count) {
    foreach ($k in Get-ChildItem 'HKLM:\SOFTWARE\Classes\Installer\UpgradeCodes' -ErrorAction SilentlyContinue) {
        if (@((Get-Item -LiteralPath $k.PSPath).Property | Where-Object { $squashed.Contains($_) }).Count) { Remove-RegKey $k.PSPath }
    }
}

foreach ($run in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run') {
    $props = Get-ItemProperty -LiteralPath $run -ErrorAction SilentlyContinue
    if (-not $props) { continue }
    foreach ($n in (Get-Item -LiteralPath $run).Property) {
        if ("$n $($props.$n)" -match $(if ($RemoveScope -eq 'AllVMware') { 'VMware|vmtoolsd' } else { 'vmtoolsd|VMware Tools' })) {
            Remove-ItemProperty -LiteralPath $run -Name $n -ErrorAction SilentlyContinue
            Log "Removed Run entry '$n' from $run"
            Mark 'RegKeys'
        }
    }
}

# --- 2i. Verify
$leftSvc = @(Get-ChildItem $svcRoot -ErrorAction SilentlyContinue | Where-Object { $knownSvc -contains $_.PSChildName })
if ($leftSvc.Count) { Log ("Service keys still present (should clear after reboot): " + (($leftSvc | ForEach-Object PSChildName) -join ', ')) 'WARN' }
if (@(Get-UninstallEntries 'VMware Tools*').Count) { Fail 'VMware Tools still appears in Programs and Features' }
}

# ================================================================ Phase 3: restore NIC settings
# Runs last so the log is already written if the agent's connection drops while the address changes.
Log '=== Phase 3: restore NIC settings ==='
if (-not $nicCaptures.Count -and (Test-Path $nicJson)) {
    # Re-run after the ghosts are already gone: use what an earlier run captured
    # ForEach-Object flattens: Windows PowerShell 5.1's ConvertFrom-Json emits a JSON array as a single object
    $nicCaptures = @(Get-Content -Path $nicJson -Raw | ConvertFrom-Json | ForEach-Object { $_ })
    Log "Using $($nicCaptures.Count) NIC capture(s) saved by an earlier run"
}
if (-not $ApplyNicConfig) {
    Log 'ApplyNicConfig is off; captured settings were only logged'
} elseif (-not $nicCaptures.Count) {
    Log 'No captured NIC settings to apply'
} elseif (-not (Get-Command Set-NetIPInterface -ErrorAction SilentlyContinue)) {
    Fail 'NetTCPIP cmdlets are not available; apply the captured settings by hand'
} else {
    $adapters = Get-TargetAdapters
    foreach ($a in $adapters) { Log "Present NIC: $($a.Name) [$($a.InterfaceDescription)] MAC $($a.MacAddress)" }
    Invoke-NicRestore $nicCaptures $adapters
}

Set-PrivateProfile

# ================================================================ Phase 4: wrap-up
Write-RunSummary
$toolsLeft = [bool]@(Get-UninstallEntries 'VMware Tools*').Count
$rebootPlanned = $script:NeedsReboot -and $RebootWhenDone
Write-Result $(if ($script:Failures.Count) { 'attention' } else { 'ok' }) @{
    virtioGaps = @($gapsAfter); virtio = $script:Did.VirtIO; vmwareToolsRemoved = (-not $toolsLeft); removalSkipped = [bool]$script:SkipRemoval
    removed = @{ ghosts = $script:Did.Ghosts; services = $script:Did.Services; packages = $script:Did.Packages; files = $script:Did.Files; regKeys = $script:Did.RegKeys; filters = $script:Did.Filters }
    nics = @($script:Did.Nics); leftInPlace = @($script:LeftInPlace); products = $script:Inventory
    leftovers = @($script:Leftovers).Count; reboot = $rebootPlanned; rebootDelaySeconds = $RebootDelaySeconds
}
Log "Result: $ResultFile"
if (Test-Path (Join-Path $WorkDir "ghost-nic-config-$Stamp.txt")) {
    Log "Old NIC settings saved: $WorkDir\ghost-nic-config-$Stamp.txt"
}
if ($script:NeedsReboot) {
    if (-not $script:Failures.Count) { [DateTime]::UtcNow.Ticks | Set-Content -Path $marker }
    if ($RebootWhenDone) { Invoke-ScheduledReboot } else { Log 'A reboot is required to finish (RebootWhenDone is off)' 'WARN' }
} else {
    Log 'Reboot not needed: nothing changed that requires one'
}
Log "Full log: $LogFile"
if ($script:Failures.Count) { exit 1 } else { exit 0 }
