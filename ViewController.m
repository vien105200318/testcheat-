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

    [self setupUI];
    [self loadInstalledApps];
}

- (void)setupUI {
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"AppCell"];
    [self.view addSubview:self.tableView];

    UIBarButtonItem *refreshBtn = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                                                target:self
                                                                                action:@selector(loadInstalledApps)];
    self.navigationItem.rightBarButtonItem = refreshBtn;

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
            NSString *docsPath = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
            NSString *destPath = [docsPath stringByAppendingPathComponent:filename];

            NSError *error;
            [[NSFileManager defaultManager] removeItemAtPath:destPath error:nil];
            [[NSFileManager defaultManager] copyItemAtURL:url toURL:[NSURL fileURLWithPath:destPath] error:&error];

            if (!error) {
                self.selectedDylibPath = destPath;
                [self.tableView reloadData];
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
    return 3; // Exploit status, Manual input, Apps
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) {
        return @"🔓 Kernel Exploit";
    }
    if (section == 1) {
        return self.selectedDylibPath ? [NSString stringWithFormat:@"📦 Dylib: %@", self.selectedDylibPath.lastPathComponent] : @"📦 Chưa chọn dylib";
    }
    if (self.installedApps.count == 0) {
        return @"📱 Chạy exploit để quét apps";
    }
    return [NSString stringWithFormat:@"📱 Ứng dụng (%lu)", (unsigned long)self.installedApps.count];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) {
        return @"Exploit cần thiết để truy cập apps và inject dylib";
    }
    return nil;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 2; // Run exploit + status
    if (section == 1) return 1; // Manual input
    return self.installedApps.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"AppCell" forIndexPath:indexPath];
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.textLabel.textColor = [UIColor labelColor];

    if (indexPath.section == 0) {
        DylibInjector *injector = [DylibInjector sharedInstance];

        if (indexPath.row == 0) {
            // Run exploit button
            if ([injector isExploitReady]) {
                cell.textLabel.text = @"✅ Exploit đã chạy";
                cell.imageView.image = [UIImage systemImageNamed:@"checkmark.shield.fill"];
                cell.textLabel.textColor = [UIColor systemGreenColor];
            } else {
                cell.textLabel.text = @"🚀 Chạy Kernel Exploit";
                cell.imageView.image = [UIImage systemImageNamed:@"bolt.shield.fill"];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            }
        } else {
            // Sandbox status
            if ([injector isSandboxEscaped]) {
                cell.textLabel.text = @"✅ Đã thoát sandbox";
                cell.imageView.image = [UIImage systemImageNamed:@"lock.open.fill"];
                cell.textLabel.textColor = [UIColor systemGreenColor];
            } else {
                cell.textLabel.text = @"🔒 Sandbox chưa thoát";
                cell.imageView.image = [UIImage systemImageNamed:@"lock.fill"];
                cell.textLabel.textColor = [UIColor systemOrangeColor];
            }
        }
        return cell;
    }

    if (indexPath.section == 1) {
        cell.textLabel.text = @"Nhập Bundle ID thủ công";
        cell.imageView.image = [UIImage systemImageNamed:@"keyboard"];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }

    NSDictionary *app = self.installedApps[indexPath.row];
    cell.textLabel.text = app[@"name"];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

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

    if (indexPath.section == 0) {
        if (indexPath.row == 0) {
            [self runExploit];
        }
        return;
    }

    if (!self.selectedDylibPath) {
        [self showAlert:@"Chưa chọn dylib" message:@"Vui lòng chọn file .dylib trước"];
        return;
    }

    if (indexPath.section == 1) {
        [self showManualBundleIDInput];
        return;
    }

    self.selectedApp = self.installedApps[indexPath.row];
    [self showInjectConfirmation];
}

#pragma mark - Exploit

- (void)runExploit {
    DylibInjector *injector = [DylibInjector sharedInstance];

    if ([injector isExploitReady]) {
        [self showAlert:@"Đã sẵn sàng" message:@"Exploit đã chạy thành công"];
        return;
    }

    UIAlertController *loading = [UIAlertController alertControllerWithTitle:@"Đang chạy exploit..."
                                                                     message:@"Vui lòng đợi, có thể mất 10-30 giây"
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:loading animated:YES completion:nil];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSError *error;
        BOOL success = [injector runExploit:&error];

        if (success) {
            [injector escapeSandbox:&error];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [loading dismissViewControllerAnimated:YES completion:^{
                [self.tableView reloadData];

                if (success) {
                    [self showAlert:@"Thành công!" message:@"Kernel exploit đã chạy. Bạn có thể inject dylib vào apps."];
                    [self loadInstalledApps];
                } else {
                    [self showAlert:@"Lỗi" message:error.localizedDescription];
                }
            }];
        });
    });
}

#pragma mark - Manual Input

- (void)showManualBundleIDInput {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Nhập Bundle ID"
                                                                   message:@"Ví dụ: com.garena.game.kgvn"
                                                            preferredStyle:UIAlertControllerStyleAlert];

    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"com.garena.game.kgvn";
        textField.keyboardType = UIKeyboardTypeASCIICapable;
    }];

    [alert addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *bundleID = alert.textFields.firstObject.text;
        if (bundleID.length > 0) {
            NSString *appPath = [[AppListManager sharedManager] getAppPathForBundleID:bundleID];

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
                                                                   message:[NSString stringWithFormat:@"Inject %@ vào %@?\n\nApp sẽ cần restart để load dylib.", dylibName, appName]
                                                            preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Inject" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [self performInject];
    }]];

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)performInject {
    UIAlertController *loading = [UIAlertController alertControllerWithTitle:@"Đang inject..."
                                                                     message:@"Đang chạy exploit và inject dylib..."
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:loading animated:YES completion:nil];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSError *error;
        BOOL success = [[DylibInjector sharedInstance] injectDylib:self.selectedDylibPath
                                                          intoApp:self.selectedApp
                                                             error:&error];

        dispatch_async(dispatch_get_main_queue(), ^{
            [loading dismissViewControllerAnimated:YES completion:^{
                [self.tableView reloadData];

                if (success) {
                    [self showAlert:@"Thành công!" message:@"Đã inject dylib vào app.\n\nKhởi động lại app để load dylib."];
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
