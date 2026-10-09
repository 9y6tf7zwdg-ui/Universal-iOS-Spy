#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <AVFoundation/AVFoundation.h>
#import <PhotosUI/PhotosUI.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface MessageDetailController : UIViewController
@end

@interface VoicePackListVC : UITableViewController <PHPickerViewControllerDelegate, UIDocumentPickerDelegate>
@property (nonatomic, strong) NSMutableArray<NSString *> *files;
@property (nonatomic, copy) void (^onSelect)(NSString *path); // nil = 使用刚录制的语音
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

static AVAudioPlayer *sharedAudioPlayer = nil;
static void stopPlayingAudio() {
    if (sharedAudioPlayer && sharedAudioPlayer.isPlaying) [sharedAudioPlayer stop];
    sharedAudioPlayer = nil;
}

// ===================== 全局变量 =====================
static NSString *g_voicePathToSend = nil;   // 用户选中的替换音频
static BOOL g_skipIntercept = NO;           // 二次调用标志，避免死循环

// ===================== 语音列表 =====================
@implementation VoicePackListVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"选择要发送的语音";
    self.files = [NSMutableArray arrayWithArray:getAllVoiceFiles()];
    self.tableView.rowHeight = 64;
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"cell"];
    
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(cancel)];
    
    self.navigationController.toolbarHidden = NO;
    UIBarButtonItem *videoBtn = [[UIBarButtonItem alloc] initWithTitle:@"视频转语音" style:UIBarButtonItemStylePlain target:self action:@selector(videoAction)];
    UIBarButtonItem *importBtn = [[UIBarButtonItem alloc] initWithTitle:@"导入语音包" style:UIBarButtonItemStylePlain target:self action:@selector(importAction)];
    UIBarButtonItem *space = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    UIBarButtonItem *space2 = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    self.toolbarItems = @[videoBtn, space, importBtn, space2, [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil]];
}

- (void)cancel {
    stopPlayingAudio();
    if (self.onSelect) self.onSelect(nil); // nil 表示取消整个发送
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
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.audio"] inMode:UIDocumentPickerModeImport];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

// 第一行是"使用刚录制的语音"，后面是预设文件
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.files.count + 1;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell" forIndexPath:indexPath];
    
    UIView *rightView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 60, 40)];
    
    if (indexPath.row == 0) {
        // 使用刚录制的语音
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
    if (indexPath.row == 0) {
        selectedPath = nil; // 使用原录音
    } else {
        NSString *fileName = self.files[indexPath.row - 1];
        selectedPath = [getVoicePacksDirectory() stringByAppendingPathComponent:fileName];
    }
    
    if (self.onSelect) self.onSelect(selectedPath);
    [self dismissViewControllerAnimated:YES completion:nil];
}

// 相册视频转语音
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

// 文件导入
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

// ===================== 关键拦截：录音结束、准备发送的那一刻 =====================
%hook MessageDetailController

- (void)sendSound {
    // 二次调用，直接放行
    if (g_skipIntercept) {
        g_skipIntercept = NO;
        %orig;
        return;
    }
    
    // 首次调用：弹出列表让用户选择
    NSLog(@"[VoicePlugin] 拦截到 sendSound，弹出选择列表");
    
    VoicePackListVC *vc = [[VoicePackListVC alloc] init];
    __weak typeof(self) weakSelf = self;
    vc.onSelect = ^(NSString *path) {
        if (path) {
            // 用户选择了预设音频，需要先转码为 m4a
            NSString *outputPath = [getVoicePacksDirectory() stringByAppendingPathComponent:@"temp_send_voice.m4a"];
            [[NSFileManager defaultManager] removeItemAtPath:outputPath error:nil];
            
            AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
            AVAssetExportSession *session = [[AVAssetExportSession alloc] initWithAsset:asset presetName:AVAssetExportPresetAppleM4A];
            session.outputURL = [NSURL fileURLWithPath:outputPath];
            session.outputFileType = AVFileTypeAppleM4A;
            
            [session exportAsynchronouslyWithCompletionHandler:^{
                dispatch_async(dispatch_get_main_queue(), ^{
                    g_voicePathToSend = outputPath;
                    g_skipIntercept = YES;
                    [weakSelf sendSound]; // 再次进入 Hook，这次放行
                });
            }];
        } else {
            // 使用原录音，直接放行
            g_voicePathToSend = nil;
            g_skipIntercept = YES;
            [weakSelf sendSound];
        }
    };
    
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

%end

// ===================== 替换录音路径 =====================
%hook CWRecorder
- (NSString *)recordPath {
    if (g_voicePathToSend && [[NSFileManager defaultManager] fileExistsAtPath:g_voicePathToSend]) {
        NSLog(@"[VoicePlugin] 替换录音路径为: %@", g_voicePathToSend);
        return g_voicePathToSend;
    }
    return %orig;
}
%end