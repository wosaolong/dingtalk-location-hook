//
//  LocationHook.m — 加固版 v2
//  钉钉虚拟定位插件 — 主入口
//  特性：定位参数随机化、fishhook dyld 反检测、零日志、加密配置
//

#import <CoreLocation/CoreLocation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#include <pthread.h>
#import "ConfigManager.h"
#import "fishhook.h"

// 编译开关 — 发布版（DNDEBUG）不输出日志
#ifdef DEBUG
  #define HOOK_LOG(fmt, ...) NSLog(@fmt, ##__VA_ARGS__)
#else
  #define HOOK_LOG(fmt, ...) ((void)0)
#endif

// ============================================================
//  dyld 反检测 — 使用 fishhook 隐藏 dylib
// ============================================================

static const char *s_hookDylibPath = NULL;

/// 获取当前 dylib 自身路径（通过 dladdr 取回）
static const char *getMyDylibPath() {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Dl_info info;
        if (dladdr(getMyDylibPath, &info) && info.dli_fname) {
            s_hookDylibPath = strdup(info.dli_fname);
        }
    });
    return s_hookDylibPath;
}

/// 替代 _dyld_get_image_name — 若返回我们 dylib 的路径则替换为主程序路径
static char *s_original_dyld_get_image_name = NULL;
static char *my_dyld_get_image_name(uint32_t image_index) {
    // 调用原始函数
    char *(*orig)(uint32_t) = (char *(*)(uint32_t))s_original_dyld_get_image_name;
    char *name = orig(image_index);
    if (!name) return name;

    const char *myPath = getMyDylibPath();
    if (myPath && strstr(name, myPath)) {
        // 伪装成主程序
        static char *mainPath = NULL;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            uint32_t cnt = _dyld_image_count();
            for (uint32_t i = 0; i < cnt; i++) {
                const char *p = orig(i);
                if (p && strstr(p, ".app/")) {
                    // 找到主程序路径（通常是第一个 .app/ 路径）
                    // 排除自身
                    if (!myPath || !strstr(p, myPath)) {
                        mainPath = strdup(p);
                        break;
                    }
                }
            }
            if (!mainPath) mainPath = strdup("/usr/lib/libSystem.B.dylib");
        });
        return mainPath;
    }
    return name;
}

/// 替代 dladdr — 若地址落在本 dylib 范围内则返回主程序信息
static int (*s_original_dladdr)(const void *, Dl_info *) = NULL;
static int my_dladdr(const void *addr, Dl_info *info) {
    int ret = s_original_dladdr(addr, info);
    if (ret && info->dli_fname) {
        const char *myPath = getMyDylibPath();
        if (myPath && strstr(info->dli_fname, myPath)) {
            // 伪装为主程序
            static const char *mainPath = NULL;
            static dispatch_once_t once;
            dispatch_once(&once, ^{
                Dl_info mainInfo;
                if (dladdr(getMyDylibPath, &mainInfo) && mainInfo.dli_fname) {
                    // 找主程序路径：通常是第一个含 .app/ 且不是我们的
                    uint32_t cnt = _dyld_image_count();
                    for (uint32_t i = 0; i < cnt; i++) {
                        const char *p = _dyld_get_image_name(i);
                        if (p && strstr(p, ".app/") && strcmp(p, myPath) != 0) {
                            mainPath = strdup(p);
                            break;
                        }
                    }
                    if (!mainPath) mainPath = strdup("/usr/lib/libSystem.B.dylib");
                }
            });
            if (mainPath) info->dli_fname = mainPath;
        }
    }
    return ret;
}

/// 安装 dyld 隐藏
static void installDyldHide() {
    // 先触发一次绑定，确保符号可用
    _dyld_get_image_name(0);

    struct rebinding bindings[] = {
        {
            .name = "_dyld_get_image_name",
            .replacement = (void *)my_dyld_get_image_name,
            .replaced = (void **)&s_original_dyld_get_image_name,
        },
        {
            .name = "dladdr",
            .replacement = (void *)my_dladdr,
            .replaced = (void **)&s_original_dladdr,
        },
    };

    int ret = rebind_symbols(bindings, 2);
    HOOK_LOG(@"dyld 反检测安装: %s", ret == 0 ? "OK" : "FAIL");
}

// ============================================================
//  安全的 Method Swizzling
// ============================================================

static BOOL SafeSwizzle(Class cls, SEL original, SEL swizzled) {
    Method origMethod = class_getInstanceMethod(cls, original);
    Method newMethod = class_getInstanceMethod(cls, swizzled);
    if (!origMethod || !newMethod) return NO;

    BOOL didAdd = class_addMethod(cls, original,
                                  method_getImplementation(newMethod),
                                  method_getTypeEncoding(newMethod));
    if (didAdd) {
        class_replaceMethod(cls, swizzled,
                            method_getImplementation(origMethod),
                            method_getTypeEncoding(origMethod));
    } else {
        method_exchangeImplementations(origMethod, newMethod);
    }
    return YES;
}

// ============================================================
//  定位参数随机化
// ============================================================

/// 给坐标加微小随机漂移
static CLLocationCoordinate2D JitterCoordinate(CLLocationCoordinate2D base) {
    double latOff = ((double)arc4random_uniform(1000) / 1000000.0) - 0.0005;
    double lonOff = ((double)arc4random_uniform(1000) / 1000000.0) - 0.0005;
    return CLLocationCoordinate2DMake(base.latitude + latOff, base.longitude + lonOff);
}

static CLLocationAccuracy RandAccuracy() {
    return 30 + arc4random_uniform(100);  // 30~130
}

static CLLocationSpeed RandSpeed() {
    // 70% 低速 ~1.0，30% 稍快
    if (arc4random_uniform(100) < 70)
        return (CLLocationSpeed)arc4random_uniform(120) / 100.0;
    return 1.2 + (CLLocationSpeed)arc4random_uniform(150) / 100.0;
}

static CLLocationDirection RandCourse() {
    return (CLLocationDirection)arc4random_uniform(360);
}

/// 制造干净假位置
static CLLocation *MakeFakeLocation() {
    ConfigManager *cfg = [ConfigManager shared];
    CLLocationCoordinate2D base = CLLocationCoordinate2DMake(cfg.targetLatitude, cfg.targetLongitude);
    CLLocationCoordinate2D jittered = JitterCoordinate(base);

    CLLocation *loc = [[CLLocation alloc] initWithCoordinate:jittered
                                                    altitude:cfg.targetAltitude
                                          horizontalAccuracy:RandAccuracy()
                                            verticalAccuracy:30 + arc4random_uniform(60)
                                                      course:RandCourse()
                                                       speed:RandSpeed()
                                                   timestamp:[NSDate date]];

    @autoreleasepool {
        for (NSString *key in @[@"isFromMockProvider", @"isSimulatedBySoftware",
                                @"matchInfo", @"trustedTimestamp",
                                @"detectedByGpsOverride", @"isProducedByAccessDevice",
                                @"isLikelyFromLocationdSimulation"]) {
            @try { [loc setValue:@NO forKey:key]; } @catch(NSException *e) {}
        }
    }
    return loc;
}

// ============================================================
//  中间代理
// ============================================================

@interface LocationInterceptor : NSObject <CLLocationManagerDelegate>
@property (nonatomic, weak) id<CLLocationManagerDelegate> originalDelegate;
@end

@implementation LocationInterceptor

- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray *)locations {
    if (!self.originalDelegate) return;
    if (![ConfigManager shared].isEnabled) {
        if ([self.originalDelegate respondsToSelector:@selector(locationManager:didUpdateLocations:)])
            [self.originalDelegate locationManager:manager didUpdateLocations:locations];
        return;
    }

    CLLocation *fake = nil;
    @try { fake = MakeFakeLocation(); } @catch(NSException *e) { fake = locations.firstObject; }
    if ([self.originalDelegate respondsToSelector:@selector(locationManager:didUpdateLocations:)])
        [self.originalDelegate locationManager:manager didUpdateLocations:@[fake]];
}

- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error {
    if (self.originalDelegate && [self.originalDelegate respondsToSelector:_cmd])
        [self.originalDelegate locationManager:manager didFailWithError:error];
}

- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)manager {
    if (self.originalDelegate && [self.originalDelegate respondsToSelector:_cmd])
        [self.originalDelegate locationManagerDidChangeAuthorization:manager];
    else if (self.originalDelegate && [self.originalDelegate respondsToSelector:@selector(locationManager:didChangeAuthorizationStatus:)]) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [self.originalDelegate locationManager:manager didChangeAuthorizationStatus:[manager authorizationStatus]];
        #pragma clang diagnostic pop
    }
}

- (BOOL)respondsToSelector:(SEL)aSelector {
    if ([super respondsToSelector:aSelector]) return YES;
    return [self.originalDelegate respondsToSelector:aSelector];
}
- (id)forwardingTargetForSelector:(SEL)aSelector {
    return self.originalDelegate;
}

@end

// ============================================================
//  CLLocationManager Hook
// ============================================================

static NSMapTable *s_interceptorMap = nil;

@interface CLLocationManager (Hook)
- (void)hk_setDelegate:(id<CLLocationManagerDelegate>)d;
- (void)hk_startUpdatingLocation;
- (void)hk_stopUpdatingLocation;
- (void)hk_requestLocation;
@end

@implementation CLLocationManager (Hook)

- (void)hk_setDelegate:(id<CLLocationManagerDelegate>)d {
    if (!d || [d isKindOfClass:[LocationInterceptor class]]) {
        [self hk_setDelegate:d];
        return;
    }

    LocationInterceptor *inter = [LocationInterceptor new];
    inter.originalDelegate = d;

    static dispatch_once_t once;
    dispatch_once(&once, ^{ s_interceptorMap = [NSMapTable weakToStrongObjectsMapTable]; });
    @synchronized (s_interceptorMap) { [s_interceptorMap setObject:inter forKey:self]; }

    [self hk_setDelegate:(id<CLLocationManagerDelegate>)inter];
}

- (void)hk_startUpdatingLocation { [self hk_startUpdatingLocation]; }
- (void)hk_stopUpdatingLocation {
    @synchronized (s_interceptorMap) { [s_interceptorMap removeObjectForKey:self]; }
    [self hk_stopUpdatingLocation];
}
- (void)hk_requestLocation { [self hk_requestLocation]; }

@end

// ============================================================
//  入口
// ============================================================

__attribute__((constructor))
static void Init() {
    @autoreleasepool {
        [ConfigManager shared];  // 触发初始化

        installDyldHide();

        SafeSwizzle([CLLocationManager class], @selector(setDelegate:), @selector(hk_setDelegate:));
        SafeSwizzle([CLLocationManager class], @selector(startUpdatingLocation), @selector(hk_startUpdatingLocation));
        SafeSwizzle([CLLocationManager class], @selector(stopUpdatingLocation), @selector(hk_stopUpdatingLocation));
        SafeSwizzle([CLLocationManager class], @selector(requestLocation), @selector(hk_requestLocation));

        dispatch_async(dispatch_get_main_queue(), ^{
            Class cls = NSClassFromString(@"FloatingMenuManager");
            if (cls) {
                id mgr = [cls shared];
                SEL sel = NSSelectorFromString(@"delayedInit");
                if ([mgr respondsToSelector:sel]) {
                    ((void (*)(id, SEL))[mgr methodForSelector:sel])(mgr, sel);
                }
            }

            [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                              object:nil queue:[NSOperationQueue mainQueue]
                                                          usingBlock:^(NSNotification *n) {
                [ConfigManager.shared parseFromPasteboard];
            }];
        });

        HOOK_LOG(@"✅ 加载完成");
    }
}
