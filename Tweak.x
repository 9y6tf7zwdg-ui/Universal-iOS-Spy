#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

// ===================== 日志 =====================
static NSString *getLogPath() {
    NSString *docPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *dir = [docPath stringByAppendingPathComponent:@"VoicePacks"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:@"final_send_test.log"];
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

// ===================== 核心：强制输出 8000Hz 单声道 AAC =====================
static void transcodeToNativeAAC(NSString *sourcePath, NSString *outputPath, void (^completion)(BOOL success)) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:outputPath]) [fm removeItemAtPath:outputPath error:nil];

    AVAsset *asset = [AVAsset assetWithURL:[NSURL fileURLWithPath:sourcePath]];
    NSArray *audioTracks = [asset tracksWithMediaType:AVMediaTypeAudio];
    if (audioTracks.count == 0) {
        traceLog(@"❌ 源文件无音频轨道");
        completion(NO);
        return;
    }

    NSError *error = nil;
    AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:&error];
    AVAssetReaderTrackOutput *readerOutput = [[AVAssetReaderTrackOutput alloc] initWithTrack:audioTracks.firstObject outputSettings:@{
        AVFormatIDKey: @(kAudioFormatLinearPCM),
        AVSampleRateKey: @8000, // 读取时就强制 8000Hz
        AVNumberOfChannelsKey: @1,
        AVLinearPCMBitDepthKey: @16,
        AVLinearPCMIsFloatKey: @NO,
        AVLinearPCMIsBigEndianKey: @NO,
        AVLinearPCMIsNonInterleaved: @NO
    }];
    [reader addOutput:readerOutput];
    [reader startReading];

    // 写入设置：AAC 8000Hz 单声道
    NSDictionary *writerSettings = @{
        AVFormatIDKey: @(kAudioFormatMPEG4AAC),
        AVSampleRateKey: @8000,
        AVNumberOfChannelsKey: @1,
        AVEncoderBitRateKey: @16000,
    };

    NSError *writerError = nil;
    AVAssetWriter *writer = [[AVAssetWriter alloc] initWithURL:[NSURL fileURLWithPath:outputPath] fileType:AVFileTypeAppleM4A error:&writerError];
    if (writerError) {
        traceLog(@"❌ 创建 Writer 失败: %@", writerError);
        completion(NO);
        return;
    }

    AVAssetWriterInput *writerInput = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeAudio outputSettings:writerSettings];
    writerInput.expectsMediaDataInRealTime = NO;
    [writer addInput:writerInput];
    [writer startWriting];
    [writer startSessionAtSourceTime:kCMTimeZero];

    [writerInput requestMediaDataWhenReadyOnQueue:dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0) usingBlock:^{
        while (writerInput.isReadyForMoreMediaData) {
            CMSampleBufferRef sampleBuffer = [readerOutput copyNextSampleBuffer];
            if (!sampleBuffer) {
                [writerInput markAsFinished];
                [writer finishWritingWithCompletionHandler:^{
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (writer.status == AVAssetWriterStatusCompleted) {
                            traceLog(@"✅ 转码成功: %@", outputPath.lastPathComponent);
                            completion(YES);
                        } else {
                            traceLog(@"❌ 写入失败: %@", writer.error);
                            completion(NO);
                        }
                    });
                }];
                break;
            }
            if (![writerInput appendSampleBuffer:sampleBuffer]) {
                traceLog(@"❌ 追加样本失败");
                CFRelease(sampleBuffer);
                [writerInput markAsFinished];
                [writer cancelWriting];
                completion(NO);
                break;
            }
            CFRelease(sampleBuffer);
        }
    }];
}

// ===================== 终极发送函数 =====================
static void testSendFinal(NSString *sourcePath) {
    traceLog(@"\n========== 🚀 终极发送测试 (8000Hz 单声道) ==========");
    if (![[NSFileManager defaultManager] fileExistsAtPath:sourcePath]) {
        traceLog(@"❌ 源文件不存在");
        return;
    }

    NSString *docPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *hcrDir = [docPath stringByAppendingPathComponent:@"HCRecordAudio/1A913486"];
    [[NSFileManager defaultManager] createDirectoryAtPath:hcrDir withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *uuid = [[NSUUID UUID] UUIDString];
    NSString *finalAacPath = [hcrDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.aac", uuid]];

    transcodeToNativeAAC(sourcePath, finalAacPath, ^(BOOL success) {
        if (!success) return;
        
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:finalAacPath error:nil];
        traceLog(@"✅ 转码完成。文件大小: %llu 字节", [attrs fileSize]);

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
    // 阻止原有录音行为
}
%end