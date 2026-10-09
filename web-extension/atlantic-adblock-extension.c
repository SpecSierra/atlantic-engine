/*
 * Atlantic Browser — WebKit web-process extension for network ad/tracker blocking.
 *
 * Runs inside the WPE WebProcess (the only place that sees every subresource)
 * and routes each request through the Brave/Rust adblock engine
 * (libatlantic_adblock) via WebKitWebPage::send-request. The engine is loaded
 * from the serialized cache shipped at /usr/share/atlantic-browser/engine.dat.
 *
 * Built and shipped to /usr/lib64/atlantic-browser/web-extensions/; registered
 * by the UI process via webkit_web_context_set_web_process_extensions_directory.
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this file,
 * You can obtain one at http://mozilla.org/MPL/2.0/.
 */

#include <wpe/webkit-web-process-extension.h>
#include <libsoup/soup.h>
#include <gmodule.h>
#include <glib.h>
#include <string.h>
#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>

/* --- libatlantic_adblock (Brave/Rust) C ABI; mirrors AdBlockEngine.h --- */
typedef void AtlanticAdblockEngine;
typedef struct {
    bool matched;
    bool important;
    char *redirect;
    char *exception;
} MatchResult;

extern AtlanticAdblockEngine *atlantic_adblock_create_from_cache(const uint8_t *data, size_t len);
extern bool atlantic_adblock_use_resources_json(AtlanticAdblockEngine *engine,
                                                const uint8_t *data, size_t len);
extern MatchResult atlantic_adblock_match_network_v2(AtlanticAdblockEngine *engine,
                                                  const char *src, const char *req,
                                                  const char *type, int third_party,
                                                  const char *method);
extern void atlantic_adblock_free_match_result(MatchResult result);

#define ATL_SHIPPED_DIR "/usr/share/atlantic-browser"
/* Relative to g_get_user_cache_dir(); where the browser's AdBlockListUpdater
 * downloads refreshed lists. Loaded instead of the shipped copy when its
 * engine.version stamp is higher (same rule as the UI process). */
#define ATL_UPDATED_SUBDIR "org.atlantic/atlanticbrowser/adblock"
#define ATL_TOGGLE_MESSAGE "atlantic-adblock-set-enabled"
#define ATL_ALLOWLIST_MESSAGE "atlantic-adblock-set-allowlist"

/* The engine is loaded on a worker thread (see load_engine_thread): reading,
 * checksumming, copying and verifying the ~16 MB engine.dat used to run inside
 * the extension's initialize function, which WebKit calls while the WebProcess
 * is still initializing -- so every non-prewarmed process (a new tab, and every
 * cross-site navigation under process swap) paid for it before it could even
 * create its page. Now it overlaps with that setup and with the fetch of the
 * document; a frame or subresource request that needs the engine before it is
 * ready waits for it (ready_engine), a top-level document does not (see
 * on_send_request).
 * ATLANTIC_ADBLOCK_SYNC_LOAD=1 restores the old in-line load (A/B). */
static GMutex g_engine_mutex;
static GCond g_engine_cond;
static gint g_engine_settled = 0; /* atomic; set once g_engine is final */
static AtlanticAdblockEngine *g_engine = NULL;
/* Upper bound on that wait. The load takes a fraction of a second; this only
 * keeps a load that never finishes from wedging the page's main thread. */
#define ATL_ENGINE_WAIT_US (5 * G_USEC_PER_SEC)

static gboolean g_enabled = TRUE;
/* Per-site allowlist: NULL-terminated host vector; blocking is skipped when
 * the page host is one of these (or a subdomain, per hosts_related). */
static char **g_allowlist = NULL;

static void set_allowlist(const char *joined)
{
    g_strfreev(g_allowlist);
    g_allowlist = (joined && *joined) ? g_strsplit(joined, "\n", -1) : NULL;
}

/* Map a request to a Brave resource-type string. An empty/unknown type makes
 * the engine return no-match, so we always return a concrete string. The
 * Sec-Fetch-Dest header (Chromium taxonomy) is the most accurate signal; fall
 * back to Accept, then the URL extension, then "other". */
static const char *resource_type_for(WebKitURIRequest *request, const char *uri)
{
    SoupMessageHeaders *headers = webkit_uri_request_get_http_headers(request);
    if (headers) {
        const char *dest = soup_message_headers_get_one(headers, "Sec-Fetch-Dest");
        if (dest && *dest) {
            if (!strcmp(dest, "script"))   return "script";
            if (!strcmp(dest, "style"))    return "stylesheet";
            if (!strcmp(dest, "image"))    return "image";
            if (!strcmp(dest, "font"))     return "font";
            if (!strcmp(dest, "document")) return "document";
            if (!strcmp(dest, "iframe") || !strcmp(dest, "frame")) return "sub_frame";
            if (!strcmp(dest, "empty"))    return "xmlhttprequest";
            if (!strcmp(dest, "audio") || !strcmp(dest, "video") || !strcmp(dest, "track")) return "media";
            if (!strcmp(dest, "object") || !strcmp(dest, "embed")) return "object";
        }
        const char *accept = soup_message_headers_get_one(headers, "Accept");
        if (accept && *accept) {
            if (strstr(accept, "text/css"))       return "stylesheet";
            if (strstr(accept, "image/"))         return "image";
            if (strstr(accept, "text/html") ||
                strstr(accept, "application/xhtml")) return "sub_frame";
            if (strstr(accept, "font") ||
                strstr(accept, "application/font")) return "font";
        }
    }

    /* URL-extension fallback (ignore query string). */
    if (uri) {
        const char *q = strchr(uri, '?');
        size_t len = q ? (size_t)(q - uri) : strlen(uri);
        const char *dot = NULL;
        for (size_t i = len; i > 0; --i) {
            char c = uri[i - 1];
            if (c == '.') { dot = uri + i; break; }
            if (c == '/') break;
        }
        if (dot) {
            size_t elen = (uri + len) - dot;
            char ext[12];
            if (elen > 0 && elen < sizeof(ext)) {
                for (size_t i = 0; i < elen; ++i) ext[i] = g_ascii_tolower(dot[i]);
                ext[elen] = '\0';
                if (!strcmp(ext, "js") || !strcmp(ext, "mjs")) return "script";
                if (!strcmp(ext, "css")) return "stylesheet";
                if (!strcmp(ext, "png") || !strcmp(ext, "jpg") || !strcmp(ext, "jpeg") ||
                    !strcmp(ext, "gif") || !strcmp(ext, "webp") || !strcmp(ext, "svg") ||
                    !strcmp(ext, "ico") || !strcmp(ext, "bmp")) return "image";
                if (!strcmp(ext, "woff") || !strcmp(ext, "woff2") || !strcmp(ext, "ttf") ||
                    !strcmp(ext, "otf") || !strcmp(ext, "eot")) return "font";
                if (!strcmp(ext, "mp4") || !strcmp(ext, "webm") || !strcmp(ext, "m3u8") ||
                    !strcmp(ext, "mp3") || !strcmp(ext, "ogg")) return "media";
            }
        }
    }
    return "other";
}

/* true if a == b or one host is a dotted suffix of the other (subdomain). */
static gboolean hosts_related(const char *a, const char *b)
{
    if (!a || !b) return FALSE;
    if (!g_ascii_strcasecmp(a, b)) return TRUE;
    size_t la = strlen(a), lb = strlen(b);
    if (la > lb && a[la - lb - 1] == '.' && !g_ascii_strcasecmp(a + la - lb, b)) return TRUE;
    if (lb > la && b[lb - la - 1] == '.' && !g_ascii_strcasecmp(b + lb - la, a)) return TRUE;
    return FALSE;
}

static gboolean page_allowlisted(const char *page_uri)
{
    if (!g_allowlist || !page_uri || !*page_uri)
        return FALSE;
    GUri *pu = g_uri_parse(page_uri, G_URI_FLAGS_NONE, NULL);
    if (!pu)
        return FALSE;
    const char *host = g_uri_get_host(pu);
    gboolean allowed = FALSE;
    for (char **h = g_allowlist; host && *h && !allowed; h++) {
        if (**h)
            allowed = hosts_related(host, *h);
    }
    g_uri_unref(pu);
    return allowed;
}

static int is_third_party(const char *page_uri, const char *req_uri)
{
    if (!page_uri || !*page_uri) return 0; /* unknown source -> treat as first-party */
    GUri *pu = g_uri_parse(page_uri, G_URI_FLAGS_NONE, NULL);
    GUri *ru = g_uri_parse(req_uri, G_URI_FLAGS_NONE, NULL);
    int tp = 0;
    if (pu && ru)
        tp = hosts_related(g_uri_get_host(pu), g_uri_get_host(ru)) ? 0 : 1;
    if (pu) g_uri_unref(pu);
    if (ru) g_uri_unref(ru);
    return tp;
}

/* The engine, once the load has settled. Until then a caller that may_wait
 * blocks for it (bounded); one that may not gets NULL straight away. NULL also
 * when the load failed, or while a timed-out load is still running. Main
 * thread only. */
static AtlanticAdblockEngine *ready_engine(gboolean may_wait, const char *rtype)
{
    static gboolean wait_expired = FALSE;
    static gboolean logged_skip = FALSE;

    /* g_engine is written before the settled flag is set, and GLib atomics are
     * full barriers, so seeing the flag means seeing the final pointer. */
    if (g_atomic_int_get(&g_engine_settled))
        return g_engine;
    if (!may_wait) {
        if (!logged_skip) {
            logged_skip = TRUE;
            fprintf(stderr, "[ATL-ADBLOCK-EXT] %s request did not wait for the engine\n", rtype);
        }
        return NULL;
    }
    if (wait_expired)
        return NULL;

    const gint64 start = g_get_monotonic_time();
    g_mutex_lock(&g_engine_mutex);
    while (!g_atomic_int_get(&g_engine_settled)) {
        if (!g_cond_wait_until(&g_engine_cond, &g_engine_mutex, start + ATL_ENGINE_WAIT_US))
            break;
    }
    g_mutex_unlock(&g_engine_mutex);

    const gboolean settled = g_atomic_int_get(&g_engine_settled);
    if (!settled)
        wait_expired = TRUE;
    fprintf(stderr, "[ATL-ADBLOCK-EXT] first %s request waited %lld ms for the engine%s\n",
            rtype, (long long)((g_get_monotonic_time() - start) / 1000),
            settled ? "" : " -- gave up, requests pass unfiltered until it loads");
    return settled ? g_engine : NULL;
}

static gboolean on_send_request(WebKitWebPage *page, WebKitURIRequest *request,
                                WebKitURIResponse *redirected_response, gpointer user_data)
{
    (void)redirected_response;
    (void)user_data;
    if (!g_enabled)
        return FALSE;

    const char *req_uri = webkit_uri_request_get_uri(request);
    if (!req_uri || strncmp(req_uri, "http", 4) != 0) /* only http/https */
        return FALSE;

    const char *page_uri = webkit_web_page_get_uri(page);
    if (page_allowlisted(page_uri))
        return FALSE;
    const char *src = page_uri ? page_uri : "";
    const char *rtype = resource_type_for(request, req_uri);
    int third_party = is_third_party(page_uri, req_uri);
    /* adblock 0.13 added $method. A filter carrying it never matches unless the
     * real verb is supplied, so pass it through rather than defaulting. */
    const char *method = webkit_uri_request_get_http_method(request);
    if (!method)
        method = "GET";

    /* A top-level document (Sec-Fetch-Dest: document; https only) does not wait
     * for the engine. In a fresh WebProcess it is the first request, issued a
     * few tens of ms after the process initialized and before the ~100 ms load
     * is done, so waiting here put the rest of that load back on the
     * navigation's critical path (J2, prewarm off: 29 ms). The UI process
     * already matches main-frame navigations and their redirect hops against
     * the same filters as documents (onDecidePolicy / WEBKIT_LOAD_REDIRECTED ->
     * AdBlockEngine::shouldBlockPopup), except a fresh tab's first URL, which
     * the user typed or opened. It is still checked here whenever the engine is
     * ready; frames and subresources always wait. */
    AtlanticAdblockEngine *engine = ready_engine(strcmp(rtype, "document") != 0, rtype);
    if (!engine)
        return FALSE;

    MatchResult r = atlantic_adblock_match_network_v2(engine, src, req_uri, rtype,
                                                   third_party, method);
    gboolean block = FALSE;
    if (r.redirect) {
        webkit_uri_request_set_uri(request, r.redirect); /* surrogate/redirect, allow */
    } else if (r.matched) {
        block = TRUE;
    }
    atlantic_adblock_free_match_result(r);

    if (block)
        g_debug("[ATL-ADBLOCK-EXT] blocked %s (%s)", req_uri, rtype);
    return block; /* TRUE stops the load */
}

static gboolean on_user_message(WebKitWebPage *page, WebKitUserMessage *message, gpointer user_data)
{
    (void)page;
    (void)user_data;
    const char *name = webkit_user_message_get_name(message);
    if (name && !strcmp(name, ATL_TOGGLE_MESSAGE)) {
        GVariant *params = webkit_user_message_get_parameters(message);
        if (params && g_variant_is_of_type(params, G_VARIANT_TYPE_BOOLEAN))
            g_enabled = g_variant_get_boolean(params);
        g_debug("[ATL-ADBLOCK-EXT] enabled=%d (toggle)", g_enabled);
        return TRUE;
    }
    if (name && !strcmp(name, ATL_ALLOWLIST_MESSAGE)) {
        GVariant *params = webkit_user_message_get_parameters(message);
        if (params && g_variant_is_of_type(params, G_VARIANT_TYPE_STRING))
            set_allowlist(g_variant_get_string(params, NULL));
        g_debug("[ATL-ADBLOCK-EXT] allowlist updated (%d hosts)",
                g_allowlist ? (int)g_strv_length(g_allowlist) : 0);
        return TRUE;
    }
    return FALSE;
}

static void on_page_created(WebKitWebProcessExtension *extension, WebKitWebPage *page, gpointer user_data)
{
    (void)extension;
    (void)user_data;
    g_signal_connect(page, "send-request", G_CALLBACK(on_send_request), NULL);
    g_signal_connect(page, "user-message-received", G_CALLBACK(on_user_message), NULL);
}

/* Loads the engine and publishes it (g_engine, then g_engine_settled) exactly
 * once. Runs on the loader thread, or in-line for ATLANTIC_ADBLOCK_SYNC_LOAD=1.
 * Owns updated_dir. */
static gpointer load_engine_thread(gpointer data)
{
    char *updated_dir = data;
    const gint64 start = g_get_monotonic_time();
    AtlanticAdblockEngine *engine = NULL;

    /* Pick the filter dir with the higher engine.version stamp (0 if absent). */
    gint64 shipped_ver = 0, updated_ver = 0;
    char *ver = NULL;
    if (g_file_get_contents(ATL_SHIPPED_DIR "/engine.version", &ver, NULL, NULL)) {
        shipped_ver = g_ascii_strtoll(ver, NULL, 10);
        g_free(ver);
        ver = NULL;
    }
    char *updated_ver_path = g_build_filename(updated_dir, "engine.version", NULL);
    if (g_file_get_contents(updated_ver_path, &ver, NULL, NULL)) {
        updated_ver = g_ascii_strtoll(ver, NULL, 10);
        g_free(ver);
    }
    g_free(updated_ver_path);
    const gboolean use_updated = updated_ver > shipped_ver;
    const char *dir = use_updated ? updated_dir : ATL_SHIPPED_DIR;

    char *dat_path = g_build_filename(dir, "engine.dat", NULL);
    char *dat = NULL;
    gsize len = 0;
    if (g_file_get_contents(dat_path, &dat, &len, NULL) && len > 0)
        engine = atlantic_adblock_create_from_cache((const uint8_t *)dat, len);
    g_free(dat);
    dat = NULL;
    /* A corrupt/missing updated copy must not kill adblock entirely. */
    if (!engine && use_updated) {
        dir = ATL_SHIPPED_DIR;
        if (g_file_get_contents(ATL_SHIPPED_DIR "/engine.dat", &dat, &len, NULL) && len > 0)
            engine = atlantic_adblock_create_from_cache((const uint8_t *)dat, len);
        g_free(dat);
    }
    g_free(dat_path);

    /* Scriptlet/redirect resources are not part of the serialized cache; load
     * them so redirect= rules resolve to their surrogates instead of no-ops.
     * Before publishing: the engine must be complete when requests see it. */
    if (engine) {
        char *res_path = g_build_filename(dir, "adblock-resources.json", NULL);
        char *res = NULL;
        gsize rlen = 0;
        if (g_file_get_contents(res_path, &res, &rlen, NULL) && rlen > 0) {
            if (!atlantic_adblock_use_resources_json(engine, (const uint8_t *)res, rlen))
                fprintf(stderr, "[ATL-ADBLOCK-EXT] resources.json failed to load\n");
        }
        g_free(res);
        g_free(res_path);
    }

    fprintf(stderr, "[ATL-ADBLOCK-EXT] engine=%s (%s) in %lld ms\n",
            engine ? "loaded" : "FAILED", dir, (long long)((g_get_monotonic_time() - start) / 1000));
    g_free(updated_dir);

    g_mutex_lock(&g_engine_mutex);
    g_engine = engine;
    g_atomic_int_set(&g_engine_settled, 1);
    g_cond_broadcast(&g_engine_cond);
    g_mutex_unlock(&g_engine_mutex);
    return NULL;
}

G_MODULE_EXPORT void
webkit_web_process_extension_initialize_with_user_data(WebKitWebProcessExtension *extension,
                                                       GVariant *user_data)
{
    if (user_data && g_variant_is_of_type(user_data, G_VARIANT_TYPE_BOOLEAN)) {
        g_enabled = g_variant_get_boolean(user_data);
    } else if (user_data && g_variant_is_of_type(user_data, G_VARIANT_TYPE("(bs)"))) {
        const char *joined = NULL;
        gboolean enabled = TRUE;
        g_variant_get(user_data, "(b&s)", &enabled, &joined);
        g_enabled = enabled;
        set_allowlist(joined);
    }

    /* Connected before the engine exists: pages created while it loads still
     * route their requests through on_send_request, which waits for it. */
    g_signal_connect(extension, "page-created", G_CALLBACK(on_page_created), NULL);

    char *updated_dir = g_build_filename(g_get_user_cache_dir(), ATL_UPDATED_SUBDIR, NULL);
    const char *sync_load = g_getenv("ATLANTIC_ADBLOCK_SYNC_LOAD");
    if (sync_load && *sync_load && strcmp(sync_load, "0") != 0) {
        load_engine_thread(updated_dir);
    } else {
        GError *error = NULL;
        GThread *loader = g_thread_try_new("atl-adblock-load", load_engine_thread, updated_dir, &error);
        if (loader) {
            g_thread_unref(loader); /* detached; it publishes and exits */
        } else {
            fprintf(stderr, "[ATL-ADBLOCK-EXT] loader thread failed (%s); loading in-line\n",
                    error ? error->message : "?");
            g_clear_error(&error);
            load_engine_thread(updated_dir);
        }
    }
    fprintf(stderr, "[ATL-ADBLOCK-EXT] initialized: enabled=%d, engine %s\n", g_enabled,
            g_atomic_int_get(&g_engine_settled) ? "ready" : "loading on a worker thread");
}
