#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// 静态变量防止被 ARC 回收
static UIWindow *spyWindow;
static UIButton *spyButton;
static id spyTarget;
static BOOL isScanning = NO;

// 负责处理扫描逻辑的类
@interface SpyHandler : NSObject
@end

@implementation SpyHandler

// 拖拽悬浮球
- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    UIView *btn = gesture.view;
    CGPoint translation = [gesture translationInView:btn.superview];
    btn.center = CGPointMake(btn.center.x + translation.x, btn.center.y + translation.y);
    [gesture setTranslation:CGPointZero inView:btn.superview];
}

// 点击开始扫描
- (void)startScan {
    if (isScanning) return;
    isScanning = YES;
    
    spyButton.backgroundColor = [UIColor colorWithRed:1 green:0.5 blue:0 alpha:0.8]; // 扫描中变橙色
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        NSMutableString *output = [NSMutableString string];
        [output appendFormat:@"==== 侦察报告: %@ ====\n\n", bundleID];
        
        int numClasses = objc_getClassList(NULL, 0);
        Class *classes = (Class *)malloc(sizeof(Class) * numClasses);
        objc_getClassList(classes, numClasses);
        
        int count = 0;
        for (int i = 0; i < numClasses; i++) {
            Class cls = classes[i];
            const char *className = class_getName(cls);
            NSString *classStr = [NSString stringWithUTF8String:className];
            
            // 【深度优化】过滤系统底层类，只保留业务逻辑类
            if ([classStr hasPrefix:@"UI"] || [classStr hasPrefix:@"NS"] || 
                [classStr hasPrefix:@"CA"] || [classStr hasPrefix:@"AV"] || 
                [classStr hasPrefix:@"WK"] || [classStr hasPrefix:@"_"] || 
                [classStr hasPrefix:@"OS_"] || [classStr hasPrefix:@"CC"] ||
                [classStr hasPrefix:@"SK"] || [classStr hasPrefix:@"CL"]) {
                continue;
            }
            
            [output appendFormat:@"[Class] %@\n", classStr];
            
            // 获取实例方法
            unsigned int methodCount;
            Method *methods = class_copyMethodList(cls, &methodCount);
            for (int j = 0; j < methodCount; j++) {
                NSString *methodName = NSStringFromSelector(method_getName(methods[j]));
                [output appendFormat:@"  - %@\n", methodName];
            }
            free(methods);
            
            // 获取类方法
            Class metaClass = object_getClass(cls);
            Method *classMethods = class_copyMethodList(metaClass, &methodCount);
            for (int j = 0; j < methodCount; j++) {
                NSString *methodName = NSStringFromSelector(method_getName(classMethods[j]));
                [output appendFormat:@"  + %@\n", methodName];
            }
            free(classMethods);
            
            count++;
        }
        free(classes);
        [output appendFormat:@"\n共找到 %d 个非系统类", count];
        
        // 写入 App 沙盒的 Documents 目录
        NSString *docPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        NSString *fileName = [NSString stringWithFormat:@"Spy_%@.txt", bundleID];
        NSString *filePath = [docPath stringByAppendingPathComponent:fileName];
        NSError *error;
        [output writeToFile:filePath atomically:YES encoding:NSUTF8StringEncoding error:&error];
        
        // 回到主线程提示
        dispatch_async(dispatch_get_main_queue(), ^{
            isScanning = NO;
            spyButton.backgroundColor = [UIColor colorWithRed:0 green:1 blue:0 alpha:0.5]; // 恢复绿色
            
            NSString *msg = error ? [NSString stringWithFormat:@"写入失败: %@", error.localizedDescription] : [NSString stringWithFormat:@"扫描完成！\n共发现 %d 个类。\n文件已保存至:\nDocuments/%@", count, fileName];
            
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"扫描结果" message:msg preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"我知道了" style:UIAlertActionStyleDefault handler:nil]];
            [spyWindow.rootViewController presentViewController:alert animated:YES completion:nil];
        });
    });
}

@end

// 创建悬浮窗 UI (适配 iOS 16 的 UIWindowScene)
static void createSpyUI() {
    dispatch_async(dispatch_get_main_queue(), ^{
        // 获取当前活跃的 UIWindowScene
        UIWindowScene *windowScene = nil;
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]] && scene.activationState == UISceneActivationStateForegroundActive) {
                windowScene = (UIWindowScene *)scene;
                break;
            }
        }
        
        if (!windowScene) return; // 场景未就绪，稍后重试
        
        spyWindow = [[UIWindow alloc] initWithWindowScene:windowScene];
        spyWindow.frame = CGRectMake(120, 120, 60, 60);
        spyWindow.windowLevel = UIWindowLevelAlert + 100;
        spyWindow.backgroundColor = [UIColor clearColor];
        spyWindow.rootViewController = [UIViewController new];
        spyWindow.hidden = NO;
        
        spyTarget = [[NSClassFromString(@"SpyHandler") alloc] init];
        
        spyButton = [UIButton buttonWithType:UIButtonTypeCustom];
        spyButton.frame = CGRectMake(0, 0, 60, 60);
        spyButton.backgroundColor = [UIColor colorWithRed:0 green:1 blue:0 alpha:0.5];
        spyButton.layer.cornerRadius = 30;
        spyButton.layer.shadowColor = [UIColor blackColor].CGColor;
        spyButton.layer.shadowOffset = CGSizeMake(0, 2);
        spyButton.layer.shadowOpacity = 0.5;
        spyButton.layer.shadowRadius = 2;
        spyButton.titleLabel.font = [UIFont boldSystemFontOfSize:20];
        [spyButton setTitle:@"侦" forState:UIControlStateNormal];
        [spyButton addTarget:spyTarget action:@selector(startScan) forControlEvents:UIControlEventTouchUpInside];
        
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:spyTarget action:@selector(handlePan:)];
        [spyButton addGestureRecognizer:pan];
        
        [spyWindow.rootViewController.view addSubview:spyButton];
    });
}

// 插件加载入口
__attribute__((constructor)) static void init() {
    // 监听 App 启动完成通知，确保 UI 安全
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        // 延迟 2 秒显示，确保主界面和 Scene 完全初始化
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            createSpyUI();
        });
    }];
    
    // 如果已经启动（比如注入后重新挂载），也尝试显示
    if ([UIApplication sharedApplication].applicationState == UIApplicationStateActive) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            createSpyUI();
        });
    }
}