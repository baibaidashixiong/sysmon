PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin

.PHONY: check install uninstall

check:
	bash -n sysmon.sh
	bash -n tests/smoke.sh
	bash tests/smoke.sh

install:
	install -d "$(DESTDIR)$(BINDIR)"
	install -m 0755 sysmon.sh "$(DESTDIR)$(BINDIR)/sysmon"

uninstall:
	rm -f "$(DESTDIR)$(BINDIR)/sysmon"
