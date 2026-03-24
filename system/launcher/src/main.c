#define _DEFAULT_SOURCE

#include <sys/wait.h>
#include <errno.h>
#include <signal.h>
#include <curses.h>

#include "shared.h"

// Layout using TER16x32
#define MARGIN       1
#define USABLE_COLS  38
#define USABLE_ROWS  13
#define HEADER_ROW   MARGIN
#define FOOTER_ROW   (MARGIN + USABLE_ROWS)
#define CONTENT_ROW  (HEADER_ROW + 2)
#define BATTERY_COL  (MARGIN + USABLE_COLS - 7)

// Menu
#define MAX_SYSTEMS 5
#define MAX_GAMES 256
#define GAMES_PER_PAGE 10
#define GAME_NAME_MAX_CHARS 32
#define BATTERY_READ_MS 1750

typedef struct
{
    char name[256];
    char path[512];
} Game;

typedef struct
{
    const char *name;
    const char *short_name;
    const char *emulator;
    const char **extensions;
    Game games[MAX_GAMES];
    int game_count;
} System;

static int current_system = 0;
static int current_game = 0;
static bool in_game_list = false;

static int battery_capacity = -1;
static bool battery_charging = false;
static long battery_last_read_ms = 0;

static int scroll_offset = 0;
static int last_scrolled_game = -1;

static const char *n64_exts[] = {".z64", ".n64", ".v64", NULL};
static const char *stn_exts[] = {".chd", ".iso", ".cue", NULL};
static const char *dc_exts[] = {".gdi", ".cdi", ".chd", NULL};
static const char *ps1_exts[] = {".cue", ".chd", ".pbp", NULL};
static const char *psp_exts[] = {".iso", ".cso", ".chd", NULL};

static System systems[MAX_SYSTEMS] = {
    {"Nintendo 64", "n64", "mupen64plus", n64_exts, {}, 0},
    {"Saturn", "stn", "yabasanshiro", stn_exts, {}, 0},
    {"Dreamcast", "dc", "flycast", dc_exts, {}, 0},
    {"PlayStation", "ps1", "pcsx", ps1_exts, {}, 0},
    {"PS Portable", "psp", "PPSSPPSDL", psp_exts, {}, 0}};

enum {
    PAIR_DEFAULT = 1,
    PAIR_SELECTED,
    PAIR_BATTERY_LOW,
    PAIR_BATTERY_CHARGING,
};

static long monotonic_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static bool has_extension(const char *filename, const char **extensions)
{
    if (!filename || !extensions)
        return false;

    const char *dot = strrchr(filename, '.');
    if (!dot)
        return false;

    for (int i = 0; extensions[i]; i++)
    {
        if (strcasecmp(dot, extensions[i]) == 0)
            return true;
    }
    return false;
}

static void set_cpu_governor(const char *cpu_gov)
{
    if (cpu_gov) {
        for (int cpu = 0; cpu < 4; cpu++) {
            char path[256];
            snprintf(path, sizeof(path),
                "/sys/devices/system/cpu/cpu%d/cpufreq/scaling_governor", cpu);

            FILE *fp = fopen(path, "w");
            if (fp) {
                fprintf(fp, "%s\n", cpu_gov);
                fclose(fp);
            } else if (cpu == 0) {
                break;
            }
        }
    }
}

static void set_gpu_governor(const char *gpu_gov)
{
    if (gpu_gov)
    {
        const char *gpu_path = "/sys/class/devfreq/fde60000.gpu/governor";
        FILE *fp = fopen(gpu_path, "w");
        if (fp)
        {
            fprintf(fp, "%s\n", gpu_gov);
            fclose(fp);
            return;
        }
    }
}

static int compare_games(const void *a, const void *b)
{
    const Game *game_a = (const Game *)a;
    const Game *game_b = (const Game *)b;
    return strcasecmp(game_a->name, game_b->name);
}

static void scan_games(System *sys)
{
    DIR *dir;
    struct dirent *entry;
    sys->game_count = 0;

    const char *base_dirs[] = {"/mnt/games", "/mnt/games2"};

    for (int d = 0; d < 2; d++)
    {
        char rom_dir[32];
        snprintf(rom_dir, sizeof(rom_dir), "%s/%s", base_dirs[d], sys->short_name);

        dir = opendir(rom_dir);
        if (!dir)
            continue;

        while ((entry = readdir(dir)) != NULL && sys->game_count < MAX_GAMES)
        {
            if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0)
                continue;

            if (entry->d_type == DT_DIR)
                continue;

            if (has_extension(entry->d_name, sys->extensions))
            {
                Game *game = &sys->games[sys->game_count];

                strncpy(game->name, entry->d_name, sizeof(game->name) - 2);
                char *dot = strrchr(game->name, '.');
                if (dot)
                    *dot = '\0';

                // Remove parenthesized, bracketed, and braced annotations
                static const char open_brackets[]  = "([{";
                static const char close_brackets[] = ")]}";
                for (int b = 0; b < 3; b++) {
                    char *open = game->name;
                    while ((open = strchr(open, open_brackets[b])) != NULL) {
                        char *close = strchr(open, close_brackets[b]);
                        if (!close) break;
                        memmove(open, close + 1, strlen(close + 1) + 1);
                    }
                }
                char *end = game->name + strlen(game->name) - 1;
                while (end > game->name && *end == ' ')
                    *end-- = '\0';

                snprintf(game->path, sizeof(game->path), "%s/%s",
                         rom_dir, entry->d_name);

                sys->game_count++;
            }
        }
        closedir(dir);
    }

    if (sys->game_count > 0)
        qsort(sys->games, sys->game_count, sizeof(Game), compare_games);
}

static void init_curses(void)
{
    initscr();
    cbreak();
    noecho();
    curs_set(0);

    if (has_colors())
    {
        start_color();
        use_default_colors();
        init_pair(PAIR_DEFAULT, COLOR_WHITE, -1);
        init_pair(PAIR_SELECTED, COLOR_GREEN, -1);
        init_pair(PAIR_BATTERY_LOW, COLOR_RED, -1);
        init_pair(PAIR_BATTERY_CHARGING, COLOR_GREEN, -1);
    }
}

static void cleanup_curses(void)
{
    endwin();
}

static bool read_battery(void)
{
    long now = monotonic_ms();
    if (battery_capacity >= 0 && (now - battery_last_read_ms) < BATTERY_READ_MS)
        return false;
    battery_last_read_ms = now;

    int old_capacity = battery_capacity;
    bool old_charging = battery_charging;

    FILE *fp = fopen("/sys/class/power_supply/rk817-battery/capacity", "r");
    if (fp) {
        if (fscanf(fp, "%d", &battery_capacity) != 1)
            battery_capacity = -1;
        fclose(fp);
    }

    fp = fopen("/sys/class/power_supply/rk817-battery/status", "r");
    if (fp) {
        char status[32] = {0};
        fgets(status, sizeof(status), fp);
        fclose(fp);
        battery_charging = (strncmp(status, "Charging", 8) == 0);
    } else {
        battery_charging = false;
    }

    return (battery_capacity != old_capacity || battery_charging != old_charging);
}

static void draw_battery(int row, int col)
{
    if (battery_capacity < 0)
        return;

    int capacity = battery_capacity;
    int level;
    int color_pair = PAIR_DEFAULT;

    if (battery_charging) {
        color_pair = PAIR_BATTERY_CHARGING;
    }
    if (capacity < 10) {
        level = 0;
        if (!battery_charging)
            color_pair = PAIR_BATTERY_LOW;
    } else if (capacity < 25) {
        level = 1;
    } else if (capacity < 50) {
        level = 2;
    } else if (capacity < 75) {
        level = 3;
    } else {
        level = 4;
    }

    char buf[9];
    buf[0] = battery_charging ? '+' : ' ';
    buf[1] = '{';
    for (int i = 0; i < 4; i++)
        buf[2 + i] = (i >= 4 - level) ? '#' : ' ';
    buf[6] = ']';
    buf[7] = '\0';

    attron(COLOR_PAIR(color_pair));
    mvprintw(row, col, "%s", buf);
    attroff(COLOR_PAIR(color_pair));
}

static void render_system_menu(void)
{
    erase();

    // Title centered in usable area
    const char *title = "MIMIKI";
    int title_col = MARGIN + (USABLE_COLS - (int)strlen(title)) / 2;
    mvprintw(HEADER_ROW, title_col, "%s", title);

    draw_battery(HEADER_ROW - 1, BATTERY_COL);

    // System list
    for (int i = 0; i < MAX_SYSTEMS; i++)
    {
        int row = CONTENT_ROW + (i * 2);
        bool selected = (i == current_system);

        if (selected)
        {
            attron(COLOR_PAIR(PAIR_SELECTED));
            mvprintw(row, MARGIN + 1, ">");
        }

        int pair = selected ? PAIR_SELECTED : PAIR_DEFAULT;
        attron(COLOR_PAIR(pair));
        mvprintw(row, MARGIN + 3, "%s", systems[i].name);
        attroff(COLOR_PAIR(pair));

        char count[32];
        snprintf(count, sizeof(count), "(%d games)", systems[i].game_count);
        mvprintw(row, MARGIN + 26, "%s", count);

        if (selected)
            attroff(COLOR_PAIR(PAIR_SELECTED));
    }

    mvprintw(FOOTER_ROW, MARGIN + 2, "D-PAD: Navigate  A: Select");

    refresh();
}

static void render_game_menu(void)
{
    erase();

    System *sys = &systems[current_system];

    // Title centered
    int title_col = MARGIN + (USABLE_COLS - (int)strlen(sys->name)) / 2;
    mvprintw(HEADER_ROW, title_col, "%s", sys->name);

    draw_battery(HEADER_ROW - 1, BATTERY_COL);

    // Game list
    int start_idx = (current_game / GAMES_PER_PAGE) * GAMES_PER_PAGE;

    for (int i = start_idx; i < start_idx + GAMES_PER_PAGE && i < sys->game_count; i++)
    {
        int row = CONTENT_ROW + (i - start_idx);
        bool selected = (i == current_game);
        const char *full_name = sys->games[i].name;
        int name_len = (int)strlen(full_name);

        // For unselected long names, scroll_offset is irrelevant (always 0)
        int offset = selected ? scroll_offset : 0;
        char display_name[GAME_NAME_MAX_CHARS + 1];

        if (name_len <= GAME_NAME_MAX_CHARS) {
            strncpy(display_name, full_name, sizeof(display_name));
            display_name[GAME_NAME_MAX_CHARS] = '\0';
        } else {
            bool can_scroll_left = (offset > 0);
            bool can_scroll_right = (offset + GAME_NAME_MAX_CHARS < name_len);

            strncpy(display_name, full_name + offset, GAME_NAME_MAX_CHARS);
            display_name[GAME_NAME_MAX_CHARS] = '\0';

            if (can_scroll_left)
                display_name[0] = '<';
            if (can_scroll_right)
                display_name[GAME_NAME_MAX_CHARS - 1] = '>';
        }

        if (selected)
        {
            attron(COLOR_PAIR(PAIR_SELECTED));
            mvprintw(row, MARGIN + 1, ">");
        }

        int pair = selected ? PAIR_SELECTED : PAIR_DEFAULT;
        attron(COLOR_PAIR(pair));
        mvprintw(row, MARGIN + 3, "%s", display_name);
        attroff(COLOR_PAIR(pair));

        if (selected)
            attroff(COLOR_PAIR(PAIR_SELECTED));
    }

    // Footer
    if (sys->game_count > GAMES_PER_PAGE)
    {
        int current_page = (current_game / GAMES_PER_PAGE) + 1;
        int total_pages = (sys->game_count + GAMES_PER_PAGE - 1) / GAMES_PER_PAGE;
        mvprintw(FOOTER_ROW, MARGIN + 2, "PAGE %d/%d", current_page, total_pages);
        mvprintw(FOOTER_ROW, MARGIN + 19, "A: Launch B: Back");
    }
    else
    {
        mvprintw(FOOTER_ROW, MARGIN + 2, "D-PAD: Navigate  A: Launch B: Back");
    }

    refresh();
}

static void launch_game(System *sys, Game *game)
{
    cleanup_curses();

    const char *cpu_gov = "schedutil";
    const char *gpu_gov = "simple_ondemand";

    if ((strcmp(sys->short_name, "n64") == 0) ||
        (strcmp(sys->short_name, "dc") == 0))
        gpu_gov = "performance";

    if (strcmp(sys->short_name, "stn") == 0)
        cpu_gov = "performance";

    set_cpu_governor(cpu_gov);
    set_gpu_governor(gpu_gov);

    pid_t pid = fork();
    if (pid == 0)
    {
        // Redirect child output to log so it doesn't clobber the console
        int log_fd = open("/mnt/games/data/mimiki.log",
                          O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (log_fd >= 0) {
            dup2(log_fd, STDOUT_FILENO);
            dup2(log_fd, STDERR_FILENO);
            close(log_fd);
        }

        if (strcmp(sys->short_name, "n64") == 0)
        {
            setenv("XDG_CACHE_HOME", "/mnt/games/data/.cache", 1);
            execl("/usr/bin/mupen64plus", sys->emulator, game->path, (char *)NULL);
        }
        else if (strcmp(sys->short_name, "stn") == 0)
        {
            execl("/usr/bin/yabasanshiro", sys->emulator,
                "-b", "/mnt/games/data/saturn_bios.bin", "-i", game->path, (char *)NULL);
        }
        else if (strcmp(sys->short_name, "dc") == 0)
        {
            execl("/usr/bin/flycast", sys->emulator, game->path, (char *)NULL);
        }
        else if (strcmp(sys->short_name, "ps1") == 0)
        {
            execl("/usr/bin/pcsx", sys->emulator, "-cdfile", game->path, (char *)NULL);
        }
        else if (strcmp(sys->short_name, "psp") == 0)
        {
            setenv("XDG_CONFIG_HOME", "/mnt/games/data", 1);
            execl("/usr/bin/PPSSPPSDL", sys->emulator, game->path, (char *)NULL);
        }

        _exit(1);
    }
    else if (pid > 0)
    {
        int status;
        while (waitpid(pid, &status, WNOHANG) == 0)
        {
            InputEvents ev = {0};
            input_monitor_poll(&ev);
            if (ev.exit_emu || ev.shutdown) {
                kill(pid, SIGTERM);
                usleep(250000);
                break;
            }
            usleep(50000);
        }
    }

    init_curses();

    set_cpu_governor("powersave");
    set_gpu_governor("powersave");
}

static bool handle_input(InputEvents *ev)
{
    bool dirty = false;

    if (ev->nav_up)
    {
        if (in_game_list)
        {
            if (current_game > 0)
                current_game--;
        }
        else
        {
            if (current_system > 0)
                current_system--;
        }
        dirty = true;
    }

    if (ev->nav_down)
    {
        if (in_game_list)
        {
            System *sys = &systems[current_system];
            if (current_game < sys->game_count - 1)
                current_game++;
        }
        else
        {
            if (current_system < MAX_SYSTEMS - 1)
                current_system++;
        }
        dirty = true;
    }

    if (ev->nav_left && in_game_list)
    {
        if (scroll_offset > 0)
        {
            scroll_offset--;
            dirty = true;
        }
    }

    if (ev->nav_right && in_game_list)
    {
        System *sys = &systems[current_system];
        int name_len = (int)strlen(sys->games[current_game].name);
        if (scroll_offset + GAME_NAME_MAX_CHARS < name_len)
        {
            scroll_offset++;
            dirty = true;
        }
    }

    if (ev->nav_select)
    {
        if (in_game_list)
        {
            System *sys = &systems[current_system];
            if (sys->game_count > 0)
                launch_game(sys, &sys->games[current_game]);
        }
        else
        {
            System *sys = &systems[current_system];
            if (sys->game_count > 0)
            {
                in_game_list = true;
                current_game = 0;
            }
        }
        dirty = true;
    }

    if (ev->nav_back)
    {
        if (in_game_list)
        {
            in_game_list = false;
            current_game = 0;
        }
        dirty = true;
    }

    // Reset scroll when selection changes
    if (current_game != last_scrolled_game)
    {
        scroll_offset = 0;
        last_scrolled_game = current_game;
    }

    return dirty;
}

int main(void)
{
    if (!input_monitor_init())
        fprintf(stderr, "Warning: Menu controls unavailable!\n");

    for (int i = 0; i < MAX_SYSTEMS; i++)
        scan_games(&systems[i]);

    set_cpu_governor("powersave");
    set_gpu_governor("powersave");

    init_curses();

    // Initial draw
    render_system_menu();

    while (true)
    {
        InputEvents ev = {0};
        input_monitor_poll(&ev);

        if (ev.shutdown) {
            erase();
            mvprintw(FOOTER_ROW, MARGIN + USABLE_COLS - 8, "mata ne!");
            refresh();
            usleep(1000000);
            system("poweroff");
            break;
        }

        bool dirty = handle_input(&ev);
        if (read_battery())
            dirty = true;

        if (dirty)
        {
            if (in_game_list)
                render_game_menu();
            else
                render_system_menu();
        }

        usleep(50000);
    }

    input_monitor_cleanup();
    cleanup_curses();
    return 0;
}
