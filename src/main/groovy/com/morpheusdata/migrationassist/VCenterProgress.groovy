package com.morpheusdata.migrationassist

import com.morpheusdata.core.MorpheusContext
import groovy.util.logging.Slf4j
import groovy.xml.XmlUtil

import java.net.http.HttpClient
import java.net.http.HttpRequest
import java.net.http.HttpResponse
import java.time.Duration

/**
 * Live progress of the vCenter side of a migration ("Export OVF template 37%").
 *
 * Morpheus migrates with action migrateOvfToHvm against the source cloud's /sdk endpoint, and its own
 * "Transferring Workload" event stays at 0% while vCenter's export task moves. vCenter keeps that progress
 * on its Task objects, so: Login -> TaskManager.recentTask -> each Task.info (entityName, name/descriptionId,
 * state, progress) via PropertyCollector.RetrievePropertiesEx -> Logout. Plain SOAP over the JDK client, no SDK.
 *
 * Credentials, in order: the plugin's "vCenter credential" setting (Trust ref), then the source cloud's
 * credentials through plugin-api (the REST cloud record masks the password).
 */
@Slf4j
class VCenterProgress {

    final MorpheusContext morpheus
    final Closure<Map> settings
    final Closure<MorpheusApi> api
    final Closure<CredentialResolver> resolverFor
    static final Map<String, String> FRIENDLY = ['VirtualMachine.exportVm': 'Export OVF template', 'ExportVm': 'Export OVF template',
        'VirtualMachine.powerOff': 'Power off', 'VirtualMachine.shutdownGuest': 'Guest shutdown', 'VirtualMachine.createSnapshot': 'Create snapshot',
        'VirtualMachine.removeSnapshot': 'Remove snapshot', 'VirtualMachine.reconfigure': 'Reconfigure']
    private final Map<Long, Map> cache = [:]   // cloudId -> [at, tasks]

    VCenterProgress(MorpheusContext morpheus, Closure<Map> settings, Closure<MorpheusApi> api, Closure<CredentialResolver> resolverFor) {
        this.morpheus = morpheus; this.settings = settings; this.api = api; this.resolverFor = resolverFor
    }

    /** Running/queued vCenter tasks for the given VM names in a source cloud. Cached 10 s per cloud. */
    Map tasksFor(Long cloudId, Collection<String> vmNames) {
        Map c = cache[cloudId]
        if (!c || System.currentTimeMillis() - (c.at as long) > 10_000L) {
            try { c = [at: System.currentTimeMillis(), tasks: fetch(cloudId)] }
            catch (Exception e) { c = [at: System.currentTimeMillis(), error: "${e.class.simpleName}${e.message ? ': ' + e.message : ''}".toString(), tasks: []] }
            cache[cloudId] = c
        }
        Set<String> names = vmNames.findAll { it }.collect { it.toLowerCase() } as Set
        [error: c.error, tasks: ((c.tasks ?: []) as List<Map>).findAll { names.contains(((it.entityName ?: '') as String).toLowerCase()) }]
    }

    // ── connection details ───────────────────────────────────────────────────

    Map connection(Long cloudId) {
        Map z = (api().get("/api/zones/${cloudId}").zone ?: [:]) as Map
        Map cfg = PlanService.m(z.config)
        String url = (cfg.apiUrl ?: '') as String
        if (!url) throw new IllegalStateException("cloud ${cloudId} has no apiUrl")
        if (!url.endsWith('/sdk')) url = url.replaceAll('/+$', '') + '/sdk'
        String user = null, pass = null, how = null

        String ref = (settings().vcenterCredential ?: '').toString().trim()
        if (ref) {
            Map r = resolverFor(ref).resolve()
            if (!r.error && r.username && r.password) { user = r.username; pass = r.password; how = "credential ${ref}" }
        }
        if (!pass) {
            try {
                def cloud = morpheus.services.cloud.get(cloudId)
                def cred = null
                try { cred = morpheus.services.accountCredential.loadCredentials(cloud) } catch (Throwable ignored) {}
                if (cred && !(cred instanceof Map)) { try { cred = cred.data } catch (Throwable ignored) {} }
                if (cred instanceof Map && cred.password) { user = cred.username; pass = cred.password; how = 'cloud credential' }
                if (!pass) {
                    try { user = user ?: cloud.serviceUsername; pass = cloud.servicePassword; if (pass) how = 'cloud service login' } catch (Throwable ignored) {}
                }
                if (!pass) {
                    try { user = user ?: cloud.getConfigProperty('username'); pass = cloud.getConfigProperty('password'); if (pass) how = 'cloud config' } catch (Throwable ignored) {}
                }
            } catch (Throwable t) { log.debug("cloud ${cloudId} credentials via plugin-api: ${t.message}") }
        }
        user = user ?: (cfg.username as String)
        if (!pass || (pass as String).startsWith('****'))
            throw new IllegalStateException('no vCenter password available: set "vCenter credential" in plugin settings')
        [url: url, username: user, password: pass, via: how]
    }

    // ── SOAP ────────────────────────────────────────────────────────────────

    List<Map> fetch(Long cloudId) {
        Map c = connection(cloudId)
        CookieManager cm = new CookieManager(null, CookiePolicy.ACCEPT_ALL)
        HttpClient http = HttpClient.newBuilder().sslContext(MorpheusApi.HTTP.sslContext()).cookieHandler(cm)
                .connectTimeout(Duration.ofSeconds(15)).build()
        def sc = soap(http, c.url as String, '<urn:RetrieveServiceContent><urn:_this type="ServiceInstance">ServiceInstance</urn:_this></urn:RetrieveServiceContent>')
        def content = sc.'**'.find { it.name() == 'returnval' }
        String sm = text(content, 'sessionManager') ?: 'SessionManager'
        String pc = text(content, 'propertyCollector') ?: 'propertyCollector'
        String tm = text(content, 'taskManager') ?: 'TaskManager'
        soap(http, c.url as String, "<urn:Login><urn:_this type=\"SessionManager\">${x(sm)}</urn:_this><urn:userName>${x(c.username)}</urn:userName><urn:password>${x(c.password)}</urn:password></urn:Login>")
        try {
            def rt = soap(http, c.url as String,
                "<urn:RetrievePropertiesEx><urn:_this type=\"PropertyCollector\">${x(pc)}</urn:_this><urn:specSet>" +
                "<urn:propSet><urn:type>TaskManager</urn:type><urn:pathSet>recentTask</urn:pathSet></urn:propSet>" +
                "<urn:objectSet><urn:obj type=\"TaskManager\">${x(tm)}</urn:obj></urn:objectSet></urn:specSet><urn:options/></urn:RetrievePropertiesEx>")
            List<String> ids = rt.'**'.findAll { it.name() == 'ManagedObjectReference' && it.@type == 'Task' }.collect { it.text() }
            if (!ids) return []
            String objs = ids.collect { "<urn:objectSet><urn:obj type=\"Task\">${x(it)}</urn:obj></urn:objectSet>" }.join('')
            def info = soap(http, c.url as String,
                "<urn:RetrievePropertiesEx><urn:_this type=\"PropertyCollector\">${x(pc)}</urn:_this><urn:specSet>" +
                "<urn:propSet><urn:type>Task</urn:type><urn:pathSet>info</urn:pathSet></urn:propSet>${objs}</urn:specSet><urn:options/></urn:RetrievePropertiesEx>")
            return info.'**'.findAll { it.name() == 'val' }.collect { v ->
                [task: text(v, 'key'), name: FRIENDLY[text(v, 'descriptionId')] ?: FRIENDLY[text(v, 'name')] ?: text(v, 'name') ?: text(v, 'descriptionId'), descriptionId: text(v, 'descriptionId'),
                 entityName: text(v, 'entityName'), state: text(v, 'state'), progress: (text(v, 'progress') ?: null) as Integer,
                 startTime: text(v, 'startTime'), via: c.via]
            }.findAll { it.state in ['running', 'queued'] }
        } finally {
            try { soap(http, c.url as String, "<urn:Logout><urn:_this type=\"SessionManager\">${x(sm)}</urn:_this></urn:Logout>") } catch (Exception ignored) {}
        }
    }

    private static def soap(HttpClient http, String url, String body) {
        String env = '<?xml version="1.0" encoding="UTF-8"?><soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" ' +
                     'xmlns:urn="urn:vim25"><soapenv:Body>' + body + '</soapenv:Body></soapenv:Envelope>'
        HttpResponse<String> r = http.send(HttpRequest.newBuilder(URI.create(url)).timeout(Duration.ofSeconds(30))
                .header('Content-Type', 'text/xml; charset=utf-8').header('SOAPAction', 'urn:vim25/7.0')
                .POST(HttpRequest.BodyPublishers.ofString(env)).build(), HttpResponse.BodyHandlers.ofString())
        def xml = new XmlSlurper(false, false).parseText(r.body() ?: '<empty/>')
        def fault = xml.'**'.find { it.name() == 'faultstring' }
        if (r.statusCode() >= 400 || fault) throw new IllegalStateException("vCenter SOAP: ${fault ? fault.text() : 'HTTP ' + r.statusCode()}")
        return xml
    }

    private static String text(def node, String child) {
        def n = node?.'**'?.find { it.name() == child }
        String t = n ? n.text() : null
        return t ? t.trim() : null
    }

    private static String x(Object s) { XmlUtil.escapeXml((s ?: '').toString()) }
}
