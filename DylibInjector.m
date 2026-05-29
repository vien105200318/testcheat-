// DylibInjector.m - Kernel-based injection using Cyanide exploit
#import "DylibInjector.h"
#import <mach-o/loader.h>
#import <mach-o/fat.h>
#import <sys/stat.h>
#import <spawn.h>
#import <sys/wait.h>
#import <dlfcn.h>
#import <sys/utsname.h>
#import <errno.h>

// Kernel exploit
#import "kexploit/kexploit_opa334.h"
#import "kexploit/krw.h"
#import "kexploit/kutils.h"
#import "kexploit/offsets.h"
#import "kexploit/vnode.h"
#import "kexploit/xpaci.h"
#import "utils/sandbox.h"
#import "utils/file.h"
#import "TaskRop/RemoteCall.h"
#import "research/amfi_research.h"

// Code Signing Flags (from XNU bsd/sys/codesign.h)
#define CS_VALID            0x00000001  // dynamically valid
#define CS_ADHOC            0x00000002  // ad hoc signed
#define CS_GET_TASK_ALLOW   0x00000004  // has get-task-allow entitlement
#define CS_INSTALLER        0x00000008  // has installer entitlement
#define CS_FORCED_LV        0x00000010  // Library Validation required by Hardened Runtime
#define CS_INVALID_ALLOWED  0x00000020  // allow invalid pages (for debugging)
#define CS_HARD             0x00000100  // don't load invalid pages
#define CS_KILL             0x00000200  // kill process if invalid pages
#define CS_CHECK_EXPIRATION 0x00000400
#define CS_RESTRICT         0x00000800  // restrict VM access
#define CS_ENFORCEMENT      0x00001000  // require enforcement
#define CS_REQUIRE_LV       0x00002000  // require library validation
#define CS_ENTITLEMENTS_VALIDATED 0x00004000
#define CS_RUNTIME          0x00010000  // Hardened Runtime
#define CS_DEBUGGED         0x10000000  // process is being debugged
#define CS_PLATFORM_BINARY  0x04000000  // is platform binary
#define CS_PLATFORM_PATH    0x08000000  // platform path

// Device support check - same as Cyanide
static NSComparisonResult injector_compare_system_version(NSString *version) {
    return [UIDevice.currentDevice.systemVersion compare:version options:NSNumericSearch];
}

static BOOL injector_device_supported(void) {
    // iOS 17.0 - 18.7.1
    BOOL ios17to18 =
        injector_compare_system_version(@"17.0") != NSOrderedAscending &&
        injector_compare_system_version(@"18.7.1") != NSOrderedDescending;

    // iOS 26.0 - 26.0.1
    BOOL ios26 =
        injector_compare_system_version(@"26.0") != NSOrderedAscending &&
        injector_compare_system_version(@"26.0.1") != NSOrderedDescending;

    return ios17to18 || ios26;
}

static NSString *injector_unsupported_message(void) {
    NSString *version = UIDevice.currentDevice.systemVersion ?: @"unknown";
    return [NSString stringWithFormat:@"Không hỗ trợ iOS %@. Yêu cầu: iOS/iPadOS 17.0-18.7.1 hoặc 26.0-26.0.1.", version];
}

static void injector_log_device_info(void) {
    struct utsname u = {0};
    const char *machine = "unknown";
    if (uname(&u) == 0 && u.machine[0]) machine = u.machine;

    NSString *version = UIDevice.currentDevice.systemVersion ?: @"unknown";
    NSLog(@"[Injector] Device: %s, iOS %@", machine, version);
    NSLog(@"[Injector] Supported: %@", injector_device_supported() ? @"YES" : @"NO");
}

// Private API
@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (BOOL)installApplication:(NSURL *)appURL withOptions:(NSDictionary *)options error:(NSError **)error;
- (BOOL)uninstallApplication:(NSString *)bundleID withOptions:(NSDictionary *)options error:(NSError **)error;
- (BOOL)openApplicationWithBundleID:(NSString *)bundleID;
@end

@interface LSApplicationProxy : NSObject
+ (instancetype)applicationProxyForIdentifier:(NSString *)bundleID;
@property (nonatomic, readonly) NSURL *bundleURL;
@property (nonatomic, readonly) NSURL *dataContainerURL;
@end

@implementation DylibInjector {
    BOOL _exploitReady;
    BOOL _sandboxEscaped;
    RemoteCallSession *_springboardSession;
}

+ (instancetype)sharedInstance {
    static DylibInjector *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[DylibInjector alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _exploitReady = NO;
        _sandboxEscaped = NO;
    }
    return self;
}

#pragma mark - Kernel Exploit

- (BOOL)runExploit:(NSError **)error {
    // Log device info
    injector_log_device_info();

    // Check device support FIRST - same as Cyanide
    if (!injector_device_supported()) {
        NSString *msg = injector_unsupported_message();
        NSLog(@"[Injector] %@", msg);
        if (error) {
            *error = [NSError errorWithDomain:@"InjectorError" code:-1
                                     userInfo:@{NSLocalizedDescriptionKey: msg}];
        }
        return NO;
    }

    // Check if already ready AND KRW is still valid
    if (_exploitReady) {
        if (kexploit_krw_ready()) {
            NSLog(@"[Injector] Reusing live KRW session");
            return YES;
        }
        // KRW is stale, need to reset and re-run
        NSLog(@"[Injector] Cached KRW is stale, resetting state...");
        _exploitReady = NO;
        _sandboxEscaped = NO;
        kutils_reset_self_cache();
    }

    NSLog(@"[Injector] Running kernel exploit (recovery first, then fresh if needed)...");

    int ret = kexploit_opa334();
    if (ret != 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"InjectorError" code:ret
                                     userInfo:@{NSLocalizedDescriptionKey: @"Kernel exploit failed"}];
        }
        NSLog(@"[Injector] Exploit failed: %d", ret);
        return NO;
    }

    // Validate KRW is working after exploit
    if (!kexploit_krw_ready()) {
        NSLog(@"[Injector] Warning: KRW validation failed after exploit");
    }

    _exploitReady = YES;
    NSLog(@"[Injector] Exploit successful! kernel_base=0x%llx slide=0x%llx", g_kernel_base, g_kernel_slide);
    return YES;
}

- (BOOL)escapeSandbox:(NSError **)error {
    if (_sandboxEscaped) {
        NSLog(@"[Injector] Sandbox already escaped");
        return YES;
    }

    if (!_exploitReady) {
        *error = [NSError errorWithDomain:@"InjectorError" code:1
                                 userInfo:@{NSLocalizedDescriptionKey: @"Exploit not ready"}];
        return NO;
    }

    NSLog(@"[Injector] Escaping sandbox...");

    // Use patch_sandbox_ext only - this works for listing apps
    int ret = patch_sandbox_ext();
    if (ret != 0) {
        NSLog(@"[Injector] patch_sandbox_ext failed: %d", ret);
        *error = [NSError errorWithDomain:@"InjectorError" code:ret
                                 userInfo:@{NSLocalizedDescriptionKey: @"Sandbox escape failed"}];
        return NO;
    }

    NSLog(@"[Injector] patch_sandbox_ext succeeded");
    _sandboxEscaped = YES;
    NSLog(@"[Injector] Sandbox escaped successfully!");
    return YES;
}

- (BOOL)initSpringBoardSession:(NSError **)error {
    if (_springboardSession) {
        NSLog(@"[Injector] SpringBoard session already active");
        return YES;
    }

    if (!_exploitReady) {
        *error = [NSError errorWithDomain:@"InjectorError" code:1
                                 userInfo:@{NSLocalizedDescriptionKey: @"Exploit not ready"}];
        return NO;
    }

    NSLog(@"[Injector] Initializing SpringBoard RemoteCall session...");

    _springboardSession = [[RemoteCallSession alloc] initWithProcess:@"SpringBoard"
                                                    useMigFilterBypass:YES
                                               firstExceptionTimeoutMS:3000];

    if (!_springboardSession || ![_springboardSession hasLocalState]) {
        *error = [NSError errorWithDomain:@"InjectorError" code:2
                                 userInfo:@{NSLocalizedDescriptionKey: @"Failed to initialize SpringBoard session"}];
        return NO;
    }

    NSLog(@"[Injector] SpringBoard session ready!");
    return YES;
}

#pragma mark - AMFI Bypass

// Bypass AMFI code signing for target process to allow loading unsigned dylibs
- (BOOL)bypassAMFIForProcess:(pid_t)pid {
    NSLog(@"[Injector] Bypassing AMFI for PID %d...", pid);

    // Step 1: Find process
    uint64_t proc = proc_find(pid);
    if (!proc || !is_kaddr_valid(proc)) {
        NSLog(@"[Injector] Cannot find process %d", pid);
        return NO;
    }
    NSLog(@"[Injector] Found proc at 0x%llx", proc);

    // Step 2: Get credential label
    uint64_t label = proc_get_cred_label(proc);
    if (!label || !is_kaddr_valid(label)) {
        NSLog(@"[Injector] Cannot get credential label");
        return NO;
    }
    NSLog(@"[Injector] Credential label at 0x%llx", label);

    // Step 3: Get AMFI slot (OSEntitlements*)
    uint64_t amfi_slot = amfi_cslot_get(label);
    if (!amfi_slot || !is_kaddr_valid(amfi_slot)) {
        NSLog(@"[Injector] Cannot get AMFI slot");
        return NO;
    }
    NSLog(@"[Injector] AMFI slot (OSEntitlements) at 0x%llx", amfi_slot);

    // Step 4: Read OSEntitlementsState pointer (offset +0x10)
    uint64_t state = kread64(amfi_slot + 0x10);
    state = xpaci(state);
    if (!state || !is_kaddr_valid(state)) {
        NSLog(@"[Injector] Cannot get OSEntitlementsState");
        return NO;
    }
    NSLog(@"[Injector] OSEntitlementsState at 0x%llx", state);

    // Step 5: Read current is_cs_platform value (offset +0x4A)
    uint8_t current_platform = kread8(state + 0x4A);
    NSLog(@"[Injector] Current is_cs_platform = %d", current_platform);

    // Step 6: Set is_cs_platform = 1 to bypass code signing checks
    if (current_platform != 1) {
        kwrite8(state + 0x4A, 1);

        // Verify write succeeded
        uint8_t new_platform = kread8(state + 0x4A);
        if (new_platform != 1) {
            NSLog(@"[Injector] Failed to patch is_cs_platform");
            return NO;
        }
        NSLog(@"[Injector] Patched is_cs_platform: %d -> %d", current_platform, new_platform);
    } else {
        NSLog(@"[Injector] Process already marked as platform binary");
    }

    // Also set valid flag (offset +0x48)
    uint8_t valid = kread8(state + 0x48);
    if (valid != 1) {
        kwrite8(state + 0x48, 1);
        NSLog(@"[Injector] Set valid flag to 1");
    }

    NSLog(@"[Injector] AMFI bypass successful for PID %d!", pid);
    return YES;
}

#pragma mark - Runtime Injection (dlopen approach - no kernel panic)

- (BOOL)injectDylib:(NSString *)dylibPath
            intoApp:(NSDictionary *)appInfo
              error:(NSError **)error {

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *bundleID = appInfo[@"bundleID"];
    NSString *appName = appInfo[@"name"];

    NSLog(@"[Injector] Starting RUNTIME injection into %@ (%@)", appName, bundleID);

    // Step 1: Run exploit if not ready
    if (!_exploitReady) {
        if (![self runExploit:error]) {
            return NO;
        }
    }

    // Step 2: Escape sandbox
    if (!_sandboxEscaped) {
        if (![self escapeSandbox:error]) {
            return NO;
        }
    }

    // Step 3: Copy dylib to app's Documents (accessible by target app)
    NSString *appDataPath = [self getAppDataPathForBundleID:bundleID];
    if (!appDataPath) {
        // Fallback: use shared container
        appDataPath = @"/var/mobile/Library/Caches";
    }

    NSString *dylibName = [dylibPath lastPathComponent];
    NSString *targetDylibPath = [appDataPath stringByAppendingPathComponent:dylibName];

    // Also try Documents subfolder
    NSString *docsPath = [appDataPath stringByAppendingPathComponent:@"Documents"];
    if ([fm fileExistsAtPath:docsPath]) {
        targetDylibPath = [docsPath stringByAppendingPathComponent:dylibName];
    }

    [fm removeItemAtPath:targetDylibPath error:nil];
    NSError *copyError = nil;
    if (![fm copyItemAtPath:dylibPath toPath:targetDylibPath error:&copyError]) {
        // Try alternative location
        NSString *tmpPath = [NSString stringWithFormat:@"/var/tmp/%@", dylibName];
        [fm removeItemAtPath:tmpPath error:nil];
        if (![fm copyItemAtPath:dylibPath toPath:tmpPath error:&copyError]) {
            *error = [NSError errorWithDomain:@"InjectorError" code:5
                                     userInfo:@{NSLocalizedDescriptionKey:
                [NSString stringWithFormat:@"Cannot copy dylib: %@", copyError.localizedDescription]}];
            return NO;
        }
        targetDylibPath = tmpPath;
    }
    NSLog(@"[Injector] Dylib copied to: %@", targetDylibPath);

    // Make dylib executable
    chmod(targetDylibPath.UTF8String, 0755);

    // Step 4: Launch the app if not running
    NSLog(@"[Injector] Launching app %@...", bundleID);
    Class LSWorkspace = NSClassFromString(@"LSApplicationWorkspace");
    if (LSWorkspace) {
        [[LSWorkspace defaultWorkspace] openApplicationWithBundleID:bundleID];
    }

    // Wait for app to start
    usleep(1500000); // 1.5 seconds

    // Step 5: Find the running process
    NSString *executableName = [self getExecutableNameForBundleID:bundleID];
    if (!executableName) {
        *error = [NSError errorWithDomain:@"InjectorError" code:6
                                 userInfo:@{NSLocalizedDescriptionKey: @"Cannot find executable name"}];
        return NO;
    }
    NSLog(@"[Injector] Looking for process: %@", executableName);

    // Step 6: Create RemoteCallSession to target app
    RemoteCallSession *session = [[RemoteCallSession alloc] initWithProcess:executableName
                                                          useMigFilterBypass:YES
                                                     firstExceptionTimeoutMS:5000];

    if (!session || ![session hasLocalState]) {
        // Retry with bundle ID as process name
        session = [[RemoteCallSession alloc] initWithProcess:bundleID
                                            useMigFilterBypass:YES
                                       firstExceptionTimeoutMS:5000];

        if (!session || ![session hasLocalState]) {
            *error = [NSError errorWithDomain:@"InjectorError" code:7
                                     userInfo:@{NSLocalizedDescriptionKey:
                [NSString stringWithFormat:@"Cannot connect to %@. Make sure app is running.", appName]}];
            return NO;
        }
    }
    NSLog(@"[Injector] Connected to process PID=%d", session.pid);

    // Step 7: Bypass AMFI to allow loading unsigned dylibs
    if (![self bypassAMFIForProcess:session.pid]) {
        NSLog(@"[Injector] Warning: AMFI bypass may have failed, dlopen might not work");
        // Continue anyway - some apps might already have the right entitlements
    }

    // Step 8: Write dylib path to remote memory
    uint64_t trojanMem = session.trojanMem;
    if (!trojanMem) {
        [session destroyRemoteCall];
        *error = [NSError errorWithDomain:@"InjectorError" code:8
                                 userInfo:@{NSLocalizedDescriptionKey: @"No trojan memory available"}];
        return NO;
    }

    // Use offset in trojan memory for the path string
    uint64_t pathAddr = trojanMem + 0x1000; // Safe offset
    if (![session remoteWriteString:pathAddr value:targetDylibPath.UTF8String]) {
        [session destroyRemoteCall];
        *error = [NSError errorWithDomain:@"InjectorError" code:9
                                 userInfo:@{NSLocalizedDescriptionKey: @"Cannot write dylib path to remote memory"}];
        return NO;
    }
    NSLog(@"[Injector] Wrote dylib path at 0x%llx", pathAddr);

    // Step 9: Call dlopen in target process
    // dlopen(const char *path, int mode) - RTLD_NOW = 0x2
    NSLog(@"[Injector] Calling dlopen(\"%@\", RTLD_NOW)...", targetDylibPath);

    uint64_t handle = [session doRemoteCallStableWithTimeout:10000
                                               functionName:"dlopen"
                                                         x0:pathAddr
                                                         x1:0x2 // RTLD_NOW
                                                         x2:0
                                                         x3:0
                                                         x4:0
                                                         x5:0
                                                         x6:0
                                                         x7:0];

    if (handle == 0) {
        // dlopen failed, try to get error
        NSLog(@"[Injector] dlopen returned NULL, calling dlerror...");

        uint64_t errAddr = [session doRemoteCallStableWithTimeout:5000
                                                    functionName:"dlerror"
                                                              x0:0 x1:0 x2:0 x3:0 x4:0 x5:0 x6:0 x7:0];

        NSString *errMsg = @"dlopen failed (unknown error)";
        if (errAddr != 0) {
            char errBuf[256] = {0};
            if ([session remoteRead:errAddr to:errBuf size:255]) {
                errMsg = [NSString stringWithFormat:@"dlopen failed: %s", errBuf];
            }
        }

        [session destroyRemoteCall];
        *error = [NSError errorWithDomain:@"InjectorError" code:10
                                 userInfo:@{NSLocalizedDescriptionKey: errMsg}];
        return NO;
    }

    NSLog(@"[Injector] ========================================");
    NSLog(@"[Injector] INJECTION SUCCESSFUL!");
    NSLog(@"[Injector] dlopen returned handle: 0x%llx", handle);
    NSLog(@"[Injector] Dylib loaded: %@", targetDylibPath);
    NSLog(@"[Injector] Process: %@ (PID %d)", executableName, session.pid);
    NSLog(@"[Injector] ========================================");

    // Destroy session immediately after successful injection
    // The dylib is already loaded into target process memory
    // Keeping session alive causes crash when injector app goes to background
    [session destroyRemoteCall];
    NSLog(@"[Injector] Session cleaned up - you can now close this app");

    return YES;
}

- (NSString *)getAppDataPathForBundleID:(NSString *)bundleID {
    Class LSProxy = NSClassFromString(@"LSApplicationProxy");
    if (!LSProxy) return nil;

    id proxy = [LSProxy applicationProxyForIdentifier:bundleID];
    if (proxy) {
        NSURL *url = [proxy dataContainerURL];
        return url.path;
    }
    return nil;
}

- (NSString *)getExecutableNameForBundleID:(NSString *)bundleID {
    NSString *appPath = [self getAppPathForBundleID:bundleID];
    if (!appPath) return nil;

    NSString *infoPlistPath = [appPath stringByAppendingPathComponent:@"Info.plist"];
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPlistPath];
    return info[@"CFBundleExecutable"];
}

// Patch binary data (in-memory) to add LC_LOAD_DYLIB
- (BOOL)patchBinaryData:(NSMutableData *)mutableData
          toLoadDylib:(NSString *)dylibPath
                error:(NSError **)error {

    const uint8_t *bytes = mutableData.bytes;
    uint32_t magic = *(uint32_t *)bytes;

    BOOL success = NO;

    if (magic == FAT_MAGIC || magic == FAT_CIGAM) {
        success = [self patchFatBinary:mutableData dylibName:dylibPath error:error];
    } else if (magic == MH_MAGIC_64 || magic == MH_CIGAM_64) {
        success = [self patchMachO64:mutableData offset:0 dylibName:dylibPath error:error];
    } else if (magic == MH_MAGIC || magic == MH_CIGAM) {
        success = [self patchMachO32:mutableData offset:0 dylibName:dylibPath error:error];
    } else {
        *error = [NSError errorWithDomain:@"InjectorError" code:11
                                 userInfo:@{NSLocalizedDescriptionKey: @"Unsupported binary format"}];
        return NO;
    }

    return success;
}

- (NSString *)getAppPathForBundleID:(NSString *)bundleID {
    Class LSProxy = NSClassFromString(@"LSApplicationProxy");
    if (!LSProxy) return nil;

    id proxy = [LSProxy applicationProxyForIdentifier:bundleID];
    if (proxy) {
        NSURL *url = [proxy bundleURL];
        return url.path;
    }
    return nil;
}

#pragma mark - Mach-O Patching

- (BOOL)patchFatBinary:(NSMutableData *)data dylibName:(NSString *)dylibName error:(NSError **)error {
    const uint8_t *bytes = data.bytes;
    struct fat_header *fatHeader = (struct fat_header *)bytes;

    uint32_t nfat = OSSwapBigToHostInt32(fatHeader->nfat_arch);
    struct fat_arch *archs = (struct fat_arch *)(bytes + sizeof(struct fat_header));

    NSLog(@"[Injector] FAT binary with %d architectures", nfat);

    for (uint32_t i = 0; i < nfat; i++) {
        uint32_t offset = OSSwapBigToHostInt32(archs[i].offset);
        uint32_t magic = *(uint32_t *)(bytes + offset);

        if (magic == MH_MAGIC_64 || magic == MH_CIGAM_64) {
            if (![self patchMachO64:data offset:offset dylibName:dylibName error:error]) {
                return NO;
            }
        } else if (magic == MH_MAGIC || magic == MH_CIGAM) {
            if (![self patchMachO32:data offset:offset dylibName:dylibName error:error]) {
                return NO;
            }
        }
    }

    return YES;
}

- (BOOL)patchMachO64:(NSMutableData *)data offset:(uint32_t)offset dylibName:(NSString *)dylibName error:(NSError **)error {
    uint8_t *bytes = (uint8_t *)data.mutableBytes + offset;
    struct mach_header_64 *header = (struct mach_header_64 *)bytes;

    // Check if already has this dylib
    uint32_t cmdOffset = sizeof(struct mach_header_64);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        struct load_command *cmd = (struct load_command *)(bytes + cmdOffset);

        if (cmd->cmd == LC_LOAD_DYLIB || cmd->cmd == LC_LOAD_WEAK_DYLIB) {
            struct dylib_command *dylibCmd = (struct dylib_command *)cmd;
            char *name = (char *)cmd + dylibCmd->dylib.name.offset;
            if (strcmp(name, dylibName.UTF8String) == 0) {
                NSLog(@"[Injector] Dylib already loaded, skipping");
                return YES;
            }
        }
        cmdOffset += cmd->cmdsize;
    }

    // Create new LC_LOAD_DYLIB command
    uint32_t nameLen = (uint32_t)dylibName.length + 1;
    uint32_t cmdSize = sizeof(struct dylib_command) + nameLen;
    cmdSize = (cmdSize + 7) & ~7;

    // Check if there's space in header
    uint32_t headerEnd = sizeof(struct mach_header_64) + header->sizeofcmds;
    uint32_t firstSectionOffset = [self findFirstSectionOffset64:bytes];

    if (headerEnd + cmdSize > firstSectionOffset) {
        *error = [NSError errorWithDomain:@"InjectorError" code:12
                                 userInfo:@{NSLocalizedDescriptionKey: @"Not enough space in header"}];
        return NO;
    }

    // Write new command
    struct dylib_command newCmd = {0};
    newCmd.cmd = LC_LOAD_DYLIB;
    newCmd.cmdsize = cmdSize;
    newCmd.dylib.name.offset = sizeof(struct dylib_command);
    newCmd.dylib.timestamp = 2;
    newCmd.dylib.current_version = 0x10000;
    newCmd.dylib.compatibility_version = 0x10000;

    uint8_t *cmdPtr = bytes + sizeof(struct mach_header_64) + header->sizeofcmds;
    memcpy(cmdPtr, &newCmd, sizeof(struct dylib_command));
    memcpy(cmdPtr + sizeof(struct dylib_command), dylibName.UTF8String, nameLen);

    // Update header
    header->ncmds += 1;
    header->sizeofcmds += cmdSize;

    NSLog(@"[Injector] Added LC_LOAD_DYLIB for %@", dylibName);
    return YES;
}

- (BOOL)patchMachO32:(NSMutableData *)data offset:(uint32_t)offset dylibName:(NSString *)dylibName error:(NSError **)error {
    uint8_t *bytes = (uint8_t *)data.mutableBytes + offset;
    struct mach_header *header = (struct mach_header *)bytes;

    uint32_t cmdOffset = sizeof(struct mach_header);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        struct load_command *cmd = (struct load_command *)(bytes + cmdOffset);

        if (cmd->cmd == LC_LOAD_DYLIB || cmd->cmd == LC_LOAD_WEAK_DYLIB) {
            struct dylib_command *dylibCmd = (struct dylib_command *)cmd;
            char *name = (char *)cmd + dylibCmd->dylib.name.offset;
            if (strcmp(name, dylibName.UTF8String) == 0) {
                return YES;
            }
        }
        cmdOffset += cmd->cmdsize;
    }

    uint32_t nameLen = (uint32_t)dylibName.length + 1;
    uint32_t cmdSize = sizeof(struct dylib_command) + nameLen;
    cmdSize = (cmdSize + 3) & ~3;

    struct dylib_command newCmd = {0};
    newCmd.cmd = LC_LOAD_DYLIB;
    newCmd.cmdsize = cmdSize;
    newCmd.dylib.name.offset = sizeof(struct dylib_command);
    newCmd.dylib.timestamp = 2;
    newCmd.dylib.current_version = 0x10000;
    newCmd.dylib.compatibility_version = 0x10000;

    uint8_t *cmdPtr = bytes + sizeof(struct mach_header) + header->sizeofcmds;
    memcpy(cmdPtr, &newCmd, sizeof(struct dylib_command));
    memcpy(cmdPtr + sizeof(struct dylib_command), dylibName.UTF8String, nameLen);

    header->ncmds += 1;
    header->sizeofcmds += cmdSize;

    return YES;
}

- (uint32_t)findFirstSectionOffset64:(const uint8_t *)bytes {
    struct mach_header_64 *header = (struct mach_header_64 *)bytes;
    uint32_t cmdOffset = sizeof(struct mach_header_64);
    uint32_t firstOffset = UINT32_MAX;

    for (uint32_t i = 0; i < header->ncmds; i++) {
        struct load_command *cmd = (struct load_command *)(bytes + cmdOffset);

        if (cmd->cmd == LC_SEGMENT_64) {
            struct segment_command_64 *seg = (struct segment_command_64 *)cmd;
            struct section_64 *sections = (struct section_64 *)((uint8_t *)seg + sizeof(struct segment_command_64));

            for (uint32_t j = 0; j < seg->nsects; j++) {
                if (sections[j].offset > 0 && sections[j].offset < firstOffset) {
                    firstOffset = sections[j].offset;
                }
            }
        }
        cmdOffset += cmd->cmdsize;
    }

    return firstOffset;
}

#pragma mark - Signing

- (void)signFile:(NSString *)path {
    // Use ldid if available
    NSString *ldidPath = @"/usr/bin/ldid";
    if (![[NSFileManager defaultManager] fileExistsAtPath:ldidPath]) {
        ldidPath = @"/var/jb/usr/bin/ldid";
    }

    if ([[NSFileManager defaultManager] fileExistsAtPath:ldidPath]) {
        pid_t pid;
        const char *argv[] = {ldidPath.UTF8String, "-S", [path UTF8String], NULL};

        int status = posix_spawn(&pid, ldidPath.UTF8String, NULL, NULL, (char *const *)argv, NULL);
        if (status == 0) {
            waitpid(pid, &status, 0);
            NSLog(@"[Injector] Signed with ldid: %@", path);
        }
        return;
    }

    NSLog(@"[Injector] No ldid found, using adhoc sign");
}

#pragma mark - State

- (BOOL)isExploitReady {
    return _exploitReady;
}

- (BOOL)isSandboxEscaped {
    return _sandboxEscaped;
}

- (BOOL)isDeviceSupported {
    return injector_device_supported();
}

- (NSString *)deviceSupportMessage {
    if (injector_device_supported()) {
        return [NSString stringWithFormat:@"iOS %@ được hỗ trợ", UIDevice.currentDevice.systemVersion];
    }
    return injector_unsupported_message();
}

@end
