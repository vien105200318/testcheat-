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
    [self logWelcomeMessage];
    [self loadInstalledApps];
}

- (void)logWelcomeMessage {
    [self.logView appendLogLine:@"═══════════════════════════════════════"];
    [self.logView appendLogLine:@"       Dylib Injector v1.0"];
    [self.logView appendLogLine:@"       Kernel Exploit (Cyanide)"];
    [self.logView appendLogLine:@"═══════════════════════════════════════"];
    [self.logView appendLogLine:[NSString stringWithFormat:@"[*] Device: %@", [[UIDevice currentDevice] model]]];
    [self.logView appendLogLine:[NSString stringWithFormat:@"[*] iOS: %@", [[UIDevice currentDevice] systemVersion]]];

    DylibInjector *injector = [DylibInjector sharedInstance];
    if ([injector isDeviceSupported]) {
        [self.logView appendLogLine:@"[+] Device supported!"];
    } else {
        [self.logView appendLogLine:@"[!] Device NOT supported"];
        [self.logView appendLogLine:[injector deviceSupportMessage]];
    }
    [self.logView appendLogLine:@""];
    [self.logView appendLogLine:@"[*] Chọn Dylib và app để inject"];
    [self.logView appendLogLine:@"[*] Nhấn 'Chạy Kernel Exploit' để bắt đầu"];
    [self.logView appendLogLine:@""];
}

- (void)setupUI {
    CGFloat screenHeight = self.view.bounds.size.height;
    CGFloat logHeight = 200;
    CGFloat tableHeight = screenHeight - logHeight;

    // Table view (top)
    self.tableView = [[UITableView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, tableHeight)
                                                  style:UITableViewStyleInsetGrouped];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"AppCell"];
    [self.view addSubview:self.tableView];

    // Log view container (bottom)
    UIView *logContainer = [[UIView alloc] initWithFrame:CGRectMake(0, tableHeight, self.view.bounds.size.width, logHeight)];
    logContainer.backgroundColor = [UIColor colorWithRed:0.1 green:0.1 blue:0.12 alpha:1.0];
    logContainer.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    [self.view addSubview:logContainer];

    // Log header
    UILabel *logHeader = [[UILabel alloc] initWithFrame:CGRectMake(12, 4, logContainer.bounds.size.width - 80, 24)];
    logHeader.text = @"📋 Console Log";
    logHeader.textColor = [UIColor whiteColor];
    logHeader.font = [UIFont boldSystemFontOfSize:13];
    [logContainer addSubview:logHeader];

    // Clear button
    UIButton *clearBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    clearBtn.frame = CGRectMake(logContainer.bounds.size.width - 70, 4, 60, 24);
    clearBtn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [clearBtn setTitle:@"Clear" forState:UIControlStateNormal];
    [clearBtn setTitleColor:[UIColor systemBlueColor] forState:UIControlStateNormal];
    clearBtn.titleLabel.font = [UIFont systemFontOfSize:12];
    [clearBtn addTarget:self action:@selector(clearLog) forControlEvents:UIControlEventTouchUpInside];
    [logContainer addSubview:clearBtn];

    // Log text view
    self.logView = [[LogTextView alloc] initWithFrame:CGRectMake(8, 28, logContainer.bounds.size.width - 16, logHeight - 36)];
    self.logView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [logContainer addSubview:self.logView];

    // Navigation buttons
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

        [self.logView appendLogLine:[NSString stringWithFormat:@"[*] Selected file: %@", filename]];

        if ([filename hasSuffix:@".dylib"]) {
            NSString *docsPath = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
            NSString *destPath = [docsPath stringByAppendingPathComponent:filename];

            NSError *error;
            [[NSFileManager defaultManager] removeItemAtPath:destPath error:nil];
            [[NSFileManager defaultManager] copyItemAtURL:url toURL:[NSURL fileURLWithPath:destPath] error:&error];

            if (!error) {
                self.selectedDylibPath = destPath;
                [self.tableView reloadData];
                [self.logView appendLogLine:[NSString stringWithFormat:@"[+] Dylib loaded: %@", filename]];
                [self showAlert:@"Đã chọn" message:[NSString stringWithFormat:@"Dylib: %@", filename]];
            } else {
                [self.logView appendLogLine:[NSString stringWithFormat:@"[!] Error: %@", error.localizedDescription]];
                [self showAlert:@"Lỗi" message:error.localizedDescription];
            }
        } else {
            [self.logView appendLogLine:@"[!] Invalid file - must be .dylib"];
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
        DylibInjector *injector = [DylibInjector sharedInstance];
        NSString *deviceMsg = [injector deviceSupportMessage];
        return [NSString stringWithFormat:@"Exploit cần thiết để truy cập apps và inject dylib.\n%@", deviceMsg];
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
            } else if (![injector isDeviceSupported]) {
                cell.textLabel.text = @"⛔ Thiết bị không hỗ trợ";
                cell.imageView.image = [UIImage systemImageNamed:@"xmark.shield.fill"];
                cell.textLabel.textColor = [UIColor systemRedColor];
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

- (void)clearLog {
    [self.logView clearLog];
    [self.logView appendLogLine:@"[*] Log cleared"];
}

- (void)runExploit {
    DylibInjector *injector = [DylibInjector sharedInstance];

    [self.logView appendLogLine:@""];
    [self.logView appendLogLine:@"═══════════════════════════════════════"];
    [self.logView appendLogLine:@"[*] Starting Kernel Exploit..."];
    [self.logView appendLogLine:@"═══════════════════════════════════════"];

    // Check device support first
    if (![injector isDeviceSupported]) {
        [self.logView appendLogLine:@"[!] Device not supported!"];
        [self.logView appendLogLine:[injector deviceSupportMessage]];
        [self showAlert:@"Không hỗ trợ" message:[injector deviceSupportMessage]];
        return;
    }

    [self.logView appendLogLine:@"[+] Device supported"];

    if ([injector isExploitReady]) {
        [self.logView appendLogLine:@"[+] Exploit already running"];
        [self showAlert:@"Đã sẵn sàng" message:@"Exploit đã chạy thành công"];
        return;
    }

    [self.logView appendLogLine:@"[*] Running exploit... (10-30 seconds)"];

    UIAlertController *loading = [UIAlertController alertControllerWithTitle:@"Đang chạy exploit..."
                                                                     message:@"Vui lòng đợi, có thể mất 10-30 giây"
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:loading animated:YES completion:nil];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self.logView appendLogLine:@"[*] Phase 1: Kernel exploit..."];

        NSError *error;
        BOOL success = [injector runExploit:&error];

        if (success) {
            [self.logView appendLogLine:@"[+] Kernel exploit successful!"];
            [self.logView appendLogLine:@"[*] Phase 2: Escaping sandbox..."];
            [injector escapeSandbox:&error];
            [self.logView appendLogLine:@"[+] Sandbox escaped!"];
        } else {
            [self.logView appendLogLine:[NSString stringWithFormat:@"[!] Exploit failed: %@", error.localizedDescription]];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [loading dismissViewControllerAnimated:YES completion:^{
                [self.tableView reloadData];

                if (success) {
                    [self.logView appendLogLine:@""];
                    [self.logView appendLogLine:@"[+] ═══════════════════════════════════"];
                    [self.logView appendLogLine:@"[+]     EXPLOIT SUCCESSFUL!"];
                    [self.logView appendLogLine:@"[+] ═══════════════════════════════════"];
                    [self.logView appendLogLine:@"[*] Ready to inject dylibs"];
                    [self showAlert:@"Thành công!" message:@"Kernel exploit đã chạy. Bạn có thể inject dylib vào apps."];
                    [self loadInstalledApps];
                } else {
                    [self.logView appendLogLine:@"[!] ═══════════════════════════════════"];
                    [self.logView appendLogLine:@"[!]     EXPLOIT FAILED"];
                    [self.logView appendLogLine:@"[!] ═══════════════════════════════════"];
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
    NSString *appName = self.selectedApp[@"name"];
    NSString *bundleID = self.selectedApp[@"bundleID"];
    NSString *dylibName = self.selectedDylibPath.lastPathComponent;

    [self.logView appendLogLine:@""];
    [self.logView appendLogLine:@"═══════════════════════════════════════"];
    [self.logView appendLogLine:@"[*] Starting Dylib Injection..."];
    [self.logView appendLogLine:@"═══════════════════════════════════════"];
    [self.logView appendLogLine:[NSString stringWithFormat:@"[*] Target: %@", appName]];
    [self.logView appendLogLine:[NSString stringWithFormat:@"[*] Bundle: %@", bundleID]];
    [self.logView appendLogLine:[NSString stringWithFormat:@"[*] Dylib: %@", dylibName]];

    UIAlertController *loading = [UIAlertController alertControllerWithTitle:@"Đang inject..."
                                                                     message:@"Đang chạy exploit và inject dylib..."
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:loading animated:YES completion:nil];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self.logView appendLogLine:@"[*] Checking exploit status..."];

        DylibInjector *injector = [DylibInjector sharedInstance];
        if (![injector isExploitReady]) {
            [self.logView appendLogLine:@"[*] Running kernel exploit first..."];
        }

        [self.logView appendLogLine:@"[*] Injecting dylib into app..."];

        NSError *error;
        BOOL success = [injector injectDylib:self.selectedDylibPath
                                    intoApp:self.selectedApp
                                      error:&error];

        dispatch_async(dispatch_get_main_queue(), ^{
            [loading dismissViewControllerAnimated:YES completion:^{
                [self.tableView reloadData];

                if (success) {
                    [self.logView appendLogLine:@""];
                    [self.logView appendLogLine:@"[+] ═══════════════════════════════════"];
                    [self.logView appendLogLine:@"[+]     INJECTION SUCCESSFUL!"];
                    [self.logView appendLogLine:@"[+] ═══════════════════════════════════"];
                    [self.logView appendLogLine:[NSString stringWithFormat:@"[+] Injected %@ into %@", dylibName, appName]];
                    [self.logView appendLogLine:@"[*] Restart the app to load dylib"];
                    [self showAlert:@"Thành công!" message:@"Đã inject dylib vào app.\n\nKhởi động lại app để load dylib."];
                } else {
                    [self.logView appendLogLine:@""];
                    [self.logView appendLogLine:@"[!] ═══════════════════════════════════"];
                    [self.logView appendLogLine:@"[!]     INJECTION FAILED"];
                    [self.logView appendLogLine:@"[!] ═══════════════════════════════════"];
                    [self.logView appendLogLine:[NSString stringWithFormat:@"[!] Error: %@", error.localizedDescription]];
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
