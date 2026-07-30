//
//  LocationHook.m — TrollFools 适配版 v3
//  三重 hook 策略 + 立即初始化
//

#import <CoreLocation/CoreLocation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ============================================================
//  配置
// ============================================================

@interface _LH_Config : NSObject
@property double lat, lon;
@property BOOL enabled;
+ (instancetype)shared;
- (void)save;
@end

@implementation _LH_Config
+ (instancetype)shared {
    static id s;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ s = [[self alloc] init]; });
    return s;
}
- (instancetype)init {
    if (self = [super init]) {
        _lat = 39.9042; _lon = 116.4074; _enabled = YES;
        NSDictionary *d = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"_LH"];
        if (d) {
            if (d[@"a"]) _lat = [d[@"a"] doubleValue];
            if (d[@"b"]) _lon = [d[@"b"] doubleValue];
            if (d[@"c"]) _enabled = [d[@"c"] boolValue];
        }
    }
    return self;
}
- (void)save {
    [[NSUserDefaults standardUserDefaults] setObject:@{@"a":@(_lat),@"b":@(_lon),@"c":@(_enabled)} forKey:@"_LH"];
}
@end

// ============================================================
//  位置篡改核心 — 清除模拟标记 + 随机漂移
// ============================================================

static void CleanLocation(CLLocation *loc) {
    @try {
        for (NSString *k in @[@"isFromMockProvider",@"isSimulatedBySoftware",
                              @"matchInfo",@"trustedTimestamp",
                              @"detectedByGpsOverride",@"isProducedByAccessDevice",
                              @"isLikelyFromLocationdSimulation"]) {
            @try { [loc setValue:@NO forKey:k]; } @catch(id e) {}
        }
    } @catch(id e) {}
}

static CLLocation *MakeFake() {
    _LH_Config *c = [_LH_Config shared];
    double lat = c.lat + ((double)arc4random_uniform(1000)/1000000.0) - 0.0005;
    double lon = c.lon + ((double)arc4random_uniform(1000)/1000000.0) - 0.0005;
    CLLocation *loc = [[CLLocation alloc] initWithCoordinate:CLLocationCoordinate2DMake(lat,lon)
                                                    altitude:50
                                          horizontalAccuracy:30+arc4random_uniform(100)
                                            verticalAccuracy:30+arc4random_uniform(60)
                                                      course:arc4random_uniform(360)
                                                       speed:(CLLocationSpeed)arc4random_uniform(200)/100.0
                                                   timestamp:[NSDate date]];
    CleanLocation(loc);
    return loc;
}

// ============================================================
//  Hook 策略 A: 拦截 CLLocation 的指定初始化器
//  任何新创建的 CLLocation 坐标会被篡改
// ============================================================

// 最常用的 6 参数初始化器
typedef CLLocation *(*InitWithCoord6_t)(id, SEL, CLLocationCoordinate2D, CLLocationDistance, CLLocationAccuracy, CLLocationAccuracy, CLLocationDirection, CLLocationSpeed, NSDate*);

static InitWithCoord6_t orig_init6 = nil;
static CLLocation *hook_init6(id self, SEL _cmd,
                               CLLocationCoordinate2D coord,
                               CLLocationDistance alt,
                               CLLocationAccuracy hAcc,
                               CLLocationAccuracy vAcc,
                               CLLocationDirection course,
                               CLLocationSpeed speed,
                               NSDate *timestamp) {
    _LH_Config *c = [_LH_Config shared];
    if (c.enabled) {
        double lat = c.lat + ((double)arc4random_uniform(500)/1000000.0) - 0.00025;
        double lon = c.lon + ((double)arc4random_uniform(500)/1000000.0) - 0.00025;
        coord = CLLocationCoordinate2DMake(lat, lon);
    }
    CLLocation *loc = orig_init6(self, _cmd, coord, alt, hAcc, vAcc, course, speed, timestamp);
    CleanLocation(loc);
    return loc;
}

// 4 参数初始化器（旧版）
typedef CLLocation *(*InitWithCoord4_t)(id, SEL, CLLocationCoordinate2D, CLLocationDistance, CLLocationAccuracy, CLLocationAccuracy, NSDate*);
static InitWithCoord4_t orig_init4 = nil;
static CLLocation *hook_init4(id self, SEL _cmd,
                               CLLocationCoordinate2D coord,
                               CLLocationDistance alt,
                               CLLocationAccuracy hAcc,
                               CLLocationAccuracy vAcc,
                               NSDate *timestamp) {
    _LH_Config *c = [_LH_Config shared];
    if (c.enabled) {
        double lat = c.lat + ((double)arc4random_uniform(500)/1000000.0) - 0.00025;
        double lon = c.lon + ((double)arc4random_uniform(500)/1000000.0) - 0.00025;
        coord = CLLocationCoordinate2DMake(lat, lon);
    }
    CLLocation *loc = orig_init4(self, _cmd, coord, alt, hAcc, vAcc, timestamp);
    CleanLocation(loc);
    return loc;
}

// ============================================================
//  Hook 策略 B: 拦截 CLLocationManager setDelegate:
//  在 delegate 回调中替换位置
// ============================================================

@interface _LH_Proxy : NSObject <CLLocationManagerDelegate>
@property (nonatomic, weak) id orig;
@end
@implementation _LH_Proxy
- (void)locationManager:(CLLocationManager *)m didUpdateLocations:(NSArray *)l {
    if (!_orig) return;
    if ([_LH_Config shared].enabled) {
        CLLocation *fake = nil;
        @try { fake = MakeFake(); } @catch(id e) { fake = l.firstObject; }
        if ([_orig respondsToSelector:_cmd])
            [_orig locationManager:m didUpdateLocations:fake ? @[fake] : l];
        return;
    }
    if ([_orig respondsToSelector:_cmd]) [_orig locationManager:m didUpdateLocations:l];
}
- (void)locationManager:(CLLocationManager *)m didFailWithError:(NSError *)e {
    if (_orig && [_orig respondsToSelector:_cmd]) [_orig locationManager:m didFailWithError:e];
}
- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)m {
    if (_orig && [_orig respondsToSelector:_cmd]) [_orig locationManagerDidChangeAuthorization:m];
}
- (BOOL)respondsToSelector:(SEL)s { return [super respondsToSelector:s] || [_orig respondsToSelector:s]; }
- (id)forwardingTargetForSelector:(SEL)s { return _orig; }
@end

// ============================================================
//  CLLocationManager swizzle
// ============================================================

static NSMapTable *gProxyMap = nil;

static void Swz(Class c, SEL o, SEL n) {
    Method om = class_getInstanceMethod(c, o);
    Method nm = class_getInstanceMethod(c, n);
    if (om && nm) method_exchangeImplementations(om, nm);
}

@interface CLLocationManager (_LH)
- (void)_lh_setDelegate:(id)d;
- (void)_lh_startUpdatingLocation;
- (void)_lh_requestLocation;
@end
@implementation CLLocationManager (_LH)
- (void)_lh_setDelegate:(id)d {
    if (d && ![d isKindOfClass:[_LH_Proxy class]]) {
        _LH_Proxy *p = [_LH_Proxy new];
        p.orig = d;
        if (!gProxyMap) gProxyMap = [NSMapTable weakToStrongObjectsMapTable];
        @synchronized(gProxyMap) { [gProxyMap setObject:p forKey:self]; }
        [self _lh_setDelegate:(id)p];
        return;
    }
    [self _lh_setDelegate:d];
}
- (void)_lh_startUpdatingLocation {
    _LH_Config *c = [_LH_Config shared];
    if (c.enabled) {
        // 阻断真实定位 → 直接回调假位置
        id delegate = [self valueForKey:@"delegate"];
        if ([delegate respondsToSelector:@selector(locationManager:didUpdateLocations:)]) {
            [delegate locationManager:self didUpdateLocations:@[MakeFake()]];
        }
        return;
    }
    [self _lh_startUpdatingLocation];
}
- (void)_lh_requestLocation {
    _LH_Config *c = [_LH_Config shared];
    if (c.enabled) {
        id delegate = [self valueForKey:@"delegate"];
        if ([delegate respondsToSelector:@selector(locationManager:didUpdateLocations:)]) {
            [delegate locationManager:self didUpdateLocations:@[MakeFake()]];
        }
        return;
    }
    [self _lh_requestLocation];
}
@end

// ============================================================
//  Hook 策略 C: 替换 coordinate getter
//  兜底方案，防止某些路径绕过 A 和 B
// ============================================================

static CLLocationCoordinate2D (*orig_coord)(id,SEL);
static CLLocationCoordinate2D hook_coord(id self, SEL _cmd) {
    if (![_LH_Config shared].enabled) return orig_coord(self, _cmd);
    _LH_Config *c = [_LH_Config shared];
    double lat = c.lat + ((double)arc4random_uniform(500)/1000000.0) - 0.00025;
    double lon = c.lon + ((double)arc4random_uniform(500)/1000000.0) - 0.00025;
    return CLLocationCoordinate2DMake(lat, lon);
}

// ============================================================
//  安装
// ============================================================

static void InstallAllHooks() {
    // A: 拦截 CLLocation 初始化
    Method m6 = class_getInstanceMethod([CLLocation class],
        @selector(initWithCoordinate:altitude:horizontalAccuracy:verticalAccuracy:course:speed:timestamp:));
    if (m6) {
        orig_init6 = (InitWithCoord6_t)method_getImplementation(m6);
        method_setImplementation(m6, (IMP)hook_init6);
    }
    Method m4 = class_getInstanceMethod([CLLocation class],
        @selector(initWithCoordinate:altitude:horizontalAccuracy:verticalAccuracy:timestamp:));
    if (m4) {
        orig_init4 = (InitWithCoord4_t)method_getImplementation(m4);
        method_setImplementation(m4, (IMP)hook_init4);
    }

    // B: 拦截 delegate + 阻断系统定位
    Swz([CLLocationManager class], @selector(setDelegate:), @selector(_lh_setDelegate:));
    Swz([CLLocationManager class], @selector(startUpdatingLocation), @selector(_lh_startUpdatingLocation));
    Swz([CLLocationManager class], @selector(requestLocation), @selector(_lh_requestLocation));

    // C: 拦截 coordinate getter
    Method mc = class_getInstanceMethod([CLLocation class], @selector(coordinate));
    if (mc) {
        orig_coord = (void*)method_getImplementation(mc);
        method_setImplementation(mc, (IMP)hook_coord);
    }
}

// ============================================================
//  浮动按钮
// ============================================================

@interface _LH_Btn : UIButton @end
@implementation _LH_Btn
- (void)showMenu {
    _LH_Config *c = [_LH_Config shared];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"📍"
        message:[NSString stringWithFormat:@"%.4f,%.4f  %@",c.lat,c.lon,c.enabled?@"开":@"关"]
        preferredStyle:UIAlertControllerStyleActionSheet];
    [a addAction:[UIAlertAction actionWithTitle:@"开/关" style:0 handler:^(UIAlertAction *a) {
        c.enabled = !c.enabled; [c save];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"输入坐标" style:0 handler:^(UIAlertAction *a) {
        [self inputCoord];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.sourceView = self;
    a.popoverPresentationController.sourceRect = self.bounds;
    [[self window].rootViewController presentViewController:a animated:YES completion:nil];
}
- (void)inputCoord {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"输入坐标"
        message:@"纬度,经度" preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *t) { t.placeholder = @"39.9042,116.4074"; }];
    [a addAction:[UIAlertAction actionWithTitle:@"确定" style:0 handler:^(UIAlertAction *act) {
        NSString *t = a.textFields.firstObject.text;
        NSArray *p = [t componentsSeparatedByString:@","];
        if (p.count!=2) p = [t componentsSeparatedByString:@"，"];
        if (p.count==2) {
            double la=[p[0] doubleValue], lo=[p[1] doubleValue];
            if (la>=-90&&la<=90&&lo>=-180&&lo<=180) {
                _LH_Config *c = [_LH_Config shared];
                c.lat=la; c.lon=lo; [c save];
            }
        }
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [[self window].rootViewController presentViewController:a animated:YES completion:nil];
}
@end

static void ShowUI() {
    _LH_Btn *b = [_LH_Btn buttonWithType:UIButtonTypeCustom];
    CGRect s = [UIScreen mainScreen].bounds;
    b.frame = CGRectMake(s.size.width-65, s.size.height/2, 50, 50);
    b.backgroundColor = [UIColor colorWithRed:0.2 green:0.5 blue:1.0 alpha:0.85];
    b.layer.cornerRadius = 25;
    [b setTitle:@"📍" forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:22];
    [b addTarget:b action:@selector(showMenu) forControlEvents:UIControlEventTouchUpInside];

    UIWindow *w = nil;
    if (@available(iOS 15, *)) {
        for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
            if (sc.activationState == UISceneActivationStateForegroundActive) {
                w = [(UIWindowScene *)sc windows].firstObject;
                break;
            }
        }
    }
    if (!w) w = UIApplication.sharedApplication.windows.firstObject;
    [w addSubview:b];
}

// ============================================================
//  入口
// ============================================================

@interface _LH_Init : NSObject @end
@implementation _LH_Init
+ (void)load {
    // 尽快安装 hook，不依赖 UI
    InstallAllHooks();

    // UI 部分延迟到主线程就绪
    dispatch_async(dispatch_get_main_queue(), ^{
        ShowUI();
    });
}
@end
