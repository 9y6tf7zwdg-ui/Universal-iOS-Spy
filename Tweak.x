#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <AVFoundation/AVFoundation.h>
#import <PhotosUI/PhotosUI.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface MessageDetailController : UIViewController
- (void)sendSound;
- (void)sendMessage:(id)msg isRetry:(BOOL)retry;
@end

@interface CWTalkBackView : UIView
- (void)sendRecorde:(id)sender;
@end

@interface VoicePackListVC : UITableViewController <PHPickerViewControllerDelegate, UIDocumentPickerDelegate>
@property (nonatomic, strong) NSMutableArray<NSString *> *files;
@property (nonatomic, copy) void (^onSelect)(NSString *path);
@property (nonatomic, copy) void (^onCancel)(void);
@end

static NSString *getVoicePacksDirectory() {
    NSString *docPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *voiceDir = [docPath stringByAppendingPathComponent:@"VoicePacks"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:voiceDir]) {
        [[NSFileManager defaultManager] createDirectoryAtPath:voiceDir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    return voiceDir;
}

static NSArray<NSString *> *getAllVoiceFiles() {
    NSError *error;
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:getVoicePacksDirectory() error:&error];
    if (error) return @[];
    NSMutableArray *voiceFiles = [NSMutableArray array];
    for (NSString *file in files) {
        NSString *lower = [file lowercaseString];
        if ([lower hasSuffix:@".wav"] || [lower hasSuffix:@".mp3"] || [lower hasSuffix:@".m4a"] || [lower hasSuffix:@".caf"]) {
            [voiceFiles addObject:file];
        }
    }
    return voiceFiles;
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

static UIViewController *findMessageDetailController(UIViewController *vc) {
    if ([vc isKindOfClass:NSClassFromString(@"MessageDetailController")]) return vc;
    for (UIViewController *child in vc.childViewControllers) {
        UIViewController *found = findMessageDetailController(child);
        if (found) return found;
    }
    if (vc.presentedViewController) return findMessageDetailController(vc.presentedViewController);
    return nil;
}

static AVAudioPlayer *sharedAudioPlayer = nil;
static void stopPlayingAudio() {
    if (sharedAudioPlayer && sharedAudioPlayer.isPlaying) [sharedAudioPlayer stop];
    sharedAudioPlayer = nil;
}

static BOOL g_skipIntercept = NO;

// ===================== 语音列表 =====================
@implementation VoicePackListVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"选择要发送的语音";
    self.files = [NSMutableArray arrayWithArray:getAllVoiceFiles()];
    self.tableView.rowHeight = 64;
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"cell"];
    
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(cancel)];
    
    self.navigationController.toolbarHidden = NO;
    UIBarButtonItem *videoBtn = [[UIBarButtonItem alloc] initWithTitle:@"视频转语音" style:UIBarButtonItemStylePlain target:self action:@selector(videoAction)];
    UIBarButtonItem *importBtn = [[UIBarButtonItem alloc] initWithTitle:@"导入语音包" style:UIBarButtonItemStylePlain target:self action:@selector(importAction)];
    UIBarButtonItem *space = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    UIBarButtonItem *space2 = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    self.toolbarItems = @[videoBtn, space, importBtn, space2, [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil]];
}

- (void)cancel {
    stopPlayingAudio();
    if (self.onCancel) self.onCancel();
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)videoAction {
    PHPickerConfiguration *config = [[PHPickerConfiguration alloc] init];
    config.filter = PHPickerFilter.videosFilter;
    config.selectionLimit = 1;
    PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:config];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)importAction {
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeAudio] asCopy:YES];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.files.count + 1;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell" forIndexPath:indexPath];
    UIView *rightView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 60, 40)];
    
    if (indexPath.row == 0) {
        cell.textLabel.text = @"🎤 使用刚录制的语音";
        cell.detailTextLabel.text = @"点击发送刚才按住的录音";
    } else {
        NSString *fileName = self.files[indexPath.row - 1];
        NSString *fullPath = [getVoicePacksDirectory() stringByAppendingPathComponent:fileName];
        cell.textLabel.text = fileName;
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:fullPath error:nil];
        double size = [attrs fileSize] / 1024.0;
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%.2f KB", size];
        
        UIButton *playBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        playBtn.frame = CGRectMake(0, 5, 50, 30);
        [playBtn setImage:[UIImage systemImageNamed:@"play.circle.fill"] forState:UIControlStateNormal];
        playBtn.tag = indexPath.row - 1;
        [playBtn addTarget:self action:@selector(playAction:) forControlEvents:UIControlEventTouchUpInside];
        [rightView addSubview:playBtn];
    }
    cell.accessoryView = rightView;
    return cell;
}

- (void)playAction:(UIButton *)sender {
    NSString *fileName = self.files[sender.tag];
    NSString *path = [getVoicePacksDirectory() stringByAppendingPathComponent:fileName];
    stopPlayingAudio();
    NSError *err;
    sharedAudioPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:path] error:&err];
    if (!err && sharedAudioPlayer) [sharedAudioPlayer play];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    stopPlayingAudio();
    
    NSString *selectedPath = nil;
    if (indexPath.row > 0) {
        NSString *fileName = self.files[indexPath.row - 1];
        selectedPath = [getVoicePacksDirectory() stringByAppendingPathComponent:fileName];
    }
    if (self.onSelect) self.onSelect(selectedPath);
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    if (results.count == 0) return;
    PHPickerResult *result = results.firstObject;
    if ([result.itemProvider hasItemConformingToTypeIdentifier:UTTypeMovie.identifier]) {
        [result.itemProvider loadFileRepresentationForTypeIdentifier:UTTypeMovie.identifier completionHandler:^(NSURL *url, NSError *error) {
            if (error || !url) return;
            NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:url.lastPathComponent];
            NSFileManager *fm = [NSFileManager defaultManager];
            if ([fm fileExistsAtPath:tempPath]) [fm removeItemAtPath:tempPath error:nil];
            [fm copyItemAtPath:url.path toPath:tempPath error:&error];
            if (error) return;
            NSString *destName = [NSString stringWithFormat:@"视频转语音_%ld.m4a", (long)[[NSDate date] timeIntervalSince1970]];
            NSString *destPath = [getVoicePacksDirectory() stringByAppendingPathComponent:destName];
            AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:tempPath] options:nil];
            AVAssetExportSession *session = [[AVAssetExportSession alloc] initWithAsset:asset presetName:AVAssetExportPresetAppleM4A];
            session.outputURL = [NSURL fileURLWithPath:destPath];
            session.outputFileType = AVFileTypeAppleM4A;
            [session exportAsynchronouslyWithCompletionHandler:^{
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (session.status == AVAssetExportSessionStatusCompleted) {
                        self.files = [NSMutableArray arrayWithArray:getAllVoiceFiles()];
                        [self.tableView reloadData];
                    }
                });
            }];
        }];
    }
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (urls.count == 0) return;
    NSURL *url = urls.firstObject;
    NSString *destPath = [getVoicePacksDirectory() stringByAppendingPathComponent:url.lastPathComponent];
    [[NSFileManager defaultManager] removeItemAtPath:destPath error:nil];
    NSError *error;
    [[NSFileManager defaultManager] copyItemAtPath:url.path toPath:destPath error:&error];
    if (!error) {
        self.files = [NSMutableArray arrayWithArray:getAllVoiceFiles()];
        [self.tableView reloadData];
    }
}

@end

// ===================== 核心：拦截松手发送，用 V2TIM API 直接发 =====================
%hook CWTalkBackView

- (void)sendRecorde:(id)sender {
    if (g_skipIntercept) {
        g_skipIntercept = NO;
        %orig;
        return;
    }
    
    NSLog(@"[VoicePlugin] 拦截 sendRecorde，弹出列表");
    
    VoicePackListVC *vc = [[VoicePackListVC alloc] init];
    vc.onSelect = ^(NSString *path) {
        if (!path) {
            // 使用原录音，走原生
            g_skipIntercept = YES;
            NSLog(@"[VoicePlugin] 用户使用原录音");
            return;
        }
        
        // 用户选择了预设音频，转码后通过 V2TIM API 直接发送
        NSString *outputPath = [getVoicePacksDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"send_%ld.m4a", (long)[[NSDate date] timeIntervalSince1970]]];
            
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
        __block int duration = (int)ceil(CMTimeGetSeconds(asset.duration));
        if (duration <= 0) duration = 1;
        
        AVAssetExportSession *session = [[AVAssetExportSession alloc] initWithAsset:asset presetName:AVAssetExportPresetAppleM4A];
        session.outputURL = [NSURL fileURLWithPath:outputPath];
        session.outputFileType = AVFileTypeAppleM4A;
        
        [session exportAsynchronouslyWithCompletionHandler:^{
            dispatch_async(dispatch_get_main_queue(), ^{
                NSDictionary *outAttrs = [[NSFileManager defaultManager] attributesOfItemAtPath:outputPath error:nil];
                if (session.status != AVAssetExportSessionStatusCompleted || !outAttrs || [outAttrs fileSize] == 0) {
                    NSLog(@"[VoicePlugin] 转码失败");
                    return;
                }
                
                // 获取聊天控制器
                UIViewController *chatVC = findMessageDetailController(topViewController());
                if (!chatVC) {
                    NSLog(@"[VoicePlugin] 找不到聊天控制器");
                    return;
                }
                
                // 提取接收者
                NSString *receiver = nil;
                @try { receiver = [chatVC valueForKey:@"friendUserId"]; } @catch (NSException *e) {}
                NSLog(@"[VoicePlugin] 接收者: %@", receiver);
                
                // 构造 V2TIM 消息
                Class v2MgrClass = NSClassFromString(@"V2TIMManager");
                id manager = [v2MgrClass performSelector:@selector(sharedInstance)];
                
                SEL createSel = NSSelectorFromString(@"createSoundMessage:duration:");
                if ([manager respondsToSelector:createSel]) {
                    NSMethodSignature *sig = [manager methodSignatureForSelector:createSel];
                    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                    [inv setTarget:manager];
                    [inv setSelector:createSel];
                    __unsafe_unretained NSString *pathArg = outputPath;
                    [inv setArgument:&pathArg atIndex:2];
                    [inv setArgument:&duration atIndex:3];
                    [inv invoke];
                    
                    __unsafe_unretained id msg = nil;
                    [inv getReturnValue:&msg];
                    
                    // 用 App 自己的 sendMessage:isRetry: 发送
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
                        NSLog(@"[VoicePlugin] 已调用 sendMessage:isRetry: 发送");
                    } else {
                        NSLog(@"[VoicePlugin] 聊天控制器不支持 sendMessage:isRetry:");
                    }
                }
            });
        }];
    };
    
    vc.onCancel = ^{
        g_skipIntercept = YES;
        NSLog(@"[VoicePlugin] 用户取消");
    };
    
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [topViewController() presentViewController:nav animated:YES completion:nil];
}

%end

// 拦截原生发送，避免用户点击后重复发送原录音
%hook MessageDetailController
- (void)sendSound {
    if (g_skipIntercept) {
        g_skipIntercept = NO;
        return;
    }
    NSLog(@"[VoicePlugin] 拦截 sendSound，不发送");
}
%end