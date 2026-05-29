// LogTextView.m - Real-time log display
#import "LogTextView.h"
#import <pthread.h>

static LogTextView *_sharedLogView = nil;
static pthread_mutex_t _logMutex = PTHREAD_MUTEX_INITIALIZER;

@implementation LogTextView

+ (instancetype)sharedInstance {
    return _sharedLogView;
}

+ (void)setSharedInstance:(LogTextView *)instance {
    _sharedLogView = instance;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self setupAppearance];
        [LogTextView setSharedInstance:self];
    }
    return self;
}

- (void)setupAppearance {
    self.backgroundColor = [UIColor colorWithRed:0.1 green:0.1 blue:0.12 alpha:1.0];
    self.textColor = [UIColor colorWithRed:0.0 green:0.9 blue:0.4 alpha:1.0];
    self.font = [UIFont fontWithName:@"Menlo" size:11];
    if (!self.font) {
        self.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    }
    self.editable = NO;
    self.selectable = YES;
    self.layer.cornerRadius = 8;
    self.layer.masksToBounds = YES;
    self.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    self.contentInset = UIEdgeInsetsMake(8, 8, 8, 8);
}

- (void)appendLog:(NSString *)text {
    if (!text) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        pthread_mutex_lock(&_logMutex);

        NSMutableAttributedString *newText = [[NSMutableAttributedString alloc] init];

        if (self.attributedText.length > 0) {
            [newText appendAttributedString:self.attributedText];
        }

        // Color code based on content
        UIColor *textColor = self.textColor;
        if ([text containsString:@"[!]"] || [text containsString:@"Error"] || [text containsString:@"failed"] || [text containsString:@"Lỗi"]) {
            textColor = [UIColor colorWithRed:1.0 green:0.3 blue:0.3 alpha:1.0];
        } else if ([text containsString:@"[+]"] || [text containsString:@"success"] || [text containsString:@"Thành công"]) {
            textColor = [UIColor colorWithRed:0.3 green:1.0 blue:0.3 alpha:1.0];
        } else if ([text containsString:@"[*]"] || [text containsString:@"..."]) {
            textColor = [UIColor colorWithRed:0.3 green:0.7 blue:1.0 alpha:1.0];
        } else if ([text containsString:@"[KRW]"] || [text containsString:@"[Injector]"]) {
            textColor = [UIColor colorWithRed:1.0 green:0.8 blue:0.2 alpha:1.0];
        }

        NSDictionary *attrs = @{
            NSFontAttributeName: self.font,
            NSForegroundColorAttributeName: textColor
        };

        NSAttributedString *coloredText = [[NSAttributedString alloc] initWithString:text attributes:attrs];
        [newText appendAttributedString:coloredText];

        self.attributedText = newText;

        // Auto-scroll to bottom
        if (self.text.length > 0) {
            NSRange bottom = NSMakeRange(self.text.length - 1, 1);
            [self scrollRangeToVisible:bottom];
        }

        // Limit log size (keep last 500 lines)
        NSArray *lines = [self.text componentsSeparatedByString:@"\n"];
        if (lines.count > 500) {
            NSArray *trimmed = [lines subarrayWithRange:NSMakeRange(lines.count - 400, 400)];
            self.text = [trimmed componentsJoinedByString:@"\n"];
        }

        pthread_mutex_unlock(&_logMutex);
    });
}

- (void)appendLogLine:(NSString *)line {
    [self appendLog:[line stringByAppendingString:@"\n"]];
}

- (void)clearLog {
    dispatch_async(dispatch_get_main_queue(), ^{
        pthread_mutex_lock(&_logMutex);
        self.text = @"";
        pthread_mutex_unlock(&_logMutex);
    });
}

@end

#pragma mark - Global Log Functions

void log_to_ui(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    // Also print to console
    NSLog(@"%@", message);

    // Send to UI
    LogTextView *logView = [LogTextView sharedInstance];
    if (logView) {
        [logView appendLogLine:message];
    }
}

void log_console(const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);

    char buffer[4096];
    vsnprintf(buffer, sizeof(buffer), fmt, args);
    va_end(args);

    NSString *message = [NSString stringWithUTF8String:buffer];

    // Print to console
    printf("%s\n", buffer);

    // Send to UI
    LogTextView *logView = [LogTextView sharedInstance];
    if (logView) {
        [logView appendLogLine:message];
    }
}

void log_user(const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);

    char buffer[4096];
    vsnprintf(buffer, sizeof(buffer), fmt, args);
    va_end(args);

    NSString *message = [NSString stringWithUTF8String:buffer];

    // Print to console
    printf("%s\n", buffer);

    // Send to UI
    LogTextView *logView = [LogTextView sharedInstance];
    if (logView) {
        [logView appendLogLine:message];
    }
}

#pragma mark - NSLog Redirect

static void (*original_NSLog)(NSString *format, ...) = NULL;

static void redirected_NSLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    // Call original NSLog
    if (original_NSLog) {
        original_NSLog(@"%@", message);
    } else {
        fprintf(stderr, "%s\n", message.UTF8String);
    }

    // Send to UI
    LogTextView *logView = [LogTextView sharedInstance];
    if (logView) {
        [logView appendLogLine:message];
    }
}

void setup_log_redirect(void) {
    // Note: NSLog interception is complex; we use a simpler approach
    // by having kexploit code call log_console/log_user directly
}
