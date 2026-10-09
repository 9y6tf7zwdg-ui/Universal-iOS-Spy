#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <AVFoundation/AVFoundation.h>

@interface MessageDetailController : UIViewController
@end

// ================= 基础辅助函数 =================

// 获取沙盒里的源文件路径
static NSString *getSourceVoicePath() {
    NSString *docPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *voiceDir = [docPath stringByAppendingPathComponent:@"VoicePacks"];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:voiceDir]) {
        [fm createDirectoryAtPath:voiceDir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    for (NSString *ext in @[@"wav", @"mp3", @"m4a"]) {
        NSString *path = [voiceDir stringByAppendingPathComponent:[NSString stringWithFormat:@"test.%@", ext]];
        if ([fm fileExistsAtPath:path]) return path;
    }
    return nil;
}

// 自动转码器：把任意音频转为 M4A
static void convertToM4A(NSString *inputPath, NSString *outputPath, void (^completion)(BOOL success)) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:outputPath]) {
        [fm removeItemAtPath:outputPath error:nil];
    }
    NSURL *inputURL = [NSURL fileURLWithPath:inputPath];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:inputURL options:nil];
    AVAssetExportSession *session = [[AVAssetExportSession alloc] initWithAsset:asset presetName:AVAssetExportPresetAppleM4A];
    session.outputURL = [NSURL fileURLWithPath:outputPath];
    session.outputFileType = AVFileTypeAppleM4A;
    [session exportAsynchronouslyWithCompletionHandler:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(session.status == AVAssetExportSessionStatusCompleted);
        });
    }];
}

// 获取音频真实时长（秒）
static int getAudioDuration(NSString *path) {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
    float seconds = CMTimeGetSeconds(asset.duration);
    if (isnan(seconds) || seconds <= 0) return 1;
    return (int)ceil(seconds);
}

// 递归寻找聊天控制器
static UIViewController *findMessageDetailController(UIViewController *vc) {
    if ([vc isKindOfClass:NSClassFromString(@"MessageDetailController")]) return vc;
    for (UIViewController *child in vc.childViewControllers) {
        UIViewController *found = findMessageDetailController(child);
        if (found) return found;
    }
    if (vc.presentedViewController) return findMessageDetailController(vc.presentedViewController);
    return nil;
}

// 获取当前顶层控制器
static UIViewController *topViewController() {
    UIWindow *keyWindow = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]] && scene.activationState == UISceneActivationStateForegroundActive) {
            for (UIWindow *window in scene.windows) {
                if (window.isKeyWindow) {
                    keyWindow = window;
                    break;
                }
            }
        }
    }
    if (!keyWindow) return nil;
    UIViewController *topVC = keyWindow.rootViewController;
    while (topVC.presentedViewController) topVC = topVC.presentedViewController;
    return topVC;
}

// ================= 悬浮球逻辑 =================

static UIWindow *floatWindow;
static UIButton *floatButton;

@interface FloatHandler : NSObject
@end

@implementation FloatHandler

// 拖动
- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    UIView *btn = gesture.view;
    CGPoint translation = [gesture translationInView:btn.superview];
    btn.center = CGPointMake(btn.center.x + translation.x, btn.center.y + translation.y);
    [gesture setTranslation:CGPointZero inView:btn.superview];
}

// 点击发送
- (void)handleTap {
    NSLog(@"[VoicePlugin] 悬浮球被点击了！");
    
    NSString *sourcePath = getSourceVoicePath();
    if (!sourcePath) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"找不到音频" message:@"请打开 Filza，在沙盒 Documents/VoicePacks/ 下放一个 test.wav 或 test.mp3" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [topViewController() presentViewController:alert animated:YES completion:nil];
        return;
    }
    
    NSString *docPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *outputPath = [docPath stringByAppendingPathComponent:@"VoicePacks/converted_voice.m4a"];
    
    NSLog(@"[VoicePlugin] 开始转码: %@", sourcePath);
    convertToM4A(sourcePath, outputPath, ^(BOOL success) {
        if (!success) {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"转码失败" message:@"音频文件可能已损坏，请换一个文件尝试。" preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            [topViewController() presentViewController:alert animated:YES completion:nil];
            return;
        }
        
        NSLog(@"[VoicePlugin] 转码成功，准备发送...");
        UIViewController *chatVC = findMessageDetailController(topViewController());
        if (!chatVC) {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"请先进入聊天" message:@"请在进入任意一个聊天界面后，再点击悬浮球。" preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            [topViewController() presentViewController:alert animated:YES completion:nil];
            return;
        }
        
        // 获取真实时长（完美同步的关键）
        int duration = getAudioDuration(outputPath);
        NSLog(@"[VoicePlugin] 音频真实时长: %d秒", duration);
        
        // 构造 V2TIM 语音消息
        Class v2ManagerClass = NSClassFromString(@"V2TIMManager");
        id manager = [v2ManagerClass performSelector:@selector(sharedInstance)];
        SEL createSel = NSSelectorFromString(@"createSoundMessage:duration:");
        
        if ([manager respondsToSelector:createSel]) {
            NSMethodSignature *sig = [manager methodSignatureForSelector:createSel];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:manager];
            [inv setSelector:createSel];
            
            // 修复编译报错：用 __unsafe_unretained 中转
            __unsafe_unretained NSString *pathArg = outputPath;
            [inv setArgument:&pathArg atIndex:2];
            [inv setArgument:&duration atIndex:3];
            [inv invoke];
            
            __unsafe_unretained id msg = nil;
            [inv getReturnValue:&msg];
            
            // 触发发送
            SEL sendSel = NSSelectorFromString(@"sendMessage:isRetry:");
            if ([chatVC respondsToSelector:sendSel]) {
                NSMethodSignature *sendSig = [chatVC methodSignatureForSelector:sendSel];
                NSInvocation *sendInv = [NSInvocation invocationWithMethodSignature:sendSig];
                [sendInv setTarget:chatVC];
                [sendInv setSelector:sendSel];
                [sendInv setArgument:&msg atIndex:2];
                BOOL retry = NO;
                [sendInv setArgument:&retry atIndex:3];
                [sendInv invoke];
                NSLog(@"[VoicePlugin] 语音已触发发送！");
            }
        }
    });
}

@end

// 创建悬浮窗
static void createFloatUI() {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindowScene *windowScene = nil;
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]] && scene.activationState == UISceneActivationStateForegroundActive) {
                windowScene = (UIWindowScene *)scene;
                break;
            }
        }
        if (!windowScene) return;
        
        floatWindow = [[UIWindow alloc] initWithWindowScene:windowScene];
        floatWindow.frame = CGRectMake(150, 300, 60, 60);
        floatWindow.windowLevel = UIWindowLevelAlert + 100;
        floatWindow.backgroundColor = [UIColor clearColor];
        floatWindow.rootViewController = [UIViewController new];
        floatWindow.hidden = NO;
        
        FloatHandler *handler = [FloatHandler new];
        
        floatButton = [UIButton buttonWithType:UIButtonTypeCustom];
        floatButton.frame = CGRectMake(0, 0, 60, 60);
        floatButton.backgroundColor = [UIColor colorWithRed:0.2 green:0.6 blue:1.0 alpha:0.9];
        floatButton.layer.cornerRadius = 30;
        floatButton.layer.shadowColor = [UIColor blackColor].CGColor;
        floatButton.layer.shadowOpacity = 0.5;
        floatButton.layer.shadowOffset = CGSizeMake(0, 2);
        [floatButton setTitle:@"发语音" forState:UIControlStateNormal];
        floatButton.titleLabel.font = [UIFont boldSystemFontOfSize:12];
        
        [floatButton addTarget:handler action:@selector(handleTap) forControlEvents:UIControlEventTouchUpInside];
        
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:handler action:@selector(handlePan:)];
        [floatButton addGestureRecognizer:pan];
        
        [floatWindow.rootViewController.view addSubview:floatButton];
    });
}

// 插件加载入口
__attribute__((constructor)) static void init() {
    // 延迟 2 秒等 App 启动完毕
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        createFloatUI();
    });
}