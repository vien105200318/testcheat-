// DylibInjector.h
#import <Foundation/Foundation.h>

@interface DylibInjector : NSObject

+ (instancetype)sharedInstance;

// Inject dylib into app
- (BOOL)injectDylib:(NSString *)dylibPath
            intoApp:(NSDictionary *)appInfo
              error:(NSError **)error;

// Patch Mach-O binary to load dylib
- (BOOL)patchBinary:(NSString *)binaryPath
      toLoadDylib:(NSString *)dylibName
              error:(NSError **)error;

@end
