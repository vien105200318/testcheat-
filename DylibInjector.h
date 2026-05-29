// DylibInjector.h - Kernel-based injection
#import <Foundation/Foundation.h>

@interface DylibInjector : NSObject

+ (instancetype)sharedInstance;

// Kernel exploit
- (BOOL)runExploit:(NSError **)error;
- (BOOL)escapeSandbox:(NSError **)error;
- (BOOL)initSpringBoardSession:(NSError **)error;

// Injection
- (BOOL)injectDylib:(NSString *)dylibPath
            intoApp:(NSDictionary *)appInfo
              error:(NSError **)error;

// State
- (BOOL)isExploitReady;
- (BOOL)isSandboxEscaped;
- (BOOL)isDeviceSupported;
- (NSString *)deviceSupportMessage;
- (void)resetState;

@end
