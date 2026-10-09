#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <AVFoundation/AVFoundation.h> 

// 动态获取当前 App 沙盒内的 Documents 路径，并在其中创建 VoicePacks 文件夹
static NSString *getSandboxVoicePath() {
    NSString *docPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *voiceDir = [docPath stringByAppendingPathComponent:@"VoicePacks"];
    
    // 如果文件夹不存在，自动创建
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:voiceDir]) {
        [fm createDirectoryAtPath:voiceDir withIntermediateDirectories:YES attributes:nil error:nil];
        NSLog(@"[VoicePlugin] 已自动创建语音文件夹: %@", voiceDir);
    }
    
    // 默认读取目录下的 test.m4a（建议使用 m4a，兼容性比 mp3 好）
    return [voiceDir stringByAppendingPathComponent:@"test.m4a"];
}

// 获取音频真实时长（秒）
static int getAudioDuration(NSString *path) {
    NSURL *url = [NSURL fileURLWithPath:path];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    CMTime time = asset.duration;
    float seconds = CMTimeGetSeconds(time);
    if (isnan(seconds) || seconds <= 0) return 1;
    return (int)ceil(seconds); // 向上取整
}

static UIWindow *spyWindow;
static UIButton *spyButton;
static id spyTarget;

@interface SpyHandler : NSObject
@end

@implementation SpyHandler

- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    UIView *btn = gesture.view;
    CGPoint translation = [gesture translationInView:btn.superview];
    btn.center = CGPointMake(btn.center.x + translation.x, btn.center.y + translation.y);
    [gesture setTranslation:CGPointZero inView:btn.superview];
}

- (void)doDirectSend {
    NSString *customVoicePath = getSandboxVoicePath();
    
    if (![[NSFileManager defaultManager] fileExistsAtPath:customVoicePath]) {
        NSString *msg = [NSString stringWithFormat:@"请把音频文件（建议用 test.m4a）放到沙盒的 Documents/VoicePacks/ 目录下。\n\n你的沙盒路径是:\n%@", customVoicePath];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"找不到语音文件" message:msg preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"我知道了" style:UIAlertActionStyleDefault handler:nil]];
        [spyWindow.rootViewController presentViewController:alert animated:YES completion:nil];
        return;
    }

    int duration = getAudioDuration(customVoicePath);
    NSLog(@"[VoicePlugin] 准备发送语音，路径: %@，真实时长: %d 秒", customVoicePath, duration);

    UIViewController *topVC = spyWindow.rootViewController;
    while (topVC.presentedViewController) topVC = topVC.presentedViewController;
    
    UIViewController *chatVC = [self findMessageDetailController:topVC];
    if (!chatVC) {
        NSLog(@"[VoicePlugin] 没找到聊天界面，请先进入聊天页面");
        return;
    }

    // 利用 Runtime 构造 V2TIM 语音消息 (带真实时长)
    Class v2ManagerClass = NSClassFromString(@"V2TIMManager");
    id manager = [v2ManagerClass performSelector:@selector(sharedInstance)];
    
    SEL createSel = NSSelectorFromString(@"createSoundMessage:duration:");
    if ([manager respondsToSelector:createSel]) {
        NSMethodSignature *sig = [manager methodSignatureForSelector:createSel];
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        [inv setTarget:manager];
        [inv setSelector:createSel];
        [inv setArgument:&customVoicePath atIndex:2];
        [inv setArgument:&duration atIndex:3];
        [inv invoke];
        
        __unsafe_unretained id msg = nil;
        [inv getReturnValue:&msg];

        // 调用聊天控制器发送
        SEL sendSel = NSSelectorFromString(@"sendMessage:isRetry:");
        if ([chatVC respondsToSelector:sendSel]) {
            NSMethodSignature *sendSig = [chatVC methodSignatureForSelector:sendSel];
            NSInvocation *sendInv = [NSInvocation invocationWithMethodSignature:sendSig];
            [sendInv setTarget:chatVC];
            [sendInv setSelector:sendSel];
            [sendInv setArgument:&msg atIndex:2];
            BOOL isRetry = NO;
            [sendInv setArgument:&isRetry atIndex:3];
            [sendInv invoke];
            
            NSLog(@"[VoicePlugin] 语音已触发直接发送！");
        } else {
            NSLog(@"[VoicePlugin] 聊天控制器没有 sendMessage:isRetry: 方法");
        }
    }
}

- (UIViewController *)findMessageDetailController:(UIViewController *)vc {
    if ([vc isKindOfClass:NSClassFromString(@"MessageDetailController")]) return vc;
    for (UIViewController *child in vc.childViewControllers) {
        UIViewController *found = [self findMessageDetailController:child];
        if (found) return found;
    }
    if (vc.presentedViewController) return [self findMessageDetailController:vc.presentedViewController];
    return nil;
}

@end

static void createSpyUI() {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindowScene *windowScene = nil;
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]] && scene.activationState == UISceneActivationStateForegroundActive) {
                windowScene = (UIWindowScene *)scene;
                break;
            }
        }
        if (!windowScene) return;
        
        spyWindow = [[UIWindow alloc] initWithWindowScene:windowScene];
        spyWindow.frame = CGRectMake(120, 120, 60, 60);
        spyWindow.windowLevel = UIWindowLevelAlert + 100;
        spyWindow.backgroundColor = [UIColor clearColor];
        spyWindow.rootViewController = [UIViewController new];
        spyWindow.hidden = NO;
        
        spyTarget = [[NSClassFromString(@"SpyHandler") alloc] init];
        
        spyButton = [UIButton buttonWithType:UIButtonTypeCustom];
        spyButton.frame = CGRectMake(0, 0, 60, 60);
        spyButton.backgroundColor = [UIColor colorWithRed:0 green:1 blue:0 alpha:0.5];
        spyButton.layer.cornerRadius = 30;
        spyButton.titleLabel.font = [UIFont boldSystemFontOfSize:20];
        [spyButton setTitle:@"发" forState:UIControlStateNormal];
        [spyButton addTarget:spyTarget action:@selector(doDirectSend) forControlEvents:UIControlEventTouchUpInside];
        
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:spyTarget action:@selector(handlePan:)];
        [spyButton addGestureRecognizer:pan];
        
        [spyWindow.rootViewController.view addSubview:spyButton];
    });
}

__attribute__((constructor)) static void init() {
    // 插件加载时，先尝试创建沙盒文件夹
    getSandboxVoicePath();
    
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            createSpyUI();
        });
    }];
    
    if ([UIApplication sharedApplication].applicationState == UIApplicationStateActive) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            createSpyUI();
        });
    }
}