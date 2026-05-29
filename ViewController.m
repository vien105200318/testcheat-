// ViewController.m - Main UI for Dylib Injector
#import "ViewController.h"
#import "AppListManager.h"
#import "DylibInjector.h"

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"Dylib Injector";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    // Setup UI
    [self setupUI];

    // Load installed apps
    [self loadInstalledApps];
}

- (void)setupUI {
    // Table view for app list
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"AppCell"];
    [self.view addSubview:self.tableView];

    // Refresh button
    UIBarButtonItem *refreshBtn = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                                                target:self
                                                                                action:@selector(loadInstalledApps)];
    self.navigationItem.rightBarButtonItem = refreshBtn;

    // Select dylib button
    UIBarButtonItem *dylibBtn = [[UIBarButtonItem alloc] initWithTitle:@"Chọn Dylib"
                                                                 style:UIBarButtonItemStylePlain
                                                                target:self
                                                                action:@selector(selectDylib)];
    self.navigationItem.leftBarButtonItem = dylibBtn;
}

- (void)loadInstalledApps {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        self.installedApps = [[AppListManager sharedManager] getInstalledApps];

        dispatch_async(dispatch_get_main_queue(), ^{
            [self.tableView reloadData];
        });
    });
}

#pragma mark - Select Dylib

- (void)selectDylib {
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initWithDocumentTypes:@[@"public.data"]
        inMode:UIDocumentPickerModeImport];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (urls.count > 0) {
        NSURL *url = urls.firstObject;
        NSString *filename = url.lastPathComponent;

        if ([filename hasSuffix:@".dylib"]) {
            // Copy to app documents
            NSString *docsPath = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
            NSString *destPath = [docsPath stringByAppendingPathComponent:filename];

            NSError *error;
            [[NSFileManager defaultManager] removeItemAtPath:destPath error:nil];
            [[NSFileManager defaultManager] copyItemAtURL:url toURL:[NSURL fileURLWithPath:destPath] error:&error];

            if (!error) {
                self.selectedDylibPath = destPath;
                [self showAlert:@"Đã chọn" message:[NSString stringWithFormat:@"Dylib: %@", filename]];
            } else {
                [self showAlert:@"Lỗi" message:error.localizedDescription];
            }
        } else {
            [self showAlert:@"Lỗi" message:@"Vui lòng chọn file .dylib"];
        }
    }
}

#pragma mark - TableView

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) {
        return self.selectedDylibPath ? [NSString stringWithFormat:@"Dylib: %@", self.selectedDylibPath.lastPathComponent] : @"Chưa chọn dylib";
    }
    return @"Ứng dụng đã cài";
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 0;
    return self.installedApps.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"AppCell" forIndexPath:indexPath];

    NSDictionary *app = self.installedApps[indexPath.row];
    cell.textLabel.text = app[@"name"];
    cell.detailTextLabel.text = app[@"bundleID"];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

    // Load app icon
    NSString *iconPath = app[@"iconPath"];
    if (iconPath && [[NSFileManager defaultManager] fileExistsAtPath:iconPath]) {
        cell.imageView.image = [UIImage imageWithContentsOfFile:iconPath];
    } else {
        cell.imageView.image = [UIImage systemImageNamed:@"app.fill"];
    }

    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (!self.selectedDylibPath) {
        [self showAlert:@"Chưa chọn dylib" message:@"Vui lòng chọn file .dylib trước"];
        return;
    }

    self.selectedApp = self.installedApps[indexPath.row];
    [self showInjectConfirmation];
}

#pragma mark - Inject

- (void)showInjectConfirmation {
    NSString *appName = self.selectedApp[@"name"];
    NSString *dylibName = self.selectedDylibPath.lastPathComponent;

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Xác nhận Inject"
                                                                   message:[NSString stringWithFormat:@"Inject %@ vào %@?", dylibName, appName]
                                                            preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Inject" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [self performInject];
    }]];

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)performInject {
    // Show loading
    UIAlertController *loading = [UIAlertController alertControllerWithTitle:@"Đang inject..."
                                                                     message:@"Vui lòng đợi"
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:loading animated:YES completion:nil];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSError *error;
        BOOL success = [[DylibInjector sharedInstance] injectDylib:self.selectedDylibPath
                                                          intoApp:self.selectedApp
                                                             error:&error];

        dispatch_async(dispatch_get_main_queue(), ^{
            [loading dismissViewControllerAnimated:YES completion:^{
                if (success) {
                    [self showAlert:@"Thành công!" message:@"Đã inject dylib. App sẽ được cài lại."];
                } else {
                    [self showAlert:@"Lỗi" message:error.localizedDescription];
                }
            }];
        });
    });
}

- (void)showAlert:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
