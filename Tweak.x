#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <AVFoundation/AVFoundation.h>

// 1. 动态获取当前 App 沙盒内的 Documents/VoicePacks/test.m4a 路径
static NSString *getSandboxVoicePath() {
    NSString *docPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *voiceDir = [docPath stringByAppendingPathComponent:@"VoicePacks"];
    
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:voiceDir]) {
        [fm createDirectoryAtPath:voiceDir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    return [voiceDir stringByAppendingPathComponent:@"test.m4a"];
}

// 2. 计算音频真实时长
static int getAudioDuration(NSString *path) {
    NSURL *url = [NSURL fileURLWithPath:path];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    CMTime time = asset.duration;
    float seconds = CMTimeGetSeconds(time);
    if (isnan(seconds) || seconds <= 0) return 1;
    return (int)ceil(seconds);
}

// 3. Hook 聊天控制器，在 viewDidLoad 时注入按钮
%hook MessageDetailController

- (void)viewDidLoad {
    %orig; // 执行原始方法
    
    // 延迟一小会儿，等原本的UI渲染完成
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        // 获取底部输入栏视图
        UIView *inputBanner = [self valueForKey:@"inputBannerView"];
        if (!inputBanner) {
            NSLog(@"[VoicePlugin] 没找到 inputBannerView，尝试从子视图查找");
            // 备用方案：遍历搜索
            for (UIView *subview in self.view.subviews) {
                if ([subview isKindOfClass:NSClassFromString(@"HCPLPInputBannerView")] || subview.frame.size.height < 80) {
                    inputBanner = subview; // 粗筛，真实情况可能需要按类名准确找
                    break;
                }
            }
        }
        
        if (inputBanner) {
            // 防止重复添加
            if ([inputBanner viewWithTag:9999]) return;
            
            UIButton *voiceBtn = [UIButton buttonWithType:UIButtonTypeCustom];
            voiceBtn.tag = 9999;
            // 用一个类似语音的图标
            [voiceBtn setImage:[UIImage systemImageNamed:@"waveform"] forState:UIControlStateNormal];
            [voiceBtn setTintColor:[UIColor darkGrayColor]];
            voiceBtn.translatesAutoresizingMaskIntoConstraints = NO;
            [voiceBtn addTarget:self action:@selector(doDirectSendVoice) forControlEvents:UIControlEventTouchUpInside];
            
            [inputBanner addSubview:voiceBtn];
            
            // 自动布局：把它放在右边或者某个合适的位置（这里以放在靠右位置为例）
            [NSLayoutConstraint activateConstraints:@[
                [voiceBtn.centerYAnchor constraintEqualToAnchor:inputBanner.centerYAnchor],
                [voiceBtn.rightAnchor constraintEqualToAnchor:inputBanner.rightAnchor constant:-10], // 距离右边10
                [voiceBtn.widthAnchor constraintEqualToConstant:30],
                [voiceBtn.heightAnchor constraintEqualToConstant:30]
            ]];
            
            NSLog(@"[VoicePlugin] 按钮已成功添加到输入栏！");
        }
    });
}

// 4. 新增一键发送方法
%new
- (void)doDirectSendVoice {
    NSString *customVoicePath = getSandboxVoicePath();
    
    if (![[NSFileManager defaultManager] fileExistsAtPath:customVoicePath]) {
        NSString *msg = [NSString stringWithFormat:@"请把音频文件（建议用 test.m4a）放到沙盒的 Documents/VoicePacks/ 目录下。\n\n路径: %@", customVoicePath];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"找不到语音文件" message:msg preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"我知道了" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    int duration = getAudioDuration(customVoicePath);
    NSLog(@"[VoicePlugin] 直接发送语音: %@，时长: %d 秒", customVoicePath, duration);

    // 构造 V2TIM 语音消息
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

        // 调用自身（MessageDetailController）的发送方法
        SEL sendSel = NSSelectorFromString(@"sendMessage:isRetry:");
        if ([self respondsToSelector:sendSel]) {
            NSMethodSignature *sendSig = [self methodSignatureForSelector:sendSel];
            NSInvocation *sendInv = [NSInvocation invocationWithMethodSignature:sendSig];
            [sendInv setTarget:self];
            [sendInv setSelector:sendSel];
            [sendInv setArgument:&msg atIndex:2];
            BOOL isRetry = NO;
            [sendInv setArgument:&isRetry atIndex:3];
            [sendInv invoke];
            
            NSLog(@"[VoicePlugin] 语音发送成功！");
        } else {
            NSLog(@"[VoicePlugin] 找不到 sendMessage:isRetry: 方法");
        }
    }
}

%end