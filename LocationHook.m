//
//  LocationHook.m — TrollFools 适配版
//  精简定位注入，只用 method swizzling，不依赖 fishhook/constructor 时序
//

#import <CoreLocation/CoreLocation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ============================================================
//  TrollFools 兼容：使用 +load 作为入口（constructor 可能不被触发）
// ============================================================

@interface _LH_Init : NSObject @end
@implementation _LH_Init
+ (void)load {
    // 延迟到主线程就绪后初始化
    dispatch_async(dispatch_get_main_queue(), ^{
        [self performSelector:@selector(setup) withObject:nil afterDelay:1.0];
    });
}
+ (void)setup {
    // 初始化配置
    [[_LH_Config shared] load];
    // 安装 hook
    InstallHooks();
    // 启动 UI
    ShowFloatingButton();
}
@end

// ============================================================
//  配置（轻量，不用文件存储，防崩溃）
// ============================================================

@interface _LH_Config : NSObject
@property (nonatomic, assign) double lat;
@property (nonatomic, assign) double lon;
@property (nonatomic, assign) BOOL enabled;
+ (instancetype)shared;
- (void)load;
- (void)save;
@end

@implementation _LH_Config
+ (instancetype)shared {
    static id s = nil;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ s = [self new]; });
    return s;
}
- (instancetype)init {
    if (self = [super init]) {
        _lat = 39.9042;
        _lon = 116.4074;
        _enabled = YES;
    }
    return self;
}
- (void)load {
    NSDictionary *d = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"_LH"];
    if (d) {
        if (d[@"a"]) _lat = [d[@"a"] doubleValue];
        if (d[@"b"]) _lon = [d[@"b"] doubleValue];
        if (d[@"c"]) _enabled = [d[@"c"] boolValue];
    }
}
- (void)save {
    [[NSUserDefaults standardUserDefaults] setObject:@{
        @"a": @(_lat), @"b": @(_lon), @"c": @(_enabled)
    } forKey:@"_LH"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}
@end

// ============================================================
//  定位参数 — 每次随机化
// ============================================================

static CLLocation *MakeLocation() {
    _LH_Config *c = [_LH_Config shared];
    double lat = c.lat + ((double)arc4random_uniform(1000) / 1000000.0) - 0.0005;
    double lon = c.lon + ((double)arc4random_uniform(1000) / 1000000.0) - 0.0005;

    CLLocation *loc = [[CLLocation alloc] initWithCoordinate:CLLocationCoordinate2DMake(lat, lon)
                                                    altitude:50
                                          horizontalAccuracy:30 + arc4random_uniform(100)
                                            verticalAccuracy:30 + arc4random_uniform(60)
                                                      course:arc4random_uniform(360)
                                                       speed:(CLLocationSpeed)arc4random_uniform(200) / 100.0
                                                   timestamp:[NSDate date]];
    @try {
        for (NSString *k in @[@"isFromMockProvider",@"isSimulatedBySoftware",
                              @"matchInfo",@"trustedTimestamp",@"detectedByGpsOverride",
                              @"isProducedByAccessDevice",@"isLikelyFromLocationdSimulation"]) {
            @try { [loc setValue:@NO forKey:k]; } @catch(id e) {}
        }
    } @catch(id e) {}
    return loc;
}

// ============================================================
//  代理拦截
// ============================================================

@interface _LH_Proxy : NSObject <CLLocationManagerDelegate>
@property (nonatomic, weak) id original;
@end

@implementation _LH_Proxy
- (void)locationManager:(CLLocationManager *)m didUpdateLocations:(NSArray *)l {
    if (!_original) return;
    if (![_LH_Config shared].enabled) {
        if ([_original respondsToSelector:_cmd]) [_original locationManager:m didUpdateLocations:l];
        return;
    }
    CLLocation *fake = nil;
    @try { fake = MakeLocation(); } @catch(id e) { fake = l.firstObject; }
    if ([_original respondsToSelector:_cmd]) [_original locationManager:m didUpdateLocations:@[fake]];
}
- (void)locationManager:(CLLocationManager *)m didFailWithError:(NSError *)e {
    if (_original && [_original respondsToSelector:_cmd]) [_original locationManager:m didFailWithError:e];
}
- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)m {
    if (_original && [_original respondsToSelector:_cmd]) [_original locationManagerDidChangeAuthorization:m];
}
- (BOOL)respondsToSelector:(SEL)s {
    return [super respondsToSelector:s] || [_original respondsToSelector:s];
}
- (id)forwardingTargetForSelector:(SEL)s { return _original; }
@end

// ============================================================
//  Method Swizzle
// ============================================================

static NSMapTable *proxyMap = nil;

static void Swz(Class c, SEL o, SEL n) {
    Method om = class_getInstanceMethod(c, o);
    Method nm = class_getInstanceMethod(c, n);
    if (!om || !nm) return;
    method_exchangeImplementations(om, nm);
}

// ============================================================
//  直接拦截 CLLocationManagerDelegate 的定位回调
//  不依赖于 setDelegate: hook（因为钉钉可能在 init 时设置 delegate）
// ============================================================

// 方案 B：Hook CLLocation 的 coordinate getter
// 当钉钉读取 location.coordinate 时，返回我们的坐标

static CLLocationCoordinate2D (*orig_coordinate)(id, SEL) = NULL;
static CLLocationCoordinate2D hook_coordinate(id self, SEL _cmd) {
    if (![_LH_Config shared].enabled) {
        return orig_coordinate(self, _cmd);
    }
    _LH_Config *c = [_LH_Config shared];
    double lat = c.lat + ((double)arc4random_uniform(500) / 1000000.0) - 0.00025;
    double lon = c.lon + ((double)arc4random_uniform(500) / 1000000.0) - 0.00025;
    return CLLocationCoordinate2DMake(lat, lon);
}

static void InstallCoordinateHook() {
    // Hook CLLocation.coordinate getter
    Method m = class_getInstanceMethod([CLLocation class], @selector(coordinate));
    if (m) {
        orig_coordinate = (void*)method_getImplementation(m);
        method_setImplementation(m, (IMP)hook_coordinate);
    }
}

// ============================================================
//  setDelegate: hook（作为补充）
// ============================================================

@interface CLLocationManager (_LH)
- (void)_lh_setDelegate:(id)d;
- (void)_lh_startUpdatingLocation;
@end
@implementation CLLocationManager (_LH)
- (void)_lh_setDelegate:(id)d {
    if (d && ![d isKindOfClass:[_LH_Proxy class]]) {
        _LH_Proxy *p = [_LH_Proxy new];
        p.original = d;
        if (!proxyMap) proxyMap = [NSMapTable weakToStrongObjectsMapTable];
        @synchronized(proxyMap) { [proxyMap setObject:p forKey:self]; }
        [self _lh_setDelegate:(id)p];
        return;
    }
    [self _lh_setDelegate:d];
}
- (void)_lh_startUpdatingLocation {
    [self _lh_startUpdatingLocation];
}
@end

// ============================================================
//  Hook 安装
// ============================================================

void InstallHooks() {
    // 方式 A：Hook coordinate（最可靠，直接改坐标值）
    InstallCoordinateHook();

    // 方式 B：Hook setDelegate（补充）
    Swz([CLLocationManager class], @selector(setDelegate:), @selector(_lh_setDelegate:));
    Swz([CLLocationManager class], @selector(startUpdatingLocation), @selector(_lh_startUpdatingLocation));
}

// ============================================================
//  浮动按钮
// ============================================================

@interface _LH_Btn : UIButton @end
@implementation _LH_Btn
- (void)showMenu {
    _LH_Config *c = [_LH_Config shared];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"📍"
        message:[NSString stringWithFormat:@"%.4f,%.4f\n%@", c.lat, c.lon, c.enabled?@"已启用":@"已暂停"]
        preferredStyle:UIAlertControllerStyleActionSheet];

    [a addAction:[UIAlertAction actionWithTitle:@"⏸ 暂停/启用" style:0 handler:^(UIAlertAction *a) {
        c.enabled = !c.enabled; [c save];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"✏️ 输入坐标" style:0 handler:^(UIAlertAction *a) {
        [self inputCoord];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    a.popoverPresentationController.sourceView = self;
    a.popoverPresentationController.sourceRect = self.bounds;
    [[self window].rootViewController presentViewController:a animated:YES completion:nil];
}
- (void)inputCoord {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"输入坐标"
        message:@"纬度,经度\n如：39.9042,116.4074" preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"39.9042,116.4074";
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"确认" style:0 handler:^(UIAlertAction *act) {
        NSString *t = a.textFields.firstObject.text;
        NSArray *p = [t componentsSeparatedByString:@","];
        if (p.count != 2) p = [t componentsSeparatedByString:@"，"];
        if (p.count == 2) {
            double lat = [p[0] doubleValue], lon = [p[1] doubleValue];
            if (lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180) {
                [_LH_Config shared].lat = lat;
                [_LH_Config shared].lon = lon;
                [[_LH_Config shared] save];
            }
        }
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [[self window].rootViewController presentViewController:a animated:YES completion:nil];
}
@end

void ShowFloatingButton() {
    CGRect s = [UIScreen mainScreen].bounds;
    _LH_Btn *btn = [_LH_Btn buttonWithType:UIButtonTypeCustom];
    btn.frame = CGRectMake(s.size.width - 70, s.size.height / 2, 50, 50);
    btn.backgroundColor = [UIColor colorWithRed:0.2 green:0.5 blue:1.0 alpha:0.85];
    btn.layer.cornerRadius = 25;
    [btn setTitle:@"📍" forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont systemFontOfSize:22];
    [btn addTarget:btn action:@selector(showMenu) forControlEvents:UIControlEventTouchUpInside];

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
    [w addSubview:btn];
}
