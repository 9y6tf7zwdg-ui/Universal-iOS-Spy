#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <AVFoundation/AVFoundation.h>

@interface MessageDetailController : UIViewController
@end

// 存放转换后音频的路径
static NSString *convertedVoicePath = nil;

// 1. 自动转码器：把任意音频转为 M4A
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
            if (session.status == AVAssetExportSessionStatusCompleted) {
                completion(YES);
            } else {
                completion(NO);
            }
        });
    }];
}

// 2. 获取沙盒源文件路径
static NSString *getSourceVoicePath() {
    NSString *docPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *voiceDir = [docPath stringByAppendingPathComponent:@"VoicePacks"];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:voiceDir]) {
        [fm createDirectoryAtPath:voiceDir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    // 检测源文件，优先 wav，其次 mp3，最后 m4a
    NSArray *exts = @[@"wav", @"mp3", @"m4a"];
    for (NSString *ext in exts) {
        NSString *path = [voiceDir stringByAppendingPathComponent:[NSString stringWithFormat:@"test.%@", ext]];
        if ([fm fileExistsAtPath:path]) return path;
    }
    return nil;
}

// 3. Hook 录音路径
%hook CWRecorder

- (NSString *)recordPath {
    if (convertedVoicePath && [[NSFileManager defaultManager] fileExistsAtPath:convertedVoicePath]) {
        NSLog(@"[VoicePlugin] 拦截录音路径，替换为: %@", convertedVoicePath);
        return convertedVoicePath;
    }
    return %orig;
}

%end

// 4. Hook 聊天控制器
%hook MessageDetailController

- (void)viewDidLoad {
    %orig;
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIView *inputBanner = [self valueForKey:@"inputBannerView"];
        if (!inputBanner) return;
        
        if ([inputBanner viewWithTag:9999]) return;
        
        UIButton *voiceBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        voiceBtn.tag = 9999;
        [voiceBtn setImage:[UIImage systemImageNamed:@"waveform"] forState:UIControlStateNormal];
        [voiceBtn setTintColor:[UIColor darkGrayColor]];
        voiceBtn.translatesAutoresizingMaskIntoConstraints = NO;
        [voiceBtn addTarget:self action:@selector(doDirectSendVoice) forControlEvents:UIControlEventTouchUpInside];
        
        [inputBanner addSubview:voiceBtn];
        [NSLayoutConstraint activateConstraints:@[
            [voiceBtn.centerYAnchor constraintEqualToAnchor:inputBanner.centerYAnchor],
            [voiceBtn.rightAnchor constraintEqualToAnchor:inputBanner.rightAnchor constant:-10],
            [voiceBtn.widthAnchor constraintEqualToConstant:30],
            [voiceBtn.heightAnchor constraintEqualToConstant:30]
        ]];
    });
}

// 5. 核心逻辑：转码 + 触发发送
%new
- (void)doDirectSendVoice {
    NSString *sourcePath = getSourceVoicePath();
    if (!sourcePath) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"找不到源文件" message:@"请在沙盒 Documents/VoicePacks/ 目录下放置 test.wav 或 test.mp3" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    
    NSString *docPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *outputPath = [docPath stringByAppendingPathComponent:@"VoicePacks/converted_voice.m4a"];
    
    NSLog(@"[VoicePlugin] 开始转码: %@ -> %@", sourcePath, outputPath);
    
    convertToM4A(sourcePath, outputPath, ^(BOOL success) {
        if (success) {
            NSLog(@"[VoicePlugin] 转码成功，准备发送");
            convertedVoicePath = outputPath;
            
            // 🚨 修复点：用 NSInvocation 替代 performSelector，解决编译报错
            SEL sendSel = NSSelectorFromString(@"sendSound");
            if ([self respondsToSelector:sendSel]) {
                NSMethodSignature *sendSig = [self methodSignatureForSelector:sendSel];
                NSInvocation *sendInv = [NSInvocation invocationWithMethodSignature:sendSig];
                [sendInv setTarget:self];
                [sendInv setSelector:sendSel];
                [sendInv invoke];
            } else {
                NSLog(@"[VoicePlugin] 找不到 sendSound 方法");
            }
        } else {
            NSLog(@"[VoicePlugin] 转码失败");
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"转码失败" message:@"源文件格式无法转换，请确保音频未损坏。" preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
        }
    });
}

%end