#define _GNU_SOURCE

#include "shared.h"
#include <linux/input.h>
#include <sys/ioctl.h>

#define MAX_INPUT_DEVICES 3
#define WAKE_DEBOUNCE_MS 500

static int input_fds[MAX_INPUT_DEVICES] = {-1, -1, -1};
static int num_devices = 0;
static struct timespec power_press_time = {0};
static struct timespec last_wake_time = {0};
static bool power_button_held = false;
static bool mode_button_held = false;

// Currently 4-100 in 7 steps of 16, default to ~50%
static int current_brightness = 52;

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
            printf("Found input device: %s (%s)\n", path, name);
            closedir(dir);
            return fd;
        }
        close(fd);
    }

    closedir(dir);
    return -1;
}

bool input_monitor_init(void)
{
    num_devices = 0;
    const char *device_names[] = {
        "joypad",    // Mode
        "pwrkey",    // Power
        "gpio-keys"  // Volume + Lid
    };

    for (int i = 0; i < MAX_INPUT_DEVICES; i++)
    {
        int fd = find_device_by_name(device_names[i]);
        if (fd >= 0 && num_devices < MAX_INPUT_DEVICES)
        {
            input_fds[num_devices++] = fd;
        }
        else
        {
            fprintf(stderr, "Warning: Could not find device '%s'\n", device_names[i]);
        }
    }

    if (num_devices == 0)
    {
        fprintf(stderr, "Failed to open any input devices\n");
        return false;
    }

    printf("Monitoring %d input device(s)\n", num_devices);
    return true;
}

bool input_monitor_check_hotkeys(void)
{
    struct input_event ev;

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

                    if (held_ms >= 1750)
                        return true;

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
                if (mode_button_held && backlight_on)
                {
                    // Can't get brighter than physically possible
                    if (current_brightness < 100)
                    {
                        current_brightness += 16;
                        char cmd[128];
                        snprintf(cmd, sizeof(cmd),
                                 "echo %d > /sys/class/backlight/backlight/brightness",
                                 (int)(current_brightness * 255 / 100));
                        system(cmd);
                    }
                }
                else
                {
                    system("amixer -q -c 0 sset 'Master' 5%+");
                }
                break;

            case KEY_VOLUMEDOWN:
                if (ev.value != 1)
                    continue;
                if (mode_button_held && backlight_on)
                {
                    // Don't go completely dark
                    if (current_brightness > 4)
                    {
                        current_brightness -= 16;
                        char cmd[128];
                        snprintf(cmd, sizeof(cmd),
                                 "echo %d > /sys/class/backlight/backlight/brightness",
                                 (int)(current_brightness * 255 / 100));
                        system(cmd);
                    }
                }
                else
                {
                    system("amixer -q -c 0 sset 'Master' 5%-");
                }
                break;

            case SW_LID:
                if (ev.value == 1)
                {
                    system("echo mem > /sys/power/state");
                    clock_gettime(CLOCK_MONOTONIC, &last_wake_time);
                }
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
            return true;
    }

    return false;
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
    num_devices = 0;
    mode_button_held = false;
    power_button_held = false;
}
