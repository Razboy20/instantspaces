// instantspaces loader - injects payload into Dock via Mach APIs
//
// Based on injection technique from yabai by koekeishiya (Jeremy Legendre).
// Requires: SIP disabled, arm64e, macOS 14+

#import <Cocoa/Cocoa.h>
#import <mach/mach.h>
#import <mach/mach_vm.h>
#import <dlfcn.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>
#import <sys/stat.h>
#import <ptrauth.h>

// Private API for thread state conversion (arm64e PAC)
kern_return_t (*_thread_convert_thread_state)(
    thread_act_t thread,
    int direction,
    thread_state_flavor_t flavor,
    thread_state_t in_state,
    mach_msg_type_number_t in_stateCnt,
    thread_state_t out_state,
    mach_msg_type_number_t *out_stateCnt
);

// Default payload path (can be overridden via command line)
static const char *default_payload_path =
    "/Library/ScriptingAdditions/instantspaces.osax/Contents/Resources/payload.dylib";

// ARM64e shellcode that:
// 1. Calls pthread_create_from_mach_thread to spawn a proper thread
// 2. The spawned thread calls dlopen() to load our payload
// 3. Signals completion by setting x0 to magic value
//
// Layout:
//   0x00-0x58: bootstrap (calls pthread_create_from_mach_thread)
//   0x58-0x60: pthread_create_from_mach_thread address
//   0x60-0x98: thread function (calls dlopen)
//   0xA0-0xA8: dlopen address
//   0xA8+:     payload path string

static char shellcode[] =
    // Bootstrap: create pthread and wait
    "\xFF\xC3\x00\xD1"                 // sub     sp, sp, #0x30
    "\xFD\x7B\x02\xA9"                 // stp     x29, x30, [sp, #0x20]
    "\xFD\x83\x00\x91"                 // add     x29, sp, #0x20
    "\xA0\xC3\x1F\xB8"                 // stur    w0, [x29, #-0x4]
    "\xE1\x0B\x00\xF9"                 // str     x1, [sp, #0x10]
    "\xE0\x23\x00\x91"                 // add     x0, sp, #0x8
    "\x08\x00\x80\xD2"                 // mov     x8, #0
    "\xE8\x07\x00\xF9"                 // str     x8, [sp, #0x8]
    "\xE1\x03\x08\xAA"                 // mov     x1, x8
    "\xE2\x01\x00\x10"                 // adr     x2, #0x3C (thread function)
    "\xE2\x23\xC1\xDA"                 // paciza  x2
    "\xE3\x03\x08\xAA"                 // mov     x3, x8
    "\x49\x01\x00\x10"                 // adr     x9, #0x28 (pthread_create_from_mach_thread ptr)
    "\x29\x01\x40\xF9"                 // ldr     x9, [x9]
    "\x20\x01\x3F\xD6"                 // blr     x9
    "\xA0\x4C\x8C\xD2"                 // movz    x0, #0x6265 ('eb')
    "\x20\x2C\xAF\xF2"                 // movk    x0, #0x7961, lsl #16 ('ya' -> 0x79616265 = "yabe")
    "\x09\x00\x00\x10"                 // adr     x9, #0
    "\x20\x01\x1F\xD6"                 // br      x9 (infinite loop)
    "\xFD\x7B\x42\xA9"                 // ldp     x29, x30, [sp, #0x20]
    "\xFF\xC3\x00\x91"                 // add     sp, sp, #0x30
    "\xC0\x03\x5F\xD6"                 // ret
    "\x00\x00\x00\x00\x00\x00\x00\x00" // [0x58] pthread_create_from_mach_thread address

    // Thread function: dlopen payload
    "\x7F\x23\x03\xD5"                 // pacibsp
    "\xFF\xC3\x00\xD1"                 // sub     sp, sp, #0x30
    "\xFD\x7B\x02\xA9"                 // stp     x29, x30, [sp, #0x20]
    "\xFD\x83\x00\x91"                 // add     x29, sp, #0x20
    "\xA0\xC3\x1F\xB8"                 // stur    w0, [x29, #-0x4]
    "\xE1\x0B\x00\xF9"                 // str     x1, [sp, #0x10]
    "\x21\x00\x80\xD2"                 // mov     x1, #1 (RTLD_LAZY)
    "\x60\x01\x00\x10"                 // adr     x0, #0x2c (payload path)
    "\x09\x01\x00\x10"                 // adr     x9, #0x20 (dlopen ptr)
    "\x29\x01\x40\xF9"                 // ldr     x9, [x9]
    "\x20\x01\x3F\xD6"                 // blr     x9
    "\x09\x00\x80\x52"                 // mov     w9, #0
    "\xE0\x03\x09\xAA"                 // mov     x0, x9
    "\xFD\x7B\x42\xA9"                 // ldp     x29, x30, [sp, #0x20]
    "\xFF\xC3\x00\x91"                 // add     sp, sp, #0x30
    "\xFF\x0F\x5F\xD6"                 // retab
    "\x00\x00\x00\x00\x00\x00\x00\x00" // [0xA0] dlopen address

    // [0xA8+] Payload path (filled in at runtime)
    "\x00\x00\x00\x00\x00\x00\x00\x00"
    "\x00\x00\x00\x00\x00\x00\x00\x00"
    "\x00\x00\x00\x00\x00\x00\x00\x00"
    "\x00\x00\x00\x00\x00\x00\x00\x00"
    "\x00\x00\x00\x00\x00\x00\x00\x00"
    "\x00\x00\x00\x00\x00\x00\x00\x00"
    "\x00\x00\x00\x00\x00\x00\x00\x00"
    "\x00\x00\x00\x00\x00\x00\x00\x00"
    "\x00\x00\x00\x00\x00\x00\x00\x00"
    "\x00\x00\x00\x00\x00\x00\x00\x00"
    "\x00\x00\x00\x00\x00\x00\x00\x00"
    "\x00\x00\x00\x00\x00\x00\x00\x00"
    "\x00\x00\x00\x00\x00\x00\x00\x00";

// Shellcode layout constants
#define OFFSET_PCFMT_ADDR   0x58
#define OFFSET_DLOPEN_ADDR  0xA0
#define OFFSET_PAYLOAD_PATH 0xA8
#define MAX_PATH_LEN        104  // Space reserved for path

static pid_t find_dock_pid(void) {
    NSArray *apps = [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.dock"];
    if (apps.count == 1) {
        NSRunningApplication *dock = apps[0];
        if ([dock isFinishedLaunching]) {
            return [dock processIdentifier];
        }
    }
    return 0;
}

static BOOL load_thread_convert(void) {
    void *handle = dlopen("/usr/lib/system/libsystem_kernel.dylib", RTLD_GLOBAL | RTLD_LAZY);
    if (!handle) return NO;

    _thread_convert_thread_state = dlsym(handle, "thread_convert_thread_state");
    dlclose(handle);

    return _thread_convert_thread_state != NULL;
}

// Config file path (must match payload.m)
#define CONFIG_PATH "/private/var/tmp/instantspaces.conf"

static BOOL write_config(const char *mode, const char *features) {
    FILE *f = fopen(CONFIG_PATH, "w");
    if (!f) {
        fprintf(stderr, "error: cannot write config file: %s\n", CONFIG_PATH);
        return NO;
    }
    fprintf(f, "mode=%s\n", mode);
    fprintf(f, "features=%s\n", features);
    fclose(f);
    chmod(CONFIG_PATH, 0644);
    return YES;
}

static void print_usage(const char *prog) {
    fprintf(stderr, "Usage: %s [-m MODE] [-f FEATURES] [payload_path]\n", prog);
    fprintf(stderr, "Options:\n");
    fprintf(stderr, "  -m MODE      zero | min0125 (default: zero)\n");
    fprintf(stderr, "  -f FEATURES  all | spaces | minimize (default: all)\n");
    fprintf(stderr, "  payload_path Optional path to payload.dylib\n");
    fprintf(stderr, "               Default: %s\n", default_payload_path);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        // Parse arguments
        const char *payload_path = default_payload_path;
        const char *mode = "zero";
        const char *features = "all";

        int opt;
        while ((opt = getopt(argc, argv, "m:f:h")) != -1) {
            switch (opt) {
                case 'm': mode = optarg; break;
                case 'f': features = optarg; break;
                case 'h':
                    print_usage(argv[0]);
                    return 0;
                default:
                    print_usage(argv[0]);
                    return 1;
            }
        }

        // Remaining argument is payload path
        if (optind < argc) {
            payload_path = argv[optind];
        }

        // Validate path length
        if (strlen(payload_path) >= MAX_PATH_LEN) {
            fprintf(stderr, "error: payload path too long (max %d chars)\n", MAX_PATH_LEN - 1);
            return 1;
        }

        // Check payload exists
        if (access(payload_path, R_OK) != 0) {
            fprintf(stderr, "error: cannot access payload: %s\n", payload_path);
            return 1;
        }

        // Write config file for payload to read
        if (!write_config(mode, features)) {
            return 1;
        }

        fprintf(stderr, "Injecting (mode=%s, features=%s)\n", mode, features);

        // Find Dock
        pid_t pid = find_dock_pid();
        if (!pid) {
            fprintf(stderr, "error: Dock.app not running or not ready\n");
            return 1;
        }
        fprintf(stderr, "Dock pid: %d\n", pid);

        // Get task port (requires SIP disabled or proper entitlements)
        mach_port_t task = 0;
        kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
        if (kr != KERN_SUCCESS) {
            fprintf(stderr, "error: task_for_pid failed: %s\n", mach_error_string(kr));
            fprintf(stderr, "hint: ensure SIP is disabled (csrutil disable)\n");
            return 1;
        }

        // Load private API for thread state conversion
        if (!load_thread_convert()) {
            fprintf(stderr, "error: failed to load thread_convert_thread_state\n");
            return 1;
        }

        // Allocate stack in target process
        vm_size_t stack_size = 16 * 1024;
        mach_vm_address_t stack = 0;
        kr = mach_vm_allocate(task, &stack, stack_size, VM_FLAGS_ANYWHERE);
        if (kr != KERN_SUCCESS) {
            fprintf(stderr, "error: failed to allocate stack: %s\n", mach_error_string(kr));
            return 1;
        }

        // Write dummy return address to stack
        uint64_t dummy_ret = 0x00000000CAFEBABE;
        kr = mach_vm_write(task, stack, (vm_address_t)&dummy_ret, sizeof(uint64_t));
        if (kr != KERN_SUCCESS) {
            fprintf(stderr, "error: failed to write stack: %s\n", mach_error_string(kr));
            return 1;
        }

        kr = vm_protect(task, stack, stack_size, 1, VM_PROT_READ | VM_PROT_WRITE);
        if (kr != KERN_SUCCESS) {
            fprintf(stderr, "error: failed to protect stack: %s\n", mach_error_string(kr));
            return 1;
        }

        // Allocate code segment in target process
        mach_vm_address_t code = 0;
        kr = mach_vm_allocate(task, &code, sizeof(shellcode), VM_FLAGS_ANYWHERE);
        if (kr != KERN_SUCCESS) {
            fprintf(stderr, "error: failed to allocate code: %s\n", mach_error_string(kr));
            return 1;
        }

        // Patch shellcode with function addresses and payload path
        uint64_t pcfmt_addr = (uint64_t)ptrauth_strip(
            dlsym(RTLD_DEFAULT, "pthread_create_from_mach_thread"),
            ptrauth_key_function_pointer
        );
        uint64_t dlopen_addr = (uint64_t)ptrauth_strip(
            dlsym(RTLD_DEFAULT, "dlopen"),
            ptrauth_key_function_pointer
        );

        memcpy(shellcode + OFFSET_PCFMT_ADDR, &pcfmt_addr, sizeof(uint64_t));
        memcpy(shellcode + OFFSET_DLOPEN_ADDR, &dlopen_addr, sizeof(uint64_t));
        memcpy(shellcode + OFFSET_PAYLOAD_PATH, payload_path, strlen(payload_path));

        // Write shellcode to target
        kr = mach_vm_write(task, code, (vm_address_t)shellcode, sizeof(shellcode));
        if (kr != KERN_SUCCESS) {
            fprintf(stderr, "error: failed to write shellcode: %s\n", mach_error_string(kr));
            return 1;
        }

        kr = vm_protect(task, code, sizeof(shellcode), 0, VM_PROT_EXECUTE | VM_PROT_READ);
        if (kr != KERN_SUCCESS) {
            fprintf(stderr, "error: failed to protect code: %s\n", mach_error_string(kr));
            return 1;
        }

        // Create remote thread
        thread_act_t thread = 0;
        arm_thread_state64_t state = {}, machine_state = {};
        thread_state_flavor_t flavor = ARM_THREAD_STATE64;
        mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
        mach_msg_type_number_t machine_count = ARM_THREAD_STATE64_COUNT;

        __darwin_arm_thread_state64_set_pc_fptr(
            state,
            ptrauth_sign_unauthenticated((void *)code, ptrauth_key_asia, 0)
        );
        __darwin_arm_thread_state64_set_sp(state, stack + (stack_size / 2));

        kr = thread_create(task, &thread);
        if (kr != KERN_SUCCESS) {
            fprintf(stderr, "error: failed to create thread: %s\n", mach_error_string(kr));
            return 1;
        }

        kr = _thread_convert_thread_state(
            thread, 2, flavor,
            (thread_state_t)&state, count,
            (thread_state_t)&machine_state, &machine_count
        );
        if (kr != KERN_SUCCESS) {
            fprintf(stderr, "error: failed to convert thread state: %s\n", mach_error_string(kr));
            thread_terminate(thread);
            return 1;
        }

        // macOS 14.4+ requires thread_create_running instead of thread_resume
        NSOperatingSystemVersion os = [[NSProcessInfo processInfo] operatingSystemVersion];
        if ((os.majorVersion == 14 && os.minorVersion >= 4) || os.majorVersion >= 15) {
            thread_terminate(thread);
            kr = thread_create_running(task, flavor, (thread_state_t)&machine_state, machine_count, &thread);
            if (kr != KERN_SUCCESS) {
                fprintf(stderr, "error: failed to spawn thread: %s\n", mach_error_string(kr));
                return 1;
            }
        } else {
            kr = thread_set_state(thread, flavor, (thread_state_t)&machine_state, machine_count);
            if (kr != KERN_SUCCESS) {
                fprintf(stderr, "error: failed to set thread state: %s\n", mach_error_string(kr));
                thread_terminate(thread);
                return 1;
            }

            kr = thread_resume(thread);
            if (kr != KERN_SUCCESS) {
                fprintf(stderr, "error: failed to resume thread: %s\n", mach_error_string(kr));
                thread_terminate(thread);
                return 1;
            }
        }

        // Wait for injection to complete (shellcode sets x0 to magic value)
        usleep(10000);

        int result = 1;
        for (int i = 0; i < 10; i++) {
            arm_thread_state64_t check_state = {};
            mach_msg_type_number_t check_count = ARM_THREAD_STATE64_COUNT;

            kr = thread_get_state(thread, flavor, (thread_state_t)&check_state, &check_count);
            if (kr != KERN_SUCCESS) {
                fprintf(stderr, "error: failed to get thread state: %s\n", mach_error_string(kr));
                break;
            }

            // Check for magic value indicating success
            if (check_state.__x[0] == 0x79616265) {
                fprintf(stderr, "Payload injected successfully\n");
                result = 0;
                break;
            }

            usleep(20000);
        }

        thread_terminate(thread);

        if (result != 0) {
            fprintf(stderr, "error: injection timed out\n");
        }

        return result;
    }
}
