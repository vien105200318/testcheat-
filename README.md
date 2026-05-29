# Dylib Injector - iOS App

App iOS để inject dylib vào các ứng dụng đã cài đặt trên iPhone.

## Tính năng

- Hiển thị danh sách tất cả app đã cài
- Chọn file .dylib từ Files
- Inject dylib vào app được chọn
- Tự động patch Mach-O binary
- Cài lại app đã inject

## Yêu cầu

- iPhone với TrollStore (không cần jailbreak)
- Hoặc iPhone jailbreak

## Cách build

### Cách 1: Dùng Theos (Linux/Mac)

```bash
# Cài Theos
bash -c "$(curl -fsSL https://raw.githubusercontent.com/theos/theos/master/bin/install-theos)"

# Build
cp Makefile.theos Makefile
make package
```

Output: `packages/DylibInjector_1.0_iphoneos-arm.deb` hoặc `.ipa`

### Cách 2: Dùng Xcode (Mac)

```bash
make ipa
```

Output: `DylibInjector.ipa`

### Cách 3: Dùng GitHub Actions

Fork repo và dùng workflow để build online.

## Cách sử dụng

1. Cài app qua TrollStore
2. Mở app, sẽ thấy danh sách ứng dụng
3. Nhấn "Chọn Dylib" để chọn file .dylib
4. Chọn app muốn inject
5. Xác nhận và đợi inject hoàn tất
6. App sẽ được cài lại tự động

## Lưu ý

- App cần chạy với quyền TrollStore (platform-application)
- Một số app có protection có thể không inject được
- Nên backup app trước khi inject

## Files

```
DylibInjector/
├── AppDelegate.m       # Entry point
├── ViewController.m    # Main UI
├── ViewController.h
├── AppListManager.m    # List installed apps
├── AppListManager.h
├── DylibInjector.m     # Core injection logic
├── DylibInjector.h
├── Info.plist          # App config
├── entitlements.plist  # TrollStore entitlements
├── Makefile            # Xcode build
└── Makefile.theos      # Theos build
```

## Cách hoạt động

1. **List apps**: Dùng `LSApplicationWorkspace` private API để lấy danh sách app
2. **Copy app**: Copy app bundle ra thư mục tạm
3. **Copy dylib**: Copy dylib vào trong app bundle
4. **Patch binary**: Thêm `LC_LOAD_DYLIB` vào Mach-O header để load dylib khi app khởi động
5. **Sign**: Sign lại binary với ldid
6. **Install**: Dùng `LSApplicationWorkspace` để cài lại app

## Troubleshooting

### "Không đủ chỗ trong header"
Binary không có đủ padding để thêm load command. Cần dùng tool khác để expand header.

### App crash sau inject
- Dylib không tương thích với app
- Dylib chưa được sign đúng
- Entitlements thiếu

### Không thấy app trong danh sách
- App là system app (không thể modify)
- App bị ẩn
