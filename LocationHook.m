//
//  LocationHook.m — TrollFools 最终版
//  坐标硬编码 31.273598,121.463739 + 开关功能 + 区域监控拦截
//

#import <CoreLocation/CoreLocation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#define TARGET_LAT 31.273598
#define TARGET_LON 121.463739

// 开关 — 存储在 NSUserDefaults
static BOOL IsEnabled() {
    return [[NSUserDefaults standardUserDefaults] boolForKey:@"_FE"];
}
static void SetEnabled(BOOL v) {
    [[NSUserDefaults standardUserDefaults] setBool:v forKey:@"_FE"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

// ===== 假位置 =====
static CLLocation *FakeLoc() {
    CLLocation *loc = [[CLLocation alloc]
        initWithCoordinate:CLLocationCoordinate2DMake(TARGET_LAT, TARGET_LON)
        altitude:50 horizontalAccuracy:65 verticalAccuracy:10
        course:0 speed:0.5 timestamp:[NSDate date]];
    @try { [loc setValue:@NO forKey:@"isFromMockProvider"]; } @catch(id e){}
    @try { [loc setValue:@NO forKey:@"isSimulatedBySoftware"]; } @catch(id e){}
    return loc;
}

// ===== Swizzle =====
static void Swz(Class c, SEL o, SEL n) {
    Method om = class_getInstanceMethod(c, o);
    Method nm = class_getInstanceMethod(c, n);
    if (om && nm) method_exchangeImplementations(om, nm);
}

// ===== 动态代理 =====
static void SetupProxy(Class cls) {
    // locationManager:didUpdateLocations:
    class_addMethod(cls, @selector(locationManager:didUpdateLocations:),
        imp_implementationWithBlock(^(id _self, CLLocationManager *m, NSArray *l) {
            id od = objc_getAssociatedObject(_self, "od");
            if (!od || ![od respondsToSelector:@selector(locationManager:didUpdateLocations:)]) return;
            [od locationManager:m didUpdateLocations:IsEnabled() ? @[FakeLoc()] : l];
        }), "v@:@@");

    // locationManager:didDetermineState:forRegion: — 始终返回在区域内
    class_addMethod(cls, @selector(locationManager:didDetermineState:forRegion:),
        imp_implementationWithBlock(^(id _self, CLLocationManager *m, NSInteger st, id r) {
            id od = objc_getAssociatedObject(_self, "od");
            if (!od || ![od respondsToSelector:@selector(locationManager:didDetermineState:forRegion:)]) return;
            [od locationManager:m didDetermineState:IsEnabled() ? CLRegionStateInside : st forRegion:r];
        }), "v@:@q@");

    // locationManager:didFailWithError:
    class_addMethod(cls, @selector(locationManager:didFailWithError:),
        imp_implementationWithBlock(^(id _self, CLLocationManager *m, NSError *e) {
            id od = objc_getAssociatedObject(_self, "od");
            if (od && [od respondsToSelector:@selector(locationManager:didFailWithError:)])
                [od locationManager:m didFailWithError:e];
        }), "v@:@@");

    // locationManagerDidChangeAuthorization:
    class_addMethod(cls, @selector(locationManagerDidChangeAuthorization:),
        imp_implementationWithBlock(^(id _self, CLLocationManager *m) {
            id od = objc_getAssociatedObject(_self, "od");
            if (od && [od respondsToSelector:@selector(locationManagerDidChangeAuthorization:)])
                [od locationManagerDidChangeAuthorization:m];
        }), "v@:@");

    // forwardInvocation:
    class_addMethod(cls, @selector(forwardInvocation:),
        imp_implementationWithBlock(^(id _self, NSInvocation *inv) {
            id od = objc_getAssociatedObject(_self, "od");
            if (od && [od respondsToSelector:inv.selector]) [inv invokeWithTarget:od];
        }), "v@:@");

    // methodSignatureForSelector:
    class_addMethod(cls, @selector(methodSignatureForSelector:),
        imp_implementationWithBlock(^NSMethodSignature *(id _self, SEL sel) {
            return [objc_getAssociatedObject(_self, "od") methodSignatureForSelector:sel];
        }), "@@::");

    // respondsToSelector:
    class_addMethod(cls, @selector(respondsToSelector:),
        imp_implementationWithBlock(^BOOL(id _self, SEL sel) {
            return [objc_getAssociatedObject(_self, "od") respondsToSelector:sel];
        }), "B@::");
}

// ===== CLLocationManager Hook =====
@interface CLLocationManager (_F)
- (instancetype)_f_init;
- (void)_f_setDelegate:(id)d;
- (CLLocation *)_f_location;
@end
@implementation CLLocationManager (_F)
- (instancetype)_f_init {
    return [self _f_init];
}
- (void)_f_setDelegate:(id)d {
    static Class pc = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        pc = objc_allocateClassPair([NSObject class], "_F_P", 0);
        SetupProxy(pc);
        objc_registerClassPair(pc);
    });
    if (d && ![d isKindOfClass:pc]) {
        id p = [[pc alloc] init];
        objc_setAssociatedObject(p, "od", d, OBJC_ASSOCIATION_ASSIGN);
        objc_setAssociatedObject(self, "_pr", p, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [self _f_setDelegate:p];
        return;
    }
    [self _f_setDelegate:d];
}
- (CLLocation *)_f_location {
    return IsEnabled() ? FakeLoc() : [self _f_location];
}
@end

// ===== coordinate hook =====
static void InstallCoordHook() {
    Method m = class_getInstanceMethod([CLLocation class], @selector(coordinate));
    if (!m) return;
    IMP orig = method_getImplementation(m);
    method_setImplementation(m, imp_implementationWithBlock(^CLLocationCoordinate2D(id self) {
        if (!IsEnabled()) return ((CLLocationCoordinate2D(*)(id,SEL))orig)(self, @selector(coordinate));
        return CLLocationCoordinate2DMake(TARGET_LAT, TARGET_LON);
    }));
}

// ===== +load 入口 =====
@interface _F_L : NSObject @end
@implementation _F_L
+ (void)load {
    InstallCoordHook();
    Swz([CLLocationManager class], @selector(init), @selector(_f_init));
    Swz([CLLocationManager class], @selector(setDelegate:), @selector(_f_setDelegate:));
    Swz([CLLocationManager class], @selector(location), @selector(_f_location));

    dispatch_async(dispatch_get_main_queue(), ^{
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        CGFloat w = [UIScreen mainScreen].bounds.size.width;
        CGFloat h = [UIScreen mainScreen].bounds.size.height;
        b.frame = CGRectMake(w-65, h/2, 50, 50);
        b.backgroundColor = IsEnabled() ? [UIColor colorWithRed:0.2 green:0.5 blue:1.0 alpha:0.85] : [UIColor grayColor];
        b.layer.cornerRadius = 25;
        [b setTitle:@"📍" forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:22];
        [b addTarget:b action:@selector(_f_tap) forControlEvents:UIControlEventTouchUpInside];
        [[UIApplication sharedApplication].windows.firstObject addSubview:b];
    });
}
@end

// ===== UI 菜单 =====
@interface UIButton (_F) @end
@implementation UIButton (_F)
- (void)_f_tap {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"📍 虚拟定位"
        message:[NSString stringWithFormat:@"坐标: %.4f,%.4f\n状态: %@", TARGET_LAT, TARGET_LON, IsEnabled()?@"✅ 开启":@"❌ 关闭"]
        preferredStyle:UIAlertControllerStyleActionSheet];

    [a addAction:[UIAlertAction actionWithTitle:IsEnabled()?@"⏸ 暂停":@"▶️ 开启" style:0 handler:^(UIAlertAction *act) {
        SetEnabled(!IsEnabled());
        self.backgroundColor = IsEnabled() ? [UIColor colorWithRed:0.2 green:0.5 blue:1.0 alpha:0.85] : [UIColor grayColor];
    }]];

    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    a.popoverPresentationController.sourceView = self;
    a.popoverPresentationController.sourceRect = self.bounds;
    [[self window].rootViewController presentViewController:a animated:YES completion:nil];
}
@end
