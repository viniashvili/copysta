.PHONY: run build bundle clean

BUNDLE   = copysta.app
CONTENTS = $(BUNDLE)/Contents
BINARY   = copysta

# Development: compile and run directly (AX permissions tied to this binary path).
run:
	swift run

# Release binary.
build:
	swift build -c release

# Wrap the release binary into an .app bundle (icon, Info.plist, no Dock icon).
# Grant $(BUNDLE) Accessibility in System Settings → Privacy & Security; the app is
# unsigned, so macOS resets that permission after every rebuild.
bundle: build
	rm -rf $(BUNDLE)
	mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	cp .build/release/$(BINARY) $(CONTENTS)/MacOS/$(BINARY)
	cp Resources/Info.plist $(CONTENTS)/
	cp Resources/AppIcon.icns Resources/MenuBarIcon*.png $(CONTENTS)/Resources/
	@echo ""
	@echo "Bundle created: $(BUNDLE)"
	@echo "Run with:  open $(BUNDLE)"
	@echo "For Accessibility (⌘⇧V hotkey + caret detection):"
	@echo "  System Settings → Privacy & Security → Accessibility → add $(BUNDLE)"

clean:
	swift package clean
	rm -rf $(BUNDLE)
