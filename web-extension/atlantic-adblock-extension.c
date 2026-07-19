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
extern MatchResult atlantic_adblock_match_network(AtlanticAdblockEngine *engine,
                                                  const char *src, const char *req,
                                                  const char *type, int third_party);
extern void atlantic_adblock_free_match_result(MatchResult result);

#define ATL_ENGINE_DAT "/usr/share/atlantic-browser/engine.dat"
#define ATL_RESOURCES_JSON "/usr/share/atlantic-browser/adblock-resources.json"
#define ATL_TOGGLE_MESSAGE "atlantic-adblock-set-enabled"
#define ATL_ALLOWLIST_MESSAGE "atlantic-adblock-set-allowlist"

static AtlanticAdblockEngine *g_engine = NULL;
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

static gboolean on_send_request(WebKitWebPage *page, WebKitURIRequest *request,
                                WebKitURIResponse *redirected_response, gpointer user_data)
{
    (void)redirected_response;
    (void)user_data;
    if (!g_engine || !g_enabled)
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

    MatchResult r = atlantic_adblock_match_network(g_engine, src, req_uri, rtype, third_party);
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

    char *data = NULL;
    gsize len = 0;
    if (g_file_get_contents(ATL_ENGINE_DAT, &data, &len, NULL) && len > 0)
        g_engine = atlantic_adblock_create_from_cache((const uint8_t *)data, len);
    g_free(data);

    /* Scriptlet/redirect resources are not part of the serialized cache; load
     * them so redirect= rules resolve to their surrogates instead of no-ops. */
    if (g_engine) {
        char *res = NULL;
        gsize rlen = 0;
        if (g_file_get_contents(ATL_RESOURCES_JSON, &res, &rlen, NULL) && rlen > 0) {
            if (!atlantic_adblock_use_resources_json(g_engine, (const uint8_t *)res, rlen))
                fprintf(stderr, "[ATL-ADBLOCK-EXT] resources.json failed to load\n");
        }
        g_free(res);
    }

    fprintf(stderr, "[ATL-ADBLOCK-EXT] initialized: engine=%s enabled=%d\n",
            g_engine ? "loaded" : "FAILED", g_enabled);

    g_signal_connect(extension, "page-created", G_CALLBACK(on_page_created), NULL);
}
