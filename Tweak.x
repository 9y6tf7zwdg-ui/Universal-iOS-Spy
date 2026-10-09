#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <AVFoundation/AVFoundation.h>
#import <PhotosUI/PhotosUI.h>

@interface MessageDetailController : UIViewController
@end

// ===================== 辅助函数 =====================

static NSString *getVoicePacksDirectory() {
    NSString *docPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *voiceDir = [docPath stringByAppendingPathComponent:@"VoicePacks"];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:voiceDir]) {
        [fm createDirectoryAtPath:voiceDir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    return voiceDir;
}

static NSArray<NSString *> *getAllVoiceFiles() {
    NSString *voiceDir = getVoicePacksDirectory();
    NSError *error;
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:voiceDir error:&error];
    if (error) return @[];
    NSMutableArray *voiceFiles = [NSMutableArray array];
    for (NSString *file in files) {
        NSString *lower = [file lowercaseString];
        if ([lower hasSuffix:@".wav"] || [lower hasSuffix:@".mp3"] || [lower hasSuffix:@".m4a"]) {
            [voiceFiles addObject:file];
        }
    }
    return voiceFiles;
}

static int getAudioDuration(NSString *path) {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
    float seconds = CMTimeGetSeconds(asset.duration);
    if (isnan(seconds) || seconds <= 0) return 1;
    return (int)ceil(seconds);
}

static void convertToM4A(NSString *inputPath, NSString *outputPath, void (^completion)(BOOL success)) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:outputPath]) [fm removeItemAtPath:outputPath error:nil];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:inputPath] options:nil];
    AVAssetExportSession *session = [[AVAssetExportSession alloc] initWithAsset:asset presetName:AVAssetExportPresetAppleM4A];
    session.outputURL = [NSURL fileURLWithPath:outputPath];
    session.outputFileType = AVFileTypeAppleM4A;
    [session exportAsynchronouslyWithCompletionHandler:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(session.status == AVAssetExportSessionStatusCompleted);
        });
    }];
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

// 核心发送逻辑
static void sendVoiceWithPath(NSString *sourcePath) {
    if (!sourcePath || ![[NSFileManager defaultManager] fileExistsAtPath:sourcePath]) return;
    UIViewController *chatVC = findMessageDetailController(topViewController());
    if (!chatVC) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"提示" message:@"请先进入聊天界面！" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [topViewController() presentViewController:alert animated:YES completion:nil];
        return;
    }
    
    NSString *outputPath = [getVoicePacksDirectory() stringByAppendingPathComponent:@"temp_send_voice.m4a"];
    convertToM4A(sourcePath, outputPath, ^(BOOL success) {
        if (!success) return;
        int duration = getAudioDuration(outputPath);
        
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
    });
}

// ===================== 语音列表Cell =====================
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
        
        // 布局
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
@interface VoicePackManagerViewController : UIViewController <UITableViewDelegate, UITableViewDataSource, UISearchBarDelegate, PHPickerViewControllerDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSMutableArray<NSString *> *voiceFiles;
@property (nonatomic, strong) NSMutableArray<NSString *> *filteredFiles;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) AVAudioPlayer *audioPlayer;
@end

@implementation VoicePackManagerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"语音包管理";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    
    // 顶部导航栏按钮
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"新建分类" style:UIBarButtonItemStylePlain target:self action:@selector(createCategory)];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(close)];
    
    // 搜索栏
    self.searchBar = [[UISearchBar alloc] init];
    self.searchBar.placeholder = @"搜索语音包";
    self.searchBar.delegate = self;
    self.tableView.tableHeaderView = self.searchBar;
    
    // 表格
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.rowHeight = 70;
    [self.tableView registerClass:[VoicePackCell class] forCellReuseIdentifier:@"VoicePackCell"];
    [self.view addSubview:self.tableView];
    
    // 底部工具栏
    UIView *bottomView = [[UIView alloc] initWithFrame:CGRectMake(0, self.view.bounds.size.height - 80, self.view.bounds.size.width, 80)];
    bottomView.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
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
    
    // 调整表格高度，避开底部
    self.tableView.contentInset = UIEdgeInsetsMake(0, 0, 80, 0);
    
    [self reloadData];
}

- (void)reloadData {
    self.voiceFiles = [NSMutableArray arrayWithArray:getAllVoiceFiles()];
    self.filteredFiles = [NSMutableArray arrayWithArray:self.voiceFiles];
    [self.tableView reloadData];
}

- (void)close {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)createCategory {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"新建分类" message:@"分类功能待实现，这里先用文件名区分" preferredStyle:UIAlertControllerStyleAlert];
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
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"链接转语音" message:@"该功能需要后端接口支持，暂不开放。" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    } else { // 导入语音包
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"导入语音包" message:@"请使用 Filza 将音频文件放入 App 沙盒的 Documents/VoicePacks/ 目录下。" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

// ================= 表格代理 =================
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
    
    [cell.playButton removeTarget:self action:@selector(playVoice:) forControlEvents:UIControlEventTouchUpInside];
    [cell.sendButton removeTarget:self action:@selector(sendVoice:) forControlEvents:UIControlEventTouchUpInside];
    
    [cell.playButton addTarget:self action:@selector(playVoice:) forControlEvents:UIControlEventTouchUpInside];
    [cell.sendButton addTarget:self action:@selector(sendVoice:) forControlEvents:UIControlEventTouchUpInside];
    
    return cell;
}

- (void)playVoice:(UIButton *)sender {
    VoicePackCell *cell = (VoicePackCell *)sender.superview.superview;
    if (![cell isKindOfClass:[VoicePackCell class]]) return;
    
    if (self.audioPlayer && self.audioPlayer.isPlaying) {
        [self.audioPlayer stop];
    }
    NSError *error;
    self.audioPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:cell.filePath] error:&error];
    if (!error) {
        [self.audioPlayer play];
    }
}

- (void)sendVoice:(UIButton *)sender {
    VoicePackCell *cell = (VoicePackCell *)sender.superview.superview;
    if (![cell isKindOfClass:[VoicePackCell class]]) return;
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"发送语音" message:[NSString stringWithFormat:@"即将发送: %@", cell.nameLabel.text] preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"发送" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self dismissViewControllerAnimated:YES completion:^{
            sendVoiceWithPath(cell.filePath);
        }];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

// 侧滑删除
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    UIContextualAction *deleteAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"删除" handler:^(UIContextualAction * _Nonnull action, __kindof UIView * _Nonnull sourceView, void (^ _Nonnull completionHandler)(BOOL)) {
        NSString *fileName = self.filteredFiles[indexPath.row];
        NSString *fullPath = [getVoicePacksDirectory() stringByAppendingPathComponent:fileName];
        [[NSFileManager defaultManager] removeItemAtPath:fullPath error:nil];
        [self.filteredFiles removeObjectAtIndex:indexPath.row];
        [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
        completionHandler(YES);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[deleteAction]];
}

// 搜索
- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    if (searchText.length == 0) {
        self.filteredFiles = [NSMutableArray arrayWithArray:self.voiceFiles];
    } else {
        self.filteredFiles = [NSMutableArray array];
        for (NSString *file in self.voiceFiles) {
            if ([file.lowercaseString containsString:searchText.lowercaseString]) {
                [self.filteredFiles addObject:file];
            }
        }
    }
    [self.tableView reloadData];
}

// PHPicker 代理
- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    if (results.count == 0) return;
    
    PHPickerResult *result = results.firstObject;
    NSItemProvider *provider = result.itemProvider;
    
    if ([provider hasItemConformingToTypeIdentifier:UTTypeMovie.identifier]) {
        [provider loadFileRepresentationForTypeIdentifier:UTTypeMovie.identifier completionHandler:^(NSURL *url, NSError *error) {
            if (error || !url) return;
            
            NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:url.lastPathComponent];
            NSFileManager *fm = [NSFileManager defaultManager];
            if ([fm fileExistsAtPath:tempPath]) [fm removeItemAtPath:tempPath error:nil];
            [fm copyItemAtPath:url.path toPath:tempPath error:&error];
            
            if (error) return;
            
            NSString *voiceDir = getVoicePacksDirectory();
            NSString *fileName = [NSString stringWithFormat:@"视频转语音_%ld.m4a", (long)[[NSDate date] timeIntervalSince1970]];
            NSString *destPath = [voiceDir stringByAppendingPathComponent:fileName];
            
            convertToM4A(tempPath, destPath, ^(BOOL success) {
                if (success) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self reloadData];
                        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"转换成功" message:@"视频语音已提取并保存在列表中。" preferredStyle:UIAlertControllerStyleAlert];
                        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
                        [self presentViewController:alert animated:YES completion:nil];
                    });
                }
            });
        }];
    }
}

@end

// ===================== 悬浮球入口 =====================
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
                windowScene = (UIWindowScene *)scene;
                break;
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