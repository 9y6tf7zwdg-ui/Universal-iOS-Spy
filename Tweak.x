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

// ===================== 沙盒路径 =====================
static NSString *getVoicePacksDirectory() {
    NSString *docPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *voiceDir = [docPath stringByAppendingPathComponent:@"VoicePacks"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:voiceDir]) {
        [[NSFileManager defaultManager] createDirectoryAtPath:voiceDir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    return voiceDir;
}

static void addLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[VoicePlugin] %@", msg);
    NSString *logPath = [getVoicePacksDirectory() stringByAppendingPathComponent:@"debug.log"];
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"HH:mm:ss";
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [fmt stringFromDate:[NSDate date]], msg];
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

static NSArray<NSString *> *getAllVoiceFiles() {
    NSError *error;
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:getVoicePacksDirectory() error:&error];
    if (error) return @[];
    NSMutableArray *voiceFiles = [NSMutableArray array];
    for (NSString *file in files) {
        NSString *lower = [file lowercaseString];
        if ([lower hasPrefix:@"send_"] || [lower hasPrefix:@"tmp_"] || [lower hasPrefix:@"extract_"]) continue;
        if ([lower hasSuffix:@".wav"] || [lower hasSuffix:@".mp3"] || [lower hasSuffix:@".m4a"] || [lower hasSuffix:@".caf"] || [lower hasSuffix:@".aac"]) {
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

// ===================== 扬声器 =====================
static AVAudioPlayer *sharedAudioPlayer = nil;
static void setupSpeakerPlayback() {
    @try {
        AVAudioSession *session = [AVAudioSession sharedInstance];
        [session setCategory:AVAudioSessionCategoryPlayback error:nil];
        [session setActive:YES error:nil];
    } @catch (NSException *e) {}
}
static void stopPlayingAudio() {
    if (sharedAudioPlayer && sharedAudioPlayer.isPlaying) [sharedAudioPlayer stop];
    sharedAudioPlayer = nil;
}

// ===================== 视频 → WAV：一步到位（抄自早上好.wav 生成源码） =====================
static BOOL convertVideoToVoicePackWAV(NSString *videoPath, NSString *outputPath) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:outputPath]) [fm removeItemAtPath:outputPath error:nil];

    AVAsset *asset = [AVAsset assetWithURL:[NSURL fileURLWithPath:videoPath]];
    NSArray *audioTracks = [asset tracksWithMediaType:AVMediaTypeAudio];
    if (audioTracks.count == 0) { addLog(@"❌ 视频无音频轨道"); return NO; }

    NSError *error = nil;
    AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:&error];
    if (error || !reader) { addLog(@"❌ reader 失败: %@", error); return NO; }

    NSDictionary *outputSettings = @{
        AVFormatIDKey: @(kAudioFormatLinearPCM),
        AVSampleRateKey: @(16000.0),
        AVNumberOfChannelsKey: @(1),
        AVLinearPCMBitDepthKey: @(16),
        AVLinearPCMIsFloatKey: @(NO),
        AVLinearPCMIsBigEndianKey: @(NO),
        AVLinearPCMIsNonInterleaved: @(NO)
    };
    AVAssetReaderTrackOutput *readerOutput = [[AVAssetReaderTrackOutput alloc] initWithTrack:audioTracks.firstObject outputSettings:outputSettings];
    readerOutput.alwaysCopiesSampleData = NO;
    if (![reader canAddOutput:readerOutput]) { addLog(@"❌ canAddOutput 失败"); return NO; }
    [reader addOutput:readerOutput];
    [reader startReading];

    NSMutableData *pcmData = [NSMutableData data];
    CMSampleBufferRef sampleBuffer = NULL;
    int safety = 0;

    while ((sampleBuffer = [readerOutput copyNextSampleBuffer])) {
        if (++safety > 500000) { addLog(@"⚠️ 循环保护"); break; }
        CMBlockBufferRef blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
        size_t length = CMBlockBufferGetDataLength(blockBuffer);
        if (length > 0) {
            char *dataPointer = NULL;
            CMBlockBufferGetDataPointer(blockBuffer, 0, NULL, NULL, &dataPointer);
            [pcmData appendBytes:dataPointer length:length];
        }
        CFRelease(sampleBuffer);
    }

    if (pcmData.length == 0) { addLog(@"❌ 提取 PCM 为空"); return NO; }

    NSMutableData *wavData = [NSMutableData data];
    uint32_t chunkSize = 36 + (uint32_t)pcmData.length;
    uint32_t format = 0x45564157;  // 'WAVE'
    uint32_t subchunk1Size = 16;
    uint16_t audioFormat = 1;      // PCM
    uint16_t numChannels = 1;
    uint32_t sampleRate = 16000;
    uint32_t byteRate = sampleRate * numChannels * 2;
    uint16_t blockAlign = numChannels * 2;
    uint16_t bitsPerSample = 16;
    uint32_t subchunk2Size = (uint32_t)pcmData.length;
    uint32_t dataChunk = 0x61746164;  // 'data'

    [wavData appendBytes:"RIFF" length:4];
    [wavData appendBytes:&chunkSize length:4];
    [wavData appendBytes:&format length:4];
    [wavData appendBytes:"fmt " length:4];
    [wavData appendBytes:&subchunk1Size length:4];
    [wavData appendBytes:&audioFormat length:2];
    [wavData appendBytes:&numChannels length:2];
    [wavData appendBytes:&sampleRate length:4];
    [wavData appendBytes:&byteRate length:4];
    [wavData appendBytes:&blockAlign length:2];
    [wavData appendBytes:&bitsPerSample length:2];
    [wavData appendBytes:&dataChunk length:4];
    [wavData appendBytes:&subchunk2Size length:4];
    [wavData appendData:pcmData];

    NSError *writeErr = nil;
    [wavData writeToFile:outputPath options:NSDataWritingAtomic error:&writeErr];
    if (writeErr) { addLog(@"❌ 写入失败: %@", writeErr); return NO; }

    addLog(@"✅ WAV 生成成功: %@ (%lu 字节)", outputPath.lastPathComponent, (unsigned long)wavData.length);
    return YES;
}

// ===================== 发送：跳过转码，强制发送源文件 =====================
static void sendVoice(NSString *sourcePath) {
    stopPlayingAudio();
    if (!sourcePath || ![[NSFileManager defaultManager] fileExistsAtPath:sourcePath]) {
        addLog(@"❌ 源文件不存在或路径为空: %@", sourcePath);
        return;
    }

    UIViewController *chatVC = findMessageDetailController(topViewController());
    if (!chatVC) {
        addLog(@"❌ 找不到 MessageDetailController");
        return;
    }

    // 详细的发送前诊断
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:sourcePath error:nil];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:sourcePath] options:nil];
    __block int duration = (int)ceil(CMTimeGetSeconds(asset.duration));
    if (duration <= 0) duration = 1;
    
    addLog(@"🚀 准备发送源文件: %@", sourcePath.lastPathComponent);
    addLog(@"📊 文件大小: %llu 字节, 计算时长: %d 秒", [attrs fileSize], duration);
    addLog(@"🎵 音频轨道数: %lu", (unsigned long)[asset tracksWithMediaType:AVMediaTypeAudio].count);

    // 原发送逻辑
    Class v2Mgr = NSClassFromString(@"V2TIMManager");
    id manager = [v2Mgr performSelector:@selector(sharedInstance)];
    SEL createSel = NSSelectorFromString(@"createSoundMessage:duration:");
    if (![manager respondsToSelector:createSel]) {
        addLog(@"❌ V2TIMManager 不响应 createSoundMessage:duration:");
        return;
    }

    NSMethodSignature *sig = [manager methodSignatureForSelector:createSel];
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setTarget:manager];
    [inv setSelector:createSel];
    __unsafe_unretained NSString *pathArg = sourcePath;
    [inv setArgument:&pathArg atIndex:2];
    [inv setArgument:&duration atIndex:3];
    [inv invoke];

    __unsafe_unretained id msg = nil;
    [inv getReturnValue:&msg];
    addLog(@"📨 创建消息结果: %@", msg);

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
        addLog(@"✅ 已调用 sendMessage:isRetry:");
    } else {
        addLog(@"❌ MessageDetailController 不响应 sendMessage:isRetry:");
    }
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
}

- (void)close { stopPlayingAudio(); [self dismissViewControllerAnimated:YES completion:nil]; }

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

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return self.files.count; }

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

// 🚨 这里加入了极详尽的诊断日志
- (void)playAction:(UIButton *)sender {
    NSString *fileName = self.files[sender.tag];
    NSString *path = [getVoicePacksDirectory() stringByAppendingPathComponent:fileName];
    stopPlayingAudio();
    setupSpeakerPlayback();
    
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL exists = [fm fileExistsAtPath:path];
    BOOL readable = [fm isReadableFileAtPath:path];
    NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];

    addLog(@"🎵 ==================== 开始试听 ====================");
    addLog(@"🎵 文件名: %@", fileName);
    addLog(@"📁 绝对路径: %@", path);
    addLog(@"📂 文件是否存在: %@", exists ? @"YES" : @"NO");
    addLog(@"🔐 是否可读: %@", readable ? @"YES" : @"NO");
    addLog(@"⚖️ 文件大小: %llu 字节", [attrs fileSize]);
    addLog(@"🔑 文件权限: %@", attrs[NSFilePosixPermissions] ?: @"未知");
    addLog(@"👤 文件所有者: %@", attrs[NSFileOwnerAccountName] ?: @"未知");

    // 检查 AVAudioSession 当前状态
    AVAudioSession *session = [AVAudioSession sharedInstance];
    addLog(@"🔊 音频会话类别: %@", session.category);
    addLog(@"🔊 音频会话采样率: %.2f", session.sampleRate);
    addLog(@"🔊 音频会话输出声道数: %lu", (unsigned long)session.outputNumberOfChannels);
    addLog(@"🔊 当前输出设备: %@", session.currentRoute.outputs.firstObject.portName ?: @"未知");

    // 尝试通过 AVAsset 预检文件
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
    addLog(@"📊 AVAsset 解析时长: %.2f 秒", CMTimeGetSeconds(asset.duration));
    addLog(@"📊 AVAsset 音频轨道数: %lu", (unsigned long)[asset tracksWithMediaType:AVMediaTypeAudio].count);

    NSError *err = nil;
    sharedAudioPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:path] error:&err];
    if (err) {
        addLog(@"❌ AVAudioPlayer 初始化失败: %@", err);
        addLog(@"❌ 错误 Domain: %@, Code: %ld", err.domain, (long)err.code);
        return;
    }
    if (!sharedAudioPlayer) {
        addLog(@"❌ AVAudioPlayer 为 nil，未知原因");
        return;
    }

    addLog(@"▶️ 播放器初始化成功。持续时长: %.2f 秒, 声道数: %lu", sharedAudioPlayer.duration, (unsigned long)sharedAudioPlayer.numberOfChannels);
    sharedAudioPlayer.volume = 1.0;
    BOOL playResult = [sharedAudioPlayer play];
    addLog(@"▶️ play 方法返回: %@", playResult ? @"YES" : @"NO");

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        addLog(@"⏱️ 1秒后检查播放器状态 - isPlaying: %@, currentTime: %.2f", sharedAudioPlayer.isPlaying ? @"YES" : @"NO", sharedAudioPlayer.currentTime);
    });
}

- (void)sendAction:(UIButton *)sender {
    NSString *fileName = self.files[sender.tag];
    NSString *path = [getVoicePacksDirectory() stringByAppendingPathComponent:fileName];
    [self dismissViewControllerAnimated:YES completion:^{ sendVoice(path); }];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSString *fileName = self.files[indexPath.row];
    NSString *fullPath = [getVoicePacksDirectory() stringByAppendingPathComponent:fileName];

    UIContextualAction *deleteAction = [UIContextualAlertAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"删除" handler:^(UIContextualAction * _Nonnull action, __kindof UIView * _Nonnull sourceView, void (^ _Nonnull completionHandler)(BOOL)) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"确认删除" message:[NSString stringWithFormat:@"确定要删除“%@”吗？", fileName] preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAction * _Nonnull action) { completionHandler(NO); }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
            [[NSFileManager defaultManager] removeItemAtPath:fullPath error:nil];
            [self.files removeObjectAtIndex:indexPath.row];
            [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
            completionHandler(YES);
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[deleteAction]];
}

// ===================== 视频转语音 =====================
- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    if (results.count == 0) { addLog(@"视频选择取消"); return; }

    PHPickerResult *result = results.firstObject;
    if (![result.itemProvider hasItemConformingToTypeIdentifier:UTTypeMovie.identifier]) return;

    [result.itemProvider loadFileRepresentationForTypeIdentifier:UTTypeMovie.identifier completionHandler:^(NSURL *url, NSError *error) {
        if (error || !url) { addLog(@"❌ 加载视频失败: %@", error); return; }

        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:url.lastPathComponent];
        if ([fm fileExistsAtPath:tempPath]) [fm removeItemAtPath:tempPath error:nil];
        NSError *copyErr;
        [fm copyItemAtPath:url.path toPath:tempPath error:&copyErr];
        if (copyErr) { addLog(@"❌ 复制视频失败: %@", copyErr); return; }

        NSString *destName = [NSString stringWithFormat:@"视频语音_%ld.wav", (long)[[NSDate date] timeIntervalSince1970]];
        NSString *destPath = [getVoicePacksDirectory() stringByAppendingPathComponent:destName];

        addLog(@"开始转换: %@", destName);

        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            BOOL ok = convertVideoToVoicePackWAV(tempPath, destPath);
            [[NSFileManager defaultManager] removeItemAtPath:tempPath error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (ok) {
                    self.files = [NSMutableArray arrayWithArray:getAllVoiceFiles()];
                    [self.tableView reloadData];
                    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"✅ 转换成功" message:destName preferredStyle:UIAlertControllerStyleAlert];
                    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
                    [self presentViewController:a animated:YES completion:nil];
                } else {
                    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"转换失败" message:@"视频可能没有音频轨道或格式不支持" preferredStyle:UIAlertControllerStyleAlert];
                    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
                    [self presentViewController:a animated:YES completion:nil];
                }
            });
        });
    }];
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

%hook CWTalkBackView
- (void)sendRecorde:(id)sender {
    VoicePackListVC *vc = [[VoicePackListVC alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [topViewController() presentViewController:nav animated:YES completion:nil];
}
%end

// ===================== 监测原生录音路径 =====================
%hook V2TIMManager

- (id)createSoundMessage:(NSString *)soundPath duration:(int)duration {
    NSString *logMsg = [NSString stringWithFormat:@"\n=== 🎯 拦截到 createSoundMessage ===\n路径: %@\n时长: %d 秒\n==============================\n", soundPath, duration];
    NSString *docPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *voiceDir = [docPath stringByAppendingPathComponent:@"VoicePacks"];
    NSString *logPath = [voiceDir stringByAppendingPathComponent:@"path_tracker.log"];
    [[NSFileManager defaultManager] createDirectoryAtPath:voiceDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:logPath]) {
        [logMsg writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } else {
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:logPath];
        [fh seekToEndOfFile];
        [fh writeData:[logMsg dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
    return %orig;
}
%end