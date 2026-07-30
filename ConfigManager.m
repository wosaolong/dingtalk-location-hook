//
//  ConfigManager.m
//  钉钉虚拟定位 — 配置管理器实现
//

#import "ConfigManager.h"
#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>

@implementation LocationPreset
+ (instancetype)presetWithName:(NSString *)name latitude:(double)lat longitude:(double)lon {
    LocationPreset *p = [LocationPreset new];
    p.name = name;
    p.latitude = lat;
    p.longitude = lon;
    return p;
}
@end

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
        // 默认坐标：北京天安门
        _targetLatitude = 39.9042;
        _targetLongitude = 116.4074;
        _targetAltitude = 50.0;
        _enabled = YES;
        _showFloatingButton = YES;

        // 预设常用坐标
        _presets = @[
            [LocationPreset presetWithName:@"🏢 公司 (默认)" latitude:39.9042 longitude:116.4074],
            [LocationPreset presetWithName:@"🏠 家" latitude:39.9500 longitude:116.3300],
            [LocationPreset presetWithName:@"🏪 商圈" latitude:39.9200 longitude:116.4600],
            [LocationPreset presetWithName:@"🚇 地铁站" latitude:39.9100 longitude:116.4200],
            [LocationPreset presetWithName:@"🎯 自定义" latitude:0 longitude:0],
        ];
    }
    return self;
}

- (void)setLatitude:(double)lat longitude:(double)lon {
    self.targetLatitude = lat;
    self.targetLongitude = lon;
    [self save];
    NSLog(@"[LocationHook] 坐标已更新: %.4f, %.4f", lat, lon);
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

/// 从剪贴板解析坐标
/// 支持的格式：
///   loc:39.9042,116.4074
///   39.9042,116.4074
///   39.9042, 116.4074
- (BOOL)parseFromPasteboard {
    UIPasteboard *pb = [UIPasteboard generalPasteboard];
    NSString *text = pb.string;
    if (!text || text.length == 0) return NO;

    // 清理文本
    text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    // 尝试匹配格式
    NSString *coordStr = text;
    if ([text.lowercaseString hasPrefix:@"loc:"]) {
        coordStr = [text substringFromIndex:4];
    } else if ([text.lowercaseString hasPrefix:@"location:"]) {
        coordStr = [text substringFromIndex:9];
    }

    // 解析逗号分隔的坐标
    NSArray *parts = [coordStr componentsSeparatedByString:@","];
    if (parts.count != 2) {
        // 尝试中文逗号
        parts = [coordStr componentsSeparatedByString:@"，"];
        if (parts.count != 2) return NO;
    }

    double lat = [parts[0] doubleValue];
    double lon = [parts[1] doubleValue];

    if (lat < -90 || lat > 90 || lon < -180 || lon > 180) {
        NSLog(@"[LocationHook] 剪贴板坐标值超出范围: %.4f, %.4f", lat, lon);
        return NO;
    }

    [self setLatitude:lat longitude:lon];

    // 显示确认通知
    NSString *msg = [NSString stringWithFormat:@"📍 坐标已更新: %.4f, %.4f", lat, lon];
    [self showLocalNotification:msg];

    return YES;
}

- (void)showLocalNotification:(NSString *)message {
    // 使用 UILocalNotification（兼容 iOS 10+）
    if (@available(iOS 10.0, *)) {
        UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
        UNMutableNotificationContent *content = [UNMutableNotificationContent new];
        content.body = message;
        content.sound = [UNNotificationSound defaultSound];
        content.badge = @0;

        UNTimeIntervalNotificationTrigger *trigger = [UNTimeIntervalNotificationTrigger triggerWithTimeInterval:1 repeats:NO];
        UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:@"LocationHook" content:content trigger:trigger];
        [center addNotificationRequest:request withCompletionHandler:nil];
    }
}

/// 保存到 NSUserDefaults
- (void)save {
    NSDictionary *dict = @{
        @"lat": @(self.targetLatitude),
        @"lon": @(self.targetLongitude),
        @"alt": @(self.targetAltitude),
        @"enabled": @(self.isEnabled),
        @"showBtn": @(self.showFloatingButton),
    };
    [[NSUserDefaults standardUserDefaults] setObject:dict forKey:@"LocationHookConfig"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

/// 加载配置
- (void)load {
    NSDictionary *dict = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"LocationHookConfig"];
    if (!dict) return;

    self.targetLatitude = [dict[@"lat"] doubleValue] ?: self.targetLatitude;
    self.targetLongitude = [dict[@"lon"] doubleValue] ?: self.targetLongitude;
    self.targetAltitude = [dict[@"alt"] doubleValue] ?: self.targetAltitude;
    self.enabled = [dict[@"enabled"] boolValue];
    self.showFloatingButton = [dict[@"showBtn"] boolValue];
}

@end
