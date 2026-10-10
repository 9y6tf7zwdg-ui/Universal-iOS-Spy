#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

// ===================== 日志 =====================
static NSString *getLogPath() {
    NSString *docPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *dir = [docPath stringByAppendingPathComponent:@"VoicePacks"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:@"export_test.log"];
}

static void traceLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"HH:mm:ss.SSS";
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [fmt stringFromDate:[NSDate date]], msg];
    NSString *path = getLogPath();
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) {
        [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } else {
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
}

// ===================== Hook：聊天界面发送按钮 =====================
%hook MessageDetailController

- (void)sendSound {
    traceLog(@"触发原生 sendSound，不干预");
    %orig;
}

- (void)sendMessage:(id)msg isRetry:(BOOL)retry {
    traceLog(@"触发原生 sendMessage:isRetry:，不干预");
    %orig;
}

%end

// ===================== 我们的纯诊断测试 =====================
%hook CWTalkBackView

- (void)sendRecorde:(id)sender {
    // 1. 寻找源文件（这里我们直接找用户放在 VoicePacks 里的 早上好.wav）
    NSString *docPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *sourcePath = [docPath stringByAppendingPathComponent:@"VoicePacks/早上好.wav"];
    
    traceLog(@"\n========== 🧪 开始转码测试 ==========");
    traceLog(@"源文件路径: %@", sourcePath);
    
    if (![[NSFileManager defaultManager] fileExistsAtPath:sourcePath]) {
        traceLog(@"❌ 源文件不存在，请把 早上好.wav 放进 VoicePacks 目录");
        return %orig;
    }
    
    // 2. 设定输出路径为系统原生认可的 AAC 路径（弄成 m4a 再改后缀）
    NSString *outputPath = [docPath stringByAppendingPathComponent:@"VoicePacks/test_export.aac"];
    [[NSFileManager defaultManager] removeItemAtPath:outputPath error:nil];
    
    // 3. 使用 AVAssetExportSession 进行标准转码
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:sourcePath] options:nil];
    AVAssetExportSession *exportSession = [[AVAssetExportSession alloc] initWithAsset:asset presetName:AVAssetExportPresetAppleM4A];
    exportSession.outputURL = [NSURL fileURLWithPath:outputPath];
    exportSession.outputFileType = AVFileTypeAppleM4A;
    
    traceLog(@"开始导出为 M4A...");
    [exportSession exportAsynchronouslyWithCompletionHandler:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            traceLog(@"导出状态: %ld", (long)exportSession.status);
            if (exportSession.status == AVAssetExportSessionStatusCompleted) {
                NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:outputPath error:nil];
                traceLog(@"✅ 导出成功! 文件大小: %llu 字节", [attrs fileSize]);
                traceLog(@"文件路径: %@", outputPath);
                
                // 读取前 32 字节，看是否是标准 M4A 容器
                NSData *data = [NSData dataWithContentsOfFile:outputPath];
                NSMutableString *hex = [NSMutableString string];
                for (int i = 0; i < 32 && i < data.length; i++) {
                    [hex appendFormat:@"%02X ", ((const unsigned char *)data.bytes)[i]];
                }
                traceLog(@"🔍 M4A 文件头(前32字节): %@", hex);
                
                // 现在，我们可以尝试用原生录音目录的格式来发送这个文件！
                // （这里只写日志，不实际发送，保证诊断纯度）
                traceLog(@"✅ 诊断完成，等待下一步指令");
                
            } else {
                traceLog(@"❌ 导出失败: %@", exportSession.error);
            }
        });
    }];
    
    // 不调用 %orig，阻止原有录音逻辑
}
%end