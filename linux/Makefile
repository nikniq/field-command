# Field Command (Linux edition)
#   make run               play from the source tree
#   make test              the test suite (pytest)
#   make smoke             headless AI-vs-AI game, no window
#   sudo make install      install to /usr/local (PREFIX=/usr for system packaging)
#   make rpm               build a Fedora RPM into ./rpmbuild

NAME     := field-command
VERSION  := 1.6.0
PREFIX   ?= /usr/local
DESTDIR  ?=
DATADIR  := $(PREFIX)/share
APPDIR   := $(DATADIR)/$(NAME)
PYTHON   ?= python3

.PHONY: run test smoke install uninstall icons dist rpm clean

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

rpm: dist
	rpmbuild --define "_topdir $(CURDIR)/rpmbuild" -ba $(NAME).spec
	@echo; echo "RPMs:"; find rpmbuild/RPMS rpmbuild/SRPMS -name '*.rpm'

clean:
	rm -rf rpmbuild fieldcommand/__pycache__
