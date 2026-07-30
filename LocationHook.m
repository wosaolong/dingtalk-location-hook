//
//  LocationHook.m — MSHookMessageEx 方案
//  使用 CydiaSubstrate 的 MSHookMessageEx（如果可用）
//  回退到 method_setImplementation
//

#import <CoreLocation/CoreLocation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>

#define TARGET_LAT 31.273598
#define TARGET_LON 121.463739

// ===== MSHookMessageEx（动态查找） =====
static void (*s_MSHookMessageEx)(Class, SEL, IMP, IMP *) = NULL;

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

// 开关
static BOOL IsOn() { return [[NSUserDefaults standardUserDefaults] boolForKey:@"_on"]; }
static void SetOn(BOOL v) { [[NSUserDefaults standardUserDefaults] setBool:v forKey:@"_on"]; [[NSUserDefaults standardUserDefaults] synchronize]; }

// ===== 原始 IMP 存储 =====
static IMP orig_setDelegate = NULL;
static IMP orig_startUpdate = NULL;
static IMP orig_requestLoc = NULL;
static IMP orig_location = NULL;
static IMP orig_coordinate = NULL;

// ===== 替换实现 =====
static void hook_setDelegate(id self, SEL _cmd, id delegate) {
    if (delegate && ![delegate isKindOfClass:NSClassFromString(@"_F_P")]) {
        static Class pc = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            pc = objc_allocateClassPair([NSObject class], "_F_P", 0);
            // locationManager:didUpdateLocations:
            class_addMethod(pc, @selector(locationManager:didUpdateLocations:),
                imp_implementationWithBlock(^(id _s, CLLocationManager *m, NSArray *l) {
                    id od = objc_getAssociatedObject(_s, "od");
                    if (od && [od respondsToSelector:@selector(locationManager:didUpdateLocations:)])
                        [od locationManager:m didUpdateLocations:IsOn()?@[FakeLoc()]:l];
                }), "v@:@@");
            // locationManager:didDetermineState:forRegion:
            class_addMethod(pc, @selector(locationManager:didDetermineState:forRegion:),
                imp_implementationWithBlock(^(id _s, CLLocationManager *m, NSInteger st, id r) {
                    id od = objc_getAssociatedObject(_s, "od");
                    if (od && [od respondsToSelector:@selector(locationManager:didDetermineState:forRegion:)])
                        [od locationManager:m didDetermineState:IsOn()?CLRegionStateInside:st forRegion:r];
                }), "v@:@q@");
            // forwardInvocation:
            class_addMethod(pc, @selector(forwardInvocation:),
                imp_implementationWithBlock(^(id _s, NSInvocation *inv) {
                    id od = objc_getAssociatedObject(_s, "od");
                    if (od && [od respondsToSelector:inv.selector]) [inv invokeWithTarget:od];
                }), "v@:@");
            class_addMethod(pc, @selector(methodSignatureForSelector:),
                imp_implementationWithBlock(^NSMethodSignature*(id _s, SEL sel) {
                    return [objc_getAssociatedObject(_s, "od") methodSignatureForSelector:sel];
                }), "@@::");
            objc_registerClassPair(pc);
        });
        id proxy = [[pc alloc] init];
        objc_setAssociatedObject(proxy, "od", delegate, OBJC_ASSOCIATION_ASSIGN);
        objc_setAssociatedObject(self, "_pr", proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ((void(*)(id,SEL,id))orig_setDelegate)(self, _cmd, proxy);
        return;
    }
    ((void(*)(id,SEL,id))orig_setDelegate)(self, _cmd, delegate);
}

static void hook_startUpdate(id self, SEL _cmd) {
    // 不阻断
    ((void(*)(id,SEL))orig_startUpdate)(self, _cmd);
}

static void hook_requestLoc(id self, SEL _cmd) {
    ((void(*)(id,SEL))orig_requestLoc)(self, _cmd);
}

static id hook_location(id self, SEL _cmd) {
    return IsOn() ? FakeLoc() : ((id(*)(id,SEL))orig_location)(self, _cmd);
}

static CLLocationCoordinate2D hook_coordinate(id self, SEL _cmd) {
    if (!IsOn()) return ((CLLocationCoordinate2D(*)(id,SEL))orig_coordinate)(self, _cmd);
    return CLLocationCoordinate2DMake(TARGET_LAT, TARGET_LON);
}

// ===== 安装 Hook =====
static void DoHook(Class cls, SEL sel, IMP hook, IMP *orig) {
    if (s_MSHookMessageEx) {
        s_MSHookMessageEx(cls, sel, hook, orig);
    } else {
        Method m = class_getInstanceMethod(cls, sel);
        if (m) { if (orig) *orig = method_getImplementation(m); method_setImplementation(m, hook); }
    }
}

static void InstallAll() {
    s_MSHookMessageEx = dlsym(RTLD_DEFAULT, "MSHookMessageEx");

    DoHook([CLLocationManager class], @selector(setDelegate:), (IMP)hook_setDelegate, &orig_setDelegate);
    DoHook([CLLocationManager class], @selector(startUpdatingLocation), (IMP)hook_startUpdate, &orig_startUpdate);
    DoHook([CLLocationManager class], @selector(requestLocation), (IMP)hook_requestLoc, &orig_requestLoc);
    DoHook([CLLocationManager class], @selector(location), (IMP)hook_location, &orig_location);
    DoHook([CLLocation class], @selector(coordinate), (IMP)hook_coordinate, &orig_coordinate);
}

// ===== +load 入口 =====
@interface _F_L : NSObject @end
@implementation _F_L
+ (void)load {
    InstallAll();

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
@end

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
