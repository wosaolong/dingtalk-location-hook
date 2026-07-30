//
//  test_inject.m — 极简测试 dylib，只输日志，不 hook 任何东西
//  用于先确认 TrollStore + inject_dylib 流程是否通畅
//
//  编译：
//    clang -shared -arch arm64 \
//          -isysroot $(xcrun --sdk iphoneos --show-sdk-path) \
//          -o test_inject.dylib test_inject.m
//

#import <Foundation/Foundation.h>

__attribute__((constructor))
static void TestInit() {
    NSLog(@"[TestInject] ========================================");
    NSLog(@"[TestInject] ✅ 插件加载成功！注入和加载流程通畅");
    NSLog(@"[TestInject] 📱 设备: %@", [[UIDevice currentDevice] model]);
    NSLog(@"[TestInject] 📋 iOS: %@", [[UIDevice currentDevice] systemVersion]);
    NSLog(@"[TestInject] ⏰ %@", [NSDate date]);
    NSLog(@"[TestInject] ========================================");
}
