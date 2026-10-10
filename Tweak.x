#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <AVFoundation/AVFoundation.h>
#import <PhotosUI/PhotosUI.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

// ===================== 进度条 HUD =====================
@interface ProgressHUD : UIView
@property (nonatomic, strong) UIProgressView *progressView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, weak) AVAssetExportSession *session;
@property (nonatomic, weak) UIView *container;
+ (instancetype)shared;
- (void)showOnView:(UIView *)view title:(NSString *)title;
- (void)trackSession:(AVAssetExportSession *)session;
- (void)updateProgress:(float)progress;
- (void)dismiss;
@end

static ProgressHUD *g_hud = nil;

@implementation ProgressHUD

+ (instancetype)shared {
    if (!g_hud) {
        g_hud = [[ProgressHUD alloc] initWithFrame:CGRectZero];
    }
    return g_hud;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithWhite:0 alpha:0.5];
        self.layer.cornerRadius = 12;

        _titleLabel = [[UILabel alloc] init];
        _titleLabel.textColor = [UIColor whiteColor];
        _titleLabel.font = [UIFont boldSystemFontOfSize:14];
        _titleLabel.textAlignment = NSTextAlignmentCenter;
        [self addSubview:_titleLabel];

        _progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
        _progressView.progressTintColor = [UIColor colorWithRed:0.2 green:0.6 blue:1.0 alpha:1.0];
        _progressView.trackTintColor = [UIColor colorWithWhite:1 alpha:0.3];
        [self addSubview:_progressView];
    }
    return self;
}

- (void)showOnView:(UIView *)view title:(NSString *)title {
    self.container = view;
    self.titleLabel.text = title;
    self.progressView.progress = 0;

    CGFloat w = 200, h = 80;
    self.frame = CGRectMake((view.bounds.size.width - w) / 2,
                            (view.bounds.size.height - h) / 2,
                            w, h);
    self.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin |
                            UIViewAutoresizingFlexibleRightMargin |
                            UIViewAutoresizingFlexibleTopMargin |
                            UIViewAutoresizingFlexibleBottomMargin;

    self.titleLabel.frame = CGRectMake(10, 15, w - 20, 20);
    self.progressView.frame = CGRectMake(20, 50, w - 40, 4);

    [view addSubview:self];
    [view bringSubviewToFront:self];

    // 每 0.1 秒刷新一次进度
    [self.timer invalidate];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.1 target:self selector:@selector(tick) userInfo:nil repeats:YES];
}

- (void)trackSession:(AVAssetExportSession *)session {
    self.session = session;
}

- (void)tick {
    if (self.session) {
        float p = self.session.progress;
        if (p > 0 && p <= 1.0) {
            [self.progressView setProgress:p animated:YES];
        }
    }
}

- (void)updateProgress:(float)progress {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.progressView setProgress:progress animated:YES];
    });
}

- (void)dismiss {
    [self.timer invalidate];
    self.timer = nil;
    self.session = nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self removeFromSuperview];
    });
}

@end

// ===================== 基础声明 =====================
@interface MessageDetailController : UIViewController
@end

@interface CWTalkBackView : UIView
- (void)sendRecorde:(id)sender;
@end

@interface VoicePackListVC : UITableViewController <PHPickerViewControllerDelegate, UIDocumentPickerDelegate>
@property (nonatomic, strong) NSMutableArray<NSString *> *files;
@end

// ===================== 工具 =====================
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
        if ([lower hasPrefix:@"send_"]) continue;
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

static AVAudioPlayer *sharedAudioPlayer = nil;
static void stopPlayingAudio() {
    if (sharedAudioPlayer && sharedAudioPlayer.isPlaying) [sharedAudioPlayer stop];
    sharedAudioPlayer = nil;
}

// ===================== 转码 AAC =====================
static void convertToAAC(NSString *inputPath, NSString *outputPath, void (^completion)(BOOL success)) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:outputPath]) [fm removeItemAtPath:outputPath error:nil];

    @autoreleasepool {
        NSError *error = nil;
        AVAudioFile *inFile = [[AVAudioFile alloc] initForReading:[NSURL fileURLWithPath:inputPath] error:&error];
        if (error || !inFile) { addLog(@"❌ 读取源文件失败: %@", error); completion(NO); return; }

        NSDictionary *outSettings = @{
            AVFormatIDKey: @(kAudioFormatMPEG4AAC),
            AVSampleRateKey: @8000,
            AVNumberOfChannelsKey: @1,
            AVEncoderBitRateKey: @16000,
        };

        AVAudioFile *outFile = [[AVAudioFile alloc] initForWriting:[NSURL fileURLWithPath:outputPath]
                                                          settings:outSettings
                                                     commonFormat:AVAudioPCMFormatInt16
                                                      interleaved:NO
                                                            error:&error];
        if (error || !outFile) { addLog(@"❌ 创建输出文件失败: %@", error); completion(NO); return; }

        AVAudioConverter *converter = [[AVAudioConverter alloc] initFromFormat:inFile.processingFormat toFormat:outFile.processingFormat];
        if (!converter) { addLog(@"❌ Converter 创建失败"); outFile = nil; completion(NO); return; }

        AVAudioFrameCount capacity = 4096;
        AVAudioPCMBuffer *inBuf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:inFile.processingFormat frameCapacity:capacity];
        AVAudioPCMBuffer *outBuf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:outFile.processingFormat frameCapacity:capacity];

        BOOL writeError = NO;
        while (1) {
            NSError *convError = nil;
            AVAudioConverterOutputStatus status = [converter convertToBuffer:outBuf error:&convError withInputFromBlock:^AVAudioBuffer * _Nullable(AVAudioPacketCount inNumberOfPackets, AVAudioConverterInputStatus * _Nonnull outStatus) {
                NSError *readError = nil;
                [inFile readIntoBuffer:inBuf error:&readError];
                if (readError || inBuf.frameLength == 0) {
                    *outStatus = AVAudioConverterInputStatus_EndOfStream;
                    return nil;
                }
                *outStatus = AVAudioConverterInputStatus_HaveData;
                return inBuf;
            }];

            if (status == AVAudioConverterOutputStatus_Error) { addLog(@"❌ 转换错误: %@", convError); writeError = YES; break; }
            if (outBuf.frameLength > 0) {
                NSError *writeErr = nil;
                [outFile writeFromBuffer:outBuf error:&writeErr];
                if (writeErr) { addLog(@"❌ 写入错误: %@", writeErr); writeError = YES; break; }
            }
            if (status == AVAudioConverterOutputStatus_EndOfStream) break;
        }
        outFile = nil;
        inFile = nil;
        completion(!writeError);
    }
}

// ===================== 音频剪辑 =====================
static void clipAudio(NSString *sourcePath, NSString *outputPath, NSTimeInterval start, NSTimeInterval end, void (^completion)(BOOL success)) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:outputPath]) [fm removeItemAtPath:outputPath error:nil];

    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:sourcePath] options:nil];
    AVAssetExportSession *session = [[AVAssetExportSession alloc] initWithAsset:asset presetName:AVAssetExportPresetAppleM4A];
    session.outputURL = [NSURL fileURLWithPath:outputPath];
    session.outputFileType = AVFileTypeAppleM4A;
    session.timeRange = CMTimeRangeMake(CMTimeMakeWithSeconds(start, 1000), CMTimeMakeWithSeconds(end - start, 1000));

    [session exportAsynchronouslyWithCompletionHandler:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(session.status == AVAssetExportSessionStatusCompleted);
        });
    }];
}

// ===================== 发送 =====================
static void sendVoice(NSString *sourcePath) {
    stopPlayingAudio();
    if (!sourcePath || ![[NSFileManager defaultManager] fileExistsAtPath:sourcePath]) return;

    UIViewController *chatVC = findMessageDetailController(topViewController());
    if (!chatVC) return;

    NSString *outputPath = [getVoicePacksDirectory() stringByAppendingPathComponent:
                            [NSString stringWithFormat:@"send_%ld.aac", (long)[[NSDate date] timeIntervalSince1970]]];

    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:sourcePath] options:nil];
    __block int duration = (int)ceil(CMTimeGetSeconds(asset.duration));
    if (duration <= 0) duration = 1;

    convertToAAC(sourcePath, outputPath, ^(BOOL success) {
        if (!success) return;

        Class v2Mgr = NSClassFromString(@"V2TIMManager");
        id manager = [v2Mgr performSelector:@selector(sharedInstance)];
        SEL createSel = NSSelectorFromString(@"createSoundMessage:duration:");
        if (![manager respondsToSelector:createSel]) return;

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
        }
        [[NSFileManager defaultManager] removeItemAtPath:outputPath error:nil];
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

- (void)playAction:(UIButton *)sender {
    NSString *fileName = self.files[sender.tag];
    NSString *path = [getVoicePacksDirectory() stringByAppendingPathComponent:fileName];
    stopPlayingAudio();
    sharedAudioPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:path] error:nil];
    [sharedAudioPlayer play];
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
    [actionSheet addAction:[UIAlertAction actionWithTitle:@"剪辑" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self clipFile:fullPath fileName:fileName atIndexPath:indexPath];
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

- (void)clipFile:(NSString *)fullPath fileName:(NSString *)fileName atIndexPath:(NSIndexPath *)indexPath {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:fullPath] options:nil];
    double totalDuration = CMTimeGetSeconds(asset.duration);

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"剪辑音频" message:[NSString stringWithFormat:@"原时长 %.2f 秒\n请输入剪辑时间范围（秒）", totalDuration] preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.placeholder = @"开始时间 (如 0)";
        textField.keyboardType = UIKeyboardTypeDecimalPad;
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.placeholder = [NSString stringWithFormat:@"结束时间 (如 %.1f)", totalDuration];
        textField.keyboardType = UIKeyboardTypeDecimalPad;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"确认" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        double start = [alert.textFields[0].text doubleValue];
        double end = [alert.textFields[1].text doubleValue];
        if (end <= start || start < 0) return;

        NSString *newName = [NSString stringWithFormat:@"剪辑_%.0f_%@", [[NSDate date] timeIntervalSince1970], fileName];
        NSString *newPath = [getVoicePacksDirectory() stringByAppendingPathComponent:newName];

        // 🚨 显示进度条
        [[ProgressHUD shared] showOnView:self.view title:@"正在剪辑..."];
        clipAudio(fullPath, newPath, start, end, ^(BOOL success) {
            [[ProgressHUD shared] dismiss];
            if (success) {
                self.files = [NSMutableArray arrayWithArray:getAllVoiceFiles()];
                [self.tableView reloadData];
            }
        });
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSString *fileName = self.files[indexPath.row];
    NSString *fullPath = [getVoicePacksDirectory() stringByAppendingPathComponent:fileName];

    UIContextualAction *deleteAction = [UIContextualAction contextualActionWithTitle:@"删除" style:UIContextualActionStyleDestructive handler:^(UIContextualAction * _Nonnull action, __kindof UIView * _Nonnull sourceView, void (^ _Nonnull completionHandler)(BOOL)) {
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

// 🚨 视频转语音：带进度条
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

            NSString *tempAudioPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"temp_extract.m4a"];
            if ([fm fileExistsAtPath:tempAudioPath]) [fm removeItemAtPath:tempAudioPath error:nil];

            AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:tempPath] options:nil];
            AVAssetExportSession *extractor = [[AVAssetExportSession alloc] initWithAsset:asset presetName:AVAssetExportPresetAppleM4A];
            extractor.outputURL = [NSURL fileURLWithPath:tempAudioPath];
            extractor.outputFileType = AVFileTypeAppleM4A;

            // 🚨 显示进度条并开始追踪
            [[ProgressHUD shared] showOnView:self.view title:@"正在提取音频..."];
            [[ProgressHUD shared] trackSession:extractor];

            [extractor exportAsynchronouslyWithCompletionHandler:^{
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (extractor.status != AVAssetExportSessionStatusCompleted) {
                        addLog(@"❌ 视频提取音频失败: %@", extractor.error);
                        [[ProgressHUD shared] dismiss];
                        return;
                    }

                    // 提取完成，进入转码阶段
                    [[ProgressHUD shared] updateProgress:1.0];
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        [[ProgressHUD shared] showOnView:self.view title:@"正在转码..."];

                        NSString *destName = [NSString stringWithFormat:@"视频转语音_%ld.aac", (long)[[NSDate date] timeIntervalSince1970]];
                        NSString *destPath = [getVoicePacksDirectory() stringByAppendingPathComponent:destName];
                        convertToAAC(tempAudioPath, destPath, ^(BOOL success) {
                            [[ProgressHUD shared] updateProgress:1.0];
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                                [[ProgressHUD shared] dismiss];
                                if (success) {
                                    addLog(@"✅ 视频转语音成功: %@", destName);
                                    self.files = [NSMutableArray arrayWithArray:getAllVoiceFiles()];
                                    [self.tableView reloadData];
                                } else {
                                    addLog(@"❌ 视频转语音最终转码失败");
                                }
                            });
                        });
                    });
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

%hook CWTalkBackView
- (void)sendRecorde:(id)sender {
    VoicePackListVC *vc = [[VoicePackListVC alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [topViewController() presentViewController:nav animated:YES completion:nil];
}
%end