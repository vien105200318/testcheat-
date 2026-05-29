// AppDelegate.m - Dylib Injector App
#import <UIKit/UIKit.h>
#import "ViewController.h"
#import "kexploit/kexploit_opa334.h"
#import <signal.h>

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

static void termination_signal_handler(int sig) {
    NSLog(@"[AppDelegate] Received signal %d, running kernel cleanup...", sig);
    kexploit_terminal_cleanup();
    signal(sig, SIG_DFL);
    raise(sig);
}

static void atexit_handler(void) {
    NSLog(@"[AppDelegate] atexit handler, running kernel cleanup...");
    kexploit_terminal_cleanup();
}

@implementation AppDelegate

- (void)installTerminationHandlers {
    NSLog(@"[AppDelegate] Installing termination handlers...");

    signal(SIGTERM, termination_signal_handler);
    signal(SIGINT, termination_signal_handler);
    signal(SIGHUP, termination_signal_handler);
    signal(SIGQUIT, termination_signal_handler);

    atexit(atexit_handler);

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationWillTerminateNotification:)
                                                 name:UIApplicationWillTerminateNotification
                                               object:nil];

    NSLog(@"[AppDelegate] Termination handlers installed");
}

- (void)applicationWillTerminateNotification:(NSNotification *)notification {
    NSLog(@"[AppDelegate] UIApplicationWillTerminateNotification, running kernel cleanup...");
    kexploit_terminal_cleanup();
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    NSLog(@"[AppDelegate] Application launching...");

    [self installTerminationHandlers];

    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];

    ViewController *vc = [[ViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];

    self.window.rootViewController = nav;
    [self.window makeKeyAndVisible];

    NSLog(@"[AppDelegate] Application launched successfully");
    return YES;
}

- (void)applicationWillTerminate:(UIApplication *)application {
    NSLog(@"[AppDelegate] applicationWillTerminate, running kernel cleanup...");
    kexploit_terminal_cleanup();
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    NSLog(@"[AppDelegate] App entered background, running kernel cleanup as precaution...");
    kexploit_terminal_cleanup();
}

@end

int main(int argc, char * argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
