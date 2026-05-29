// ViewController.h
#import <UIKit/UIKit.h>

@interface ViewController : UIViewController <UITableViewDelegate, UITableViewDataSource, UIDocumentPickerDelegate>

@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSMutableArray *installedApps;
@property (nonatomic, strong) NSString *selectedDylibPath;
@property (nonatomic, strong) NSDictionary *selectedApp;

@end
