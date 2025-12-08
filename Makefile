# instantspaces Makefile
#
# Usage:
#   make                  Build payload and loader
#   make install          Install to /Library/ScriptingAdditions
#   make inject           Inject into running Dock (requires sudo)
#   make service-install  Install LaunchDaemon for auto-injection
#   make service-remove   Remove LaunchDaemon
#   make uninstall        Remove everything
#   make clean            Remove build artifacts
#
# Configuration:
#   MODE=zero|min0125     Animation mode (default: zero)
#   FEATURES=all|spaces|minimize  Which features to patch (default: all)

# Build configuration
CC := xcrun clang
CFLAGS := -mmacosx-version-min=14.0 -Wall -O2 -arch arm64e
FRAMEWORKS := -framework Cocoa
PAYLOAD_EXPORTS := -Wl,-exported_symbol,_instantspaces_patch -Wl,-exported_symbol,_instantspaces_verify

# Runtime configuration
MODE ?= zero
FEATURES ?= all

# Paths
OSAX_PATH := /Library/ScriptingAdditions/instantspaces.osax
AGENT_PLIST := $(HOME)/Library/LaunchAgents/com.instantspaces.inject.plist
PAYLOAD := $(OSAX_PATH)/Contents/Resources/payload.bundle/Contents/MacOS/payload

# =============================================================================
# Build targets
# =============================================================================

.PHONY: all clean

all: payload.dylib loader

payload.dylib: src/payload.m
	$(CC) $(CFLAGS) -dynamiclib $(FRAMEWORKS) $(PAYLOAD_EXPORTS) $< -o $@

loader: src/loader.m
	$(CC) $(CFLAGS) $(FRAMEWORKS) $< -o $@
	# codesign -fs "-" $@
	# pain and suffering; Mach-O caps (check in otool -h) must be 0x80, however recent versions of clang build with 0x81.
	printf '\x80' | dd of=loader bs=1 seek=11 count=1 conv=notrunc

# =============================================================================
# Installation targets
# =============================================================================

.PHONY: install uninstall

install: payload.dylib loader
	@echo "Installing to $(OSAX_PATH)..."
	sudo mkdir -p $(OSAX_PATH)/Contents/MacOS
	sudo mkdir -p $(OSAX_PATH)/Contents/Resources/payload.bundle/Contents/MacOS
	sudo cp osax/Info.plist $(OSAX_PATH)/Contents/Info.plist
	sudo cp osax/payload-Info.plist $(OSAX_PATH)/Contents/Resources/payload.bundle/Contents/Info.plist
	sudo cp payload.dylib $(OSAX_PATH)/Contents/Resources/payload.bundle/Contents/MacOS/payload
	sudo cp loader $(OSAX_PATH)/Contents/MacOS/loader
	sudo cp scripts/auto-inject.sh $(OSAX_PATH)/Contents/Resources/auto-inject.sh
	sudo chmod +x $(OSAX_PATH)/Contents/Resources/auto-inject.sh
	sudo xattr -dr com.apple.quarantine $(OSAX_PATH) 2>/dev/null || true
	sudo codesign -fs "-" $(OSAX_PATH)/Contents/Resources/payload.bundle
	sudo codesign -fs "-" $(OSAX_PATH)
	@echo "Installed successfully."

uninstall: service-remove
	@echo "Removing $(OSAX_PATH)..."
	sudo rm -rf $(OSAX_PATH)
	@echo "Uninstalled."

# =============================================================================
# Injection targets
# =============================================================================

.PHONY: inject

# Internal target for injection logic
_inject:
	@echo "Injecting with MODE=$(MODE) FEATURES=$(FEATURES)..."
	@PID=$$(pgrep -x Dock); \
	if [ -z "$$PID" ]; then \
		echo "error: Dock not running"; \
		exit 1; \
	fi; \
	echo "Dock pid: $$PID"; \
	if nvram boot-args 2>/dev/null | grep -q "arm64e_preview_abi" && [ -x "$(OSAX_PATH)/Contents/MacOS/loader" ]; then \
		echo "Using loader (arm64e_preview_abi enabled)"; \
		sudo $(OSAX_PATH)/Contents/MacOS/loader -m "$(MODE)" -f "$(FEATURES)" "$(PAYLOAD)"; \
	else \
		echo "Using LLDB"; \
		sudo /usr/bin/lldb -p "$$PID" -b \
			-o "expr (int)setenv(\"INSTANTSPACES_MODE\",\"$(MODE)\",1)" \
			-o "expr (int)setenv(\"INSTANTSPACES_FEATURES\",\"$(FEATURES)\",1)" \
			-o "expr (void*)dlopen(\"$(PAYLOAD)\", 2)" \
			-o 'expr (char*)dlerror()' \
			-o 'process detach' \
			-o 'quit'; \
	fi
	@echo "Done."

inject: install _inject

# =============================================================================
# Service targets (LaunchDaemon for auto-injection on Dock restart)
# =============================================================================

.PHONY: service-install service-remove service-status

service-install: install
	@echo "Installing LaunchAgent..."
	@mkdir -p $(HOME)/Library/LaunchAgents
	cp osax/launchd.plist $(AGENT_PLIST)
	launchctl bootstrap gui/$$(id -u) $(AGENT_PLIST) 2>/dev/null || true
	launchctl enable gui/$$(id -u)/com.instantspaces.inject
	launchctl kickstart -k gui/$$(id -u)/com.instantspaces.inject 2>/dev/null || true
	@echo "Service installed. Will auto-inject on login and Dock restart."

service-remove:
	@echo "Removing LaunchAgent..."
	-launchctl bootout gui/$$(id -u)/com.instantspaces.inject 2>/dev/null
	-rm -f $(AGENT_PLIST)
	@echo "Service removed."

service-status:
	@if launchctl list | grep -q com.instantspaces.inject; then \
		echo "Service is loaded"; \
		launchctl list com.instantspaces.inject; \
	else \
		echo "Service is not loaded"; \
	fi

# =============================================================================
# Convenience targets
# =============================================================================

.PHONY: restart logs

# Restart Dock and inject
restart: install
	@echo "Restarting Dock..."
	killall Dock
	@sleep 1
	@$(MAKE) _inject MODE=$(MODE) FEATURES=$(FEATURES)

# Show logs
logs:
	@PID=$$(pgrep -x Dock); \
	if [ -n "$$PID" ] && [ -f "/private/var/tmp/instantspaces.$$PID.log" ]; then \
		cat "/private/var/tmp/instantspaces.$$PID.log"; \
	else \
		echo "No log file found. Check Console.app with filter: instantspaces"; \
	fi

clean:
	rm -f payload.dylib loader loader_test
