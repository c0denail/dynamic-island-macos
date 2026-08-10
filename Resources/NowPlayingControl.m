#import <Cocoa/Cocoa.h>
#import <dlfcn.h>

typedef bool (*MediaRemoteSendCommand)(NSInteger command, id userInfo);
typedef bool (*MediaRemoteSetElapsedTime)(double elapsedTime);

static const NSInteger kTogglePlayPause = 2;
static const NSInteger kNextTrack = 4;
static const NSInteger kPreviousTrack = 5;
static const NSInteger kRewind15Seconds = 12;
static const NSInteger kForward15Seconds = 13;

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) return 64;

        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];

        void *framework = dlopen(
            "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
            RTLD_NOW | RTLD_GLOBAL
        );
        if (!framework) return 69;

        NSString *command = [NSString stringWithUTF8String:argv[1]];
        bool sent = false;

        if ([command isEqualToString:@"seek"]) {
            if (argc < 3) return 64;
            MediaRemoteSetElapsedTime setElapsed =
                (MediaRemoteSetElapsedTime)dlsym(framework, "MRMediaRemoteSetElapsedTime");
            if (setElapsed) sent = setElapsed(strtod(argv[2], NULL));
        } else {
            NSDictionary<NSString *, NSNumber *> *commands = @{
                @"toggle": @(kTogglePlayPause),
                @"next": @(kNextTrack),
                @"previous": @(kPreviousTrack),
                @"back15": @(kRewind15Seconds),
                @"forward15": @(kForward15Seconds)
            };
            NSNumber *value = commands[command];
            MediaRemoteSendCommand sendCommand =
                (MediaRemoteSendCommand)dlsym(framework, "MRMediaRemoteSendCommand");
            if (value && sendCommand) sent = sendCommand(value.integerValue, nil);
        }

        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.35]];
        dlclose(framework);
        return sent ? 0 : 1;
    }
}
