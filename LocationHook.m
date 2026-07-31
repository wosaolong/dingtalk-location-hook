//
//  LocationHook.m — TrollFools 最终稳定版
//  解决核心问题：CoreLocation 可能晚于 dylib 加载，导致 hook 失败
//  方案：轮询等待 CLLocation 类可用后再安装 hook
//

#import <CoreLocation/CoreLocation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>

#define TARGET_LAT 31.273598
#define TARGET_LON 121.463739

// ===== 开关 =====
static BOOL IsOn() { return [[NSUserDefaults standardUserDefaults] boolForKey:@"_on"]; }
static void SetOn(BOOL v) { [[NSUserDefaults standardUserDefaults] setBool:v forKey:@"_on"]; [[NSUserDefaults standardUserDefaults] synchronize]; }

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

// ===== 原 IMP 存储 =====
static IMP orig_coordinate = NULL;
static IMP orig_location = NULL;
static IMP orig_setDelegate = NULL;

// ===== coordinate hook =====
static CLLocationCoordinate2D hook_coordinate(id self, SEL _cmd) {
    if (!IsOn()) return ((CLLocationCoordinate2D(*)(id,SEL))orig_coordinate)(self, _cmd);
    return CLLocationCoordinate2DMake(TARGET_LAT, TARGET_LON);
}

// ===== 模拟标记 hook（配合 SimLoc 或系统级模拟使用）=====
static BOOL hook_flag_no(id self, SEL _cmd) { return NO; }

// ===== CLLocationManager 方法 =====
static id hook_location(id self, SEL _cmd) {
    if (!IsOn()) return ((id(*)(id,SEL))orig_location)(self, _cmd);
    return FakeLoc();
}

// ===== delegate 代理 =====
static void hook_setDelegate(id self, SEL _cmd, id delegate) {
    if (delegate && !objc_getAssociatedObject(delegate, "isProxy")) {
        static Class pc = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            pc = objc_allocateClassPair([NSObject class], "_FP", 0);
            class_addMethod(pc, @selector(locationManager:didUpdateLocations:),
                imp_implementationWithBlock(^(id _s, CLLocationManager *m, NSArray *l) {
                    id od = objc_getAssociatedObject(_s, "od");
                    if (od && [od respondsToSelector:@selector(locationManager:didUpdateLocations:)])
                        [od locationManager:m didUpdateLocations:IsOn()?@[FakeLoc()]:l];
                }), "v@:@@");
            class_addMethod(pc, @selector(locationManager:didDetermineState:forRegion:),
                imp_implementationWithBlock(^(id _s, CLLocationManager *m, NSInteger st, id r) {
                    id od = objc_getAssociatedObject(_s, "od");
                    if (od && [od respondsToSelector:@selector(locationManager:didDetermineState:forRegion:)])
                        [od locationManager:m didDetermineState:IsOn()?CLRegionStateInside:st forRegion:r];
                }), "v@:@q@");
            class_addMethod(pc, @selector(forwardInvocation:),
                imp_implementationWithBlock(^(id _s, NSInvocation *inv) {
                    id od = objc_getAssociatedObject(_s, "od");
                    if (od && [od respondsToSelector:inv.selector]) [inv invokeWithTarget:od];
                }), "v@:@");
            class_addMethod(pc, @selector(methodSignatureForSelector:),
                imp_implementationWithBlock(^NSMethodSignature*(id _s, SEL sel) {
                    return [objc_getAssociatedObject(_s, "od") methodSignatureForSelector:sel];
                }), "@@::");
            class_addMethod(pc, @selector(respondsToSelector:),
                imp_implementationWithBlock(^BOOL(id _s, SEL sel) {
                    return [objc_getAssociatedObject(_s, "od") respondsToSelector:sel];
                }), "B@::");
            objc_registerClassPair(pc);
        });
        id proxy = [[pc alloc] init];
        objc_setAssociatedObject(proxy, "isProxy", @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(proxy, "od", delegate, OBJC_ASSOCIATION_ASSIGN);
        objc_setAssociatedObject(self, "_pr", proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ((void(*)(id,SEL,id))orig_setDelegate)(self, _cmd, proxy);
        return;
    }
    ((void(*)(id,SEL,id))orig_setDelegate)(self, _cmd, delegate);
}

// ============================================================
//  Hook 安装（带 CoreLocation 就绪检测）
// ============================================================

static BOOL s_hooksInstalled = NO;

static void InstallHooks() {
    Class cl = [CLLocation class];
    if (!cl) return;  // CoreLocation 未加载

    Class cm = [CLLocationManager class];
    if (!cm) return;

    // coordinate
    Method m1 = class_getInstanceMethod(cl, @selector(coordinate));
    if (m1 && !orig_coordinate) {
        orig_coordinate = method_getImplementation(m1);
        method_setImplementation(m1, (IMP)hook_coordinate);
    }

    // location
    Method m2 = class_getInstanceMethod(cm, @selector(location));
    if (m2 && !orig_location) {
        orig_location = method_getImplementation(m2);
        method_setImplementation(m2, (IMP)hook_location);
    }

    // setDelegate
    Method m3 = class_getInstanceMethod(cm, @selector(setDelegate:));
    if (m3 && !orig_setDelegate) {
        orig_setDelegate = method_getImplementation(m3);
        method_setImplementation(m3, (IMP)hook_setDelegate);
    }

    // 模拟标记 getter → 返回 NO（防止钉钉闪退）
    NSArray *flags = @[@"isSimulatedBySoftware", @"isFromMockProvider",
                       @"isProducedByAccessDevice", @"isLocationSimulated",
                       @"isLikelyFromLocationdSimulation"];
    for (NSString *n in flags) {
        SEL sel = NSSelectorFromString(n);
        Method fm = class_getInstanceMethod(cl, sel);
        if (fm) method_setImplementation(fm, (IMP)hook_flag_no);
    }

    s_hooksInstalled = YES;
}

// 轮询等待 CoreLocation 就绪（最多 15 秒）
static void EnsureHooks() {
    if (s_hooksInstalled) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        for (int i = 0; i < 30; i++) {
            if ([CLLocation class] && [CLLocationManager class]) {
                InstallHooks();
                break;
            }
            usleep(500000);  // 0.5s
        }
        // 最后一搏
        if (!s_hooksInstalled) InstallHooks();
    });
}

// ============================================================
//  入口
// ============================================================

__attribute__((constructor)) static void Init() {
    EnsureHooks();

    dispatch_async(dispatch_get_main_queue(), ^{
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        CGFloat w = [UIScreen mainScreen].bounds.size.width;
        CGFloat h = [UIScreen mainScreen].bounds.size.height;
        b.frame = CGRectMake(w-65, h/2, 50, 50);
        b.backgroundColor = IsOn() ? [UIColor colorWithRed:0.2 green:0.5 blue:1.0 alpha:0.85] : [UIColor grayColor];
        b.layer.cornerRadius = 25;
        [b setTitle:@"📍" forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:22];
        [b addTarget:b action:@selector(_f_tap) forControlEvents:UIControlEventTouchUpInside];
        [[UIApplication sharedApplication].windows.firstObject addSubview:b];
    });
}

// ===== UI 菜单 =====
@interface UIButton (_F) @end
@implementation UIButton (_F)
- (void)_f_tap {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"📍 虚拟定位"
        message:[NSString stringWithFormat:@"坐标: %.4f,%.4f\n状态: %@", TARGET_LAT, TARGET_LON, IsOn()?@"✅ 开启":@"❌ 关闭"]
        preferredStyle:UIAlertControllerStyleActionSheet];
    [a addAction:[UIAlertAction actionWithTitle:IsOn()?@"⏸ 暂停":@"▶️ 开启" style:0 handler:^(UIAlertAction *act) {
        SetOn(!IsOn());
        self.backgroundColor = IsOn() ? [UIColor blueColor] : [UIColor grayColor];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.sourceView = self;
    a.popoverPresentationController.sourceRect = self.bounds;
    [[self window].rootViewController presentViewController:a animated:YES completion:nil];
}
@end
