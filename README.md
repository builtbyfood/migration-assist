# Migration Assist

**Finishes VMware → HVM migrations in HPE Morpheus / VM Essentials: static IPs, VMware Tools removal and the full VirtIO guest tools — driven from inside Morpheus.**

A Morpheus UI plugin that wraps the native migration plans. Before a plan runs it snapshots every source NIC and checks that the VM will be reachable after cutover; while it runs it shows each VM's migration phases and the real vCenter export progress; once the new instance has finished provisioning it runs a guest script that installs the full VirtIO set, removes VMware Tools and puts the old network settings back on the new virtio NIC. One page at `https://<appliance>/plugin/migrationAssist`.

> **Status:** 0.3.0 — completed end to end on a Morpheus 9.0.2 appliance with Windows Server 2022 VMs (pre-migration checks, agent install, migration tracking, post-migration run). Linux guests and HA / multi-node appliances are not covered yet. See [Known gaps](#known-gaps).

---

## Table of contents

- [Why](#why)
- [What it does](#what-it-does)
- [How it works](#how-it-works)
- [Requirements](#requirements)
- [Install](#install)
- [Configure](#configure)
- [Use it](#use-it)
- [The guest script](#the-guest-script)
- [Pre-flight checks](#pre-flight-checks)
- [Troubleshooting](#troubleshooting)
- [Build from source](#build-from-source)
- [Repository layout](#repository-layout)
- [Known gaps](#known-gaps)
- [Security notes](#security-notes)
- [License](#license)

---

## Why

The built-in migration keeps each NIC's MAC address, which only goes so far for static-IP VMs:

- **Windows binds IP settings to the adapter's device instance, not its MAC.** The new virtio NIC is a new device ("Ethernet 2"); the old vmxnet3 becomes a hidden ghost adapter that still holds the static IP.
- **Morpheus's VirtIO injection installs boot and network drivers only.** The full guest tools suite (QEMU guest agent, balloon, serial, …) is left for later.
- **VMware Tools stays installed**, and its uninstaller often fails with MSI 1603 once the VM is off VMware.
- **The source VM's IPs vanish from Morpheus** as soon as the plan powers it off, so they have to be captured while the plan is still pending.

## What it does

| Stage | Summary |
|---|---|
| **Before migration** | Snapshots every source NIC (MAC, IP, network) while the plan is pending. Checks the plan's network mapping, DHCP and subnet fit on the destination network, that the VM is managed, the Morpheus agent is healthy and WinRM is reachable, and scans the appliance log for rejected guest logins. Writes a credential profile into one or more plans. Installs the Morpheus agent itself over WinRM when Morpheus's own push fails. |
| **During migration** | Shows the seven migration phases per VM, flags phases that stop updating, shows vCenter's live *Export OVF template* percent (Morpheus's own *Transferring Workload* stays at 0%), then follows the new instance's Provision and Startup processes. |
| **After migration** | Scans for VMware, Broadcom and Omnissa software, then runs the guest script on the migrated VM: full VirtIO set, VMware Tools removal (Tools only by default), NIC settings restored by MAC, reboot, and a final check. |

## How it works

- The plugin runs inside the Morpheus UI. It reads migration plans, processes, servers, networks and logs through the **Morpheus REST API** with its own token (OAuth `morph-api` password grant from a service-account Trust credential, refreshed automatically — no pasted token to expire).
- Credentials are Morpheus **Trust credentials**, decrypted on the appliance through the plugin API. Passwords never reach the browser; the plugin stores references only.
- Guest work goes over **WinRM** through `executeCommandOnServer` with the plan's credential profile — the same path as a Remote PowerShell task, independent of the login stored on the VM record. Files go up in base64 chunks and are SHA-256 checked inside the guest; success is judged by exit codes and markers because the call may return no output.
- The post-migration script runs as a **one-shot SYSTEM scheduled task**, because restoring the IP ends any WinRM session. The plugin polls `result.json`, follows the VM to its restored address, waits for the reboot and checks the result.
- vCenter progress comes from the vSphere SOAP API (`/sdk`, `TaskManager.recentTask`).

Full documentation (architecture, every check, script reference, API notes): [docs/migration-assist.md](docs/migration-assist.md).

## Requirements

- HPE Morpheus / VM Essentials **9.0.x** (built against plugin API 1.3.3; tested on 9.0.2).
- A **vCenter cloud managed by Morpheus**, with VMware Tools as its RPC mode; the VMs to migrate are **managed** (instances, not discovered-only).
- **WinRM (5985)** reachable from the appliance to the VMs, and **DHCP on the destination network** so the migrated VM is reachable before its static IP is restored.
- A **Morpheus service account** (a real Morpheus login, admin rights — health logs need them) stored as a Trust credential.
- A **Windows guest credential** (local administrator over WinRM) stored as a Trust credential.
- For the VirtIO installer: internet access from the migrated VM, an internal URL (setting below), or an attached virtio-win ISO.

## Install

1. Build `migration-assist-0.3.0-all.jar` ([Build from source](#build-from-source)) or download it from the releases page.
2. Upload it in **Administration › Integrations › Plugins**.
3. Open `https://<appliance>/plugin/migrationAssist`. The header shows the plugin version, the bundled script version and the API token state.

Upgrading from the earlier *Migration Prep* builds (`migrationPrep`): remove that plugin first. The plugin code changed, so settings must be entered again.

## Configure

Plugin settings (Administration › Integrations › Plugins › Migration Assist):

| Setting | Default | Purpose |
|---|---|---|
| Appliance URL | `https://127.0.0.1` | Where the plugin calls the Morpheus API (the appliance calling itself). Certificate chain and hostname checks are skipped for this call. |
| Service account credential | — | Trust credential ID (or name, or a Cypher key holding `user:password`) of a Morpheus user. Used for the plugin's own API token and for the web sign-in that downloads agent scripts. **Must be a Morpheus login, not a guest login.** |
| API token (fallback) | — | Only when no service credential works. Expires (30 days by default on 9.0); the header badge turns yellow while it is in use. |
| vCenter credential | — | Optional Trust credential for reading vCenter task progress. Empty = the source cloud's own credentials. |
| VirtIO installer URL | — | Where migrated VMs download `virtio-win-guest-tools.exe` (e.g. an internal web server). Empty = fedorapeople.org or an attached ISO. |
| Snapshot poll interval | 120 s | How often pending plans are re-snapshotted. |
| Stall threshold | 30 min | A running phase with no update for this long is flagged. |

Test the service account before saving:

```bash
curl -sk -X POST "https://<appliance>/oauth/token?grant_type=password&scope=write&client_id=morph-api" \
  --data-urlencode "username=<user>" --data-urlencode "password=<pass>"
```

An `access_token` in the reply means it works. A rejected login is not retried for 10 minutes, so the plugin cannot lock the account.

## Use it

**Before migration (plan pending)**

1. Create the migration plan in Morpheus as usual and leave it pending.
2. Tick the plan, pick the guest Trust credential and the OS, **Apply to selected plans**. For pending plans this also sets the plan's own Windows/Linux credentials; for every plan it is saved for the post-migration run.
3. Let the poller take the **NIC snapshot** (or click it). Every NIC should show an IP — this is the only record of the source IPs once the plan runs.
4. **Check connectivity + logins.** Fix what it flags: **Apply profile to VM login** for a stale VM record login, **Install agent (remote run)** for a missing agent.
5. Optional: **Scan VMware/Broadcom software** now — products other than VMware Tools uninstall best while the VM is still on VMware.
6. Run the plan from Morpheus.

**During migration** — watch the phases, the vCenter percent and the plan log; a stalled phase turns red.

**After migration**

1. Wait for **ready for post-migration run**. The plan reports complete before Morpheus finishes the new instance's Provision and Startup; the badge reads *instance still provisioning* until then.
2. **Scan** the migrated VM and choose a scope: *VMware Tools only* (default), *Tools + ticked products*, or *Everything VMware-published*.
3. **Run post-migration script** and follow the job log: upload → scheduled task → result → address switch → reboot → final check (VMTools service gone, QEMU guest agent present, WinRM answering).

Results stay on the VM in `C:\ProgramData\VMwareToVirtio\` (`result.json`, `run-*.log`).

## The guest script

`Invoke-VMwareToVirtio.ps1` 1.4.0 is bundled in the plugin and also lives in [`scripts/`](scripts/) for standalone use.

| Phase | What it does |
|---|---|
| 0. Pre-flight | 64-bit relaunch, FullLanguage, elevation and PowerShell 4+ checks; reads `run-config.json`; inventories VMware/Broadcom/Omnissa software (`Mode=Inventory` stops here). On VMware hardware it only captures the NICs and exits. |
| 1. VirtIO | Installs `virtio-win-guest-tools.exe` when anything is missing (work folder → `VirtioSource` → attached ISO → download), signature-checked. |
| 2. VMware Tools | Skipped when Phase 1 left gaps. Otherwise: selected product uninstalls, Tools MSI uninstall, ghost NIC capture and removal, then services, filters, driver packages, files and registry keys per the scope. |
| 3. NIC restore | Places each old config on a virtio NIC (pre-migration GUID → NIC map MAC → device ID → gateway probe), verifies with DAD and a gateway ping, rolls back to DHCP on failure, frees and reuses the old connection name. |
| 4. Wrap-up | Summary, `result.json`, reboot 60 s later when needed. |

**Removal scopes** — `ToolsOnly` (default) removes VMware Tools and its own drivers, services, files and registry keys, and leaves every other VMware/Broadcom/Omnissa product in place (logged). `Selected` also uninstalls the products you pick, through their own uninstallers; tamper-protected security products (Carbon Black and similar) are never uninstalled. `AllVMware` is the full Broadcom KB 315629 sweep.

**Work-folder files** — `run-config.json` (overrides: `Mode`, `RemoveScope`, `RemoveProducts`, `VirtioSource`, `RebootWhenDone`, …), `nic-map.json` (`[{MacAddress, IPAddress, Name, Source}]`), `result.json` (`status`, `failures`, `virtioGaps`, `vmwareToolsRemoved`, `nics`, `leftInPlace`, `products`, `reboot`, …).

**Standalone use**

- *Morpheus task* — PowerShell, Execute Target **Remote**, host and credentials in the task, Elevated Shell unticked; body = `scripts/Start-VMwareToVirtio.ps1`, which downloads the script from your web server and checks its SHA-256 pin before running it.
- *No network / no WinRM* — `scripts/vme-guest-run.py <domain> --nic-map <file> --wait-reboot` on the HVM host runs it through the QEMU guest agent.
- *Tests* — `pwsh -File scripts/Test-VMwareToVirtio.ps1` (170 offline checks; PowerShell 7 on Windows or Linux).

## Pre-flight checks

| Check | Level | Fix |
|---|---|---|
| No NIC snapshot / NIC without IP | warn / bad | Snapshot while the plan is pending, with VMware Tools running |
| Network not mapped / IP outside destination CIDR | bad | Fix the plan's network mapping |
| DHCP off on the destination network | warn / bad | Enable DHCP or a temporary pool, or use the QEMU guest agent runner |
| No CIDR on the destination network | info | Fill in CIDR and gateway to enable the subnet-fit check |
| Not managed by Morpheus | bad | Actions › Make Managed |
| Agent missing or silent 15+ min | warn | Install agent (remote run) |
| Guest login rejected (from appliance logs) | bad | Apply profile to VM login |
| No guest credentials on the plan | warn | Assign a credential profile |
| No 5985/5986/22 reachable | bad | Firewall / WinRM service / network profile (5986 closed is normal) |
| Phase stalled or failed | bad | Plan log; HVM host storage pools |
| Instance still provisioning / provision failed | info / bad | Wait / Operations › Activity › History |

## Troubleshooting

| Symptom | Fix |
|---|---|
| `password grant HTTP 400 … invalid_grant` in the header | The service credential is not a Morpheus login — point it at one. |
| Morpheus agent upgrade fails with `Authorization loop detected` / `InvalidGuestLogin` | The VM record's stored login is wrong: **Apply profile to VM login**, or **Install agent (remote run)**. |
| Plan stuck at *Create Destination Workloads* 0% | Check the HVM hosts' storage pools (`virsh pool-list --all`); an inactive `morpheus-images` pool blocks it (`virsh pool-build` + `pool-start`). Recreate the plan and power the source VM back on. |
| *Transferring Workload* stays at 0% | Normal — use the vCenter percent shown under the VM. |
| `/api/health/logs` returns an error page | URL-encode the pipe in `level=WARN%7CERROR`. |

More in the [full documentation](docs/migration-assist.md).

## Build from source

Same toolchain as other Morpheus plugins built against plugin API 1.3.3:

```bash
./gradlew shadowJar
# build/libs/migration-assist-0.3.0-all.jar
```

Gradle 8.10.2 wrapper, JDK 17 (Java 11 target), Shadow 7.1.2, `morpheus-plugin-gradle` 1.3.0, `morpheus-plugin-api` 1.3.3, Groovy 3.0.13. The guest script is bundled from `src/main/resources/scripts/`; keep it identical to `scripts/Invoke-VMwareToVirtio.ps1`.

## Repository layout

```
src/main/groovy/com/morpheusdata/migrationassist/
  MigrationAssistPlugin.groovy      plugin entry, settings, wiring
  MigrationAssistController.groovy  JSON routes (admin-cm)
  Page.groovy                       the single-page UI
  PlanService.groovy                plans, phases, checks, snapshots, logs
  AgentInstaller.groovy             WinRM jobs: agent install, inventory, post-migration run
  VCenterProgress.groovy            vCenter SOAP task progress
  TokenSource.groovy                self-refreshing API token
  CredentialResolver.groovy         Trust credential / Cypher resolution
  MorpheusApi.groovy                REST client
  Store.groovy                      JSON files under /var/opt/morpheus/morpheus-ui/migration-assist/
src/main/resources/scripts/         bundled guest script
scripts/                            standalone script, loader, tests, QEMU guest agent runner
docs/migration-assist.md            full documentation
```

## Known gaps

- **Windows only.** No Linux path yet (open-vm-tools removal, initramfs virtio check, netplan/nmcli re-binding).
- **Needs DHCP after migration** for the WinRM run; DHCP-less networks need the QEMU guest agent runner.
- **IPv4 settings only** are restored; NetBIOS/WINS, DNS registration flags, metrics and static IPv6 are not.
- **No leader election** — on an HA appliance cluster more than one node could run the poller.
- **Plans are run from Morpheus**, not from the plugin.
- **Simulated only so far:** vCenter progress against a real vCenter, the server address switch after the IP change, and the `Selected` / `AllVMware` scopes on VMs with other VMware products.

Roadmap: Linux support, full network settings, cloud RPC-mode check, Make Managed action, pre-flight fixes over VMware Tools guest exec, renaming the migrated VM's record, HA leader election, running plans from the plugin.

## Security notes

- All routes require the `admin-cm` permission.
- Passwords are resolved on the appliance and never sent to the page; `config.json` holds credential references only.
- The plugin calls the appliance's own API with certificate checks disabled (self-call on 127.0.0.1); vCenter calls do the same, as Morpheus does for self-signed vCenters.
- The guest script refuses to run a VirtIO installer whose Authenticode signature is invalid or not Red Hat's, and never deletes files that are not VMware-signed.
- Uploads to the guest are SHA-256 verified inside the guest before anything runs.

## License

MIT — see [LICENSE](LICENSE).
