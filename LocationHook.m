//
//  LocationHook.m — 最终版
//  核心策略：hook init + 全路径覆盖，不依赖注入时机
//  坐标 31.273598, 121.463739（上海）
//

#import <CoreLocation/CoreLocation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#define TARGET_LAT 31.273598
#define TARGET_LON 121.463739

// ===== 假位置生成 =====
static CLLocation *FakeLoc() {
    CLLocation *loc = [[CLLocation alloc]
        initWithCoordinate:CLLocationCoordinate2DMake(TARGET_LAT, TARGET_LON)
        altitude:50 horizontalAccuracy:65 verticalAccuracy:10
        course:0 speed:0.5 timestamp:[NSDate date]];
    @try { [loc setValue:@NO forKey:@"isFromMockProvider"]; } @catch(id e){}
    @try { [loc setValue:@NO forKey:@"isSimulatedBySoftware"]; } @catch(id e){}
    return loc;
}

// ===== Swizzle 工具 =====
static void Swz(Class c, SEL o, SEL n) {
    Method om = class_getInstanceMethod(c, o);
    Method nm = class_getInstanceMethod(c, n);
    if (om && nm) method_exchangeImplementations(om, nm);
}
static void SetImp(Class c, SEL sel, IMP imp, IMP *orig) {
    Method m = class_getInstanceMethod(c, sel);
    if (m) { if(orig) *orig = method_getImplementation(m); method_setImplementation(m, imp); }
}

// ===== CLLocationManager 全面拦截 =====

@interface CLLocationManager (_F)
- (instancetype)_f_init;
- (void)_f_setDelegate:(id)d;
- (void)_f_startUpdatingLocation;
- (void)_f_requestLocation;
- (CLLocation *)_f_location;
@end

@implementation CLLocationManager (_F)

- (instancetype)_f_init {
    CLLocationManager *m = [self _f_init];
    // 确保任何已创建的实例的 delegate 被我们包裹
    // 注意：此时 delegate 可能已经设置了，但我们无法在这里修复
    // 需要依赖 setDelegate: hook 来捕获
    return m;
}

static void SetupProxyClass(Class proxyClass) {
    // locationManager:didUpdateLocations:
    class_addMethod(proxyClass, @selector(locationManager:didUpdateLocations:),
        imp_implementationWithBlock(^(id _self, CLLocationManager *mgr, NSArray *locs) {
            id origDel = objc_getAssociatedObject(_self, "origDel");
            if (origDel && [origDel respondsToSelector:@selector(locationManager:didUpdateLocations:)])
                [origDel locationManager:mgr didUpdateLocations:@[FakeLoc()]];
        }), "v@:@@");

    // respondsToSelector:
    class_addMethod(proxyClass, @selector(respondsToSelector:),
        imp_implementationWithBlock(^BOOL(id _self, SEL sel) {
            id origDel = objc_getAssociatedObject(_self, "origDel");
            return [origDel respondsToSelector:sel];
        }), "B@::");

    // forwardInvocation:
    class_addMethod(proxyClass, @selector(forwardInvocation:),
        imp_implementationWithBlock(^(id _self, NSInvocation *inv) {
            id origDel = objc_getAssociatedObject(_self, "origDel");
            if (origDel && [origDel respondsToSelector:inv.selector])
                [inv invokeWithTarget:origDel];
        }), "v@:@");

    // methodSignatureForSelector:
    class_addMethod(proxyClass, @selector(methodSignatureForSelector:),
        imp_implementationWithBlock(^NSMethodSignature *(id _self, SEL sel) {
            id origDel = objc_getAssociatedObject(_self, "origDel");
            return [origDel methodSignatureForSelector:sel];
        }), "@@::");
}

- (void)_f_setDelegate:(id)d {
    static Class proxyClass = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        proxyClass = objc_allocateClassPair([NSObject class], "_F_Proxy", 0);
        SetupProxyClass(proxyClass);
        objc_registerClassPair(proxyClass);
    });

    if (d && ![d isKindOfClass:proxyClass]) {
        id proxy = [[proxyClass alloc] init];
        objc_setAssociatedObject(proxy, "origDel", d, OBJC_ASSOCIATION_ASSIGN);
        [self _f_setDelegate:proxy];
        return;
    }
    [self _f_setDelegate:d];
}

- (void)_f_startUpdatingLocation {
    id del = [self valueForKey:@"delegate"];
    if ([del respondsToSelector:@selector(locationManager:didUpdateLocations:)])
        [del locationManager:self didUpdateLocations:@[FakeLoc()]];
}
- (void)_f_requestLocation { [self _f_startUpdatingLocation]; }
- (CLLocation *)_f_location { return FakeLoc(); }
@end

// ===== 直接 hook CLLocation.coordinate =====
static void InstallCoordHook() {
    SetImp([CLLocation class], @selector(coordinate),
           imp_implementationWithBlock(^CLLocationCoordinate2D(id self) {
               return CLLocationCoordinate2DMake(TARGET_LAT, TARGET_LON);
           }), NULL);
}

// ===== +load 入口 =====
@interface _F_Loader : NSObject @end
@implementation _F_Loader
+ (void)load {
    // 1. hook CLLocation.coordinate（最底层）
    InstallCoordHook();

    // 2. hook CLLocationManager init + 所有定位方法
    Swz([CLLocationManager class], @selector(init), @selector(_f_init));
    Swz([CLLocationManager class], @selector(setDelegate:), @selector(_f_setDelegate:));
    Swz([CLLocationManager class], @selector(startUpdatingLocation), @selector(_f_startUpdatingLocation));
    Swz([CLLocationManager class], @selector(requestLocation), @selector(_f_requestLocation));
    Swz([CLLocationManager class], @selector(location), @selector(_f_location));

    // 3. UI
    dispatch_async(dispatch_get_main_queue(), ^{
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        CGFloat w = [UIScreen mainScreen].bounds.size.width;
        CGFloat h = [UIScreen mainScreen].bounds.size.height;
        b.frame = CGRectMake(w-65, h/2, 50, 50);
        b.backgroundColor = [UIColor colorWithRed:0.2 green:0.5 blue:1.0 alpha:0.85];
        b.layer.cornerRadius = 25;
        [b setTitle:@"📍" forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:22];
        [[UIApplication sharedApplication].windows.firstObject addSubview:b];
    });
}
@end
