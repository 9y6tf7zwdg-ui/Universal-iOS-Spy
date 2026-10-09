#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <AVFoundation/AVFoundation.h>

@interface MessageDetailController : UIViewController
@end

// 动态获取当前 App 沙盒内的 Documents/VoicePacks/test.m4a 路径
static NSString *getSandboxVoicePath() {
    NSString *docPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *voiceDir = [docPath stringByAppendingPathComponent:@"VoicePacks"];
    
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:voiceDir]) {
        [fm createDirectoryAtPath:voiceDir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    return [voiceDir stringByAppendingPathComponent:@"test.m4a"];
}

%hook MessageDetailController

- (void)viewDidLoad {
    %orig;
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIView *inputBanner = [self valueForKey:@"inputBannerView"];
        if (!inputBanner) {
            for (UIView *subview in self.view.subviews) {
                if (subview.frame.size.height < 80 && subview.frame.size.height > 40) {
                    inputBanner = subview;
                    break;
                }
            }
        }
        
        if (inputBanner) {
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
        }
    });
}

%new
- (void)doDirectSendVoice {
    NSString *customVoicePath = getSandboxVoicePath();
    
    if (![[NSFileManager defaultManager] fileExistsAtPath:customVoicePath]) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"找不到语音文件" message:[NSString stringWithFormat:@"请把音频文件放到: %@", customVoicePath] preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    NSLog(@"[VoicePlugin] 尝试走内部录音与发送流程: %@", customVoicePath);

    // 1. 尝试获取 CWRecorder 实例
    id recorder = nil;
    @try {
        recorder = [self valueForKey:@"recorder"]; // 尝试 KVC 获取
    } @catch (NSException *exception) {
        NSLog(@"[VoicePlugin] KVC 找不到 recorder 属性");
    }
    
    // 如果 KVC 失败，尝试在子视图中找 CWTalkBackView 或 CWRecordView
    if (!recorder) {
        for (UIView *sub in self.view.subviews) {
            if ([sub isKindOfClass:NSClassFromString(@"CWTalkBackView")] || [sub isKindOfClass:NSClassFromString(@"CWRecordView")]) {
                recorder = sub;
                break;
            }
        }
    }
    
    if (recorder && [recorder respondsToSelector:NSSelectorFromString(@"beginRecordWithRecordPath:")]) {
        // 欺骗 App：开始录音，但传入我们的路径
        SEL beginSel = NSSelectorFromString(@"beginRecordWithRecordPath:");
        NSMethodSignature *beginSig = [recorder methodSignatureForSelector:beginSel];
        NSInvocation *beginInv = [NSInvocation invocationWithMethodSignature:beginSig];
        [beginInv setTarget:recorder];
        [beginInv setSelector:beginSel];
        [beginInv setArgument:&customVoicePath atIndex:2];
        [beginInv invoke];
        
        // 立刻结束录音，触发 App 内部状态机
        if ([recorder respondsToSelector:NSSelectorFromString(@"endRecord")]) {
            [recorder performSelector:NSSelectorFromString(@"endRecord")];
        }
        
        // 调用 MessageDetailController 自己的发送方法，此时它会拿到我们刚刚“录制”的路径
        if ([self respondsToSelector:NSSelectorFromString(@"sendSound")]) {
            [self performSelector:NSSelectorFromString(@"sendSound")];
            NSLog(@"[VoicePlugin] 成功触发内部发送流程");
        }
    } else {
        NSLog(@"[VoicePlugin] 找不到 CWRecorder 实例或方法，无法走内部流程");
        // 备用方案：如果找不到 recorder，只能弹窗提示
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"发送失败" message:@"无法获取底层录音器，请检查是否在聊天界面。" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

%end