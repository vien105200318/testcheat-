// DylibInjector.m - Core injection logic
#import "DylibInjector.h"
#import <mach-o/loader.h>
#import <mach-o/fat.h>
#import <sys/stat.h>

// Private API
@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (BOOL)installApplication:(NSURL *)appURL withOptions:(NSDictionary *)options error:(NSError **)error;
- (BOOL)uninstallApplication:(NSString *)bundleID withOptions:(NSDictionary *)options error:(NSError **)error;
@end

@implementation DylibInjector

+ (instancetype)sharedInstance {
    static DylibInjector *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[DylibInjector alloc] init];
    });
    return instance;
}

- (BOOL)injectDylib:(NSString *)dylibPath
            intoApp:(NSDictionary *)appInfo
              error:(NSError **)error {

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *appPath = appInfo[@"path"];
    NSString *bundleID = appInfo[@"bundleID"];
    NSString *appName = appInfo[@"name"];

    NSLog(@"[Injector] Starting injection into %@ (%@)", appName, bundleID);

    // 1. Create temp directory
    NSString *tempDir = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
    NSString *tempAppPath = [tempDir stringByAppendingPathComponent:[appPath lastPathComponent]];

    if (![fm createDirectoryAtPath:tempDir withIntermediateDirectories:YES attributes:nil error:error]) {
        return NO;
    }

    // 2. Copy app to temp
    NSLog(@"[Injector] Copying app to temp...");
    if (![fm copyItemAtPath:appPath toPath:tempAppPath error:error]) {
        [fm removeItemAtPath:tempDir error:nil];
        return NO;
    }

    // 3. Copy dylib into app bundle
    NSString *dylibName = [dylibPath lastPathComponent];
    NSString *destDylibPath = [tempAppPath stringByAppendingPathComponent:dylibName];

    NSLog(@"[Injector] Copying dylib...");
    [fm removeItemAtPath:destDylibPath error:nil];
    if (![fm copyItemAtPath:dylibPath toPath:destDylibPath error:error]) {
        [fm removeItemAtPath:tempDir error:nil];
        return NO;
    }

    // 4. Find and patch main binary
    NSString *infoPlistPath = [tempAppPath stringByAppendingPathComponent:@"Info.plist"];
    NSDictionary *infoPlist = [NSDictionary dictionaryWithContentsOfFile:infoPlistPath];
    NSString *executableName = infoPlist[@"CFBundleExecutable"];

    if (!executableName) {
        *error = [NSError errorWithDomain:@"InjectorError" code:1
                                 userInfo:@{NSLocalizedDescriptionKey: @"Không tìm thấy CFBundleExecutable"}];
        [fm removeItemAtPath:tempDir error:nil];
        return NO;
    }

    NSString *binaryPath = [tempAppPath stringByAppendingPathComponent:executableName];

    NSLog(@"[Injector] Patching binary: %@", executableName);
    if (![self patchBinary:binaryPath toLoadDylib:[@"@executable_path/" stringByAppendingString:dylibName] error:error]) {
        [fm removeItemAtPath:tempDir error:nil];
        return NO;
    }

    // 5. Sign the dylib and binary (using ldid or codesign)
    NSLog(@"[Injector] Signing...");
    [self signFile:destDylibPath];
    [self signFile:binaryPath];

    // 6. Uninstall old app
    NSLog(@"[Injector] Uninstalling old app...");
    Class LSWorkspace = NSClassFromString(@"LSApplicationWorkspace");
    id workspace = [LSWorkspace defaultWorkspace];

    NSError *uninstallError;
    [workspace uninstallApplication:bundleID withOptions:nil error:&uninstallError];
    // Ignore uninstall error, may not be installed

    // 7. Install modified app
    NSLog(@"[Injector] Installing modified app...");
    NSURL *appURL = [NSURL fileURLWithPath:tempAppPath];

    NSDictionary *options = @{
        @"CFBundleIdentifier": bundleID,
        @"AllowInstallLocalProvisioned": @YES
    };

    BOOL installed = [workspace installApplication:appURL withOptions:options error:error];

    // Cleanup
    [fm removeItemAtPath:tempDir error:nil];

    if (installed) {
        NSLog(@"[Injector] Success!");
    } else {
        NSLog(@"[Injector] Install failed: %@", (*error).localizedDescription);
    }

    return installed;
}

#pragma mark - Mach-O Patching

- (BOOL)patchBinary:(NSString *)binaryPath
      toLoadDylib:(NSString *)dylibName
              error:(NSError **)error {

    NSData *binaryData = [NSData dataWithContentsOfFile:binaryPath];
    if (!binaryData) {
        *error = [NSError errorWithDomain:@"InjectorError" code:2
                                 userInfo:@{NSLocalizedDescriptionKey: @"Không đọc được binary"}];
        return NO;
    }

    NSMutableData *mutableData = [binaryData mutableCopy];
    const uint8_t *bytes = mutableData.bytes;
    uint32_t magic = *(uint32_t *)bytes;

    BOOL success = NO;

    if (magic == FAT_MAGIC || magic == FAT_CIGAM) {
        // FAT binary - patch all architectures
        success = [self patchFatBinary:mutableData dylibName:dylibName error:error];
    } else if (magic == MH_MAGIC_64 || magic == MH_CIGAM_64) {
        // 64-bit Mach-O
        success = [self patchMachO64:mutableData offset:0 dylibName:dylibName error:error];
    } else if (magic == MH_MAGIC || magic == MH_CIGAM) {
        // 32-bit Mach-O
        success = [self patchMachO32:mutableData offset:0 dylibName:dylibName error:error];
    } else {
        *error = [NSError errorWithDomain:@"InjectorError" code:3
                                 userInfo:@{NSLocalizedDescriptionKey: @"Định dạng binary không hỗ trợ"}];
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
    cmdSize = (cmdSize + 7) & ~7; // Align to 8 bytes

    // Check if there's space in header
    uint32_t headerEnd = sizeof(struct mach_header_64) + header->sizeofcmds;
    uint32_t firstSectionOffset = [self findFirstSectionOffset64:bytes];

    if (headerEnd + cmdSize > firstSectionOffset) {
        *error = [NSError errorWithDomain:@"InjectorError" code:4
                                 userInfo:@{NSLocalizedDescriptionKey: @"Không đủ chỗ trong header"}];
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

    // Similar to 64-bit but with mach_header instead of mach_header_64
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
    cmdSize = (cmdSize + 3) & ~3; // Align to 4 bytes

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
    // Try ldid first (if available via TrollStore)
    NSString *ldidPath = @"/usr/bin/ldid";
    if ([[NSFileManager defaultManager] fileExistsAtPath:ldidPath]) {
        NSTask *task = [[NSTask alloc] init];
        task.launchPath = ldidPath;
        task.arguments = @[@"-S", path];
        @try {
            [task launch];
            [task waitUntilExit];
            NSLog(@"[Injector] Signed with ldid: %@", path);
        } @catch (NSException *e) {
            NSLog(@"[Injector] ldid failed: %@", e);
        }
        return;
    }

    // Alternative: use codesign (requires entitlements)
    NSLog(@"[Injector] No ldid found, skipping signing");
}

@end
