.PHONY: all swift-build go-build go-vendor go-tidy clean

SERVICE_DIR := clicktion-service
SERVICE_BIN := $(SERVICE_DIR)/clicktion-service

all: go-build swift-build

# Build the Go service
go-build:
	cd $(SERVICE_DIR) && CGO_ENABLED=1 go build -o clicktion-service ./cmd/server

# Vendor Go dependencies (run once)
go-vendor:
	cd $(SERVICE_DIR) && go mod tidy && go mod vendor

# Build the Swift app (produces .build/debug/Clicktion)
swift-build:
	swift build

# Build release
swift-release:
	swift build -c release

# Bundle the service binary next to the Swift app for local dev
dev-install: go-build
	mkdir -p "$(HOME)/Library/Application Support/Clicktion"
	cp $(SERVICE_BIN) "$(HOME)/Library/Application Support/Clicktion/clicktion-service.new"
	mv -f "$(HOME)/Library/Application Support/Clicktion/clicktion-service.new" "$(HOME)/Library/Application Support/Clicktion/clicktion-service"
	cp -r skills "$(HOME)/Library/Application Support/Clicktion/skills" 2>/dev/null || true

# Install default skills
install-skills:
	mkdir -p "$(HOME)/Library/Application Support/Clicktion/skills"
	cp skills/*.md skills/*.json "$(HOME)/Library/Application Support/Clicktion/skills/"

SUPPORT_DIR      := $(HOME)/Library/Application\ Support/Clicktion
APP_BUNDLE       := Clicktion.app/Contents/MacOS/Clicktion
# The Go service ships inside the app bundle; ServiceManager launches it from
# here (falling back to Application Support for older installs).
SERVICE_RESOURCE := Clicktion.app/Contents/Resources/clicktion-service

# Code-signing identity. Defaults to ad-hoc ("-") so the project builds
# without any developer cert. To use your own Apple Developer identity,
# create an untracked Makefile.local with e.g.:
#   SIGNING_IDENTITY = Apple Development: you@example.com (TEAMID)
SIGNING_IDENTITY ?= -
-include Makefile.local

# Full rebuild + reinstall + relaunch
dev: go-build swift-release bundle install-skills
	@echo "Relaunching Clicktion…"
	@pkill -x Clicktion 2>/dev/null; sleep 0.5; open Clicktion.app

bundle: swift-release go-build
	mkdir -p Clicktion.app/Contents/MacOS Clicktion.app/Contents/Resources
	cp .build/release/Clicktion $(APP_BUNDLE)
	cp $(SERVICE_BIN) $(SERVICE_RESOURCE)
	# Sign the nested service first, then the app (hardened runtime rejects
	# unsigned nested executables).
	codesign --force --sign "$(SIGNING_IDENTITY)" --options runtime $(SERVICE_RESOURCE)
	codesign --force --sign "$(SIGNING_IDENTITY)" --entitlements Clicktion.entitlements --options runtime Clicktion.app

install-skills:
	mkdir -p "$(SUPPORT_DIR)/skills" "$(SUPPORT_DIR)/captures"
	cp skills/*.md skills/*.json "$(SUPPORT_DIR)/skills/"

DIST_SIGNING ?= -

dist: swift-release go-build
	rm -rf Build
	mkdir -p Build/Clicktion.app/Contents/MacOS Build/Clicktion.app/Contents/Resources
	cp .build/release/Clicktion Build/Clicktion.app/Contents/MacOS/Clicktion
	cp $(SERVICE_BIN) Build/Clicktion.app/Contents/Resources/clicktion-service
	cp Clicktion.app/Contents/Info.plist Build/Clicktion.app/Contents/Info.plist
	cp -r skills Build/Clicktion.app/Contents/Resources/skills 2>/dev/null || true
	# Sign nested service first, then seal the whole app (with all resources in place).
	codesign --force --sign "$(DIST_SIGNING)" --options runtime Build/Clicktion.app/Contents/Resources/clicktion-service
	codesign --force --sign "$(DIST_SIGNING)" --entitlements Clicktion.entitlements --options runtime Build/Clicktion.app
	rm -f Build/Clicktion.dmg
	ln -sf /Applications Build/
	@echo ""
	@echo "✅ Drag Build/Clicktion.app into Build/Applications to install."
	@echo "   Or: open Build/"

clean:
	swift package clean
	rm -f $(SERVICE_BIN)
	rm -rf Build
