# Field Command (Linux edition)
#   make run               play from the source tree
#   make test              the test suite (pytest)
#   make smoke             headless AI-vs-AI game, no window
#   sudo make install      install to /usr/local (PREFIX=/usr for system packaging)
#   make rpm               build a Fedora RPM into ./rpmbuild (make rpm-deps first, once)

NAME     := field-command
VERSION  := 1.40.2
PREFIX   ?= /usr/local
DESTDIR  ?=
DATADIR  := $(PREFIX)/share
APPDIR   := $(DATADIR)/$(NAME)
PYTHON   ?= python3

.PHONY: run test smoke install uninstall icons dist rpm rpm-deps clean

run:
	./field-command

test:
	$(PYTHON) -m pytest tests -q

smoke:
	FC_HEADLESS=1 FC_AUTOPLAY=1 FC_AUTOSTART=1 $(PYTHON) -m fieldcommand

icons:
	$(PYTHON) -m fieldcommand --make-icons data/icons/hicolor

install:
	install -d $(DESTDIR)$(APPDIR)/fieldcommand $(DESTDIR)$(PREFIX)/bin
	install -m 644 fieldcommand/*.py $(DESTDIR)$(APPDIR)/fieldcommand/
	sed 's|/usr/share/field-command|$(APPDIR)|' field-command > $(DESTDIR)$(PREFIX)/bin/$(NAME)
	chmod 755 $(DESTDIR)$(PREFIX)/bin/$(NAME)
	install -d $(DESTDIR)$(DATADIR)/applications $(DESTDIR)$(DATADIR)/metainfo
	install -m 644 data/$(NAME).desktop $(DESTDIR)$(DATADIR)/applications/
	install -m 644 data/$(NAME).metainfo.xml $(DESTDIR)$(DATADIR)/metainfo/
	for d in data/icons/hicolor/*/apps; do \
		size=$$(basename $$(dirname $$d)); \
		install -d $(DESTDIR)$(DATADIR)/icons/hicolor/$$size/apps; \
		install -m 644 $$d/$(NAME).png $(DESTDIR)$(DATADIR)/icons/hicolor/$$size/apps/; \
	done

uninstall:
	rm -rf $(DESTDIR)$(APPDIR)
	rm -f $(DESTDIR)$(PREFIX)/bin/$(NAME)
	rm -f $(DESTDIR)$(DATADIR)/applications/$(NAME).desktop $(DESTDIR)$(DATADIR)/metainfo/$(NAME).metainfo.xml
	rm -f $(DESTDIR)$(DATADIR)/icons/hicolor/*/apps/$(NAME).png

dist:
	mkdir -p rpmbuild/SOURCES
	tar --exclude='__pycache__' --exclude='rpmbuild' --exclude='tests' --exclude='.pytest_cache' -czf rpmbuild/SOURCES/$(NAME)-$(VERSION).tar.gz \
		--transform 's|^\.|$(NAME)-$(VERSION)|' .

# The packages rpmbuild needs on the build machine (the spec's BuildRequires). `make rpm-deps` installs them.
BUILD_DEPS := rpm-build make python3-devel desktop-file-utils libappstream-glib

rpm-deps:
	sudo dnf install -y $(BUILD_DEPS)

rpm: dist
	@for p in $(BUILD_DEPS); do rpm -q $$p >/dev/null 2>&1 || missing="$$missing $$p"; done; \
	if [ -n "$$missing" ]; then echo "Missing build packages:$$missing"; echo "Install them with:  make rpm-deps   (or: sudo dnf install$$missing)"; exit 1; fi
	rpmbuild --define "_topdir $(CURDIR)/rpmbuild" -ba $(NAME).spec
	@echo; echo "RPMs:"; find rpmbuild/RPMS rpmbuild/SRPMS -name '*.rpm'

clean:
	rm -rf rpmbuild fieldcommand/__pycache__
