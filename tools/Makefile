# fw12-foldstate -- the fold-switch level reader.
#
# Kept apart from osk/ because it shares nothing with the keyboard: no GTK, no
# Wayland, no xkb. It is one ioctl and a directory scan, and building it with
# the keyboard's flags would mean pulling four pkg-config packages in to
# compile ninety lines that need none of them.

PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin

CFLAGS ?= -O2 -Wall -Wextra

all: fw12-foldstate

fw12-foldstate: fw12-foldstate.c
	$(CC) $(CFLAGS) -o $@ $<

install: fw12-foldstate
	install -Dm755 fw12-foldstate $(DESTDIR)$(BINDIR)/fw12-foldstate

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/fw12-foldstate

clean:
	rm -f fw12-foldstate

.PHONY: all install uninstall clean
