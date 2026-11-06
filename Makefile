APP_NAME = Sift
BINARY = LarkMini
APP = dist/$(APP_NAME).app
BIN = .build/release/$(BINARY)

.PHONY: build app run demo dmg clean icon install

build:
	swift build -c release

app: build icon
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(BIN) $(APP)/Contents/MacOS/$(APP_NAME)
	cp Support/Info.plist $(APP)/Contents/Info.plist
	@if [ -f Support/AppIcon.icns ]; then cp Support/AppIcon.icns $(APP)/Contents/Resources/AppIcon.icns; fi
	codesign --force --deep --sign - $(APP)
	@echo "Built $(APP)"

install: app
	rm -f "$(HOME)/.local/bin/larkmini"
	rm -rf "$(HOME)/Applications/LarkMini.app" "$(HOME)/Applications/Sift.app"
	mkdir -p "$(HOME)/Applications" "$(HOME)/.local/bin"
	cp -R $(APP) "$(HOME)/Applications/Sift.app"
	printf '#!/bin/sh\nexec "$(HOME)/Applications/Sift.app/Contents/MacOS/Sift" --cli "$$@"\n' > "$(HOME)/.local/bin/sift"
	chmod +x "$(HOME)/.local/bin/sift"
	@echo "Installed $(HOME)/Applications/Sift.app and $(HOME)/.local/bin/sift"

icon:
	@if [ ! -f Support/AppIcon.icns ]; then \
		swift Tools/make-icon.swift >/dev/null 2>&1 && \
		iconutil -c icns Support/AppIcon.iconset -o Support/AppIcon.icns && \
		rm -rf Support/AppIcon.iconset; \
	fi

run: app
	open $(APP)

demo: app
	open $(APP) --args --demo

dmg: app
	rm -rf dist/dmg dist/$(APP_NAME).dmg
	mkdir -p dist/dmg
	cp -R $(APP) dist/dmg/
	ln -s /Applications dist/dmg/Applications
	hdiutil create -volname "Sift" -srcfolder dist/dmg -ov -format UDZO dist/$(APP_NAME).dmg
	@echo "dist/$(APP_NAME).dmg"

clean:
	swift package clean
	rm -rf dist Support/AppIcon.iconset
