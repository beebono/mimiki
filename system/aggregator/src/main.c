#define _GNU_SOURCE

// MIROKI input aggregator
//
// Merges the RG Rotate's split input hardware into one virtual gamepad:
//   - gpio-keys-gamepad: every button as a discrete GPIO (grabbed exclusively)
//   - sc27xx vibrator:   a separate ff-memless evdev node
// SDL only exposes rumble on the joystick's own evdev node, so without this
// daemon SDL_GameControllerRumble reports unsupported. The virtual device
// carries the buttons AND FF_RUMBLE, with effect uploads proxied through.
//
// Also provides a dpad<->virtual-analog toggle for stickless play:
// holding MODE and pressing THUMBR (the vestigial stick-click pad) switches
// the dpad between BTN_DPAD_* passthrough and ABS_X/ABS_Y emission.
//
// Mode control from the launcher (pid in /tmp/mimiki-inputd.pid):
//   SIGUSR1: N64 shift mode - while TR2 (R2) is held, the four face buttons
//            emit BTN_TRIGGER_HAPPY1-4 (C-up/down/left/right) instead, and
//            TR2 itself is swallowed as the dedicated shift key.
//   SIGUSR2: back to defaults - shift off, dpad mode restored, everything
//            recentered/released (the launcher only navigates by dpad).

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <linux/input.h>
#include <linux/uinput.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define GAMEPAD_NAME  "gpio-keys-gamepad"
#define VIBRA_NAME    "vibrator"
#define VIRTUAL_NAME  "MIMIKI Gamepad"
#define MAX_FF_SLOTS  8
#define ANALOG_MAX    32767

static int gamepad_fd = -1;
static int vibra_fd = -1;
static int uinput_fd = -1;

// uinput effect id -> vibrator effect id (or -1)
static int ff_map[MAX_FF_SLOTS];

static bool analog_mode = false;
static bool mode_held = false;
static bool n64_mode = false;
static bool tr2_held = false;
// Keycode emitted at press time for each face button (0 = not pressed), so
// a release always matches its press even if the shift state changed between
static int face_down_code[4];
static volatile sig_atomic_t running = 1;
static volatile sig_atomic_t n64_request = -1; // -1 none, 0 disable, 1 enable

static void handle_signal(int sig)
{
    (void)sig;
    running = 0;
}

static void handle_mode_signal(int sig)
{
    n64_request = (sig == SIGUSR1) ? 1 : 0;
}

// Log to the kernel ring buffer so failures are visible in dmesg -
// there is no persistent console on this device.
static void klog(const char *fmt, ...)
{
    static int kmsg_fd = -2;
    if (kmsg_fd == -2)
        kmsg_fd = open("/dev/kmsg", O_WRONLY);

    char buf[256];
    int n = snprintf(buf, sizeof(buf), "mimiki-inputd: ");
    va_list ap;
    va_start(ap, fmt);
    n += vsnprintf(buf + n, sizeof(buf) - n, fmt, ap);
    va_end(ap);

    if (kmsg_fd >= 0)
        write(kmsg_fd, buf, n);
    fprintf(stderr, "%s\n", buf);
}

static int find_device_by_name(const char *device_name, bool grab)
{
    DIR *dir = opendir("/dev/input");
    if (!dir)
        return -1;

    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL)
    {
        if (strncmp(entry->d_name, "event", 5) != 0)
            continue;

        char path[512];
        snprintf(path, sizeof(path), "/dev/input/%s", entry->d_name);

        int fd = open(path, O_RDWR | O_NONBLOCK);
        if (fd < 0)
            continue;

        char name[256] = "Unknown";
        ioctl(fd, EVIOCGNAME(sizeof(name)), name);
        if (strstr(name, device_name) != NULL)
        {
            if (grab && ioctl(fd, EVIOCGRAB, 1) < 0)
                fprintf(stderr, "aggregator: failed to grab %s: %s\n",
                        path, strerror(errno));
            closedir(dir);
            return fd;
        }
        close(fd);
    }

    closedir(dir);
    return -1;
}

static const int forwarded_keys[] = {
    BTN_SOUTH, BTN_EAST, BTN_NORTH, BTN_WEST,
    BTN_TL, BTN_TR, BTN_TL2, BTN_TR2,
    BTN_SELECT, BTN_START, BTN_MODE, BTN_THUMBR,
    BTN_DPAD_UP, BTN_DPAD_DOWN, BTN_DPAD_LEFT, BTN_DPAD_RIGHT,
    // N64 C-buttons, emitted by the R2-shifted face buttons (joystick
    // buttons 16-19: C-up, C-down, C-left, C-right)
    BTN_TRIGGER_HAPPY1, BTN_TRIGGER_HAPPY2,
    BTN_TRIGGER_HAPPY3, BTN_TRIGGER_HAPPY4,
};

// Face-button index (SOUTH/EAST/NORTH/WEST) -> shifted C-button code.
// Layout mirrors the C cluster: NORTH=C-up, SOUTH=C-down, WEST=C-left,
// EAST=C-right.
static int face_index(int code)
{
    switch (code)
    {
    case BTN_SOUTH: return 0;
    case BTN_EAST:  return 1;
    case BTN_NORTH: return 2;
    case BTN_WEST:  return 3;
    default:        return -1;
    }
}

static const int face_shift_code[4] = {
    BTN_TRIGGER_HAPPY2, // SOUTH -> C-down
    BTN_TRIGGER_HAPPY4, // EAST  -> C-right
    BTN_TRIGGER_HAPPY1, // NORTH -> C-up
    BTN_TRIGGER_HAPPY3, // WEST  -> C-left
};

static int create_virtual_pad(void)
{
    int fd = open("/dev/uinput", O_RDWR | O_NONBLOCK);
    if (fd < 0)
    {
        fprintf(stderr, "aggregator: cannot open /dev/uinput: %s\n",
                strerror(errno));
        return -1;
    }

    ioctl(fd, UI_SET_EVBIT, EV_KEY);
    for (size_t i = 0; i < sizeof(forwarded_keys) / sizeof(forwarded_keys[0]); i++)
        ioctl(fd, UI_SET_KEYBIT, forwarded_keys[i]);

    ioctl(fd, UI_SET_EVBIT, EV_ABS);
    ioctl(fd, UI_SET_ABSBIT, ABS_X);
    ioctl(fd, UI_SET_ABSBIT, ABS_Y);

    if (vibra_fd >= 0)
    {
        ioctl(fd, UI_SET_EVBIT, EV_FF);
        ioctl(fd, UI_SET_FFBIT, FF_RUMBLE);
        ioctl(fd, UI_SET_FFBIT, FF_PERIODIC);
        ioctl(fd, UI_SET_FFBIT, FF_SQUARE);
        ioctl(fd, UI_SET_FFBIT, FF_TRIANGLE);
        ioctl(fd, UI_SET_FFBIT, FF_SINE);
        ioctl(fd, UI_SET_FFBIT, FF_GAIN);
    }

    struct uinput_user_dev uidev;
    memset(&uidev, 0, sizeof(uidev));
    snprintf(uidev.name, UINPUT_MAX_NAME_SIZE, VIRTUAL_NAME);
    uidev.id.bustype = BUS_HOST;
    uidev.id.vendor = 0x4d49;  // "MI"
    uidev.id.product = 0x4b49; // "KI"
    uidev.id.version = 1;
    uidev.absmin[ABS_X] = -ANALOG_MAX;
    uidev.absmax[ABS_X] = ANALOG_MAX;
    uidev.absmin[ABS_Y] = -ANALOG_MAX;
    uidev.absmax[ABS_Y] = ANALOG_MAX;
    uidev.ff_effects_max = (vibra_fd >= 0) ? MAX_FF_SLOTS : 0;

    if (write(fd, &uidev, sizeof(uidev)) != sizeof(uidev) ||
        ioctl(fd, UI_DEV_CREATE) < 0)
    {
        fprintf(stderr, "aggregator: uinput device creation failed: %s\n",
                strerror(errno));
        close(fd);
        return -1;
    }

    return fd;
}

static void emit(int fd, unsigned short type, unsigned short code, int value)
{
    struct input_event ev;
    memset(&ev, 0, sizeof(ev));
    ev.type = type;
    ev.code = code;
    ev.value = value;
    write(fd, &ev, sizeof(ev));
}

// The vibrator is a bare LDO gate: magnitude is effectively on/off. Convert
// whatever effect the client uploads into a rumble the sc27xx driver plays
// (it takes max(strong, weak)).
static void ff_upload(struct uinput_ff_upload *upload)
{
    struct ff_effect effect = upload->effect;

    if (upload->effect.id >= MAX_FF_SLOTS)
    {
        upload->retval = -ENOSPC;
        return;
    }

    // Reuse the previously-mapped slot on re-upload
    effect.id = ff_map[upload->effect.id];

    if (ioctl(vibra_fd, EVIOCSFF, &effect) < 0)
    {
        upload->retval = -errno;
        return;
    }

    ff_map[upload->effect.id] = effect.id;
    upload->retval = 0;
}

static void ff_erase(struct uinput_ff_erase *erase)
{
    if (erase->effect_id >= MAX_FF_SLOTS || ff_map[erase->effect_id] < 0)
    {
        erase->retval = -EINVAL;
        return;
    }

    ioctl(vibra_fd, EVIOCRMFF, ff_map[erase->effect_id]);
    ff_map[erase->effect_id] = -1;
    erase->retval = 0;
}

static void handle_uinput_event(void)
{
    struct input_event ev;

    while (read(uinput_fd, &ev, sizeof(ev)) == sizeof(ev))
    {
        if (ev.type == EV_UINPUT)
        {
            if (ev.code == UI_FF_UPLOAD)
            {
                struct uinput_ff_upload upload;
                memset(&upload, 0, sizeof(upload));
                upload.request_id = ev.value;
                ioctl(uinput_fd, UI_BEGIN_FF_UPLOAD, &upload);
                ff_upload(&upload);
                ioctl(uinput_fd, UI_END_FF_UPLOAD, &upload);
            }
            else if (ev.code == UI_FF_ERASE)
            {
                struct uinput_ff_erase erase;
                memset(&erase, 0, sizeof(erase));
                erase.request_id = ev.value;
                ioctl(uinput_fd, UI_BEGIN_FF_ERASE, &erase);
                ff_erase(&erase);
                ioctl(uinput_fd, UI_END_FF_ERASE, &erase);
            }
        }
        else if (ev.type == EV_FF)
        {
            // Play/stop request: forward with the mapped effect id
            if (ev.code < MAX_FF_SLOTS && ff_map[ev.code] >= 0)
                emit(vibra_fd, EV_FF, ff_map[ev.code], ev.value);
            else if (ev.code == FF_GAIN)
                emit(vibra_fd, EV_FF, FF_GAIN, ev.value);
        }
    }
}

static void handle_gamepad_event(void)
{
    struct input_event ev;

    while (read(gamepad_fd, &ev, sizeof(ev)) == sizeof(ev))
    {
        if (ev.type == EV_SYN)
        {
            emit(uinput_fd, EV_SYN, SYN_REPORT, 0);
            continue;
        }

        if (ev.type != EV_KEY)
            continue;

        int fi = face_index(ev.code);
        if (fi >= 0)
        {
            // Press picks plain or shifted code; release/repeat reuses
            // whatever the press emitted so nothing gets stuck
            if (ev.value == 1)
                face_down_code[fi] = (n64_mode && tr2_held)
                    ? face_shift_code[fi] : ev.code;
            int out = face_down_code[fi] ? face_down_code[fi] : ev.code;
            emit(uinput_fd, EV_KEY, out, ev.value);
            if (ev.value == 0)
                face_down_code[fi] = 0;
            continue;
        }

        switch (ev.code)
        {
        case BTN_TR2:
            tr2_held = (ev.value != 0);
            // In N64 mode R2 is the dedicated C-button shift; swallow it
            if (!n64_mode)
                emit(uinput_fd, EV_KEY, ev.code, ev.value);
            break;

        case BTN_MODE:
            mode_held = (ev.value != 0);
            emit(uinput_fd, EV_KEY, ev.code, ev.value);
            break;

        case BTN_THUMBR:
            // MODE+THUMBR toggles dpad<->analog; swallow the press so the
            // toggle chord doesn't leak a stray button to the game
            if (mode_held && ev.value == 1)
            {
                analog_mode = !analog_mode;
                // Recenter/release everything the old mode may have latched
                emit(uinput_fd, EV_ABS, ABS_X, 0);
                emit(uinput_fd, EV_ABS, ABS_Y, 0);
                emit(uinput_fd, EV_KEY, BTN_DPAD_UP, 0);
                emit(uinput_fd, EV_KEY, BTN_DPAD_DOWN, 0);
                emit(uinput_fd, EV_KEY, BTN_DPAD_LEFT, 0);
                emit(uinput_fd, EV_KEY, BTN_DPAD_RIGHT, 0);
            }
            else if (!mode_held)
            {
                emit(uinput_fd, EV_KEY, ev.code, ev.value);
            }
            break;

        case BTN_DPAD_UP:
            if (analog_mode)
                emit(uinput_fd, EV_ABS, ABS_Y, ev.value ? -ANALOG_MAX : 0);
            else
                emit(uinput_fd, EV_KEY, ev.code, ev.value);
            break;

        case BTN_DPAD_DOWN:
            if (analog_mode)
                emit(uinput_fd, EV_ABS, ABS_Y, ev.value ? ANALOG_MAX : 0);
            else
                emit(uinput_fd, EV_KEY, ev.code, ev.value);
            break;

        case BTN_DPAD_LEFT:
            if (analog_mode)
                emit(uinput_fd, EV_ABS, ABS_X, ev.value ? -ANALOG_MAX : 0);
            else
                emit(uinput_fd, EV_KEY, ev.code, ev.value);
            break;

        case BTN_DPAD_RIGHT:
            if (analog_mode)
                emit(uinput_fd, EV_ABS, ABS_X, ev.value ? ANALOG_MAX : 0);
            else
                emit(uinput_fd, EV_KEY, ev.code, ev.value);
            break;

        default:
            emit(uinput_fd, EV_KEY, ev.code, ev.value);
            break;
        }
    }
}

static void write_pidfile(void)
{
    FILE *f = fopen("/tmp/mimiki-inputd.pid", "w");
    if (f)
    {
        fprintf(f, "%d\n", getpid());
        fclose(f);
    }
}

int main(void)
{
    signal(SIGTERM, handle_signal);
    signal(SIGINT, handle_signal);
    signal(SIGUSR1, handle_mode_signal);
    signal(SIGUSR2, handle_mode_signal);
    write_pidfile();

    for (int i = 0; i < MAX_FF_SLOTS; i++)
        ff_map[i] = -1;

    // The gamepad must exist; the vibrator is optional (rumble just absent).
    // Wait for the device rather than dying if we raced device creation.
    for (int tries = 0; tries < 100; tries++)
    {
        gamepad_fd = find_device_by_name(GAMEPAD_NAME, true);
        if (gamepad_fd >= 0)
            break;
        usleep(100000);
    }
    if (gamepad_fd < 0)
    {
        klog("gamepad device '%s' not found after 10s, giving up", GAMEPAD_NAME);
        return 1;
    }

    vibra_fd = find_device_by_name(VIBRA_NAME, false);
    if (vibra_fd < 0)
        klog("vibrator '%s' not found, rumble disabled", VIBRA_NAME);

    uinput_fd = create_virtual_pad();
    if (uinput_fd < 0)
    {
        klog("uinput device creation failed: %s", strerror(errno));
        close(gamepad_fd);
        return 1;
    }

    klog("up: virtual pad created (gamepad grabbed, rumble %s)",
         vibra_fd >= 0 ? "on" : "off");

    struct pollfd fds[2] = {
        {.fd = gamepad_fd, .events = POLLIN},
        {.fd = uinput_fd, .events = POLLIN},
    };

    while (running)
    {
        if (n64_request >= 0)
        {
            n64_mode = (n64_request == 1);
            n64_request = -1;
            if (!n64_mode)
            {
                // Emulator exited: restore dpad navigation for the launcher
                // and release anything a mode change may have latched
                analog_mode = false;
                emit(uinput_fd, EV_ABS, ABS_X, 0);
                emit(uinput_fd, EV_ABS, ABS_Y, 0);
                emit(uinput_fd, EV_KEY, BTN_DPAD_UP, 0);
                emit(uinput_fd, EV_KEY, BTN_DPAD_DOWN, 0);
                emit(uinput_fd, EV_KEY, BTN_DPAD_LEFT, 0);
                emit(uinput_fd, EV_KEY, BTN_DPAD_RIGHT, 0);
                emit(uinput_fd, EV_KEY, BTN_TRIGGER_HAPPY1, 0);
                emit(uinput_fd, EV_KEY, BTN_TRIGGER_HAPPY2, 0);
                emit(uinput_fd, EV_KEY, BTN_TRIGGER_HAPPY3, 0);
                emit(uinput_fd, EV_KEY, BTN_TRIGGER_HAPPY4, 0);
                emit(uinput_fd, EV_SYN, SYN_REPORT, 0);
                for (int i = 0; i < 4; i++)
                    face_down_code[i] = 0;
            }
        }

        if (poll(fds, 2, -1) < 0)
        {
            if (errno == EINTR)
                continue;
            break;
        }

        if (fds[0].revents & POLLIN)
            handle_gamepad_event();
        if (fds[1].revents & POLLIN)
            handle_uinput_event();
    }

    ioctl(uinput_fd, UI_DEV_DESTROY);
    close(uinput_fd);
    ioctl(gamepad_fd, EVIOCGRAB, 0);
    close(gamepad_fd);
    if (vibra_fd >= 0)
        close(vibra_fd);

    return 0;
}
