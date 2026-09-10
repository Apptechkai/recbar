PREFIX ?= $(HOME)/bin
APP = RecBar.app
# Signing identity. A stable identity (even a self-signed "RecBar Dev" cert
# in the login keychain) keeps the Screen Recording / Microphone grants across
# rebuilds; ad-hoc ("-") signing loses them every build. Auto-detects the
# self-signed cert; override with SIGN="Developer ID Application: ...".
SIGN ?= $(shell security find-identity -p codesigning 2>/dev/null | grep -q '"RecBar Dev"' && echo "RecBar Dev" || echo "-")

.PHONY: build install uninstall app install-app uninstall-app clean smoke

# End-to-end check of the real capture engine (plays sound; ~1 minute).
smoke: build
	@bash scripts/smoke.sh

build:
	swift build -c release

install: build
	mkdir -p $(PREFIX)
	install .build/release/rec $(PREFIX)/rec
	@echo "Installed $(PREFIX)/rec — make sure $(PREFIX) is on your PATH."

uninstall:
	rm -f $(PREFIX)/rec

app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	install .build/release/RecBar $(APP)/Contents/MacOS/RecBar
	cp Sources/RecBar/Info.plist $(APP)/Contents/Info.plist
	cp Resources/RecBar.icns $(APP)/Contents/Resources/RecBar.icns
	codesign --force -s "$(SIGN)" $(APP)

install-app: app
	rm -rf /Applications/$(APP)
	cp -R $(APP) /Applications/$(APP)
	@echo "Installed /Applications/$(APP) — launch it from Spotlight (RecBar)."

uninstall-app:
	rm -rf /Applications/$(APP)

# --- Release ----------------------------------------------------------------
# One-time setup for notarization (needs an Apple Developer ID):
#   xcrun notarytool store-credentials "RecBar" --apple-id you@example.com \
#       --team-id TEAMID --password <app-specific-password>
# Then:  make release SIGN="Developer ID Application: Your Name (TEAMID)"
VERSION ?= $(shell git describe --tags --always 2>/dev/null || echo dev)
NOTARY_PROFILE ?= RecBar
DIST = dist

release: app
	rm -rf $(DIST) && mkdir -p $(DIST)
	codesign --force --options runtime --timestamp -s "$(SIGN)" $(APP)
	ditto -c -k --keepParent $(APP) $(DIST)/RecBar-$(VERSION).zip
	xcrun notarytool submit $(DIST)/RecBar-$(VERSION).zip --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple $(APP)
	ditto -c -k --keepParent $(APP) $(DIST)/RecBar-$(VERSION).zip
	install .build/release/rec $(DIST)/rec
	@echo "Release artifacts in $(DIST)/"

clean:
	swift package clean
	rm -rf $(APP) $(DIST)
