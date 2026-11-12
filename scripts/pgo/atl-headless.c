/* SPDX-License-Identifier: MPL-2.0
 *
 * atl-headless — drives the Atlantic WPE WebKit build with no display, on the
 * build host. It exists to run a browsing workload under an instrumented
 * engine so the PGO pipeline (scripts/pgo/) can collect a profile in CI.
 *
 * The view backend is WPEBackend-fdo in SHM mode: the WebProcess renders with
 * whatever EGL the host has (Mesa llvmpipe) and hands frames over as wl_shm
 * buffers, which are acknowledged and dropped here. No compositor is needed.
 *
 * Usage: atl-headless WORKLOAD
 * WORKLOAD lines:  URL SECONDS [JS-DONE-EXPRESSION]
 *   The page is scrolled for SECONDS; with a done-expression it is instead
 *   polled (no scrolling) and the step ends when it is truthy or SECONDS pass.
 *   The truthy value is printed, so a benchmark can report its score.
 */
#include <glib.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <wpe/webkit.h>
#include <wpe/fdo.h>
#include <wpe/unstable/fdo-shm.h>
#include <wayland-server.h>

#define VIEW_W 432
#define VIEW_H 936
#define VIEW_SCALE 2.5f

typedef struct {
    char* url;
    int seconds;
    char* done;
} Step;

static struct wpe_view_backend_exportable_fdo* exportable;
static WebKitWebView* view;
static GMainLoop* loop;
static GArray* steps;
static guint step_index;
static gint64 step_deadline;
static guint frames;
static gboolean step_reported;
static gboolean finished;
static struct wpe_fdo_shm_exported_buffer* pending_buffer;

/* ATL_HEADLESS_DUMP_DIR=<dir>: keep the last frame of every step as
 * <dir>/step-<n>.ppm, to compare renderings (e.g. an engine switch off/on). */
static void dump_frame(struct wpe_fdo_shm_exported_buffer* buffer)
{
    const char* dir = g_getenv("ATL_HEADLESS_DUMP_DIR");
    if (!dir || step_deadline - g_get_monotonic_time() > 1500000)
        return;
    struct wl_shm_buffer* shm = wpe_fdo_shm_exported_buffer_get_shm_buffer(buffer);
    int width = wl_shm_buffer_get_width(shm);
    int height = wl_shm_buffer_get_height(shm);
    int stride = wl_shm_buffer_get_stride(shm);
    char* path = g_strdup_printf("%s/step-%u.ppm", dir, step_index + 1);
    FILE* file = fopen(path, "wb");
    g_free(path);
    if (!file)
        return;
    fprintf(file, "P6\n%d %d\n255\n", width, height);
    wl_shm_buffer_begin_access(shm);
    const unsigned char* pixels = wl_shm_buffer_get_data(shm);
    for (int y = 0; y < height; y++) {
        const unsigned char* row = pixels + (size_t)y * stride;
        for (int x = 0; x < width; x++) {
            /* ARGB8888, little endian: B G R A in memory. */
            unsigned char rgb[3] = { row[x * 4 + 2], row[x * 4 + 1], row[x * 4] };
            fwrite(rgb, 1, 3, file);
        }
    }
    wl_shm_buffer_end_access(shm);
    fclose(file);
}

/* One frame per 16 ms, like a 60 Hz panel: release the buffer and ack. */
static gboolean frame_tick(gpointer data)
{
    if (pending_buffer) {
        dump_frame(pending_buffer);
        wpe_view_backend_exportable_fdo_dispatch_release_shm_exported_buffer(exportable, pending_buffer);
        pending_buffer = NULL;
        wpe_view_backend_exportable_fdo_dispatch_frame_complete(exportable);
        frames++;
    }
    return G_SOURCE_CONTINUE;
}

static void export_shm_buffer(void* data, struct wpe_fdo_shm_exported_buffer* buffer)
{
    if (pending_buffer)
        wpe_view_backend_exportable_fdo_dispatch_release_shm_exported_buffer(exportable, pending_buffer);
    pending_buffer = buffer;
}

static void start_step(void);

static gboolean quit_loop(gpointer data)
{
    g_main_loop_quit(loop);
    return G_SOURCE_REMOVE;
}

static void next_step(void)
{
    step_index++;
    if (step_index >= steps->len) {
        finished = TRUE;
        g_main_loop_quit(loop);
        return;
    }
    start_step();
}

static void done_cb(GObject* object, GAsyncResult* result, gpointer data)
{
    GError* error = NULL;
    JSCValue* value = webkit_web_view_evaluate_javascript_finish(WEBKIT_WEB_VIEW(object), result, &error);
    if (!value) {
        g_clear_error(&error);
        return;
    }
    gboolean finished = jsc_value_to_boolean(value);
    char* text = finished ? jsc_value_to_string(value) : NULL;
    g_object_unref(value);
    if (finished && GPOINTER_TO_UINT(data) == step_index && !step_reported) {
        step_reported = TRUE;
        fprintf(stderr, "[atl-headless]   result: %s\n", text);
        /* Let the page report its result before leaving it. */
        step_deadline = MIN(step_deadline, g_get_monotonic_time() + 3 * G_USEC_PER_SEC);
    }
    g_free(text);
}

/* A flick every tick: down the page, and back to the top when it runs out, so
 * scrolling, tile raster and lazy-loading all get exercised. */
static const char scroll_js[] =
    "(function(){var e=document.scrollingElement||document.documentElement;"
    "if(!e)return;"
    "if(e.scrollTop+innerHeight>=e.scrollHeight-4)scrollTo({top:0,behavior:'smooth'});"
    "else scrollBy({top:innerHeight*0.8,behavior:'smooth'});})()";

static gboolean step_tick(gpointer data)
{
    if (finished)
        return G_SOURCE_REMOVE;
    Step* step = &g_array_index(steps, Step, step_index);
    if (g_get_monotonic_time() >= step_deadline) {
        fprintf(stderr, "[atl-headless]   left after %u frames\n", frames);
        next_step();
        return G_SOURCE_CONTINUE;
    }
    if (step->done)
        webkit_web_view_evaluate_javascript(view, step->done, -1, NULL, NULL, NULL, done_cb, GUINT_TO_POINTER(step_index));
    else
        webkit_web_view_evaluate_javascript(view, scroll_js, -1, NULL, NULL, NULL, NULL, NULL);
    return G_SOURCE_CONTINUE;
}

static void start_step(void)
{
    Step* step = &g_array_index(steps, Step, step_index);
    fprintf(stderr, "[atl-headless] %u/%u %s (%d s)\n", step_index + 1, steps->len, step->url, step->seconds);
    frames = 0;
    step_reported = FALSE;
    step_deadline = g_get_monotonic_time() + (gint64)step->seconds * G_USEC_PER_SEC;
    webkit_web_view_load_uri(view, step->url);
}

static void load_failed_cb(WebKitWebView* v, WebKitLoadEvent event, const char* uri, GError* error, gpointer data)
{
    fprintf(stderr, "[atl-headless]   load failed: %s\n", error->message);
}

static void terminated_cb(WebKitWebView* v, WebKitWebProcessTerminationReason reason, gpointer data)
{
    fprintf(stderr, "[atl-headless]   WebProcess terminated (reason %d)\n", (int)reason);
    step_deadline = 0;
}

static gboolean read_workload(const char* path)
{
    char* contents;
    if (!g_file_get_contents(path, &contents, NULL, NULL))
        return FALSE;
    steps = g_array_new(FALSE, TRUE, sizeof(Step));
    char** lines = g_strsplit(contents, "\n", -1);
    for (char** line = lines; *line; line++) {
        g_strstrip(*line);
        if (!**line || **line == '#')
            continue;
        char** fields = g_strsplit_set(*line, " \t", 3);
        if (fields[0] && fields[1]) {
            Step step = { g_strdup(fields[0]), atoi(fields[1]), NULL };
            if (fields[2] && *g_strstrip(fields[2]))
                step.done = g_strdup(fields[2]);
            if (step.seconds > 0)
                g_array_append_val(steps, step);
        }
        g_strfreev(fields);
    }
    g_strfreev(lines);
    g_free(contents);
    return steps->len > 0;
}

int main(int argc, char** argv)
{
    if (argc != 2 || !read_workload(argv[1])) {
        fprintf(stderr, "usage: %s WORKLOAD   (lines: URL SECONDS [JS-DONE-EXPRESSION])\n", argv[0]);
        return 2;
    }

    /* A page can wedge the session (a modal the embedder never answers, a
     * hung helper). Never outlive the workload by more than a few minutes:
     * SIGALRM ends this process, and the helpers follow when their connection
     * closes. */
    unsigned budget = 180;
    for (guint i = 0; i < steps->len; i++)
        budget += g_array_index(steps, Step, i).seconds + 10;
    alarm(budget);

    wpe_loader_init("libWPEBackend-fdo-1.0.so.1");
    if (!wpe_fdo_initialize_shm()) {
        fprintf(stderr, "[atl-headless] wpe_fdo_initialize_shm failed\n");
        return 1;
    }

    static struct wpe_view_backend_exportable_fdo_client client = {
        .export_shm_buffer = export_shm_buffer,
    };
    exportable = wpe_view_backend_exportable_fdo_create(&client, NULL, VIEW_W * VIEW_SCALE, VIEW_H * VIEW_SCALE);
    struct wpe_view_backend* backend = wpe_view_backend_exportable_fdo_get_view_backend(exportable);

    const char* data_dir = g_getenv("ATL_HEADLESS_DATA_DIR");
    WebKitNetworkSession* session = data_dir
        ? webkit_network_session_new(data_dir, data_dir)
        : webkit_network_session_new_ephemeral();

    WebKitSettings* settings = webkit_settings_new_with_settings(
        "user-agent", g_getenv("ATL_HEADLESS_USER_AGENT") ? g_getenv("ATL_HEADLESS_USER_AGENT")
            : "Mozilla/5.0 (Linux; Android 14; Mobile) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile Safari/605.1.15",
        "enable-webgl", TRUE,
        /* ATL_HEADLESS_CONSOLE=1: page console messages go to stdout. */
        "enable-write-console-messages-to-stdout", g_getenv("ATL_HEADLESS_CONSOLE") != NULL,
        "media-playback-requires-user-gesture", TRUE,
        NULL);

    /* ATL_HEADLESS_USER_CSS / ATL_HEADLESS_USER_JS=<file>: a user style sheet
     * and a document-start user script for every page, to reproduce what a
     * browser front end injects (cosmetic filters, site scripts). */
    WebKitUserContentManager* content_manager = webkit_user_content_manager_new();
    char* injected = NULL;
    if (g_getenv("ATL_HEADLESS_USER_CSS") && g_file_get_contents(g_getenv("ATL_HEADLESS_USER_CSS"), &injected, NULL, NULL)) {
        webkit_user_content_manager_add_style_sheet(content_manager, webkit_user_style_sheet_new(injected,
            WEBKIT_USER_CONTENT_INJECT_ALL_FRAMES, WEBKIT_USER_STYLE_LEVEL_USER, NULL, NULL));
        g_free(injected);
    }
    if (g_getenv("ATL_HEADLESS_USER_JS") && g_file_get_contents(g_getenv("ATL_HEADLESS_USER_JS"), &injected, NULL, NULL)) {
        webkit_user_content_manager_add_script(content_manager, webkit_user_script_new(injected,
            WEBKIT_USER_CONTENT_INJECT_ALL_FRAMES, WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START, NULL, NULL));
        g_free(injected);
    }

    view = WEBKIT_WEB_VIEW(g_object_new(WEBKIT_TYPE_WEB_VIEW,
        "backend", webkit_web_view_backend_new(backend, NULL, NULL),
        "user-content-manager", content_manager,
        "network-session", session,
        "settings", settings,
        NULL));

    wpe_view_backend_dispatch_set_size(backend, VIEW_W * VIEW_SCALE, VIEW_H * VIEW_SCALE);
    wpe_view_backend_dispatch_set_device_scale_factor(backend, VIEW_SCALE);
    wpe_view_backend_add_activity_state(backend,
        wpe_view_activity_state_visible | wpe_view_activity_state_focused | wpe_view_activity_state_in_window);

    g_signal_connect(view, "load-failed", G_CALLBACK(load_failed_cb), NULL);
    g_signal_connect(view, "web-process-terminated", G_CALLBACK(terminated_cb), NULL);

    loop = g_main_loop_new(NULL, FALSE);
    g_timeout_add(16, frame_tick, NULL);
    g_timeout_add(700, step_tick, NULL);
    start_step();
    g_main_loop_run(loop);

    /* Leave the last page before going away. A WebProcess that is still busy
     * when its connection closes is aborted by WebKit's 10 s exit watchdog,
     * which under PGO instrumentation costs it its final profile flush. */
    webkit_web_view_load_uri(view, "about:blank");
    g_timeout_add_seconds(3, (GSourceFunc)quit_loop, NULL);
    g_main_loop_run(loop);
    fprintf(stderr, "[atl-headless] workload finished\n");
    return 0;
}
