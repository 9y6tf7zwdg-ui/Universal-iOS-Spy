#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <AVFoundation/AVFoundation.h>

@interface CWTalkBackView : UIView
@end

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

static NSString *audioInfo(NSString *path) {
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
    double duration = CMTimeGetSeconds(asset.duration);
    NSMutableString *s = [NSMutableString stringWithFormat:@"大小=%.2fKB, 时长=%.2fs",
                          [attrs fileSize] / 1024.0, duration];

    AVAssetTrack *track = [[asset tracksWithMediaType:AVMediaTypeAudio] firstObject];
    if (!track) { [s appendString:@", 无音频轨道"]; return s; }
    for (id desc in track.formatDescriptions) {
        CMAudioFormatDescriptionRef fmt = (__bridge CMAudioFormatDescriptionRef)desc;
        const AudioStreamBasicDescription *asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt);
        if (asbd) {
            [s appendFormat:@", 采样率=%.0fHz, 声道=%u, 格式ID=%u(%c%c%c%c)",
                asbd->mSampleRate, asbd->mChannelsPerFrame, (unsigned int)asbd->mFormatID,
                (char)((asbd->mFormatID >> 24) & 0xFF),
                (char)((asbd->mFormatID >> 16) & 0xFF),
                (char)((asbd->mFormatID >> 8) & 0xFF),
                (char)(asbd->mFormatID & 0xFF)];
        }
    }
    return s;
}

// 只记录 App 自己录音时用的是什么格式
%hook CWRecorder
- (NSString *)recordPath {
    NSString *path = %orig;
    if (path && path.length > 0) {
        addLog(@"🎙️ App 自己录音的文件: %@", path);
        addLog(@"🎙️ App 自己录音格式: %@", audioInfo(path));
    }
    return path;
}
%end