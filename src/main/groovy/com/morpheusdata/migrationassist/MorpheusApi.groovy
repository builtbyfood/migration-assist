package com.morpheusdata.migrationassist

import groovy.json.JsonOutput
import groovy.json.JsonSlurper
import groovy.util.logging.Slf4j

import java.net.http.HttpClient
import java.net.http.HttpRequest
import java.net.http.HttpResponse
import java.security.cert.X509Certificate
import java.time.Duration
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManager
import javax.net.ssl.SSLEngine
import javax.net.ssl.X509ExtendedTrustManager
import java.net.Socket

/**
 * REST client for the appliance's own API, used only where plugin-api has no service:
 * migration plans, processes, health logs, networks.
 *
 * Token handling (the reason this differs from hvm-updater): a static pasted token
 * expires (30-day default on 9.0) and then every call 401s. Here the token comes from a
 * TokenSource that mints and refreshes its own; on a 401 we ask it for a fresh one and
 * retry once.
 */
@Slf4j
class MorpheusApi {

    final String base
    private final Closure<String> tokenFn
    private final Closure<Void> invalidateFn
    static final HttpClient HTTP = buildClient()

    /** Static-token form (kept for CredentialResolver.viaRest compatibility). */
    MorpheusApi(String base, String token) {
        this(base, { -> token }, null)
    }

    MorpheusApi(String base, Closure<String> tokenFn, Closure<Void> invalidateFn) {
        this.base = (base ?: 'https://127.0.0.1').replaceAll('/+$', '')
        this.tokenFn = tokenFn
        this.invalidateFn = invalidateFn
    }

    boolean configured() { base && tokenFn() }

    Map get(String path) { call('GET', path, null, true) }
    Map post(String path, Map body) { call('POST', path, body ?: [:], true) }
    Map put(String path, Map body) { call('PUT', path, body ?: [:], true) }
    Map delete(String path) { call('DELETE', path, null, true) }

    private Map call(String method, String path, Map body, boolean retry) {
        String token = tokenFn()
        if (!token) throw new IllegalStateException('no API token: set "Service account credential" (or an API token) in plugin settings')
        def rb = HttpRequest.newBuilder(URI.create(base + path)).timeout(Duration.ofSeconds(60))
                .header('Authorization', "Bearer ${token}").header('Accept', 'application/json')
        String json = body != null ? JsonOutput.toJson(body) : null
        switch (method) {
            case 'POST': rb.header('Content-Type', 'application/json').POST(HttpRequest.BodyPublishers.ofString(json)); break
            case 'PUT': rb.header('Content-Type', 'application/json').PUT(HttpRequest.BodyPublishers.ofString(json)); break
            case 'DELETE': rb.DELETE(); break
            default: rb.GET()
        }
        HttpResponse<String> resp = HTTP.send(rb.build(), HttpResponse.BodyHandlers.ofString())
        if (resp.statusCode() == 401 && retry && invalidateFn) {
            invalidateFn()
            return call(method, path, body, false)
        }
        if (resp.statusCode() >= 400) throw new RuntimeException("${method} ${path} -> HTTP ${resp.statusCode()}: ${resp.body()?.take(300)}")
        String b = resp.body()
        if (!b) return [:]
        def parsed = new JsonSlurper().parseText(b)
        return parsed instanceof Map ? (parsed as Map) : [data: parsed]
    }

    /** Form POST without auth (for /oauth/token). Returns [status, body]. */
    static Map formPost(String url, Map<String, String> form) {
        String enc = form.collect { k, v -> URLEncoder.encode(k, 'UTF-8') + '=' + URLEncoder.encode(v ?: '', 'UTF-8') }.join('&')
        def req = HttpRequest.newBuilder(URI.create(url)).timeout(Duration.ofSeconds(30))
                .header('Content-Type', 'application/x-www-form-urlencoded').header('Accept', 'application/json')
                .POST(HttpRequest.BodyPublishers.ofString(enc)).build()
        HttpResponse<String> r = HTTP.send(req, HttpResponse.BodyHandlers.ofString())
        return [status: r.statusCode(), body: r.body()]
    }

    /**
     * The appliance talks to itself on 127.0.0.1 with a cert whose SANs don't include that IP.
     * A plain X509TrustManager isn't enough: the JDK wraps it and still checks the hostname
     * ("No subject alternative names matching IP address 127.0.0.1 found"). An
     * X509ExtendedTrustManager is used as-is, so both chain and hostname checks are skipped.
     */
    private static HttpClient buildClient() {
        X509ExtendedTrustManager trustAll = new X509ExtendedTrustManager() {
            X509Certificate[] getAcceptedIssuers() { new X509Certificate[0] }
            void checkClientTrusted(X509Certificate[] c, String a) {}
            void checkServerTrusted(X509Certificate[] c, String a) {}
            void checkClientTrusted(X509Certificate[] c, String a, Socket s) {}
            void checkServerTrusted(X509Certificate[] c, String a, Socket s) {}
            void checkClientTrusted(X509Certificate[] c, String a, SSLEngine e) {}
            void checkServerTrusted(X509Certificate[] c, String a, SSLEngine e) {}
        }
        SSLContext ctx = SSLContext.getInstance('TLS')
        ctx.init(null, [trustAll] as TrustManager[], new java.security.SecureRandom())
        HttpClient.newBuilder().sslContext(ctx).connectTimeout(Duration.ofSeconds(15)).build()
    }

    static String q(Object v) { URLEncoder.encode((v ?: '').toString(), 'UTF-8') }

    /** Page through a list endpoint. key = the array field ('migrations', 'logs', ...). */
    List<Map> all(String path, String key, int pageSize = 100, int maxRows = 2000) {
        List<Map> out = []
        int offset = 0
        String sep = path.contains('?') ? '&' : '?'
        while (out.size() < maxRows) {
            Map r = get("${path}${sep}max=${pageSize}&offset=${offset}")
            List<Map> rows = (r[key] ?: []) as List<Map>
            out.addAll(rows)
            offset += rows.size()
            Long total = ((r.meta as Map)?.total ?: 0) as Long
            if (!rows || rows.size() < pageSize || (total && offset >= total)) break
        }
        return out
    }
}
