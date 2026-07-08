PREFIX ?= $(HOME)/bin
APP = RecBar.app
# Ad-hoc signing by default. With a real identity the TCC grant survives
# rebuilds: make app SIGN="Developer ID Application: Your Name (TEAMID)"
SIGN ?= -

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
	mkdir -p $(APP)/Contents/MacOS
	install .build/release/RecBar $(APP)/Contents/MacOS/RecBar
	cp Sources/RecBar/Info.plist $(APP)/Contents/Info.plist
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
