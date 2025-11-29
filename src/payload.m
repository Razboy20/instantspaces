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

// Feature categories for selective patching
typedef enum {
    FEATURE_SPACES   = 1 << 0,
    FEATURE_MINIMIZE = 1 << 1,
    FEATURE_ALL      = FEATURE_SPACES | FEATURE_MINIMIZE,
} FeatureFlags;

// macOS version targeting
typedef enum {
    OS_ANY     = 0,  // Works on all versions
    OS_SONOMA  = 14, // macOS 14
    OS_SEQUOIA = 15, // macOS 15
} OSVersion;

// Pattern specification with metadata
typedef struct {
    const char  *pattern;      // Hex pattern to match
    int          patch_offset; // Byte offset within match to apply patch
    const char  *name;         // Descriptive name for logging
    FeatureFlags feature;      // Which feature this pattern belongs to
    OSVersion    os_target;    // Target OS (OS_ANY = all versions)
    OSVersion    os_fallback;  // Fallback: try if os_target didn't match (OS_ANY = no fallback)
} PatternSpec;

static int g_log_fd = -1;
static void log_line(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    { va_list cp; va_copy(cp, ap); char buf[1024]; vsnprintf(buf, sizeof(buf), fmt, cp); va_end(cp); NSLog(@"[instantspaces] %s", buf); }
    if (g_log_fd == -1) {
        char path[PATH_MAX]; snprintf(path, sizeof(path), "/private/var/tmp/instantspaces.%d.log", getpid());
        g_log_fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
    }
    if (g_log_fd != -1) { char line[1024]; vsnprintf(line, sizeof(line), fmt, ap); write(g_log_fd, line, (unsigned)strlen(line)); write(g_log_fd, "\n", 1); fsync(g_log_fd); }
    va_end(ap);
}

static inline int hexval(char c){ if(c>='0'&&c<='9')return c-'0'; if(c>='a'&&c<='f')return 10+(c-'a'); if(c>='A'&&c<='F')return 10+(c-'A'); return -1; }
static size_t parse_pattern(const char *p,unsigned char *bytes,unsigned char *mask,size_t cap){
    size_t n=0; while(*p && n<cap){ while(*p==' ') p++; if(!*p) break;
        if(p[0]=='?'&&p[1]=='?'){ bytes[n]=0; mask[n]=0; n++; p+=2; }
        else { int hi=hexval(p[0]), lo=hexval(p[1]); if(hi<0||lo<0) break; bytes[n]=(unsigned char)((hi<<4)|lo); mask[n]=1; n++; p+=2; }
        if(*p==' ') p++;
    } return n;
}
static size_t search_buf(const unsigned char *buf,size_t buflen,const unsigned char *pat,const unsigned char *msk,size_t patlen,size_t start_off){
    if(!buf||patlen==0||buflen<patlen||start_off>buflen-patlen) return SIZE_MAX;
    size_t limit=buflen-patlen; for(size_t i=start_off;i<=limit;i++){ size_t j=0;
        for(;j<patlen;j++){ if(!msk[j]) continue; if(buf[i+j]!=pat[j]) break; }
        if(j==patlen) return i;
    } return SIZE_MAX;
}

static BOOL find_dock_text(uint64_t *out_text_start,uint64_t *out_text_size){
    uint32_t count=_dyld_image_count();
    for(uint32_t i=0;i<count;i++){
        const char *name=_dyld_get_image_name(i); if(!name) continue;
        if(!strstr(name,"/Dock.app/Contents/MacOS/Dock")) continue;
        const struct mach_header_64 *mh=(const struct mach_header_64*)_dyld_get_image_header(i);
        if(!mh||mh->magic!=MH_MAGIC_64) continue;
        intptr_t slide=_dyld_get_image_vmaddr_slide(i);
        const uint8_t *cur=(const uint8_t*)(mh+1);
        for(uint32_t c=0;c<mh->ncmds;c++){
            const struct load_command *lc=(const struct load_command*)cur;
            if(lc->cmd==LC_SEGMENT_64){
                const struct segment_command_64 *seg=(const struct segment_command_64*)cur;
                if(strcmp(seg->segname,"__TEXT")==0){
                    *out_text_start=seg->vmaddr + (uint64_t)slide;
                    *out_text_size =seg->vmsize;
                    return YES;
                }
            }
            cur += lc->cmdsize;
        }
    }
    return NO;
}

// All pattern definitions
// Spaces: patch first instruction (fmov d0, #0.5 -> our replacement)
// Minimize: patch second instruction at offset 4 (fmov d0, d8 -> our replacement)
//
// Format: {pattern, patch_offset, name, feature, os_target, os_fallback}
// - os_target: primary OS version this pattern is for
// - os_fallback: if os_target patterns find nothing, try patterns with this as os_target
static PatternSpec g_all_patterns[] = {
    // Spaces switching patterns (patch at offset 0)
    // Sonoma primary, Sequoia fallback
    {"00 10 6A 1E E0 03 14 AA ?? 03 ?? AA", 0, "spaces-sonoma",   FEATURE_SPACES, OS_SONOMA,  OS_SEQUOIA},
    // Sequoia primary, Sonoma fallback
    {"00 10 6A 1E A8 ?? ?? D1 ?? 01 ?? F8", 0, "spaces-sequoia",  FEATURE_SPACES, OS_SEQUOIA, OS_SONOMA},

    // Minimize patterns (patch at offset 4 - the fmov d0, d8 instruction)
    // These appear to work across versions (OS_ANY)
    {"28 1C 60 1E 00 41 60 1E", 4, "minimize-scale",  FEATURE_MINIMIZE, OS_ANY, OS_ANY},
    {"08 1C 61 1E 00 41 60 1E", 4, "minimize-shrink", FEATURE_MINIMIZE, OS_ANY, OS_ANY},
    // TODO: Genie mode pattern
};
static const int g_pattern_count = sizeof(g_all_patterns) / sizeof(g_all_patterns[0]);

// Get current macOS major version
static int get_os_major_version(void) {
    static int cached = -1;
    if (cached < 0) {
        NSOperatingSystemVersion v = [[NSProcessInfo processInfo] operatingSystemVersion];
        cached = (int)v.majorVersion;
    }
    return cached;
}

// Check if pattern should be tried for current OS
// pass=0: try patterns matching current OS or OS_ANY
// pass=1: try fallback patterns (where os_fallback matches current OS)
static BOOL pattern_matches_os(PatternSpec *spec, int pass) {
    int os = get_os_major_version();
    if (pass == 0) {
        // Primary pass: match os_target == current OS or OS_ANY
        return (spec->os_target == OS_ANY || spec->os_target == os);
    } else {
        // Fallback pass: match os_fallback == current OS
        return (spec->os_fallback == os);
    }
}

// Parse INSTANTSPACES_FEATURES env var: "all" (default), "spaces", "minimize"
static FeatureFlags get_enabled_features(void) {
    const char *feat = getenv("INSTANTSPACES_FEATURES");
    if (!feat || strcmp(feat, "all") == 0) return FEATURE_ALL;
    if (strcmp(feat, "spaces") == 0) return FEATURE_SPACES;
    if (strcmp(feat, "minimize") == 0) return FEATURE_MINIMIZE;
    return FEATURE_ALL;
}
static inline uint64_t page_align(uint64_t x){ return x & ~(uint64_t)(vm_page_size-1); }

// Record patched sites
static uint64_t g_patched_sites[64];
static int g_patched_count = 0;

static void record_patched(uint64_t addr){
    if(g_patched_count < (int)(sizeof(g_patched_sites)/sizeof(g_patched_sites[0]))){
        g_patched_sites[g_patched_count++] = addr;
    }
}

// Select patch opcode by env var: INSTANTSPACES_MODE = "zero" | "min0125"
static uint32_t pick_patch_insn(void){
    const char *mode = getenv("INSTANTSPACES_MODE");
    if (mode && strcmp(mode, "min0125") == 0) {
        // fmov d0, #0.125
        return 0x1e681000;
    }
    // default: zero duration (current behavior)
    // movi d0, #0 (as used by yabai Write)
    return 0x2f00e400;
}

// Try to patch a single pattern, returns number of sites patched
static int try_patch_pattern(PatternSpec *spec, uint64_t text_start, uint64_t text_size,
                             uint32_t patchInsn, int *spaces_patched, int *minimize_patched) {
    unsigned char pat[128], msk[128];
    size_t plen = parse_pattern(spec->pattern, pat, msk, sizeof(pat));
    if (!plen) return 0;

    int patched = 0;
    size_t start_off = 0;
    while (1) {
        size_t off = search_buf((const unsigned char*)(uintptr_t)text_start,
                                (size_t)text_size, pat, msk, plen, start_off);
        if (off == SIZE_MAX) break;

        // Calculate patch target: match start + patch_offset
        uint64_t match_start = text_start + off;
        uint64_t patch_addr = match_start + spec->patch_offset;
        uint32_t before = *(volatile uint32_t*)patch_addr;

        kern_return_t kr = vm_protect(mach_task_self(), page_align(patch_addr),
                                      vm_page_size, 0, VM_PROT_READ|VM_PROT_WRITE|VM_PROT_COPY);
        if (kr != KERN_SUCCESS) {
            log_line("vm_protect RW failed @0x%llx: %d", (unsigned long long)patch_addr, kr);
            return patched;
        }

        *(volatile uint32_t*)patch_addr = patchInsn;
        sys_icache_invalidate((void*)(uintptr_t)patch_addr, sizeof(uint32_t));
        __builtin___clear_cache((char*)(uintptr_t)patch_addr,
                                (char*)(uintptr_t)(patch_addr + sizeof(uint32_t)));
        (void)vm_protect(mach_task_self(), page_align(patch_addr), vm_page_size, 0,
                         VM_PROT_READ|VM_PROT_EXECUTE);

        uint32_t after = *(volatile uint32_t*)patch_addr;
        log_line("Patched [%s] @0x%llx: before=0x%08x after=0x%08x",
                 spec->name, (unsigned long long)patch_addr, before, after);
        record_patched(patch_addr);
        patched++;

        // Track per-feature counts
        if (spec->feature & FEATURE_SPACES) (*spaces_patched)++;
        if (spec->feature & FEATURE_MINIMIZE) (*minimize_patched)++;

        start_off = off + 1;
    }
    return patched;
}

static int patch_all_hits_in_text(uint64_t text_start, uint64_t text_size) {
    const FeatureFlags enabled = get_enabled_features();
    const uint32_t patchInsn = pick_patch_insn();
    int total_patched = 0;
    int spaces_patched = 0;
    int minimize_patched = 0;

    log_line("Running on macOS %d", get_os_major_version());

    // Two-pass approach:
    // Pass 0: Try patterns targeting current OS (or OS_ANY)
    // Pass 1: Try fallback patterns if primary pass found nothing for a feature
    int spaces_found_primary = 0;
    int minimize_found_primary = 0;

    for (int pass = 0; pass <= 1; pass++) {
        const char *pass_name = (pass == 0) ? "primary" : "fallback";

        for (int i = 0; i < g_pattern_count; i++) {
            PatternSpec *spec = &g_all_patterns[i];

            // Skip patterns for disabled features
            if (!(spec->feature & enabled)) continue;

            // Skip if this pattern doesn't match current pass criteria
            if (!pattern_matches_os(spec, pass)) continue;

            // On fallback pass, skip features that already found matches
            if (pass == 1) {
                if ((spec->feature & FEATURE_SPACES) && spaces_found_primary) continue;
                if ((spec->feature & FEATURE_MINIMIZE) && minimize_found_primary) continue;
            }

            int before_spaces = spaces_patched;
            int before_minimize = minimize_patched;

            int count = try_patch_pattern(spec, text_start, text_size, patchInsn,
                                          &spaces_patched, &minimize_patched);
            if (count > 0) {
                log_line("Pattern [%s] matched %d site(s) (%s pass)", spec->name, count, pass_name);
                total_patched += count;
            }

            // Track if primary pass found matches per feature
            if (pass == 0) {
                if (spaces_patched > before_spaces) spaces_found_primary = 1;
                if (minimize_patched > before_minimize) minimize_found_primary = 1;
            }
        }
    }

    log_line("Patched breakdown: spaces=%d, minimize=%d", spaces_patched, minimize_patched);
    return total_patched;
}

static const char* features_to_str(FeatureFlags f) {
    if (f == FEATURE_ALL) return "all";
    if (f == FEATURE_SPACES) return "spaces";
    if (f == FEATURE_MINIMIZE) return "minimize";
    return "none";
}

__attribute__((visibility("default"))) int instantspaces_patch(void) {
#if !defined(__arm64__)
    return 1;
#else
    @autoreleasepool {
        const char *mode = getenv("INSTANTSPACES_MODE");
        FeatureFlags features = get_enabled_features();
        log_line("instantspaces_patch: entered (mode=%s, features=%s)",
                 mode ? mode : "zero", features_to_str(features));

        uint64_t text_start = 0, text_size = 0;
        if (!find_dock_text(&text_start, &text_size)) {
            log_line("Failed to find Dock __TEXT; abort.");
            return 1;
        }
        log_line("Dock __TEXT=[0x%llx..0x%llx)",
                 (unsigned long long)text_start, (unsigned long long)(text_start + text_size));

        g_patched_count = 0;
        int count = patch_all_hits_in_text(text_start, text_size);
        log_line("Total sites patched: %d", count);
        return count > 0 ? 0 : 2;
    }
#endif
}

__attribute__((visibility("default"))) int instantspaces_verify(void){
#if !defined(__arm64__)
    return 1;
#else
    @autoreleasepool {
        log_line("Verify: patched_count=%d", g_patched_count);
        for(int i=0;i<g_patched_count;i++){
            uint64_t addr = g_patched_sites[i];
            uint32_t val = *(volatile uint32_t*)addr;
            log_line("Verify patched @0x%llx => 0x%08x", (unsigned long long)addr, val);
        }
        return g_patched_count;
    }
#endif
}

__attribute__((constructor)) static void ctor(void){
    log_line("constructor: payload loaded into Dock pid=%d", getpid());
    (void)instantspaces_patch();
}