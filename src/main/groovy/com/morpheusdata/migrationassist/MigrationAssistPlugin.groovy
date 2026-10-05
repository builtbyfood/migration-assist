package com.morpheusdata.migrationassist

import com.morpheusdata.core.Plugin
import com.morpheusdata.model.OptionType
import com.morpheusdata.views.HandlebarsRenderer
import groovy.json.JsonSlurper
import groovy.util.logging.Slf4j

/**
 * Migration Assist (Stage 1).
 *
 *  - Lists VMware -> HVM migration plans with per-VM phase progress and stall detection.
 *  - Snapshots each source VM's NICs while plans are pending (the source record loses its
 *    IPs once the plan powers the VM off).
 *  - Pre-flight per NIC: plan network mapping, destination DHCP, subnet fit, and a
 *    WinRM/SSH port check from the appliance.
 *  - Credential profiles: a Trust credential written into one or more pending plans.
 *  - Appliance log lines for a plan's run window.
 *
 * Page: /plugin/migrationAssist
 */
@Slf4j
class MigrationAssistPlugin extends Plugin {

    { this.renderer = new HandlebarsRenderer() }

    static final String VERSION = '0.3.0'
    static final String DATA_DIR = '/var/opt/morpheus/morpheus-ui/migration-assist'

    Store store
    TokenSource tokens
    PlanService plans
    MigrationAssistController controller
    AgentInstaller agents
    VCenterProgress vcenter

    @Override String getCode() { 'migrationAssist' }
    @Override String getName() { 'Migration Assist' }

    @Override
    void initialize() {
        setName('Migration Assist')
        setDescription('VMware to HVM migration plans: per-VM phase tracking, stall detection, pre-flight network/DHCP/WinRM checks, NIC snapshots and plan credentials.')
        setAuthor('Travis DeLuca')

        Closure<Map> cfg = { loadSettings() }
        Closure<CredentialResolver> resolverFor = { String ref ->
            new CredentialResolver(morpheus, { -> cfg() + [sshCredential: ref, sshUser: null] })
        }
        store = new Store(DATA_DIR)
        tokens = new TokenSource(cfg, resolverFor)
        plans = new PlanService({ -> api() }, cfg, store, resolverFor)
        agents = new AgentInstaller(morpheus, cfg, resolverFor)
        agents.api = { -> api() }
        agents.onResult = { Long planId, Object srcId, String key, Object value -> plans.saveVmExtra(planId, srcId, key, value) }
        vcenter = new VCenterProgress(morpheus, cfg, { -> api() }, resolverFor)
        controller = new MigrationAssistController(this, morpheus)
        this.controllers.add(controller)   // controllers are not providers (see hvm-updater)
        plans.start()
        log.info('Migration Assist initialized; page at /plugin/migrationAssist')
    }

    @Override
    void onDestroy() {
        try { plans?.stop() } catch (Exception ignored) {}
        try { agents?.stop() } catch (Exception ignored) {}
    }

    Boolean hasCustomRenderer() { true }

    MorpheusApi api() {
        Map s = loadSettings()
        new MorpheusApi((s.applianceUrl ?: 'https://127.0.0.1') as String, { -> tokens.get() }, { -> tokens.invalidate() })
    }

    @Override
    List<OptionType> getSettings() {
        int i = 0
        [
            opt('Appliance URL', 'applianceUrl', OptionType.InputType.TEXT, 'https://127.0.0.1', i++,
                'Where the plugin calls the Morpheus API for migration plans, processes, networks and logs. 127.0.0.1 = this appliance.'),
            opt('Service account credential (Trust ID or name)', 'serviceCredential', OptionType.InputType.TEXT, '', i++,
                'Infrastructure > Trust > Credentials: username/password of a Morpheus user with admin rights (health logs need it). ' +
                'The plugin gets and refreshes its own API token from it, so nothing expires. Use a dedicated service user. ' +
                'Numeric ID preferred; a Cypher key like secret/migration-assist holding user:password also works.'),
            opt('API token (fallback only)', 'apiToken', OptionType.InputType.PASSWORD, null, i++,
                'Only used when no service credential is set. Tokens expire (30 days by default on 9.0).'),
            opt('vCenter credential (Trust ID or name, optional)', 'vcenterCredential', OptionType.InputType.TEXT, '', i++,
                'Used to read live export progress from vCenter during migrations. Leave empty to use the source cloud\'s own credentials.'),
            opt('VirtIO installer URL (optional)', 'virtioUrl', OptionType.InputType.TEXT, '', i++,
                'Where migrated VMs download virtio-win-guest-tools.exe during the post-migration run, e.g. an internal web server. ' +
                'Empty = the script default (fedorapeople.org, needs internet) or an attached virtio-win ISO.'),
            opt('Snapshot poll interval (seconds)', 'pollSeconds', OptionType.InputType.NUMBER, '120', i++,
                'How often pending plans are re-snapshotted while their source VMs still report IPs.'),
            opt('Stall threshold (minutes)', 'stallMinutes', OptionType.InputType.NUMBER, '30', i++,
                'A running phase with no update for this long is flagged as stalled.'),
        ]
    }

    private static OptionType opt(String label, String field, OptionType.InputType type, String dflt, int order, String help) {
        new OptionType(name: label, code: "migrationAssist.${field}", fieldName: field, fieldLabel: label,
                       inputType: type, defaultValue: dflt, displayOrder: order, helpText: help)
    }

    Map loadSettings() {
        try {
            String json = morpheus.getSettings(this).blockingGet()
            if (json) return new JsonSlurper().parseText(json) as Map
        } catch (Exception e) {
            log.debug("settings unavailable, using defaults: ${e.message}")
        }
        return [:]
    }
}
