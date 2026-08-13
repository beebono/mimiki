// mimiki-glinfo: step-by-step probe of the two presentation paths
// (GBM/EGL/GLES and Vulkan VK_KHR_display) with per-step error reporting.
// Debug tool - run from the serial console.

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>

#include <gbm.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>

#define VK_NO_PROTOTYPES 1
#include <vulkan/vulkan.h>

#include <xf86drm.h>
#include <xf86drmMode.h>

static void probe_drm_kms(void)
{
    printf("\n=== Kernel KMS view (card0) ===\n");

    int fd = open("/dev/dri/card0", O_RDWR | O_CLOEXEC);
    if (fd < 0)
    {
        printf("open card0: %s\n", strerror(errno));
        return;
    }

    if (drmSetMaster(fd) == 0)
        printf("drmSetMaster: OK (master was free)\n");
    else
        printf("drmSetMaster: %s (someone else is master)\n", strerror(errno));

    drmModeResPtr r = drmModeGetResources(fd);
    if (!r)
    {
        printf("drmModeGetResources: FAILED (%s)\n", strerror(errno));
        drmDropMaster(fd);
        close(fd);
        return;
    }
    printf("connectors=%d crtcs=%d encoders=%d fbs=%d\n",
           r->count_connectors, r->count_crtcs, r->count_encoders, r->count_fbs);
    for (int i = 0; i < r->count_connectors; i++)
    {
        drmModeConnectorPtr c = drmModeGetConnector(fd, r->connectors[i]);
        if (!c)
            continue;
        printf("connector %u: type=%u status=%s modes=%d (first: %s)\n",
               c->connector_id, c->connector_type,
               c->connection == DRM_MODE_CONNECTED ? "connected" :
               c->connection == DRM_MODE_DISCONNECTED ? "disconnected" : "unknown",
               c->count_modes, c->count_modes ? c->modes[0].name : "-");
        drmModeFreeConnector(c);
    }
    drmModeFreeResources(r);
    drmDropMaster(fd);
    close(fd);
}

static const char *egl_err(void)
{
    static char buf[32];
    snprintf(buf, sizeof(buf), "0x%04x", eglGetError());
    return buf;
}

static void probe_egl(void)
{
    printf("=== EGL / GBM path ===\n");

    const char *card = "/dev/dri/card0";
    int fd = open(card, O_RDWR | O_CLOEXEC);
    printf("open %s: %s\n", card, fd >= 0 ? "OK" : strerror(errno));
    if (fd < 0)
        return;

    struct gbm_device *gbm = gbm_create_device(fd);
    printf("gbm_create_device: %s\n", gbm ? "OK" : "FAILED");
    if (!gbm)
        return;
    printf("gbm backend: %s\n", gbm_device_get_backend_name(gbm));

    const char *client_exts = eglQueryString(EGL_NO_DISPLAY, EGL_EXTENSIONS);
    printf("EGL client extensions: %s\n", client_exts ? client_exts : "(null)");

    // Try the modern platform API first, then legacy
    EGLDisplay dpy = EGL_NO_DISPLAY;
    PFNEGLGETPLATFORMDISPLAYEXTPROC get_platform_display =
        (PFNEGLGETPLATFORMDISPLAYEXTPROC)eglGetProcAddress("eglGetPlatformDisplayEXT");
    if (get_platform_display)
    {
        dpy = get_platform_display(EGL_PLATFORM_GBM_KHR, gbm, NULL);
        printf("eglGetPlatformDisplayEXT(GBM): %s (err %s)\n",
               dpy != EGL_NO_DISPLAY ? "OK" : "EGL_NO_DISPLAY", egl_err());
    }
    if (dpy == EGL_NO_DISPLAY)
    {
        dpy = eglGetDisplay((EGLNativeDisplayType)gbm);
        printf("eglGetDisplay(gbm): %s (err %s)\n",
               dpy != EGL_NO_DISPLAY ? "OK" : "EGL_NO_DISPLAY", egl_err());
    }
    if (dpy == EGL_NO_DISPLAY)
        return;

    EGLint major = 0, minor = 0;
    EGLBoolean ok = eglInitialize(dpy, &major, &minor);
    printf("eglInitialize: %s (err %s) version %d.%d\n",
           ok ? "OK" : "FAILED", egl_err(), major, minor);
    if (!ok)
        return;

    printf("EGL vendor: %s\n", eglQueryString(dpy, EGL_VENDOR));
    printf("EGL version: %s\n", eglQueryString(dpy, EGL_VERSION));

    // On the GBM platform the config's native visual id must equal the gbm
    // surface format, or eglCreateWindowSurface fails with EGL_BAD_MATCH
    EGLint ncfg = 0;
    static const EGLint cfg_attrs[] = {
        EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8,
        EGL_NONE};
    EGLConfig cfgs[64];
    ok = eglChooseConfig(dpy, cfg_attrs, cfgs, 64, &ncfg);
    printf("eglChooseConfig: %s, %d configs (err %s)\n",
           ok ? "OK" : "FAILED", ncfg, egl_err());
    if (!ok || ncfg == 0)
        return;
    EGLConfig cfg = cfgs[0];
    for (EGLint i = 0; i < ncfg; i++)
    {
        EGLint vid = 0;
        eglGetConfigAttrib(dpy, cfgs[i], EGL_NATIVE_VISUAL_ID, &vid);
        if (vid == GBM_FORMAT_ARGB8888)
        {
            cfg = cfgs[i];
            break;
        }
    }

    eglBindAPI(EGL_OPENGL_ES_API);
    static const EGLint ctx_attrs[] = {EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE};
    EGLContext ctx = eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, ctx_attrs);
    printf("eglCreateContext: %s (err %s)\n",
           ctx != EGL_NO_CONTEXT ? "OK" : "FAILED", egl_err());

    struct gbm_surface *gs = gbm_surface_create(gbm, 720, 720,
                                                GBM_FORMAT_ARGB8888,
                                                GBM_BO_USE_SCANOUT | GBM_BO_USE_RENDERING);
    printf("gbm_surface_create(720x720 ARGB8888 scanout): %s\n", gs ? "OK" : "FAILED");
    if (gs && ctx != EGL_NO_CONTEXT)
    {
        EGLSurface surf = eglCreateWindowSurface(dpy, cfg, (EGLNativeWindowType)gs, NULL);
        printf("eglCreateWindowSurface: %s (err %s)\n",
               surf != EGL_NO_SURFACE ? "OK" : "FAILED", egl_err());
        if (surf != EGL_NO_SURFACE)
        {
            ok = eglMakeCurrent(dpy, surf, surf, ctx);
            printf("eglMakeCurrent: %s (err %s)\n", ok ? "OK" : "FAILED", egl_err());
        }
    }
}

static void probe_vulkan(void)
{
    printf("\n=== Vulkan VK_KHR_display path ===\n");

    void *lib = dlopen("libvulkan.so.1", RTLD_NOW);
    printf("dlopen libvulkan.so.1: %s\n", lib ? "OK" : dlerror());
    if (!lib)
        return;

    PFN_vkGetInstanceProcAddr gipa =
        (PFN_vkGetInstanceProcAddr)dlsym(lib, "vkGetInstanceProcAddr");

#define IPROC(inst, name) PFN_##name name = (PFN_##name)gipa(inst, #name)

    IPROC(NULL, vkCreateInstance);
    IPROC(NULL, vkEnumerateInstanceExtensionProperties);

    uint32_t ext_count = 0;
    vkEnumerateInstanceExtensionProperties(NULL, &ext_count, NULL);
    VkExtensionProperties *exts = calloc(ext_count, sizeof(*exts));
    vkEnumerateInstanceExtensionProperties(NULL, &ext_count, exts);
    int have_display = 0;
    printf("instance extensions (%u):", ext_count);
    for (uint32_t i = 0; i < ext_count; i++)
    {
        printf(" %s", exts[i].extensionName);
        if (!strcmp(exts[i].extensionName, "VK_KHR_display"))
            have_display = 1;
    }
    printf("\nVK_KHR_display advertised: %s\n", have_display ? "YES" : "NO");

    const char *want_exts[] = {"VK_KHR_surface", "VK_KHR_display"};
    VkInstanceCreateInfo ici = {.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
                                .enabledExtensionCount = have_display ? 2u : 0u,
                                .ppEnabledExtensionNames = want_exts};
    VkInstance inst = VK_NULL_HANDLE;
    VkResult res = vkCreateInstance(&ici, NULL, &inst);
    printf("vkCreateInstance: %d\n", res);
    if (res != VK_SUCCESS)
        return;

    IPROC(inst, vkEnumeratePhysicalDevices);
    IPROC(inst, vkGetPhysicalDeviceProperties);
    IPROC(inst, vkGetPhysicalDeviceDisplayPropertiesKHR);
    IPROC(inst, vkGetDisplayModePropertiesKHR);
    IPROC(inst, vkGetPhysicalDeviceDisplayPlanePropertiesKHR);
    IPROC(inst, vkGetDisplayPlaneSupportedDisplaysKHR);
    IPROC(inst, vkCreateDisplayPlaneSurfaceKHR);
    IPROC(inst, vkGetPhysicalDeviceQueueFamilyProperties);
    IPROC(inst, vkCreateDevice);
    IPROC(inst, vkGetPhysicalDeviceSurfaceSupportKHR);

    uint32_t gpu_count = 0;
    vkEnumeratePhysicalDevices(inst, &gpu_count, NULL);
    printf("physical devices: %u\n", gpu_count);
    if (gpu_count == 0)
        return;
    VkPhysicalDevice gpus[4];
    if (gpu_count > 4) gpu_count = 4;
    vkEnumeratePhysicalDevices(inst, &gpu_count, gpus);
    VkPhysicalDevice gpu = gpus[0];

    VkPhysicalDeviceProperties props;
    vkGetPhysicalDeviceProperties(gpu, &props);
    printf("device: %s (api %u.%u.%u)\n", props.deviceName,
           VK_VERSION_MAJOR(props.apiVersion), VK_VERSION_MINOR(props.apiVersion),
           VK_VERSION_PATCH(props.apiVersion));

    if (!vkGetPhysicalDeviceDisplayPropertiesKHR)
    {
        printf("vkGetPhysicalDeviceDisplayPropertiesKHR: NULL\n");
        return;
    }
    uint32_t disp_count = 0;
    res = vkGetPhysicalDeviceDisplayPropertiesKHR(gpu, &disp_count, NULL);
    printf("displays: %u (res %d)\n", disp_count, res);
    if (disp_count == 0)
        return;
    VkDisplayPropertiesKHR dprops[4];
    if (disp_count > 4) disp_count = 4;
    vkGetPhysicalDeviceDisplayPropertiesKHR(gpu, &disp_count, dprops);
    printf("display[0]: %s\n", dprops[0].displayName ? dprops[0].displayName : "(unnamed)");

    uint32_t mode_count = 0;
    res = vkGetDisplayModePropertiesKHR(gpu, dprops[0].display, &mode_count, NULL);
    printf("modes: %u (res %d)\n", mode_count, res);
    if (mode_count == 0)
        return;
    VkDisplayModePropertiesKHR modes[16];
    if (mode_count > 16) mode_count = 16;
    vkGetDisplayModePropertiesKHR(gpu, dprops[0].display, &mode_count, modes);
    printf("mode[0]: %ux%u @ %u mHz\n",
           modes[0].parameters.visibleRegion.width,
           modes[0].parameters.visibleRegion.height,
           modes[0].parameters.refreshRate);

    uint32_t plane_count = 0;
    vkGetPhysicalDeviceDisplayPlanePropertiesKHR(gpu, &plane_count, NULL);
    printf("planes: %u\n", plane_count);

    VkDisplaySurfaceCreateInfoKHR sci = {
        .sType = VK_STRUCTURE_TYPE_DISPLAY_SURFACE_CREATE_INFO_KHR,
        .displayMode = modes[0].displayMode,
        .planeIndex = 0,
        .planeStackIndex = 0,
        .transform = VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR,
        .globalAlpha = 1.0f,
        .alphaMode = VK_DISPLAY_PLANE_ALPHA_OPAQUE_BIT_KHR,
        .imageExtent = modes[0].parameters.visibleRegion,
    };
    VkSurfaceKHR surface = VK_NULL_HANDLE;
    res = vkCreateDisplayPlaneSurfaceKHR(inst, &sci, NULL, &surface);
    printf("vkCreateDisplayPlaneSurfaceKHR: %d\n", res);
    if (res != VK_SUCCESS)
        return;

    uint32_t qf_count = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(gpu, &qf_count, NULL);
    printf("queue families: %u\n", qf_count);
    VkBool32 present_ok = VK_FALSE;
    vkGetPhysicalDeviceSurfaceSupportKHR(gpu, 0, surface, &present_ok);
    printf("qf0 can present to display surface: %s\n", present_ok ? "YES" : "NO");

    float prio = 1.0f;
    VkDeviceQueueCreateInfo qci = {.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
                                   .queueFamilyIndex = 0,
                                   .queueCount = 1,
                                   .pQueuePriorities = &prio};
    const char *dev_exts[] = {"VK_KHR_swapchain"};
    VkDeviceCreateInfo dci = {.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
                              .queueCreateInfoCount = 1,
                              .pQueueCreateInfos = &qci,
                              .enabledExtensionCount = 1,
                              .ppEnabledExtensionNames = dev_exts};
    VkDevice dev = VK_NULL_HANDLE;
    res = vkCreateDevice(gpu, &dci, NULL, &dev);
    printf("vkCreateDevice(+swapchain): %d\n", res);
}

int main(void)
{
    // Order matters: the first open of card0 with no master present is
    // implicitly granted DRM master and holds it for the fd's lifetime.
    // The EGL probe keeps its fd open, which would starve the blob's
    // VK_KHR_display enumeration (it opens card0 itself and needs master),
    // so Vulkan must probe first. probe_drm_kms closes its fd afterwards.
    probe_drm_kms();
    probe_vulkan();
    probe_egl();
    printf("\ndone.\n");
    return 0;
}
