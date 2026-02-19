#ifndef INPUT_MONITOR_H
#define INPUT_MONITOR_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <unistd.h>
#include <dirent.h>
#include <fcntl.h>
#include <time.h>

extern bool backlight_on;

bool input_monitor_init(void);
bool input_monitor_check_hotkeys(void);
void input_monitor_cleanup(void);

#endif // INPUT_MONITOR_H
