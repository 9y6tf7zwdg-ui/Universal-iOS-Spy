#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <AVFoundation/AVFoundation.h>

@interface MessageDetailController : UIViewController
@end

// 存放转换后音频的全局路径
static NSString *convertedVoicePath = nil;

// 1. 自动转码器：把任意音频（WAV/MP3）转为标准的 M4A
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

// 2. 获取沙盒中的源文件
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

// 3. 拦截底层录音路径
%hook CWRecorder
- (NSString *)recordPath {
    if (convertedVoicePath && [[NSFileManager defaultManager] fileExistsAtPath:convertedVoicePath]) {
        return convertedVoicePath;
    }
    return %orig;
}
%end

// 4. 注入按钮
%hook MessageDetailController

- (void)viewDidLoad {
    %orig;
    
    // 延迟添加，等原生UI渲染完毕
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIView *inputBanner = [self valueForKey:@"inputBannerView"];
        if (!inputBanner) return;
        
        if ([inputBanner viewWithTag:9999]) return; // 防止重复
        
        UIButton *voiceBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        voiceBtn.tag = 9999;
        voiceBtn.backgroundColor = [UIColor colorWithRed:0.2 green:0.6 blue:1.0 alpha:0.9]; // 醒目蓝色背景
        voiceBtn.layer.cornerRadius = 15;
        [voiceBtn setImage:[UIImage systemImageNamed:@"waveform"] forState:UIControlStateNormal];
        [voiceBtn setTintColor:[UIColor whiteColor]];
        
        // 使用 frame 布局，放在输入栏左侧，避免约束冲突
        CGFloat height = inputBanner.bounds.size.height > 0 ? inputBanner.bounds.size.height : 50;
        voiceBtn.frame = CGRectMake(10, (height - 30) / 2.0, 30, 30);
        
        [voiceBtn addTarget:self action:@selector(doDirectSendVoice) forControlEvents:UIControlEventTouchUpInside];
        [inputBanner addSubview:voiceBtn];
        [inputBanner bringSubviewToFront:voiceBtn]; // 强制置顶，防止被其他透明层遮挡
        
        NSLog(@"[VoicePlugin] 按钮已注入");
    });
}

// 5. 核心逻辑
%new
- (void)doDirectSendVoice {
    NSString *sourcePath = getSourceVoicePath();
    if (!sourcePath) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"找不到音频" message:@"请在沙盒 Documents/VoicePacks/ 下放一个 test.wav 或 test.mp3" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    
    NSString *docPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *outputPath = [docPath stringByAppendingPathComponent:@"VoicePacks/converted_voice.m4a"];
    
    NSLog(@"[VoicePlugin] 开始转码: %@", sourcePath);
    convertToM4A(sourcePath, outputPath, ^(BOOL success) {
        if (!success) {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"转码失败" message:@"音频文件可能损坏，请换一个文件。" preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
            return;
        }
        
        convertedVoicePath = outputPath;
        NSLog(@"[VoicePlugin] 转码成功，准备发送");
        
        // 暴力寻找 CWRecorder 实例
        id recorder = nil;
        @try {
            recorder = [self valueForKey:@"recorder"];
        } @catch (NSException *e) {}
        
        if (!recorder) {
            for (UIView *sub in self.view.subviews) {
                if ([sub isKindOfClass:NSClassFromString(@"CWRecordView")] || [sub isKindOfClass:NSClassFromString(@"CWTalkBackView")]) {
                    recorder = sub;
                    break;
                }
            }
        }
        
        if (recorder && [recorder respondsToSelector:NSSelectorFromString(@"beginRecordWithRecordPath:")]) {
            NSLog(@"[VoicePlugin] 找到录音器，开始移花接木");
            
            // 欺骗录音器：开始录音
            SEL beginSel = NSSelectorFromString(@"beginRecordWithRecordPath:");
            NSMethodSignature *beginSig = [recorder methodSignatureForSelector:beginSel];
            NSInvocation *beginInv = [NSInvocation invocationWithMethodSignature:beginSig];
            [beginInv setTarget:recorder];
            [beginInv setSelector:beginSel];
            
            // 🚨 修复编译报错的关键：用 __unsafe_unretained 中转对象参数
            __unsafe_unretained NSString *pathArg = outputPath;
            [beginInv setArgument:&pathArg atIndex:2];
            [beginInv invoke];
            
            // 立刻结束录音，触发 App 内部的上传和发送
            if ([recorder respondsToSelector:NSSelectorFromString(@"endRecord")]) {
                SEL endSel = NSSelectorFromString(@"endRecord");
                NSMethodSignature *endSig = [recorder methodSignatureForSelector:endSel];
                NSInvocation *endInv = [NSInvocation invocationWithMethodSignature:endSig];
                [endInv setTarget:recorder];
                [endInv setSelector:endSel];
                [endInv invoke];
                NSLog(@"[VoicePlugin] 已触发内部发送流程！");
            }
        } else {
            NSLog(@"[VoicePlugin] 找不到录音器，退回到直接调用 sendSound");
            if ([self respondsToSelector:NSSelectorFromString(@"sendSound")]) {
                SEL sendSel = NSSelectorFromString(@"sendSound");
                NSMethodSignature *sig = [self methodSignatureForSelector:sendSel];
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                [inv setTarget:self];
                [inv setSelector:sendSel];
                [inv invoke];
            }
        }
    });
}

%end