package com.morpheusdata.migrationassist

import com.morpheusdata.core.MorpheusContext
import com.morpheusdata.core.Plugin
import com.morpheusdata.model.Permission
import com.morpheusdata.views.HTMLResponse
import com.morpheusdata.views.JsonResponse
import com.morpheusdata.views.ViewModel
import com.morpheusdata.web.PluginController
import com.morpheusdata.web.Route
import groovy.util.logging.Slf4j

@Slf4j
class MigrationAssistController implements PluginController {

    MigrationAssistPlugin plugin
    MorpheusContext morpheus

    MigrationAssistController(MigrationAssistPlugin plugin, MorpheusContext morpheus) { this.plugin = plugin; this.morpheus = morpheus }

    @Override Plugin getPlugin() { plugin }
    void setPlugin(Plugin p) { this.plugin = p as MigrationAssistPlugin }
    @Override MorpheusContext getMorpheus() { morpheus }
    Boolean isEnabled() { true }
    String getCode() { 'migrationAssistController' }
    String getName() { 'Migration Assist Controller' }

    @Override
    List<Route> getRoutes() {
        def p = { String path, String action -> Route.build(path, action, Permission.build('admin-cm', 'full')) }
        [
            p('/migrationAssist',                'page'),
            p('/migrationAssist/api/plans',      'apiPlans'),
            p('/migrationAssist/api/plan',       'apiPlan'),
            p('/migrationAssist/api/snapshot',   'apiSnapshot'),
            p('/migrationAssist/api/ports',      'apiPorts'),
            p('/migrationAssist/api/assign',     'apiAssign'),
            p('/migrationAssist/api/logs',       'apiLogs'),
            p('/migrationAssist/api/diag',       'apiDiag'),
            p('/migrationAssist/api/credentials', 'apiCredentials'),
            p('/migrationAssist/api/fixVmLogin', 'apiFixVmLogin'),
            p('/migrationAssist/api/agentInstall', 'apiAgentInstall'),
            p('/migrationAssist/api/agentJob', 'apiAgentJob'),
            p('/migrationAssist/api/vcenter', 'apiVcenter'),
            p('/migrationAssist/api/inventory', 'apiInventory'),
            p('/migrationAssist/api/postRun', 'apiPostRun'),
        ]
    }

    def page(ViewModel<Map> model) { HTMLResponse.success(Page.html(safeNonce(model))) }

    def apiPlans(ViewModel<Map> model) {
        safe { [plans: plugin.plans.plans(), version: MigrationAssistPlugin.VERSION, scriptVersion: AgentInstaller.bundledScriptVersion(), token: plugin.tokens.describe(), lastTick: plugin.plans.lastTick, lastTickError: plugin.plans.lastTickError] }
    }

    def apiPlan(ViewModel<Map> model) { safe { plugin.plans.detail(idParam(model)) } }

    def apiSnapshot(ViewModel<Map> model) { safe { plugin.plans.snapshot(idParam(model)) } }

    def apiPorts(ViewModel<Map> model) { safe { plugin.plans.portCheck(idParam(model)) } }

    /** ?ref=<Trust id/name or cypher key>&os=windows|linux&ids=1,2,3 — the secret is resolved server-side. */
    def apiAssign(ViewModel<Map> model) {
        safe {
            List<Long> ids = (param(model, 'ids') ?: '').tokenize(',').findAll { it.trim().isLong() }.collect { it.trim() as Long }
            if (!ids) return [error: 'select at least one pending plan']
            plugin.plans.assign(param(model, 'ref')?.trim(), param(model, 'os'), ids)
        }
    }

    def apiLogs(ViewModel<Map> model) {
        safe {
            plugin.plans.logs(idParam(model), param(model, 'level'), param(model, 'all') == 'true',
                              PlanService.asInt(param(model, 'max'), 200))
        }
    }

    def apiFixVmLogin(ViewModel<Map> model) {
        safe {
            String sid = param(model, 'serverId')
            if (!sid?.isLong()) return [error: 'serverId is required']
            plugin.plans.applyProfileToVm(idParam(model), sid as Long)
        }
    }

    /** ?id=plan&serverId=N - push and run the VM's agent script over WinRM with the plan's Windows profile. */
    def apiAgentInstall(ViewModel<Map> model) {
        safe {
            Long planId = idParam(model)
            String sid = param(model, 'serverId')
            if (!sid?.isLong()) return [error: 'serverId is required']
            Map a = plugin.plans.assignmentFor(planId).find { it.os == 'windows' } as Map
            if (!a) return [error: 'assign a Windows credential profile to this plan first']
            Map p = plugin.plans.plan(planId)
            boolean inPlan = ((p.servers ?: []) as List<Map>).any { PlanService.m(it.sourceServer).id as Long == sid as Long || PlanService.m(it.destinationServer).id as Long == sid as Long }
            if (!inPlan) return [error: "server ${sid} is not in plan ${planId}".toString()]
            plugin.agents.start(sid as Long, a.credentialRef as String, param(model, 'name'))
        }
    }

    /** Live vCenter task progress (e.g. Export OVF template) for the VMs of a plan. */
    def apiVcenter(ViewModel<Map> model) {
        safe {
            Map p = plugin.plans.plan(idParam(model))
            Long cloudId = PlanService.m(p.sourceCloud).id as Long
            if (!cloudId) return [error: 'plan has no source cloud']
            List<String> names = ((p.servers ?: []) as List<Map>).collect { PlanService.m(it.sourceServer).name as String }
            Map r = plugin.vcenter.tasksFor(cloudId, names)
            r + [cloudId: cloudId]
        }
    }

    private Map vmContext(ViewModel<Map> model) {
        Long planId = idParam(model)
        String src = param(model, 'sourceId')
        if (!src?.isLong()) throw new IllegalArgumentException('sourceId is required')
        Map p = plugin.plans.plan(planId)
        Map sv = ((p.servers ?: []) as List<Map>).find { PlanService.m(it.sourceServer).id as Long == src as Long }
        if (!sv) throw new IllegalArgumentException("source server ${src} is not in plan ${planId}")
        Map a = plugin.plans.assignmentFor(planId).find { it.os == 'windows' } as Map
        if (!a) throw new IllegalArgumentException('assign a Windows credential profile to this plan first')
        Map dst = PlanService.m(sv.destinationServer), s = PlanService.m(sv.sourceServer)
        [planId: planId, sourceId: src as Long, plan: p, credentialRef: a.credentialRef,
         serverId: (dst.id ?: s.id) as Long, serverName: dst.name ?: s.name, hasDest: dst.id != null]
    }

    /** Scan VMware/Broadcom/Omnissa software on the VM (the migrated VM if it exists, else the source). */
    def apiInventory(ViewModel<Map> model) { safe { plugin.agents.startJob('inventory', vmContext(model)) } }

    /** Run Invoke-VMwareToVirtio on the migrated VM. ?scope=ToolsOnly|Selected|AllVMware&products=code1,code2 */
    def apiPostRun(ViewModel<Map> model) {
        safe {
            Map ctx = vmContext(model)
            if (!ctx.hasDest) return [error: 'this VM has no migrated server yet']
            Map row = ((plugin.plans.detail(ctx.planId as Long).vms ?: []) as List<Map>).find { (it.sourceId as Long) == ctx.sourceId }
            if (row && !row.readyForPostRun) return [error: 'the migrated VM is not ready yet (migration or instance provisioning still running)']
            String scope = param(model, 'scope') ?: 'ToolsOnly'
            if (!(scope in ['ToolsOnly', 'Selected', 'AllVMware'])) return [error: 'scope must be ToolsOnly, Selected or AllVMware']
            List<String> products = (param(model, 'products') ?: '').tokenize(',').collect { it.trim() }.findAll { it }
            ctx.scope = scope; ctx.products = products
            ctx.nicMap = plugin.plans.nicMapFor(ctx.planId as Long, ctx.sourceId)
            ctx.virtioUrl = (plugin.loadSettings().virtioUrl ?: '').toString().trim()
            plugin.agents.startJob('postRun', ctx)
        }
    }

    def apiAgentJob(ViewModel<Map> model) { safe { plugin.agents.status(param(model, 'job')) } }

    def apiCredentials(ViewModel<Map> model) { safe { [credentials: plugin.plans.credentials()] } }

    def apiDiag(ViewModel<Map> model) {
        safe {
            Map out = [token: plugin.tokens.describe(), dataDir: MigrationAssistPlugin.DATA_DIR]
            try { Map w = plugin.api().get('/api/whoami'); out.whoami = [(w.user as Map)?.username, (w.appliance as Map)?.buildVersion] } catch (Exception e) { out.whoamiError = e.message }
            // Stage 2 needs the exact task-type codes for the remote PowerShell / shell tasks on this build.
            try {
                out.taskTypes = ((plugin.api().get('/api/task-types?max=100').taskTypes ?: []) as List<Map>)
                        .collect { [id: it.id, code: it.code, name: it.name] }
            } catch (Exception e) { out.taskTypesError = e.message }
            out
        }
    }

    // ── helpers ─────────────────────────────────────────────────────────────

    private static def safe(Closure<Map> c) {
        try { return JsonResponse.of(c() ?: [:]) }
        catch (Exception e) {
            log.warn("migration-assist: ${e.class.simpleName}: ${e.message}")
            return JsonResponse.of([error: "${e.class.simpleName}: ${e.message}".toString()])
        }
    }

    private static Long idParam(ViewModel<Map> model) {
        String v = param(model, 'id')
        if (!v?.isLong()) throw new IllegalArgumentException('id parameter is required')
        v as Long
    }

    private static String param(ViewModel<Map> model, String key) {
        def v = model?.object?.get(key)
        if (v == null) v = model?.request?.getParameter(key)
        return v?.toString()
    }

    private static String safeNonce(ViewModel model) {
        try { return (model?.request?.getAttribute('js-nonce') ?: '') as String } catch (Exception ignored) { return '' }
    }
}
