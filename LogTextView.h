// LogTextView.h - Stub for DylibInjector
#import <UIKit/UIKit.h>

@interface LogTextView : UITextView
- (void)appendLogLine:(NSString *)line;
@end

static inline void log_console(const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    vprintf(fmt, args);
    va_end(args);
    printf("\n");
}
