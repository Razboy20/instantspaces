# instantspaces

Patches macOS Dock in-process to reduce animation durations for:
- **Spaces switching** - Desktop/Space transitions
- **Window minimize/unminimize** - Scale and Shrink effects

| | |
|---|---|
| **macOS** | 14 (Sonoma), 15 (Sequoia) |
| **Arch** | Apple Silicon (arm64e) |
| **Requires** | SIP disabled, Xcode Command Line Tools |

Based on [yabai](https://github.com/koekeishiya/yabai)'s scripting addition injection technique.

## Quick Start

```bash
# Build and install
make install

# Restart Dock and inject
make restart

# Or just inject into running Dock
make inject
```

## Installation

### Prerequisites

1. **Disable SIP** - Boot to Recovery Mode, run:
   ```bash
   csrutil enable --without fs --without debug --without nvram
   ```

2. **Install Xcode Command Line Tools**:
   ```bash
   # although technically running `make` will install this as well
   xcode-select --install
   ```

### Build & Install

```bash
make install
```

This installs to `/Library/ScriptingAdditions/instantspaces.osax/`.

## Usage

### Manual Injection

```bash
# Inject with defaults (mode=zero, features=all)
make inject

# Restart Dock and inject
make restart

# Custom mode and features
make inject MODE=min0125 FEATURES=spaces
```

### Modes

| Mode | Duration | Description |
|------|----------|-------------|
| `zero` | 0.0s | Instant (default) |
| `min0125` | 0.125s | Near-instant, helps with floating window redraw issues |

### Features

| Feature | Description |
|---------|-------------|
| `all` | Patch everything (default) |
| `spaces` | Only Spaces switching animations |
| `minimize` | Only window minimize/unminimize |

### Auto-Injection Service

Install a LaunchDaemon to automatically inject when Dock starts:

```bash
# Install service
make service-install

# Check status
make service-status

# Remove service
make service-remove
```

## Makefile Targets

| Target | Description |
|--------|-------------|
| `make` | Build payload and loader |
| `make install` | Install to /Library/ScriptingAdditions |
| `make inject` | Inject into running Dock |
| `make restart` | Restart Dock and inject |
| `make service-install` | Install auto-injection service |
| `make service-remove` | Remove auto-injection service |
| `make service-status` | Check service status |
| `make uninstall` | Remove everything |
| `make logs` | Show payload logs |
| `make clean` | Remove build artifacts |

## Logs

```bash
# View logs
make logs

# Or check Console.app with filter: instantspaces
# Or: /private/var/tmp/instantspaces.<PID>.log
```

Expected output:
```
[instantspaces] Payload loaded into Dock (pid=1234)
[instantspaces] instantspaces_patch started (mode=zero, features=all)
[instantspaces] Dock __TEXT: 0x... - 0x... (... bytes)
[instantspaces] Patched [spaces-sequoia] @0x...: 0x... -> 0x2f00e400
[instantspaces] Patched: spaces=2, minimize=4
[instantspaces] Total patches applied: 6
```

## Uninstall

```bash
make uninstall
```

## Troubleshooting

**Injection fails / dlopen returns NULL:**
- Ensure SIP is disabled: `csrutil status`
- Grant Developer Tools permission (Terminal/LLDB) in System Settings > Privacy & Security
- Run `make install` to ensure proper signing

**Animation still present:**
- Check logs show patches were applied
- Try `make restart` to patch early in Dock lifecycle
- Ensure "Displays have separate Spaces" is enabled in System Settings > Desktop & Dock

**Floating windows disappear (zero mode):**
- Use `min0125` mode: `make inject MODE=min0125`
- This gives the compositor a frame to redraw

## How It Works

The payload searches for ARM64 instruction patterns that control animation durations in Dock's `__TEXT` segment, then patches them to load immediate values (0.0 or 0.125) instead of the original duration.

Injection uses LLDB by default. If `nvram boot-args` contains `arm64e_preview_abi`, a faster Mach-based loader is used instead.
