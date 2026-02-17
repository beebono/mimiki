#define _DEFAULT_SOURCE

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <unistd.h>
#include <sys/wait.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <time.h>
#include <SDL2/SDL.h>
#include <SDL2/SDL_image.h>
#include "font_data.h"

// Display configuration
#define SCREEN_WIDTH 640
#define SCREEN_HEIGHT 480

// Colors (RGB565 approximations)
#define COLOR_BACKGROUND 0x000000
#define COLOR_TEXT 0xFFFFFF
#define COLOR_SELECTED 0x00FF00
#define COLOR_BORDER 0x808080

// Menu configuration
#define MAX_SYSTEMS 4
#define MAX_GAMES 256

typedef enum {
    SYSTEM_N64,
    SYSTEM_DREAMCAST,
    SYSTEM_PS1,
    SYSTEM_PSP
} SystemType;

typedef struct {
    char name[256];
    char path[512];
} Game;

typedef struct {
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

static const char *n64_exts[] = {".z64", ".n64", ".v64", NULL};
static const char *dc_exts[] = {".gdi", ".cdi", ".chd", NULL};
static const char *ps1_exts[] = {".cue", ".chd", ".pbp", NULL};
static const char *psp_exts[] = {".iso", ".cso", ".chd", NULL};

static System systems[MAX_SYSTEMS] = {
    {"Nintendo 64", "n64", "mupen64plus", n64_exts, {}, 0},
    {"Dreamcast", "dreamcast", "flycast", dc_exts, {}, 0},
    {"PlayStation", "ps1", "duckstation-nogui", ps1_exts, {}, 0},
    {"PS Portable", "psp", "PPSSPPSDL", psp_exts, {}, 0}
};

static bool has_extension(const char *filename, const char **extensions) {
    if (!filename || !extensions) return false;

    const char *dot = strrchr(filename, '.');
    if (!dot) return false;

    for (int i = 0; extensions[i]; i++) {
        if (strcasecmp(dot, extensions[i]) == 0) {
            return true;
        }
    }
    return false;
}

static void set_governors(const char *cpu_gov, const char *gpu_gov) {
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

    if (gpu_gov) {
        const char *gpu_path = "/sys/class/devfreq/fde60000.gpu/governor";
        FILE *fp = fopen(gpu_path, "w");
        if (fp) {
            fprintf(fp, "%s\n", gpu_gov);
            fclose(fp);
            printf("Set GPU governor to: %s\n", gpu_gov);
            return;
        }
        fprintf(stderr, "Could not set GPU governor.\n");
    }
}

// Comparison function for qsort to sort games alphabetically by name
static int compare_games(const void *a, const void *b) {
    const Game *game_a = (const Game *)a;
    const Game *game_b = (const Game *)b;
    return strcasecmp(game_a->name, game_b->name);
}

static void scan_games(System *system) {
    DIR *dir;
    struct dirent *entry;
    system->game_count = 0;

    const char *base_dirs[] = {"/mnt/games", "/mnt/games2"};

    // Scan each base directory
    for (int d = 0; d < 2; d++) {
        char rom_dir[512];
        snprintf(rom_dir, sizeof(rom_dir), "%s/%s", base_dirs[d], system->short_name);

        dir = opendir(rom_dir);
        if (!dir) continue;

        while ((entry = readdir(dir)) != NULL && system->game_count < MAX_GAMES) {
            if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) {
                continue;
            }

            // Only skip directories, regular files may be DT_UNKNOWN
            if (entry->d_type == DT_DIR) continue;

            if (has_extension(entry->d_name, system->extensions)) {
                Game *game = &system->games[system->game_count];

                // Copy filename without extension as game name
                strncpy(game->name, entry->d_name, sizeof(game->name) - 1);
                char *dot = strrchr(game->name, '.');
                if (dot) *dot = '\0';

                // Full path
                snprintf(game->path, sizeof(game->path), "%s/%s",
                         rom_dir, entry->d_name);

                system->game_count++;
            }
        }
        closedir(dir);
    }

    // Sort games alphabetically by name
    if (system->game_count > 0) {
        qsort(system->games, system->game_count, sizeof(Game), compare_games);
    }

    printf("Found %d games for %s\n", system->game_count, system->name);
}

static bool load_font(void) {
    int img_flags = IMG_INIT_PNG;
    if (!(IMG_Init(img_flags) & img_flags)) {
        fprintf(stderr, "SDL_image init failed: %s\n", IMG_GetError());
        return false;
    }

    SDL_Surface *font_surface = IMG_Load("/usr/share/mimiki/assets/font.png");
    if (!font_surface) {
        fprintf(stderr, "Failed to load font.png: %s\n", IMG_GetError());
        return false;
    }

    font_texture = SDL_CreateTextureFromSurface(renderer, font_surface);
    SDL_FreeSurface(font_surface);

    if (!font_texture) {
        fprintf(stderr, "Failed to create font texture: %s\n", SDL_GetError());
        return false;
    }

    printf("Bitmap font loaded successfully\n");
    return true;
}

static bool init_sdl(void) {
    if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_GAMECONTROLLER) < 0) {
        fprintf(stderr, "SDL_Init failed: %s\n", SDL_GetError());
        return false;
    }

    window = SDL_CreateWindow("MIMIKI",
                               SDL_WINDOWPOS_UNDEFINED,
                               SDL_WINDOWPOS_UNDEFINED,
                               SCREEN_WIDTH, SCREEN_HEIGHT,
                               SDL_WINDOW_FULLSCREEN | SDL_WINDOW_VULKAN);

    if (!window) {
        fprintf(stderr, "SDL_CreateWindow failed: %s\n", SDL_GetError());
        SDL_Quit();
        return false;
    }

    renderer = SDL_CreateRenderer(window, -1, SDL_RENDERER_ACCELERATED);

    if (!renderer) {
        fprintf(stderr, "SDL_CreateRenderer failed: %s\n", SDL_GetError());
        SDL_DestroyWindow(window);
        SDL_Quit();
        return false;
    }

    if (!load_font()) {
        SDL_DestroyRenderer(renderer);
        SDL_DestroyWindow(window);
        SDL_Quit();
        return false;
    }

    for (int i = 0; i < SDL_NumJoysticks(); i++) {
        if (SDL_IsGameController(i)) {
            gamepad = SDL_GameControllerOpen(i);
            if (gamepad) {
                printf("Gamepad opened: %s\n", SDL_GameControllerName(gamepad));
                break;
            }
        }
    }

    printf("SDL2 initialized successfully (KMS/DRM backend)\n");
    return true;
}

static void cleanup_sdl(void) {
    if (font_texture) { SDL_DestroyTexture(font_texture); font_texture = NULL; }
    if (gamepad) { SDL_GameControllerClose(gamepad); gamepad = NULL; }
    if (renderer) { SDL_DestroyRenderer(renderer); renderer = NULL; }
    if (window) { SDL_DestroyWindow(window); window = NULL; }
    IMG_Quit();
    SDL_Quit();
}

static void draw_text(int x, int y, const char *text, bool selected) {
    if (!text || !font_texture) return;

    if (selected) {
        SDL_SetTextureColorMod(font_texture, 100, 255, 100);
    } else {
        SDL_SetTextureColorMod(font_texture, 255, 255, 255);
    }

    int cursor_x = x;
    int cursor_y = y;

    for (const char *c = text; *c != '\0'; c++) {
        unsigned char ch = (unsigned char)*c;

        // Only render supported ASCII characters
        if (ch < FONT_FIRST_CHAR || ch > FONT_LAST_CHAR) {
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
            FONT_CHAR_HEIGHT
        };

        // Destination rect on screen
        SDL_Rect dst_rect = {
            cursor_x,
            cursor_y,
            FONT_CHAR_WIDTH,
            FONT_CHAR_HEIGHT
        };

        SDL_RenderCopy(renderer, font_texture, &src_rect, &dst_rect);

        cursor_x += FONT_CHAR_WIDTH;
    }

    SDL_SetTextureColorMod(font_texture, 255, 255, 255);
}

static void render_system_menu(void) {
    SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255);
    SDL_RenderClear(renderer);

    // Title
    draw_text(272, 40, "MIMIKI", false);

    // System list
    int y = 120;
    for (int i = 0; i < MAX_SYSTEMS; i++) {
        bool selected = (i == current_system);

        // Selection indicator
        if (selected) {
            draw_text(120, y, ">", true);
        }

        draw_text(150, y, systems[i].name, selected);

        // Game count
        char count[32];
        snprintf(count, sizeof(count), "(%d games)", systems[i].game_count);
        draw_text(400, y, count, false);

        y += 50;
    }

    // Instructions
    draw_text(120, 396, "D-PAD: Navigate  A: Select", false);

    SDL_RenderPresent(renderer);
}

static void render_game_menu(void) {
    SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255);
    SDL_RenderClear(renderer);

    System *sys = &systems[current_system];

    // Title
    int title_width = strlen(sys->name) * FONT_CHAR_WIDTH;
    int title_x = (SCREEN_WIDTH - title_width) / 2;
    draw_text(title_x, 40, sys->name, false);

    // Game list
    int games_per_page = 10;
    int start_idx = (current_game / games_per_page) * games_per_page;
    int y = 80;

    for (int i = start_idx; i < start_idx + games_per_page && i < sys->game_count; i++) {
        bool selected = (i == current_game);

        // Selection indicator
        if (selected) {
            draw_text(80, y, ">", true);
        }

        draw_text(110, y, sys->games[i].name, selected);
        y += 30;
    }

    // Instructions
    draw_text(120, 396, "D-PAD: Navigate  A: Launch", false);
    draw_text(120, 420, "                 B:  Back", false);

    // Page indicator if needed
    if (sys->game_count > games_per_page) {
        int current_page = (current_game / games_per_page) + 1;
        int total_pages = (sys->game_count + games_per_page - 1) / games_per_page;
        char page_info[32];
        snprintf(page_info, sizeof(page_info), "PAGE : %d/%d", current_page, total_pages);
        draw_text(120, 420, page_info, false);
    }

    SDL_RenderPresent(renderer);
}

static void launch_game(System *sys, Game *game) {
    printf("Launching: %s (%s)\n", game->name, game->path);
    cleanup_sdl();

    const char *cpu_gov = "schedutil";
    const char *gpu_gov = "simple_ondemand";
    if (strcmp(sys->short_name, "n64") == 0) {
        cpu_gov = "performance";
        gpu_gov = "performance";
    } else if ((strcmp(sys->short_name, "dreamcast") == 0) || 
               (strcmp(sys->short_name, "psp") == 0)) {
        gpu_gov = "performance";
    }

    if (strcmp(cpu_gov, "performance") == 0)
        printf("Hyper Clock Up!!!\n");
    else
        printf("Clock Up!\n");

    set_governors(cpu_gov, gpu_gov);

    pid_t pid = fork();
    if (pid == 0) {
        // Child process
        if (strcmp(sys->short_name, "n64") == 0) {
            execl("/usr/bin/mupen64plus", "mupen64plus", "--fullscreen", game->path, (char *)NULL);
        } else if (strcmp(sys->short_name, "dreamcast") == 0) {
            execl("/usr/bin/flycast", "flycast", game->path, (char *)NULL);
        } else if (strcmp(sys->short_name, "ps1") == 0) {
            execl("/usr/bin/duckstation-nogui", "duckstation-nogui", game->path, (char *)NULL);
        } else if (strcmp(sys->short_name, "psp") == 0) {
            execl("/usr/bin/PPSSPPSDL", "PPSSPPSDL", game->path, (char *)NULL);
        }

        fprintf(stderr, "Failed to launch %s: %s\n", sys->emulator, strerror(errno));
    } else if (pid > 0) {
        // Parent process
        int status;
        waitpid(pid, &status, 0);

        printf("Emulator exited with status %d\n", WEXITSTATUS(status));
    } else {
        // Fork failed
        fprintf(stderr, "Fork failed\n");
    }

    printf("Clock Over...\n");
    set_governors("powersave", "powersave");
    init_sdl();
}

static void handle_input(SDL_Event *event) {
    if (event->type == SDL_QUIT) {
        exit(0);
    }

    // Gamepad inputs
    if (event->type == SDL_CONTROLLERBUTTONDOWN) {
        switch (event->cbutton.button) {
            case SDL_CONTROLLER_BUTTON_DPAD_UP:
                if (in_game_list) {
                    if (current_game > 0) current_game--;
                } else {
                    if (current_system > 0) current_system--;
                }
                break;

            case SDL_CONTROLLER_BUTTON_DPAD_DOWN:
                if (in_game_list) {
                    System *sys = &systems[current_system];
                    if (current_game < sys->game_count - 1) current_game++;
                } else {
                    if (current_system < MAX_SYSTEMS - 1) current_system++;
                }
                break;

            case SDL_CONTROLLER_BUTTON_A:
                if (in_game_list) {
                    System *sys = &systems[current_system];
                    if (sys->game_count > 0) {
                        launch_game(sys, &sys->games[current_game]);
                    }
                } else {
                    System *sys = &systems[current_system];
                    if (sys->game_count > 0) {
                        in_game_list = true;
                        current_game = 0;
                    }
                }
                break;

            case SDL_CONTROLLER_BUTTON_B:
                if (in_game_list) {
                    in_game_list = false;
                    current_game = 0;
                }
                break;
        }
    }
}

int main(int argc, char *argv[]) {
    printf("MIMIKI Launcher - Starting...\n");

    if (!init_sdl()) {
        return 1;
    }

    for (int i = 0; i < MAX_SYSTEMS; i++) {
        scan_games(&systems[i]);
    }

    set_governors("powersave", "powersave");
    printf("Standing by...\n");

    SDL_Event event;
    bool running = true;

    while (running) {
        while (SDL_PollEvent(&event)) {
            handle_input(&event);
        }

        if (in_game_list) {
            render_game_menu();
        } else {
            render_system_menu();
        }

        SDL_Delay(100); // ~10 FPS is fine for a basic menu
    }

    cleanup_sdl();
    return 0;
}
