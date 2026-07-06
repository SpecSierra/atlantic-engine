/*
 * gstdroidcamdeviceprovider.c — GstDeviceProvider exposing gst-droid cameras.
 *
 * WPE WebKit enumerates capture devices exclusively through GstDeviceMonitor
 * (GStreamerCaptureDeviceManager), but the SFOS gst-droid plugin only ships
 * the droidcamsrc *element* — no device provider — so getUserMedia({video})
 * fails with OverconstrainedError before the permission prompt is even shown.
 *
 * This standalone plugin registers a "Video/Source" provider announcing one
 * back and one front camera. Camera discovery goes through droidmedia
 * (droid_media_camera_get_info — the same call gst-droid makes), because HAL
 * ids are NOT 0=back/1=front everywhere: the Xperia 10 II exposes 0/1/2 as
 * back lenses and 3 as the front camera. droidmedia is reached the way its
 * own hybris.c shim does it: dlopen libhybris-common.so.1 → android_dlopen
 * the bionic libdroidmedia.so. No camera is opened during enumeration.
 *
 * Device creation returns a GstBin: droidcamsrc ! capsfilter ! videoflip.
 *  - droidcamsrc has three always-src pads (vfsrc/imgsrc/vidsrc); WebKit's
 *    capturer looks up the static pad "src" and links blindly, so the bin
 *    ghosts exactly one canonically-named pad.
 *  - vfsrc negotiates plain system-memory video/x-raw NV21 (device-verified
 *    on Xperia 10 II), which WebKit's videoconvertscale handles.
 *  - the viewfinder is pinned to one fixed mode (720p30) and upstream
 *    RECONFIGURE events are DROPPED at the bin boundary: WebKit re-caps its
 *    capsfilter when track constraints are applied, and the resulting
 *    mid-stream renegotiation deadlocks gst_droidcamsrc_mode_negotiate
 *    (main thread stuck waiting on the viewfinder restart, device-observed).
 *    droidcamsrc must negotiate exactly once; WebKit scales downstream.
 *  - videoflip compensates the sensor mount angle (90° on the Xperia 10 II
 *    back cameras, 270° front), so frames reach WebKit upright (portrait).
 */

#include <gst/gst.h>
#include <dlfcn.h>

GST_DEBUG_CATEGORY_STATIC(droidcam_provider_debug);
#define GST_CAT_DEFAULT droidcam_provider_debug

/* Fixed viewfinder mode (pre-rotation, sensor-landscape); WebKit
 * converts/scales downstream. */
#define DROIDCAM_VF_WIDTH  1280
#define DROIDCAM_VF_HEIGHT 720
#define DROIDCAM_VF_FPS    30

/* ── droidmedia glue (mirrors droidmedia's hybris.c) ────────────────────── */

/* droidmediacamera.h: raw facing constant — note it is the OPPOSITE of the
 * Android convention: DROID_MEDIA_CAMERA_FACING_FRONT == 0. */
#define DROIDCAM_RAW_FACING_FRONT 0

typedef struct {
    int facing;
    int orientation;            /* sensor mount angle, degrees */
} DroidMediaCameraInfo;

typedef int (*droid_get_num_fn)(void);
typedef int (*droid_get_info_fn)(DroidMediaCameraInfo *, int); /* bool */

static droid_get_num_fn droid_get_num;
static droid_get_info_fn droid_get_info;

static gboolean
droidmedia_glue_init(void)
{
    static gsize once = 0;
    if (g_once_init_enter(&once)) {
        void *(*android_dlopen)(const char *, int) = NULL;
        void *(*android_dlsym)(void *, const char *) = NULL;
        void *hybris = dlopen("libhybris-common.so.1", RTLD_LAZY);
        if (hybris) {
            android_dlopen = dlsym(hybris, "android_dlopen");
            android_dlsym = dlsym(hybris, "android_dlsym");
        }
        if (android_dlopen && android_dlsym) {
            void *dm = android_dlopen("libdroidmedia.so", RTLD_NOW);
            if (dm) {
                droid_get_num = (droid_get_num_fn)
                    android_dlsym(dm, "droid_media_camera_get_number_of_cameras");
                droid_get_info = (droid_get_info_fn)
                    android_dlsym(dm, "droid_media_camera_get_info");
            }
        }
        if (!droid_get_num || !droid_get_info)
            GST_WARNING("droidmedia unavailable, falling back to static camera list");
        g_once_init_leave(&once, 1);
    }
    return droid_get_num && droid_get_info;
}

/* ── GstDroidCamDevice ──────────────────────────────────────────────────── */

typedef struct {
    GstDevice parent;
    gint camera_device;         /* HAL id passed to droidcamsrc */
    gboolean is_front;
    gint rotation;              /* clockwise degrees to apply: 0/90/180/270 */
} GstDroidCamDevice;

typedef struct {
    GstDeviceClass parent_class;
} GstDroidCamDeviceClass;

G_DEFINE_TYPE(GstDroidCamDevice, gst_droidcam_device, GST_TYPE_DEVICE)

static GstPadProbeReturn
drop_reconfigure_probe(GstPad * pad, GstPadProbeInfo * info, gpointer user_data)
{
    (void) pad;
    (void) user_data;
    GstEvent *event = GST_PAD_PROBE_INFO_EVENT(info);
    if (GST_EVENT_TYPE(event) == GST_EVENT_RECONFIGURE)
        return GST_PAD_PROBE_DROP;
    return GST_PAD_PROBE_OK;
}

static const gchar *
videoflip_method_for_rotation(gint rotation)
{
    switch (rotation) {
    case 90:  return "clockwise";
    case 180: return "rotate-180";
    case 270: return "counterclockwise";
    default:  return "none";
    }
}

static GstElement *
gst_droidcam_device_create_element(GstDevice * device, const gchar * name)
{
    GstDroidCamDevice *self = (GstDroidCamDevice *) device;

    GstElement *src = gst_element_factory_make("droidcamsrc", "droidcamsrc-actual");
    if (!src) {
        GST_ERROR_OBJECT(device, "droidcamsrc element not available");
        return NULL;
    }
    /* mode=2 (video): continuous viewfinder stream tuned for video capture */
    g_object_set(src, "camera-device", self->camera_device, "mode", 2, NULL);

    GstElement *filter = gst_element_factory_make("capsfilter", "droidcam-vf-caps");
    GstCaps *vfcaps = gst_caps_new_simple("video/x-raw",
        "format", G_TYPE_STRING, "NV21",
        "width", G_TYPE_INT, DROIDCAM_VF_WIDTH,
        "height", G_TYPE_INT, DROIDCAM_VF_HEIGHT,
        "framerate", GST_TYPE_FRACTION, DROIDCAM_VF_FPS, 1, NULL);
    g_object_set(filter, "caps", vfcaps, NULL);
    gst_caps_unref(vfcaps);

    GstElement *flip = gst_element_factory_make("videoflip", "droidcam-flip");
    if (flip)
        gst_util_set_object_arg(G_OBJECT(flip), "method",
            videoflip_method_for_rotation(self->rotation));
    else
        GST_WARNING_OBJECT(device, "videoflip missing, frames stay unrotated");

    GstElement *bin = gst_bin_new(name);
    gst_bin_add_many(GST_BIN(bin), src, filter, NULL);
    if (flip)
        gst_bin_add(GST_BIN(bin), flip);

    GstPad *vfsrc = gst_element_get_static_pad(src, "vfsrc");
    GstPad *fsink = gst_element_get_static_pad(filter, "sink");
    gboolean linked = vfsrc && fsink
        && gst_pad_link(vfsrc, fsink) == GST_PAD_LINK_OK
        && (!flip || gst_element_link(filter, flip));
    g_clear_object(&vfsrc);
    g_clear_object(&fsink);
    if (!linked) {
        GST_ERROR_OBJECT(device, "failed to link droidcamsrc capture chain");
        gst_object_unref(bin);
        return NULL;
    }

    GstElement *tail = flip ? flip : filter;
    GstPad *tsrc = gst_element_get_static_pad(tail, "src");
    GstPad *ghost = gst_ghost_pad_new("src", tsrc);
    gst_object_unref(tsrc);

    /* The camera mode is fixed: mid-stream renegotiation deadlocks
     * droidcamsrc, so upstream reconfigure requests must die here. */
    gst_pad_add_probe(ghost, GST_PAD_PROBE_TYPE_EVENT_UPSTREAM,
        drop_reconfigure_probe, NULL, NULL);

    gst_element_add_pad(bin, ghost);
    return bin;
}

static void
gst_droidcam_device_class_init(GstDroidCamDeviceClass * klass)
{
    GST_DEVICE_CLASS(klass)->create_element = gst_droidcam_device_create_element;
}

static void
gst_droidcam_device_init(GstDroidCamDevice * self)
{
    (void) self;
}

static GstDevice *
gst_droidcam_device_new(gint camera_device, gboolean is_front, gint rotation)
{
    /* Advertise exactly what the bin delivers post-rotation; WebKit
     * satisfies other requested sizes with its own videoconvertscale. */
    gboolean swaps = rotation == 90 || rotation == 270;
    GstCaps *caps = gst_caps_new_simple("video/x-raw",
        "format", G_TYPE_STRING, "NV21",
        "width", G_TYPE_INT, swaps ? DROIDCAM_VF_HEIGHT : DROIDCAM_VF_WIDTH,
        "height", G_TYPE_INT, swaps ? DROIDCAM_VF_WIDTH : DROIDCAM_VF_HEIGHT,
        "framerate", GST_TYPE_FRACTION, DROIDCAM_VF_FPS, 1, NULL);

    GstStructure *props = gst_structure_new("droidcam-proplist",
        "device.api", G_TYPE_STRING, "droid",
        "camera.device", G_TYPE_INT, camera_device,
        "is-default", G_TYPE_BOOLEAN, !is_front, NULL);

    gchar *display_name = g_strdup_printf("%s camera",
        is_front ? "Front" : "Back");

    GstDevice *device = g_object_new(gst_droidcam_device_get_type(),
        "display-name", display_name,
        "device-class", "Video/Source",
        "caps", caps,
        "properties", props, NULL);
    GstDroidCamDevice *self = (GstDroidCamDevice *) device;
    self->camera_device = camera_device;
    self->is_front = is_front;
    self->rotation = rotation;

    g_free(display_name);
    gst_structure_free(props);
    gst_caps_unref(caps);
    return device;
}

/* ── GstDroidCamDeviceProvider ──────────────────────────────────────────── */

typedef struct {
    GstDeviceProvider parent;
} GstDroidCamDeviceProvider;

typedef struct {
    GstDeviceProviderClass parent_class;
} GstDroidCamDeviceProviderClass;

G_DEFINE_TYPE(GstDroidCamDeviceProvider, gst_droidcam_device_provider,
    GST_TYPE_DEVICE_PROVIDER)

static gboolean
droidcamsrc_available(void)
{
    GstElementFactory *factory = gst_element_factory_find("droidcamsrc");
    if (!factory)
        return FALSE;
    gst_object_unref(factory);
    return TRUE;
}

/* Build the advertised list: the first back and the first front camera
 * droidmedia reports (extra lenses are auxiliary sensors — the HAL exposes
 * them but sites expect one camera per facing). Fallback when droidmedia is
 * unreachable: assume 0=back/1=front with the Xperia 10 II mount angles. */
static GList *
droidcam_make_devices(void)
{
    if (!droidcamsrc_available())
        return NULL;

    GList *devices = NULL;
    gint back_id = -1, front_id = -1;
    gint back_rot = 90, front_rot = 270;

    if (droidmedia_glue_init()) {
        gint num = droid_get_num();
        GST_INFO("droidmedia reports %d cameras", num);
        for (gint i = 0; i < num; i++) {
            DroidMediaCameraInfo info;
            if (!droid_get_info(&info, i))
                continue;
            gboolean front = info.facing == DROIDCAM_RAW_FACING_FRONT;
            GST_INFO("camera %d: %s, mount angle %d", i,
                front ? "front" : "back", info.orientation);
            if (front && front_id < 0) {
                front_id = i;
                /* Same mapping as back: rotate by the mount angle. The
                 * Android "(360 - angle)" front formula bakes in display
                 * mirroring and lands 180° off here (device-verified). */
                front_rot = info.orientation % 360;
            } else if (!front && back_id < 0) {
                back_id = i;
                back_rot = info.orientation % 360;
            }
        }
    } else {
        back_id = 0;
        front_id = 1;
    }

    if (back_id >= 0)
        devices = g_list_append(devices,
            gst_droidcam_device_new(back_id, FALSE, back_rot));
    if (front_id >= 0)
        devices = g_list_append(devices,
            gst_droidcam_device_new(front_id, TRUE, front_rot));
    return devices;
}

static GList *
gst_droidcam_device_provider_probe(GstDeviceProvider * provider)
{
    (void) provider;
    return droidcam_make_devices();
}

static gboolean
gst_droidcam_device_provider_start(GstDeviceProvider * provider)
{
    GList *devices = droidcam_make_devices();
    for (GList * l = devices; l; l = l->next)
        gst_device_provider_device_add(provider, GST_DEVICE(l->data));
    g_list_free(devices);
    return TRUE;
}

static void
gst_droidcam_device_provider_stop(GstDeviceProvider * provider)
{
    (void) provider;                /* static list, nothing to tear down */
}

static void
gst_droidcam_device_provider_class_init(GstDroidCamDeviceProviderClass * klass)
{
    GstDeviceProviderClass *dp_class = GST_DEVICE_PROVIDER_CLASS(klass);
    dp_class->probe = gst_droidcam_device_provider_probe;
    dp_class->start = gst_droidcam_device_provider_start;
    dp_class->stop = gst_droidcam_device_provider_stop;

    gst_device_provider_class_set_static_metadata(dp_class,
        "Droid camera device provider",
        "Source/Video",
        "Exposes Android HAL cameras (gst-droid droidcamsrc) as capture devices",
        "Atlantic Browser <atlantic@sailfishos.org>");
}

static void
gst_droidcam_device_provider_init(GstDroidCamDeviceProvider * self)
{
    (void) self;
}

/* ── plugin entry ───────────────────────────────────────────────────────── */

static gboolean
plugin_init(GstPlugin * plugin)
{
    GST_DEBUG_CATEGORY_INIT(droidcam_provider_debug, "droidcamprovider", 0,
        "droidcamsrc device provider");
    return gst_device_provider_register(plugin, "droidcamdeviceprovider",
        GST_RANK_PRIMARY, gst_droidcam_device_provider_get_type());
}

#define PACKAGE "atlantic-engine"
GST_PLUGIN_DEFINE(GST_VERSION_MAJOR, GST_VERSION_MINOR,
    droidcamdeviceprovider,
    "Device provider for gst-droid cameras",
    plugin_init, "1.0.0", "LGPL", "atlantic-engine",
    "https://github.com/SpecSierra/atlantic-engine")
