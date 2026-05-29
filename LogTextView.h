// LogTextView.h - Real-time log display
#import <UIKit/UIKit.h>

@interface LogTextView : UITextView

+ (instancetype)sharedInstance;
- (void)appendLog:(NSString *)text;
- (void)appendLogLine:(NSString *)line;
- (void)clearLog;

@end

// Global log functions
void log_to_ui(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
void log_console(const char *fmt, ...);
void log_user(const char *fmt, ...);

// Redirect NSLog to UI
void setup_log_redirect(void);
