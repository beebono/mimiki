#ifndef SHARED_H
#define SHARED_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <unistd.h>
#include <dirent.h>
#include <fcntl.h>
#include <time.h>

typedef struct {
    bool nav_up;
    bool nav_down;
    bool nav_left;
    bool nav_right;
    bool nav_select;
    bool nav_back;
    bool exit_emu;
    bool shutdown;
} InputEvents;

bool input_monitor_init(void);
void input_monitor_poll(InputEvents *events);
void input_monitor_cleanup(void);

#endif // SHARED_H
