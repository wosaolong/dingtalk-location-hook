//
//  FloatingMenu.m
//  钉钉虚拟定位 — 悬浮配置按钮
//
//  在屏幕上添加一个可拖动的悬浮按钮，点击弹出配置菜单
//  用于快速切换坐标和查看当前状态
//

#import <UIKit/UIKit.h>
#import "ConfigManager.h"

// 兼容 iOS 13+，keyWindow 废弃但 iOS 15 仍可用
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

// ============================================================
//  悬浮按钮视图
// ============================================================

@interface FloatingButtonView : UIView
@property (nonatomic, strong) UIButton *button;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, assign) CGPoint dragStart;
@property (nonatomic, assign) CGPoint originStart;
@property (nonatomic, assign) BOOL isDragging;
@end

@implementation FloatingButtonView

- (instancetype)init {
    CGFloat size = 50;
    CGFloat margin = 20;
    // 默认放在右侧中间
    CGRect frame = CGRectMake([UIScreen mainScreen].bounds.size.width - size - margin,
                              [UIScreen mainScreen].bounds.size.height / 2,
                              size, size);
    self = [super initWithFrame:frame];
    if (self) {
        // 圆形容器
        self.backgroundColor = [UIColor colorWithRed:0.2 green:0.5 blue:1.0 alpha:0.85];
        self.layer.cornerRadius = size / 2;
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOffset = CGSizeMake(0, 2);
        self.layer.shadowOpacity = 0.3;
        self.layer.shadowRadius = 4;
        self.userInteractionEnabled = YES;
        self.clipsToBounds = NO;
        self.window.windowLevel = UIWindowLevelAlert + 100;

        // 按钮
        _button = [UIButton buttonWithType:UIButtonTypeCustom];
        _button.frame = self.bounds;
        [_button setTitle:@"📍" forState:UIControlStateNormal];
        _button.titleLabel.font = [UIFont systemFontOfSize:22];
        _button.userInteractionEnabled = YES;
        [self addSubview:_button];

        // 状态小标签（显示当前是否启用）
        _statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(-4, -4, 16, 16)];
        _statusLabel.backgroundColor = [UIColor greenColor];
        _statusLabel.layer.cornerRadius = 8;
        _statusLabel.layer.masksToBounds = YES;
        _statusLabel.hidden = NO;
        [self addSubview:_statusLabel];

        // 添加手势 - 点击
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(didTap)];
        [_button addGestureRecognizer:tap];

        // 添加手势 - 拖动
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(didPan:)];
        [self addGestureRecognizer:pan];
    }
    return self;
}

- (void)didTap {
    [self showConfigMenu];
}

- (void)didPan:(UIPanGestureRecognizer *)gesture {
    CGPoint translation = [gesture translationInView:self.superview];
    if (gesture.state == UIGestureRecognizerStateBegan) {
        self.dragStart = [gesture locationInView:self.superview];
        self.originStart = self.center;
    } else if (gesture.state == UIGestureRecognizerStateChanged) {
        self.center = CGPointMake(self.originStart.x + translation.x,
                                  self.originStart.y + translation.y);
        // 防止拖出屏幕边缘
        CGRect bounds = [UIScreen mainScreen].bounds;
        CGFloat halfSize = self.frame.size.width / 2;
        self.center = CGPointMake(
            MAX(halfSize, MIN(bounds.size.width - halfSize, self.center.x)),
            MAX(halfSize + 60, MIN(bounds.size.height - halfSize - 60, self.center.y))
        );
    }
}

/// 更新状态指示器颜色
- (void)updateStatus {
    ConfigManager *cfg = [ConfigManager shared];
    self.statusLabel.backgroundColor = cfg.isEnabled ? [UIColor greenColor] : [UIColor redColor];
    [self.statusLabel setNeedsDisplay];
}

/// 弹出配置菜单
- (void)showConfigMenu {
    UIViewController *rootVC = [UIApplication sharedApplication].keyWindow.rootViewController;
    if (!rootVC) {
        // 尝试找最上层的 VC
        rootVC = [self topMostViewController];
    }
    if (!rootVC) return;

    ConfigManager *cfg = [ConfigManager shared];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"📍 虚拟定位配置"
                                                                   message:[NSString stringWithFormat:@"当前坐标: %.4f, %.4f\n状态: %@",
                                                                            cfg.targetLatitude,
                                                                            cfg.targetLongitude,
                                                                            cfg.isEnabled ? @"✅ 已启用" : @"❌ 已禁用"]
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    // 预设坐标选项
    for (LocationPreset *preset in cfg.presets) {
        NSString *title = [NSString stringWithFormat:@"%@ (%.4f, %.4f)", preset.name, preset.latitude, preset.longitude];
        UIAlertAction *action = [UIAlertAction actionWithTitle:title
                                                         style:UIAlertActionStyleDefault
                                                       handler:^(UIAlertAction * _Nonnull action) {
            [cfg setLatitude:preset.latitude longitude:preset.longitude];
            [self updateStatus];
            [self showTemporaryToast:[NSString stringWithFormat:@"已切换到: %@", preset.name]];
        }];
        [alert addAction:action];
    }

    // 启用/禁用切换
    NSString *toggleTitle = cfg.isEnabled ? @"⏸ 暂停虚拟定位" : @"▶️ 启用虚拟定位";
    UIAlertAction *toggleAction = [UIAlertAction actionWithTitle:toggleTitle
                                                          style:UIAlertActionStyleDefault
                                                        handler:^(UIAlertAction * _Nonnull action) {
        cfg.enabled = !cfg.isEnabled;
        [cfg save];
        [self updateStatus];
        [self showTemporaryToast:cfg.isEnabled ? @"虚拟定位已启用" : @"虚拟定位已暂停"];
    }];
    [alert addAction:toggleAction];

    // 自定义坐标
    UIAlertAction *customAction = [UIAlertAction actionWithTitle:@"✏️ 输入自定义坐标"
                                                          style:UIAlertActionStyleDefault
                                                        handler:^(UIAlertAction * _Nonnull action) {
        [self showCustomCoordinateInput];
    }];
    [alert addAction:customAction];

    // 使用说明
    UIAlertAction *helpAction = [UIAlertAction actionWithTitle:@"ℹ️ 使用说明"
                                                        style:UIAlertActionStyleDefault
                                                      handler:^(UIAlertAction * _Nonnull action) {
        [self showHelp];
    }];
    [alert addAction:helpAction];

    // 隐藏按钮
    UIAlertAction *hideAction = [UIAlertAction actionWithTitle:@"🙈 隐藏此按钮"
                                                        style:UIAlertActionStyleDestructive
                                                      handler:^(UIAlertAction * _Nonnull action) {
        cfg.showFloatingButton = NO;
        [cfg save];
        self.hidden = YES;
    }];
    [alert addAction:hideAction];

    // 取消
    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil];
    [alert addAction:cancelAction];

    // 在 iPad 上需要设置 popover 锚点
    alert.popoverPresentationController.sourceView = self;
    alert.popoverPresentationController.sourceRect = self.bounds;

    [rootVC presentViewController:alert animated:YES completion:nil];
}

/// 自定义坐标输入
- (void)showCustomCoordinateInput {
    UIViewController *rootVC = [UIApplication sharedApplication].keyWindow.rootViewController ?: [self topMostViewController];
    if (!rootVC) return;

    UIAlertController *inputAlert = [UIAlertController alertControllerWithTitle:@"输入坐标"
                                                                        message:@"格式: 纬度,经度\n示例: 39.9042,116.4074"
                                                                 preferredStyle:UIAlertControllerStyleAlert];

    [inputAlert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.placeholder = @"纬度,经度";
        textField.keyboardType = UIKeyboardTypeDecimalPad;
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];

    UIAlertAction *confirmAction = [UIAlertAction actionWithTitle:@"确认" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        NSString *text = inputAlert.textFields.firstObject.text;
        if (text.length == 0) return;

        // 解析坐标
        NSArray *parts = [text componentsSeparatedByString:@","];
        if (parts.count != 2) {
            parts = [text componentsSeparatedByString:@"，"];
        }
        if (parts.count == 2) {
            double lat = [parts[0] doubleValue];
            double lon = [parts[1] doubleValue];
            if (lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180) {
                [[ConfigManager shared] setLatitude:lat longitude:lon];
                [self showTemporaryToast:[NSString stringWithFormat:@"📍 已设置: %.4f, %.4f", lat, lon]];
                [self updateStatus];
            } else {
                [self showTemporaryToast:@"❌ 坐标值超出范围"];
            }
        } else {
            [self showTemporaryToast:@"❌ 格式错误，请使用: 纬度,经度"];
        }
    }];
    [inputAlert addAction:confirmAction];

    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil];
    [inputAlert addAction:cancelAction];

    [rootVC presentViewController:inputAlert animated:YES completion:nil];
}

/// 使用说明
- (void)showHelp {
    UIViewController *rootVC = [UIApplication sharedApplication].keyWindow.rootViewController ?: [self topMostViewController];
    if (!rootVC) return;

    NSString *helpText = @"📍 钉钉虚拟定位插件\n\n"
                          @"📋 剪贴板配置：\n"
                          @"复制 loc:39.9042,116.4074 到剪贴板\n"
                          @"或直接复制 39.9042,116.4074\n\n"
                          @"📌 浮动按钮：\n"
                          @"点击弹出配置菜单\n"
                          @"拖动可改变位置\n\n"
                          @"⚠️ 注意：\n"
                          @"• 需授予通知权限以接收反馈\n"
                          @"• 坐标格式: 纬度,经度\n"
                          @"• 纬度范围: -90~90\n"
                          @"• 经度范围: -180~180";

    UIAlertController *helpAlert = [UIAlertController alertControllerWithTitle:@"ℹ️ 帮助"
                                                                       message:helpText
                                                                preferredStyle:UIAlertControllerStyleAlert];
    [helpAlert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
    [rootVC presentViewController:helpAlert animated:YES completion:nil];
}

/// 显示临时 Toast
- (void)showTemporaryToast:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        // 使用横幅通知
        CGFloat width = 280;
        CGFloat height = 50;
        CGFloat x = ([UIScreen mainScreen].bounds.size.width - width) / 2;
        CGFloat y = 100;

        UILabel *toast = [[UILabel alloc] initWithFrame:CGRectMake(x, y, width, height)];
        toast.text = message;
        toast.textAlignment = NSTextAlignmentCenter;
        toast.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.8];
        toast.textColor = [UIColor whiteColor];
        toast.font = [UIFont systemFontOfSize:14];
        toast.layer.cornerRadius = 12;
        toast.layer.masksToBounds = YES;
        toast.alpha = 0;
        toast.numberOfLines = 0;

        UIWindow *keyWindow = [UIApplication sharedApplication].keyWindow;
        [keyWindow addSubview:toast];

        [UIView animateWithDuration:0.3 animations:^{
            toast.alpha = 1;
        } completion:^(BOOL finished) {
            [UIView animateWithDuration:0.3 delay:2.0 options:0 animations:^{
                toast.alpha = 0;
            } completion:^(BOOL finished) {
                [toast removeFromSuperview];
            }];
        }];
    });
}

/// 找到最上层的 ViewController
- (UIViewController *)topMostViewController {
    UIViewController *root = [UIApplication sharedApplication].keyWindow.rootViewController;
    return [self topFrom:root];
}

- (UIViewController *)topFrom:(UIViewController *)vc {
    if (vc.presentedViewController) return [self topFrom:vc.presentedViewController];
    if ([vc isKindOfClass:[UITabBarController class]]) {
        return [self topFrom:((UITabBarController *)vc).selectedViewController];
    }
    if ([vc isKindOfClass:[UINavigationController class]]) {
        return [self topFrom:((UINavigationController *)vc).topViewController];
    }
    return vc;
}

@end

// ============================================================
//  浮动按钮管理器 — 负责创建和维护浮动按钮
// ============================================================

@interface FloatingMenuManager : NSObject
@property (nonatomic, strong) FloatingButtonView *floatingView;
@property (nonatomic, strong) NSTimer *pasteboardTimer;
@property (nonatomic, copy) NSString *lastPasteboardContent;
@end

@implementation FloatingMenuManager

+ (instancetype)shared {
    static FloatingMenuManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [FloatingMenuManager new];
    });
    return instance;
}

/// 创建浮动按钮（必须在主线程调用）
- (void)showFloatingButton {
    if (self.floatingView) return;

    ConfigManager *cfg = [ConfigManager shared];
    if (!cfg.showFloatingButton) {
        NSLog(@"[LocationHook] 浮动按钮已被用户隐藏");
        return;
    }

    self.floatingView = [[FloatingButtonView alloc] init];
    [self.floatingView updateStatus];

    // 添加到 keyWindow
    [[UIApplication sharedApplication].keyWindow addSubview:self.floatingView];
    NSLog(@"[LocationHook] 浮动按钮已显示");
}

/// 启动剪贴板监听（每秒检查一次）
- (void)startPasteboardMonitoring {
    if (self.pasteboardTimer) return;

    self.lastPasteboardContent = [UIPasteboard generalPasteboard].string;

    self.pasteboardTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                            target:self
                                                          selector:@selector(checkPasteboard)
                                                          userInfo:nil
                                                           repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.pasteboardTimer forMode:NSRunLoopCommonModes];
    NSLog(@"[LocationHook] 剪贴板监听已启动");
}

/// 检查剪贴板是否包含坐标指令
- (void)checkPasteboard {
    // 如果插件未启用，不处理
    if (![ConfigManager shared].isEnabled) return;

    UIPasteboard *pb = [UIPasteboard generalPasteboard];
    NSString *currentText = pb.string;
    if (!currentText || currentText.length == 0) return;

    // 检查是否是新的内容
    if ([currentText isEqualToString:self.lastPasteboardContent]) return;

    // 检查是否包含 loc: 前缀（避免误触发）
    NSString *lower = currentText.lowercaseString;
    if ([lower hasPrefix:@"loc:"] || [lower hasPrefix:@"location:"]) {
        BOOL success = [[ConfigManager shared] parseFromPasteboard];
        if (success) {
            self.lastPasteboardContent = currentText;
            // 更新浮动按钮状态
            [self.floatingView updateStatus];
        }
    }
}

/// 延迟初始化（等待 UI 就绪）
- (void)delayedInit {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self showFloatingButton];
        [self startPasteboardMonitoring];
    });
}

@end
