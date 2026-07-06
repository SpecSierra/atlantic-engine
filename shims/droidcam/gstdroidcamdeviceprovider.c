/*
 * gstdroidcamdeviceprovider.c — GstDeviceProvider exposing gst-droid cameras.
 *
 * WPE WebKit enumerates capture devices exclusively through GstDeviceMonitor
 * (GStreamerCaptureDeviceManager), but the SFOS gst-droid plugin only ships
 * the droidcamsrc *element* — no device provider — so getUserMedia({video})
 * fails with OverconstrainedError before the permission prompt is even shown.
 *
 * This standalone plugin registers a "Video/Source" provider announcing the
 * two HAL cameras (0 = back, 1 = front). Device creation returns a GstBin
 * wrapping droidcamsrc with its viewfinder pad (vfsrc) ghosted as "src":
 *  - droidcamsrc has three always-src pads (vfsrc/imgsrc/vidsrc); WebKit's
 *    capturer looks up the static pad "src" and links blindly, so it must
 *    see exactly one canonically-named pad.
 *  - vfsrc negotiates plain system-memory video/x-raw NV21 (device-verified
 *    on Xperia 10 II), which WebKit's videoconvertscale handles.
 *  - the bin pins the viewfinder to one fixed mode (720p30) and DROPS
 *    upstream RECONFIGURE events: WebKit re-caps its capsfilter when track
 *    constraints are applied, and the resulting mid-stream renegotiation
 *    deadlocks gst_droidcamsrc_mode_negotiate (main thread stuck waiting on
 *    the viewfinder restart, device-observed). droidcamsrc must negotiate
 *    exactly once; WebKit scales/converts downstream.
 *
 * Enumeration is static — no HAL/camera is opened until capture starts.
 */

#include <gst/gst.h>

GST_DEBUG_CATEGORY_STATIC(droidcam_provider_debug);
#define GST_CAT_DEFAULT droidcam_provider_debug

#define DROIDCAM_NUM_DEVICES 2

/* ── GstDroidCamDevice ──────────────────────────────────────────────────── */

typedef struct {
    GstDevice parent;
    gint camera_device;
} GstDroidCamDevice;

typedef struct {
    GstDeviceClass parent_class;
} GstDroidCamDeviceClass;

G_DEFINE_TYPE(GstDroidCamDevice, gst_droidcam_device, GST_TYPE_DEVICE)

/* Fixed viewfinder mode; WebKit converts/scales downstream. */
#define DROIDCAM_VF_WIDTH  1280
#define DROIDCAM_VF_HEIGHT 720
#define DROIDCAM_VF_FPS    30

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

    GstElement *bin = gst_bin_new(name);
    gst_bin_add_many(GST_BIN(bin), src, filter, NULL);

    GstPad *vfsrc = gst_element_get_static_pad(src, "vfsrc");
    GstPad *fsink = gst_element_get_static_pad(filter, "sink");
    if (!vfsrc || !fsink || gst_pad_link(vfsrc, fsink) != GST_PAD_LINK_OK) {
        GST_ERROR_OBJECT(device, "failed to link droidcamsrc vfsrc to capsfilter");
        g_clear_object(&vfsrc);
        g_clear_object(&fsink);
        gst_object_unref(bin);
        return NULL;
    }
    gst_object_unref(vfsrc);
    gst_object_unref(fsink);

    GstPad *fsrc = gst_element_get_static_pad(filter, "src");
    GstPad *ghost = gst_ghost_pad_new("src", fsrc);
    gst_object_unref(fsrc);

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
gst_droidcam_device_new(gint camera_device)
{
    /* Advertise exactly the fixed mode the bin delivers; WebKit satisfies
     * other requested sizes with its own videoconvertscale. */
    GstCaps *caps = gst_caps_new_simple("video/x-raw",
        "format", G_TYPE_STRING, "NV21",
        "width", G_TYPE_INT, DROIDCAM_VF_WIDTH,
        "height", G_TYPE_INT, DROIDCAM_VF_HEIGHT,
        "framerate", GST_TYPE_FRACTION, DROIDCAM_VF_FPS, 1, NULL);

    GstStructure *props = gst_structure_new("droidcam-proplist",
        "device.api", G_TYPE_STRING, "droid",
        "camera.device", G_TYPE_INT, camera_device,
        "is-default", G_TYPE_BOOLEAN, camera_device == 0, NULL);

    gchar *display_name = g_strdup_printf("%s camera",
        camera_device == 0 ? "Back" : "Front");

    GstDevice *device = g_object_new(gst_droidcam_device_get_type(),
        "display-name", display_name,
        "device-class", "Video/Source",
        "caps", caps,
        "properties", props, NULL);
    ((GstDroidCamDevice *) device)->camera_device = camera_device;

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

static GList *
gst_droidcam_device_provider_probe(GstDeviceProvider * provider)
{
    (void) provider;
    if (!droidcamsrc_available())
        return NULL;

    GList *devices = NULL;
    for (gint i = DROIDCAM_NUM_DEVICES - 1; i >= 0; i--)
        devices = g_list_prepend(devices, gst_droidcam_device_new(i));
    return devices;
}

static gboolean
gst_droidcam_device_provider_start(GstDeviceProvider * provider)
{
    if (!droidcamsrc_available())
        return TRUE;                /* started, zero devices */

    for (gint i = 0; i < DROIDCAM_NUM_DEVICES; i++) {
        GstDevice *device = gst_droidcam_device_new(i);
        gst_device_provider_device_add(provider, device);
    }
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
