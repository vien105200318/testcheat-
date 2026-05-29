// ViewController.h
#import <UIKit/UIKit.h>
#import "LogTextView.h"

@interface ViewController : UIViewController <UITableViewDelegate, UITableViewDataSource, UIDocumentPickerDelegate>

@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) LogTextView *logView;
@property (nonatomic, strong) NSMutableArray *installedApps;
@property (nonatomic, strong) NSString *selectedDylibPath;
@property (nonatomic, strong) NSDictionary *selectedApp;

@end
