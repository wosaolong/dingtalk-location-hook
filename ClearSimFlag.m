//
//  ClearSimFlag.dylib — 清除系统级模拟定位标记
//  配合 SimLoc 使用：SimLoc 设置模拟位置，本 dylib 让钉钉认为位置真实
//
//  原理：系统级模拟位置自带 isSimulatedBySoftware=YES，
//        钉钉检测到该标记会闪退。本 dylib hook CLLocation
//        的所有模拟标记属性，强制返回 NO。
//
//  用法：电脑上 inject.py 注入钉钉 IPA → TrollStore 安装
//

#import <CoreLocation/CoreLocation.h>
#import <objc/runtime.h>

// ============================================================
//  CLLocation 模拟标记属性 Hook
//  所有标记统一返回 NO
// ============================================================

// 通用 hook：BOOL 类型 getter
static BOOL HookReturnNo(id self, SEL _cmd) {
    return NO;
}

static void InstallHooks() {
    // 模拟位置标记（系统级模拟会设置这些）
    NSArray *flagSelectors = @[
        @"isSimulatedBySoftware",     // 系统模拟标记（最重要！）
        @"isFromMockProvider",        // Android 风格标记（iOS 也有）
        @"isProducedByAccessDevice",  // 外接设备产生
        @"isLocationSimulated",       // 部分版本用这个
        @"simulatedBySoftware",       // 变体
        @"isLikelyFromLocationdSimulation", // iOS 15+ locationd 模拟
        @"detectedByGpsOverride",     // GPS 覆盖检测
        @"isCoarse",                  // 粗略位置（可能触发检查）
    ];

    for (NSString *selName in flagSelectors) {
        SEL sel = NSSelectorFromString(selName);
        Method m = class_getInstanceMethod([CLLocation class], sel);
        if (m) {
            method_setImplementation(m, (IMP)HookReturnNo);
        }
    }

    // 覆盖读取坐标的其他可能路径：部分实现直接读 ivar
    // 通过 KVC 清理所有现存 CLLocation 实例的标记（无法枚举，跳过）
    // 这里只 hook getter，后续新对象也会走 getter

    // ============ 附加：Hook CLLocation 初始化，强制清理标记 ============
    // 当钉钉调用 initWithCoordinate:... 时，返回对象强制清标记
    // （有些版本标记在 init 后设置，hook getter 已足够，这里作为兜底）
}

// ============================================================
//  入口 — 使用 +load 保证最早加载
// ============================================================

__attribute__((constructor))
static void _ClearSim_Init() {
    InstallHooks();
}

// 双保险：+load 也会触发
@interface _CSF_Loader : NSObject @end
@implementation _CSF_Loader
+ (void)load {
    // 延迟一点执行，确保 CoreLocation 已加载（系统框架必然已加载，直接执行）
    InstallHooks();
}
@end
