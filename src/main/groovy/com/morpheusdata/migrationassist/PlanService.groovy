package com.morpheusdata.migrationassist

import groovy.util.logging.Slf4j

import java.time.Instant
import java.time.OffsetDateTime
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit

/**
 * Everything Stage 1 knows about migration plans. All field names below were verified on
 * a Morpheus 9.0.2 appliance (Oct 2026):
 *   GET /api/migrations[/{id}]   -> migration{ id,name,status,statusMessage,installGuestTools,skipPrechecks,
 *                                   windowsUsername,windowsPassword(masked),linuxUsername,linuxPassword,linuxKeyPair,
 *                                   networks[{sourceNetwork,destinationNetwork}],
 *                                   servers[{sourceServer,destinationServer,status,statusMessage}], ... }
 *   GET /api/processes?refType=migrationPlan&refId={id} -> processes[{ events[{processType.name,status,percent,
 *                                   displayName(=VM name),startDate,lastUpdated,error,output}] }]
 *   GET /api/networks/{id}       -> network{ dhcpServer,cidr,gateway,vlanId,... }
 *   GET /api/health/logs         -> {logs[{ts,level,message,hostname,objectId,...}], meta}
 * Source server interfaces lose their ipAddress once the plan powers the VM off, which is
 * why snapshots are taken while plans are pending and never overwrite a known IP with null.
 */
@Slf4j
class PlanService {

    static final List<String> PHASES = ['Migration preCheck', 'Preparing Source Workloads', 'Create Destination Workloads',
                                        'Transferring Workload', 'Reconfigure VirtIO Drivers', 'general', 'Finalize Migration']

    final Closure<MorpheusApi> api
    final Closure<Map> settings
    final Store store
    final Closure<CredentialResolver> resolverFor
    private ScheduledExecutorService exec
    volatile String lastTickError
    volatile long lastTick

    PlanService(Closure<MorpheusApi> api, Closure<Map> settings, Store store, Closure<CredentialResolver> resolverFor) {
        this.api = api; this.settings = settings; this.store = store; this.resolverFor = resolverFor
    }

    // ── background: snapshot pending plans while their source VMs still report IPs ─────────

    void start() {
        int secs = Math.max(30, asInt(settings().pollSeconds, 120))
        exec = Executors.newSingleThreadScheduledExecutor({ Runnable r -> Thread t = new Thread(r, 'migration-assist-poll'); t.daemon = true; t } as java.util.concurrent.ThreadFactory)
        exec.scheduleWithFixedDelay({ try { tick() } catch (Throwable ignored) {} } as Runnable, 15, secs, TimeUnit.SECONDS)
    }

    void stop() { try { exec?.shutdownNow() } catch (Exception ignored) {} }

    void tick() {
        try {
            plansRaw().findAll { (it.status as String) == 'pending' }.each { Map p ->
                try { snapshot(p.id as Long) } catch (Exception e) { log.debug("snapshot plan ${p.id}: ${e.message}") }
            }
            lastTickError = null
        } catch (Throwable t) {
            lastTickError = "${t.class.simpleName}: ${t.message}".toString()
        } finally {
            lastTick = System.currentTimeMillis()
        }
    }

    // ── plans ───────────────────────────────────────────────────────────────────

    List<Map> plansRaw() { api().all('/api/migrations', 'migrations') }

    Map plan(Long id) { (api().get("/api/migrations/${id}").migration ?: [:]) as Map }

    List<Map> plans() {
        plansRaw().collect { Map p ->
            List<Map> servers = (p.servers ?: []) as List<Map>
            Map counts = servers.countBy { (it.status ?: 'unknown') as String }
            Map snap = store.snapshot(p.id as Long)
            [id: p.id, name: p.name, status: p.status, statusMessage: p.statusMessage, vmCount: servers.size(), vmStatus: counts,
             sourceCloud: m(p.sourceCloud).name, targetCloud: m(p.targetCloud).name,
             windowsUsername: p.windowsUsername, linuxUsername: p.linuxUsername,
             snapshotAt: snap.updatedAt, assignment: assignmentFor(p.id as Long)]
        }.sort { -(it.id as Long) }
    }

    /** Full view of one plan: per-VM phases with stall flags, NIC snapshot and per-NIC checks. */
    Map detail(Long id) {
        Map p = plan(id)
        if (!p) return [error: "migration plan ${id} not found".toString()]
        int stallMin = Math.max(1, asInt(settings().stallMinutes, 30))
        Map<String, List<Map>> phasesByVm = phases(id, stallMin)
        Map<Long, Map> mapping = networkMapping(p)
        Map snap = store.snapshot(id)
        Map snapVms = (snap.vms ?: [:]) as Map

        List<Map> vms = ((p.servers ?: []) as List<Map>).collect { Map sv ->
            Map src = m(sv.sourceServer), dst = m(sv.destinationServer)
            Map s = m(snapVms[src.id?.toString()])
            List<Map> nics = ((s.nics ?: []) as List<Map>).collect { Map n -> n + [checks: nicChecks(n, mapping)] }
            List<Map> ph = phasesByVm[(src.name ?: '') as String] ?: []
            Map row = [sourceId: src.id, sourceName: src.name, destId: dst.id, destName: dst.name,
                       status: sv.status, statusMessage: sv.statusMessage,
                       platform: s.platform, powerState: s.powerState, snapshotAt: s.capturedAt,
                       nics: nics, phases: ph,
                       stalled: ph.any { it.stalled }, failed: ph.any { (it.status as String) == 'failed' },
                       finalized: ph.any { (it.name as String) == 'Finalize Migration' && (it.status as String) == 'complete' },
                       ports: s.ports, snapErrors: s.errors, from: s.from, afterRun: s.afterRun, managed: s.managed, agent: s.agent, recordUser: s.recordUser, auth: s.auth,
                       inventory: s.inventory, postRun: s.postRun]
            if (dst.id && row.finalized) row.instance = instanceActivity(dst)
            Map ia = m(row.instance)
            // The plan reports complete while Morpheus is still provisioning/starting the new instance
            // (e.g. "windows2-migrated - Provision ... Finalizing"); wait for that too.
            row.instanceBusy = ia.running == true
            row.readyForPostRun = row.finalized && dst.id != null && !row.instanceBusy && ia.failed != true
            row.issues = vmIssues(row, p)
            row
        }
        [plan: [id: p.id, name: p.name, status: p.status, statusMessage: p.statusMessage,
                installGuestTools: p.installGuestTools, skipPrechecks: p.skipPrechecks,
                windowsUsername: p.windowsUsername, windowsPasswordSet: (p.windowsPassword ? true : false),
                linuxUsername: p.linuxUsername, linuxPasswordSet: (p.linuxPassword ? true : false)],
         networks: mapping.values().toList(), vms: vms, stallMinutes: stallMin,
         snapshotAt: snap.updatedAt, assignment: assignmentFor(id)]
    }

    /** VM name -> ordered phase list from the newest migrationPlan process. */
    Map<String, List<Map>> phases(Long planId, int stallMin) {
        List<Map> procs = []
        try { procs = (api().get("/api/processes?refType=migrationPlan&refId=${planId}&max=20&sort=startDate&direction=desc").processes ?: []) as List<Map> }
        catch (Exception e) { log.debug("processes for plan ${planId}: ${e.message}") }
        if (!procs) return [:]
        Map proc = procs.max { parseDate(it.startDate) }
        long now = System.currentTimeMillis()
        Map<String, List<Map>> out = [:].withDefault { [] }
        ((proc.events ?: []) as List<Map>).each { Map e ->
            String vm = (e.displayName ?: '(plan)') as String
            String st = (e.status ?: '') as String
            long upd = parseDate(e.lastUpdated ?: e.startDate)
            boolean stalled = st == 'running' && upd > 0 && (now - upd) > stallMin * 60_000L
            out[vm] << [id: e.id, name: m(e.processType).name ?: e.description, status: st, percent: e.percent,
                        startDate: e.startDate, lastUpdated: e.lastUpdated, idleMinutes: upd ? ((now - upd) / 60000L) as long : null,
                        stalled: stalled, error: (e.error ?: '')?.toString()?.take(1500), output: (e.output ?: '')?.toString()?.take(1500)]
        }
        return out
    }

    /**
     * The migrated VM's own instance processes (Provision, Startup, ...) from /api/instances/{id}/history.
     * Instance id comes from the server record, else an instance name lookup.
     */
    Map instanceActivity(Map dst) {
        try {
            Long instId = null
            try {
                Map sv = (api().get("/api/servers/${dst.id}").server ?: [:]) as Map
                instId = (m(sv.instance).id ?: sv.instanceId) as Long
            } catch (Exception ignored) {}
            if (!instId && dst.name) {
                List<Map> hits = (api().get("/api/instances?max=5&name=${MorpheusApi.q(dst.name)}").instances ?: []) as List<Map>
                instId = (hits.find { (it.name as String) == (dst.name as String) }?.id) as Long
            }
            if (!instId) return [error: 'instance for the migrated VM not found']
            List<Map> procs = (api().get("/api/instances/${instId}/history?max=10&sort=startDate&direction=desc").processes ?: []) as List<Map>
            List<Map> rows = procs.sort { -parseDate(it.startDate) }.take(5).collect { Map pr ->
                String typeName = (m(pr.processType).name ?: pr.displayName ?: '') as String
                [id: pr.id, name: typeName, displayName: pr.displayName, status: pr.status, startDate: pr.startDate, endDate: pr.endDate,
                 events: ((pr.events ?: []) as List<Map>).collect { Map e -> [name: m(e.processType).name ?: e.displayName, status: e.status] }]
            }
            boolean running = rows.any { it.status in ['running', 'queued', 'pending'] }
            Map lastProv = rows.find { ((it.name ?: '') as String).toLowerCase().contains('provision') }
            return [instanceId: instId, processes: rows, running: running, failed: lastProv?.status == 'failed',
                    current: rows.find { it.status in ['running', 'queued', 'pending'] }]
        } catch (Exception e) { return [error: e.message] }
    }

    /** source network id -> [source, dest, dest network facts] */
    Map<Long, Map> networkMapping(Map p) {
        Map<Long, Map> out = [:]
        ((p.networks ?: []) as List<Map>).each { Map n ->
            Map s = m(n.sourceNetwork), d = m(n.destinationNetwork)
            if (!s.id) return
            Map facts = [:]
            if (d.id) {
                try {
                    Map net = (api().get("/api/networks/${d.id}").network ?: [:]) as Map
                    facts = [dhcpServer: net.dhcpServer, cidr: net.cidr, gateway: net.gateway, dnsPrimary: net.dnsPrimary, vlanId: net.vlanId]
                } catch (Exception e) { facts = [error: e.message] }
            }
            out[s.id as Long] = [sourceId: s.id, sourceName: s.name, destId: d.id, destName: d.name] + facts
        }
        return out
    }

    // ── checks ──────────────────────────────────────────────────────────────────

    List<Map> nicChecks(Map nic, Map<Long, Map> mapping) {
        List<Map> c = []
        String ip = (nic.ipAddress ?: '') as String
        Map m = nic.networkId ? mapping[nic.networkId as Long]
              : (nic.destNetworkId ? mapping.values().find { (it.destId as Long) == (nic.destNetworkId as Long) } : null)
        if (!ip) c << chk('warn', 'No IP recorded for this NIC. VMware Tools may not be reporting it, so the post-migration script cannot place this NIC by IP.')
        if (!m) { c << chk('bad', "Source network ${nic.networkName ?: nic.networkId ?: '?'} is not mapped in this plan."); return c }
        if (!m.destId) { c << chk('bad', "Source network ${m.sourceName} has no destination network."); return c }
        if (m.error) { c << chk('warn', "Could not read destination network ${m.destName}: ${m.error}"); return c }
        if (m.dhcpServer == true) c << chk('ok', "${m.destName}: DHCP on. The VM should get a lease after migration, so the remote run can reach it.")
        else if (ip) c << chk('warn', "${m.destName}: DHCP off. After migration this NIC has no address until the script restores it, so a remote WinRM/SSH run cannot reach it. Use the qemu-ga runner or enable DHCP / a temporary pool.")
        else c << chk('bad', "${m.destName}: DHCP off and no static IP recorded. The VM will come up with no address on this NIC.")
        if (m.cidr && ip) {
            Boolean fits = inCidr(ip, m.cidr as String)
            if (fits == true) c << chk('ok', "${ip} is inside ${m.cidr}.")
            else if (fits == false) c << chk('bad', "${ip} is NOT inside ${m.destName} (${m.cidr}). The plan may map this NIC to the wrong VLAN.")
            if (m.gateway && nic.gateway && m.gateway != nic.gateway) c << chk('warn', "Destination gateway ${m.gateway} differs from the source gateway ${nic.gateway}.")
        } else if (!m.cidr) {
            c << chk('info', "${m.destName} has no CIDR set, so the subnet-fit check is skipped. Fill in CIDR/gateway on the network to enable it.")
        }
        return c
    }

    List<Map> vmIssues(Map row, Map plan) {
        List<Map> c = []
        boolean pending = (plan.status as String) == 'pending'
        boolean haveIps = ((row.nics ?: []) as List<Map>).any { it.ipAddress }
        if (!row.nics) c << chk(pending ? 'warn' : 'bad', pending ? 'No NIC snapshot yet. Take one before running the plan.'
                : 'No NIC snapshot was taken before this plan ran; source IPs are now gone from Morpheus.')
        else if (!pending && !haveIps) c << chk('bad', 'NICs captured after the plan ran (MAC and network only). The old IPs were not snapshotted while the plan was pending.')
        Map mg = m(row.managed)
        if (pending) {
            if (mg.managed == false) c << chk('bad', "Not managed by Morpheus (${mg.why}). Requirement: convert the VM to managed before running this plan.".toString())
            else if (mg.managed == true) c << chk('ok', "Managed by Morpheus (${mg.why}).".toString())
            else if (row.nics) c << chk('warn', "Could not confirm the VM is managed by Morpheus: ${mg.why ?: 'take a snapshot'}.".toString())
        }
        Map ag = m(row.agent)
        if (pending && ag) {
            if (!ag.installed) c << chk('warn', 'Morpheus agent is not installed. Guest commands during the migration go over VMware Tools only; check the cloud RPC mode is VMware Tools.')
            else if (ag.minutesSinceSeen != null && ag.minutesSinceSeen > 15) c << chk('warn', "Morpheus agent ${ag.version ?: ''} installed but last checked in ${ag.minutesSinceSeen} min ago. Morpheus logs 'unable to execute command on unheard from server' when it is stale.".toString())
            else c << chk('ok', "Morpheus agent ${ag.version ?: ''} installed${ag.minutesSinceSeen != null ? ', checked in ' + ag.minutesSinceSeen + ' min ago' : ''}.".toString())
        }
        Map au = m(row.auth)
        List<Map> fails = (au.failures ?: []) as List<Map>
        if (fails) c << chk('bad', "Morpheus's stored guest login for this VM is being rejected: ${fails.collect { it.kind + ' x' + it.count }.join(', ')} (last ${au.last}). " +
                "WinRM and VMware Tools both use the VM record's own login${row.recordUser ? ' (' + row.recordUser + ')' : ''}, not the plan's. Use 'Apply profile to VM' to fix it.")
        else if (au.checkedAt) c << chk('ok', 'No guest-login failures for this VM in the appliance log (last 2h).')
        if (row.recordUser && plan.windowsUsername && row.platform != 'linux' && !(row.recordUser as String).equalsIgnoreCase(plan.windowsUsername as String))
            c << chk('info', "VM record login is ${row.recordUser}; the plan uses ${plan.windowsUsername}.".toString())
        ((row.snapErrors ?: []) as List).each { c << chk('warn', "Snapshot: ${it}".toString()) }
        String pf = (row.platform ?: '') as String
        if (pf == 'windows' && !plan.windowsUsername) c << chk('warn', 'Plan has no Windows credentials. Assign a credential profile.')
        if (pf == 'linux' && !plan.linuxUsername) c << chk('warn', 'Plan has no Linux credentials. Assign a credential profile.')
        Map ia = m(row.instance)
        if (row.finalized && ia.running) c << chk('info', "Migration finished; Morpheus is still running '${m(ia.current).name ?: m(ia.current).displayName}' on the new instance. The post-migration run waits for it.".toString())
        if (ia.failed) c << chk('bad', 'The provision process of the new instance failed. See Operations > Activity > History for the instance.')
        if (ia.error && row.finalized) c << chk('warn', "Could not read the new instance's activity: ${ia.error}".toString())
        if (row.stalled) c << chk('bad', "A phase has not updated in over ${asInt(settings().stallMinutes, 30)} minutes. Check the appliance log below.")
        if (row.failed) c << chk('bad', 'A migration phase failed. See the phase error.')
        Map ports = (row.ports ?: [:]) as Map
        if (ports.error) c << chk('warn', "Port check (${ports.target}): ${ports.error}".toString())
        if (ports.results) {
            List<Map> rs = ports.results as List<Map>
            if (rs.every { !it.open }) c << chk('bad', "No remote-management port reachable from the appliance (${rs.collect { it.ip + ':' + it.port }.join(', ')}).")
        }
        return c
    }

    private static Map chk(String level, String msg) { [level: level, msg: msg] }

    // ── snapshots ───────────────────────────────────────────────────────────────

    /** Capture each source VM's NICs. Merges: a NIC's known IP is never replaced by an empty one. */
    Map snapshot(Long planId) {
        Map p = plan(planId)
        if (!p) return [error: "plan ${planId} not found".toString()]
        Map snap = store.snapshot(planId) ?: [:]
        Map vms = ((snap.vms ?: [:]) as Map).collectEntries { k, v -> [(k): v] }
        List<String> errors = []
        int captured = 0
        ((p.servers ?: []) as List<Map>).each { Map sv ->
            Map src = m(sv.sourceServer), dst = m(sv.destinationServer)
            if (!src.id) return
            Map prev = m(vms[src.id.toString()])
            Map s = null, from = null
            List<String> vmErr = []
            try { s = (api().get("/api/servers/${src.id}").server ?: [:]) as Map; from = [kind: 'source', id: src.id] }
            catch (Exception e) { vmErr << "source server ${src.id}: ${e.message}".toString() }
            List<Map> ifaces = ((s?.interfaces ?: []) as List<Map>).findAll { it.macAddress }
            // After cutover the source record may be gone or bare. The migrated VM keeps the MACs, so its record
            // still gives MAC + network (the old IP is unrecoverable from Morpheus at that point).
            if (!ifaces && dst.id) {
                try {
                    Map d = (api().get("/api/servers/${dst.id}").server ?: [:]) as Map
                    ifaces = ((d.interfaces ?: []) as List<Map>).findAll { it.macAddress }.collect { it + [ipAddress: null] }
                    if (ifaces) { from = [kind: 'destination', id: dst.id]; if (!s) s = d }
                } catch (Exception e) { vmErr << "destination server ${dst.id}: ${e.message}".toString() }
            }
            if (!ifaces && !s?.interfaces) vmErr << "no interfaces with a MAC on ${from ? from.kind + ' record' : 'any record'}".toString()
            Map prevByMac = ((prev.nics ?: []) as List<Map>).collectEntries { [(norm(it.macAddress)): it] }
            List<Map> nics = ifaces.collect { Map i ->
                Map old = m(prevByMac[norm(i.macAddress)])
                Map net = m(i.network)
                [macAddress: i.macAddress, name: i.name, ipAddress: i.ipAddress ?: old.ipAddress,
                 ipFrom: i.ipAddress ? 'live' : (old.ipAddress ? (old.ipFrom == 'live' ? 'earlier snapshot' : old.ipFrom) : null),
                 networkId: (from?.kind == 'source' ? net.id : null) ?: old.networkId, networkName: (from?.kind == 'source' ? net.name : null) ?: old.networkName,
                 destNetworkId: from?.kind == 'destination' ? net.id : old.destNetworkId,
                 gateway: i.gateway ?: old.gateway, primary: i.primaryInterface]
            }
            if (nics) captured++
            vms[src.id.toString()] = [id: src.id, name: s?.name ?: src.name, platform: (s ? platformOf(s) : null) ?: prev.platform,
                                      powerState: s?.powerState, internalIp: s?.internalIp ?: prev.internalIp,
                                      nics: nics ?: prev.nics ?: [], from: from ?: prev.from,
                                      capturedAt: (nics.any { it.ipFrom == 'live' } || (nics && !prev.capturedAt)) ? Instant.now().toString() : prev.capturedAt,
                                      afterRun: (p.status as String) != 'pending' && !nics.any { it.ipFrom == 'live' },
                                      errors: vmErr, ports: prev.ports,
                                      managed: from?.kind == 'source' && s ? managedOf(s) : prev.managed,
                                      agent: from?.kind == 'source' && s ? agentOf(s) : prev.agent,
                                      recordUser: from?.kind == 'source' && s ? (s.sshUsername ?: null) : prev.recordUser]
            errors.addAll(vmErr.collect { "${src.name}: ${it}".toString() })
        }
        snap.vms = vms
        if (captured) snap.updatedAt = Instant.now().toString()
        snap.planName = p.name
        snap.lastAttempt = [at: Instant.now().toString(), errors: errors]
        store.saveSnapshot(planId, snap)
        return [ok: errors.isEmpty(), errors: errors, vms: captured]
    }

    /**
     * TCP check from the appliance (where remote tasks run from). Before migration it probes the source
     * VM's recorded IPs; once a VM has a migrated (destination) server it probes that VM's current
     * address instead, since that is what the post-migration remote run will connect to.
     */
    Map portCheck(Long planId) {
        Map p = plan(planId)
        Map snap = store.snapshot(planId) ?: [:]
        Map vms = ((snap.vms ?: [:]) as Map).collectEntries { k, v -> [(k): v] }
        ((p.servers ?: []) as List<Map>).each { Map sv ->
            Map src = m(sv.sourceServer), dst = m(sv.destinationServer)
            if (!src.id) return
            Map vm = m(vms[src.id.toString()]) ?: [id: src.id, name: src.name, nics: []]
            List<String> ips = []
            String target = 'source VM'
            if (dst.id) {
                try {
                    Map d = (api().get("/api/servers/${dst.id}").server ?: [:]) as Map
                    ips = (((d.interfaces ?: []) as List<Map>).collect { it.ipAddress as String } + [d.internalIp as String, d.externalIp as String]).findAll { it }.unique()
                    target = "migrated VM ${dst.name ?: dst.id}"
                    if (!vm.platform) vm.platform = platformOf(d)
                } catch (Exception e) { vm.ports = [checkedAt: Instant.now().toString(), target: "migrated VM ${dst.id}", error: e.message, results: []]; vms[src.id.toString()] = vm; return }
            } else {
                ips = (((vm.nics ?: []) as List<Map>).collect { it.ipAddress as String } + [vm.internalIp as String]).findAll { it }.unique()
            }
            List<Integer> ports = vm.platform == 'windows' ? [5985, 5986] : (vm.platform == 'linux' ? [22] : [5985, 5986, 22])
            List<Map> res = []
            ips.each { ip -> ports.each { port -> res << [ip: ip, port: port] + tcp(ip, port) } }
            vm.ports = [checkedAt: Instant.now().toString(), target: target,
                        error: ips ? null : "no IP known for the ${target}".toString(), results: res]
            vms[src.id.toString()] = vm
        }
        try { authScan(p, vms) } catch (Exception e) { log.debug("auth scan: ${e.message}") }
        snap.vms = vms
        store.saveSnapshot(planId, snap)
        return [ok: true]
    }

    static String threadOf(String msg) {
        if (!msg?.startsWith('[')) return null
        int e = msg.indexOf(']')
        return e > 1 ? msg.substring(1, e) : null
    }

    static final Map<String, String> AUTH_PATTERNS = [
        'InvalidGuestLogin'                     : 'VMware Tools guest login rejected',
        'WinRMAuthorizationError'               : 'WinRM login rejected',
        'Invalid credentials or incompatible'   : 'WinRM login rejected',
        'Authentication failed'                 : 'SSH login rejected',
        'Auth fail'                             : 'SSH login rejected',
    ]

    /**
     * Morpheus logs guest-login failures with the VM's IP or name but never surfaces them on the VM.
     * Look back 2h for ERROR lines naming each VM and matching a known auth failure.
     */
    private void authScan(Map plan, Map vms) {
        String start = Instant.ofEpochMilli(System.currentTimeMillis() - 7_200_000L).toString()
        List<Map> rows = api().all("/api/health/logs?level=${MorpheusApi.q('INFO|WARN|ERROR')}&startDate=${MorpheusApi.q(start)}", 'logs', 200, 5000)
        ((plan.servers ?: []) as List<Map>).each { Map sv ->
            Map src = m(sv.sourceServer), dst = m(sv.destinationServer)
            Map vm = m(vms[src.id?.toString()])
            if (!vm) return
            Set<String> keys = ([src.name, dst.name] + ((vm.nics ?: []) as List<Map>).collect { it.ipAddress } +
                                ((m(vm.ports).results ?: []) as List<Map>).collect { it.ip }).findAll { it }.collect { it.toString() } as Set
            Map<String, Integer> kinds = [:].withDefault { 0 }
            String last = null
            // VMware Tools failures ("InvalidGuestLogin") don't name the VM. Morpheus logs the VM's address on the
            // same worker thread just before (e.g. "[appJobNormal-2] win agent attributes: [... winrmAddress:...]"),
            // so lines on a thread that named this VM within the previous 10 minutes count too.
            Map<String, Long> threadSeen = [:]
            rows.sort { parseDate(it.ts) }.each { Map l ->
                String msg = (l.message ?: '') as String
                String thread = threadOf(msg)
                long t = parseDate(l.ts)
                boolean names = keys.any { msg.contains(it) } || msg.contains('server ' + src.id + ' ')
                if (names && thread) threadSeen[thread] = t
                boolean viaThread = !names && thread && threadSeen[thread] && (t - threadSeen[thread]) <= 600_000L
                if (!names && !viaThread) return
                AUTH_PATTERNS.each { pat, label -> if (msg.contains(pat)) { kinds[label] = kinds[label] + 1; if (!last || (l.ts as String) > last) last = l.ts as String } }
            }
            vm.auth = [checkedAt: Instant.now().toString(), failures: kinds.collect { k, v -> [kind: k, count: v] }, last: last]
        }
    }

    /**
     * Fix action: write the plan's credential profile into the VM record's own guest login
     * (server.sshUsername/sshPassword), which is what Morpheus uses for WinRM and VMware Tools guest exec.
     */
    Map applyProfileToVm(Long planId, Long serverId) {
        Map p = plan(planId)
        String os = 'windows'
        Map snapVm = m(m(store.snapshot(planId).vms)[serverId?.toString()])
        if (snapVm.platform == 'linux') os = 'linux'
        Map a = assignmentFor(planId).find { it.os == os } as Map
        if (!a) return [error: "no ${os} credential profile assigned to this plan".toString()]
        Map c = resolverFor(a.credentialRef as String).resolve()
        if (c.error) return [error: c.error]
        if (!((p.servers ?: []) as List<Map>).any { m(it.sourceServer).id as Long == serverId || m(it.destinationServer).id as Long == serverId })
            return [error: "server ${serverId} is not in plan ${planId}".toString()]
        api().put("/api/servers/${serverId}", [server: [sshUsername: c.username, sshPassword: c.password]])
        return [ok: true, username: c.username, serverId: serverId]
    }

    private static Map tcp(String ip, int port) {
        long t = System.currentTimeMillis()
        Socket s = new Socket()
        try { s.connect(new InetSocketAddress(ip, port), 3000); return [open: true, ms: System.currentTimeMillis() - t] }
        catch (Exception e) { return [open: false, error: e.class.simpleName + (e.message ? ': ' + e.message : '')] }
        finally { try { s.close() } catch (Exception ignored) {} }
    }

    /** Persist a per-VM result (inventory, postRun) into the plan's snapshot file. */
    synchronized void saveVmExtra(Long planId, Object sourceId, String key, Object value) {
        Map snap = store.snapshot(planId) ?: [:]
        Map vms = ((snap.vms ?: [:]) as Map).collectEntries { k, v -> [(k): v] }
        Map vm = m(vms[sourceId.toString()]) ?: [id: sourceId]
        vm[key] = value
        vms[sourceId.toString()] = vm
        snap.vms = vms
        store.saveSnapshot(planId, snap)
    }

    /** NIC map for the script (nic-map.json) from the pre-migration snapshot. */
    List<Map> nicMapFor(Long planId, Object sourceId) {
        Map vm = m(m(store.snapshot(planId).vms)[sourceId.toString()])
        ((vm.nics ?: []) as List<Map>).findAll { it.macAddress }.collect {
            [MacAddress: it.macAddress, IPAddress: it.ipAddress ?: '', Name: it.name ?: '', Source: "Migration Assist snapshot ${vm.capturedAt ?: ''}".toString()]
        }
    }

    // ── credentials ─────────────────────────────────────────────────────────────

    List<Map> assignmentFor(Long planId) {
        ((store.config().assignments ?: []) as List<Map>).findAll { (it.planId as Long) == planId }
    }

    /**
     * Resolve a Trust credential server-side and write it into each plan's
     * windowsUsername/windowsPassword (or linux*). Only pending plans are changed.
     */
    Map assign(String ref, String os, List<Long> planIds) {
        if (!ref) return [error: 'credential reference is required']
        if (!(os in ['windows', 'linux'])) return [error: 'os must be windows or linux']
        Map c = resolverFor(ref).resolve()
        if (c.error) return [error: c.error]
        if (!c.username || !(c.password || c.privateKey)) return [error: "credential ${ref} has no username/password"]
        List<Map> results = []
        Map cfg = store.config()
        List<Map> asg = ((cfg.assignments ?: []) as List<Map>).findAll { !((it.planId as Long) in planIds && it.os == os) }
        planIds.each { Long id ->
            try {
                Map p = plan(id)
                if (!p) { results << [planId: id, ok: false, error: 'plan not found']; return }
                // The profile is always kept for this plan: Stage 2's post-migration remote run uses it.
                asg << [planId: id, os: os, credentialRef: ref, username: c.username, assignedAt: Instant.now().toString()]
                if ((p.status as String) == 'pending') {
                    Map body = os == 'windows' ? [windowsUsername: c.username, windowsPassword: c.password]
                                               : [linuxUsername: c.username, linuxPassword: c.password]
                    api().put("/api/migrations/${id}", [migration: body])
                    results << [planId: id, ok: true, note: 'saved and written into the plan']
                } else {
                    results << [planId: id, ok: true, note: "saved for the post-migration run (plan is ${p.status}, so its own credentials were not changed)".toString()]
                }
            } catch (Exception e) { results << [planId: id, ok: false, error: e.message] }
        }
        cfg.assignments = asg
        store.saveConfig(cfg)
        return [results: results, username: c.username]
    }

    /** Trust credentials for the picker. Passwords come back masked from REST; only ids/names/usernames are used here. */
    List<Map> credentials() {
        Map r = api().get('/api/credentials?max=500')
        List<Map> rows = (r.credentials ?: r.accountCredentials ?: []) as List<Map>
        rows.findAll { it.enabled != false }.collect { Map c ->
            [id: c.id, name: c.name, type: m(c.type).name ?: m(c.type).code ?: (c.type instanceof String ? c.type : null),
             typeCode: m(c.type).code, username: c.username]
        }.sort { (it.name ?: '').toString().toLowerCase() }
    }

    // ── logs ────────────────────────────────────────────────────────────────────

    /** Appliance log lines for a plan's run window, filtered to its VM names/IPs unless all=true. */
    Map logs(Long planId, String level, boolean all, int maxRows) {
        Map p = plan(planId)
        Map snap = store.snapshot(planId)
        List<Map> procs = []
        try { procs = (api().get("/api/processes?refType=migrationPlan&refId=${planId}&max=5&sort=startDate&direction=desc").processes ?: []) as List<Map> } catch (Exception ignored) {}
        Map proc = procs ? procs.max { parseDate(it.startDate) } : null
        long since = proc ? parseDate(proc.startDate) : System.currentTimeMillis() - 3_600_000L
        long until = proc && proc.endDate ? parseDate(proc.endDate) + 300_000L : 0L
        String start = Instant.ofEpochMilli(since - 120_000L).toString()
        String end = until ? Instant.ofEpochMilli(until).toString() : null
        Set<String> terms = [] as Set
        if (p.name && (p.name as String).length() > 2) terms << (p.name as String)
        ((p.servers ?: []) as List<Map>).each { Map sv ->
            ['sourceServer', 'destinationServer'].each { k -> String n = m(sv[k]).name as String; if (n) terms << n }
        }
        ((snap.vms ?: [:]) as Map).values().each { Map vm -> ((vm.nics ?: []) as List<Map>).each { if (it.ipAddress) terms << (it.ipAddress as String) } }
        String lv = level ?: 'WARN|ERROR'
        List<Map> rows = api().all("/api/health/logs?level=${MorpheusApi.q(lv)}&startDate=${MorpheusApi.q(start)}" +
                (end ? "&endDate=${MorpheusApi.q(end)}" : ''), 'logs', 200, all ? Math.max(200, maxRows) : 5000)
        List<String> lower = terms.collect { it.toLowerCase() }
        List<Map> hits = rows.findAll { Map l -> all || lower.any { t -> ((l.message ?: '') as String).toLowerCase().contains(t) } }
        [since: start, until: end, terms: terms.toList(), scanned: rows.size(),
         rows: hits.take(maxRows).collect { [ts: it.ts, level: it.level, host: it.hostname, message: ((it.message ?: '') as String).take(4000)] }]
    }

    // ── helpers ─────────────────────────────────────────────────────────────────

    static String platformOf(Map s) {
        List<String> hints = [m(s.serverOs).platform, m(s.serverOs).name, m(s.osType).platform, m(s.osType).code,
                              s.osType instanceof String ? s.osType : null, s.platform instanceof String ? s.platform : null,
                              m(s.computeServerType).code, s.serverType instanceof String ? s.serverType : null]
                .findAll { it }.collect { it.toString().toLowerCase() }
        if (hints.any { it.contains('windows') }) return 'windows'
        if (hints) return 'linux'
        return null
    }

    /**
     * Is this VMware VM managed by Morpheus (an instance), or only discovered? Morpheus exposes this in
     * several places depending on version/view (the /api/servers list view on 9.0 returns managed=null),
     * so every signal is checked and the deciding one is reported.
     */
    static Map managedOf(Map s) {
        Map t = m(s.computeServerType)
        String code = ((t.code ?: '') as String).toLowerCase()
        def inst = s.instance ?: s.instanceId ?: (s.containers instanceof List && s.containers ? s.containers : null)
        if (s.managed == false) return [managed: false, why: 'server.managed = false']
        if (code.contains('unmanaged')) return [managed: false, why: "server type ${t.code}".toString()]
        if (t.managed == false && !inst) return [managed: false, why: "server type ${t.code ?: t.name} is not a managed type".toString()]
        if (s.managed == true) return [managed: true, why: 'server.managed = true']
        if (inst) return [managed: true, why: 'linked to a Morpheus instance']
        if (t.managed == true) return [managed: true, why: "server type ${t.code ?: t.name} is managed".toString()]
        return [managed: null, why: "no managed signal on the record (managed=${s.managed}, type=${t.code}, instance=${inst ? 'yes' : 'none'})".toString()]
    }

    /** Morpheus agent state from a server record: installed, version, and how long since it last checked in. */
    static Map agentOf(Map s) {
        long last = parseDate(s.lastAgentUpdate)
        [installed: s.agentInstalled == true, version: s.agentVersion,
         lastSeen: s.lastAgentUpdate, minutesSinceSeen: last ? ((System.currentTimeMillis() - last) / 60000L) as long : null,
         status: s.status]
    }

    /** Value as a Map, or [:] when it is null / a String / anything else. */
    static Map m(Object v) { v instanceof Map ? (v as Map) : [:] }

    static String norm(Object mac) { (mac ?: '').toString().toLowerCase().replaceAll('[^0-9a-f]', '') }

    static Boolean inCidr(String ip, String cidr) {
        try {
            String[] parts = cidr.split('/')
            int bits = parts.length > 1 ? parts[1] as int : 32
            long mask = bits == 0 ? 0L : (0xFFFFFFFFL << (32 - bits)) & 0xFFFFFFFFL
            return (v4(ip) & mask) == (v4(parts[0]) & mask)
        } catch (Exception e) { return null }
    }

    private static long v4(String ip) {
        List<Integer> o = ip.trim().tokenize('.').collect { it as int }
        if (o.size() != 4) throw new IllegalArgumentException(ip)
        (o[0] * 16777216L) + (o[1] * 65536L) + (o[2] * 256L) + o[3]
    }

    static long parseDate(Object d) {
        if (!d) return 0L
        String s = d.toString()
        try { return Instant.parse(s).toEpochMilli() } catch (Exception ignored) {}
        // health logs use +0000 (no colon)
        String fixed = s.replaceFirst('([+-][0-9]{2})([0-9]{2})$', '$1:$2')
        try { return OffsetDateTime.parse(fixed).toInstant().toEpochMilli() } catch (Exception ignored) { return 0L }
    }

    static int asInt(Object v, int dflt) {
        try { return v == null || v.toString().trim() == '' ? dflt : (v.toString().trim() as int) } catch (Exception e) { return dflt }
    }
}
