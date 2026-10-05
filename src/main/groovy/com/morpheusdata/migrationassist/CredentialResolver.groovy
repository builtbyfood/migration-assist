package com.morpheusdata.migrationassist

import com.morpheusdata.core.MorpheusContext
import groovy.util.logging.Slf4j

/**
 * Resolves an SSH credential the way the rest of the Milestone tooling does:
 * a Morpheus Trust credential referenced by numeric ID (preferred — survives
 * renames) or by name. Two lookups are tried and the first that yields a real
 * secret wins:
 *
 *   1. plugin-api  morpheus.services.accountCredential.get(id)  (in-process)
 *   2. REST        GET /api/credentials/{id}                    (needs apiToken)
 *
 * A "secret" is a password or private key that isn't empty and isn't the
 * masked placeholder (****). Nothing secret is ever logged; describe() reports
 * lengths and flags only.
 */
@Slf4j
class CredentialResolver {

    final MorpheusContext morpheus
    final Closure<Map> settings

    CredentialResolver(MorpheusContext morpheus, Closure<Map> settings) {
        this.morpheus = morpheus
        this.settings = settings
    }

    /** @return [username:, password:, privateKey:, source:, id:, name:, type:] or [error:] */
    Map resolve() {
        Map s = settings()
        String ref = (s.sshCredential ?: '').toString().trim()
        if (!ref) {
            // legacy fallback: plain settings
            if (s.sshUser) return [username: s.sshUser, password: s.sshSecret, privateKey: null, keyPath: s.sshKeyPath, source: 'settings']
            return [error: 'no SSH credential configured (set "SSH credential" to a Trust credential ID or name)']
        }
        List<String> tried = []
        if (ref.startsWith('cypher:') || ref.startsWith('secret/')) {
            try { return viaCypher(ref.replaceFirst(/^cypher:/, '')) } catch (Exception e) { return [error: "cypher ${ref}: ${e.message}".toString()] }
        }
        Map fromApi = null, fromRest = null
        try { fromApi = viaPluginApi(ref, tried) } catch (Exception e) { tried << "plugin-api: ${e.message}".toString() }
        if (usable(fromApi)) return fromApi
        try { fromRest = viaRest(ref, s) } catch (Exception e) { tried << "rest: ${e.message}".toString() }
        if (usable(fromRest)) return fromRest
        Map partial = fromApi ?: fromRest
        if (partial) {
            return [error: "credential '${ref}' resolved (user ${partial.username}) but the secret came back ${partial.masked ? 'masked' : 'empty'} " +
                           "from ${partial.source}; ${tried ? 'other lookup: ' + tried.join('; ') : ''}".toString()]
        }
        return [error: "credential '${ref}' not found — ${tried.join('; ') ?: 'no lookup succeeded'}".toString()]
    }

    /** Safe summary for diagnostics. */
    Map describe() {
        Map r = resolve()
        if (r.error) return [ok: false, error: r.error]
        [ok: true, source: r.source, id: r.id, name: r.name, type: r.type, username: r.username,
         passwordLength: r.password?.toString()?.length() ?: 0, hasPrivateKey: r.privateKey ? true : false,
         keyPath: r.keyPath]
    }

    private static boolean usable(Map c) {
        c && c.username && !c.masked && (c.password || c.privateKey)
    }

    private static boolean masked(String v) { v && v ==~ /\*{3,}/ }

    // ── 1. plugin-api ────────────────────────────────────────────────────────
    private Map viaPluginApi(String ref, List<String> tried) {
        def cred = null
        def q = new com.morpheusdata.core.data.DataQuery().withFilter(ref.isLong() ? 'id' : 'name', ref.isLong() ? (ref as Long) : ref)
        List attempts = [
            { ref.isLong() ? morpheus.async.accountCredential.listById([ref as Long]).toList().blockingGet() : null },
            { morpheus.async.accountCredential.list(q).toList().blockingGet() },
            { morpheus.services.accountCredential.list(q) },
        ]
        for (Closure a : attempts) {
            try { def list = a(); if (list) { cred = list[0]; break } }
            catch (Exception e) { tried << "plugin-api list: ${e.message?.take(120)}".toString() }
        }
        if (!cred) return null

        // The secrets live in cred.data, which is only populated after a decrypt call.
        // loadCredentialConfig resolves a credential reference the way option-source services do.
        Map data = extractData(cred)
        if (!(data.username || data.password || data.privateKey)) {
            // loadCredentialConfig takes the form's "credential" element: [type: <credential id>] selects a
            // stored credential ([type:'local', ...] means inline values, which is what returned nothing in 0.1.0).
            // Morpheus providers read the decrypted values from the result's .data.
            Long cid = (cred.id ?: (ref.isLong() ? ref as Long : null)) as Long
            if (cid) {
                List<Map> configs = [[type: cid], [type: cid.toString()], [type: cid, id: cid], [type: 'local', credential: [id: cid]]]
                outer:
                for (Map cc : configs) {
                    for (String via : ['services', 'async']) {
                        try {
                            def res = via == 'services' ? morpheus.services.accountCredential.loadCredentialConfig(cc, [:])
                                                        : morpheus.async.accountCredential.loadCredentialConfig(cc, [:]).blockingGet()
                            Map found = pickSecret(res)
                            if (found) { data = found; break outer }
                            tried << "loadCredentialConfig(${via}, type=${cc.type}): no username in keys ${(res instanceof Map) ? (res as Map).keySet() : res?.class?.simpleName}".toString()
                        } catch (Exception e) { tried << "loadCredentialConfig(${via}, type=${cc.type}): ${e.message?.take(100)}".toString() }
                    }
                }
            }
        }
        String type = null
        try { type = cred.type?.code } catch (Exception ignored) {}
        return [id: cred.id, name: cred.name, type: type, source: 'plugin-api',
                username: data.username, password: data.password, privateKey: data.privateKey,
                masked: masked(data.password as String) || masked(data.privateKey as String)]
    }

    /** Find username/password/privateKey in a loadCredentialConfig result: .data, .credential, or top level. */
    private static Map pickSecret(Object res) {
        if (!(res instanceof Map)) { try { res = res?.hasProperty('data') ? [data: res.data] : null } catch (Exception ignored) { res = null } }
        if (!(res instanceof Map)) return null
        Map r = res as Map
        for (Object cand : [r.data, r.credential, (r.credential instanceof Map ? (r.credential as Map).data : null), r]) {
            if (!(cand instanceof Map)) continue
            Map c = cand as Map
            String u = (c.username ?: c.user) as String
            String p = c.password as String
            String k = (c.privateKey ?: (c.keyPair instanceof Map ? (c.keyPair as Map).privateKey : null)) as String
            if (u && (p || k) && !masked(p)) return [username: u, password: p, privateKey: k]
        }
        return null
    }

    private static Map extractData(cred) {
        Map data = [:]
        try { if (cred.hasProperty('data') && cred.data instanceof Map) data.putAll(cred.data as Map) } catch (Exception ignored) {}
        ['username', 'password', 'privateKey'].each { k ->
            if (!data[k]) try { if (cred.hasProperty(k)) data[k] = cred."$k" } catch (Exception ignored) {}
        }
        return data
    }

    // ── 0. Cypher ────────────────────────────────────────────────────────────
    /** Cypher secret holding "user:password", "user password", or JSON {username,password[,privateKey]}. */
    private Map viaCypher(String key) {
        String raw = readCypher(key)
        if (!raw) return [error: "cypher key ${key} is empty or missing".toString()]
        raw = raw.trim()
        Map out = [source: 'cypher', name: key]
        if (raw.startsWith('{')) {
            Map j = new groovy.json.JsonSlurper().parseText(raw) as Map
            out += [username: j.username ?: j.user, password: j.password, privateKey: j.privateKey]
        } else {
            def m = raw =~ /^([^:\s]+)[:\s]+(.+)$/
            if (!m) return [error: "cypher value must be user:password or JSON".toString()]
            out += [username: m.group(1), password: m.group(2)]
        }
        return usable(out) ? out : [error: 'cypher value has no usable username/secret']
    }

    /** Diagnostic: try each key spelling and signature, report length + which worked (no value). */
    Map cypherProbe(String key) {
        List<String> keys = [key, key.replaceFirst(/^secret\//, ''), 'secret/' + key.replaceFirst(/^secret\//, '')].unique()
        Map out = [:]
        keys.each { k ->
            List<Map> sigs = []
            [['getAt', { morpheus.services.cypher.getAt(k) }],
             ['svc.get', { def v = morpheus.services.cypher.get(k); v?.hasProperty('value') ? v.value : v }],
             ['async.get', { def v = morpheus.async.cypher.get(k).blockingGet(); v?.hasProperty('value') ? v.value : v }]].each { pair ->
                try { def r = (pair[1] as Closure)(); sigs << [sig: pair[0], len: (r as String)?.length() ?: 0] }
                catch (Exception e) { sigs << [sig: pair[0], err: (e.message?.take(60) ?: e.class.simpleName)] }
            }
            out[k] = sigs
        }
        return out
    }

    /** Cypher read is overloaded oddly across builds; try the known-good signatures in order. */
    private String readCypher(String key) {
        List<String> errs = []
        List<Closure<String>> tries = [
            { morpheus.services.cypher.getAt(key) as String },
            { def v = morpheus.async.cypher.get(key).blockingGet(); (v?.hasProperty('value') ? v.value : v) as String },
            { def v = morpheus.services.cypher.get(key); (v?.hasProperty('value') ? v.value : v) as String },
            { morpheus.async.cypher.read(key).blockingGet() as String },
        ]
        for (Closure<String> t : tries) {
            try { String r = t(); if (r) return r } catch (Exception e) { errs << (e.message?.take(80) ?: e.class.simpleName) }
        }
        log.warn("migration-assist: cypher read ${key} failed: ${errs.join(' | ')}")
        return null
    }

    // ── 2. REST ──────────────────────────────────────────────────────────────
    private Map viaRest(String ref, Map s) {
        MorpheusApi api = new MorpheusApi(s.applianceUrl as String, s.apiToken as String)
        if (!api.configured()) throw new IllegalStateException('apiToken not set')
        String id = ref
        if (!ref.isLong()) {
            List<Map> hits = (api.get("/api/credentials?name=${URLEncoder.encode(ref, 'UTF-8')}&max=5").credentials ?: []) as List<Map>
            Map hit = hits.find { it.name == ref } ?: (hits ? hits[0] : null)
            if (!hit) return null
            id = hit.id.toString()
        }
        Map c = (api.get("/api/credentials/${id}").credential ?: [:]) as Map
        if (!c) return null
        return [id: c.id, name: c.name, type: (c.type as Map)?.code, source: 'rest',
                username: c.username, password: c.password, privateKey: c.privateKey,
                masked: masked(c.password as String) || masked(c.privateKey as String)]
    }
}
