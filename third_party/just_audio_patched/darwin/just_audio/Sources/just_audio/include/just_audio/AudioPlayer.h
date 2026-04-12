#import <AVFoundation/AVFoundation.h>
#if TARGET_OS_OSX
#import <FlutterMacOS/FlutterMacOS.h>
#else
#import <Flutter/Flutter.h>
#endif

@interface AudioPlayer : NSObject<AVPlayerItemMetadataOutputPushDelegate>

@property (readonly, nonatomic) AVQueuePlayer *player;
@property (readonly, nonatomic) float speed;

- (instancetype)initWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar playerId:(NSString*)idParam loadConfiguration:(NSDictionary *)loadConfiguration useLazyPreparation:(BOOL)useLazyPreparation;
- (void)dispose:(BOOL)calledFromDealloc;
- (void)setBassBoostEnabled:(BOOL)enabled amount:(float)amount;
- (void)setKaraokeEnabled:(BOOL)enabled amount:(float)amount;

@end

enum ProcessingState {
    psIdle,
    psLoading,
    psBuffering,
    psReady,
    psCompleted
};

enum LoopMode {
    lmLoopOff,
    lmLoopOne,
    lmLoopAll
};
