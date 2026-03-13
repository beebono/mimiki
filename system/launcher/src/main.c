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

// Colors
#define COLOR_BACKGROUND 0x000000
#define COLOR_TEXT 0xFFFFFF
#define COLOR_SELECTED 0x00FF00

// Menu
#define MAX_SYSTEMS 4
#define MAX_GAMES 256

typedef struct
{
    char name[256];
    char path[512];
} Game;

typedef struct
{
    const char *name;
    const char *short_name;
    const char *core;
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

static const char *n64_exts[] = {".z64", ".n64", ".v64", NULL};
static const char *dc_exts[] = {".gdi", ".cdi", ".chd", NULL};
static const char *ps1_exts[] = {".cue", ".chd", ".pbp", NULL};
static const char *psp_exts[] = {".iso", ".cso", ".chd", NULL};

static System systems[MAX_SYSTEMS] = {
    {"Nintendo 64", "n64", "/usr/lib/cores/mupen64plus_next_libretro.so", n64_exts, {}, 0},
    {"Dreamcast", "dc", "/usr/lib/cores/flycast_libretro.so", dc_exts, {}, 0},
    {"PlayStation", "ps1", "/usr/lib/cores/pcsx_rearmed_libretro.so", ps1_exts, {}, 0},
    {"PS Portable", "psp", "/usr/lib/cores/ppsspp_libretro.so", psp_exts, {}, 0}};

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
    if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_GAMECONTROLLER) < 0)
    {
        fprintf(stderr, "SDL_Init failed: %s\n", SDL_GetError());
        return false;
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

static void draw_text(int x, int y, const char *text, bool selected)
{
    if (!text || !font_texture)
        return;

    if (selected)
        SDL_SetTextureColorMod(font_texture, 100, 255, 100);
    else
        SDL_SetTextureColorMod(font_texture, 255, 255, 255);

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

        // Source rect from atlas
        SDL_Rect src_rect = {
            atlas_x,
            atlas_y,
            FONT_CHAR_WIDTH,
            FONT_CHAR_HEIGHT};

        // Destination rect on screen
        SDL_Rect dst_rect = {
            cursor_x,
            cursor_y,
            FONT_CHAR_WIDTH,
            FONT_CHAR_HEIGHT};

        SDL_RenderCopy(renderer, font_texture, &src_rect, &dst_rect);

        cursor_x += FONT_CHAR_WIDTH;
    }

    SDL_SetTextureColorMod(font_texture, 255, 255, 255);
}

static void render_system_menu(void)
{
    SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255);
    SDL_RenderClear(renderer);

    // Title
    draw_text(272, 40, "MIMIKI", false);

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

    const char *system_dir = "/root/.config/retroarch/system";
    const char *gpu_gov = "simple_ondemand";
    if ((strcmp(sys->short_name, "ps1") == 0) ||
        (strcmp(sys->short_name, "dc") == 0)) {
        system_dir = "/mnt/games/bios";
    } else if (strcmp(sys->short_name, "n64") == 0) {
        gpu_gov = "performance";
    }

    setenv("LIBRETRO_SYSTEM_DIRECTORY", system_dir, 1);
    set_cpu_governor("schedutil");
    set_gpu_governor(gpu_gov);

    pid_t pid = fork();
    if (pid == 0)
    {
        // Child process
        execl("/usr/bin/retroarch", "retroarch",
            "-f", "-L", sys->core, game->path, (char *)NULL);

        fprintf(stderr, "Failed to launch %s: %s\n", sys->core, strerror(errno));
    }
    else if (pid > 0)
    {
        // Parent process
        int status;
        while (waitpid(pid, &status, WNOHANG) == 0)
        {
            if (input_monitor_check_hotkeys()) {
                kill(pid, SIGTERM); // rcK handles reaping
                // Don't bother changing governor here since it's going down soon anyway
                goto powoff;
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

    set_cpu_governor("powersave");
    set_gpu_governor("powersave");

powoff:
    init_sdl();
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

        if (input_monitor_check_hotkeys()) {
            SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255);
            SDL_RenderClear(renderer);
            draw_text(460, 400, "mata ne!", false);
            SDL_RenderPresent(renderer);
            SDL_Delay(1000);
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
