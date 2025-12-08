// instantspaces payload - patches Dock animation timings in-process
//
// Injected into Dock via LLDB/scripting addition. Searches for ARM64 instruction
// patterns that control animation durations, then patches them to near-instant values.

#import <Cocoa/Cocoa.h>
#import <mach/mach.h>
#import <mach/mach_vm.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <libkern/OSCacheControl.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <limits.h>

// ============================================================================
#pragma mark - Configuration Types
// ============================================================================

typedef enum {
    FEATURE_SPACES   = 1 << 0,
    FEATURE_MINIMIZE = 1 << 1,
    FEATURE_ALL      = FEATURE_SPACES | FEATURE_MINIMIZE,
} FeatureFlags;

typedef enum {
    OS_ANY     = 0,
    OS_SONOMA  = 14,
    OS_SEQUOIA = 15,
} OSVersion;

typedef struct {
    const char   *pattern;       // Hex pattern with ?? wildcards
    int           patch_offset;  // Byte offset to instruction to replace
    const char   *name;          // Identifier for logging
    FeatureFlags  feature;       // Which feature category
    OSVersion     os_min;        // Minimum OS version (0 = no minimum)
    OSVersion     os_max;        // Maximum OS version (0 = no maximum)
} PatternSpec;

// ============================================================================
#pragma mark - Pattern Definitions
// ============================================================================

// Spaces: patch fmov d0, #0.5 instruction at match start
// Minimize: patch fmov s8/s0 instruction at specified offset
//
// os_min/os_max define version range (inclusive). Use 0 for unbounded.
// Examples: {.os_min=14, .os_max=14} = Sonoma only
//           {.os_min=15, .os_max=0}  = Sequoia and later
//           {.os_min=0,  .os_max=0}  = all versions

static PatternSpec g_patterns[] = {
    // Spaces - Sonoma only
    {
        .pattern      = "00 10 6A 1E E0 03 14 AA ?? 03 ?? AA",
        .patch_offset = 0,
        .name         = "spaces-sonoma",
        .feature      = FEATURE_SPACES,
        .os_min       = OS_SONOMA,
        .os_max       = OS_SONOMA,
    },
    // Spaces - Sequoia and later
    {
        .pattern      = "00 10 6A 1E A8 ?? ?? D1 ?? 01 ?? F8",
        .patch_offset = 0,
        .name         = "spaces-sequoia",
        .feature      = FEATURE_SPACES,
        .os_min       = OS_SEQUOIA,
        .os_max       = 0,
    },
    // Minimize - all versions
    {
        .pattern      = "E1 87 00 AD 08 1C 28 1E",
        .patch_offset = 4,
        .name         = "minimize",
        .feature      = FEATURE_MINIMIZE,
        .os_min       = 0,
        .os_max       = 0,
    },
    // Unminimize - all versions
    {
        .pattern      = "08 0D 20 1E 00 E4 00 6F E0 83 01 AD",
        .patch_offset = 0,
        .name         = "maximize",
        .feature      = FEATURE_MINIMIZE,
        .os_min       = 0,
        .os_max       = 0,
    },
};

static const int g_pattern_count = sizeof(g_patterns) / sizeof(g_patterns[0]);

// ============================================================================
#pragma mark - Global State
// ============================================================================

static int g_log_fd = -1;
static uint64_t g_patched_addrs[64];
static int g_patched_count = 0;

// ============================================================================
#pragma mark - Logging
// ============================================================================

static void log_line(const char *fmt, ...) {
    char buf[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);

    // Console.app via NSLog
    NSLog(@"[instantspaces] %s", buf);

    // File log for debugging
    if (g_log_fd == -1) {
        char path[PATH_MAX];
        snprintf(path, sizeof(path), "/private/var/tmp/instantspaces.%d.log", getpid());
        g_log_fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
    }
    if (g_log_fd != -1) {
        write(g_log_fd, buf, strlen(buf));
        write(g_log_fd, "\n", 1);
        fsync(g_log_fd);
    }
}

// ============================================================================
#pragma mark - Configuration
// ============================================================================

// Config file written by loader before injection (takes precedence over env vars)
#define CONFIG_PATH "/private/var/tmp/instantspaces.conf"

static char g_mode[16] = "zero";
static char g_features[16] = "all";

static void load_config(void) {
    // Try config file first (used by loader)
    FILE *f = fopen(CONFIG_PATH, "r");
    if (f) {
        char line[64];
        while (fgets(line, sizeof(line), f)) {
            char key[32], val[32];
            if (sscanf(line, "%31[^=]=%31s", key, val) == 2) {
                if (strcmp(key, "mode") == 0) {
                    strncpy(g_mode, val, sizeof(g_mode) - 1);
                } else if (strcmp(key, "features") == 0) {
                    strncpy(g_features, val, sizeof(g_features) - 1);
                }
            }
        }
        fclose(f);
        unlink(CONFIG_PATH);
        return;
    }

    // Fall back to environment variables (used by LLDB injection)
    const char *env_mode = getenv("INSTANTSPACES_MODE");
    if (env_mode) strncpy(g_mode, env_mode, sizeof(g_mode) - 1);

    const char *env_features = getenv("INSTANTSPACES_FEATURES");
    if (env_features) strncpy(g_features, env_features, sizeof(g_features) - 1);
}

static int get_macos_version(void) {
    static int cached = -1;
    if (cached < 0) {
        NSOperatingSystemVersion v = [[NSProcessInfo processInfo] operatingSystemVersion];
        cached = (int)v.majorVersion;
    }
    return cached;
}

static FeatureFlags get_enabled_features(void) {
    if (strcmp(g_features, "spaces") == 0) return FEATURE_SPACES;
    if (strcmp(g_features, "minimize") == 0) return FEATURE_MINIMIZE;
    return FEATURE_ALL;
}

static const char *features_str(FeatureFlags f) {
    if (f == FEATURE_ALL) return "all";
    if (f == FEATURE_SPACES) return "spaces";
    if (f == FEATURE_MINIMIZE) return "minimize";
    return "none";
}

// Returns replacement instruction for the given register
// Mode: "zero" = movi #0, "min0125" = fmov #0.125
static uint32_t get_patch_instruction(unsigned int reg) {
    if (reg > 31) {
        log_line("Invalid register number %u (must be 0-31)", reg);
        reg = 0;
    }

    BOOL use_min0125 = strcmp(g_mode, "min0125") == 0;
    uint32_t base = use_min0125 ? 0x1e681000u   // fmov d_, #0.125
                                : 0x2f00e400u;  // movi d_, #0
    return base | reg;
}

// ============================================================================
#pragma mark - Pattern Matching
// ============================================================================

static int hexval(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return 10 + (c - 'a');
    if (c >= 'A' && c <= 'F') return 10 + (c - 'A');
    return -1;
}

// Parse hex pattern string into bytes and mask arrays
// Returns number of bytes parsed
static size_t parse_pattern(const char *hex, uint8_t *bytes, uint8_t *mask, size_t capacity) {
    size_t n = 0;
    const char *p = hex;

    while (*p && n < capacity) {
        while (*p == ' ') p++;
        if (!*p) break;

        if (p[0] == '?' && p[1] == '?') {
            bytes[n] = 0;
            mask[n] = 0;  // Wildcard - don't compare
            n++;
            p += 2;
        } else {
            int hi = hexval(p[0]);
            int lo = hexval(p[1]);
            if (hi < 0 || lo < 0) break;
            bytes[n] = (uint8_t)((hi << 4) | lo);
            mask[n] = 1;  // Must match
            n++;
            p += 2;
        }
        if (*p == ' ') p++;
    }
    return n;
}

// Search buffer for pattern, respecting mask. Returns offset or SIZE_MAX if not found.
static size_t find_pattern(const uint8_t *buf, size_t buflen,
                           const uint8_t *pattern, const uint8_t *mask, size_t patlen,
                           size_t start_offset) {
    if (!buf || patlen == 0 || buflen < patlen || start_offset > buflen - patlen) {
        return SIZE_MAX;
    }

    size_t limit = buflen - patlen;
    for (size_t i = start_offset; i <= limit; i++) {
        BOOL match = YES;
        for (size_t j = 0; j < patlen; j++) {
            if (mask[j] && buf[i + j] != pattern[j]) {
                match = NO;
                break;
            }
        }
        if (match) return i;
    }
    return SIZE_MAX;
}

// ============================================================================
#pragma mark - Mach-O Parsing
// ============================================================================

// Locate Dock's __TEXT segment in memory
static BOOL find_dock_text(uint64_t *text_start, uint64_t *text_size) {
    uint32_t image_count = _dyld_image_count();

    for (uint32_t i = 0; i < image_count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name || !strstr(name, "/Dock.app/Contents/MacOS/Dock")) continue;

        const struct mach_header_64 *header = (const struct mach_header_64 *)_dyld_get_image_header(i);
        if (!header || header->magic != MH_MAGIC_64) continue;

        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        const uint8_t *cmd_ptr = (const uint8_t *)(header + 1);

        for (uint32_t c = 0; c < header->ncmds; c++) {
            const struct load_command *cmd = (const struct load_command *)cmd_ptr;
            if (cmd->cmd == LC_SEGMENT_64) {
                const struct segment_command_64 *seg = (const struct segment_command_64 *)cmd_ptr;
                if (strcmp(seg->segname, "__TEXT") == 0) {
                    *text_start = seg->vmaddr + (uint64_t)slide;
                    *text_size = seg->vmsize;
                    return YES;
                }
            }
            cmd_ptr += cmd->cmdsize;
        }
    }
    return NO;
}

// ============================================================================
#pragma mark - Memory Patching
// ============================================================================

static inline uint64_t page_start(uint64_t addr) {
    return addr & ~(uint64_t)(vm_page_size - 1);
}

// Make memory page writable for patching
static BOOL make_writable(uint64_t addr) {
    kern_return_t kr = vm_protect(mach_task_self(), page_start(addr), vm_page_size, 0,
                                  VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) {
        log_line("vm_protect RW failed @0x%llx: %d", (unsigned long long)addr, kr);
        return NO;
    }
    return YES;
}

// Restore memory page to executable
static void make_executable(uint64_t addr) {
    vm_protect(mach_task_self(), page_start(addr), vm_page_size, 0,
               VM_PROT_READ | VM_PROT_EXECUTE);
}

// Write instruction and flush caches
static void write_instruction(uint64_t addr, uint32_t instruction) {
    *(volatile uint32_t *)addr = instruction;
    sys_icache_invalidate((void *)(uintptr_t)addr, sizeof(uint32_t));
    __builtin___clear_cache((char *)(uintptr_t)addr,
                            (char *)(uintptr_t)(addr + sizeof(uint32_t)));
}

static void record_patch(uint64_t addr) {
    if (g_patched_count < (int)(sizeof(g_patched_addrs) / sizeof(g_patched_addrs[0]))) {
        g_patched_addrs[g_patched_count++] = addr;
    }
}

// ============================================================================
#pragma mark - Patching Engine
// ============================================================================

// Check if pattern applies to current macOS version
static BOOL pattern_matches_os(PatternSpec *spec) {
    int os = get_macos_version();
    BOOL above_min = (spec->os_min == 0) || (os >= spec->os_min);
    BOOL below_max = (spec->os_max == 0) || (os <= spec->os_max);
    return above_min && below_max;
}

// Apply patches for a single pattern specification
static int apply_pattern(PatternSpec *spec, uint64_t text_start, uint64_t text_size,
                         int *spaces_count, int *minimize_count) {
    uint8_t pattern_bytes[128];
    uint8_t pattern_mask[128];
    size_t pattern_len = parse_pattern(spec->pattern, pattern_bytes, pattern_mask, sizeof(pattern_bytes));
    if (pattern_len == 0) return 0;

    // Spaces patches d0, minimize patches d8
    int reg = (spec->feature & FEATURE_MINIMIZE) ? 8 : 0;
    uint32_t replacement = get_patch_instruction(reg);

    int patched = 0;
    size_t search_offset = 0;

    while (1) {
        size_t match = find_pattern((const uint8_t *)(uintptr_t)text_start, (size_t)text_size,
                                    pattern_bytes, pattern_mask, pattern_len, search_offset);
        if (match == SIZE_MAX) break;

        uint64_t patch_addr = text_start + match + spec->patch_offset;
        uint32_t before = *(volatile uint32_t *)patch_addr;

        if (!make_writable(patch_addr)) break;

        write_instruction(patch_addr, replacement);
        make_executable(patch_addr);

        uint32_t after = *(volatile uint32_t *)patch_addr;
        log_line("Patched [%s] @0x%llx: 0x%08x -> 0x%08x",
                 spec->name, (unsigned long long)patch_addr, before, after);

        record_patch(patch_addr);
        patched++;

        if (spec->feature & FEATURE_SPACES) (*spaces_count)++;
        if (spec->feature & FEATURE_MINIMIZE) (*minimize_count)++;

        search_offset = match + 1;
    }
    return patched;
}

// Apply all applicable patterns for current OS
static int patch_dock_text(uint64_t text_start, uint64_t text_size) {
    FeatureFlags enabled = get_enabled_features();
    int total = 0;
    int spaces_count = 0;
    int minimize_count = 0;

    log_line("macOS version: %d", get_macos_version());

    for (int i = 0; i < g_pattern_count; i++) {
        PatternSpec *spec = &g_patterns[i];

        // Skip disabled features
        if (!(spec->feature & enabled)) continue;

        // Skip patterns not applicable to this OS version
        if (!pattern_matches_os(spec)) continue;

        int count = apply_pattern(spec, text_start, text_size, &spaces_count, &minimize_count);
        if (count > 0) {
            log_line("[%s] %d match(es)", spec->name, count);
            total += count;
        }
    }

    log_line("Patched: spaces=%d, minimize=%d", spaces_count, minimize_count);
    return total;
}

// ============================================================================
#pragma mark - Public API
// ============================================================================

__attribute__((visibility("default")))
int instantspaces_patch(void) {
#if !defined(__arm64__)
    return 1;
#else
    @autoreleasepool {
        load_config();
        FeatureFlags features = get_enabled_features();
        log_line("instantspaces_patch started (mode=%s, features=%s)",
                 g_mode, features_str(features));

        uint64_t text_start = 0, text_size = 0;
        if (!find_dock_text(&text_start, &text_size)) {
            log_line("Failed to locate Dock __TEXT segment");
            return 1;
        }
        log_line("Dock __TEXT: 0x%llx - 0x%llx (%llu bytes)",
                 (unsigned long long)text_start,
                 (unsigned long long)(text_start + text_size),
                 (unsigned long long)text_size);

        g_patched_count = 0;
        int count = patch_dock_text(text_start, text_size);
        log_line("Total patches applied: %d", count);

        return count > 0 ? 0 : 2;
    }
#endif
}

__attribute__((visibility("default")))
int instantspaces_verify(void) {
#if !defined(__arm64__)
    return 1;
#else
    @autoreleasepool {
        log_line("Verifying %d patched sites", g_patched_count);
        for (int i = 0; i < g_patched_count; i++) {
            uint64_t addr = g_patched_addrs[i];
            uint32_t val = *(volatile uint32_t *)addr;
            log_line("  [%d] @0x%llx = 0x%08x", i, (unsigned long long)addr, val);
        }
        return g_patched_count;
    }
#endif
}

__attribute__((constructor))
static void payload_init(void) {
    log_line("Payload loaded into Dock (pid=%d)", getpid());
    instantspaces_patch();
}
