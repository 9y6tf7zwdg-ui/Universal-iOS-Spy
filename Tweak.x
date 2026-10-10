#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>

// ===================== 日志 =====================
static NSString *getLogPath() {
    NSString *docPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *dir = [docPath stringByAppendingPathComponent:@"VoicePacks"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:@"final_adts_test.log"];
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

// ===================== 终极核心：生成带 ADTS 头的 8000Hz 单声道 AAC =====================
static void convertToADTSAAC(NSString *sourcePath, NSString *outputPath, void (^completion)(BOOL success)) {
    // 1. 打开输入文件（早上好.wav）
    ExtAudioFileRef inFile = NULL;
    OSStatus status = ExtAudioFileOpenURL((__bridge CFURLRef)[NSURL fileURLWithPath:sourcePath], &inFile);
    if (status != noErr) {
        traceLog(@"❌ 无法打开输入文件: %d", (int)status);
        completion(NO);
        return;
    }

    // 2. 设定输入文件的客户端格式（PCM 16kHz 单声道 16bit）
    AudioStreamBasicDescription clientFormat = {0};
    clientFormat.mSampleRate = 16000;
    clientFormat.mFormatID = kAudioFormatLinearPCM;
    clientFormat.mFormatFlags = kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    clientFormat.mBytesPerPacket = 2;
    clientFormat.mFramesPerPacket = 1;
    clientFormat.mBytesPerFrame = 2;
    clientFormat.mChannelsPerFrame = 1;
    clientFormat.mBitsPerChannel = 16;
    
    status = ExtAudioFileSetProperty(inFile, kExtAudioFileProperty_ClientDataFormat, sizeof(clientFormat), &clientFormat);
    if (status != noErr) {
        traceLog(@"❌ 设定输入格式失败: %d", (int)status);
        ExtAudioFileDispose(inFile);
        completion(NO);
        return;
    }

    // 3. 创建输出文件（ADTS AAC 8kHz 单声道）
    AudioStreamBasicDescription outFormat = {0};
    outFormat.mSampleRate = 8000;
    outFormat.mFormatID = kAudioFormatMPEG4AAC;
    outFormat.mChannelsPerFrame = 1;
    outFormat.mBytesPerPacket = 0;
    outFormat.mFramesPerPacket = 1024; // ADTS 帧大小
    outFormat.mBytesPerFrame = 0;
    outFormat.mBitsPerChannel = 0;
    
    ExtAudioFileRef outFile = NULL;
    status = ExtAudioFileCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:outputPath], kAudioFileAAC_ADTSType, &outFormat, NULL, kAudioFileFlags_EraseFile, &outFile);
    if (status != noErr) {
        traceLog(@"❌ 创建输出文件失败: %d", (int)status);
        ExtAudioFileDispose(inFile);
        completion(NO);
        return;
    }

    // 4. 设定输出文件的客户端格式（我们往里面写 PCM 数据）
    status = ExtAudioFileSetProperty(outFile, kExtAudioFileProperty_ClientDataFormat, sizeof(clientFormat), &clientFormat);
    if (status != noErr) {
        traceLog(@"❌ 设定输出格式失败: %d", (int)status);
        ExtAudioFileDispose(inFile);
        ExtAudioFileDispose(outFile);
        completion(NO);
        return;
    }

    // 5. 循环读取 PCM 并写入 AAC
    UInt32 bufferByteSize = 4096;
    void *buffer = malloc(bufferByteSize);
    AudioBufferList bufferList;
    bufferList.mNumberBuffers = 1;
    bufferList.mBuffers[0].mNumberChannels = clientFormat.mChannelsPerFrame;
    bufferList.mBuffers[0].mDataByteSize = bufferByteSize;
    bufferList.mBuffers[0].mData = buffer;

    UInt32 numFrames = bufferByteSize / clientFormat.mBytesPerFrame;
    BOOL success = YES;
    while (1) {
        status = ExtAudioFileRead(inFile, &numFrames, &bufferList);
        if (status != noErr) { success = NO; break; }
        if (numFrames == 0) { break; } // 读完
        
        status = ExtAudioFileWrite(outFile, numFrames, &bufferList);
        if (status != noErr) { success = NO; break; }
    }

    free(buffer);
    ExtAudioFileDispose(inFile);
    ExtAudioFileDispose(outFile);

    if (success) {
        traceLog(@"✅ ADTS AAC 转换成功");
        completion(YES);
    } else {
        traceLog(@"❌ ADTS AAC 转换失败，错误码: %d", (int)status);
        completion(NO);
    }
}

// ===================== 终极发送函数 =====================
static void testSendFinal(NSString *sourcePath) {
    traceLog(@"\n========== 🚀 终极发送测试 (纯正 ADTS AAC) ==========");
    if (![[NSFileManager defaultManager] fileExistsAtPath:sourcePath]) {
        traceLog(@"❌ 源文件不存在");
        return;
    }

    NSString *docPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *hcrDir = [docPath stringByAppendingPathComponent:@"HCRecordAudio/1A913486"];
    [[NSFileManager defaultManager] createDirectoryAtPath:hcrDir withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *uuid = [[NSUUID UUID] UUIDString];
    NSString *finalAacPath = [hcrDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.aac", uuid]];

    convertToADTSAAC(sourcePath, finalAacPath, ^(BOOL success) {
        if (!success) return;
        
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:finalAacPath error:nil];
        traceLog(@"✅ 转换完成。文件大小: %llu 字节", [attrs fileSize]);

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