#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

// ===================== 日志路径：对齐 VoicePacks 目录 =====================
static NSString *getVoicePacksDirectory() {
    NSString *docPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *voiceDir = [docPath stringByAppendingPathComponent:@"VoicePacks"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:voiceDir]) {
        [[NSFileManager defaultManager] createDirectoryAtPath:voiceDir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    return voiceDir;
}

static void traceLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[QuxinTracker] %@", msg);

    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"HH:mm:ss.SSS";
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [fmt stringFromDate:[NSDate date]], msg];

    NSString *path = [getVoicePacksDirectory() stringByAppendingPathComponent:@"quxin_tracker.log"];
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

// ===================== 辅助：打印文件真实状态 =====================
static void traceFileInfo(NSString *prefix, NSString *path) {
    if (!path) { traceLog(@"%@ 路径为空", prefix); return; }
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) {
        traceLog(@"%@ [不存在] %@", prefix, path);
        return;
    }
    NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
    traceLog(@"%@ [存在] %@ | 大小: %llu 字节 | 权限: %@ | 属主: %@",
             prefix, path, [attrs fileSize],
             attrs[NSFilePosixPermissions], attrs[NSFileOwnerAccountName]);
}

// ===================== 1. 监控录音 =====================
%hook AVAudioRecorder

- (BOOL)record {
    traceLog(@"\n========== 🎙️ AVAudioRecorder 开始录音 ==========");
    traceLog(@"录音文件 URL: %@", self.url.path);
    return %orig;
}

- (void)stop {
    traceLog(@"\n========== ⏹️ AVAudioRecorder 停止录音 ==========");
    traceFileInfo(@"停止后录音文件", self.url.path);
    %orig;
}

%end

// ===================== 2. 监控腾讯云 IM（如果它用的话） =====================
%hook V2TIMManager

- (id)createSoundMessage:(NSString *)soundPath duration:(int)duration {
    traceLog(@"\n========== 🎯 腾讯云 IM createSoundMessage ==========");
    traceLog(@"传入的音频路径: %@", soundPath);
    traceLog(@"传入的时长: %d 秒", duration);
    traceFileInfo(@"腾讯云 IM 接到的文件", soundPath);
    return %orig;
}

%end

// ===================== 3. 监控声网 Agora（如果它用的话） =====================
%hook AgoraRtcEngineKit

- (int)startAudioRecording:(NSString *)filePath quality:(int)quality {
    traceLog(@"\n========== 📡 Agora 开始录音 ==========");
    traceLog(@"Agora 录音文件路径: %@", filePath);
    return %orig;
}

- (int)stopAudioRecording {
    traceLog(@"\n========== 📡 Agora 停止录音 ==========");
    return %orig;
}

%end

// ===================== 4. 监控本地新建音频文件 =====================
%hook NSFileManager

- (BOOL)createFileAtPath:(NSString *)path contents:(NSData *)data attributes:(NSDictionary *)attr {
    if ([path hasSuffix:@".aac"] || [path hasSuffix:@".m4a"] || [path hasSuffix:@".wav"] ||
        [path hasSuffix:@".mp3"] || [path hasSuffix:@".caf"]) {
        traceLog(@"\n========== 📁 新建音频文件 ==========");
        traceLog(@"路径: %@", path);
        traceLog(@"大小: %lu 字节", (unsigned long)data.length);
    }
    return %orig;
}

%end

// ===================== 5. 监控 HTTP 上传（防止它走自研接口） =====================
%hook NSURLSession

- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request fromFile:(NSURL *)fileURL {
    traceLog(@"\n========== 🌐 NSURLSession 文件上传 ==========");
    traceLog(@"请求 URL: %@", request.URL.absoluteString);
    traceLog(@"上传文件: %@", fileURL.path);
    traceFileInfo(@"上传的音频文件", fileURL.path);
    return %orig;
}

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    NSString *url = request.URL.absoluteString;
    if ([url containsString:@"upload"] || [url containsString:@"audio"] ||
        [url containsString:@"voice"] || [url containsString:@"sound"] ||
        [url containsString:@"file"]) {
        traceLog(@"\n========== 🌐 疑似音频上传接口 ==========");
        traceLog(@"URL: %@", url);
        traceLog(@"HTTP Method: %@", request.HTTPMethod);
        traceLog(@"Body 长度: %lu", (unsigned long)request.HTTPBody.length);
    }
    return %orig;
}

%end

// ===================== 6. 监控 UIViewController，寻找聊天入口 =====================
%hook UIViewController

- (void)viewDidLoad {
    %orig;
    NSString *className = NSStringFromClass([self class]);
    if ([className containsString:@"Chat"] || [className containsString:@"Message"] ||
        [className containsString:@"Record"] || [className containsString:@"Audio"] ||
        [className containsString:@"Voice"] || [className containsString:@"Talk"] ||
        [className containsString:@"Mic"]) {
        traceLog(@"🔍 发现疑似聊天/音频界面: %@", className);
    }
}

%end