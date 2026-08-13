#define _GNU_SOURCE

#include "shared.h"
#include <linux/input.h>
#include <sys/ioctl.h>

#define MAX_INPUT_DEVICES 4
#define WAKE_DEBOUNCE_MS 500

static int input_fds[MAX_INPUT_DEVICES] = {-1, -1, -1, -1};
static int num_devices = 0;
static struct timespec power_press_time = {0};
static struct timespec last_wake_time = {0};
static bool power_button_held = false;
static bool mode_button_held = false;

// Brightness: 4-100% in 7 steps of 16, default to ~50%
static int current_brightness = 52;

// Volume: softvol user control from /etc/asound.conf (16 steps, -45..0dB).
// The HP hardware "gains" are attenuators pinned by rcS; softvol is the
// only runtime volume, like ROCKNIX does it in pipewire.
static int current_volume = 6;

static void set_hp_volume(int vol)
{
    char cmd[160];
    snprintf(cmd, sizeof(cmd),
             "amixer -q -c 0 cset name='MIMIKI Playback Volume' %d,%d",
             vol, vol);
    system(cmd);
}

static int find_device_by_name(const char *device_name)
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

        int fd = open(path, O_RDONLY | O_NONBLOCK);
        if (fd < 0)
            continue;

        char name[256] = "Unknown";
        ioctl(fd, EVIOCGNAME(sizeof(name)), name);
        if (strstr(name, device_name) != NULL)
        {
            closedir(dir);
            return fd;
        }
        close(fd);
    }

    closedir(dir);
    return -1;
}

static const char *device_names[] = {
    "MIMIKI Gamepad",  // Aggregated pad (raw gamepad_keys is grabbed by mimiki-inputd)
    "gpio-keys-system", // Power + Volume + Hall swivel
};
#define NUM_DEVICE_NAMES ((int)(sizeof(device_names) / sizeof(device_names[0])))

static int named_fds[NUM_DEVICE_NAMES] = {-1, -1};
static struct timespec last_rescan_time = {0};

// The aggregator's virtual pad can appear after we start (or respawn after a
// crash), so keep rescanning for missing devices rather than failing once.
static void rescan_missing_devices(void)
{
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    long since_ms = (now.tv_sec - last_rescan_time.tv_sec) * 1000 +
                    (now.tv_nsec - last_rescan_time.tv_nsec) / 1000000;
    if (since_ms < 2000)
        return;
    last_rescan_time = now;

    num_devices = 0;
    for (int i = 0; i < NUM_DEVICE_NAMES; i++)
    {
        if (named_fds[i] < 0)
            named_fds[i] = find_device_by_name(device_names[i]);
        if (named_fds[i] >= 0)
            input_fds[num_devices++] = named_fds[i];
    }
}

bool input_monitor_init(void)
{
    num_devices = 0;
    for (int i = 0; i < NUM_DEVICE_NAMES; i++)
    {
        named_fds[i] = find_device_by_name(device_names[i]);
        if (named_fds[i] >= 0)
            input_fds[num_devices++] = named_fds[i];
    }

    if (num_devices == 0)
        return false;

    return true;
}

void input_monitor_poll(InputEvents *events)
{
    struct input_event ev;

    if (num_devices < NUM_DEVICE_NAMES)
        rescan_missing_devices();

    for (int i = 0; i < num_devices; i++)
    {
        if (input_fds[i] < 0)
            continue;

        while (read(input_fds[i], &ev, sizeof(ev)) == sizeof(ev))
        {
            if (ev.type != EV_KEY && ev.type != EV_SW)
                continue;

            switch (ev.code)
            {
            case BTN_MODE:
                mode_button_held = (ev.value == 1 || ev.value == 2);
                break;

            case KEY_POWER:
            {
                if (ev.value == 1 && !power_button_held)
                {
                    clock_gettime(CLOCK_MONOTONIC, &power_press_time);
                    power_button_held = true;
                }
                else if (ev.value == 0 && power_button_held)
                {
                    struct timespec now;
                    clock_gettime(CLOCK_MONOTONIC, &now);
                    long held_ms = (now.tv_sec - power_press_time.tv_sec) * 1000 +
                                   (now.tv_nsec - power_press_time.tv_nsec) / 1000000;
                    power_button_held = false;

                    if (held_ms >= 1750) {
                        events->shutdown = true;
                        return;
                    }

                    long last_wake_ms = (now.tv_sec - last_wake_time.tv_sec) * 1000 +
                                        (now.tv_nsec - last_wake_time.tv_nsec) / 1000000;
                    if (last_wake_ms < WAKE_DEBOUNCE_MS)
                        continue;

                    system("echo mem > /sys/power/state");
                    clock_gettime(CLOCK_MONOTONIC, &last_wake_time);
                }
                break;
            }

            case KEY_VOLUMEUP:
                if (ev.value != 1)
                    continue;
                if (mode_button_held)
                {
                    if (current_brightness < 100)
                    {
                        current_brightness += 16;
                        char cmd[128];
                        snprintf(cmd, sizeof(cmd),
                                 "echo %d > /sys/class/backlight/backlight/brightness",
                                 (int)(current_brightness * 4095 / 100));
                        system(cmd);
                    }
                }
                else
                {
                    if (current_volume < 15)
                        set_hp_volume(++current_volume);
                }
                break;

            case KEY_VOLUMEDOWN:
                if (ev.value != 1)
                    continue;
                if (mode_button_held)
                {
                    if (current_brightness > 4)
                    {
                        current_brightness -= 16;
                        char cmd[128];
                        snprintf(cmd, sizeof(cmd),
                                 "echo %d > /sys/class/backlight/backlight/brightness",
                                 (int)(current_brightness * 4095 / 100));
                        system(cmd);
                    }
                }
                else
                {
                    if (current_volume > 0)
                        set_hp_volume(--current_volume);
                }
                break;

            case BTN_START:
                if (ev.value == 1 && mode_button_held)
                    events->exit_emu = true;
                break;

            case SW_LID:
                if (ev.value == 1)
                {
                    system("echo mem > /sys/power/state");
                    clock_gettime(CLOCK_MONOTONIC, &last_wake_time);
                }
                break;

            // Navigation
            case BTN_DPAD_UP:
                if (ev.value == 1)
                    events->nav_up = true;
                break;

            case BTN_DPAD_DOWN:
                if (ev.value == 1)
                    events->nav_down = true;
                break;

            case BTN_DPAD_LEFT:
                if (ev.value == 1)
                    events->nav_left = true;
                break;

            case BTN_DPAD_RIGHT:
                if (ev.value == 1)
                    events->nav_right = true;
                break;

            // A selects, B backs out. The aggregator emits proper
            // positional codes, unlike the Flip's rocknix_joypad which
            // shipped A/B swapped - hence the flip vs. the Flip layout.
            case BTN_SOUTH:
                if (ev.value == 1)
                    events->nav_select = true;
                break;

            case BTN_EAST:
                if (ev.value == 1)
                    events->nav_back = true;
                break;
            }
        }
    }

    if (power_button_held)
    {
        struct timespec now;
        clock_gettime(CLOCK_MONOTONIC, &now);
        long held_ms = (now.tv_sec - power_press_time.tv_sec) * 1000 +
                       (now.tv_nsec - power_press_time.tv_nsec) / 1000000;
        if (held_ms >= 1750)
            events->shutdown = true;
    }
}

void input_monitor_cleanup(void)
{
    for (int i = 0; i < num_devices; i++)
    {
        if (input_fds[i] >= 0)
        {
            close(input_fds[i]);
            input_fds[i] = -1;
        }
    }
    for (int i = 0; i < NUM_DEVICE_NAMES; i++)
        named_fds[i] = -1;
    num_devices = 0;
    mode_button_held = false;
    power_button_held = false;
}
