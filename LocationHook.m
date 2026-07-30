//
//  LocationHook.m
//  钉钉虚拟定位插件 — 主入口
//
//  编译方式（在 Mac 上）：
//    make
//    或手动: clang -shared -framework Foundation -framework CoreLocation \
//                  -framework UIKit -framework UserNotifications \
//                  -arch arm64 -isysroot $(xcrun --sdk iphoneos --show-sdk-path) \
//                  -o LocationHook.dylib LocationHook.m ConfigManager.m FloatingMenu.m
//

#import <CoreLocation/CoreLocation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "ConfigManager.h"

// 前向声明 FloatingMenuManager（避免 import 整个 .m）
@interface FloatingMenuManager : NSObject
+ (instancetype)shared;
- (void)delayedInit;
@end

// ============================================================
//  中间代理类 — 拦截定位回调并注入假坐标
// ============================================================

@interface LocationInterceptor : NSObject <CLLocationManagerDelegate>
@property (nonatomic, weak) id<CLLocationManagerDelegate> originalDelegate;
@property (nonatomic, weak) CLLocationManager *manager;
@end

@implementation LocationInterceptor

/// 制造一个"干净"的假位置 — 清除所有模拟标记
- (CLLocation *)cleanFakeLocation {
    ConfigManager *cfg = [ConfigManager shared];

    CLLocationCoordinate2D coord = CLLocationCoordinate2DMake(cfg.targetLatitude, cfg.targetLongitude);
    NSDate *now = [NSDate date];

    CLLocationAccuracy hAccuracy = 65.0;
    CLLocationAccuracy vAccuracy = 10.0;
    CLLocationSpeed speed = 0.5;
    CLLocationDirection course = 0;

    CLLocation *fakeLoc = [[CLLocation alloc] initWithCoordinate:coord
                                                        altitude:cfg.targetAltitude
                                              horizontalAccuracy:hAccuracy
                                                verticalAccuracy:vAccuracy
                                                          course:course
                                                           speed:speed
                                                       timestamp:now];

    // 清除所有模拟定位标记
    @try {
        NSArray *cleanKeys = @[
            @"isFromMockProvider",
            @"isSimulatedBySoftware",
            @"matchInfo",
            @"trustedTimestamp",
            @"detectedByGpsOverride",
            @"isProducedByAccessDevice",
            @"isLikelyFromLocationdSimulation",
            @"simulatedBy",
            @"isLocationSimulated",
        ];
        for (NSString *key in cleanKeys) {
            @try {
                [fakeLoc setValue:@NO forKey:key];
            } @catch (NSException *e) {
                // key 不存在就跳过
            }
        }
    } @catch (NSException *e) {
        NSLog(@"[LocationHook] 清除模拟标记时出错: %@", e.reason);
    }

    return fakeLoc;
}

/// 拦截定位回调 — 替换坐标并转发
- (void)locationManager:(CLLocationManager *)manager
     didUpdateLocations:(NSArray<CLLocation *> *)locations {

    // 如果虚拟定位被禁用，直接转发原始数据
    if (![ConfigManager shared].isEnabled) {
        if (self.originalDelegate && [self.originalDelegate respondsToSelector:@selector(locationManager:didUpdateLocations:)]) {
            [self.originalDelegate locationManager:manager didUpdateLocations:locations];
        }
        return;
    }

    CLLocation *fakeLocation = [self cleanFakeLocation];

    NSLog(@"[LocationHook] 📍 拦截定位 → 注入: %.4f, %.4f (原始: %@)",
          [ConfigManager shared].targetLatitude,
          [ConfigManager shared].targetLongitude,
          locations.firstObject);

    if (self.originalDelegate && [self.originalDelegate respondsToSelector:@selector(locationManager:didUpdateLocations:)]) {
        [self.originalDelegate locationManager:manager didUpdateLocations:@[fakeLocation]];
    } else if (self.originalDelegate && [self.originalDelegate respondsToSelector:@selector(locationManager:didUpdateToLocation:fromLocation:)]) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Wdeprecated-declarations"
        #pragma clang diagnostic ignored "-Wnonnull"
        [self.originalDelegate locationManager:manager didUpdateToLocation:fakeLocation fromLocation:nil];
        #pragma clang diagnostic pop
    }
}

/// 透传其他回调
- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error {
    if (self.originalDelegate && [self.originalDelegate respondsToSelector:@selector(locationManager:didFailWithError:)]) {
        [self.originalDelegate locationManager:manager didFailWithError:error];
    }
}

- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)manager {
    CLAuthorizationStatus status = [manager authorizationStatus];
    if (self.originalDelegate && [self.originalDelegate respondsToSelector:@selector(locationManagerDidChangeAuthorization:)]) {
        [self.originalDelegate locationManagerDidChangeAuthorization:manager];
    } else if (self.originalDelegate && [self.originalDelegate respondsToSelector:@selector(locationManager:didChangeAuthorizationStatus:)]) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [self.originalDelegate locationManager:manager didChangeAuthorizationStatus:status];
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
//  Method Swizzling 工具
// ============================================================

static void SwizzleInstanceMethod(Class cls, SEL original, SEL swizzled) {
    Method origMethod = class_getInstanceMethod(cls, original);
    Method newMethod = class_getInstanceMethod(cls, swizzled);
    if (!origMethod || !newMethod) {
        NSLog(@"[LocationHook] Swizzle 失败: %@/%@", NSStringFromSelector(original), NSStringFromSelector(swizzled));
        return;
    }
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
}

// ============================================================
//  CLLocationManager Hook
// ============================================================

static NSMutableDictionary *_interceptorMap = nil;

@interface CLLocationManager (Hook)
- (void)hook_setDelegate:(id<CLLocationManagerDelegate>)delegate;
- (void)hook_startUpdatingLocation;
- (void)hook_stopUpdatingLocation;
@end

@implementation CLLocationManager (Hook)

- (void)hook_setDelegate:(id<CLLocationManagerDelegate>)delegate {
    if (delegate == nil) {
        [self hook_setDelegate:nil];
        return;
    }

    LocationInterceptor *interceptor = [[LocationInterceptor alloc] init];
    interceptor.originalDelegate = delegate;
    interceptor.manager = self;

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _interceptorMap = [NSMutableDictionary new];
    });

    NSString *key = [NSString stringWithFormat:@"%p", self];
    @synchronized (_interceptorMap) {
        _interceptorMap[key] = interceptor;
    }

    [self hook_setDelegate:(id<CLLocationManagerDelegate>)interceptor];
}

- (void)hook_startUpdatingLocation {
    NSLog(@"[LocationHook] 拦截 startUpdatingLocation");
    [self hook_startUpdatingLocation];
}

- (void)hook_stopUpdatingLocation {
    NSString *key = [NSString stringWithFormat:@"%p", self];
    @synchronized (_interceptorMap) {
        [_interceptorMap removeObjectForKey:key];
    }
    [self hook_stopUpdatingLocation];
}

@end

// ============================================================
//  动态库入口
// ============================================================

__attribute__((constructor))
static void LocationHookInit() {
    @autoreleasepool {
        NSLog(@"[LocationHook] ========================================");
        NSLog(@"[LocationHook] 钉钉虚拟定位插件 v2.0 (带配置界面)");
        ConfigManager *cfg = [ConfigManager shared];
        NSLog(@"[LocationHook] 当前坐标: %.4f, %.4f", cfg.targetLatitude, cfg.targetLongitude);
        NSLog(@"[LocationHook] 状态: %@", cfg.isEnabled ? @"已启用" : @"已禁用");
        NSLog(@"[LocationHook] ========================================");

        // 1. Hook CLLocationManager.setDelegate:
        SwizzleInstanceMethod([CLLocationManager class],
                              @selector(setDelegate:),
                              @selector(hook_setDelegate:));

        // 2. Hook start/stopUpdatingLocation
        SwizzleInstanceMethod([CLLocationManager class],
                              @selector(startUpdatingLocation),
                              @selector(hook_startUpdatingLocation));

        SwizzleInstanceMethod([CLLocationManager class],
                              @selector(stopUpdatingLocation),
                              @selector(hook_stopUpdatingLocation));

        NSLog(@"[LocationHook] 定位 Hook 注册完成 ✓");

        // 3. 延迟启动 UI（等待钉钉 UI 加载完成）
        dispatch_async(dispatch_get_main_queue(), ^{
            // 导入 FloatingMenuManager 并初始化 UI
            // 使用 NSClassFromString 避免编译依赖
            Class menuMgrClass = NSClassFromString(@"FloatingMenuManager");
            if (menuMgrClass) {
                id menuMgr = [menuMgrClass shared];
                SEL sel = NSSelectorFromString(@"delayedInit");
                if ([menuMgr respondsToSelector:sel]) {
                    ((void (*)(id, SEL))[menuMgr methodForSelector:sel])(menuMgr, sel);
                }
            }

            // 启动剪贴板监听
            // 使用 NSNotificationCenter 注册应用激活通知
            [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification * _Nonnull note) {
                // 每次应用激活时检查剪贴板
            }];
            NSLog(@"[LocationHook] UI 初始化已调度");
        });

        NSLog(@"[LocationHook] 插件加载完成 ✓");
        NSLog(@"[LocationHook] ⚠️ 本插件仅用于技术研究，请遵守相关法律法规");
    }
}
