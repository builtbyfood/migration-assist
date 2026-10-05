# Changelog

## 0.3.0 — 2026-10-05
- Post-migration run: bundled `Invoke-VMwareToVirtio.ps1` 1.4.0, uploaded with the NIC snapshot and a run config, started as a SYSTEM scheduled task; `result.json` polling, address follow, reboot wait, final check.
- Software scan (VMware / Broadcom / Omnissa) and removal scope per VM: Tools only, Tools + selected products, everything VMware-published.
- VirtIO installer URL setting.

## 0.2.8
- Readiness waits for the new instance's own Provision and Startup processes.

## 0.2.7
- Live vCenter export progress (SOAP `TaskManager.recentTask`); vCenter credential setting.
- Time limits on every WinRM call; reinstall waits for a new agent check-in; auto-refresh after jobs.

## 0.2.5 – 0.2.6
- Install agent (remote run): downloads the VM's agent script through a web session and runs it over WinRM with the plan's profile; works without WinRM output.

## 0.2.0 – 0.2.4
- Renamed from Migration Prep to Migration Assist (`migrationAssist`).
- Trust credential picker; managed and agent checks; guest-login failure detection from appliance logs; Apply profile to VM login; plugin version and service user in the header; 10-minute back-off after a rejected service login.

## 0.1.x
- Plans view with per-VM phases and stall detection; NIC snapshots for pending plans; DHCP / subnet-fit / port checks; credential profiles written into plans; plan log from `/api/health/logs`; self-refreshing API token.

## Guest script 1.4.0
- `RemoveScope` (`ToolsOnly` default, `Selected`, `AllVMware`); vendor inventory with protected products never uninstalled; Phase 2 skipped when VirtIO is incomplete; uploaded installer used first; stale connection names freed before renaming; `result.json` on every exit; `run-config.json` overrides; Broadcom publisher matching.
