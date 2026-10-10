#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

// ===================== 纯日志写入 =====================
static NSString *getNativeTrackerLogPath() {
    NSString *docPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *voiceDir = [docPath stringByAppendingPathComponent:@"VoicePacks"];
    [[NSFileManager defaultManager] createDirectoryAtPath:voiceDir withIntermediateDirectories:YES attributes:nil error:nil];
    return [voiceDir stringByAppendingPathComponent:@"native_tracker.log"];
}

static void traceLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[NativeTracker] %@", msg);

    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"HH:mm:ss.SSS";
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [fmt stringFromDate:[NSDate date]], msg];

    NSString *logPath = getNativeTrackerLogPath();
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

// 辅助：记录文件的真实状态
static void traceFileInfo(NSString *prefix, NSString *path) {
    if (!path) {
        traceLog(@"%@ 路径为空", prefix);
        return;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) {
        traceLog(@"%@ [不存在] %@", prefix, path);
        return;
    }
    NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
    unsigned long long size = [attrs fileSize];
    traceLog(@"%@ [存在] %@ | 大小: %llu 字节 | 权限: %@ | 属主: %@", 
             prefix, path, size, attrs[NSFilePosixPermissions], attrs[NSFileOwnerAccountName]);
}

// ===================== 钩子：腾讯云 IM 发送入口 =====================
%hook V2TIMManager

- (id)createSoundMessage:(NSString *)soundPath duration:(int)duration {
    traceLog(@"\n========== 🎯 V2TIMManager createSoundMessage ==========");
    traceLog(@"传入的 soundPath: %@", soundPath);
    traceLog(@"传入的 duration: %d", duration);
    traceFileInfo(@"腾讯云拿到的文件", soundPath);
    id result = %orig;
    traceLog(@"createSoundMessage 返回值: %@", result);
    return result;
}
%end

// ===================== 钩子：录音器底层 =====================
%hook CWRecorder

- (NSString *)recordPath {
    NSString *path = %orig;
    traceLog(@"\n========== 🎙️ CWRecorder recordPath ==========");
    traceLog(@"录音文件路径: %@", path);
    traceFileInfo(@"录音文件", path);
    return path;
}

- (NSTimeInterval)recordDuration {
    NSTimeInterval duration = %orig;
    traceLog(@"\n========== ⏱️ CWRecorder recordDuration ==========");
    traceLog(@"录音时长: %f 秒", duration);
    return duration;
}

- (void)startRecord {
    traceLog(@"\n========== ▶️ CWRecorder 开始录音 startRecord ==========");
    %orig;
}

- (void)stopRecord {
    traceLog(@"\n========== ⏹️ CWRecorder 停止录音 stopRecord ==========");
    %orig;
}
%end

// ===================== 钩子：聊天界面的发送动作 =====================
%hook MessageDetailController

- (void)sendSound {
    traceLog(@"\n========== 📤 MessageDetailController 调用了 sendSound ==========");
    %orig;
}

- (void)sendMessage:(id)msg isRetry:(BOOL)retry {
    traceLog(@"\n========== 📨 MessageDetailController sendMessage:isRetry: ==========");
    traceLog(@"消息对象: %@ | 是否重试: %@", msg, retry ? @"YES" : @"NO");
    %orig;
}
%end

// ===================== 钩子：对讲按钮 =====================
%hook CWTalkBackView

- (void)sendRecorde:(id)sender {
    traceLog(@"\n========== 🎤 CWTalkBackView sendRecorde (对讲发送) ==========");
    %orig;
}
%end