PREFIX ?= $(HOME)/bin
APP = RecBar.app
# Signing identity. A stable identity (even a self-signed "RecBar Dev" cert
# in the login keychain) keeps the Screen Recording / Microphone grants across
# rebuilds; ad-hoc ("-") signing loses them every build. Auto-detects the
# self-signed cert; override with SIGN="Developer ID Application: ...".
SIGN ?= $(shell security find-identity -p codesigning 2>/dev/null | grep -q '"RecBar Dev"' && echo "RecBar Dev" || echo "-")

.PHONY: build install uninstall app install-app uninstall-app clean

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

clean:
	swift package clean
	rm -rf $(APP)
