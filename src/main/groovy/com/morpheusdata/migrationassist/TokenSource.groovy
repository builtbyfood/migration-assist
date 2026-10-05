package com.morpheusdata.migrationassist

import groovy.json.JsonSlurper
import groovy.util.logging.Slf4j

/**
 * Supplies a working API bearer token without anyone pasting one in.
 *
 * Order:
 *   1. cached access token, while it has more than 2 minutes left
 *   2. refresh_token grant (client morph-api)
 *   3. password grant with the "Service account credential" (Trust ID/name or Cypher key),
 *      resolved server-side by CredentialResolver, so the password never touches the browser
 *   4. the optional pasted "API token" setting (last resort; it will expire)
 *
 * Use a dedicated service-account user: a password grant for morph-api can hand back or
 * rotate that user's morph-api token.
 */
@Slf4j
class TokenSource {

    static final String CLIENT_ID = 'morph-api'

    final Closure<Map> settings
    final Closure<CredentialResolver> resolverFor   // ref -> resolver

    private volatile String access
    private volatile String refresh
    private volatile long expiresAt
    volatile String source
    volatile String lastError
    volatile String resolvedUser
    private volatile String failedKey
    private volatile long failedAt
    static final long FAIL_BACKOFF_MS = 10 * 60_000L

    TokenSource(Closure<Map> settings, Closure<CredentialResolver> resolverFor) {
        this.settings = settings
        this.resolverFor = resolverFor
    }

    private String base() { ((settings().applianceUrl ?: 'https://127.0.0.1') as String).replaceAll('/+$', '') }

    synchronized String get() {
        if (access && System.currentTimeMillis() < expiresAt - 120_000L) return access
        if (refresh && grant([grant_type: 'refresh_token', refresh_token: refresh], 'refresh')) return access
        String ref = (settings().serviceCredential ?: '').toString().trim()
        if (ref) {
            Map c = resolverFor(ref).resolve()
            resolvedUser = c.username as String
            String key = ref + '|' + (c.username ?: '') + '|' + ((c.password ?: '') as String).hashCode()
            if (c.error) lastError = "service credential: ${c.error}".toString()
            // A rejected login is not retried for 10 minutes (same credential): every page load and poll would
            // otherwise hit /oauth/token again and could lock the account.
            else if (failedKey == key && System.currentTimeMillis() - failedAt < FAIL_BACKOFF_MS) { /* keep lastError */ }
            else if (grant([grant_type: 'password', username: c.username as String, password: c.password as String], 'password')) { failedKey = null; return access }
            else { failedKey = key; failedAt = System.currentTimeMillis() }
        }
        String manual = (settings().apiToken ?: '').toString().trim()
        if (manual) { source = 'setting'; return manual }
        return null
    }

    /** Called on a 401: drop the access token; the refresh/password grant runs on the next get(). */
    synchronized void invalidate() { access = null; expiresAt = 0 }

    private boolean grant(Map<String, String> form, String how) {
        try {
            Map r = MorpheusApi.formPost("${base()}/oauth/token?client_id=${CLIENT_ID}&scope=write", form + [client_id: CLIENT_ID, scope: 'write'])
            if ((r.status as int) >= 400) { lastError = "${how} grant HTTP ${r.status}: ${(r.body as String)?.take(200)}".toString(); if (how == 'refresh') refresh = null; return false }
            Map j = new JsonSlurper().parseText(r.body as String) as Map
            if (!j.access_token) { lastError = "${how} grant returned no access_token".toString(); return false }
            access = j.access_token as String
            refresh = (j.refresh_token ?: refresh) as String
            long ttl = ((j.expires_in ?: 3600) as Long) * 1000L
            expiresAt = System.currentTimeMillis() + ttl
            source = how
            lastError = null
            log.info("migration-assist: API token obtained via ${how} grant (expires in ${(ttl / 3600000L) as long}h)")
            return true
        } catch (Exception e) {
            lastError = "${how} grant: ${e.message}".toString()
            return false
        }
    }

    Map describe() {
        [source: source, hasToken: access != null, expiresAt: expiresAt ?: null, lastError: lastError,
         serviceCredentialSet: (settings().serviceCredential ?: '').toString().trim() as boolean,
         serviceCredential: (settings().serviceCredential ?: '').toString().trim(), serviceUser: resolvedUser,
         retryInMinutes: failedAt && System.currentTimeMillis() - failedAt < FAIL_BACKOFF_MS ? ((FAIL_BACKOFF_MS - (System.currentTimeMillis() - failedAt)) / 60000L) as long : null]
    }
}
