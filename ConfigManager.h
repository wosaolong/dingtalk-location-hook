//
//  ConfigManager.h
//  钉钉虚拟定位 — 配置管理器
//

#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>

/// 一个预设坐标点
@interface LocationPreset : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) double latitude;
@property (nonatomic, assign) double longitude;
+ (instancetype)presetWithName:(NSString *)name latitude:(double)lat longitude:(double)lon;
@end

/// 配置管理（单例）
@interface ConfigManager : NSObject

/// 当前目标坐标
@property (nonatomic, assign) double targetLatitude;
@property (nonatomic, assign) double targetLongitude;
@property (nonatomic, assign) double targetAltitude;

/// 预设坐标列表
@property (nonatomic, strong) NSArray<LocationPreset *> *presets;

/// 是否启用虚拟定位
@property (nonatomic, assign, getter=isEnabled) BOOL enabled;

/// 是否显示浮动按钮
@property (nonatomic, assign) BOOL showFloatingButton;

/// 单例
+ (instancetype)shared;

/// 从预设名加载坐标（如 @"家"）
- (BOOL)loadPresetByName:(NSString *)name;

/// 手动设置坐标
- (void)setLatitude:(double)lat longitude:(double)lon;

/// 从剪贴板读取配置（格式：loc:39.9042,116.4074）
- (BOOL)parseFromPasteboard;

/// 保存配置到 UserDefaults
- (void)save;

/// 加载配置
- (void)load;

/// 当前坐标的 CLLocationCoordinate2D
- (CLLocationCoordinate2D)coordinate;

@end
