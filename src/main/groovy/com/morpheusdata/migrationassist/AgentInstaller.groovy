package com.morpheusdata.migrationassist

import com.morpheusdata.core.MorpheusContext
import groovy.util.logging.Slf4j

import java.net.http.HttpClient
import java.net.http.HttpRequest
import java.net.http.HttpResponse
import java.security.MessageDigest
import java.time.Duration
import java.time.Instant
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

/**
 * Installs the Morpheus agent on a VM without Morpheus's own push (which uses the VM record's stored login):
 *
 *  1. Download the VM-specific installer from the UI route /infrastructure/servers/{id}/download-agent-script
 *     (the same file as the "Download Agent Script" button). UI routes need a web session, not an API token,
 *     so the plugin signs in as the service account: GET /login/auth, then POST /login/process with _csrf.
 *  2. Push it to the guest over WinRM with the plan's credential profile, via
 *     morpheus.executeCommandOnServer(server, cmd, rpc=true, user, pass, ...) - the same RPC path a Remote
 *     PowerShell task uses. The script goes over in base64 chunks (WinRM command-length limits), and the
 *     guest-side SHA-256 is checked before it runs.
 *  3. Run it elevated-by-WinRM with -ExecutionPolicy Bypass and return its output.
 *
 * Runs as a background job; the page polls job status.
 */
@Slf4j
class AgentInstaller {

    static final String GUEST_DIR = 'C:/ProgramData/MigrationAssist'
    static final int CHUNK = 3000

    final MorpheusContext morpheus
    final Closure<Map> settings
    final Closure<CredentialResolver> resolverFor
    Closure<MorpheusApi> api
    final Map<String, Map> jobs = new ConcurrentHashMap<>()
    private final def rpcPool = Executors.newCachedThreadPool({ Runnable r -> Thread t = new Thread(r, 'migration-assist-rpc'); t.daemon = true; t } as java.util.concurrent.ThreadFactory)
    private final def pool = Executors.newFixedThreadPool(2, { Runnable r -> Thread t = new Thread(r, 'migration-assist-agent'); t.daemon = true; t } as java.util.concurrent.ThreadFactory)

    AgentInstaller(MorpheusContext morpheus, Closure<Map> settings, Closure<CredentialResolver> resolverFor) {
        this.morpheus = morpheus; this.settings = settings; this.resolverFor = resolverFor
    }

    void stop() { try { pool.shutdownNow(); rpcPool.shutdownNow() } catch (Exception ignored) {} }

    Map start(Long serverId, String credentialRef, String serverName) {
        String id = "agent-${serverId}-${System.currentTimeMillis()}".toString()
        Map job = [id: id, serverId: serverId, serverName: serverName, state: 'running', startedAt: Instant.now().toString(), steps: []]
        jobs[id] = job
        pool.submit({ execute(job, credentialRef) } as Runnable)
        return [jobId: id]
    }

    Map status(String id) { jobs[id] ?: [error: 'unknown job'] }

    // ── Stage 2: Invoke-VMwareToVirtio (bundled in the plugin) ──────────────────────────────

    static final String WORK_DIR = 'C:/ProgramData/VMwareToVirtio'
    static final String TASK_NAME = 'MigrationAssistPostRun'
    Closure<Void> onResult   // (planId, sourceId, key, value) -> persisted by PlanService

    static byte[] bundledScript() {
        InputStream ins = AgentInstaller.getResourceAsStream('/scripts/Invoke-VMwareToVirtio.ps1')
        if (!ins) throw new IllegalStateException('Invoke-VMwareToVirtio.ps1 is not bundled in this plugin build')
        try { return ins.bytes } finally { ins.close() }
    }

    static String bundledScriptVersion() {
        try { def m = new String(bundledScript(), 'UTF-8') =~ ('[$]ScriptVersion = ' + "'" + '([^' + "'" + ']+)' + "'"); return m.find() ? m.group(1) : null } catch (Exception e) { return null }
    }

    Map startJob(String kind, Map ctx) {
        String id = "${kind}-${ctx.serverId}-${System.currentTimeMillis()}".toString()
        Map job = [id: id, kind: kind, serverId: ctx.serverId, serverName: ctx.serverName, state: 'running', startedAt: Instant.now().toString(), steps: []]
        jobs[id] = job
        pool.submit({
            try {
                if (kind == 'inventory') runInventory(job, ctx) else runPostMigration(job, ctx)
            } catch (Throwable t) {
                job.state = 'failed'; job.error = "${t.class.simpleName}: ${t.message}".toString(); step(job, "failed: ${job.error}")
            } finally { job.finishedAt = Instant.now().toString() }
        } as Runnable)
        return [jobId: id]
    }

    /** Upload bytes to a guest path in base64 chunks and verify the SHA-256 inside the guest (exit 3 on mismatch). */
    protected void uploadFile(Map job, def server, Map guest, String guestPath, byte[] bytes) {
        String sha = sha256(bytes)
        String b64 = bytes.encodeBase64().toString()
        String dir = guestPath.substring(0, guestPath.lastIndexOf('/'))
        rpc(server, guest, "New-Item -ItemType Directory -Force -Path '${dir}' | Out-Null; Remove-Item -Force -ErrorAction SilentlyContinue '${guestPath}.b64'; Write-Output 'ok'", 'prepare ' + guestPath)
        for (int i = 0; i < b64.length(); i += CHUNK) {
            rpc(server, guest, "Add-Content -NoNewline -Path '${guestPath}.b64' -Value '${b64.substring(i, Math.min(b64.length(), i + CHUNK))}'; Write-Output 'ok'", null)
        }
        rpc(server, guest, "[IO.File]::WriteAllBytes('${guestPath}', [Convert]::FromBase64String([IO.File]::ReadAllText('${guestPath}.b64'))); Remove-Item -Force '${guestPath}.b64'; Write-Output 'ok'", 'decode ' + guestPath)
        Map v = rpc(server, guest, "if ((Get-FileHash -Algorithm SHA256 '${guestPath}').Hash.ToLower() -eq '${sha}') { Write-Output 'MA-HASH-OK' } else { Write-Output 'MA-HASH-BAD'; exit 3 }", 'verify ' + guestPath, true)
        if (!v.success || ((v.output ?: '') as String).contains('MA-HASH-BAD')) throw new IllegalStateException("upload of ${guestPath} did not verify in the guest")
        step(job, "uploaded ${guestPath.substring(guestPath.lastIndexOf('/') + 1)} (${bytes.length} bytes, SHA-256 verified)")
    }

    protected Map readResult(def server, Map guest) {
        Map r = rpc(server, guest, "if (Test-Path '${WORK_DIR}/result.json') { Get-Content -Raw '${WORK_DIR}/result.json'; exit 0 } else { Write-Output 'MA-NO-RESULT'; exit 4 }", 'read result', true, 60)
        String out = ((r.output ?: '') as String).trim()
        if (r.success && out.startsWith('{')) {
            try { return [found: true, data: new groovy.json.JsonSlurper().parseText(out)] } catch (Exception ignored) {}
        }
        if (r.success) {
            // result exists but no output came back: get the status through exit codes
            Map ok = rpc(server, guest, "if ((Get-Content -Raw '${WORK_DIR}/result.json' | ConvertFrom-Json).status -eq 'ok') { exit 0 } else { exit 2 }", 'result status', true, 60)
            return [found: true, data: [status: ok.success ? 'ok' : 'attention', note: 'details not returned over WinRM; see result.json in the guest']]
        }
        if (out.contains('MA-NO-RESULT') || r.exitCode?.toString() == '4') return [found: false, reachable: true]
        return [found: false, reachable: false, error: r.error ?: r.msg]
    }

    /** Mode=Inventory: list VMware/Broadcom/Omnissa software (works on VMware before migration too). */
    protected void runInventory(Map job, Map ctx) {
        Map guest = guestLogin(job, ctx.credentialRef as String)
        def server = loadServer(ctx.serverId as Long)
        if (!server) throw new IllegalStateException("server ${ctx.serverId} not found")
        step(job, "target: ${server.name} (${server.internalIp ?: server.sshHost ?: '?'})")
        uploadFile(job, server, guest, "${WORK_DIR}/Invoke-VMwareToVirtio.ps1", bundledScript())
        uploadFile(job, server, guest, "${WORK_DIR}/run-config.json", groovy.json.JsonOutput.toJson([Mode: 'Inventory']).getBytes('UTF-8'))
        rpc(server, guest, "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File '${WORK_DIR}/Invoke-VMwareToVirtio.ps1' | Out-Null; Write-Output 'MA-DONE'", 'inventory', true, 300)
        rpc(server, guest, "Remove-Item -Force -ErrorAction SilentlyContinue '${WORK_DIR}/run-config.json'; Write-Output 'ok'", 'cleanup', true, 60)
        Map res = readResult(server, guest)
        List products = (res.data instanceof Map ? ((res.data as Map).products ?: []) : []) as List
        job.inventory = products
        if (onResult) onResult(ctx.planId, ctx.sourceId, 'inventory', [at: Instant.now().toString(), serverId: ctx.serverId, products: products, note: (res.data as Map)?.note])
        job.state = res.found ? 'done' : 'failed'
        step(job, res.found ? "found ${products.size()} VMware/Broadcom/Omnissa product(s)${(res.data as Map)?.note ? ' (' + (res.data as Map).note + ')' : ''}" : "no result.json came back: ${res.error ?: 'unknown'}")
    }

    /**
     * The post-migration run on the migrated VM. The script changes the VM's IP in Phase 3, which ends any
     * WinRM session, so it runs detached as a one-shot SYSTEM scheduled task; the plugin then polls
     * result.json, switching the server record's address to the restored IP when the old one stops answering.
     */
    protected void runPostMigration(Map job, Map ctx) {
        Map guest = guestLogin(job, ctx.credentialRef as String)
        Long sid = ctx.serverId as Long
        def server = loadServer(sid)
        if (!server) throw new IllegalStateException("server ${sid} not found")
        String host0 = (server.sshHost ?: server.internalIp ?: '') as String
        step(job, "target: ${server.name} at ${host0 ?: '?'}; scope ${ctx.scope}${ctx.products ? ', uninstall: ' + (ctx.products as List).join(', ') : ''}")

        uploadFile(job, server, guest, "${WORK_DIR}/Invoke-VMwareToVirtio.ps1", bundledScript())
        List nicMap = (ctx.nicMap ?: []) as List
        if (nicMap) uploadFile(job, server, guest, "${WORK_DIR}/nic-map.json", groovy.json.JsonOutput.toJson(nicMap).getBytes('UTF-8'))
        else step(job, 'no NIC map from a snapshot; the script falls back to its own matching')
        Map cfg = [Mode: 'Run', RemoveScope: ctx.scope ?: 'ToolsOnly', RemoveProducts: ctx.products ?: [], RebootWhenDone: true]
        if (ctx.virtioUrl) cfg.VirtioSource = ctx.virtioUrl
        uploadFile(job, server, guest, "${WORK_DIR}/run-config.json", groovy.json.JsonOutput.toJson(cfg).getBytes('UTF-8'))

        Map started = rpc(server, guest,
            "Remove-Item -Force -ErrorAction SilentlyContinue '${WORK_DIR}/result.json'; " +
            "Register-ScheduledTask -TaskName '${TASK_NAME}' -Force -User 'SYSTEM' -RunLevel Highest " +
            "-Action (New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File C:\\ProgramData\\VMwareToVirtio\\Invoke-VMwareToVirtio.ps1') | Out-Null; " +
            "Start-ScheduledTask -TaskName '${TASK_NAME}'; Write-Output 'MA-STARTED'", 'start script')
        step(job, 'script started in the guest as a SYSTEM scheduled task')

        // poll for result.json; follow the address change
        List<String> candidates = (nicMap.collect { it.IPAddress as String } + [host0]).findAll { it }.unique()
        long until = System.currentTimeMillis() + 45 * 60_000L
        int misses = 0
        Map result = null
        String host = host0
        while (System.currentTimeMillis() < until) {
            sleep 15_000
            Map r = readResult(server, guest)
            if (r.found) { result = r.data as Map; break }
            if (r.reachable) { misses = 0; continue }
            misses++
            if (misses >= 2) {
                String alt = candidates.find { it != host && tcpOpen(it, 5985) }
                if (alt) {
                    step(job, "${host} stopped answering; ${alt}:5985 is open, pointing the server record there")
                    try { api().put("/api/servers/${sid}", [server: [sshHost: alt, internalIp: alt]]) } catch (Exception e) { step(job, "could not update the server address: ${e.message}") }
                    server = loadServer(sid) ?: server
                    host = alt; misses = 0
                }
            }
        }
        if (!result) throw new IllegalStateException('no result.json after 45 minutes; check the run log in ' + WORK_DIR + ' on the VM console')
        job.result = result
        if (onResult) onResult(ctx.planId, ctx.sourceId, 'postRun', [at: Instant.now().toString(), serverId: sid, result: result])
        step(job, "script finished: ${result.status}${result.failures ? ' - ' + (result.failures as List).join('; ') : ''}")
        ((result.nics ?: []) as List).each { step(job, "  NIC: ${it}") }
        if (result.leftInPlace) step(job, "  left in place: ${(result.leftInPlace as List).join(', ')}")

        // reboot, then the final check
        if (result.reboot) {
            step(job, "waiting for the scheduled reboot (${result.rebootDelaySeconds ?: 60}s)")
            boolean wentDown = waitPort(host, false, 600), cameUp = wentDown && waitPort(host, true, 900)
            if (!cameUp) {
                String alt = candidates.find { tcpOpen(it, 5985) }
                if (alt && alt != host) { try { api().put("/api/servers/${sid}", [server: [sshHost: alt, internalIp: alt]]) } catch (Exception ignored) {}; host = alt; server = loadServer(sid) ?: server; cameUp = true }
            }
            step(job, cameUp ? "back up at ${host}" : 'VM did not come back on WinRM within 25 minutes; check the console')
            if (!cameUp) { job.state = 'done-unconfirmed'; return }
        }
        Map fin = rpc(server, guest, "if (Get-Service -Name 'VMTools' -ErrorAction SilentlyContinue) { Write-Output 'MA-VMTOOLS-PRESENT'; exit 5 }; " +
                                     "if (-not (Get-Service -Name 'QEMU-GA' -ErrorAction SilentlyContinue)) { Write-Output 'MA-NO-QEMUGA'; exit 6 }; Write-Output 'MA-FINAL-OK'", 'final check', true, 120)
        String fo = (fin.output ?: '') as String
        boolean ok = fin.success
        step(job, ok ? "final check on ${host}: VMware Tools service gone, QEMU guest agent present, WinRM answering"
                     : "final check on ${host}: ${fo.contains('MA-VMTOOLS-PRESENT') ? 'VMTools service still present' : fo.contains('MA-NO-QEMUGA') ? 'QEMU guest agent missing' : (fin.error ?: 'failed')}")
        try { rpc(server, guest, "Unregister-ScheduledTask -TaskName '${TASK_NAME}' -Confirm:0 -ErrorAction SilentlyContinue; Write-Output 'ok'", 'cleanup', true, 60) } catch (Exception ignored) {}
        job.state = (ok && result.status == 'ok') ? 'done' : 'attention'
    }

    protected Map guestLogin(Map job, String ref) {
        Map g = resolverFor(ref).resolve()
        if (g.error || !g.username || !g.password) throw new IllegalStateException("guest credential ${ref}: ${g.error ?: 'no username/password'}")
        step(job, "guest login: ${g.username} (credential ${ref})")
        return g
    }

    static boolean tcpOpen(String ip, int port) {
        Socket s = new Socket()
        try { s.connect(new InetSocketAddress(ip, port), 3000); return true } catch (Exception e) { return false } finally { try { s.close() } catch (Exception ignored) {} }
    }

    static boolean waitPort(String ip, boolean open, int seconds) {
        long until = System.currentTimeMillis() + seconds * 1000L
        while (System.currentTimeMillis() < until) { if (tcpOpen(ip, 5985) == open) return true; sleep 10_000 }
        return false
    }

    protected void step(Map job, String msg) { (job.steps as List) << [at: Instant.now().toString(), msg: msg]; log.info("migration-assist agent ${job.serverId}: ${msg}") }

    protected void execute(Map job, String credentialRef) {
        try {
            Long sid = job.serverId as Long
            // 1. guest credentials (profile)
            Map guest = resolverFor(credentialRef).resolve()
            if (guest.error || !guest.username || !guest.password) throw new IllegalStateException("guest credential ${credentialRef}: ${guest.error ?: 'no username/password'}")
            step(job, "guest login: ${guest.username} (credential ${credentialRef})")

            // 2. download the VM-specific agent script as the service account
            String script = downloadScript(sid)
            byte[] bytes = script.getBytes('UTF-8')
            String sha = sha256(bytes)
            step(job, "downloaded agent script: ${bytes.length} bytes, sha256 ${sha.take(16)}...")

            // 3. the ComputeServer the RPC call targets
            def server = loadServer(sid)
            if (!server) throw new IllegalStateException("server ${sid} not found through the plugin API")
            step(job, "target: ${server.name} (${server.internalIp ?: server.externalIp ?: server.sshHost ?: 'no IP on record'})")

            Map before = [:]
            try { before = (api().get("/api/servers/${sid}").server ?: [:]) as Map } catch (Exception ignored) {}
            job.agentBefore = before.lastAgentUpdate
            if (before.agentInstalled == true) step(job, "agent ${before.agentVersion ?: ''} is already installed (last check-in ${before.lastAgentUpdate ?: '?'}); reinstalling")

            // 4. what kind of shell Morpheus gives us, and whether it returns output at all
            Map probe = rpc(server, guest, "Write-Output 'MA-PS-OK'", 'probe')
            String po = (probe.output ?: '') as String
            boolean outputs = po.trim() as boolean
            step(job, outputs ? (po.contains('MA-PS-OK') ? 'remote shell: PowerShell, output returned' : "remote shell returned unexpected output: ${po.trim().take(200)}")
                              : 'remote shell returns no output; checks will use exit codes and markers only')

            // 5. push in chunks (no PowerShell variables anywhere: nothing for a wrapper to expand)
            String b64 = bytes.encodeBase64().toString()
            rpc(server, guest, "New-Item -ItemType Directory -Force -Path '${GUEST_DIR}' | Out-Null; Remove-Item -Force -ErrorAction SilentlyContinue '${GUEST_DIR}/agent.b64','${GUEST_DIR}/install-agent.ps1'; Write-Output 'ok'", 'prepare folder')
            int n = 0
            for (int i = 0; i < b64.length(); i += CHUNK) {
                String part = b64.substring(i, Math.min(b64.length(), i + CHUNK))
                rpc(server, guest, "Add-Content -NoNewline -Path '${GUEST_DIR}/agent.b64' -Value '${part}'; Write-Output 'ok'", null)
                n++
            }
            step(job, "uploaded ${b64.length()} base64 chars in ${n} chunk(s)")
            rpc(server, guest, "[IO.File]::WriteAllBytes('${GUEST_DIR}/install-agent.ps1', [Convert]::FromBase64String([IO.File]::ReadAllText('${GUEST_DIR}/agent.b64'))); Write-Output 'MA-DECODED'", 'decode')

            // 6. compare the hash inside the guest; mismatch exits 3, so this works even when no output comes back
            Map v = rpc(server, guest,
                "if ((Get-FileHash -Algorithm SHA256 '${GUEST_DIR}/install-agent.ps1').Hash.ToLower() -eq '${sha}') { Write-Output 'MA-HASH-OK' } " +
                "else { Write-Output ('MA-HASH-BAD ' + (Get-FileHash -Algorithm SHA256 '${GUEST_DIR}/install-agent.ps1').Hash.ToLower() + ' size ' + (Get-Item '${GUEST_DIR}/install-agent.ps1').Length); exit 3 }",
                'verify upload', true)
            String vo = (v.output ?: '') as String
            if (!v.success || vo.contains('MA-HASH-BAD'))
                throw new IllegalStateException("upload corrupted or unreadable in guest (local ${sha}): ${(vo ?: v.error ?: v.msg ?: 'exit ' + v.exitCode).toString().trim().take(400)}")
            step(job, vo.contains('MA-HASH-OK') ? 'upload verified in guest (SHA-256 match)' : 'upload verified in guest (hash check exited 0)')

            // 7. run it; output goes to a log file in the guest as well
            Map r = rpc(server, guest,
                "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File '${GUEST_DIR}/install-agent.ps1' *>&1 | Tee-Object -FilePath '${GUEST_DIR}/install-agent.log' | Out-String -Width 200; " +
                "Write-Output ('MA-EXIT=' + [string]\$LASTEXITCODE)", 'run installer', true)
            job.output = ((r.output ?: '') as String).take(20000)
            if (!r.success) throw new IllegalStateException("installer failed: ${(r.error ?: r.msg ?: r.output ?: 'exit ' + r.exitCode).toString().take(500)} (log: ${GUEST_DIR}/install-agent.log)")
            step(job, "installer ran${job.output ? '' : ' (no output returned; see ' + GUEST_DIR + '/install-agent.log in the guest)'}")

            // 8. did Morpheus hear from the agent?
            Map seen = waitForAgent(sid, 180, job.agentBefore as String)
            job.state = seen.installed ? 'done' : 'done-unconfirmed'
            step(job, seen.installed ? "Morpheus reports the agent installed${seen.version ? ' (' + seen.version + ')' : ''}"
                                     : 'installer finished, but Morpheus has not reported the agent within 3 minutes; check Infrastructure > Compute for this VM')
        } catch (Throwable t) {
            job.state = 'failed'
            job.error = "${t.class.simpleName}: ${t.message}".toString()
            step(job, "failed: ${job.error}")
        } finally {
            job.finishedAt = Instant.now().toString()
        }
    }

    Map waitForAgent(Long sid, int seconds) { waitForAgent(sid, seconds, null) }

    /** Wait for agentInstalled, and when reinstalling, for a check-in newer than the one before. */
    Map waitForAgent(Long sid, int seconds, String before) {
        long until = System.currentTimeMillis() + seconds * 1000L
        while (System.currentTimeMillis() < until) {
            try {
                Map sv = (api().get("/api/servers/${sid}").server ?: [:]) as Map
                if (sv.agentInstalled == true && (!before || (sv.lastAgentUpdate && (sv.lastAgentUpdate as String) != before))) return [installed: true, version: sv.agentVersion]
            } catch (Exception ignored) {}
            sleep 10_000
        }
        return [installed: false]
    }

    protected Map rpc(def server, Map guest, String cmd, String label) { rpc(server, guest, cmd, label, false) }

    /** soft=true: return failures instead of throwing (caller decides). */
    protected Map rpc(def server, Map guest, String cmd, String label, boolean soft) { rpc(server, guest, cmd, label, soft, label == 'run installer' ? 900 : 120) }

    protected Map rpc(def server, Map guest, String cmd, String label, boolean soft, int limit) {
        def fut = rpcPool.submit({ -> morpheus.executeCommandOnServer(server, cmd, true, guest.username as String, guest.password as String,
                                                  null, null, null, true, false).blockingGet() } as java.util.concurrent.Callable)
        def res
        try { res = fut.get(limit, java.util.concurrent.TimeUnit.SECONDS) }
        catch (java.util.concurrent.ExecutionException ee) {
            if (soft) return [success: false, error: (ee.cause?.message ?: ee.message)]
            throw new IllegalStateException("WinRM ${label ?: 'chunk'} failed: ${ee.cause?.message ?: ee.message}")
        }
        catch (java.util.concurrent.TimeoutException te) {
            fut.cancel(true)
            if (soft) return [success: false, timedOut: true, error: "no answer within ${limit}s".toString()]
            throw new IllegalStateException("WinRM ${label ?: 'chunk'} did not return within ${limit}s" +
                (label == 'run installer' ? " (a reinstall restarts the agent service; check ${GUEST_DIR}/install-agent.log and the VM in Morpheus)" : ''))
        }
        Map r = [success: res?.success == true, output: res?.output, error: res?.error, msg: res?.msg, exitCode: res?.exitCode]
        if (!r.success && !soft) {
            String why = (r.error ?: r.msg ?: r.output ?: 'no detail') as String
            throw new IllegalStateException("WinRM ${label ?: 'chunk'} failed as ${guest.username}: ${why.take(500)}")
        }
        if (label) log.debug("migration-assist rpc ${label}: ok")
        return r
    }

    protected def loadServer(Long id) {
        try { return morpheus.services.computeServer.get(id) } catch (Throwable ignored) {}
        try { return morpheus.async.computeServer.get(id).blockingGet() } catch (Throwable ignored) {}
        return null
    }

    // ── web session for the UI route ─────────────────────────────────────────

    String downloadScript(Long serverId) {
        Map s = settings()
        String base = ((s.applianceUrl ?: 'https://127.0.0.1') as String).replaceAll('/+$', '')
        String ref = (s.serviceCredential ?: '').toString().trim()
        if (!ref) throw new IllegalStateException('set "Service account credential" (a Morpheus login) to download the agent script')
        Map svc = resolverFor(ref).resolve()
        if (svc.error || !svc.username) throw new IllegalStateException("service credential: ${svc.error ?: 'no username'}")

        CookieManager cm = new CookieManager(null, CookiePolicy.ACCEPT_ALL)
        HttpClient http = HttpClient.newBuilder().sslContext(MorpheusApi.HTTP.sslContext()).cookieHandler(cm)
                .followRedirects(HttpClient.Redirect.NEVER).connectTimeout(Duration.ofSeconds(15)).build()

        HttpResponse<String> page = http.send(HttpRequest.newBuilder(URI.create(base + '/login/auth')).GET().build(), HttpResponse.BodyHandlers.ofString())
        String csrf = hiddenInput(page.body(), '_csrf') ?: cookie(cm, 'XSRF-TOKEN')
        String form = [username: svc.username, password: svc.password, _csrf: csrf ?: ''].collect { k, v ->
            URLEncoder.encode(k as String, 'UTF-8') + '=' + URLEncoder.encode((v ?: '') as String, 'UTF-8') }.join('&')
        HttpRequest.Builder lb = HttpRequest.newBuilder(URI.create(base + '/login/process'))
                .header('Content-Type', 'application/x-www-form-urlencoded').POST(HttpRequest.BodyPublishers.ofString(form))
        if (csrf) lb.header('X-XSRF-TOKEN', csrf)
        HttpResponse<String> login = http.send(lb.build(), HttpResponse.BodyHandlers.ofString())
        String loc = login.headers().firstValue('Location').orElse('')
        if (!cookie(cm, 'JSESSIONID') || loc.contains('/login')) throw new IllegalStateException("web sign-in as ${svc.username} failed (HTTP ${login.statusCode()}${loc ? ', redirected to ' + loc : ''})")

        HttpResponse<String> r = http.send(HttpRequest.newBuilder(URI.create("${base}/infrastructure/servers/${serverId}/download-agent-script")).GET().build(),
                                           HttpResponse.BodyHandlers.ofString())
        String body = r.body() ?: ''
        if (r.statusCode() != 200) throw new IllegalStateException("download-agent-script HTTP ${r.statusCode()} ${r.headers().firstValue('Location').orElse('')}")
        if (body.trim().startsWith('<')) throw new IllegalStateException('download-agent-script returned an HTML page, not a script (session not accepted?)')
        return body
    }

    private static String hiddenInput(String html, String name) {
        def m = (html ?: '') =~ /name=["']${name}["'][^>]*value=["']([^"']+)["']/
        if (m.find()) return m.group(1)
        m = (html ?: '') =~ /value=["']([^"']+)["'][^>]*name=["']${name}["']/
        return m.find() ? m.group(1) : null
    }

    private static String cookie(CookieManager cm, String name) {
        cm.cookieStore.cookies.find { it.name == name }?.value
    }

    static String sha256(byte[] b) { MessageDigest.getInstance('SHA-256').digest(b).encodeHex().toString() }
}
