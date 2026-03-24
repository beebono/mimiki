#define _GNU_SOURCE

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <unistd.h>
#include <fcntl.h>
#include <dirent.h>
#include <time.h>
#include <errno.h>
#include <poll.h>

#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/reboot.h>
#include <linux/fb.h>
#include <linux/input.h>

static const unsigned char font_glyphs[11][7] = {
    /* 0 */ {0x0E, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0E},
    /* 1 */ {0x04, 0x0C, 0x04, 0x04, 0x04, 0x04, 0x0E},
    /* 2 */ {0x0E, 0x11, 0x01, 0x06, 0x08, 0x10, 0x1F},
    /* 3 */ {0x0E, 0x11, 0x01, 0x06, 0x01, 0x11, 0x0E},
    /* 4 */ {0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x02},
    /* 5 */ {0x1F, 0x10, 0x1E, 0x01, 0x01, 0x11, 0x0E},
    /* 6 */ {0x06, 0x08, 0x10, 0x1E, 0x11, 0x11, 0x0E},
    /* 7 */ {0x1F, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08},
    /* 8 */ {0x0E, 0x11, 0x11, 0x0E, 0x11, 0x11, 0x0E},
    /* 9 */ {0x0E, 0x11, 0x11, 0x0F, 0x01, 0x02, 0x0C},
    /* % */ {0x18, 0x19, 0x02, 0x04, 0x08, 0x13, 0x03},
};

static int glyph_index(char c)
{
    if (c >= '0' && c <= '9')
        return c - '0';
    if (c == '%')
        return 10;
    return -1;
}

static int fb_fd = -1;
static unsigned char *fb_mem;
static struct fb_var_screeninfo vinfo;
static struct fb_fix_screeninfo finfo;
static int screen_w, screen_h, bpp, stride;

static bool fb_init(void)
{
    fb_fd = open("/dev/fb0", O_RDWR);
    if (fb_fd < 0) {
        perror("open /dev/fb0");
        return false;
    }

    if (ioctl(fb_fd, FBIOGET_VSCREENINFO, &vinfo) < 0 ||
        ioctl(fb_fd, FBIOGET_FSCREENINFO, &finfo) < 0) {
        perror("ioctl fb");
        close(fb_fd);
        return false;
    }

    screen_w = vinfo.xres;
    screen_h = vinfo.yres;
    bpp = vinfo.bits_per_pixel / 8;
    stride = finfo.line_length;

    fb_mem = mmap(NULL, stride * screen_h, PROT_READ | PROT_WRITE,
                  MAP_SHARED, fb_fd, 0);
    if (fb_mem == MAP_FAILED) {
        perror("mmap fb");
        close(fb_fd);
        return false;
    }

    return true;
}

static void fb_cleanup(void)
{
    if (fb_mem && fb_mem != MAP_FAILED)
        munmap(fb_mem, stride * screen_h);
    if (fb_fd >= 0)
        close(fb_fd);
}

static inline void fb_pixel(int x, int y, unsigned char r, unsigned char g,
                            unsigned char b)
{
    if (x < 0 || x >= screen_w || y < 0 || y >= screen_h)
        return;

    unsigned char *p = fb_mem + y * stride + x * bpp;

    if (bpp == 4) {
        p[0] = b;
        p[1] = g;
        p[2] = r;
        p[3] = 0xFF;
    } else if (bpp == 2) {
        unsigned short c = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3);
        p[0] = c & 0xFF;
        p[1] = c >> 8;
    }
}

static void fb_clear(void)
{
    memset(fb_mem, 0, stride * screen_h);
}

static void fb_fill_rect(int x, int y, int w, int h,
                         unsigned char r, unsigned char g, unsigned char b)
{
    for (int row = y; row < y + h; row++)
        for (int col = x; col < x + w; col++)
            fb_pixel(col, row, r, g, b);
}

static void fb_draw_rect(int x, int y, int w, int h, int thickness,
                         unsigned char r, unsigned char g, unsigned char b)
{
    fb_fill_rect(x, y, w, thickness, r, g, b);
    fb_fill_rect(x, y + h - thickness, w, thickness, r, g, b);
    fb_fill_rect(x, y, thickness, h, r, g, b);
    fb_fill_rect(x + w - thickness, y, thickness, h, r, g, b);
}

static void fb_draw_text(const char *text, int x, int y, int scale,
                         unsigned char r, unsigned char g, unsigned char b)
{
    for (int i = 0; text[i]; i++) {
        int gi = glyph_index(text[i]);
        if (gi < 0) {
            x += 6 * scale;
            continue;
        }

        for (int row = 0; row < 7; row++) {
            unsigned char bits = font_glyphs[gi][row];
            for (int col = 0; col < 5; col++) {
                if (bits & (0x10 >> col))
                    fb_fill_rect(x + col * scale, y + row * scale,
                                 scale, scale, r, g, b);
            }
        }
        x += 6 * scale;
    }
}

static int text_width(const char *text, int scale)
{
    int len = strlen(text);
    if (len == 0)
        return 0;
    return len * 6 * scale - scale;
}

static char batt_cap_path[128];
static char batt_stat_path[128];

static bool find_battery(void)
{
    DIR *dir = opendir("/sys/class/power_supply");
    if (!dir)
        return false;

    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL) {
        if (entry->d_name[0] == '.')
            continue;

        char type_path[160];
        snprintf(type_path, sizeof(type_path),
                 "/sys/class/power_supply/%s/type", entry->d_name);

        FILE *fp = fopen(type_path, "r");
        if (!fp)
            continue;

        char type[32] = "";
        fgets(type, sizeof(type), fp);
        fclose(fp);

        if (strncmp(type, "Battery", 7) == 0) {
            snprintf(batt_cap_path, sizeof(batt_cap_path),
                     "/sys/class/power_supply/%s/capacity", entry->d_name);
            snprintf(batt_stat_path, sizeof(batt_stat_path),
                     "/sys/class/power_supply/%s/status", entry->d_name);
            closedir(dir);
            return true;
        }
    }

    closedir(dir);
    return false;
}

static int read_battery_capacity(void)
{
    FILE *fp = fopen(batt_cap_path, "r");
    if (!fp)
        return -1;

    int cap = -1;
    fscanf(fp, "%d", &cap);
    fclose(fp);
    return cap;
}

static bool read_battery_charging(void)
{
    FILE *fp = fopen(batt_stat_path, "r");
    if (!fp)
        return false;

    char status[32] = "";
    fgets(status, sizeof(status), fp);
    fclose(fp);

    return strncmp(status, "Charging", 8) == 0;
}

static int pwrkey_fd = -1;

static bool input_init(void)
{
    DIR *dir = opendir("/dev/input");
    if (!dir)
        return false;

    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL) {
        if (strncmp(entry->d_name, "event", 5) != 0)
            continue;

        char path[64];
        snprintf(path, sizeof(path), "/dev/input/%s", entry->d_name);

        int fd = open(path, O_RDONLY | O_NONBLOCK);
        if (fd < 0)
            continue;

        char name[256] = "";
        ioctl(fd, EVIOCGNAME(sizeof(name)), name);

        if (strstr(name, "pwrkey")) {
            closedir(dir);
            pwrkey_fd = fd;
            return true;
        }
        close(fd);
    }

    closedir(dir);
    return false;
}

static int check_power_button(void)
{
    static bool held = false;
    static struct timespec press_time = {0};

    struct input_event ev;
    while (read(pwrkey_fd, &ev, sizeof(ev)) == sizeof(ev)) {
        if (ev.type != EV_KEY || ev.code != KEY_POWER)
            continue;

        if (ev.value == 1 && !held) {
            clock_gettime(CLOCK_MONOTONIC, &press_time);
            held = true;
        } else if (ev.value == 0 && held) {
            held = false;
            return 1; /* short press — boot */
        }
    }

    if (held) {
        struct timespec now;
        clock_gettime(CLOCK_MONOTONIC, &now);
        long ms = (now.tv_sec - press_time.tv_sec) * 1000 +
                  (now.tv_nsec - press_time.tv_nsec) / 1000000;
        if (ms >= 1750) {
            held = false;
            return 2; /* long press — power off */
        }
    }

    return 0;
}

/* ------------------------------------------------------------------ */
/*  Drawing                                                           */
/* ------------------------------------------------------------------ */

static void draw_charging_screen(int capacity, bool charging, int frame)
{
    fb_clear();

    int batt_w = 200;
    int batt_h = 100;
    int batt_x = (screen_w - batt_w) / 2;
    int batt_y = (screen_h - batt_h) / 2 - 20;
    int border = 4;
    int nub_w = 10;
    int nub_h = 40;

    fb_draw_rect(batt_x, batt_y, batt_w, batt_h, border,
                 200, 200, 200);

    fb_fill_rect(batt_x + batt_w, batt_y + (batt_h - nub_h) / 2,
                 nub_w, nub_h, 200, 200, 200);

    int inner_w = batt_w - border * 2 - 4;
    int inner_h = batt_h - border * 2 - 4;
    int inner_x = batt_x + border + 2;
    int inner_y = batt_y + border + 2;

    int fill_w;
    if (charging) {
        int anim_cap = capacity + (frame % 4) * ((100 - capacity) / 4);
        if (anim_cap > 100) anim_cap = 100;
        fill_w = inner_w * anim_cap / 100;
    } else {
        fill_w = inner_w * capacity / 100;
    }

    unsigned char fr, fg, fb_c;
    if (charging) {
        fr = 0; fg = 200; fb_c = 0;
    } else if (capacity < 15) {
        fr = 220; fg = 50; fb_c = 50;
    } else {
        fr = 200; fg = 200; fb_c = 200;
    }

    if (fill_w > 0)
        fb_fill_rect(inner_x, inner_y, fill_w, inner_h, fr, fg, fb_c);

    char text[8];
    snprintf(text, sizeof(text), "%d%%", capacity);

    int scale = 4;
    int tw = text_width(text, scale);
    int text_x = (screen_w - tw) / 2;
    int text_y = batt_y + batt_h + 20;

    fb_draw_text(text, text_x, text_y, scale, 200, 200, 200);
}

static void do_poweroff(void)
{
    fb_clear();
    fb_cleanup();
    sync();
    reboot(RB_POWER_OFF);
    _exit(0);
}

int main(void)
{
    usleep(500000);

    if (!fb_init()) {
        fprintf(stderr, "charge-monitor: failed to init framebuffer\n");
        return 0;
    }

    int retries = 20;
    while (!find_battery() && retries-- > 0)
        usleep(250000);

    if (batt_cap_path[0] == '\0') {
        fprintf(stderr, "charge-monitor: no battery found, continuing boot\n");
        fb_cleanup();
        return 0;
    }

    input_init();

    int frame = 0;
    bool running = true;

    while (running) {
        int capacity = read_battery_capacity();
        bool charging = read_battery_charging();

        if (capacity < 0)
            capacity = 0;

        draw_charging_screen(capacity, charging, frame);

        if (!charging) {
            usleep(500000);
            if (!read_battery_charging()) {
                draw_charging_screen(capacity, false, 0);

                for (int i = 0; i < 10; i++) {
                    if (pwrkey_fd >= 0 && check_power_button() == 1) {
                        running = false;
                        goto end_loop;
                    }
                    usleep(500000);
                }
                do_poweroff();
            }
        }

        if (pwrkey_fd >= 0) {
            int action = check_power_button();
            if (action == 1) {
                running = false;
            } else if (action == 2) {
                do_poweroff();
            }
        }

        frame++;
        usleep(500000);
end_loop:;
    }

    fb_clear();
    fb_cleanup();
    if (pwrkey_fd >= 0)
        close(pwrkey_fd);

    return 0;
}
