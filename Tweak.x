#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <AVFoundation/AVFoundation.h>
#import <PhotosUI/PhotosUI.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface MessageDetailController : UIViewController
@end

@interface CWTalkBackView : UIView
- (void)sendRecorde:(id)sender;
@end

@interface VoicePackListVC : UITableViewController <PHPickerViewControllerDelegate, UIDocumentPickerDelegate>
@property (nonatomic, strong) NSMutableArray<NSString *> *files;
@end

// ===================== 目录 =====================
static NSString *getVoicePacksDirectory() {
    NSString *docPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *voiceDir = [docPath stringByAppendingPathComponent:@"VoicePacks"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:voiceDir]) {
        [[NSFileManager defaultManager] createDirectoryAtPath:voiceDir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    return voiceDir;
}

// ===================== 日志 =====================
static void addLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"HH:mm:ss";
    NSString *time = [fmt stringFromDate:[NSDate date]];
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", time, msg];

    NSLog(@"[VoicePlugin] %@", msg);

    NSString *logPath = [getVoicePacksDirectory() stringByAppendingPathComponent:@"debug.log"];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:logPath]) {
        [line writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } else {
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:logPath];
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
}

// ===================== 音频信息 =====================
static NSString *audioInfo(NSString *path) {
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
    double duration = CMTimeGetSeconds(asset.duration);
    NSMutableString *s = [NSMutableString stringWithFormat:@"大小=%.2fKB, 时长=%.2fs",
                          [attrs fileSize] / 1024.0, duration];

    AVAssetTrack *track = [[asset tracksWithMediaType:AVMediaTypeAudio] firstObject];
    if (!track) {
        [s appendString:@", 无音频轨道"];
        return s;
    }
    for (id desc in track.formatDescriptions) {
        CMAudioFormatDescriptionRef fmt = (__bridge CMAudioFormatDescriptionRef)desc;
        const AudioStreamBasicDescription *asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt);
        if (asbd) {
            [s appendFormat:@", 采样率=%.0fHz, 声道=%u, 格式ID=%u",
                asbd->mSampleRate, asbd->mChannelsPerFrame, (unsigned int)asbd->mFormatID];
        }
    }
    return s;
}

// ===================== 工具 =====================
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

// ===================== 强制重编码：44100Hz 立体声 → 16000Hz 单声道 =====================
// 关键：用 AVAssetWriter 强制重新编码，避免 AVAssetExportSession 的 pass-through 行为
static void convertToM4A(NSString *inputPath, NSString *outputPath, void (^completion)(BOOL success)) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:outputPath]) [fm removeItemAtPath:outputPath error:nil];

    NSError *error = nil;
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:inputPath] options:nil];
    AVAssetTrack *audioTrack = [[asset tracksWithMediaType:AVMediaTypeAudio] firstObject];
    if (!audioTrack) {
        addLog(@"❌ 源文件无音频轨道");
        completion(NO);
        return;
    }

    AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:&error];
    if (error || !reader) {
        addLog(@"❌ reader 创建失败: %@", error);
        completion(NO);
        return;
    }

    // 读出 PCM 16bit 未压缩数据
    NSDictionary *readerSettings = @{
        AVFormatIDKey: @(kAudioFormatLinearPCM),
        AVLinearPCMIsFloatKey: @NO,
        AVLinearPCMBitDepthKey: @16,
        AVLinearPCMIsNonInterleaved: @NO,
        AVLinearPCMIsBigEndianKey: @NO,
    };
    AVAssetReaderTrackOutput *readerOutput = [[AVAssetReaderTrackOutput alloc] initWithTrack:audioTrack outputSettings:readerSettings];
    readerOutput.alwaysCopiesSampleData = NO;
    if (![reader canAddOutput:readerOutput]) {
        addLog(@"❌ 无法添加 reader output");
        completion(NO);
        return;
    }
    [reader addOutput:readerOutput];

    // 写成 16kHz 单声道 AAC，这就是腾讯云 IM 期望的格式
    NSDictionary *writerSettings = @{
        AVFormatIDKey: @(kAudioFormatMPEG4AAC),
        AVSampleRateKey: @16000,
        AVNumberOfChannelsKey: @1,
        AVEncoderBitRateKey: @32000,
    };
    AVAssetWriter *writer = [[AVAssetWriter alloc] initWithURL:[NSURL fileURLWithPath:outputPath] fileType:AVFileTypeAppleM4A error:&error];
    if (error || !writer) {
        addLog(@"❌ writer 创建失败: %@", error);
        completion(NO);
        return;
    }

    AVAssetWriterInput *writerInput = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeAudio outputSettings:writerSettings];
    writerInput.expectsMediaDataInRealTime = NO;
    if (![writer canAddInput:writerInput]) {
        addLog(@"❌ 无法添加 writer input");
        completion(NO);
        return;
    }
    [writer addInput:writerInput];

    [reader startReading];
    [writer startWriting];
    [writer startSessionAtSourceTime:kCMTimeZero];

    dispatch_queue_t queue = dispatch_queue_create("com.voiceplugin.convert", DISPATCH_QUEUE_SERIAL);
    [writerInput requestMediaDataWhenReadyOnQueue:queue usingBlock:^{
        while ([writerInput isReadyForMoreMediaData]) {
            CMSampleBufferRef buffer = [readerOutput copyNextSampleBuffer];
            if (!buffer) {
                [writerInput markAsFinished];
                [writer finishWritingWithCompletionHandler:^{
                    BOOL ok = (writer.status == AVAssetWriterStatusCompleted);
                    if (!ok) {
                        addLog(@"❌ writer 失败: %@", writer.error);
                    }
                    dispatch_async(dispatch_get_main_queue(), ^{
                        completion(ok);
                    });
                }];
                return;
            }
            [writerInput appendSampleBuffer:buffer];
            CFRelease(buffer);
        }
    }];
}

// ===================== 发送 =====================
static void sendVoice(NSString *sourcePath) {
    stopPlayingAudio();
    addLog(@"========== 开始发送 ==========");

    if (!sourcePath || ![[NSFileManager defaultManager] fileExistsAtPath:sourcePath]) {
        addLog(@"❌ 源文件不存在");
        return;
    }

    addLog(@"📁 源文件: %@", sourcePath);
    addLog(@"📊 源文件信息: %@", audioInfo(sourcePath));

    UIViewController *chatVC = findMessageDetailController(topViewController());
    if (!chatVC) {
        addLog(@"❌ 找不到聊天控制器");
        return;
    }
    addLog(@"✅ 聊天控制器: %@", NSStringFromClass([chatVC class]));

    NSString *outputPath = [getVoicePacksDirectory() stringByAppendingPathComponent:
                            [NSString stringWithFormat:@"send_%ld.m4a", (long)[[NSDate date] timeIntervalSince1970]]];

    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:sourcePath] options:nil];
    __block int duration = (int)ceil(CMTimeGetSeconds(asset.duration));
    if (duration <= 0) duration = 1;

    convertToM4A(sourcePath, outputPath, ^(BOOL success) {
        if (!success) {
            addLog(@"❌ 转码失败，中止发送");
            return;
        }

        addLog(@"📁 转码输出: %@", outputPath);
        addLog(@"📊 转码输出信息: %@", audioInfo(outputPath));

        // 本地播放验证
        NSError *playErr = nil;
        AVAudioPlayer *verifyPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:outputPath] error:&playErr];
        if (playErr || !verifyPlayer) {
            addLog(@"❌ 本地播放器加载失败: %@", playErr);
            return;
        }
        addLog(@"✅ 本地播放器识别时长: %.2f 秒", verifyPlayer.duration);

        Class v2Mgr = NSClassFromString(@"V2TIMManager");
        id manager = [v2Mgr performSelector:@selector(sharedInstance)];
        SEL createSel = NSSelectorFromString(@"createSoundMessage:duration:");
        if (![manager respondsToSelector:createSel]) {
            addLog(@"❌ V2TIMManager 不支持 createSoundMessage");
            return;
        }

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
        addLog(@"✅ 消息构造: %@", msg ? @"成功" : @"失败");

        SEL sendSel = NSSelectorFromString(@"sendMessage:isRetry:");
        if (![chatVC respondsToSelector:sendSel]) {
            addLog(@"❌ 聊天控制器不支持 sendMessage:isRetry:");
            return;
        }

        NSMethodSignature *sendSig = [chatVC methodSignatureForSelector:sendSel];
        NSInvocation *sendInv = [NSInvocation invocationWithMethodSignature:sendSig];
        [sendInv setTarget:chatVC];
        [sendInv setSelector:sendSel];
        [sendInv setArgument:&msg atIndex:2];
        BOOL retry = NO;
        [sendInv setArgument:&retry atIndex:3];
        [sendInv invoke];
        addLog(@"✅ 已调用 sendMessage:isRetry:，发送完成");
        addLog(@"========== 流程结束 ==========");
    });
}

// ===================== 列表 =====================
@implementation VoicePackListVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"选择要发送的语音";
    self.files = [NSMutableArray arrayWithArray:getAllVoiceFiles()];
    self.tableView.rowHeight = 64;
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"cell"];

    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(close)];

    self.navigationController.toolbarHidden = NO;
    UIBarButtonItem *videoBtn = [[UIBarButtonItem alloc] initWithTitle:@"视频转语音" style:UIBarButtonItemStylePlain target:self action:@selector(videoAction)];
    UIBarButtonItem *importBtn = [[UIBarButtonItem alloc] initWithTitle:@"导入语音包" style:UIBarButtonItemStylePlain target:self action:@selector(importAction)];
    UIBarButtonItem *space1 = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    UIBarButtonItem *space2 = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    self.toolbarItems = @[videoBtn, space1, importBtn, space2];

    addLog(@"列表打开，找到 %lu 个语音文件", (unsigned long)self.files.count);
}

- (void)close {
    stopPlayingAudio();
    addLog(@"用户取消");
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)videoAction {
    addLog(@"点击视频转语音");
    PHPickerConfiguration *config = [[PHPickerConfiguration alloc] init];
    config.filter = PHPickerFilter.videosFilter;
    config.selectionLimit = 1;
    PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:config];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)importAction {
    addLog(@"点击导入语音包");
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeAudio] asCopy:YES];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.files.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell" forIndexPath:indexPath];
    NSString *fileName = self.files[indexPath.row];
    NSString *fullPath = [getVoicePacksDirectory() stringByAppendingPathComponent:fileName];

    cell.textLabel.text = fileName;
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:fullPath error:nil];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%.2f KB", [attrs fileSize] / 1024.0];

    UIView *rightView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 100, 40)];

    UIButton *playBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    playBtn.frame = CGRectMake(0, 5, 40, 30);
    if (@available(iOS 13.0, *)) [playBtn setImage:[UIImage systemImageNamed:@"play.circle.fill"] forState:UIControlStateNormal];
    playBtn.tag = indexPath.row;
    [playBtn addTarget:self action:@selector(playAction:) forControlEvents:UIControlEventTouchUpInside];
    [rightView addSubview:playBtn];

    UIButton *sendBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    sendBtn.frame = CGRectMake(50, 5, 50, 30);
    [sendBtn setTitle:@"发送" forState:UIControlStateNormal];
    sendBtn.tag = indexPath.row;
    [sendBtn addTarget:self action:@selector(sendAction:) forControlEvents:UIControlEventTouchUpInside];
    [rightView addSubview:sendBtn];

    cell.accessoryView = rightView;
    return cell;
}

- (void)playAction:(UIButton *)sender {
    NSString *fileName = self.files[sender.tag];
    NSString *path = [getVoicePacksDirectory() stringByAppendingPathComponent:fileName];
    addLog(@"试听: %@", fileName);
    stopPlayingAudio();
    sharedAudioPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:path] error:nil];
    [sharedAudioPlayer play];
}

- (void)sendAction:(UIButton *)sender {
    NSString *fileName = self.files[sender.tag];
    NSString *path = [getVoicePacksDirectory() stringByAppendingPathComponent:fileName];
    addLog(@"点击发送: %@", fileName);
    [self dismissViewControllerAnimated:YES completion:^{
        sendVoice(path);
    }];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString *fileName = self.files[indexPath.row];
    NSString *path = [getVoicePacksDirectory() stringByAppendingPathComponent:fileName];
    addLog(@"点击列表项: %@", fileName);
    [self dismissViewControllerAnimated:YES completion:^{
        sendVoice(path);
    }];
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    if (results.count == 0) {
        addLog(@"视频选择取消");
        return;
    }
    addLog(@"选中视频，开始转码");
    PHPickerResult *result = results.firstObject;
    if ([result.itemProvider hasItemConformingToTypeIdentifier:UTTypeMovie.identifier]) {
        [result.itemProvider loadFileRepresentationForTypeIdentifier:UTTypeMovie.identifier completionHandler:^(NSURL *url, NSError *error) {
            if (error || !url) {
                addLog(@"加载视频失败: %@", error);
                return;
            }
            NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:url.lastPathComponent];
            NSFileManager *fm = [NSFileManager defaultManager];
            if ([fm fileExistsAtPath:tempPath]) [fm removeItemAtPath:tempPath error:nil];
            [fm copyItemAtPath:url.path toPath:tempPath error:&error];
            if (error) {
                addLog(@"复制视频失败: %@", error);
                return;
            }
            NSString *destName = [NSString stringWithFormat:@"视频转语音_%ld.m4a", (long)[[NSDate date] timeIntervalSince1970]];
            NSString *destPath = [getVoicePacksDirectory() stringByAppendingPathComponent:destName];
            convertToM4A(tempPath, destPath, ^(BOOL success) {
                if (success) {
                    addLog(@"视频转语音成功: %@", destName);
                    self.files = [NSMutableArray arrayWithArray:getAllVoiceFiles()];
                    [self.tableView reloadData];
                }
            });
        }];
    }
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (urls.count == 0) {
        addLog(@"文件选择取消");
        return;
    }
    NSURL *url = urls.firstObject;
    addLog(@"导入文件: %@", url.lastPathComponent);
    NSString *destPath = [getVoicePacksDirectory() stringByAppendingPathComponent:url.lastPathComponent];
    [[NSFileManager defaultManager] removeItemAtPath:destPath error:nil];
    NSError *error;
    [[NSFileManager defaultManager] copyItemAtPath:url.path toPath:destPath error:&error];
    if (!error) {
        addLog(@"导入成功");
        self.files = [NSMutableArray arrayWithArray:getAllVoiceFiles()];
        [self.tableView reloadData];
    } else {
        addLog(@"导入失败: %@", error);
    }
}

@end

// ===================== 方案 C =====================
%hook CWTalkBackView

- (void)sendRecorde:(id)sender {
    addLog(@"拦截到 sendRecorde，弹出语音列表");
    VoicePackListVC *vc = [[VoicePackListVC alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [topViewController() presentViewController:nav animated:YES completion:nil];
}

%end