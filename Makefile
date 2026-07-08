PREFIX ?= $(HOME)/bin

.PHONY: build install uninstall clean

build:
	swift build -c release

install: build
	mkdir -p $(PREFIX)
	install .build/release/rec $(PREFIX)/rec
	@echo "Installed $(PREFIX)/rec — make sure $(PREFIX) is on your PATH."

uninstall:
	rm -f $(PREFIX)/rec

clean:
	swift package clean
