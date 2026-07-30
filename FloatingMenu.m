//
//  FloatingMenu.m — 加固版
//  钉钉虚拟定位 — 悬浮配置按钮（零日志 + 无废弃 API）
//

#import <UIKit/UIKit.h>
#import "ConfigManager.h"

// 编译开关
#ifdef DEBUG
    #define UI_LOG(fmt, ...) NSLog(fmt, ##__VA_ARGS__)
#else
    #define UI_LOG(fmt, ...) /* 发布版不输出 */
#endif

// ============================================================
//  兼容 iOS 13+ 获取 keyWindow 的安全方式
// ============================================================

static UIWindow *SafeKeyWindow() {
    if (@available(iOS 15.0, *)) {
        // iOS 15+ 使用 UIScene 方式
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive) {
                UIWindowScene *windowScene = (UIWindowScene *)scene;
                for (UIWindow *window in windowScene.windows) {
                    if (window.isKeyWindow) return window;
                }
            }
        }
    }
    // 回退（iOS 15 上仍可用）
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return [UIApplication sharedApplication].keyWindow;
    #pragma clang diagnostic pop
}

// ============================================================
//  悬浮按钮视图
// ============================================================

@interface FloatingButtonView : UIView
@property (nonatomic, strong) UIButton *button;
@property (nonatomic, strong) CALayer *statusDot;
@property (nonatomic, assign) CGPoint dragStart;
@property (nonatomic, assign) CGPoint originStart;
@end

@implementation FloatingButtonView

- (instancetype)init {
    CGFloat size = 50;
    CGFloat margin = 20;
    CGRect frame = CGRectMake([UIScreen mainScreen].bounds.size.width - size - margin,
                              [UIScreen mainScreen].bounds.size.height / 2,
                              size, size);
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithRed:0.2 green:0.5 blue:1.0 alpha:0.85];
        self.layer.cornerRadius = size / 2;
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOffset = CGSizeMake(0, 2);
        self.layer.shadowOpacity = 0.3;
        self.layer.shadowRadius = 4;
        self.userInteractionEnabled = YES;

        _button = [UIButton buttonWithType:UIButtonTypeCustom];
        _button.frame = self.bounds;
        [_button setTitle:@"📍" forState:UIControlStateNormal];
        _button.titleLabel.font = [UIFont systemFontOfSize:22];
        _button.userInteractionEnabled = YES;
        [self addSubview:_button];

        // 状态指示点
        _statusDot = [CALayer layer];
        _statusDot.frame = CGRectMake(-4, -4, 16, 16);
        _statusDot.cornerRadius = 8;
        _statusDot.backgroundColor = [UIColor greenColor].CGColor;
        _statusDot.borderColor = [UIColor whiteColor].CGColor;
        _statusDot.borderWidth = 2;
        [self.layer addSublayer:_statusDot];

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(didTap)];
        [_button addGestureRecognizer:tap];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(didPan:)];
        [self addGestureRecognizer:pan];
    }
    return self;
}

- (void)didTap {
    [self showConfigMenu];
}

- (void)didPan:(UIPanGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        self.dragStart = [gesture locationInView:self.superview];
        self.originStart = self.center;
    } else if (gesture.state == UIGestureRecognizerStateChanged) {
        CGPoint translation = [gesture translationInView:self.superview];
        self.center = CGPointMake(self.originStart.x + translation.x,
                                  self.originStart.y + translation.y);
        CGRect bounds = [UIScreen mainScreen].bounds;
        CGFloat halfSize = self.frame.size.width / 2;
        self.center = CGPointMake(
            MAX(halfSize, MIN(bounds.size.width - halfSize, self.center.x)),
            MAX(halfSize + 60, MIN(bounds.size.height - halfSize - 60, self.center.y))
        );
    }
}

- (void)updateStatus {
    ConfigManager *cfg = [ConfigManager shared];
    self.statusDot.backgroundColor = (cfg.isEnabled ? [UIColor greenColor] : [UIColor redColor]).CGColor;
}

- (void)showConfigMenu {
    UIViewController *rootVC = SafeKeyWindow().rootViewController;
    if (!rootVC) return;

    ConfigManager *cfg = [ConfigManager shared];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"📍 虚拟定位"
                                                                   message:[NSString stringWithFormat:@"%.4f, %.4f\n%@",
                                                                            cfg.targetLatitude,
                                                                            cfg.targetLongitude,
                                                                            cfg.isEnabled ? @"✅ 已启用" : @"❌ 已暂停"]
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    for (LocationPreset *preset in cfg.presets) {
        NSString *title = [NSString stringWithFormat:@"%@ (%.4f, %.4f)", preset.name, preset.latitude, preset.longitude];
        [alert addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [cfg setLatitude:preset.latitude longitude:preset.longitude];
            [self updateStatus];
        }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:cfg.isEnabled ? @"⏸ 暂停" : @"▶️ 启用"
                                              style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        cfg.enabled = !cfg.isEnabled;
        [cfg save];
        [self updateStatus];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"✏️ 自定义" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [self showCustomInput];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"🙈 隐藏" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        cfg.showFloatingButton = NO;
        [cfg save];
        self.hidden = YES;
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    alert.popoverPresentationController.sourceView = self;
    alert.popoverPresentationController.sourceRect = self.bounds;
    [rootVC presentViewController:alert animated:YES completion:nil];
}

- (void)showCustomInput {
    UIViewController *rootVC = SafeKeyWindow().rootViewController;
    if (!rootVC) return;

    UIAlertController *inputAlert = [UIAlertController alertControllerWithTitle:@"输入坐标"
                                                                        message:@"loc:纬度,经度\n示例: loc:39.9042,116.4074"
                                                                 preferredStyle:UIAlertControllerStyleAlert];

    [inputAlert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"loc:39.9042,116.4074";
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];

    [inputAlert addAction:[UIAlertAction actionWithTitle:@"确认" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *text = inputAlert.textFields.firstObject.text;
        if (text.length == 0) return;
        // 自动补全 loc: 前缀
        if (![text.lowercaseString hasPrefix:@"loc:"]) {
            text = [@"loc:" stringByAppendingString:text];
        }
        [UIPasteboard generalPasteboard].string = text;
        [[ConfigManager shared] parseFromPasteboard];
        [self updateStatus];
    }]];

    [inputAlert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [rootVC presentViewController:inputAlert animated:YES completion:nil];
}

@end

// ============================================================
//  浮动按钮管理器
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

- (void)showFloatingButton {
    if (self.floatingView) return;

    ConfigManager *cfg = [ConfigManager shared];
    if (!cfg.showFloatingButton) return;

    self.floatingView = [[FloatingButtonView alloc] init];
    [self.floatingView updateStatus];

    UIWindow *keyWindow = SafeKeyWindow();
    [keyWindow addSubview:self.floatingView];
}

- (void)startPasteboardMonitoring {
    if (self.pasteboardTimer) return;

    self.lastPasteboardContent = [UIPasteboard generalPasteboard].string;

    self.pasteboardTimer = [NSTimer scheduledTimerWithTimeInterval:3.0
                                                            target:self
                                                          selector:@selector(checkPasteboard)
                                                          userInfo:nil
                                                           repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.pasteboardTimer forMode:NSRunLoopCommonModes];
}

- (void)checkPasteboard {
    if (![ConfigManager shared].isEnabled) return;

    UIPasteboard *pb = [UIPasteboard generalPasteboard];
    NSString *currentText = pb.string;
    if (!currentText || currentText.length == 0) return;
    if ([currentText isEqualToString:self.lastPasteboardContent]) return;

    if ([currentText.lowercaseString hasPrefix:@"loc:"] ||
        [currentText.lowercaseString hasPrefix:@"location:"]) {
        if ([[ConfigManager shared] parseFromPasteboard]) {
            self.lastPasteboardContent = currentText;
            [self.floatingView updateStatus];
        }
    }
}

- (void)delayedInit {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self showFloatingButton];
        [self startPasteboardMonitoring];
    });
}

@end
