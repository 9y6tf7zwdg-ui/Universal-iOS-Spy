#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <AVFoundation/AVFoundation.h>
#import <PhotosUI/PhotosUI.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h> // 🚨 引入新框架解决废弃API报错

// ===================== 基础工具函数 =====================
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

// 停止当前正在播放的音频
static AVAudioPlayer *sharedAudioPlayer = nil;
static void stopPlayingAudio() {
    if (sharedAudioPlayer && sharedAudioPlayer.isPlaying) {
        [sharedAudioPlayer stop];
        sharedAudioPlayer = nil;
    }
}

// ===================== 核心发送逻辑（移花接木，彻底解决灰色方块） =====================
static void sendVoiceWithPath(NSString *sourcePath) {
    stopPlayingAudio();
    
    if (!sourcePath || ![[NSFileManager defaultManager] fileExistsAtPath:sourcePath]) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"错误" message:@"音频文件不存在。" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [topViewController() presentViewController:alert animated:YES completion:nil];
        return;
    }
    
    UIViewController *chatVC = findMessageDetailController(topViewController());
    if (!chatVC) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"提示" message:@"请先进入任意聊天界面，再点击发送！" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [topViewController() presentViewController:alert animated:YES completion:nil];
        return;
    }
    
    NSString *outputPath = [getVoicePacksDirectory() stringByAppendingPathComponent:@"temp_send_voice.m4a"];
    [[NSFileManager defaultManager] removeItemAtPath:outputPath error:nil];
    
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:sourcePath] options:nil];
    AVAssetExportSession *session = [[AVAssetExportSession alloc] initWithAsset:asset presetName:AVAssetExportPresetAppleM4A];
    session.outputURL = [NSURL fileURLWithPath:outputPath];
    session.outputFileType = AVFileTypeAppleM4A;
    
    [session exportAsynchronouslyWithCompletionHandler:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:outputPath error:nil];
            if (session.status != AVAssetExportSessionStatusCompleted || !attrs || [attrs fileSize] == 0) {
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"发送失败" message:@"音频转码失败或文件为空。" preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
                [topViewController() presentViewController:alert animated:YES completion:nil];
                return;
            }
            
            // 1. 尝试寻找 App 底层的录音器，使用最稳妥的“移花接木”方案
            id recorder = nil;
            @try { recorder = [chatVC valueForKey:@"recorder"]; } @catch (NSException *e) {}
            if (!recorder) {
                for (UIView *sub in chatVC.view.subviews) {
                    if ([sub isKindOfClass:NSClassFromString(@"CWRecordView")] || [sub isKindOfClass:NSClassFromString(@"CWTalkBackView")]) {
                        recorder = sub; break;
                    }
                }
            }
            
            if (recorder && [recorder respondsToSelector:NSSelectorFromString(@"beginRecordWithRecordPath:")]) {
                NSLog(@"[VoicePlugin] 找到原生录音器，接管发送流程...");
                SEL beginSel = NSSelectorFromString(@"beginRecordWithRecordPath:");
                NSMethodSignature *beginSig = [recorder methodSignatureForSelector:beginSel];
                NSInvocation *beginInv = [NSInvocation invocationWithMethodSignature:beginSig];
                [beginInv setTarget:recorder];
                [beginInv setSelector:beginSel];
                __unsafe_unretained NSString *pathArg = outputPath;
                [beginInv setArgument:&pathArg atIndex:2];
                [beginInv invoke];
                
                if ([recorder respondsToSelector:NSSelectorFromString(@"endRecord")]) {
                    SEL endSel = NSSelectorFromString(@"endRecord");
                    NSMethodSignature *endSig = [recorder methodSignatureForSelector:endSel];
                    NSInvocation *endInv = [NSInvocation invocationWithMethodSignature:endSig];
                    [endInv setTarget:recorder];
                    [endInv setSelector:endSel];
                    [endInv invoke];
                    NSLog(@"[VoicePlugin] 已触发原生管线发送！");
                }
            } else {
                // 2. 备用方案：直接调用底层 V2TIM API
                NSLog(@"[VoicePlugin] 未找到录音器，尝试直接调用 V2TIM API...");
                Class v2ManagerClass = NSClassFromString(@"V2TIMManager");
                id manager = [v2ManagerClass performSelector:@selector(sharedInstance)];
                SEL createSel = NSSelectorFromString(@"createSoundMessage:duration:");
                if ([manager respondsToSelector:createSel]) {
                    NSMethodSignature *sig = [manager methodSignatureForSelector:createSel];
                    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                    [inv setTarget:manager];
                    [inv setSelector:createSel];
                    __unsafe_unretained NSString *pathArg = outputPath;
                    [inv setArgument:&pathArg atIndex:2];
                    int duration = (int)ceil(CMTimeGetSeconds(asset.duration));
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
                }
            }
        });
    }];
}

// ===================== 语音列表 Cell (带试听) =====================
@interface VoicePackCell : UITableViewCell
@property (nonatomic, strong) UIButton *playButton;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *sizeLabel;
@property (nonatomic, strong) UIButton *sendButton;
@property (nonatomic, strong) NSString *filePath;
@end

@implementation VoicePackCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
        
        _playButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [_playButton setImage:[UIImage systemImageNamed:@"play.circle.fill"] forState:UIControlStateNormal];
        _playButton.tintColor = [UIColor systemBlueColor];
        [self.contentView addSubview:_playButton];
        
        _nameLabel = [[UILabel alloc] init];
        _nameLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
        _nameLabel.textColor = [UIColor labelColor];
        [self.contentView addSubview:_nameLabel];
        
        _sizeLabel = [[UILabel alloc] init];
        _sizeLabel.font = [UIFont systemFontOfSize:12];
        _sizeLabel.textColor = [UIColor secondaryLabelColor];
        [self.contentView addSubview:_sizeLabel];
        
        _sendButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [_sendButton setTitle:@"发送" forState:UIControlStateNormal];
        [_sendButton setTitleColor:[UIColor systemBlueColor] forState:UIControlStateNormal];
        [self.contentView addSubview:_sendButton];
        
        _playButton.translatesAutoresizingMaskIntoConstraints = NO;
        _nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _sizeLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _sendButton.translatesAutoresizingMaskIntoConstraints = NO;
        
        [NSLayoutConstraint activateConstraints:@[
            [_playButton.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:15],
            [_playButton.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_playButton.widthAnchor constraintEqualToConstant:36],
            [_playButton.heightAnchor constraintEqualToConstant:36],
            [_nameLabel.leadingAnchor constraintEqualToAnchor:_playButton.trailingAnchor constant:10],
            [_nameLabel.trailingAnchor constraintEqualToAnchor:_sendButton.leadingAnchor constant:-10],
            [_nameLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:10],
            [_sizeLabel.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
            [_sizeLabel.topAnchor constraintEqualToAnchor:_nameLabel.bottomAnchor constant:4],
            [_sendButton.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-15],
            [_sendButton.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_sendButton.widthAnchor constraintEqualToConstant:50],
        ]];
    }
    return self;
}
@end

// ===================== 语音包管理主界面 =====================
@interface VoicePackManagerViewController : UIViewController <UITableViewDelegate, UITableViewDataSource, UISearchBarDelegate, PHPickerViewControllerDelegate, UIDocumentPickerDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSMutableArray<NSString *> *voiceFiles;
@property (nonatomic, strong) NSMutableArray<NSString *> *filteredFiles;
@property (nonatomic, strong) UISearchBar *searchBar;
@end

@implementation VoicePackManagerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"语音包管理";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(close)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"新建分类" style:UIBarButtonItemStylePlain target:self action:@selector(createCategory)];
    
    self.searchBar = [[UISearchBar alloc] init];
    self.searchBar.placeholder = @"搜索语音包";
    self.searchBar.delegate = self;
    
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.rowHeight = 70;
    self.tableView.tableHeaderView = self.searchBar;
    [self.tableView registerClass:[VoicePackCell class] forCellReuseIdentifier:@"VoicePackCell"];
    [self.view addSubview:self.tableView];
    
    // 底部工具栏
    UIView *bottomView = [[UIView alloc] initWithFrame:CGRectMake(0, self.view.bounds.size.height - 80, self.view.bounds.size.width, 80)];
    bottomView.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    bottomView.autoresizingMask = UIViewAutoresizingFlexibleTopMargin;
    [self.view addSubview:bottomView];
    
    NSArray *titles = @[@"视频转语音", @"链接转语音", @"导入语音包"];
    CGFloat btnWidth = self.view.bounds.size.width / 3.0;
    for (int i = 0; i < titles.count; i++) {
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        btn.frame = CGRectMake(i * btnWidth, 0, btnWidth, 80);
        [btn setTitle:titles[i] forState:UIControlStateNormal];
        btn.tag = i;
        [btn addTarget:self action:@selector(bottomAction:) forControlEvents:UIControlEventTouchUpInside];
        [bottomView addSubview:btn];
    }
    
    self.tableView.contentInset = UIEdgeInsetsMake(0, 0, 80, 0);
    [self reloadData];
}

- (void)reloadData {
    self.voiceFiles = [NSMutableArray arrayWithArray:getAllVoiceFiles()];
    self.filteredFiles = [NSMutableArray arrayWithArray:self.voiceFiles];
    [self.tableView reloadData];
}

- (void)close { 
    stopPlayingAudio();
    [self dismissViewControllerAnimated:YES completion:nil]; 
}

- (void)createCategory {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"新建分类" message:@"分类功能开发中，可暂用文件名前缀区分。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)bottomAction:(UIButton *)sender {
    if (sender.tag == 0) { // 视频转语音
        PHPickerConfiguration *config = [[PHPickerConfiguration alloc] init];
        config.filter = PHPickerFilter.videosFilter;
        config.selectionLimit = 1;
        PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:config];
        picker.delegate = self;
        [self presentViewController:picker animated:YES completion:nil];
    } else if (sender.tag == 1) { // 链接转语音
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"链接转语音" message:@"该功能需要后端接口支持，暂未开放。" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    } else { // 导入语音包 🚨 替换为最新的 iOS 14+ API
        UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeAudio] asCopy:YES];
        picker.delegate = self;
        [self presentViewController:picker animated:YES completion:nil];
    }
}

// 表格代理
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.filteredFiles.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    VoicePackCell *cell = [tableView dequeueReusableCellWithIdentifier:@"VoicePackCell" forIndexPath:indexPath];
    NSString *fileName = self.filteredFiles[indexPath.row];
    NSString *fullPath = [getVoicePacksDirectory() stringByAppendingPathComponent:fileName];
    
    cell.nameLabel.text = fileName;
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:fullPath error:nil];
    double size = [attrs fileSize] / 1024.0;
    cell.sizeLabel.text = [NSString stringWithFormat:@"文件大小 %.2f KB", size];
    cell.filePath = fullPath;
    
    cell.playButton.tag = indexPath.row;
    cell.sendButton.tag = indexPath.row;
    
    [cell.playButton removeTarget:self action:@selector(playVoice:) forControlEvents:UIControlEventTouchUpInside];
    [cell.sendButton removeTarget:self action:@selector(sendVoice:) forControlEvents:UIControlEventTouchUpInside];
    [cell.playButton addTarget:self action:@selector(playVoice:) forControlEvents:UIControlEventTouchUpInside];
    [cell.sendButton addTarget:self action:@selector(sendVoice:) forControlEvents:UIControlEventTouchUpInside];
    
    return cell;
}

- (void)playVoice:(UIButton *)sender {
    NSString *fileName = self.filteredFiles[sender.tag];
    NSString *path = [getVoicePacksDirectory() stringByAppendingPathComponent:fileName];
    stopPlayingAudio();
    NSError *error;
    sharedAudioPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:path] error:&error];
    if (!error && sharedAudioPlayer) {
        [sharedAudioPlayer play];
    }
}

- (void)sendVoice:(UIButton *)sender {
    NSString *fileName = self.filteredFiles[sender.tag];
    NSString *path = [getVoicePacksDirectory() stringByAppendingPathComponent:fileName];
    [self dismissViewControllerAnimated:YES completion:^{
        sendVoiceWithPath(path);
    }];
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    if (searchText.length == 0) {
        self.filteredFiles = [NSMutableArray arrayWithArray:self.voiceFiles];
    } else {
        self.filteredFiles = [NSMutableArray array];
        for (NSString *file in self.voiceFiles) {
            if ([file.lowercaseString containsString:searchText.lowercaseString]) [self.filteredFiles addObject:file];
        }
    }
    [self.tableView reloadData];
}

// 相册视频转语音
- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    if (results.count == 0) return;
    
    PHPickerResult *result = results.firstObject;
    if ([result.itemProvider hasItemConformingToTypeIdentifier:UTTypeMovie.identifier]) {
        [result.itemProvider loadFileRepresentationForTypeIdentifier:UTTypeMovie.identifier completionHandler:^(NSURL *url, NSError *error) {
            if (error || !url) return;
            NSString *destName = [NSString stringWithFormat:@"视频转语音_%ld.m4a", (long)[[NSDate date] timeIntervalSince1970]];
            NSString *destPath = [getVoicePacksDirectory() stringByAppendingPathComponent:destName];
            
            AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
            AVAssetExportSession *session = [[AVAssetExportSession alloc] initWithAsset:asset presetName:AVAssetExportPresetAppleM4A];
            session.outputURL = [NSURL fileURLWithPath:destPath];
            session.outputFileType = AVFileTypeAppleM4A;
            
            [session exportAsynchronouslyWithCompletionHandler:^{
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (session.status == AVAssetExportSessionStatusCompleted) {
                        [self reloadData];
                    } else {
                        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"转换失败" message:@"视频提取音频失败，请换一个视频。" preferredStyle:UIAlertControllerStyleAlert];
                        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
                        [self presentViewController:alert animated:YES completion:nil];
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
    
    if (error) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"导入失败" message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    } else {
        [self reloadData];
    }
}

@end

// ===================== 悬浮球 =====================
static UIWindow *floatWindow;
static UIButton *floatButton;
static id floatHandler;

@interface FloatHandler : NSObject
@end

@implementation FloatHandler
- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    UIView *btn = gesture.view;
    CGPoint translation = [gesture translationInView:btn.superview];
    btn.center = CGPointMake(btn.center.x + translation.x, btn.center.y + translation.y);
    [gesture setTranslation:CGPointZero inView:btn.superview];
}
- (void)handleTap {
    VoicePackManagerViewController *vc = [[VoicePackManagerViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    [topViewController() presentViewController:nav animated:YES completion:nil];
}
@end

static void createFloatUI() {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindowScene *windowScene = nil;
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]] && scene.activationState == UISceneActivationStateForegroundActive) {
                windowScene = (UIWindowScene *)scene; break;
            }
        }
        if (!windowScene) return;
        floatWindow = [[UIWindow alloc] initWithWindowScene:windowScene];
        floatWindow.frame = CGRectMake(150, 300, 60, 60);
        floatWindow.windowLevel = UIWindowLevelAlert + 100;
        floatWindow.backgroundColor = [UIColor clearColor];
        floatWindow.rootViewController = [UIViewController new];
        floatWindow.hidden = NO;
        
        floatHandler = [FloatHandler new];
        floatButton = [UIButton buttonWithType:UIButtonTypeCustom];
        floatButton.frame = CGRectMake(0, 0, 60, 60);
        floatButton.backgroundColor = [UIColor colorWithRed:0.2 green:0.6 blue:1.0 alpha:0.9];
        floatButton.layer.cornerRadius = 30;
        [floatButton setTitle:@"语音" forState:UIControlStateNormal];
        floatButton.titleLabel.font = [UIFont boldSystemFontOfSize:14];
        [floatButton addTarget:floatHandler action:@selector(handleTap) forControlEvents:UIControlEventTouchUpInside];
        
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:floatHandler action:@selector(handlePan:)];
        [floatButton addGestureRecognizer:pan];
        [floatWindow.rootViewController.view addSubview:floatButton];
    });
}

__attribute__((constructor)) static void init() {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        createFloatUI();
    });
}