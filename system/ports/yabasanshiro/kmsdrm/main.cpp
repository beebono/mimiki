// Shoddy YabaSanshiro port file for VK_KHR_display-based rendering, SDL2 for audio + input.

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <unistd.h>
#include <signal.h>

#include <SDL.h>

extern "C" {
#include "../yabause.h"
#include "../yui.h"
#include "../peripheral.h"
#include "../sh2core.h"
#include "../sh2int.h"
#include "../vidsoft.h"
#include "../cs0.h"
#include "../cs2.h"
#include "../cdbase.h"
#include "../scsp.h"
#include "../m68kcore.h"
#include "../debug.h"
#include "../vdp1.h"
#include "../vdp2.h"
#include "../memory.h"
}

#ifdef HAVE_LIBSDL
extern "C" {
#include "../sndsdl.h"
#include "../persdljoy.h"
}
#endif


#ifdef HAVE_LIBGL
extern "C" {
#include "../vidogl.h"
#include "../ygl.h"
}
#endif

#ifdef HAVE_VULKAN
#include <vulkan/vulkan.h>
extern "C" {
#include "../vulkan/VIDVulkanCInterface.h"
}
#include "../vulkan/VIDVulkan.h"
#include "../vulkan/Renderer.h"
#endif

#ifdef YAB_PORT_OSD
extern "C" {
#include "../nanovg/nanovg_osdcore.h"
}
#endif

M68K_struct *M68KCoreList[] = {
    &M68KDummy,
#ifdef HAVE_MUSASHI
    &M68KMusashi,
#endif
#ifdef HAVE_C68K
    &M68KC68K,
#endif
    NULL
};

SH2Interface_struct *SH2CoreList[] = {
    &SH2Interpreter,
    &SH2DebugInterpreter,
#ifdef DYNAREC_DEVMIYAX
    &SH2Dyn,
#endif
#ifdef SH2_DYNAREC
    &SH2Dynarec,
#endif
    NULL
};

PerInterface_struct *PERCoreList[] = {
    &PERDummy,
#ifdef HAVE_LIBSDL
    &PERSDLJoy,
#endif
    NULL
};

CDInterface *CDCoreList[] = {
    &DummyCD,
    &ISOCD,
#ifndef UNKNOWN_ARCH
    &ArchCD,
#endif
    NULL
};

SoundInterface_struct *SNDCoreList[] = {
    &SNDDummy,
#ifdef HAVE_LIBSDL
    &SNDSDL,
#endif
    NULL
};

VideoInterface_struct *VIDCoreList[] = {
    &VIDDummy,
#ifdef HAVE_VULKAN
    &CVIDVulkan,
#endif
#ifdef HAVE_LIBGL
    &VIDOGL,
#endif
    &VIDSoft,
    NULL
};

#ifdef YAB_PORT_OSD
OSD_struct *OSDCoreList[] = {
#ifdef HAVE_VULKAN
    &OSDNnovgVulkan,
#endif
    &OSDNnovg,
    NULL
};
#endif

static volatile int g_running = 1;

static char biospath[512] = "\0";
static char cdpath[512]   = "\0";
static char buppath[512]  = "/mnt/games/data/saves/stn_backup.bin";
static char cartpath[512] = "\0";

extern "C" void YuiErrorMsg(const char *string) {
    fprintf(stderr, "YabaSanshiro: %s\n", string);
}

extern "C" void YuiSwapBuffers(void) {
    VIDVulkan::getInstance()->present();
    return;
}

extern "C" int YuiUseOGLOnThisThread(void) {
    return 0;
}

extern "C" int YuiRevokeOGLOnThisThread(void) {
    return 0;
}

extern "C" const char *YuiGetShaderCachePath(void) {
    return "/mnt/games/data/.cache/";
}

static void signal_handler(int sig) {
    (void)sig;
    g_running = 0;
}

static void crash_handler(int sig) {
    fprintf(stderr, "[CRASH] Signal %d received (", sig);
    if (sig == SIGSEGV) fprintf(stderr, "SIGSEGV");
    else if (sig == SIGABRT) fprintf(stderr, "SIGABRT");
    else if (sig == SIGBUS) fprintf(stderr, "SIGBUS");
    else if (sig == SIGFPE) fprintf(stderr, "SIGFPE");
    fprintf(stderr, ")\n");
    _exit(128 + sig);
}

void print_usage(const char *prog) {
    printf("Usage: %s [options]\n"
           "Options:\n"
           "  -b, --bios=PATH     Saturn BIOS file\n"
           "  -i, --iso=PATH      Disc image (ISO/CUE/CHD)\n"
           "  -h, --help          Show this help\n",
           prog);
}

int yabauseinit() {
    yabauseinit_struct yinit = {};

    yinit.m68kcoretype  = M68KCORE_C68K;
    yinit.sh2coretype   = 3; // DYNRAEC_DEVMIYAX
    yinit.vidcoretype   = VIDCORE_VULKAN;
    yinit.sndcoretype   = SNDCORE_SDL;
    yinit.percoretype   = PERCORE_SDLJOY;
    yinit.cdcoretype    = CDCORE_ISO;
    yinit.carttype      = CART_DRAM32MBIT;
    yinit.regionid      = REGION_AUTODETECT;
    yinit.biospath      = biospath;
    yinit.cdpath        = cdpath;
    yinit.buppath       = buppath;
    yinit.mpegpath      = NULL;
    yinit.cartpath      = cartpath;
    yinit.videoformattype = VIDEOFORMATTYPE_NTSC;
    yinit.osdcoretype   = OSDCORE_DUMMY;
    yinit.skip_load     = 0;
    yinit.usethreads    = 0;
    yinit.polygon_generation_mode = PERSPECTIVE_CORRECTION;
    yinit.frameskip     = 1;
    yinit.use_new_scsp  = 1;
    yinit.scsp_sync_count_per_frame = 64;
    yinit.scsp_main_mode = 0;
    yinit.extend_backup = 1;
    yinit.use_sh2_cache = 0;

    if (YabauseInit(&yinit) != 0) {
        fprintf(stderr, "YabauseInit failed\n");
        return 1;
    }

    LogStart();
    LogChangeOutput(DEBUG_STDERR, NULL);
    return 0;
}

int main(int argc, char *argv[]) {
    signal(SIGTERM, signal_handler);
    signal(SIGINT,  signal_handler);
    signal(SIGSEGV, crash_handler);
    signal(SIGABRT, crash_handler);
    signal(SIGBUS,  crash_handler);

    for (int i = 1; i < argc; i++) {
        if (!argv[i]) continue;

        if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
            print_usage(argv[0]);
            return 0;
        }
        else if (strcmp(argv[i], "-b") == 0 && i + 1 < argc) {
            strncpy(biospath, argv[++i], sizeof(biospath) - 1);
        }
        else if (strstr(argv[i], "--bios=") == argv[i]) {
            strncpy(biospath, argv[i] + 7, sizeof(biospath) - 1);
        }
        else if (strcmp(argv[i], "-i") == 0 && i + 1 < argc) {
            strncpy(cdpath, argv[++i], sizeof(cdpath) - 1);
        }
        else if (strstr(argv[i], "--iso=") == argv[i]) {
            strncpy(cdpath, argv[i] + 6, sizeof(cdpath) - 1);
        }
    }

    if (SDL_Init(SDL_INIT_AUDIO | SDL_INIT_JOYSTICK | SDL_INIT_GAMECONTROLLER) < 0) {
        fprintf(stderr, "SDL_Init failed: %s\n", SDL_GetError());
        return 1;
    }

    Renderer *r = new Renderer();
    r->OpenWindow(0, 0, "YabaSanshiro", nullptr);
    VIDVulkan::getInstance()->setRenderer(r);

    VkExtent2D surfSize = r->getWindow()->GetVulkanSurfaceSize();
    int w = surfSize.width;
    int h = surfSize.height;
    fprintf(stderr, "YabaSanshiro: display %dx%d (VK_KHR_display)\n", w, h);

    if (yabauseinit() > 0) {
        fprintf(stderr, "YabauseInit failed!\n");
        return 1;
    }

    VIDCore->SetSettingValue(VDP_SETTING_ASPECT_RATE_MODE, _4_3);
    VIDCore->SetSettingValue(VDP_SETTING_RESOLUTION_MODE, RES_NATIVE);
    VIDCore->Resize(0, 0, w, h, 0, 1);

    #define JOY_BTN(joy, btn)       ((joy) << 18 | ((btn) + 1))
    #define JOY_AXIS_POS(joy, axis) ((joy) << 18 | 0x110000 | (axis))
    #define JOY_AXIS_NEG(joy, axis) ((joy) << 18 | 0x100000 | (axis))
    #define JOY_HAT(joy, hat, dir)  ((joy) << 18 | 0x200000 | ((dir) << 4) | (hat))

    {
        PerPortReset();
        void *pad1 = PerPadAdd(&PORTDATA1);
        PerSetKey(JOY_BTN(0, 13), PERPAD_UP,    pad1);
        PerSetKey(JOY_BTN(0, 14), PERPAD_DOWN,  pad1);
        PerSetKey(JOY_BTN(0, 15), PERPAD_LEFT,  pad1);
        PerSetKey(JOY_BTN(0, 16), PERPAD_RIGHT, pad1);
        PerSetKey(JOY_BTN(0, 0),  PERPAD_A, pad1);
        PerSetKey(JOY_BTN(0, 1),  PERPAD_B, pad1);
        PerSetKey(JOY_BTN(0, 6),  PERPAD_C, pad1);
        PerSetKey(JOY_BTN(0, 2),  PERPAD_X, pad1);
        PerSetKey(JOY_BTN(0, 3),  PERPAD_Y, pad1);
        PerSetKey(JOY_BTN(0, 7),  PERPAD_Z, pad1);
        PerSetKey(JOY_BTN(0, 4),  PERPAD_LEFT_TRIGGER,  pad1);
        PerSetKey(JOY_BTN(0, 5),  PERPAD_RIGHT_TRIGGER, pad1);
        PerSetKey(JOY_BTN(0, 9),  PERPAD_START, pad1);
    }

    SDL_Joystick *joy0 = SDL_JoystickOpen(0);
    int prev_l3 = 0, prev_r3 = 0;

    SDL_Event event;
    while (g_running) {
        while (SDL_PollEvent(&event)) {
            if (event.type == SDL_QUIT)
                g_running = 0;
        }

        if (joy0) {
            int guide = SDL_JoystickGetButton(joy0, 10);
            int l3    = SDL_JoystickGetButton(joy0, 11);
            int r3    = SDL_JoystickGetButton(joy0, 12);

            if (guide && r3 && !prev_r3) {
                YabSaveStateSlot("/mnt/games/data/states", 0);
                fprintf(stderr, "YabaSanshiro: state saved\n");
            }
            if (guide && l3 && !prev_l3) {
                YabLoadStateSlot("/mnt/games/data/states", 0);
                fprintf(stderr, "YabaSanshiro: state loaded\n");
            }
            prev_l3 = l3;
            prev_r3 = r3;
        }

        if (PERCore && PERCore->HandleEvents() == -1)
            g_running = 0;
    }

    if (joy0) SDL_JoystickClose(joy0);

    YabauseDeInit();
    LogStop();

    SDL_Quit();

    return 0;
}

extern "C" {
    int YabauseThread_IsUseBios() { return 0; }
    void YabauseThread_setUseBios(int use) {}
    const char *YabauseThread_getBackupPath() { return buppath; }
    void YabauseThread_setBackupPath(const char *buf) { strcpy(buppath, buf); }
    void YabauseThread_resetPlaymode() {}
    void YabauseThread_coldBoot() {
        YabauseDeInit();
        yabauseinit();
        YabauseReset();
    }
}
