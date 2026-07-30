//
//  LocationHook.m — 极简硬编码版
//  坐标：31.273598, 121.463739（上海）
//  只用 `+load` 入口，兼容 TrollFools
//

#import <CoreLocation/CoreLocation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#define TARGET_LAT 31.273598
#define TARGET_LON 121.463739

// ===== Hook CLLocation.coordinate =====
// 当任何代码读取 location.coordinate 时，返回我们的坐标

static CLLocationCoordinate2D (*orig_coord)(id, SEL);
static CLLocationCoordinate2D hook_coord(id self, SEL _cmd) {
    return CLLocationCoordinate2DMake(TARGET_LAT, TARGET_LON);
}

// ===== Hook startUpdatingLocation / requestLocation =====
// 阻断真实 GPS，直接回调假位置

static void Swz(Class c, SEL o, SEL n) {
    Method om = class_getInstanceMethod(c, o);
    Method nm = class_getInstanceMethod(c, n);
    if (om && nm) method_exchangeImplementations(om, nm);
}

@interface CLLocationManager (_H)
- (void)_h_startUpdatingLocation;
- (void)_h_requestLocation;
- (CLLocation *)_h_location;
@end
@implementation CLLocationManager (_H)

// 生成假位置
static CLLocation *FakeLoc() {
    CLLocation *loc = [[CLLocation alloc]
        initWithCoordinate:CLLocationCoordinate2DMake(TARGET_LAT, TARGET_LON)
        altitude:50 horizontalAccuracy:65 verticalAccuracy:10
        course:0 speed:0.5 timestamp:[NSDate date]];
    @try { [loc setValue:@NO forKey:@"isFromMockProvider"]; } @catch(id e){}
    @try { [loc setValue:@NO forKey:@"isSimulatedBySoftware"]; } @catch(id e){}
    return loc;
}

- (void)_h_startUpdatingLocation {
    id del = [self valueForKey:@"delegate"];
    if ([del respondsToSelector:@selector(locationManager:didUpdateLocations:)])
        [del locationManager:self didUpdateLocations:@[FakeLoc()]];
}
- (void)_h_requestLocation {
    [self _h_startUpdatingLocation];
}
- (CLLocation *)_h_location {
    // 覆盖 location 属性，直接返回假位置
    return FakeLoc();
}

@end

// ===== +load 入口（TrollFools 兼容） =====

@interface _LH_Init : NSObject @end
@implementation _LH_Init
+ (void)load {
    // 1. Hook coordinate getter
    Method m = class_getInstanceMethod([CLLocation class], @selector(coordinate));
    if (m) {
        orig_coord = (void*)method_getImplementation(m);
        method_setImplementation(m, (IMP)hook_coord);
    }

    // 2. Hook 定位启停 + location 属性
    Swz([CLLocationManager class], @selector(startUpdatingLocation), @selector(_h_startUpdatingLocation));
    Swz([CLLocationManager class], @selector(requestLocation), @selector(_h_requestLocation));
    Swz([CLLocationManager class], @selector(location), @selector(_h_location));

    // 3. 显示 UI 按钮
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
