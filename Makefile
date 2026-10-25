# pbus - installation and Debian package build.
#
# make install DESTDIR=/path    install under an alternative root
# make deb                      build the .deb (dpkg-deb, no build dependency)
# make test                     end-to-end tests, unprivileged

PACKAGE := pbus
# Single source of truth for the version, shared with prel. It is substituted
# into lib/pbus/common.sh, the manual pages and the Debian changelog at build
# time; none of them carries a hardcoded number.
VERSION := $(strip $(shell cat VERSION 2>/dev/null))
ARCH    := all

ifeq ($(VERSION),)
$(error VERSION file is missing or empty at the root of the repository)
endif

# Copy a file, replacing @VERSION@ on the way.
subst_version = sed -e 's|@VERSION@|$(VERSION)|g' $(1) > $(2) && chmod $(3) $(2)

DESTDIR    ?=
prefix     ?= /usr
bindir      = $(prefix)/bin
sbindir     = $(prefix)/sbin
libdir      = $(prefix)/lib/pbus
mandir      = $(prefix)/share/man
docdir      = $(prefix)/share/doc/$(PACKAGE)
compdir     = $(prefix)/share/bash-completion/completions
tmpfilesdir = $(prefix)/lib/tmpfiles.d
unitdir     = $(prefix)/lib/systemd/system
sysconfdir  = /etc/pbus

BUILD := build
STAGE := $(BUILD)/$(PACKAGE)_$(VERSION)_$(ARCH)
DEB   := $(BUILD)/$(PACKAGE)_$(VERSION)_$(ARCH).deb

.PHONY: all install uninstall deb test check version clean

all:
	@echo "$(PACKAGE) $(VERSION) - targets: install, deb, test, version, clean"

version:
	@echo $(VERSION)

install:
	install -d -m 0755 $(DESTDIR)$(bindir) $(DESTDIR)$(sbindir) $(DESTDIR)$(libdir)
	install -m 0755 bin/pbus       $(DESTDIR)$(bindir)/pbus
	install -m 0755 sbin/pbusd     $(DESTDIR)$(sbindir)/pbusd
	$(call subst_version,lib/pbus/common.sh,$(DESTDIR)$(libdir)/common.sh,0644)
	install -d -m 0755 $(DESTDIR)$(sysconfdir)/events.d $(DESTDIR)$(sysconfdir)/listeners.d
	install -d -m 0700 $(DESTDIR)$(sysconfdir)/keys
	install -m 0644 etc/pbus/pbus.conf $(DESTDIR)$(sysconfdir)/pbus.conf
	install -d -m 0755 $(DESTDIR)$(unitdir)
	install -m 0644 systemd/pbus.service $(DESTDIR)$(unitdir)/pbus.service
	install -d -m 0755 $(DESTDIR)$(tmpfilesdir)
	install -m 0644 systemd/pbus.tmpfiles $(DESTDIR)$(tmpfilesdir)/pbus.conf
	install -d -m 0755 $(DESTDIR)$(compdir)
	install -m 0644 completion/pbus $(DESTDIR)$(compdir)/pbus
	install -d -m 0755 $(DESTDIR)$(mandir)/man1 $(DESTDIR)$(mandir)/man8
	$(call subst_version,man/pbus.1,$(DESTDIR)$(mandir)/man1/pbus.1,0644)
	$(call subst_version,man/pbusd.8,$(DESTDIR)$(mandir)/man8/pbusd.8,0644)
	gzip -9nf $(DESTDIR)$(mandir)/man1/pbus.1 $(DESTDIR)$(mandir)/man8/pbusd.8
	install -d -m 0755 $(DESTDIR)$(docdir)
	install -m 0644 README.md $(DESTDIR)$(docdir)/README.md
	install -m 0644 examples/prel-release.md $(DESTDIR)$(docdir)/prel-release.md
	install -m 0644 packaging/copyright $(DESTDIR)$(docdir)/copyright
	$(call subst_version,packaging/changelog,$(DESTDIR)$(docdir)/changelog.Debian,0644)
	gzip -9nf $(DESTDIR)$(docdir)/changelog.Debian
	install -d -m 0755 $(DESTDIR)/var/log/pbus
	install -d -m 0750 $(DESTDIR)/var/lib/pbus
	install -d -m 0700 $(DESTDIR)/var/lib/pbus/auth

uninstall:
	rm -f $(DESTDIR)$(bindir)/pbus $(DESTDIR)$(sbindir)/pbusd
	rm -rf $(DESTDIR)$(libdir)
	rm -f $(DESTDIR)$(unitdir)/pbus.service $(DESTDIR)$(tmpfilesdir)/pbus.conf
	rm -f $(DESTDIR)$(compdir)/pbus
	rm -f $(DESTDIR)$(mandir)/man1/pbus.1.gz $(DESTDIR)$(mandir)/man8/pbusd.8.gz
	rm -rf $(DESTDIR)$(docdir)

$(DEB): install-stage
	dpkg-deb --root-owner-group --build $(STAGE) $(DEB)
	@echo
	@dpkg-deb --info $(DEB) | sed -n '1,20p'

install-stage:
	rm -rf $(STAGE)
	$(MAKE) install DESTDIR=$(CURDIR)/$(STAGE)
	install -d -m 0755 $(STAGE)/DEBIAN
	sed -e 's/@VERSION@/$(VERSION)/' -e 's/@ARCH@/$(ARCH)/' \
		-e "s/@SIZE@/$$(du -sk $(STAGE) | cut -f1)/" \
		packaging/control.in > $(STAGE)/DEBIAN/control
	install -m 0755 packaging/postinst $(STAGE)/DEBIAN/postinst
	install -m 0755 packaging/prerm    $(STAGE)/DEBIAN/prerm
	install -m 0755 packaging/postrm   $(STAGE)/DEBIAN/postrm
	install -m 0644 packaging/conffiles $(STAGE)/DEBIAN/conffiles
	cd $(STAGE) && find . -path ./DEBIAN -prune -o -type f -print0 \
		| xargs -0 md5sum | sed 's| \./| |' > DEBIAN/md5sums
	chmod 0644 $(STAGE)/DEBIAN/md5sums

deb: $(DEB)

test check:
	tests/run-tests.sh

clean:
	rm -rf $(BUILD)
