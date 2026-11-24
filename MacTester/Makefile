# bitchat Mac tester — command-line build for macOS 10.14 Mojave and later.
#
# Needs only the Xcode Command Line Tools (Xcode 10.2/10.3 = Swift 5.0, Xcode 11 = Swift 5.1)
# or any newer Xcode. No Xcode project, no SwiftPM.
#
#   make            # build build/BitchatTester.app for this Mac's architecture
#   make run        # build and launch
#   make universal  # x86_64 + arm64 (needs Xcode 12.2+; not possible with Mojave's toolchains)
#   make clean
#
# Swift runtime: macOS 10.14.4+ ships the Swift 5 runtime in /usr/lib/swift. On 10.14.0–10.14.3
# install Apple's "Swift 5 Runtime Support for Command Line Tools" package, or update to 10.14.6.
#
# SPDX-License-Identifier: GPL-3.0-or-later

APP      := BitchatTester
BUILD    := build
BUNDLE   := $(BUILD)/$(APP).app
ARCH     ?= $(shell uname -m)
# arm64 macOS starts at 11.0; the Intel slice keeps the Mojave deployment target.
ifeq ($(ARCH),arm64)
MIN_OS   ?= 11.0
else
MIN_OS   ?= 10.14
endif
SDK      ?= $(shell xcrun --show-sdk-path --sdk macosx)
SWIFTC   ?= xcrun swiftc
CLANG    ?= xcrun clang
SWIFTFLAGS ?= -O
MONO     := Vendor/Monocypher
CORE_SRC := $(wildcard Sources/Core/*.swift)
APP_SRC  := $(wildcard Sources/App/*.swift)
FRAMEWORKS := -framework AppKit -framework CoreBluetooth -framework MultipeerConnectivity \
              -framework Network -framework Security

.PHONY: all run clean universal

all: $(BUNDLE)

$(BUILD)/$(ARCH)/monocypher.o: $(MONO)/monocypher.c $(MONO)/monocypher.h
	@mkdir -p $(dir $@)
	$(CLANG) -O2 -arch $(ARCH) -isysroot $(SDK) -mmacosx-version-min=$(MIN_OS) -c $< -o $@

$(BUILD)/$(ARCH)/monocypher-ed25519.o: $(MONO)/monocypher-ed25519.c $(MONO)/monocypher-ed25519.h
	@mkdir -p $(dir $@)
	$(CLANG) -O2 -arch $(ARCH) -isysroot $(SDK) -mmacosx-version-min=$(MIN_OS) -I$(MONO) -c $< -o $@

$(BUILD)/$(ARCH)/$(APP): $(CORE_SRC) $(APP_SRC) Sources/App/Tester-Bridging-Header.h \
                         $(BUILD)/$(ARCH)/monocypher.o $(BUILD)/$(ARCH)/monocypher-ed25519.o
	$(SWIFTC) -swift-version 5 $(SWIFTFLAGS) -sdk $(SDK) -target $(ARCH)-apple-macosx$(MIN_OS) \
	  -module-name $(APP) -import-objc-header Sources/App/Tester-Bridging-Header.h -I $(MONO) \
	  $(CORE_SRC) $(APP_SRC) $(BUILD)/$(ARCH)/monocypher.o $(BUILD)/$(ARCH)/monocypher-ed25519.o \
	  $(FRAMEWORKS) -o $@

$(BUNDLE): $(BUILD)/$(ARCH)/$(APP) Sources/App/Info.plist
	@mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	cp $(BUILD)/$(ARCH)/$(APP) $(BUNDLE)/Contents/MacOS/$(APP)
	cp Sources/App/Info.plist $(BUNDLE)/Contents/Info.plist
	printf 'APPL????' > $(BUNDLE)/Contents/PkgInfo
	codesign --force --sign - $(BUNDLE) 2>/dev/null || echo "note: ad-hoc codesign skipped"
	@echo "built $(BUNDLE)"

universal:
	$(MAKE) ARCH=x86_64 $(BUILD)/x86_64/$(APP)
	$(MAKE) ARCH=arm64 $(BUILD)/arm64/$(APP)
	@mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	lipo -create $(BUILD)/x86_64/$(APP) $(BUILD)/arm64/$(APP) -output $(BUNDLE)/Contents/MacOS/$(APP)
	cp Sources/App/Info.plist $(BUNDLE)/Contents/Info.plist
	printf 'APPL????' > $(BUNDLE)/Contents/PkgInfo
	codesign --force --sign - $(BUNDLE) 2>/dev/null || true

run: $(BUNDLE)
	open $(BUNDLE)

clean:
	rm -rf $(BUILD)
