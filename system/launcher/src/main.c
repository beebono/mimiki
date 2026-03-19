#define _DEFAULT_SOURCE

#include <sys/wait.h>
#include <errno.h>
#include <SDL2/SDL.h>
#include <SDL2/SDL_image.h>

#include "font_data.h"
#include "shared.h"

// Display
#define SCREEN_WIDTH 640
#define SCREEN_HEIGHT 480

// Menu
#define MAX_SYSTEMS 5
#define MAX_GAMES 256
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

static SDL_Window *window = NULL;
static SDL_Renderer *renderer = NULL;
static SDL_GameController *gamepad = NULL;
static SDL_Texture *font_texture = NULL;
static int current_system = 0;
static int current_game = 0;
static bool in_game_list = false;
bool backlight_on = false;

static int battery_capacity = -1;
static bool battery_charging = false;
static Uint32 battery_last_read  = 0;

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
        bool result = false;
        for (int cpu = 0; cpu < 4; cpu++) {
            char path[256];
            snprintf(path, sizeof(path),
                "/sys/devices/system/cpu/cpu%d/cpufreq/scaling_governor", cpu);

            FILE *fp = fopen(path, "w");
            if (fp) {
                fprintf(fp, "%s\n", cpu_gov);
                fclose(fp);
                result = true;
            } else if (cpu == 0) {
                fprintf(stderr, "Could not set CPU governor: %s\n", strerror(errno));
                break;
            }
        }
        if (result)
            printf("Set CPU governor to: %s\n", cpu_gov);
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
            printf("Set GPU governor to: %s\n", gpu_gov);
            return;
        }
        fprintf(stderr, "Could not set GPU governor.\n");
    }
}

static int compare_games(const void *a, const void *b)
{
    const Game *game_a = (const Game *)a;
    const Game *game_b = (const Game *)b;
    return strcasecmp(game_a->name, game_b->name);
}

static void scan_games(System *system)
{
    DIR *dir;
    struct dirent *entry;
    system->game_count = 0;

    const char *base_dirs[] = {"/mnt/games", "/mnt/games2"};

    // Scan each base directory
    for (int d = 0; d < 2; d++)
    {
        char rom_dir[32];
        snprintf(rom_dir, sizeof(rom_dir), "%s/%s", base_dirs[d], system->short_name);

        dir = opendir(rom_dir);
        if (!dir)
            continue;

        while ((entry = readdir(dir)) != NULL && system->game_count < MAX_GAMES)
        {
            if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0)
                continue;

            // Only skip directories, regular files may be DT_UNKNOWN
            if (entry->d_type == DT_DIR)
                continue;

            if (has_extension(entry->d_name, system->extensions))
            {
                Game *game = &system->games[system->game_count];

                // Copy filename without extension as game name
                strncpy(game->name, entry->d_name, sizeof(game->name) - 2);
                char *dot = strrchr(game->name, '.');
                if (dot)
                    *dot = '\0';

                // Remove parenthesized, bracketed, and braced annotations (e.g. "(USA)", "[!]", "{v1.0}")
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
                // Trim trailing whitespace left behind
                char *end = game->name + strlen(game->name) - 1;
                while (end > game->name && *end == ' ')
                    *end-- = '\0';

                // Full path
                snprintf(game->path, sizeof(game->path), "%s/%s",
                         rom_dir, entry->d_name);

                system->game_count++;
            }
        }
        closedir(dir);
    }

    // Sort games alphabetically by name
    if (system->game_count > 0)
        qsort(system->games, system->game_count, sizeof(Game), compare_games);

    printf("Found %d games for %s\n", system->game_count, system->name);
}

static bool load_font(void)
{
    int img_flags = IMG_INIT_PNG;
    if (!(IMG_Init(img_flags) & img_flags))
    {
        fprintf(stderr, "SDL_image init failed: %s\n", IMG_GetError());
        return false;
    }

    SDL_Surface *font_surface = IMG_Load("/usr/share/mimiki/assets/font.png");
    if (!font_surface)
    {
        fprintf(stderr, "Failed to load font.png: %s\n", IMG_GetError());
        return false;
    }

    font_texture = SDL_CreateTextureFromSurface(renderer, font_surface);
    SDL_FreeSurface(font_surface);

    if (!font_texture)
    {
        fprintf(stderr, "Failed to create font texture: %s\n", SDL_GetError());
        return false;
    }

    printf("Bitmap font loaded successfully\n");
    return true;
}

static bool init_sdl(void)
{
    setenv("SDL_VIDEODRIVER", "kmsdrm", 1);
    while (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_GAMECONTROLLER) < 0)
    {
        usleep(250000);
    }

    window = SDL_CreateWindow("MIMIKI",
                              SDL_WINDOWPOS_UNDEFINED,
                              SDL_WINDOWPOS_UNDEFINED,
                              SCREEN_WIDTH, SCREEN_HEIGHT,
                              SDL_WINDOW_FULLSCREEN | SDL_WINDOW_VULKAN);

    if (!window)
    {
        fprintf(stderr, "SDL_CreateWindow failed: %s\n", SDL_GetError());
        SDL_Quit();
        return false;
    }

    renderer = SDL_CreateRenderer(window, -1, SDL_RENDERER_ACCELERATED);

    if (!renderer)
    {
        fprintf(stderr, "SDL_CreateRenderer failed: %s\n", SDL_GetError());
        SDL_DestroyWindow(window);
        SDL_Quit();
        return false;
    }

    if (!load_font())
    {
        SDL_DestroyRenderer(renderer);
        SDL_DestroyWindow(window);
        SDL_Quit();
        return false;
    }

    for (int i = 0; i < SDL_NumJoysticks(); i++)
    {
        if (SDL_IsGameController(i))
        {
            gamepad = SDL_GameControllerOpen(i);
            if (gamepad)
            {
                printf("Gamepad opened: %s\n", SDL_GameControllerName(gamepad));
                break;
            }
        }
    }

    printf("SDL2 initialized successfully (KMS/DRM backend)\n");
    return true;
}

static void cleanup_sdl(void)
{
    if (gamepad)
    {
        SDL_GameControllerClose(gamepad);
        gamepad = NULL;
    }
    if (font_texture)
    {
        SDL_DestroyTexture(font_texture);
        font_texture = NULL;
    }
    if (renderer)
    {
        SDL_DestroyRenderer(renderer);
        renderer = NULL;
    }
    if (window)
    {
        SDL_DestroyWindow(window);
        window = NULL;
    }
    IMG_Quit();
    SDL_Quit();
}

static void draw_text_rgb(int x, int y, const char *text, Uint8 r, Uint8 g, Uint8 b)
{
    if (!text || !font_texture)
        return;

    SDL_SetTextureColorMod(font_texture, r, g, b);

    int cursor_x = x;
    int cursor_y = y;

    for (const char *c = text; *c != '\0'; c++)
    {
        unsigned char ch = (unsigned char)*c;

        // Only render supported ASCII characters
        if (ch < FONT_FIRST_CHAR || ch > FONT_LAST_CHAR)
        {
            cursor_x += FONT_CHAR_WIDTH;
            continue;
        }

        // Calculate position in atlas
        int char_index = ch - FONT_FIRST_CHAR;
        int atlas_x = (char_index % FONT_ATLAS_COLS) * FONT_CHAR_WIDTH;
        int atlas_y = (char_index / FONT_ATLAS_COLS) * FONT_CHAR_HEIGHT;

        SDL_Rect src_rect = {atlas_x, atlas_y, FONT_CHAR_WIDTH, FONT_CHAR_HEIGHT};
        SDL_Rect dst_rect = {cursor_x, cursor_y, FONT_CHAR_WIDTH, FONT_CHAR_HEIGHT};

        SDL_RenderCopy(renderer, font_texture, &src_rect, &dst_rect);

        cursor_x += FONT_CHAR_WIDTH;
    }

    SDL_SetTextureColorMod(font_texture, 255, 255, 255);
}

static void draw_text(int x, int y, const char *text, bool selected)
{
    if (selected)
        draw_text_rgb(x, y, text, 100, 255, 100);
    else
        draw_text_rgb(x, y, text, 255, 255, 255);
}

static char batt_cap_path[80]  = "";
static char batt_stat_path[80] = "";

static bool find_battery_supply(void)
{
    DIR *dir = opendir("/sys/class/power_supply");
    if (!dir)
        return false;

    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL)
    {
        if (entry->d_name[0] == '.')
            continue;

        char type_path[96];
        snprintf(type_path, sizeof(type_path),
                 "/sys/class/power_supply/%s/type", entry->d_name);

        FILE *fp = fopen(type_path, "r");
        if (!fp)
            continue;

        char type[32] = {0};
        fgets(type, sizeof(type), fp);
        fclose(fp);

        if (strncmp(type, "Battery", 7) == 0)
        {
            snprintf(batt_cap_path, sizeof(batt_cap_path),
                     "/sys/class/power_supply/%s/capacity", entry->d_name);
            snprintf(batt_stat_path, sizeof(batt_stat_path),
                     "/sys/class/power_supply/%s/status", entry->d_name);
            printf("Battery supply found: %s\n", entry->d_name);
            closedir(dir);
            return true;
        }
    }

    closedir(dir);
    return false;
}

static void read_battery(void)
{
    if (batt_cap_path[0] == '\0')
    {
        if (!find_battery_supply())
        {
            battery_capacity = -1;
            return;
        }
    }

    Uint32 now = SDL_GetTicks();
    if (battery_capacity >= 0 && (now - battery_last_read) < BATTERY_READ_MS)
        return;
    battery_last_read = now;

    FILE *fp = fopen(batt_cap_path, "r");
    if (fp) {
        if (fscanf(fp, "%d", &battery_capacity) != 1)
            battery_capacity = -1;
        fclose(fp);
    }

    fp = fopen(batt_stat_path, "r");
    if (fp) {
        char status[32] = {0};
        fgets(status, sizeof(status), fp);
        fclose(fp);
        battery_charging = (strncmp(status, "Charging", 8) == 0);
    } else {
        battery_charging = false;
    }
}

// Battery indicator
// Thresholds: 4=100-75%, 3=74-50%, 2=49-25%, 1=24-10%, 0=9-0% (red)
static void draw_battery(int x, int y)
{
    read_battery();
    if (battery_capacity < 0)
        return;

    int capacity = battery_capacity;
    int level;
    Uint8 r = 255, g = 255, b = 255;

    if (battery_charging && capacity >= 95) {
        level = 4;
        r = 0; g = 255; b = 0;
    } else if (battery_charging) {
        // Animate: cycle 1>2>3>4 every 600 ms
        level = (int)((SDL_GetTicks() / 600) % 4) + 1;
        r = 0; g = 255; b = 0;
    } else if (capacity < 10) {
        level = 0;
        r = 255; g = 0; b = 0;
    } else if (capacity < 25) {
        level = 1;
    } else if (capacity < 50) {
        level = 2;
    } else if (capacity < 75) {
        level = 3;
    } else {
        level = 4;
    }

    // ASCII Art Battery Builder
    char indicator[7];
    indicator[0] = '{';
    for (int i = 0; i < 4; i++)
        indicator[1 + i] = (i >= 4 - level) ? '*' : ' ';
    indicator[5] = ']';
    indicator[6] = '\0';

    draw_text_rgb(x, y, indicator, r, g, b);
}

static void render_system_menu(void)
{
    SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255);
    SDL_RenderClear(renderer);

    // Title
    draw_text(272, 40, "MIMIKI", false);

    // Battery indicator
    draw_battery(498, 40);

    // System list
    int y = 120;
    for (int i = 0; i < MAX_SYSTEMS; i++)
    {
        bool selected = (i == current_system);

        // Selection indicator
        if (selected)
            draw_text(80, y, ">", true);

        draw_text(110, y, systems[i].name, selected);

        // Game count
        char count[32];
        snprintf(count, sizeof(count), "(%d games)", systems[i].game_count);
        draw_text(380, y, count, false);

        y += 50;
    }

    // Instructions
    draw_text(120, 396, "D-PAD: Navigate  A: Select", false);

    SDL_RenderPresent(renderer);
}

// Max characters that fit in the game name column (x=110 to x=630, 16px/char)
#define GAME_NAME_MAX_CHARS 27

static int   scroll_offset     = 0;
static int   last_scrolled_game = -1;
static Uint32 scroll_last_ms   = 0;

static void render_game_menu(void)
{
    SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255);
    SDL_RenderClear(renderer);

    System *sys = &systems[current_system];

    // Title
    int title_width = strlen(sys->name) * FONT_CHAR_WIDTH;
    int title_x = (SCREEN_WIDTH - title_width) / 2;
    draw_text(title_x, 40, sys->name, false);

    // Battery indicator
    draw_battery(498, 40);

    // Advance scroll state for the selected game
    Uint32 now = SDL_GetTicks();
    if (current_game != last_scrolled_game) {
        scroll_offset      = 0;
        scroll_last_ms     = now;
        last_scrolled_game = current_game;
    } else if (now - scroll_last_ms >= 500) {
        int name_len = (int)strlen(sys->games[current_game].name);
        if (name_len > GAME_NAME_MAX_CHARS) {
            scroll_offset++;
            if (scroll_offset + GAME_NAME_MAX_CHARS > name_len)
                scroll_offset = 0;
        }
        scroll_last_ms = now;
    }

    // Game list
    int games_per_page = 10;
    int start_idx = (current_game / games_per_page) * games_per_page;
    int y = 80;

    for (int i = start_idx; i < start_idx + games_per_page && i < sys->game_count; i++)
    {
        bool selected = (i == current_game);
        const char *full_name = sys->games[i].name;
        int name_len = (int)strlen(full_name);

        // Build display name: scroll if selected & long, truncate otherwise
        char display_name[GAME_NAME_MAX_CHARS + 1];
        if (name_len <= GAME_NAME_MAX_CHARS) {
            strncpy(display_name, full_name, sizeof(display_name));
        } else if (selected) {
            strncpy(display_name, full_name + scroll_offset, GAME_NAME_MAX_CHARS);
            display_name[GAME_NAME_MAX_CHARS] = '\0';
        } else {
            strncpy(display_name, full_name, GAME_NAME_MAX_CHARS - 3);
            display_name[GAME_NAME_MAX_CHARS - 3] = '\0';
            strcat(display_name, "...");
        }

        // Selection indicator
        if (selected)
            draw_text(80, y, ">", true);

        draw_text(110, y, display_name, selected);
        y += 30;
    }

    // Instructions
    draw_text(120, 396, "D-PAD: Navigate  A: Launch", false);
    draw_text(120, 420, "                 B:  Back", false);

    // Page indicator if needed
    if (sys->game_count > games_per_page)
    {
        int current_page = (current_game / games_per_page) + 1;
        int total_pages = (sys->game_count + games_per_page - 1) / games_per_page;
        char page_info[32];
        snprintf(page_info, sizeof(page_info), "PAGE : %d/%d", current_page, total_pages);
        draw_text(120, 420, page_info, false);
    }

    SDL_RenderPresent(renderer);
}

static void launch_game(System *sys, Game *game)
{
    printf("Launching: %s (%s)\n", game->name, game->path);
    cleanup_sdl();

    const char *cpu_gov = "schedutil";
    const char *gpu_gov = "simple_ondemand";

    if (strcmp(sys->short_name, "n64") == 0)
        gpu_gov = "performance";
    
    if (strcmp(sys->short_name, "stn") == 0)
        cpu_gov = "performance";

    set_cpu_governor(cpu_gov);
    set_gpu_governor(gpu_gov);

    pid_t pid = fork();
    if (pid == 0)
    {
        // Child process
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

        fprintf(stderr, "Failed to launch %s: %s\n", sys->emulator, strerror(errno));
    }
    else if (pid > 0)
    {
        // Parent process
        int status;
        while (waitpid(pid, &status, WNOHANG) == 0)
        {
            int hotkey = input_monitor_check_hotkeys();
            if (hotkey == HOTKEY_EXIT_EMU || hotkey == HOTKEY_SHUTDOWN) {
                kill(pid, SIGTERM);
                usleep(250000); // Minor pause to let KMSDRM release itself
                break;
            }
            usleep(50000);
        }

        printf("Emulator exited\n");
    }
    else
    {
        // Fork failed
        fprintf(stderr, "Fork failed\n");
    }

    init_sdl();

    set_cpu_governor("powersave");
    set_gpu_governor("powersave");
}

static void handle_input(SDL_Event *event)
{
    if (event->type == SDL_QUIT)
        exit(0);

    // Gamepad inputs
    if (event->type == SDL_CONTROLLERBUTTONDOWN)
    {
        switch (event->cbutton.button)
        {
        case SDL_CONTROLLER_BUTTON_DPAD_UP:
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
            break;

        case SDL_CONTROLLER_BUTTON_DPAD_DOWN:
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
            break;

        // A Button on Device = East button (SDL B)
        case SDL_CONTROLLER_BUTTON_B:
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
            break;

        // B Button on Device = South button (SDL A)
        case SDL_CONTROLLER_BUTTON_A:
            if (in_game_list)
            {
                in_game_list = false;
                current_game = 0;
            }
            break;
        }
    }
}

int main()
{
    printf("MIMIKI Launcher - Starting...\n");

    if (!init_sdl())
        return 1;

    if (!input_monitor_init())
        fprintf(stderr, "Warning: Input monitoring unavailable\n");

    for (int i = 0; i < MAX_SYSTEMS; i++)
        scan_games(&systems[i]);

    set_cpu_governor("powersave");
    set_gpu_governor("powersave");
    printf("Standing by...\n");

    SDL_Event event;

    while (true)
    { 
        while (SDL_PollEvent(&event))
            handle_input(&event);

        if (in_game_list)
            render_game_menu();
        else
            render_system_menu();

        if (input_monitor_check_hotkeys() == HOTKEY_SHUTDOWN) {
            if (renderer) {
                SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255);
                SDL_RenderClear(renderer);
                draw_text(460, 400, "mata ne!", false);
                SDL_RenderPresent(renderer);
                SDL_Delay(1000);
            }
            system("poweroff");
            break;
        }

        SDL_Delay(50); // ~20 FPS is fine for a basic menu
        if (!backlight_on) // First render should be done by now
        {
            system("echo 132 > /sys/class/backlight/backlight/brightness");
            backlight_on = true;
        }
    }

    input_monitor_cleanup();
    cleanup_sdl();
    return 0;
}
