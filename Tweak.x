#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <AVFoundation/AVFoundation.h>
#import <PhotosUI/PhotosUI.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

// ===================== 进度弹窗 =====================
@interface NativeProgressVC : UIViewController
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UILabel *titleLabel;
@end

@implementation NativeProgressVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.preferredContentSize = CGSizeMake(240, 90);

    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [_spinner startAnimating];
    [self.view addSubview:_spinner];

    _titleLabel = [[UILabel alloc] init];
    _titleLabel.font = [UIFont boldSystemFontOfSize:15];
    _titleLabel.textAlignment = NSTextAlignmentCenter;
    _titleLabel.textColor = [UIColor labelColor];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_titleLabel];

    [NSLayoutConstraint activateConstraints:@[
        [_spinner.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_spinner.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor constant:-10],
        [_titleLabel.topAnchor constraintEqualToAnchor:_spinner.bottomAnchor constant:10],
        [_titleLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:15],
        [_titleLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-15]
    ]];
}

- (void)setTitle:(NSString *)title { _titleLabel.text = title; }

@end

@interface MessageDetailController : UIViewController
@end

@interface CWTalkBackView : UIView
- (void)sendRecorde:(id)sender;
@end

@interface VoicePackListVC : UITableViewController <PHPickerViewControllerDelegate, UIDocumentPickerDelegate>
@property (nonatomic, strong) NSMutableArray<NSString *> *files;
@end

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

// ===================== 音频会话：强制用扬声器播放（修复听筒问题） =====================
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

// ===================== 发送：直接发源文件，不转码 =====================
static void sendVoice(NSString *sourcePath) {
    stopPlayingAudio();
    if (!sourcePath || ![[NSFileManager defaultManager] fileExistsAtPath:sourcePath]) return;

    UIViewController *chatVC = findMessageDetailController(topViewController());
    if (!chatVC) return;

    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:sourcePath] options:nil];
    int duration = (int)ceil(CMTimeGetSeconds(asset.duration));
    if (duration <= 0) duration = 1;

    addLog(@"📤 发送: %@, 时长: %d秒", sourcePath.lastPathComponent, duration);

    Class v2Mgr = NSClassFromString(@"V2TIMManager");
    id manager = [v2Mgr performSelector:@selector(sharedInstance)];
    SEL createSel = NSSelectorFromString(@"createSoundMessage:duration:");
    if (![manager respondsToSelector:createSel]) return;

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

    SEL sendSel = NSSelectorFromString(@"sendMessage:isRetry:");
    if (![chatVC respondsToSelector:sendSel]) return;

    NSMethodSignature *sendSig = [chatVC methodSignatureForSelector:sendSel];
    NSInvocation *sendInv = [NSInvocation invocationWithMethodSignature:sendSig];
    [sendInv setTarget:chatVC];
    [sendInv setSelector:sendSel];
    [sendInv setArgument:&msg atIndex:2];
    BOOL retry = NO;
    [sendInv setArgument:&retry atIndex:3];
    [sendInv invoke];
    addLog(@"✅ 发送完成");
}

// ===================== 视频转语音：手动构建 WAV 文件，绝对无格式问题 =====================
static void writeWAVHeader(NSFileHandle *fh, uint32_t dataSize) {
    // RIFF header
    [fh writeData:[@"RIFF" dataUsingEncoding:NSASCIIStringEncoding]];
    uint32_t fileSize = 36 + dataSize;
    [fh writeData:[NSData dataWithBytes:&fileSize length:4]];
    [fh writeData:[@"WAVE" dataUsingEncoding:NSASCIIStringEncoding]];

    // fmt chunk
    [fh writeData:[@"fmt " dataUsingEncoding:NSASCIIStringEncoding]];
    uint32_t fmtSize = 16;
    [fh writeData:[NSData dataWithBytes:&fmtSize length:4]];
    uint16_t audioFormat = 1; // PCM
    [fh writeData:[NSData dataWithBytes:&audioFormat length:2]];
    uint16_t channels = 1;
    [fh writeData:[NSData dataWithBytes:&channels length:2]];
    uint32_t sampleRate = 16000;
    [fh writeData:[NSData dataWithBytes:&sampleRate length:4]];
    uint32_t byteRate = sampleRate * channels * 2; // 32000
    [fh writeData:[NSData dataWithBytes:&byteRate length:4]];
    uint16_t blockAlign = channels * 2; // 2
    [fh writeData:[NSData dataWithBytes:&blockAlign length:2]];
    uint16_t bitsPerSample = 16;
    [fh writeData:[NSData dataWithBytes:&bitsPerSample length:2]];

    // data chunk
    [fh writeData:[@"data" dataUsingEncoding:NSASCIIStringEncoding]];
    [fh writeData:[NSData dataWithBytes:&dataSize length:4]];
}

// 一步转换：直接用 AVAssetReader 读音频轨 → 手动写 WAV 文件
// 无中间文件、无 AVAudioFile、无容器问题
static void convertVideoToWAV(NSString *inputPath, NSString *outputPath, void (^completion)(BOOL success)) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:outputPath]) [fm removeItemAtPath:outputPath error:nil];

    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:inputPath] options:nil];
    AVAssetTrack *audioTrack = [[asset tracksWithMediaType:AVMediaTypeAudio] firstObject];
    if (!audioTrack) { addLog(@"❌ 无音频轨道"); completion(NO); return; }

    NSError *error = nil;
    AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:&error];
    if (error || !reader) { addLog(@"❌ reader 创建失败"); completion(NO); return; }

    // 目标：16kHz 单声道 16bit PCM
    NSDictionary *readerSettings = @{
        AVFormatIDKey: @(kAudioFormatLinearPCM),
        AVSampleRateKey: @16000,
        AVNumberOfChannelsKey: @1,
        AVLinearPCMBitDepthKey: @16,
        AVLinearPCMIsFloatKey: @NO,
        AVLinearPCMIsBigEndianKey: @NO,
        AVLinearPCMIsNonInterleaved: @NO,
    };
    AVAssetReaderTrackOutput *readerOutput = [[AVAssetReaderTrackOutput alloc] initWithTrack:audioTrack outputSettings:readerSettings];
    readerOutput.alwaysCopiesSampleData = NO;
    if (![reader canAddOutput:readerOutput]) { addLog(@"❌ 无法添加 reader output"); completion(NO); return; }
    [reader addOutput:readerOutput];

    // 创建输出文件（先写临时，最后重写 header）
    if (![fm createFileAtPath:outputPath contents:nil attributes:nil]) { completion(NO); return; }
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:outputPath];
    if (!fh) { completion(NO); return; }

    // 先占位 header（44 字节）
    uint8_t zeros[44] = {0};
    [fh writeData:[NSData dataWithBytes:zeros length:44]];

    [reader startReading];
    uint32_t totalBytes = 0;
    int safety = 0;

    while (reader.status == AVAssetReaderStatusReading) {
        if (++safety > 500000) { addLog(@"⚠️ 循环保护"); break; }

        CMSampleBufferRef sampleBuffer = [readerOutput copyNextSampleBuffer];
        if (!sampleBuffer) break;

        CMBlockBufferRef blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
        if (blockBuffer) {
            size_t length = CMBlockBufferGetDataLength(blockBuffer);
            if (length > 0) {
                uint8_t *buffer = malloc(length);
                if (buffer) {
                    CMBlockBufferCopyDataBytes(blockBuffer, 0, length, buffer);
                    [fh writeData:[NSData dataWithBytes:buffer length:length]];
                    totalBytes += (uint32_t)length;
                    free(buffer);
                }
            }
        }
        CFRelease(sampleBuffer);
    }

    // 回到文件开头写正确的 header
    [fh seekToFileOffset:0];
    writeWAVHeader(fh, totalBytes);
    [fh closeFile];

    BOOL ok = (reader.status == AVAssetReaderStatusCompleted) && (totalBytes > 0);
    addLog(@"📊 WAV 转换: %@, 写入 %u 字节", ok ? @"成功" : @"失败", totalBytes);
    completion(ok);
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

// 🚨 修复：试听前强制切换为扬声器播放
- (void)playAction:(UIButton *)sender {
    NSString *fileName = self.files[sender.tag];
    NSString *path = [getVoicePacksDirectory() stringByAppendingPathComponent:fileName];
    stopPlayingAudio();
    setupSpeakerPlayback();
    NSError *err;
    sharedAudioPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:path] error:&err];
    if (!err) {
        sharedAudioPlayer.volume = 1.0;
        [sharedAudioPlayer play];
    }
}

- (void)sendAction:(UIButton *)sender {
    NSString *fileName = self.files[sender.tag];
    NSString *path = [getVoicePacksDirectory() stringByAppendingPathComponent:fileName];
    [self dismissViewControllerAnimated:YES completion:^{ sendVoice(path); }];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString *fileName = self.files[indexPath.row];
    NSString *fullPath = [getVoicePacksDirectory() stringByAppendingPathComponent:fileName];

    UIAlertController *actionSheet = [UIAlertController alertControllerWithTitle:fileName message:@"请选择操作" preferredStyle:UIAlertControllerStyleActionSheet];

    [actionSheet addAction:[UIAlertAction actionWithTitle:@"发送" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self dismissViewControllerAnimated:YES completion:^{ sendVoice(fullPath); }];
    }]];
    [actionSheet addAction:[UIAlertAction actionWithTitle:@"重命名" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self renameFile:fileName atIndexPath:indexPath];
    }]];
    [actionSheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:actionSheet animated:YES completion:nil];
}

- (void)renameFile:(NSString *)fileName atIndexPath:(NSIndexPath *)indexPath {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"重命名" message:@"请输入新的文件名（不包含后缀）" preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.text = [fileName stringByDeletingPathExtension];
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"确认" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        NSString *newName = alert.textFields.firstObject.text;
        if (newName.length == 0) return;
        NSString *ext = [fileName pathExtension];
        NSString *newFileName = [newName stringByAppendingPathExtension:ext];
        NSString *oldPath = [getVoicePacksDirectory() stringByAppendingPathComponent:fileName];
        NSString *newPath = [getVoicePacksDirectory() stringByAppendingPathComponent:newFileName];
        NSError *error;
        [[NSFileManager defaultManager] moveItemAtPath:oldPath toPath:newPath error:&error];
        if (!error) {
            [self.files replaceObjectAtIndex:indexPath.row withObject:newFileName];
            [self.tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSString *fileName = self.files[indexPath.row];
    NSString *fullPath = [getVoicePacksDirectory() stringByAppendingPathComponent:fileName];

    UIContextualAction *deleteAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"删除" handler:^(UIContextualAction * _Nonnull action, __kindof UIView * _Nonnull sourceView, void (^ _Nonnull completionHandler)(BOOL)) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"确认删除" message:[NSString stringWithFormat:@"确定要删除“%@”吗？", fileName] preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction * _Nonnull action) { completionHandler(NO); }]];
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

// ===================== 视频转语音：手动构建 WAV =====================
- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    if (results.count == 0) return;

    PHPickerResult *result = results.firstObject;
    if (![result.itemProvider hasItemConformingToTypeIdentifier:UTTypeMovie.identifier]) return;

    [result.itemProvider loadFileRepresentationForTypeIdentifier:UTTypeMovie.identifier completionHandler:^(NSURL *url, NSError *error) {
        if (error || !url) return;

        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:url.lastPathComponent];
        if ([fm fileExistsAtPath:tempPath]) [fm removeItemAtPath:tempPath error:nil];
        [fm copyItemAtPath:url.path toPath:tempPath error:nil];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self.view) return;

            NativeProgressVC *vc = [[NativeProgressVC alloc] init];
            [vc setTitle:@"正在转换..."];
            UIAlertController *progressAlert = [UIAlertController alertControllerWithTitle:@"视频转语音" message:nil preferredStyle:UIAlertControllerStyleAlert];
            [progressAlert setValue:vc forKey:@"contentViewController"];
            [progressAlert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
            [self presentViewController:progressAlert animated:YES completion:nil];

            NSString *destName = [NSString stringWithFormat:@"视频转语音_%ld.wav", (long)[[NSDate date] timeIntervalSince1970]];
            NSString *destPath = [getVoicePacksDirectory() stringByAppendingPathComponent:destName];

            // 🚨 后台线程执行，绝不卡 UI
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                convertVideoToWAV(tempPath, destPath, ^(BOOL success) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [[NSFileManager defaultManager] removeItemAtPath:tempPath error:nil];
                        [progressAlert dismissViewControllerAnimated:YES completion:^{
                            if (success) {
                                self.files = [NSMutableArray arrayWithArray:getAllVoiceFiles()];
                                [self.tableView reloadData];
                            } else {
                                UIAlertController *a = [UIAlertController alertControllerWithTitle:@"转换失败" message:@"视频可能没有音频轨道" preferredStyle:UIAlertControllerStyleAlert];
                                [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
                                [self presentViewController:a animated:YES completion:nil];
                            }
                        }];
                    });
                });
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