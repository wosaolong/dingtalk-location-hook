# Makefile — 钉钉虚拟定位注入插件编译脚本
# 使用方式：在 Mac 上运行 make 即可编译

SDKROOT ?= $(shell xcrun --sdk iphoneos --show-sdk-path 2>/dev/null)
ARCH    ?= arm64
TARGET  ?= LocationHook.dylib
SOURCES  = LocationHook.m ConfigManager.m FloatingMenu.m fishhook.c
HEADERS  = ConfigManager.h fishhook.h

CC = $(shell xcrun --find clang 2>/dev/null || echo "clang")

CFLAGS = -shared \
         -arch $(ARCH) \
         -isysroot "$(SDKROOT)" \
         -framework Foundation \
         -framework CoreLocation \
         -framework UIKit \
         -framework QuartzCore \
         -fobjc-arc \
         -O2 \
         -DNDEBUG \
         -dynamiclib \
         -miphoneos-version-min=14.0

INSTALL_DIR ?= ./Payload/DingTalk.app

all: $(TARGET)

$(TARGET): $(SOURCES) $(HEADERS)
	@echo "📦 编译 $(TARGET) ..."
	@if [ -z "$(SDKROOT)" ]; then \
		echo "❌ 错误：找不到 iOS SDK，请确保已安装 Xcode"; \
		exit 1; \
	fi
	$(CC) $(CFLAGS) -o "$@" $(SOURCES)
	@echo "✅ 编译成功: $(TARGET)"
	@file $(TARGET)
	@echo ""
	@echo "下一步:"
	@echo "  1. 把 $(TARGET) 复制到 Payload/DingTalk.app/"
	@echo "  2. insert_dylib @executable_path/$(TARGET) Payload/DingTalk.app/DingTalk"
	@echo "  3. 重新打包 IPA → TrollStore 安装"

install: $(TARGET)
	@if [ ! -d "$(INSTALL_DIR)" ]; then \
		echo "❌ 错误: $(INSTALL_DIR) 不存在，请先解压 IPA"; \
		exit 1; \
	fi
	cp $(TARGET) "$(INSTALL_DIR)/"
	@if [ ! -f "$(INSTALL_DIR)/DingTalk_backup" ]; then \
		cp "$(INSTALL_DIR)/DingTalk" "$(INSTALL_DIR)/DingTalk_backup"; \
	fi
	@echo "🔧 注入 dylib..."
	insert_dylib "@executable_path/$(TARGET)" "$(INSTALL_DIR)/DingTalk_backup" --inplace --all-yes
	mv "$(INSTALL_DIR)/DingTalk_backup_patched" "$(INSTALL_DIR)/DingTalk" 2>/dev/null || true
	@echo "✅ 注入完成！重新打包:"
	@echo "   cd Payload && zip -r ../DingTalk_Hooked.ipa DingTalk.app/"

clean:
	rm -f $(TARGET)
	@echo "🧹 清理完成"

.PHONY: all install clean
