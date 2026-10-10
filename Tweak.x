#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

// ===================== 日志 =====================
static NSString *getLogPath() {
    NSString *docPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *dir = [docPath stringByAppendingPathComponent:@"VoicePacks"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:@"send_test.log"];
}

static void traceLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"HH:mm:ss.SSS";
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [fmt stringFromDate:[NSDate date]], msg];
    NSString *path = getLogPath();
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) {
        [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } else {
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
}

// 查找当前顶层的 MessageDetailController
static UIViewController *findMessageDetailController(UIViewController *vc) {
    if ([vc isKindOfClass:NSClassFromString(@"MessageDetailController")]) return vc;
    for (UIViewController *child in vc.childViewControllers) {
        UIViewController *found = findMessageDetailController(child);
        if (found) return found;
    }
    if (vc.presentedViewController) return findMessageDetailController(vc.presentedViewController);
    return nil;
}

static UIViewController *topViewController() {
    UIWindow *keyWindow = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]] && scene.activationState == UISceneActivationStateForegroundActive) {
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if (window.isKeyWindow) { keyWindow = window; break; }
            }
        }
    }
    if (!keyWindow) return nil;
    UIViewController *topVC = keyWindow.rootViewController;
    while (topVC.presentedViewController) topVC = topVC.presentedViewController;
    return topVC;
}

// ===================== 核心发送函数 =====================
static void testSendM4A(NSString *sourcePath) {
    traceLog(@"\n========== 🚀 开始终极发送测试 ==========");
    traceLog(@"源文件: %@", sourcePath);
    
    if (![[NSFileManager defaultManager] fileExistsAtPath:sourcePath]) {
        traceLog(@"❌ 源文件不存在");
        return;
    }

    NSString *docPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    // 原生录音所在的真实目录
    NSString *hcrDir = [docPath stringByAppendingPathComponent:@"HCRecordAudio/1A913486"];
    [[NSFileManager defaultManager] createDirectoryAtPath:hcrDir withIntermediateDirectories:YES attributes:nil error:nil];

    // 用 UUID 命名，模仿原生行为
    NSString *uuid = [[NSUUID UUID] UUIDString];
    NSString *tempM4aPath = [hcrDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.m4a", uuid]];
    NSString *finalAacPath = [hcrDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.aac", uuid]];
    [[NSFileManager defaultManager] removeItemAtPath:tempM4aPath error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:finalAacPath error:nil];

    // 1. 转码为标准 M4A
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:sourcePath] options:nil];
    AVAssetExportSession *session = [[AVAssetExportSession alloc] initWithAsset:asset presetName:AVAssetExportPresetAppleM4A];
    session.outputURL = [NSURL fileURLWithPath:tempM4aPath];
    session.outputFileType = AVFileTypeAppleM4A;

    [session exportAsynchronouslyWithCompletionHandler:^{
        if (session.status != AVAssetExportSessionStatusCompleted) {
            traceLog(@"❌ 导出失败: %@", session.error);
            return;
        }
        
        // 2. 重命名为 .aac（腾讯云 IM 偏好这个后缀）
        NSError *moveErr = nil;
        [[NSFileManager defaultManager] moveItemAtPath:tempM4aPath toPath:finalAacPath error:&moveErr];
        if (moveErr) {
            traceLog(@"❌ 重命名失败: %@", moveErr);
            return;
        }
        
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:finalAacPath error:nil];
        traceLog(@"✅ 转码并重命名完成。文件大小: %llu 字节", [attrs fileSize]);

        // 3. 强行进入主线程并执行发送
        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *chatVC = findMessageDetailController(topViewController());
            if (!chatVC) {
                traceLog(@"❌ 找不到 MessageDetailController，请确认你正在聊天界面");
                return;
            }

            // 准备时长
            int duration = (int)ceil(CMTimeGetSeconds(asset.duration));
            if (duration <= 0) duration = 1;

            traceLog(@"开始调用腾讯云 IM...");

            // 创建消息
            Class v2Mgr = NSClassFromString(@"V2TIMManager");
            id manager = [v2Mgr performSelector:@selector(sharedInstance)];
            SEL createSel = NSSelectorFromString(@"createSoundMessage:duration:");
            
            NSMethodSignature *sig = [manager methodSignatureForSelector:createSel];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:manager];
            [inv setSelector:createSel];
            __unsafe_unretained NSString *pathArg = finalAacPath;
            [inv setArgument:&pathArg atIndex:2];
            [inv setArgument:&duration atIndex:3];
            [inv invoke];
            
            __unsafe_unretained id msg = nil;
            [inv getReturnValue:&msg];
            traceLog(@"📨 createSoundMessage 返回: %@", msg);

            // 发送消息
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
                traceLog(@"✅ 已调用 sendMessage:isRetry:！请检查对方是否收到声音！");
            } else {
                traceLog(@"❌ MessageDetailController 不响应 sendMessage:isRetry:");
            }
        });
    }];
}

// ===================== Hook =====================
%hook CWTalkBackView

- (void)sendRecorde:(id)sender {
    // 长按对讲松手时触发此测试
    NSString *docPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *sourcePath = [docPath stringByAppendingPathComponent:@"VoicePacks/早上好.wav"];
    
    // 如果找不到早上好.wav，用一个存在的音频文件测试
    if (![[NSFileManager defaultManager] fileExistsAtPath:sourcePath]) {
        traceLog(@"⚠️ VoicePacks/早上好.wav 不存在");
        // 这里为了不阻断，还是调用 %orig，但会记录警告
        return %orig;
    }
    
    testSendM4A(sourcePath);
    // 阻止原始录音行为，防止冲突
}
%end