#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

// ===================== 日志 =====================
static NSString *getLogPath() {
    NSString *docPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *dir = [docPath stringByAppendingPathComponent:@"VoicePacks"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:@"final_fix_test.log"];
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

// ===================== 核心：转码为 8000Hz 单声道 M4A =====================
static void transcodeToM4A(NSString *inputPath, NSString *outputPath, void (^completion)(BOOL success)) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:outputPath]) [fm removeItemAtPath:outputPath error:nil];

    @autoreleasepool {
        NSError *error = nil;
        AVAudioFile *inFile = [[AVAudioFile alloc] initForReading:[NSURL fileURLWithPath:inputPath] error:&error];
        if (error || !inFile) { traceLog(@"❌ 读取源文件失败: %@", error); completion(NO); return; }

        // 🚨 关键：指定 8000Hz 单声道 AAC
        NSDictionary *outSettings = @{
            AVFormatIDKey: @(kAudioFormatMPEG4AAC),
            AVSampleRateKey: @8000,
            AVNumberOfChannelsKey: @1,
            AVEncoderBitRateKey: @16000,
        };

        // 🚨 关键：扩展名是 .m4a，让 AVAudioFile 写入标准容器
        AVAudioFile *outFile = [[AVAudioFile alloc] initForWriting:[NSURL fileURLWithPath:outputPath]
                                                          settings:outSettings
                                                     commonFormat:AVAudioPCMFormatInt16
                                                      interleaved:NO
                                                            error:&error];
        if (error || !outFile) { traceLog(@"❌ 创建 M4A 失败: %@", error); completion(NO); return; }

        AVAudioConverter *converter = [[AVAudioConverter alloc] initFromFormat:inFile.processingFormat toFormat:outFile.processingFormat];
        if (!converter) { traceLog(@"❌ Converter 失败"); completion(NO); return; }

        AVAudioFrameCount capacity = 4096;
        AVAudioPCMBuffer *inBuf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:inFile.processingFormat frameCapacity:capacity];
        AVAudioPCMBuffer *outBuf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:outFile.processingFormat frameCapacity:capacity];

        BOOL writeError = NO;
        int safety = 0;
        while (1) {
            if (++safety > 500000) { traceLog(@"⚠️ 循环保护"); break; }
            NSError *convError = nil;
            AVAudioConverterOutputStatus status = [converter convertToBuffer:outBuf error:&convError withInputFromBlock:^AVAudioBuffer * _Nullable(AVAudioPacketCount inNumberOfPackets, AVAudioConverterInputStatus * _Nonnull outStatus) {
                NSError *readError = nil;
                [inFile readIntoBuffer:inBuf error:&readError];
                if (readError || inBuf.frameLength == 0) {
                    *outStatus = AVAudioConverterInputStatus_EndOfStream;
                    return nil;
                }
                *outStatus = AVAudioConverterInputStatus_HaveData;
                return inBuf;
            }];
            if (status == AVAudioConverterOutputStatus_Error) { traceLog(@"❌ 转换错误: %@", convError); writeError = YES; break; }
            if (outBuf.frameLength > 0) {
                NSError *writeErr = nil;
                [outFile writeFromBuffer:outBuf error:&writeErr];
                if (writeErr) { traceLog(@"❌ 写入错误: %@", writeErr); writeError = YES; break; }
            }
            if (status == AVAudioConverterOutputStatus_EndOfStream) break;
        }
        outFile = nil;
        inFile = nil;
        completion(!writeError);
    }
}

// ===================== 终极发送函数 =====================
static void testSendFinal(NSString *sourcePath) {
    traceLog(@"\n========== 🚀 终极发送测试 (M4A 转 AAC) ==========");
    if (![[NSFileManager defaultManager] fileExistsAtPath:sourcePath]) {
        traceLog(@"❌ 源文件不存在");
        return;
    }

    NSString *docPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *hcrDir = [docPath stringByAppendingPathComponent:@"HCRecordAudio/1A913486"];
    [[NSFileManager defaultManager] createDirectoryAtPath:hcrDir withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *uuid = [[NSUUID UUID] UUIDString];
    NSString *tempM4aPath = [hcrDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.m4a", uuid]];
    NSString *finalAacPath = [hcrDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.aac", uuid]];

    transcodeToM4A(sourcePath, tempM4aPath, ^(BOOL success) {
        if (!success) return;
        
        // 重命名为 .aac（腾讯云 IM 偏好该后缀）
        NSError *moveErr = nil;
        [[NSFileManager defaultManager] moveItemAtPath:tempM4aPath toPath:finalAacPath error:&moveErr];
        if (moveErr) {
            traceLog(@"❌ 重命名失败: %@", moveErr);
            return;
        }

        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:finalAacPath error:nil];
        traceLog(@"✅ 转码+重命名完成。文件大小: %llu 字节", [attrs fileSize]);

        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *chatVC = findMessageDetailController(topViewController());
            if (!chatVC) {
                traceLog(@"❌ 找不到 MessageDetailController");
                return;
            }

            AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:sourcePath] options:nil];
            int duration = (int)ceil(CMTimeGetSeconds(asset.duration));
            if (duration <= 0) duration = 1;

            traceLog(@"开始调用腾讯云 IM...");

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
            }
        });
    });
}

// ===================== Hook =====================
%hook CWTalkBackView

- (void)sendRecorde:(id)sender {
    NSString *docPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *sourcePath = [docPath stringByAppendingPathComponent:@"VoicePacks/早上好.wav"];
    
    if (![[NSFileManager defaultManager] fileExistsAtPath:sourcePath]) {
        traceLog(@"⚠️ VoicePacks/早上好.wav 不存在，请先放入文件");
        return %orig;
    }
    
    testSendFinal(sourcePath);
}
%end