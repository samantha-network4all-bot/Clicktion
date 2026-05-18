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
	cp clicktion-service/clicktion-service $(SUPPORT_DIR)/clicktion-service.new
	mv -f $(SUPPORT_DIR)/clicktion-service.new $(SUPPORT_DIR)/clicktion-service
	codesign --force --sign "$(SIGNING_IDENTITY)" --entitlements Clicktion.entitlements --options runtime Clicktion.app

install-skills:
	mkdir -p "$(SUPPORT_DIR)/skills" "$(SUPPORT_DIR)/captures"
	cp skills/*.md skills/*.json "$(SUPPORT_DIR)/skills/"

clean:
	swift package clean
	rm -f $(SERVICE_BIN)
