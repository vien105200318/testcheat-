// ViewController.m - Main UI for Dylib Injector
#import "ViewController.h"
#import "AppListManager.h"
#import "DylibInjector.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

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
    // Use new API for iOS 14+
    NSArray *types = @[UTTypeData];
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:YES];
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
    if (self.installedApps.count == 0) {
        return @"Không tìm thấy app (cần quyền đặc biệt)";
    }
    return [NSString stringWithFormat:@"Ứng dụng đã cài (%lu)", (unsigned long)self.installedApps.count];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 1; // Manual input option
    return self.installedApps.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"AppCell" forIndexPath:indexPath];

    if (indexPath.section == 0) {
        cell.textLabel.text = @"Nhập Bundle ID thủ công";
        cell.detailTextLabel.text = @"Khi không tìm thấy app";
        cell.imageView.image = [UIImage systemImageNamed:@"keyboard"];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }

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

    if (indexPath.section == 0) {
        [self showManualBundleIDInput];
        return;
    }

    self.selectedApp = self.installedApps[indexPath.row];
    [self showInjectConfirmation];
}

- (void)showManualBundleIDInput {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Nhập Bundle ID"
                                                                   message:@"Nhập Bundle ID của app (vd: com.garena.game.kgvn)"
                                                            preferredStyle:UIAlertControllerStyleAlert];

    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"com.example.app";
        textField.keyboardType = UIKeyboardTypeASCIICapable;
    }];

    [alert addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *bundleID = alert.textFields.firstObject.text;
        if (bundleID.length > 0) {
            // Try to find app path
            NSString *appPath = [[AppListManager sharedManager] getAppPathForBundleID:bundleID];
            if (!appPath) {
                // Try common paths
                appPath = [NSString stringWithFormat:@"/var/containers/Bundle/Application/*/%@.app", bundleID.lastPathComponent];
            }

            self.selectedApp = @{
                @"name": bundleID,
                @"bundleID": bundleID,
                @"path": appPath ?: @"",
                @"bundleType": @"User"
            };
            [self showInjectConfirmation];
        }
    }]];

    [self presentViewController:alert animated:YES completion:nil];
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
