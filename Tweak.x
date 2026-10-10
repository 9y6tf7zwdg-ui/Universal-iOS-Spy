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

static void dumpHex(NSString *filePath) {
    NSData *data = [NSData dataWithContentsOfFile:filePath];
    if (!data) return;
    NSUInteger len = MIN(data.length, 32);
    NSMutableString *hex = [NSMutableString string];
    for (int i = 0; i < len; i++) {
        [hex appendFormat:@"%02X ", ((const unsigned char *)data.bytes)[i]];
    }
    traceLog(@"🔍 文件头(前%lu字节): %@", (unsigned long)len, hex);
}

// ===================== Hook =====================
%hook CWTalkBackView

- (void)sendRecorde:(id)sender {
    NSString *docPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *sourcePath = [docPath stringByAppendingPathComponent:@"VoicePacks/早上好.wav"];
    
    traceLog(@"\n========== 🧪 开始 M4A 导出测试 ==========");
    if (![[NSFileManager defaultManager] fileExistsAtPath:sourcePath]) {
        traceLog(@"❌ 源文件不存在");
        return %orig;
    }
    
    NSString *m4aPath = [docPath stringByAppendingPathComponent:@"VoicePacks/test_export.m4a"];
    [[NSFileManager defaultManager] removeItemAtPath:m4aPath error:nil];
    
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:sourcePath] options:nil];
    AVAssetExportSession *exportSession = [[AVAssetExportSession alloc] initWithAsset:asset presetName:AVAssetExportPresetAppleM4A];
    exportSession.outputURL = [NSURL fileURLWithPath:m4aPath];
    exportSession.outputFileType = AVFileTypeAppleM4A;
    
    [exportSession exportAsynchronouslyWithCompletionHandler:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            traceLog(@"导出状态: %ld", (long)exportSession.status);
            if (exportSession.status == AVAssetExportSessionStatusCompleted) {
                NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:m4aPath error:nil];
                traceLog(@"✅ M4A 导出成功! 文件大小: %llu 字节", [attrs fileSize]);
                dumpHex(m4aPath);
                
                // 模拟插件流程：把 m4a 重命名为 aac，看看腾讯云能不能认
                NSString *renamedPath = [docPath stringByAppendingPathComponent:@"VoicePacks/test_export_renamed.aac"];
                [[NSFileManager defaultManager] removeItemAtPath:renamedPath error:nil];
                [[NSFileManager defaultManager] moveItemAtPath:m4aPath toPath:renamedPath error:nil];
                traceLog(@"🔁 已重命名为 .aac，准备后续发送测试");
            } else {
                traceLog(@"❌ 导出失败: %@", exportSession.error);
            }
        });
    }];
}

%end

// 保留最简拦截，不干预
%hook V2TIMManager
- (id)createSoundMessage:(NSString *)soundPath duration:(int)duration {
    traceLog(@"🎯 拦截原生 createSoundMessage: %@", soundPath.lastPathComponent);
    return %orig;
}
%end