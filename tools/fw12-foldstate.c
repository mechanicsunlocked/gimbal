/* fw12-foldstate -- print whether the machine is folded, right now.
 *
 * Usage: fw12-foldstate [eventN]
 *   Prints "<level> <device>", e.g. "0 event3".
 *   Given a device name, it checks that one and skips the search.
 *
 * Hyprland delivers the fold switch as *edges*: switch:on enters tablet mode,
 * switch:off leaves it. An edge that never arrives is never made up for, and
 * the failure is not quiet -- tablet mode stays latched with the knob overlays
 * mapped over the desktop and follow_mouse on the tablet value, until some
 * later fold happens to land an edge.
 *
 * The same switch also has a current *level*, which answers "are we folded"
 * with no history, no threshold and no sensor fusion. It is the signal the
 * firmware itself uses to cut the built-in keyboard, so it cannot disagree
 * with the machine. Reading it takes an EVIOCGSW ioctl, which Lua has no way
 * to issue -- hence this.
 *
 * The hinge angle was the alternative and it is the weaker one: it needs a
 * threshold, it needs hysteresis, and above all it reports 500 as an
 * "indeterminate" sentinel during the fold itself, which is exactly when you
 * are most likely to ask.
 *
 * Exits 0 having printed the level and the device it was read from.
 * Exits 1, printing nothing, when no tablet-mode switch can be read, so the
 * caller can fall back to the angle rather than assume a state.
 *
 * The switch is found by capability, never by name or device number, because
 * input nodes renumber across boots -- this machine was seen renumbering its
 * IIO devices mid-session.
 *
 * That search runs in sysfs, and the reason is worth keeping. Opening an
 * evdev node opens the underlying input device, and for an i2c-HID device
 * that can mean powering it up and resetting it. A first version scanned by
 * opening every /dev/input/event* in turn: it worked, and it cost 158 ms per
 * run against a 1.2 ms fork -- all of it waiting on hardware that had no
 * business being touched. Reading capabilities/sw first costs nothing, wakes
 * nothing, and leaves exactly one device to open.
 *
 * Even that search is ~8 ms, which is most of a frame if the caller is a
 * compositor, so the answer carries the device it came from and the caller
 * can hand it back next time. A named device that no longer advertises the
 * switch is not trusted -- it falls back to the full search rather than
 * reading whatever renumbering put there instead.
 */

#define _POSIX_C_SOURCE 200809L

#include <dirent.h>
#include <fcntl.h>
#include <limits.h>
#include <linux/input.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define BITS_PER_LONG (int)(8 * sizeof(long))
#define NLONGS(n) (((n) + BITS_PER_LONG - 1) / BITS_PER_LONG)

static int bit_set(const unsigned long *arr, int bit) {
  return (arr[bit / BITS_PER_LONG] >> (bit % BITS_PER_LONG)) & 1UL;
}

/* Does this event node advertise SW_TABLET_MODE, per sysfs?
 *
 * The kernel prints capability bitmaps as space-separated hex words, most
 * significant first, so bits 0..63 are always in the final word -- and
 * SW_TABLET_MODE is bit 1. */
static int advertises_tablet_switch(const char *event_name) {
  char path[128];
  if ((size_t)snprintf(path, sizeof path,
                       "/sys/class/input/%s/device/capabilities/sw",
                       event_name) >= sizeof path)
    return 0;

  FILE *f = fopen(path, "re");
  if (!f) return 0;

  char line[256];
  char *got = fgets(line, sizeof line, f);
  fclose(f);
  if (!got) return 0;

  char *last = NULL;
  for (char *tok = strtok(line, " \t\n"); tok; tok = strtok(NULL, " \t\n"))
    last = tok;
  if (!last) return 0;

  return (strtoull(last, NULL, 16) >> SW_TABLET_MODE) & 1ULL;
}

/* -1 = could not read, 0 = laptop, 1 = folded. */
static int read_fold_level(const char *event_name) {
  char path[128];
  if ((size_t)snprintf(path, sizeof path, "/dev/input/%s", event_name) >=
      sizeof path)
    return -1;

  int fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
  if (fd < 0) return -1;

  unsigned long state[NLONGS(SW_CNT)];
  memset(state, 0, sizeof state);
  int rc = ioctl(fd, EVIOCGSW(sizeof state), state);
  close(fd);

  if (rc < 0) return -1;
  return bit_set(state, SW_TABLET_MODE) ? 1 : 0;
}

/* Verify a caller-supplied name before trusting it: renumbering is exactly
 * the failure this tool exists to be immune to. */
static int try_named(const char *name, char *out, size_t out_len) {
  if (strncmp(name, "event", 5) != 0) return -1;
  if (strpbrk(name, "/.") != NULL) return -1;
  if (!advertises_tablet_switch(name)) return -1;
  snprintf(out, out_len, "%s", name);
  return read_fold_level(name);
}

static int search(char *out, size_t out_len) {
  DIR *dir = opendir("/sys/class/input");
  if (!dir) return -1;

  int found = -1;
  struct dirent *ent;
  while (found < 0 && (ent = readdir(dir)) != NULL) {
    if (strncmp(ent->d_name, "event", 5) != 0) continue;
    if (!advertises_tablet_switch(ent->d_name)) continue;
    found = read_fold_level(ent->d_name);
    if (found >= 0) snprintf(out, out_len, "%s", ent->d_name);
  }
  closedir(dir);
  return found;
}

int main(int argc, char **argv) {
  char device[NAME_MAX + 1] = "";
  int found = -1;

  if (argc > 1) found = try_named(argv[1], device, sizeof device);
  if (found < 0) found = search(device, sizeof device);
  if (found < 0) return 1;

  printf("%d %s\n", found, device);
  return 0;
}
