# Makefile — 钉钉虚拟定位注入插件编译脚本

SDKROOT ?= $(shell xcrun --sdk iphoneos --show-sdk-path 2>/dev/null)
ARCH    ?= arm64
TARGET  ?= LocationHook.dylib
SOURCES  = LocationHook.m

CC = $(shell xcrun --find clang 2>/dev/null || echo "clang")

CFLAGS = -shared \
         -arch $(ARCH) \
         -isysroot "$(SDKROOT)" \
         -framework Foundation \
         -framework CoreLocation \
         -framework UIKit \
         -fobjc-arc \
         -O2 \
         -DNDEBUG \
         -dynamiclib \
         -miphoneos-version-min=14.0

INSTALL_DIR ?= ./Payload/DingTalk.app

all: $(TARGET)

$(TARGET): $(SOURCES)
	@echo "📦 编译 $(TARGET) ..."
	@if [ -z "$(SDKROOT)" ]; then \
		echo "❌ 错误：找不到 iOS SDK，请确保已安装 Xcode"; \
		exit 1; \
	fi
	$(CC) $(CFLAGS) -o "$@" $(SOURCES)
	@echo "✅ 编译成功: $(TARGET)"
	@file $(TARGET)

clean:
	rm -f $(TARGET)
	@echo "🧹 清理完成"

.PHONY: all clean
