# QuitGuard
#
# `make install` builds Release and installs straight to /Applications, which is
# the only build you should grant Accessibility to. Debug builds live in
# DerivedData under a path that changes, and granting those confuses TCC.

APP_NAME    := QuitGuard
BUNDLE_ID   := com.raahil.quitguard
SCHEME      := QuitGuard
INSTALL_DIR := /Applications
INSTALLED   := $(INSTALL_DIR)/$(APP_NAME).app
BUILD_DIR   := $(CURDIR)/build

.PHONY: all cert generate build install uninstall clean identity

all: install

## cert — create the self-signed "QuitGuard Local" identity (idempotent)
cert:
	./scripts/make-signing-cert.sh

## generate — regenerate the .xcodeproj from project.yml
generate:
	xcodegen generate

## build — Debug build, for a quick compile check
build: generate
	xcodebuild -scheme $(SCHEME) -configuration Debug build

## install — Release build straight into /Applications, then relaunch
install: cert generate
	@echo "==> Building Release..."
	@xcodebuild -scheme $(SCHEME) -configuration Release \
	    CONFIGURATION_BUILD_DIR="$(BUILD_DIR)/Release" \
	    build | tail -3
	@echo "==> Stopping any running instance..."
	@pkill -f "$(APP_NAME).app/Contents/MacOS/$(APP_NAME)" 2>/dev/null || true
	@sleep 1
	@echo "==> Installing to $(INSTALLED)..."
	@rm -rf "$(INSTALLED)"
	@cp -R "$(BUILD_DIR)/Release/$(APP_NAME).app" "$(INSTALLED)"
	@echo "==> Verifying signature..."
	@codesign --verify --strict --verbose=1 "$(INSTALLED)"
	@codesign -d -r- "$(INSTALLED)" 2>&1 | grep designated
	@echo "==> Launching..."
	@open "$(INSTALLED)"
	@echo "==> Installed. Accessibility grant applies to $(INSTALLED)"

## identity — print the designated requirement of the installed app
## If this string ever changes, the Accessibility grant has been invalidated.
identity:
	@codesign -d -r- "$(INSTALLED)" 2>&1 | grep designated

## uninstall — remove the installed app (does NOT revoke the TCC grant)
uninstall:
	@pkill -f "$(APP_NAME).app/Contents/MacOS/$(APP_NAME)" 2>/dev/null || true
	@rm -rf "$(INSTALLED)"
	@echo "Removed $(INSTALLED)"

clean:
	rm -rf "$(BUILD_DIR)"
	xcodebuild -scheme $(SCHEME) -configuration Release clean >/dev/null || true
