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
        NSMutableString *resultText = [NSMutableString string];
        [resultText appendString:@"==== 侦察结果 (仅显示相关类) ====\n\n"];
        
        // 要匹配的关键词
        NSArray *keywords = @[@"chat", @"message", @"voice", @"input", @"send", @"record", @"gift", @"user", @"msg"];
        
        int numClasses = objc_getClassList(NULL, 0);
        Class *classes = (Class *)malloc(sizeof(Class) * numClasses);
        objc_getClassList(classes, numClasses);
        
        int foundCount = 0;
        
        for (int i = 0; i < numClasses; i++) {
            Class cls = classes[i];
            const char *className = class_getName(cls);
            NSString *classStr = [NSString stringWithUTF8String:className];
            NSString *lowerClass = [classStr lowercaseString];
            
            // 过滤系统类
            if ([classStr hasPrefix:@"UI"] || [classStr hasPrefix:@"NS"] || 
                [classStr hasPrefix:@"CA"] || [classStr hasPrefix:@"AV"] || 
                [classStr hasPrefix:@"WK"] || [classStr hasPrefix:@"_"] || 
                [classStr hasPrefix:@"OS_"] || [classStr hasPrefix:@"CC"] ||
                [classStr hasPrefix:@"SK"] || [classStr hasPrefix:@"CL"]) {
                continue;
            }
            
            BOOL classMatched = NO;
            for (NSString *kw in keywords) {
                if ([lowerClass containsString:kw]) {
                    classMatched = YES;
                    break;
                }
            }
            
            NSMutableArray *matchedMethods = [NSMutableArray array];
            
            // 获取实例方法
            unsigned int methodCount;
            Method *methods = class_copyMethodList(cls, &methodCount);
            for (int j = 0; j < methodCount; j++) {
                NSString *methodName = NSStringFromSelector(method_getName(methods[j]));
                NSString *lowerMethod = [methodName lowercaseString];
                for (NSString *kw in keywords) {
                    if ([lowerMethod containsString:kw]) {
                        [matchedMethods addObject:[NSString stringWithFormat:@"  - %@", methodName]];
                        classMatched = YES; // 如果方法匹配，也把类显示出来
                        break;
                    }
                }
            }
            free(methods);
            
            // 获取类方法
            Class metaClass = object_getClass(cls);
            Method *classMethods = class_copyMethodList(metaClass, &methodCount);
            for (int j = 0; j < methodCount; j++) {
                NSString *methodName = NSStringFromSelector(method_getName(classMethods[j]));
                NSString *lowerMethod = [methodName lowercaseString];
                for (NSString *kw in keywords) {
                    if ([lowerMethod containsString:kw]) {
                        [matchedMethods addObject:[NSString stringWithFormat:@"  + %@", methodName]];
                        classMatched = YES;
                        break;
                    }
                }
            }
            free(classMethods);
            
            if (classMatched) {
                [resultText appendFormat:@"[Class] %@\n", classStr];
                for (NSString *m in matchedMethods) {
                    [resultText appendFormat:@"%@\n", m];
                }
                [resultText appendString:@"\n"];
                foundCount++;
            }
        }
        free(classes);
        
        [resultText appendFormat:@"\n共找到 %d 个相关类", foundCount];
        
        // 将结果转为字符串，如果太长则截断（防止 UIAlertController 崩溃）
        NSString *finalText = [resultText copy];
        if (finalText.length > 2000) {
            finalText = [[finalText substringToIndex:2000] stringByAppendingString:@"\n\n... (内容过长已截断，请点击复制结果查看全部)"];
        }
        
        // 回到主线程弹窗提示
        dispatch_async(dispatch_get_main_queue(), ^{
            isScanning = NO;
            spyButton.backgroundColor = [UIColor colorWithRed:0 green:1 blue:0 alpha:0.5]; // 恢复绿色
            
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"找到 %d 个相关类", foundCount] message:finalText preferredStyle:UIAlertControllerStyleAlert];
            
            // 复制全部结果按钮（解决内容过长的问题）
            [alert addAction:[UIAlertAction actionWithTitle:@"复制全部结果" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
                [UIPasteboard generalPasteboard].string = resultText;
            }]];
            
            // 关闭按钮
            [alert addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
            
            [spyWindow.rootViewController presentViewController:alert animated:YES completion:nil];
        });
    });
}

@end

// 创建悬浮窗 UI (适配 iOS 16 的 UIWindowScene)
static void createSpyUI() {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindowScene *windowScene = nil;
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]] && scene.activationState == UISceneActivationStateForegroundActive) {
                windowScene = (UIWindowScene *)scene;
                break;
            }
        }
        
        if (!windowScene) return;
        
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
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            createSpyUI();
        });
    }];
    
    if ([UIApplication sharedApplication].applicationState == UIApplicationStateActive) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            createSpyUI();
        });
    }
}