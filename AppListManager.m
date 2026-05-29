// AppListManager.m - List installed apps on iOS
#import "AppListManager.h"
#import "LogTextView.h"
#import <objc/runtime.h>

// Private API declarations
@interface LSApplicationProxy : NSObject
@property (nonatomic, readonly) NSString *applicationIdentifier;
@property (nonatomic, readonly) NSString *localizedName;
@property (nonatomic, readonly) NSURL *bundleURL;
@property (nonatomic, readonly) NSString *bundleType;
@property (nonatomic, readonly) NSURL *dataContainerURL;
+ (instancetype)applicationProxyForIdentifier:(NSString *)identifier;
@end

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (NSArray *)allInstalledApplications;
- (NSArray *)allApplications;
- (BOOL)openApplicationWithBundleID:(NSString *)bundleID;
- (BOOL)installApplication:(NSURL *)appURL withOptions:(NSDictionary *)options error:(NSError **)error;
- (BOOL)uninstallApplication:(NSString *)bundleID withOptions:(NSDictionary *)options error:(NSError **)error;
@end

@implementation AppListManager

+ (instancetype)sharedManager {
    static AppListManager *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[AppListManager alloc] init];
    });
    return instance;
}

- (NSMutableArray *)getInstalledApps {
    NSMutableArray *apps = [NSMutableArray array];

    log_console("[AppList] Getting installed apps...");

    // Get workspace
    Class LSApplicationWorkspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    if (!LSApplicationWorkspaceClass) {
        log_console("[AppList] LSApplicationWorkspace not found, trying filesystem");
        return [self getAppsFromFileSystem];
    }

    id workspace = [LSApplicationWorkspaceClass defaultWorkspace];
    if (!workspace) {
        log_console("[AppList] Failed to get workspace, trying filesystem");
        return [self getAppsFromFileSystem];
    }

    log_console("[AppList] Using LSApplicationWorkspace API...");
    NSArray *allApps = [workspace allInstalledApplications];
    if (!allApps || allApps.count == 0) {
        log_console("[AppList] No apps from workspace, trying filesystem");
        return [self getAppsFromFileSystem];
    }

    log_console("[AppList] Processing %lu apps...", (unsigned long)allApps.count);

    for (id proxy in allApps) {
        @try {
            NSString *bundleID = [proxy applicationIdentifier];
            NSString *name = [proxy localizedName];
            NSURL *bundleURL = [proxy bundleURL];
            NSString *bundleType = [proxy bundleType];

            // Chỉ lấy app user (không lấy system app)
            if (!bundleID || !name || !bundleURL) continue;

            // Filter: chỉ lấy user apps
            NSString *path = bundleURL.path;
            if ([path containsString:@"/Applications/"] && ![path containsString:@"/var/"]) {
                continue; // Skip system apps
            }

            // Skip this app itself
            if ([bundleID isEqualToString:[[NSBundle mainBundle] bundleIdentifier]]) {
                continue;
            }

            // Get icon path (skip for speed)
            NSString *iconPath = nil; // [self getIconPathForApp:bundleURL.path];

            NSDictionary *appInfo = @{
                @"name": name ?: @"Unknown",
                @"bundleID": bundleID ?: @"",
                @"path": bundleURL.path ?: @"",
                @"bundleType": bundleType ?: @"User",
                @"iconPath": iconPath ?: @""
            };

            [apps addObject:appInfo];

        } @catch (NSException *e) {
            // Skip problematic apps
        }
    }

    // Sort by name
    [apps sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] compare:b[@"name"] options:NSCaseInsensitiveSearch];
    }];

    log_console("[AppList] Found %lu user apps", (unsigned long)apps.count);
    return apps;
}

- (NSString *)getIconPathForApp:(NSString *)appPath {
    // Try to find app icon
    NSArray *iconNames = @[@"AppIcon60x60@3x.png", @"AppIcon60x60@2x.png", @"AppIcon.png", @"Icon.png"];

    for (NSString *iconName in iconNames) {
        NSString *iconPath = [appPath stringByAppendingPathComponent:iconName];
        if ([[NSFileManager defaultManager] fileExistsAtPath:iconPath]) {
            return iconPath;
        }
    }

    // Try Info.plist for icon name
    NSString *infoPlistPath = [appPath stringByAppendingPathComponent:@"Info.plist"];
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPlistPath];

    NSArray *iconFiles = info[@"CFBundleIconFiles"];
    if (!iconFiles) {
        NSDictionary *icons = info[@"CFBundleIcons"][@"CFBundlePrimaryIcon"];
        iconFiles = icons[@"CFBundleIconFiles"];
    }

    if (iconFiles.count > 0) {
        for (NSString *name in iconFiles) {
            NSString *iconPath = [appPath stringByAppendingPathComponent:name];
            if ([[NSFileManager defaultManager] fileExistsAtPath:iconPath]) {
                return iconPath;
            }
            // Try with @2x, @3x
            NSString *icon2x = [appPath stringByAppendingPathComponent:[name stringByAppendingString:@"@2x.png"]];
            if ([[NSFileManager defaultManager] fileExistsAtPath:icon2x]) {
                return icon2x;
            }
        }
    }

    return nil;
}

- (NSString *)getAppPathForBundleID:(NSString *)bundleID {
    Class LSApplicationProxyClass = NSClassFromString(@"LSApplicationProxy");
    if (!LSApplicationProxyClass) return nil;

    id proxy = [LSApplicationProxyClass applicationProxyForIdentifier:bundleID];
    if (proxy) {
        NSURL *url = [proxy bundleURL];
        return url.path;
    }
    return nil;
}

// Alternative method: scan filesystem
- (NSMutableArray *)getAppsFromFileSystem {
    NSMutableArray *apps = [NSMutableArray array];
    NSFileManager *fm = [NSFileManager defaultManager];

    log_console("[AppList] Scanning filesystem for apps...");

    // Common app locations
    NSArray *appDirs = @[
        @"/var/containers/Bundle/Application",
        @"/private/var/containers/Bundle/Application"
    ];

    for (NSString *baseDir in appDirs) {
        if (![fm fileExistsAtPath:baseDir]) {
            log_console("[AppList] Cannot access %s", baseDir.UTF8String);
            continue;
        }

        log_console("[AppList] Scanning %s...", baseDir.UTF8String);

        NSError *error;
        NSArray *uuids = [fm contentsOfDirectoryAtPath:baseDir error:&error];
        if (error) {
            log_console("[AppList] Error reading dir: %s", error.localizedDescription.UTF8String);
            continue;
        }

        log_console("[AppList] Found %lu app containers", (unsigned long)uuids.count);

        for (NSString *uuid in uuids) {
            NSString *uuidPath = [baseDir stringByAppendingPathComponent:uuid];
            NSArray *contents = [fm contentsOfDirectoryAtPath:uuidPath error:nil];

            for (NSString *item in contents) {
                if ([item hasSuffix:@".app"]) {
                    NSString *appPath = [uuidPath stringByAppendingPathComponent:item];
                    NSString *infoPlistPath = [appPath stringByAppendingPathComponent:@"Info.plist"];

                    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPlistPath];
                    if (!info) continue;

                    NSString *bundleID = info[@"CFBundleIdentifier"];
                    NSString *name = info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"] ?: item;

                    if (!bundleID) continue;

                    // Skip this app
                    if ([bundleID isEqualToString:[[NSBundle mainBundle] bundleIdentifier]]) continue;

                    [apps addObject:@{
                        @"name": name,
                        @"bundleID": bundleID,
                        @"path": appPath,
                        @"bundleType": @"User",
                        @"iconPath": @""
                    }];
                }
            }
        }
    }

    // Sort by name
    [apps sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] compare:b[@"name"] options:NSCaseInsensitiveSearch];
    }];

    log_console("[AppList] Found %lu apps from filesystem", (unsigned long)apps.count);
    return apps;
}

@end
