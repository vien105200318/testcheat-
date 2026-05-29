// AppListManager.h
#import <Foundation/Foundation.h>

@interface AppListManager : NSObject

+ (instancetype)sharedManager;
- (NSMutableArray *)getInstalledApps;
- (NSString *)getAppPathForBundleID:(NSString *)bundleID;

@end
