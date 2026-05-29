# Makefile for DylibInjector iOS App
# Requires Xcode command line tools on macOS

SDKROOT ?= $(shell xcrun --sdk iphoneos --show-sdk-path 2>/dev/null)
CC = clang
ARCH = -arch arm64

CFLAGS = -fobjc-arc \
         -isysroot $(SDKROOT) \
         -miphoneos-version-min=14.0 \
         -framework Foundation \
         -framework UIKit \
         -framework CoreGraphics

SOURCES = AppDelegate.m \
          ViewController.m \
          AppListManager.m \
          DylibInjector.m

TARGET = DylibInjector
APP_DIR = $(TARGET).app
IPA_NAME = $(TARGET).ipa

all: ipa

$(TARGET): $(SOURCES)
	@echo "Compiling..."
	$(CC) $(ARCH) $(CFLAGS) -o $@ $^
	@echo "Signing with ldid..."
	ldid -Sentitlements.plist $@ || codesign -f -s - --entitlements entitlements.plist $@

app: $(TARGET)
	@echo "Creating app bundle..."
	mkdir -p $(APP_DIR)
	cp $(TARGET) $(APP_DIR)/
	cp Info.plist $(APP_DIR)/
	@echo "App bundle created: $(APP_DIR)"

ipa: app
	@echo "Creating IPA..."
	mkdir -p Payload
	cp -r $(APP_DIR) Payload/
	zip -r $(IPA_NAME) Payload
	rm -rf Payload
	@echo "IPA created: $(IPA_NAME)"

clean:
	rm -rf $(TARGET) $(APP_DIR) $(IPA_NAME) Payload

.PHONY: all app ipa clean
