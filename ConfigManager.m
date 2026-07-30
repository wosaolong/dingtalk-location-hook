//
//  ConfigManager.m — 加固版
//  钉钉虚拟定位 — 配置管理器（加密存储 + 隐蔽路径）
//

#import "ConfigManager.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// 编译开关
#ifdef DEBUG
    #define CFG_LOG(fmt, ...) NSLog(fmt, ##__VA_ARGS__)
#else
    #define CFG_LOG(fmt, ...) /* 发布版不输出 */
#endif

// ============================================================
//  简单混淆存储（避开 NSUserDefaults 的明文暴露）
// ============================================================

static NSString * const kConfigDirName = @".com.apple.mis";
static NSString * const kConfigFileName = @".lk.dat";

/// 简单的 XOR 混淆（非真正加密，仅用于避免明文特征）
static NSData *ObfuscateData(NSData *data) {
    if (!data) return nil;
    const char key[] = { 0xA3, 0x7B, 0xC5, 0x1E, 0x94, 0x6D, 0x28, 0xF0 };
    NSMutableData *result = [NSMutableData dataWithLength:data.length];
    const uint8_t *src = data.bytes;
    uint8_t *dst = result.mutableBytes;
    for (NSUInteger i = 0; i < data.length; i++) {
        dst[i] = src[i] ^ key[i % sizeof(key)];
    }
    return result;
}

/// 获取配置文件的隐蔽路径
static NSString *ConfigFilePath() {
    // 使用 Caches 目录（系统会定期清理，但不影响我们的使用）
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    if (paths.count == 0) return nil;

    NSString *cacheDir = paths[0];
    NSString *configDir = [cacheDir stringByAppendingPathComponent:kConfigDirName];

    // 创建目录（模仿系统目录结构）
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:configDir isDirectory:&isDir]) {
        [fm createDirectoryAtPath:configDir
      withIntermediateDirectories:YES
                       attributes:@{
                           NSFilePosixPermissions: @(0755),
                           NSFileExtensionHidden: @YES,
                       }
                            error:nil];
    }

    return [configDir stringByAppendingPathComponent:kConfigFileName];
}

// ============================================================
//  LocationPreset
// ============================================================

@implementation LocationPreset
+ (instancetype)presetWithName:(NSString *)name latitude:(double)lat longitude:(double)lon {
    LocationPreset *p = [LocationPreset new];
    p.name = name;
    p.latitude = lat;
    p.longitude = lon;
    return p;
}
@end

// ============================================================
//  ConfigManager
// ============================================================

@implementation ConfigManager

+ (instancetype)shared {
    static ConfigManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [ConfigManager new];
        [instance load];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _targetLatitude = 39.9042;
        _targetLongitude = 116.4074;
        _targetAltitude = 50.0;
        _enabled = YES;
        _showFloatingButton = YES;

        _presets = @[
            [LocationPreset presetWithName:@"🏢 公司" latitude:39.9042 longitude:116.4074],
            [LocationPreset presetWithName:@"🏠 家" latitude:39.9500 longitude:116.3300],
            [LocationPreset presetWithName:@"🏪 商圈" latitude:39.9200 longitude:116.4600],
            [LocationPreset presetWithName:@"🚇 地铁站" latitude:39.9100 longitude:116.4200],
        ];
    }
    return self;
}

- (void)setLatitude:(double)lat longitude:(double)lon {
    if (lat < -90 || lat > 90 || lon < -180 || lon > 180) return;
    _targetLatitude = lat;
    _targetLongitude = lon;
    [self save];
}

- (BOOL)loadPresetByName:(NSString *)name {
    for (LocationPreset *p in self.presets) {
        if ([p.name containsString:name] || [name containsString:p.name]) {
            if (p.latitude != 0 || p.longitude != 0) {
                [self setLatitude:p.latitude longitude:p.longitude];
                return YES;
            }
        }
    }
    return NO;
}

- (CLLocationCoordinate2D)coordinate {
    return CLLocationCoordinate2DMake(self.targetLatitude, self.targetLongitude);
}

/// 从剪贴板解析坐标（格式：loc:39.9042,116.4074）
- (BOOL)parseFromPasteboard {
    if (!self.isEnabled) return NO;

    UIPasteboard *pb = [UIPasteboard generalPasteboard];
    NSString *text = pb.string;
    if (!text || text.length == 0) return NO;

    text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    NSString *coordStr = text;
    if ([text.lowercaseString hasPrefix:@"loc:"]) {
        coordStr = [text substringFromIndex:4];
    } else if ([text.lowercaseString hasPrefix:@"location:"]) {
        coordStr = [text substringFromIndex:9];
    } else {
        return NO;  // 必须带 loc: 前缀防误触
    }

    NSArray *parts = [coordStr componentsSeparatedByString:@","];
    if (parts.count != 2) {
        parts = [coordStr componentsSeparatedByString:@"，"];
    }
    if (parts.count != 2) return NO;

    double lat = [parts[0] doubleValue];
    double lon = [parts[1] doubleValue];

    if (lat < -90 || lat > 90 || lon < -180 || lon > 180) return NO;

    [self setLatitude:lat longitude:lon];
    return YES;
}

/// 保存到加密文件
- (void)save {
    NSDictionary *dict = @{
        @"lat": @(self.targetLatitude),
        @"lon": @(self.targetLongitude),
        @"alt": @(self.targetAltitude),
        @"enabled": @(self.isEnabled),
    };

    @try {
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:dict options:0 error:nil];
        NSData *obfuscated = ObfuscateData(jsonData);
        NSString *path = ConfigFilePath();
        if (path && obfuscated) {
            [obfuscated writeToFile:path atomically:YES];
        }
    } @catch (NSException *e) {
        // 静默失败，不影响主功能
    }
}

/// 从加密文件加载
- (void)load {
    @try {
        NSString *path = ConfigFilePath();
        if (!path) return;

        NSData *obfuscated = [NSData dataWithContentsOfFile:path];
        if (!obfuscated) return;

        NSData *jsonData = ObfuscateData(obfuscated);
        NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:nil];
        if (!dict) return;

        if (dict[@"lat"]) _targetLatitude = [dict[@"lat"] doubleValue];
        if (dict[@"lon"]) _targetLongitude = [dict[@"lon"] doubleValue];
        if (dict[@"alt"]) _targetAltitude = [dict[@"alt"] doubleValue];
        if (dict[@"enabled"]) _enabled = [dict[@"enabled"] boolValue];

    } @catch (NSException *e) {
        // 加载失败使用默认值
    }
}

@end
