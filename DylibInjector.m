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
#import "utils/sandbox.h"
#import "TaskRop/RemoteCall.h"

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

#pragma mark - Injection

- (BOOL)injectDylib:(NSString *)dylibPath
            intoApp:(NSDictionary *)appInfo
              error:(NSError **)error {

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *appPath = appInfo[@"path"];
    NSString *bundleID = appInfo[@"bundleID"];
    NSString *appName = appInfo[@"name"];

    NSLog(@"[Injector] Starting injection into %@ (%@)", appName, bundleID);

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

    // Step 3: Get actual app path if empty
    if (!appPath || appPath.length == 0) {
        appPath = [self getAppPathForBundleID:bundleID];
        if (!appPath) {
            *error = [NSError errorWithDomain:@"InjectorError" code:3
                                     userInfo:@{NSLocalizedDescriptionKey: @"Cannot find app path"}];
            return NO;
        }
    }

    NSLog(@"[Injector] App path: %@", appPath);

    // Step 4: Copy dylib into app bundle
    NSString *dylibName = [dylibPath lastPathComponent];
    NSString *destDylibPath = [appPath stringByAppendingPathComponent:dylibName];

    NSLog(@"[Injector] Copying dylib to %@", destDylibPath);

    // Remove existing file first
    [fm removeItemAtPath:destDylibPath error:nil];

    // Try normal copy first
    NSError *copyError = nil;
    BOOL copySuccess = [fm copyItemAtPath:dylibPath toPath:destDylibPath error:&copyError];

    if (!copySuccess) {
        NSLog(@"[Injector] Normal copy failed: %@, trying kernel-level copy...", copyError.localizedDescription);

        // Fallback: Read file data and write using low-level APIs
        NSData *dylibData = [NSData dataWithContentsOfFile:dylibPath];
        if (!dylibData) {
            *error = [NSError errorWithDomain:@"InjectorError" code:5
                                     userInfo:@{NSLocalizedDescriptionKey: @"Cannot read dylib file"}];
            return NO;
        }

        // Try writing with different method - create file first
        int fd = open(destDylibPath.UTF8String, O_WRONLY | O_CREAT | O_TRUNC, 0755);
        if (fd == -1) {
            NSLog(@"[Injector] open() failed: %s", strerror(errno));

            // Last resort: try writing to app's Documents first, then copy
            NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:dylibName];
            if (![dylibData writeToFile:tempPath atomically:YES]) {
                *error = [NSError errorWithDomain:@"InjectorError" code:6
                                         userInfo:@{NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:@"Cannot write to app bundle: %@", copyError.localizedDescription]}];
                return NO;
            }

            // Now try copy from temp
            if (![fm copyItemAtPath:tempPath toPath:destDylibPath error:&copyError]) {
                [fm removeItemAtPath:tempPath error:nil];
                *error = [NSError errorWithDomain:@"InjectorError" code:7
                                         userInfo:@{NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:@"Cannot copy to app bundle. Need more sandbox permissions. Error: %@", copyError.localizedDescription]}];
                return NO;
            }
            [fm removeItemAtPath:tempPath error:nil];
        } else {
            ssize_t written = write(fd, dylibData.bytes, dylibData.length);
            close(fd);

            if (written != (ssize_t)dylibData.length) {
                NSLog(@"[Injector] write() incomplete: %zd/%lu", written, (unsigned long)dylibData.length);
                *error = [NSError errorWithDomain:@"InjectorError" code:8
                                         userInfo:@{NSLocalizedDescriptionKey: @"Failed to write dylib data"}];
                return NO;
            }
            NSLog(@"[Injector] Kernel-level write succeeded");
        }
    }

    // Verify file was copied
    if (![fm fileExistsAtPath:destDylibPath]) {
        *error = [NSError errorWithDomain:@"InjectorError" code:9
                                 userInfo:@{NSLocalizedDescriptionKey: @"Dylib copy verification failed"}];
        return NO;
    }

    NSLog(@"[Injector] Dylib copied successfully");

    // Step 5: Patch main binary
    NSString *infoPlistPath = [appPath stringByAppendingPathComponent:@"Info.plist"];
    NSDictionary *infoPlist = [NSDictionary dictionaryWithContentsOfFile:infoPlistPath];
    NSString *executableName = infoPlist[@"CFBundleExecutable"];

    if (!executableName) {
        *error = [NSError errorWithDomain:@"InjectorError" code:4
                                 userInfo:@{NSLocalizedDescriptionKey: @"Cannot find CFBundleExecutable"}];
        return NO;
    }

    NSString *binaryPath = [appPath stringByAppendingPathComponent:executableName];

    NSLog(@"[Injector] Patching binary: %@", executableName);

    NSString *loadPath = [@"@executable_path/" stringByAppendingString:dylibName];
    if (![self patchBinary:binaryPath toLoadDylib:loadPath error:error]) {
        return NO;
    }

    // Step 6: Re-sign binary and dylib (using ldid)
    NSLog(@"[Injector] Re-signing...");
    [self signFile:destDylibPath];
    [self signFile:binaryPath];

    // Step 7: Touch app to invalidate cache
    NSLog(@"[Injector] Invalidating app cache...");
    [self touchAppBundle:appPath];

    NSLog(@"[Injector] Injection completed successfully!");
    NSLog(@"[Injector] Restart the app to load dylib");

    return YES;
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

- (void)touchAppBundle:(NSString *)appPath {
    // Touch Info.plist to invalidate cache
    NSString *infoPlist = [appPath stringByAppendingPathComponent:@"Info.plist"];
    NSFileManager *fm = [NSFileManager defaultManager];

    NSDictionary *attrs = @{NSFileModificationDate: [NSDate date]};
    [fm setAttributes:attrs ofItemAtPath:infoPlist error:nil];
    [fm setAttributes:attrs ofItemAtPath:appPath error:nil];
}

#pragma mark - Mach-O Patching

- (BOOL)patchBinary:(NSString *)binaryPath
      toLoadDylib:(NSString *)dylibName
              error:(NSError **)error {

    NSData *binaryData = [NSData dataWithContentsOfFile:binaryPath];
    if (!binaryData) {
        *error = [NSError errorWithDomain:@"InjectorError" code:10
                                 userInfo:@{NSLocalizedDescriptionKey: @"Cannot read binary"}];
        return NO;
    }

    NSMutableData *mutableData = [binaryData mutableCopy];
    const uint8_t *bytes = mutableData.bytes;
    uint32_t magic = *(uint32_t *)bytes;

    BOOL success = NO;

    if (magic == FAT_MAGIC || magic == FAT_CIGAM) {
        success = [self patchFatBinary:mutableData dylibName:dylibName error:error];
    } else if (magic == MH_MAGIC_64 || magic == MH_CIGAM_64) {
        success = [self patchMachO64:mutableData offset:0 dylibName:dylibName error:error];
    } else if (magic == MH_MAGIC || magic == MH_CIGAM) {
        success = [self patchMachO32:mutableData offset:0 dylibName:dylibName error:error];
    } else {
        *error = [NSError errorWithDomain:@"InjectorError" code:11
                                 userInfo:@{NSLocalizedDescriptionKey: @"Unsupported binary format"}];
        return NO;
    }

    if (success) {
        [mutableData writeToFile:binaryPath atomically:YES];
    }

    return success;
}

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
