#import "./include/just_audio/BetterEventChannel.h"
#import "./include/just_audio/AudioPlayer.h"
#import "./include/just_audio/AudioSource.h"
#import "./include/just_audio/IndexedAudioSource.h"
#import "./include/just_audio/LoadControl.h"
#import "./include/just_audio/UriAudioSource.h"
#import "./include/just_audio/ConcatenatingAudioSource.h"
#import "./include/just_audio/LoopingAudioSource.h"
#import "./include/just_audio/ClippingAudioSource.h"
#import <AVFoundation/AVFoundation.h>
#import <MediaToolbox/MediaToolbox.h>
#import <math.h>
#import <stdlib.h>
#include <TargetConditionals.h>

#define TREADMILL_SIZE 2
#define ERROR_ABORT 10000000

typedef struct {
    float bassAmount;
    float karaokeAmount;
    float alpha;
    BOOL isFloat;
    BOOL isSignedInt16;
    BOOL isInterleaved;
    UInt32 channels;
    float prev[8];
} VMAudioTapData;

typedef struct {
    float bassAmount;
    float karaokeAmount;
} VMAudioTapConfig;

static inline float vm_bass_clamp(float value, float minValue, float maxValue) {
    if (value < minValue) return minValue;
    if (value > maxValue) return maxValue;
    return value;
}

static inline CMItemCount vm_min_frames(CMItemCount a, CMItemCount b) {
    return a < b ? a : b;
}

static inline void vm_apply_karaoke_pair(
    float leftDry,
    float rightDry,
    float karaokeAmount,
    float *leftOut,
    float *rightOut
) {
    const float side = (leftDry - rightDry) * 0.5f;
    const float center = (leftDry + rightDry) * 0.5f;
    const float centerCancel = vm_bass_clamp(
        0.90f + (karaokeAmount * 0.08f),
        0.90f,
        0.995f
    );
    const float centerKeep = vm_bass_clamp(
        0.12f - (karaokeAmount * 0.06f),
        0.02f,
        0.12f
    );
    const float sideBoost = vm_bass_clamp(
        1.10f + (karaokeAmount * 0.12f),
        1.10f,
        1.32f
    );

    const float reducedCenter = center * (1.0f - centerCancel) * centerKeep;
    const float wetL = (side * sideBoost) + reducedCenter;
    const float wetR = (-side * sideBoost) + reducedCenter;

    const float dryMix = vm_bass_clamp(0.16f - (karaokeAmount * 0.07f), 0.03f, 0.16f);
    const float wetMix = 1.0f - dryMix;

    *leftOut = vm_bass_clamp((leftDry * dryMix) + (wetL * wetMix), -1.0f, 1.0f);
    *rightOut = vm_bass_clamp((rightDry * dryMix) + (wetR * wetMix), -1.0f, 1.0f);
}

static void vm_bass_tap_init(
    MTAudioProcessingTapRef tap,
    void *clientInfo,
    void **tapStorageOut
) {
    VMAudioTapData *storage = calloc(1, sizeof(VMAudioTapData));
    storage->bassAmount = 0.95f;
    storage->karaokeAmount = 0.0f;
    if (clientInfo != NULL) {
        VMAudioTapConfig *cfg = (VMAudioTapConfig *)clientInfo;
        storage->bassAmount = cfg->bassAmount;
        storage->karaokeAmount = cfg->karaokeAmount;
        free(cfg);
    }
    *tapStorageOut = storage;
}

static void vm_bass_tap_finalize(MTAudioProcessingTapRef tap) {
    VMAudioTapData *storage = (VMAudioTapData *)MTAudioProcessingTapGetStorage(tap);
    if (storage != NULL) {
        free(storage);
    }
}

static void vm_bass_tap_prepare(
    MTAudioProcessingTapRef tap,
    CMItemCount maxFrames,
    const AudioStreamBasicDescription *processingFormat
) {
    VMAudioTapData *storage = (VMAudioTapData *)MTAudioProcessingTapGetStorage(tap);
    if (storage == NULL || processingFormat == NULL) return;
    storage->channels = processingFormat->mChannelsPerFrame;
    storage->isFloat = (processingFormat->mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    storage->isSignedInt16 =
        !storage->isFloat &&
        (processingFormat->mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0 &&
        processingFormat->mBitsPerChannel == 16;
    storage->isInterleaved = (processingFormat->mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0;
    const float sampleRate = (float)processingFormat->mSampleRate;
    const float cutoff = 170.0f;
    if (sampleRate > 0.0f) {
      const float rc = 1.0f / (2.0f * (float)M_PI * cutoff);
      const float dt = 1.0f / sampleRate;
      storage->alpha = dt / (rc + dt);
    } else {
      storage->alpha = 0.02f;
    }
    for (int i = 0; i < 8; i++) {
        storage->prev[i] = 0.0f;
    }
}

static void vm_bass_tap_unprepare(MTAudioProcessingTapRef tap) {}

static void vm_bass_tap_process(
    MTAudioProcessingTapRef tap,
    CMItemCount numberFrames,
    MTAudioProcessingTapFlags flags,
    AudioBufferList *bufferListInOut,
    CMItemCount *numberFramesOut,
    MTAudioProcessingTapFlags *flagsOut
) {
    OSStatus status = MTAudioProcessingTapGetSourceAudio(
        tap,
        numberFrames,
        bufferListInOut,
        flagsOut,
        NULL,
        numberFramesOut
    );
    if (status != noErr) return;

    VMAudioTapData *storage = (VMAudioTapData *)MTAudioProcessingTapGetStorage(tap);
    if (storage == NULL || numberFramesOut == NULL) return;
    // Safety: process only formats we explicitly support.
    if (!storage->isFloat && !storage->isSignedInt16) return;

    const float alpha = vm_bass_clamp(storage->alpha, 0.0005f, 0.95f);
    const float bassAmount = vm_bass_clamp(storage->bassAmount, 0.0f, 2.2f);
    const float karaokeAmount = vm_bass_clamp(storage->karaokeAmount, 0.0f, 1.8f);
    const BOOL applyBass = bassAmount > 0.0f;
    const BOOL applyKaraoke = karaokeAmount > 0.0f;
    if (!applyBass && !applyKaraoke) return;
    const CMItemCount requestedFrames = *numberFramesOut;
    if (requestedFrames <= 0) return;

    const UInt32 channels = storage->channels;
    if (channels == 0) return;
    const UInt32 limitedChannels = channels > 8 ? 8 : channels;

    if (storage->isFloat) {
        if (storage->isInterleaved) {
            if (bufferListInOut->mNumberBuffers < 1) return;
            AudioBuffer *buffer = &bufferListInOut->mBuffers[0];
            float *samples = (float *)buffer->mData;
            if (samples == NULL) return;
            const size_t sampleCount = buffer->mDataByteSize / sizeof(float);
            const CMItemCount availableFrames = (CMItemCount)(sampleCount / channels);
            const CMItemCount framesToProcess = vm_min_frames(requestedFrames, availableFrames);
            if (framesToProcess <= 0) return;
            for (CMItemCount frame = 0; frame < framesToProcess; frame++) {
                for (UInt32 channel = 0; channel < limitedChannels; channel++) {
                    const UInt32 idx = (UInt32)(frame * channels + channel);
                    const float dry = samples[idx];
                    const float low = storage->prev[channel] + alpha * (dry - storage->prev[channel]);
                    storage->prev[channel] = low;
                    float wet = dry;
                    if (applyBass) {
                        wet = dry + (low * bassAmount);
                    }
                    samples[idx] = vm_bass_clamp(wet, -1.0f, 1.0f);
                }
                if (applyKaraoke && channels >= 2) {
                    const UInt32 leftIdx = (UInt32)(frame * channels);
                    const UInt32 rightIdx = leftIdx + 1;
                    const float leftDry = samples[leftIdx];
                    const float rightDry = samples[rightIdx];
                    float outL = leftDry;
                    float outR = rightDry;
                    vm_apply_karaoke_pair(
                        leftDry,
                        rightDry,
                        karaokeAmount,
                        &outL,
                        &outR
                    );
                    samples[leftIdx] = outL;
                    samples[rightIdx] = outR;
                }
            }
            return;
        }

        const UInt32 bufferChannels = bufferListInOut->mNumberBuffers < limitedChannels
            ? bufferListInOut->mNumberBuffers
            : limitedChannels;
        for (UInt32 channel = 0; channel < bufferChannels; channel++) {
            AudioBuffer *buffer = &bufferListInOut->mBuffers[channel];
            float *samples = (float *)buffer->mData;
            if (samples == NULL) continue;
            const CMItemCount availableFrames = (CMItemCount)(buffer->mDataByteSize / sizeof(float));
            const CMItemCount framesToProcess = vm_min_frames(requestedFrames, availableFrames);
            if (framesToProcess <= 0) continue;
            for (CMItemCount frame = 0; frame < framesToProcess; frame++) {
                const float dry = samples[frame];
                const float low = storage->prev[channel] + alpha * (dry - storage->prev[channel]);
                storage->prev[channel] = low;
                float wet = dry;
                if (applyBass) {
                    wet = dry + (low * bassAmount);
                }
                samples[frame] = vm_bass_clamp(wet, -1.0f, 1.0f);
            }
        }
        if (applyKaraoke && bufferListInOut->mNumberBuffers >= 2) {
            AudioBuffer *leftBuffer = &bufferListInOut->mBuffers[0];
            AudioBuffer *rightBuffer = &bufferListInOut->mBuffers[1];
            float *leftSamples = (float *)leftBuffer->mData;
            float *rightSamples = (float *)rightBuffer->mData;
            if (leftSamples != NULL && rightSamples != NULL) {
                const CMItemCount leftFrames = (CMItemCount)(leftBuffer->mDataByteSize / sizeof(float));
                const CMItemCount rightFrames = (CMItemCount)(rightBuffer->mDataByteSize / sizeof(float));
                const CMItemCount framesToProcess = vm_min_frames(requestedFrames, vm_min_frames(leftFrames, rightFrames));
                for (CMItemCount frame = 0; frame < framesToProcess; frame++) {
                    const float leftDry = leftSamples[frame];
                    const float rightDry = rightSamples[frame];
                    float outL = leftDry;
                    float outR = rightDry;
                    vm_apply_karaoke_pair(
                        leftDry,
                        rightDry,
                        karaokeAmount,
                        &outL,
                        &outR
                    );
                    leftSamples[frame] = outL;
                    rightSamples[frame] = outR;
                }
            }
        }
        return;
    }

    if (storage->isInterleaved) {
        if (bufferListInOut->mNumberBuffers < 1) return;
        AudioBuffer *buffer = &bufferListInOut->mBuffers[0];
        int16_t *samples = (int16_t *)buffer->mData;
        if (samples == NULL) return;
        const size_t sampleCount = buffer->mDataByteSize / sizeof(int16_t);
        const CMItemCount availableFrames = (CMItemCount)(sampleCount / channels);
        const CMItemCount framesToProcess = vm_min_frames(requestedFrames, availableFrames);
        if (framesToProcess <= 0) return;
        for (CMItemCount frame = 0; frame < framesToProcess; frame++) {
            for (UInt32 channel = 0; channel < limitedChannels; channel++) {
                const UInt32 idx = (UInt32)(frame * channels + channel);
                const float dry = (float)samples[idx] / 32768.0f;
                const float low = storage->prev[channel] + alpha * (dry - storage->prev[channel]);
                storage->prev[channel] = low;
                float wet = dry;
                if (applyBass) {
                    wet = vm_bass_clamp(dry + (low * bassAmount), -1.0f, 1.0f);
                }
                samples[idx] = (int16_t)(wet * 32767.0f);
            }
            if (applyKaraoke && channels >= 2) {
                const UInt32 leftIdx = (UInt32)(frame * channels);
                const UInt32 rightIdx = leftIdx + 1;
                const float leftDry = (float)samples[leftIdx] / 32768.0f;
                const float rightDry = (float)samples[rightIdx] / 32768.0f;
                float outL = leftDry;
                float outR = rightDry;
                vm_apply_karaoke_pair(
                    leftDry,
                    rightDry,
                    karaokeAmount,
                    &outL,
                    &outR
                );
                samples[leftIdx] = (int16_t)(outL * 32767.0f);
                samples[rightIdx] = (int16_t)(outR * 32767.0f);
            }
        }
        return;
    }

    const UInt32 bufferChannels = bufferListInOut->mNumberBuffers < limitedChannels
        ? bufferListInOut->mNumberBuffers
        : limitedChannels;
    for (UInt32 channel = 0; channel < bufferChannels; channel++) {
        AudioBuffer *buffer = &bufferListInOut->mBuffers[channel];
        int16_t *samples = (int16_t *)buffer->mData;
        if (samples == NULL) continue;
        const CMItemCount availableFrames = (CMItemCount)(buffer->mDataByteSize / sizeof(int16_t));
        const CMItemCount framesToProcess = vm_min_frames(requestedFrames, availableFrames);
        if (framesToProcess <= 0) continue;
        for (CMItemCount frame = 0; frame < framesToProcess; frame++) {
            const float dry = (float)samples[frame] / 32768.0f;
            const float low = storage->prev[channel] + alpha * (dry - storage->prev[channel]);
            storage->prev[channel] = low;
            float wet = dry;
            if (applyBass) {
                wet = vm_bass_clamp(dry + (low * bassAmount), -1.0f, 1.0f);
            }
            samples[frame] = (int16_t)(wet * 32767.0f);
        }
    }
    if (applyKaraoke && bufferListInOut->mNumberBuffers >= 2) {
        AudioBuffer *leftBuffer = &bufferListInOut->mBuffers[0];
        AudioBuffer *rightBuffer = &bufferListInOut->mBuffers[1];
        int16_t *leftSamples = (int16_t *)leftBuffer->mData;
        int16_t *rightSamples = (int16_t *)rightBuffer->mData;
        if (leftSamples != NULL && rightSamples != NULL) {
            const CMItemCount leftFrames = (CMItemCount)(leftBuffer->mDataByteSize / sizeof(int16_t));
            const CMItemCount rightFrames = (CMItemCount)(rightBuffer->mDataByteSize / sizeof(int16_t));
            const CMItemCount framesToProcess = vm_min_frames(requestedFrames, vm_min_frames(leftFrames, rightFrames));
            for (CMItemCount frame = 0; frame < framesToProcess; frame++) {
                const float leftDry = (float)leftSamples[frame] / 32768.0f;
                const float rightDry = (float)rightSamples[frame] / 32768.0f;
                float outL = leftDry;
                float outR = rightDry;
                vm_apply_karaoke_pair(
                    leftDry,
                    rightDry,
                    karaokeAmount,
                    &outL,
                    &outR
                );
                leftSamples[frame] = (int16_t)(outL * 32767.0f);
                rightSamples[frame] = (int16_t)(outR * 32767.0f);
            }
        }
    }
    return;
}

// TODO: Check for and report invalid state transitions.
// TODO: Apply Apple's guidance on seeking: https://developer.apple.com/library/archive/qa/qa1820/_index.html
@implementation AudioPlayer {
    NSObject<FlutterPluginRegistrar>* _registrar;
    FlutterMethodChannel *_methodChannel;
    BetterEventChannel *_eventChannel;
    BetterEventChannel *_dataEventChannel;
    NSString *_playerId;
    AVQueuePlayer *_player;
    AudioSource *_audioSource;
    NSMutableArray<IndexedAudioSource *> *_indexedAudioSources;
    NSArray<NSNumber *> *_order;
    NSMutableArray<NSNumber *> *_orderInv;
    int _index;
    enum ProcessingState _processingState;
    enum LoopMode _loopMode;
    BOOL _shuffleModeEnabled;
    long long _updateTime;
    int _updatePosition;
    int _lastPosition;
    int _bufferedPosition;
    // Set when the current item hasn't been played yet so we aren't sure whether sufficient audio has been buffered.
    BOOL _bufferUnconfirmed;
    CMTime _seekPos;
    FlutterResult _loadResult;
    FlutterResult _playResult;
    id _timeObserver;
    BOOL _automaticallyWaitsToMinimizeStalling;
    BOOL _allowsExternalPlayback;
    LoadControl *_loadControl;
    BOOL _useLazyPreparation;
    BOOL _playing;
    float _speed;
    float _volume;
    BOOL _justAdvanced;
    BOOL _enqueuedAll;
    NSDictionary<NSString *, NSObject *> *_icyMetadata;
    NSNumber *_errorCode;
    NSString *_errorMessage;
    BOOL _bassBoostEnabled;
    float _bassBoostAmount;
    BOOL _karaokeEnabled;
    float _karaokeAmount;
}

- (instancetype)initWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar playerId:(NSString*)idParam loadConfiguration:(NSDictionary *)loadConfiguration useLazyPreparation:(BOOL)useLazyPreparation {
    self = [super init];
    NSAssert(self, @"super init cannot be nil");
    _registrar = registrar;
    _playerId = idParam;
    _useLazyPreparation = useLazyPreparation;
    _methodChannel =
        [FlutterMethodChannel methodChannelWithName:[NSMutableString stringWithFormat:@"com.ryanheise.just_audio.methods.%@", _playerId]
                                    binaryMessenger:[registrar messenger]];
    _eventChannel = [[BetterEventChannel alloc]
        initWithName:[NSMutableString stringWithFormat:@"com.ryanheise.just_audio.events.%@", _playerId]
           messenger:[registrar messenger]];
    _dataEventChannel = [[BetterEventChannel alloc]
        initWithName:[NSMutableString stringWithFormat:@"com.ryanheise.just_audio.data.%@", _playerId]
           messenger:[registrar messenger]];
    _index = 0;
    _processingState = psIdle;
    _loopMode = lmLoopOff;
    _shuffleModeEnabled = NO;
    _player = nil;
    _audioSource = nil;
    _indexedAudioSources = nil;
    _order = nil;
    _orderInv = nil;
    _seekPos = kCMTimeInvalid;
    _timeObserver = 0;
    _updatePosition = 0;
    _updateTime = 0;
    _lastPosition = 0;
    _bufferedPosition = 0;
    _bufferUnconfirmed = NO;
    _playing = NO;
    _loadResult = nil;
    _playResult = nil;
    _automaticallyWaitsToMinimizeStalling = YES;
    _allowsExternalPlayback = NO;
    _loadControl = nil;
    if (loadConfiguration != (id)[NSNull null]) {
        NSDictionary *map = loadConfiguration[@"darwinLoadControl"];
        if (map != (id)[NSNull null]) {
            _loadControl = [[LoadControl alloc] init];
            _loadControl.preferredForwardBufferDuration = (NSNumber *)map[@"preferredForwardBufferDuration"];
            _loadControl.canUseNetworkResourcesForLiveStreamingWhilePaused = (BOOL)[map[@"canUseNetworkResourcesForLiveStreamingWhilePaused"] boolValue];
            _loadControl.preferredPeakBitRate = (NSNumber *)map[@"preferredPeakBitRate"];
            _automaticallyWaitsToMinimizeStalling = (BOOL)[map[@"automaticallyWaitsToMinimizeStalling"] boolValue];
        }
    }
    if (!_loadControl) {
        _loadControl = [[LoadControl alloc] init];
        _loadControl.preferredForwardBufferDuration = (NSNumber *)[NSNull null];
        _loadControl.canUseNetworkResourcesForLiveStreamingWhilePaused = NO;
        _loadControl.preferredPeakBitRate = (NSNumber *)[NSNull null];
    }
    _speed = 1.0f;
    _volume = 1.0f;
    _justAdvanced = NO;
    _enqueuedAll = NO;
    _icyMetadata = @{};
    _errorCode = (NSNumber *)[NSNull null];
    _errorMessage = (NSString *)[NSNull null];
    _bassBoostEnabled = NO;
    _bassBoostAmount = 0.95f;
    _karaokeEnabled = NO;
    _karaokeAmount = 1.0f;
    __weak __typeof__(self) weakSelf = self;
    [_methodChannel setMethodCallHandler:^(FlutterMethodCall* call, FlutterResult result) {
        [weakSelf handleMethodCall:call result:result];
    }];
    return self;
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
    @try {
        //NSLog(@"method: %@ index=%d", call.method, _index);
        NSDictionary *request = (NSDictionary *)call.arguments;
        if ([@"load" isEqualToString:call.method]) {
            CMTime initialPosition = request[@"initialPosition"] == (id)[NSNull null] ? kCMTimeInvalid : CMTimeMake([request[@"initialPosition"] longLongValue], 1000000);
            [self load:request[@"audioSource"] initialPosition:initialPosition initialIndex:request[@"initialIndex"] result:result];
        } else if ([@"play" isEqualToString:call.method]) {
            [self play:result];
        } else if ([@"pause" isEqualToString:call.method]) {
            [self pause];
            result(@{});
        } else if ([@"setVolume" isEqualToString:call.method]) {
            [self setVolume:(float)[request[@"volume"] doubleValue]];
            result(@{});
        } else if ([@"setSkipSilence" isEqualToString:call.method]) {
            /// TODO on iOS side; Seems more involved, so someone with ObjectiveC experience might look at it.
            result(@{});
        } else if ([@"setSpeed" isEqualToString:call.method]) {
            [self setSpeed:(float)[request[@"speed"] doubleValue]];
            result(@{});
        } else if ([@"setLoopMode" isEqualToString:call.method]) {
            [self setLoopMode:[request[@"loopMode"] intValue]];
            result(@{});
        } else if ([@"setShuffleMode" isEqualToString:call.method]) {
            [self setShuffleModeEnabled:(BOOL)([request[@"shuffleMode"] intValue] == 1)];
            result(@{});
        } else if ([@"setShuffleOrder" isEqualToString:call.method]) {
            [self setShuffleOrder:(NSDictionary *)request[@"audioSource"]];
            result(@{});
        } else if ([@"setAutomaticallyWaitsToMinimizeStalling" isEqualToString:call.method]) {
            [self setAutomaticallyWaitsToMinimizeStalling:(BOOL)[request[@"enabled"] boolValue]];
            result(@{});
        } else if ([@"setCanUseNetworkResourcesForLiveStreamingWhilePaused" isEqualToString:call.method]) {
            [self setCanUseNetworkResourcesForLiveStreamingWhilePaused:(BOOL)[request[@"enabled"] boolValue]];
            result(@{});
        } else if ([@"setPreferredPeakBitRate" isEqualToString:call.method]) {
            [self setPreferredPeakBitRate:(NSNumber *)request[@"bitRate"]];
            result(@{});
        } else if ([@"setAllowsExternalPlayback" isEqualToString:call.method]) {
            [self setAllowsExternalPlayback:(BOOL)([request[@"allowsExternalPlayback"] intValue] == 1)];
            result(@{});
        } else if ([@"seek" isEqualToString:call.method]) {
            CMTime position = request[@"position"] == (id)[NSNull null] ? kCMTimePositiveInfinity : CMTimeMake([request[@"position"] longLongValue], 1000000);
            [self seek:position index:request[@"index"] completionHandler:^(BOOL finished) {
                result(@{});
            }];
        } else if ([@"concatenatingInsertAll" isEqualToString:call.method]) {
            [self concatenatingInsertAll:(NSString *)request[@"id"] index:[request[@"index"] intValue] sources:(NSArray *)request[@"children"] shuffleOrder:(NSArray<NSNumber *> *)request[@"shuffleOrder"]];
            result(@{});
        } else if ([@"concatenatingRemoveRange" isEqualToString:call.method]) {
            [self concatenatingRemoveRange:(NSString *)request[@"id"] start:[request[@"startIndex"] intValue] end:[request[@"endIndex"] intValue] shuffleOrder:(NSArray<NSNumber *> *)request[@"shuffleOrder"]];
            result(@{});
        } else if ([@"concatenatingMove" isEqualToString:call.method]) {
            [self concatenatingMove:(NSString *)request[@"id"] currentIndex:[request[@"currentIndex"] intValue] newIndex:[request[@"newIndex"] intValue] shuffleOrder:(NSArray<NSNumber *> *)request[@"shuffleOrder"]];
            result(@{});
        } else if ([@"setAndroidAudioAttributes" isEqualToString:call.method]) {
            result(@{});
        } else {
            result(FlutterMethodNotImplemented);
        }
    } @catch (NSException *exception) {
        //NSLog(@"%@", [exception callStackSymbols]);
        FlutterError *flutterError = [FlutterError errorWithCode:@"error" message:@"Error in handleMethodCall" details:nil];
        result(flutterError);
    }
}

- (AVQueuePlayer *)player {
    return _player;
}

- (float)speed {
    return _speed;
}

- (void)setBassBoostEnabled:(BOOL)enabled amount:(float)amount {
    _bassBoostEnabled = enabled;
    _bassBoostAmount = vm_bass_clamp(amount, 0.0f, 2.2f);
    [self applyAudioProcessingToAllItems];
}

- (void)setKaraokeEnabled:(BOOL)enabled amount:(float)amount {
    _karaokeEnabled = enabled;
    _karaokeAmount = vm_bass_clamp(amount, 0.0f, 1.8f);
    [self applyAudioProcessingToAllItems];
}

- (void)applyAudioProcessingToAllItems {
    if (_player == nil) return;
    NSMutableArray<AVPlayerItem *> *items = [NSMutableArray arrayWithArray:_player.items];
    if (_player.currentItem != nil && ![items containsObject:_player.currentItem]) {
        [items addObject:_player.currentItem];
    }
    for (AVPlayerItem *item in items) {
        [self applyAudioProcessingToPlayerItem:item];
    }
}

- (void)applyAudioProcessingToPlayerItem:(AVPlayerItem *)playerItem {
    if (playerItem == nil) return;
    if (!_bassBoostEnabled && !_karaokeEnabled) {
        playerItem.audioMix = nil;
        return;
    }

    NSArray<AVAssetTrack *> *audioTracks = [playerItem.asset tracksWithMediaType:AVMediaTypeAudio];
    if (audioTracks.count == 0) return;

    AVMutableAudioMixInputParameters *inputParams =
        [AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:audioTracks.firstObject];

    VMAudioTapConfig *configPtr = malloc(sizeof(VMAudioTapConfig));
    if (configPtr == NULL) return;
    configPtr->bassAmount = _bassBoostEnabled ? _bassBoostAmount : 0.0f;
    configPtr->karaokeAmount = _karaokeEnabled ? _karaokeAmount : 0.0f;

    MTAudioProcessingTapCallbacks callbacks;
    callbacks.version = kMTAudioProcessingTapCallbacksVersion_0;
    callbacks.clientInfo = configPtr;
    callbacks.init = vm_bass_tap_init;
    callbacks.finalize = vm_bass_tap_finalize;
    callbacks.prepare = vm_bass_tap_prepare;
    callbacks.unprepare = vm_bass_tap_unprepare;
    callbacks.process = vm_bass_tap_process;

    MTAudioProcessingTapRef tap = NULL;
    OSStatus tapStatus = MTAudioProcessingTapCreate(
        kCFAllocatorDefault,
        &callbacks,
        kMTAudioProcessingTapCreationFlag_PostEffects,
        &tap
    );
    if (tapStatus != noErr || tap == NULL) {
        free(configPtr);
        return;
    }
    inputParams.audioTapProcessor = tap;
    CFRelease(tap);

    AVMutableAudioMix *mix = [AVMutableAudioMix audioMix];
    mix.inputParameters = @[inputParams];
    playerItem.audioMix = mix;
}

// Untested
- (void)concatenatingInsertAll:(NSString *)catId index:(int)index sources:(NSArray *)sources shuffleOrder:(NSArray<NSNumber *> *)shuffleOrder {
    // Find all duplicates of the identified ConcatenatingAudioSource.
    NSMutableArray *matches = [[NSMutableArray alloc] init];
    [_audioSource findById:catId matches:matches];
    // Add each new source to each match.
    for (int i = 0; i < matches.count; i++) {
        ConcatenatingAudioSource *catSource = (ConcatenatingAudioSource *)matches[i];
        int idx = index >= 0 ? index : catSource.count;
        NSMutableArray<AudioSource *> *audioSources = [self decodeAudioSources:sources];
        for (int j = 0; j < audioSources.count; j++) {
            AudioSource *audioSource = audioSources[j];
            [catSource insertSource:audioSource atIndex:(idx + j)];
        }
        [catSource setShuffleOrder:shuffleOrder];
    }
    // Index the new audio sources.
    _indexedAudioSources = [[NSMutableArray alloc] init];
    [_audioSource buildSequence:_indexedAudioSources treeIndex:0];
    for (int i = 0; i < [_indexedAudioSources count]; i++) {
        IndexedAudioSource *audioSource = _indexedAudioSources[i];
        if (!audioSource.isAttached) {
            audioSource.playerItem.audioSource = audioSource;
            [self addItemObservers:audioSource.playerItem];
        }
    }
    [self updateOrder];
    if (_player.currentItem) {
        _index = [self indexForItem:(IndexedPlayerItem *)_player.currentItem];
    } else {
        _index = 0;
    }
    [self enqueueFrom:_index];
    // Notify each new IndexedAudioSource that it's been attached to the player.
    for (int i = 0; i < [_indexedAudioSources count]; i++) {
        if (!_indexedAudioSources[i].isAttached) {
            [_indexedAudioSources[i] attach:_player initialPos:kCMTimeInvalid];
        }
    }
    [self broadcastPlaybackEvent];
}

// Untested
- (void)concatenatingRemoveRange:(NSString *)catId start:(int)start end:(int)end shuffleOrder:(NSArray<NSNumber *> *)shuffleOrder {
    // Find all duplicates of the identified ConcatenatingAudioSource.
    NSMutableArray *matches = [[NSMutableArray alloc] init];
    [_audioSource findById:catId matches:matches];
    // Remove range from each match.
    for (int i = 0; i < matches.count; i++) {
        ConcatenatingAudioSource *catSource = (ConcatenatingAudioSource *)matches[i];
        int endIndex = end >= 0 ? end : catSource.count;
        [catSource removeSourcesFromIndex:start toIndex:endIndex];
        [catSource setShuffleOrder:shuffleOrder];
    }
    // Re-index the remaining audio sources.
    NSArray<IndexedAudioSource *> *oldIndexedAudioSources = _indexedAudioSources;
    _indexedAudioSources = [[NSMutableArray alloc] init];
    [_audioSource buildSequence:_indexedAudioSources treeIndex:0];
    for (int i = 0, j = 0; i < _indexedAudioSources.count; i++, j++) {
        IndexedAudioSource *audioSource = _indexedAudioSources[i];
        while (audioSource != oldIndexedAudioSources[j]) {
            [self removeItemObservers:oldIndexedAudioSources[j].playerItem];
            if (oldIndexedAudioSources[j].playerItem2) {
                [self removeItemObservers:oldIndexedAudioSources[j].playerItem2];
            }
            if (j < _index) {
                _index--;
            } else if (j == _index) {
                // The currently playing item was removed.
            }
            j++;
        }
    }
    [self updateOrder];
    if (_index >= _indexedAudioSources.count) _index = (int)_indexedAudioSources.count - 1;
    if (_index < 0) _index = 0;
    [self enqueueFrom:_index];
    [self broadcastPlaybackEvent];
}

// Untested
- (void)concatenatingMove:(NSString *)catId currentIndex:(int)currentIndex newIndex:(int)newIndex shuffleOrder:(NSArray<NSNumber *> *)shuffleOrder {
    // Find all duplicates of the identified ConcatenatingAudioSource.
    NSMutableArray *matches = [[NSMutableArray alloc] init];
    [_audioSource findById:catId matches:matches];
    // Move range within each match.
    for (int i = 0; i < matches.count; i++) {
        ConcatenatingAudioSource *catSource = (ConcatenatingAudioSource *)matches[i];
        [catSource moveSourceFromIndex:currentIndex toIndex:newIndex];
        [catSource setShuffleOrder:shuffleOrder];
    }
    // Re-index the audio sources.
    _indexedAudioSources = [[NSMutableArray alloc] init];
    [_audioSource buildSequence:_indexedAudioSources treeIndex:0];
    [self updateOrder];
    [self enqueueFrom:[self indexForItem:(IndexedPlayerItem *)_player.currentItem]];
    [self broadcastPlaybackEvent];
}

- (void)checkForDiscontinuity {
    if (!_playing || CMTIME_IS_VALID(_seekPos) || _processingState == psCompleted) return;
    int position = [self getCurrentPosition];
    if (_processingState == psBuffering) {
        if (position > _lastPosition) {
            [self leaveBuffering:@"stall ended"];
            [self updatePosition];
            [self broadcastPlaybackEvent];
        }
    } else {
        long long now = (long long)([[NSDate date] timeIntervalSince1970] * 1000.0);
        long long timeSinceLastUpdate = now - _updateTime;
        long long expectedPosition = _updatePosition + (long long)(timeSinceLastUpdate * _player.rate);
        long long drift = position - expectedPosition;
        //NSLog(@"position: %d, drift: %lld", position, drift);
        // Update if we've drifted or just started observing
        if (_updateTime == 0L) {
            [self broadcastPlaybackEvent];
        } else if (drift < -100) {
            [self enterBuffering:@"stalling"];
            //NSLog(@"Drift: %lld", drift);
            [self updatePosition];
            [self broadcastPlaybackEvent];
        }
    }
    _lastPosition = position;
}

- (void)enterBuffering:(NSString *)reason {
    if (_processingState != psIdle) {
        //NSLog(@"ENTER BUFFERING: %@", reason);
        _processingState = psBuffering;
    }
}

- (void)leaveBuffering:(NSString *)reason {
    if (_processingState == psBuffering || _processingState == psLoading) {
        //NSLog(@"LEAVE BUFFERING: %@", reason);
        _processingState = psReady;
    }
}

- (void)broadcastPlaybackEvent {
    [_eventChannel sendEvent:@{
            @"processingState": @(_processingState),
            @"updatePosition": @((long long)1000 * _updatePosition),
            @"updateTime": @(_updateTime),
            @"bufferedPosition": @((long long)1000 * [self getBufferedPosition]),
            @"icyMetadata": _icyMetadata,
            @"duration": @([self getDurationMicroseconds]),
            @"currentIndex": @(_index),
            @"errorCode": _errorCode,
            @"errorMessage": _errorMessage,
    }];
}

- (int)getCurrentPosition {
    // XXX: During load, the second case will be selected returning 0.
    // TODO: Provide a similar case as _seekPos for _initialPos.
    if (CMTIME_IS_VALID(_seekPos)) {
        return (int)(1000 * CMTimeGetSeconds(_seekPos));
    } else if (_indexedAudioSources && _indexedAudioSources.count > 0) {
        int ms = (int)(1000 * CMTimeGetSeconds(_indexedAudioSources[_index].position));
        if (ms < 0) ms = 0;
        return ms;
    } else {
        return 0;
    }
}

- (int)getBufferedPosition {
    if (_processingState == psIdle || _processingState == psLoading) {
        return 0;
    } else if (_indexedAudioSources && _indexedAudioSources.count > 0) {
        int ms = (int)(1000 * CMTimeGetSeconds(_indexedAudioSources[_index].bufferedPosition));
        if (ms < 0) ms = 0;
        return ms;
    } else {
        return 0;
    }
}

- (int)getDuration {
    if (_processingState == psIdle || _processingState == psLoading) {
        return -1;
    } else if (_indexedAudioSources && _indexedAudioSources.count > 0) {
        int v = (int)(1000 * CMTimeGetSeconds(_indexedAudioSources[_index].duration));
        return v;
    } else {
        return 0;
    }
}

- (long long)getDurationMicroseconds {
    int duration = [self getDuration];
    return duration < 0 ? -1 : ((long long)1000 * duration);
}

- (void)removeItemObservers:(AVPlayerItem *)playerItem {
    [playerItem removeObserver:self forKeyPath:@"status"];
    [playerItem removeObserver:self forKeyPath:@"playbackBufferEmpty"];
    [playerItem removeObserver:self forKeyPath:@"playbackBufferFull"];
    [playerItem removeObserver:self forKeyPath:@"loadedTimeRanges"];
    //[playerItem removeObserver:self forKeyPath:@"playbackLikelyToKeepUp"];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemDidPlayToEndTimeNotification object:playerItem];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemFailedToPlayToEndTimeNotification object:playerItem];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemPlaybackStalledNotification object:playerItem];
}

- (void)addItemObservers:(AVPlayerItem *)playerItem {
    // Get notified when the item is loaded or had an error loading
    [playerItem addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionNew context:nil];
    // Get notified of the buffer state
    [playerItem addObserver:self forKeyPath:@"playbackBufferEmpty" options:NSKeyValueObservingOptionNew context:nil];
    [playerItem addObserver:self forKeyPath:@"playbackBufferFull" options:NSKeyValueObservingOptionNew context:nil];
    [playerItem addObserver:self forKeyPath:@"loadedTimeRanges" options:NSKeyValueObservingOptionNew context:nil];
    //[playerItem addObserver:self forKeyPath:@"playbackLikelyToKeepUp" options:NSKeyValueObservingOptionNew context:nil];
    // Get notified when playback has reached the end
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onComplete:) name:AVPlayerItemDidPlayToEndTimeNotification object:playerItem];
    // Get notified when playback stops due to a failure (currently unused)
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onFailToComplete:) name:AVPlayerItemFailedToPlayToEndTimeNotification object:playerItem];
    // Get notified when playback stalls (currently unused)
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onItemStalled:) name:AVPlayerItemPlaybackStalledNotification object:playerItem];

    AVPlayerItemMetadataOutput *metadataOutput = [[AVPlayerItemMetadataOutput alloc] initWithIdentifiers:nil];
    [metadataOutput setDelegate:self queue:dispatch_get_main_queue()];
    // Since the delegate is stored as a weak reference,
    // there shouldn't be a retain cycle.
    // TODO: Check this. Shouldn't need to removeOutput
    // later?
    [playerItem addOutput:metadataOutput];
}

- (void)metadataOutput:(AVPlayerItemMetadataOutput *)output didOutputTimedMetadataGroups:(NSArray<AVTimedMetadataGroup *> *)groups fromPlayerItemTrack:(AVPlayerItemTrack *)track {
    // ICY headers aren't available here. Maybe do this in the proxy.
    BOOL hasIcyData = NO;
    NSString *title = (NSString *)[NSNull null];
    NSString *url = (NSString *)[NSNull null];
    for (int i = 0; i < groups.count; i++) {
        AVTimedMetadataGroup *group = groups[i];
        for (int j = 0; j < group.items.count; j++) {
            AVMetadataItem *item = group.items[j];
            if ([@"icy/StreamTitle" isEqualToString:item.identifier]) {
                hasIcyData = YES;
                title = (NSString *)item.value;
            } else if ([@"icy/StreamUrl" isEqualToString:item.identifier]) {
                hasIcyData = YES;
                url = (NSString *)item.value;
            }
        }
    }
    if (hasIcyData) {
        _icyMetadata = @{
            @"info": @{
                @"title": title,
                @"url": url,
            },
        };
        [self broadcastPlaybackEvent];
    }
}

- (NSMutableArray<AudioSource *> *)decodeAudioSources:(NSArray *)data {
    NSMutableArray<AudioSource *> *array = (NSMutableArray<AudioSource *> *)[[NSMutableArray alloc] init];
    for (int i = 0; i < [data count]; i++) {
        AudioSource *source = [self decodeAudioSource:data[i]];
        [array addObject:source];
    }
    return array;
}

- (AudioSource *)decodeAudioSource:(NSDictionary *)data {
    NSString *type = data[@"type"];
    if ([@"progressive" isEqualToString:type]) {
        return [[UriAudioSource alloc] initWithId:data[@"id"] uri:data[@"uri"] loadControl:_loadControl headers:data[@"headers"] options:data[@"options"]];
    } else if ([@"dash" isEqualToString:type]) {
        return [[UriAudioSource alloc] initWithId:data[@"id"] uri:data[@"uri"] loadControl:_loadControl headers:data[@"headers"] options:data[@"options"]];
    } else if ([@"hls" isEqualToString:type]) {
        return [[UriAudioSource alloc] initWithId:data[@"id"] uri:data[@"uri"] loadControl:_loadControl headers:data[@"headers"] options:data[@"options"]];
    } else if ([@"concatenating" isEqualToString:type]) {
        return [[ConcatenatingAudioSource alloc] initWithId:data[@"id"]
                                               audioSources:[self decodeAudioSources:data[@"children"]]
                                               shuffleOrder:(NSArray<NSNumber *> *)data[@"shuffleOrder"]
                                                lazyLoading:(NSNumber *)data[@"useLazyPreparation"]];
    } else if ([@"clipping" isEqualToString:type]) {
        return [[ClippingAudioSource alloc] initWithId:data[@"id"]
                                           audioSource:(UriAudioSource *)[self decodeAudioSource:data[@"child"]]
                                                 start:data[@"start"]
                                                   end:data[@"end"]];
    } else if ([@"looping" isEqualToString:type]) {
        NSMutableArray *childSources = [NSMutableArray new];
        int count = [data[@"count"] intValue];
        for (int i = 0; i < count; i++) {
            [childSources addObject:[self decodeAudioSource:data[@"child"]]];
        }
        return [[LoopingAudioSource alloc] initWithId:data[@"id"] audioSources:childSources];
    } else {
        return nil;
    }
}

- (void)enqueueFrom:(int)index {
    //NSLog(@"### enqueueFrom:%d", index);
    _index = index;

    // Update the queue while keeping the currently playing item untouched.

    /* NSLog(@"before reorder: _player.items.count: ", _player.items.count); */
    /* [self dumpQueue]; */

    // First, remove all _player items except for the currently playing one (if any).
    IndexedPlayerItem *oldItem = (IndexedPlayerItem *)_player.currentItem;
    IndexedPlayerItem *existingItem = nil;
    IndexedPlayerItem *newItem = _indexedAudioSources.count > 0 ? _indexedAudioSources[_index].playerItem : nil;
    NSArray *oldPlayerItems = [NSArray arrayWithArray:_player.items];
    // In the first pass, preserve the old and new items.
    // TODO: preserve as much of the treadmill as possible
    for (int i = 0; i < oldPlayerItems.count; i++) {
        if (oldPlayerItems[i] == newItem) {
            // Preserve and tag new item if it is already in the queue.
            existingItem = oldPlayerItems[i];
            //NSLog(@"Preserving existing item %d", [self indexForItem:existingItem]);
        } else if (oldPlayerItems[i] == oldItem) {
            //NSLog(@"Preserving old item %d", [self indexForItem:oldItem]);
            // Temporarily preserve old item, just to avoid jumping to
            // intermediate queue positions unnecessarily. We only want to jump
            // once to _index.
        } else {
            //NSLog(@"Removing item %d", [self indexForItem:oldPlayerItems[i]]);
            [_player removeItem:oldPlayerItems[i]];
        }
    }
    // In the second pass, remove the old item (if different from new item).
    if (oldItem && newItem != oldItem) {
        //NSLog(@"removing old item %d", [self indexForItem:oldItem]);
        [_player removeItem:oldItem];
    }

    /* NSLog(@"inter order: _player.items.count: ", _player.items.count); */
    /* [self dumpQueue]; */

    // Regenerate queue
    _enqueuedAll = NO;
    if (!existingItem || _loopMode != lmLoopOne) {
        _enqueuedAll = YES;
        BOOL include = NO;
        for (int i = 0; i < [_order count]; i++) {
            int si = [_order[i] intValue];
            if (si == _index) include = YES;
            if (include && _indexedAudioSources[si].playerItem != existingItem) {
                if (_indexedAudioSources[si].lazyLoading && _player.items.count >= TREADMILL_SIZE) {
                    // Enqueue up until the first lazy item that does not fit on the treadmill.
                    _enqueuedAll = NO;
                    break;
                }
                //NSLog(@"inserting item %d", si);
                [_player insertItem:_indexedAudioSources[si].playerItem afterItem:nil];
                if (_loopMode == lmLoopOne) {
                    // We only want one item in the queue.
                    break;
                }
            }
        }
    }

    // Add next loop item if we're looping
    if (_order.count > 0) {
        if (_loopMode == lmLoopAll && _enqueuedAll) {
            int si = [_order[0] intValue];
            //NSLog(@"### add loop item:%d", si);
            if (!_indexedAudioSources[si].playerItem2) {
                [_indexedAudioSources[si] preparePlayerItem2];
                [self addItemObservers:_indexedAudioSources[si].playerItem2];
            }
            [_player insertItem:_indexedAudioSources[si].playerItem2 afterItem:nil];
        } else if (_loopMode == lmLoopOne) {
            //NSLog(@"### add loop item:%d", _index);
            if (!_indexedAudioSources[_index].playerItem2) {
                [_indexedAudioSources[_index] preparePlayerItem2];
                [self addItemObservers:_indexedAudioSources[_index].playerItem2];
            }
            [_player insertItem:_indexedAudioSources[_index].playerItem2 afterItem:nil];
        }
    }

    /* NSLog(@"after reorder: _player.items.count: ", _player.items.count); */
    /* [self dumpQueue]; */

    if (_processingState != psLoading && oldItem != newItem) {
        // || !_player.currentItem.playbackLikelyToKeepUp;
        if (_player.currentItem.playbackBufferEmpty) {
            [self enterBuffering:@"enqueueFrom playbackBufferEmpty"];
        } else {
            [self leaveBuffering:@"enqueueFrom !playbackBufferEmpty"];
        }
        [self updatePosition];
    }

    [self updateEndAction];
}

- (void)updatePosition {
    _updatePosition = [self getCurrentPosition];
    _updateTime = (long long)([[NSDate date] timeIntervalSince1970] * 1000.0);
}

- (void)load:(NSDictionary *)source initialPosition:(CMTime)initialPosition initialIndex:(NSNumber *)initialIndex result:(FlutterResult)result {
    if (_playing) {
        [_player pause];
    }
    if (_processingState == psLoading) {
        [self abortExistingConnection:NO];
    }
    _loadResult = result;
    _processingState = psLoading;
    _index = (initialIndex != (id)[NSNull null]) ? [initialIndex intValue] : 0;
    _errorCode = (NSNumber *)[NSNull null];
    _errorMessage = (NSString *)[NSNull null];
    // Remove previous observers
    if (_indexedAudioSources) {
        for (int i = 0; i < [_indexedAudioSources count]; i++) {
            [self removeItemObservers:_indexedAudioSources[i].playerItem];
            if (_indexedAudioSources[i].playerItem2) {
                [self removeItemObservers:_indexedAudioSources[i].playerItem2];
            }
        }
    }
    // Decode audio source
    if (_audioSource && [@"clipping" isEqualToString:source[@"type"]]) {
        // Check if we're clipping an audio source that was previously loaded.
        UriAudioSource *child = nil;
        if ([_audioSource isKindOfClass:[ClippingAudioSource class]]) {
            ClippingAudioSource *clipper = (ClippingAudioSource *)_audioSource;
            child = clipper.audioSource;
        } else if ([_audioSource isKindOfClass:[UriAudioSource class]]) {
            child = (UriAudioSource *)_audioSource;
        }
        NSString *type = source[@"child"][@"type"];
        NSString *uri = nil;
        if ([@"progressive" isEqualToString:type] || [@"dash" isEqualToString:type] || [@"hls" isEqualToString:type]) {
            uri = source[@"child"][@"uri"];
        }
        if (child && uri && [child.uri isEqualToString:uri]) {
            ClippingAudioSource *clipper =
                [[ClippingAudioSource alloc] initWithId:source[@"id"]
                                            audioSource:child
                                                  start:source[@"start"]
                                                    end:source[@"end"]];
            clipper.playerItem.audioSource = clipper;
            if (clipper.playerItem2) {
                clipper.playerItem2.audioSource = clipper;
            }
            _audioSource = clipper;
        } else {
            _audioSource = [self decodeAudioSource:source];
        }
    } else {
        _audioSource = [self decodeAudioSource:source];
    }
    _indexedAudioSources = [[NSMutableArray alloc] init];
    [_audioSource buildSequence:_indexedAudioSources treeIndex:0];
    for (int i = 0; i < [_indexedAudioSources count]; i++) {
        IndexedAudioSource *source = _indexedAudioSources[i];
        [self addItemObservers:source.playerItem];
        source.playerItem.audioSource = source;
    }
    [self updatePosition];
    [self updateOrder];
    // Set up an empty player
    if (!_player) {
        _player = [[AVQueuePlayer alloc] initWithItems:@[]];
        if (@available(macOS 10.12, iOS 10.0, *)) {
            _player.automaticallyWaitsToMinimizeStalling = _automaticallyWaitsToMinimizeStalling;
            // TODO: Remove these observers in dispose.
            [_player addObserver:self
                      forKeyPath:@"timeControlStatus"
                         options:NSKeyValueObservingOptionNew
                         context:nil];
        }
        if (@available(macOS 10.11, iOS 6.0, *)) {
            _player.allowsExternalPlayback = _allowsExternalPlayback;
        }
        [_player addObserver:self
                  forKeyPath:@"currentItem"
                     options:NSKeyValueObservingOptionNew
                     context:nil];
        // TODO: learn about the different ways to define weakSelf.
        //__weak __typeof__(self) weakSelf = self;
        //typeof(self) __weak weakSelf = self;
        __unsafe_unretained typeof(self) weakSelf = self;
        if (@available(macOS 10.12, iOS 10.0, *)) {}
        else {
            _timeObserver = [_player addPeriodicTimeObserverForInterval:CMTimeMake(200, 1000)
                                                                  queue:nil
                                                             usingBlock:^(CMTime time) {
                                                                 [weakSelf checkForDiscontinuity];
                                                             }
            ];
        }
    }
    // Initialise the AVQueuePlayer with items.
    [self enqueueFrom:_index];
    // Notify each IndexedAudioSource that it's been attached to the player.
    for (int i = 0; i < [_indexedAudioSources count]; i++) {
        [_indexedAudioSources[i] attach:_player initialPos:(i == _index ? initialPosition : kCMTimeInvalid)];
    }

    if (_playing) {
        _player.rate = _speed;
    }
    [_player setVolume:_volume];
    [self broadcastPlaybackEvent];

    if (_loadResult && (_indexedAudioSources.count == 0 || !_player.currentItem ||
            _player.currentItem.status == AVPlayerItemStatusReadyToPlay)) {
        _processingState = psReady;
        _loadResult(@{@"duration": @([self getDurationMicroseconds])});
        _loadResult = nil;
    } else {
        // We send result after the playerItem is ready in observeValueForKeyPath.
    }
    /* NSLog(@"load:"); */
    /* for (int i = 0; i < [_indexedAudioSources count]; i++) { */
    /*     NSLog(@"- %@", _indexedAudioSources[i].sourceId); */
    /* } */
}

- (void)updateOrder {
    _orderInv = [NSMutableArray arrayWithCapacity:[_indexedAudioSources count]];
    for (int i = 0; i < [_indexedAudioSources count]; i++) {
        [_orderInv addObject:@(0)];
    }
    if (_shuffleModeEnabled) {
        _order = [_audioSource getShuffleIndices];
    } else {
        NSMutableArray *order = [[NSMutableArray alloc] init];
        for (int i = 0; i < [_indexedAudioSources count]; i++) {
            [order addObject:@(i)];
        }
        _order = order;
    }
    for (int i = 0; i < [_indexedAudioSources count]; i++) {
        _orderInv[[_order[i] intValue]] = @(i);
    }
}

- (void)onItemStalled:(NSNotification *)notification {
    //IndexedPlayerItem *playerItem = (IndexedPlayerItem *)notification.object;
    //NSLog(@"onItemStalled");
}

- (void)onFailToComplete:(NSNotification *)notification {
    //IndexedPlayerItem *playerItem = (IndexedPlayerItem *)notification.object;
    //NSLog(@"onFailToComplete");
}

- (void)onComplete:(NSNotification *)notification {
    //NSLog(@"onComplete");

    IndexedPlayerItem *endedPlayerItem = (IndexedPlayerItem *)notification.object;
    IndexedAudioSource *endedSource = endedPlayerItem.audioSource;

    if (_loopMode == lmLoopOne) {
        [endedSource seek:kCMTimeZero];
        _justAdvanced = YES;
    } else if (_loopMode == lmLoopAll) {
        [endedSource seek:kCMTimeZero];
        _index = [_order[([_orderInv[_index] intValue] + 1) % _order.count] intValue];
        [self broadcastPlaybackEvent];
        _justAdvanced = YES;
    } else if ([_orderInv[_index] intValue] + 1 < [_order count]) {
        [endedSource seek:kCMTimeZero];
        _index = [_order[([_orderInv[_index] intValue] + 1)] intValue];
        [self updateEndAction];
        [self broadcastPlaybackEvent];
        _justAdvanced = YES;
    } else {
        // reached end of playlist
        [self complete];
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSString *,id> *)change
                       context:(void *)context {

    if ([keyPath isEqualToString:@"status"]) {
        IndexedPlayerItem *playerItem = (IndexedPlayerItem *)object;
        AVPlayerItemStatus status = AVPlayerItemStatusUnknown;
        NSNumber *statusNumber = change[NSKeyValueChangeNewKey];
        if ([statusNumber isKindOfClass:[NSNumber class]]) {
            status = statusNumber.intValue;
        }
        [playerItem.audioSource onStatusChanged:status];
        switch (status) {
            case AVPlayerItemStatusReadyToPlay: {
                [self applyAudioProcessingToPlayerItem:playerItem];
                if (playerItem != _player.currentItem) return;
                // Detect buffering in different ways depending on whether we're playing
                if (_playing) {
                    if (@available(macOS 10.12, iOS 10.0, *)) {
                        if (_player.timeControlStatus == AVPlayerTimeControlStatusWaitingToPlayAtSpecifiedRate) {
                            [self enterBuffering:@"ready to play: playing, waitingToPlay"];
                        } else {
                            [self leaveBuffering:@"ready to play: playing, !waitingToPlay"];
                        }
                        [self updatePosition];
                    } else {
                        // If this happens when we're playing, check whether buffer is confirmed
                        if (_bufferUnconfirmed && !_player.currentItem.playbackBufferFull) {
                            // Stay in bufering - XXX Test
                            [self enterBuffering:@"ready to play: playing, bufferUnconfirmed && !playbackBufferFull"];
                        } else {
                            if (_player.currentItem.playbackBufferEmpty) {
                                // !_player.currentItem.playbackLikelyToKeepUp;
                                [self enterBuffering:@"ready to play: playing, playbackBufferEmpty"];
                            } else {
                                [self leaveBuffering:@"ready to play: playing, !playbackBufferEmpty"];
                            }
                            [self updatePosition];
                        }
                    }
                } else {
                    if (_player.currentItem.playbackBufferEmpty) {
                        [self enterBuffering:@"ready to play: !playing, playbackBufferEmpty"];
                        // || !_player.currentItem.playbackLikelyToKeepUp;
                    } else {
                        [self leaveBuffering:@"ready to play: !playing, !playbackBufferEmpty"];
                    }
                    [self updatePosition];
                }
                [self broadcastPlaybackEvent];
                if (_loadResult) {
                    _loadResult(@{@"duration": @([self getDurationMicroseconds])});
                    _loadResult = nil;
                }
                break;
            }
            case AVPlayerItemStatusFailed: {
                //NSLog(@"AVPlayerItemStatusFailed on item [%d]", [self indexForItem:playerItem]);
                if (playerItem == _player.currentItem) {
                    [self sendErrorForItem:playerItem];
                }
                break;
            }
            case AVPlayerItemStatusUnknown:
                break;
        }
    } else if ([keyPath isEqualToString:@"playbackBufferEmpty"] || [keyPath isEqualToString:@"playbackBufferFull"]) {
        // Use these values to detect buffering.
        IndexedPlayerItem *playerItem = (IndexedPlayerItem *)object;
        if (playerItem != _player.currentItem) return;
        // If there's a seek in progress, these values are unreliable
        if (CMTIME_IS_VALID(_seekPos)) return;
        // Detect buffering in different ways depending on whether we're playing
        if (_playing) {
            if (@available(macOS 10.12, iOS 10.0, *)) {
                // We handle this with timeControlStatus instead.
            } else {
                if (_bufferUnconfirmed && playerItem.playbackBufferFull) {
                    _bufferUnconfirmed = NO;
                    [self leaveBuffering:@"playing, _bufferUnconfirmed && playbackBufferFull"];
                    [self updatePosition];
                    //NSLog(@"Buffering confirmed! leaving buffering");
                    [self broadcastPlaybackEvent];
                }
            }
        } else {
            if (playerItem.playbackBufferEmpty) {
                [self enterBuffering:@"!playing, playbackBufferEmpty"];
                [self updatePosition];
                [self broadcastPlaybackEvent];
            } else if (!playerItem.playbackBufferEmpty || playerItem.playbackBufferFull) {
                [self leaveBuffering:@"!playing, !playbackBufferEmpty || playbackBufferFull"];
                [self updatePosition];
                [self broadcastPlaybackEvent];
            }
        }
    /* } else if ([keyPath isEqualToString:@"playbackLikelyToKeepUp"]) { */
    } else if ([keyPath isEqualToString:@"timeControlStatus"]) {
        if (@available(macOS 10.12, iOS 10.0, *)) {
            AVPlayerTimeControlStatus status = AVPlayerTimeControlStatusPaused;
            NSNumber *statusNumber = change[NSKeyValueChangeNewKey];
            if ([statusNumber isKindOfClass:[NSNumber class]]) {
                status = statusNumber.intValue;
            }
            switch (status) {
                case AVPlayerTimeControlStatusPaused:
                    //NSLog(@"AVPlayerTimeControlStatusPaused");
                    break;
                case AVPlayerTimeControlStatusWaitingToPlayAtSpecifiedRate:
                    //NSLog(@"AVPlayerTimeControlStatusWaitingToPlayAtSpecifiedRate");
                    if (_processingState != psCompleted) {
                        [self enterBuffering:@"timeControlStatus"];
                        [self updatePosition];
                        [self broadcastPlaybackEvent];
                    } else {
                        //NSLog(@"Ignoring wait signal because we reached the end");
                    }
                    break;
                case AVPlayerTimeControlStatusPlaying:
                    [self leaveBuffering:@"timeControlStatus"];
                    [self updatePosition];
                    [self broadcastPlaybackEvent];
                    break;
            }
        }
    } else if ([keyPath isEqualToString:@"currentItem"] && _player.currentItem) {
        //NSLog(@"currentItem -> [%d]", [self indexForItem:_player.currentItem]);
        IndexedPlayerItem *playerItem = (IndexedPlayerItem *)change[NSKeyValueChangeNewKey];
        [self applyAudioProcessingToPlayerItem:playerItem];
        //IndexedPlayerItem *oldPlayerItem = (IndexedPlayerItem *)change[NSKeyValueChangeOldKey];
        if (playerItem.status == AVPlayerItemStatusFailed) {
            [self sendErrorForItem:playerItem];
            return;
        } else {
            int expectedIndex = [self indexForItem:playerItem];
            if (_index != expectedIndex) {
                // AVQueuePlayer will sometimes skip over error items without
                // notifying this observer.
                //NSLog(@"Queue change detected. Adjusting index from %d -> %d", _index, expectedIndex);
                _index = expectedIndex;
                [self updateEndAction];
                [self broadcastPlaybackEvent];
            }
        }
        //NSLog(@"currentItem changed. _index=%d", _index);
        _bufferUnconfirmed = YES;
        // If we've skipped or transitioned to a new item and we're not
        // currently in the middle of a seek
        /* if (CMTIME_IS_INVALID(_seekPos) && playerItem.status == AVPlayerItemStatusReadyToPlay) { */
        /*     [self updatePosition]; */
        /*     IndexedAudioSource *source = playerItem.audioSource; */
        /*     // We should already be at position zero but for */
        /*     // ClippingAudioSource it might be off by some milliseconds so we */
        /*     // consider anything <= 100 as close enough. */
        /*     if ((int)(1000 * CMTimeGetSeconds(source.position)) > 100) { */
        /*         NSLog(@"On currentItem change, seeking back to zero"); */
        /*         BOOL shouldResumePlayback = NO; */
        /*         AVPlayerActionAtItemEnd originalEndAction = _player.actionAtItemEnd; */
        /*         if (_playing && CMTimeGetSeconds(CMTimeSubtract(source.position, source.duration)) >= 0) { */
        /*             NSLog(@"Need to pause while rewinding because we're at the end"); */
        /*             shouldResumePlayback = YES; */
        /*             _player.actionAtItemEnd = AVPlayerActionAtItemEndPause; */
        /*             [_player pause]; */
        /*         } */
        /*         [self enterBuffering:@"currentItem changed, seeking"]; */
        /*         [self updatePosition]; */
        /*         [self broadcastPlaybackEvent]; */
        /*         __weak __typeof__(self) weakSelf = self; */
        /*         [source seek:kCMTimeZero completionHandler:^(BOOL finished) { */
        /*             [weakSelf leaveBuffering:@"currentItem changed, finished seek"]; */
        /*             [weakSelf updatePosition]; */
        /*             [weakSelf broadcastPlaybackEvent]; */
        /*             if (shouldResumePlayback) { */
        /*                 weakSelf.player.actionAtItemEnd = originalEndAction; */
        /*                 // TODO: This logic is almost duplicated in seek. See if we can reuse this code. */
        /*                 weakSelf.player.rate = weakSelf.speed; */
        /*             } */
        /*         }]; */
        /*     } else { */
        /*         // Already at zero, no need to seek. */
        /*     } */
        /* } */

        if (_justAdvanced) {
            IndexedAudioSource *audioSource = playerItem.audioSource;
            if (_loopMode == lmLoopOne) {
                [audioSource flip];
                [self enqueueFrom:_index];
            } else if (_loopMode == lmLoopAll) {
                if (_index == [_order[0] intValue] && playerItem == audioSource.playerItem2) {
                    [audioSource flip];
                    [self enqueueFrom:_index];
                } else if (!_enqueuedAll) {
                    [self enqueueFrom:_index];
                } else {
                    [self updateEndAction];
                }
            } else if (!_enqueuedAll) {
                [self enqueueFrom:_index];
            }
            _justAdvanced = NO;
        }
    } else if ([keyPath isEqualToString:@"loadedTimeRanges"]) {
        IndexedPlayerItem *playerItem = (IndexedPlayerItem *)object;
        if (playerItem != _player.currentItem) return;
        int pos = [self getBufferedPosition];
        if (pos != _bufferedPosition) {
            _bufferedPosition = pos;
            [self broadcastPlaybackEvent];
        }
    }
}

- (void)sendErrorForItem:(IndexedPlayerItem *)playerItem {
    [self sendError:@((int)playerItem.error.code) errorMessage:playerItem.error.localizedDescription playerItem:playerItem switchToIdle:YES];
    [_player removeAllItems];
}

- (void)sendError:(NSNumber *)errorCode errorMessage:(NSString *)errorMessage playerItem:(IndexedPlayerItem *)playerItem switchToIdle:(BOOL)switchToIdle {
    //NSLog(@"sendError (%@) %@", errorCode, errorMessage);
    FlutterError *flutterError = [FlutterError errorWithCode:[NSString stringWithFormat:@"%@", errorCode]
                                                     message:errorMessage
                                                     details:playerItem != nil ? @{@"index": @([self indexForItem:playerItem])} : nil];
    [_eventChannel sendEvent:flutterError];
    _errorCode = errorCode;
    _errorMessage = errorMessage;
    if (switchToIdle) {
        _processingState = psIdle;
    }
    [self broadcastPlaybackEvent];
    if (_loadResult && playerItem == _player.currentItem) {
        _loadResult(flutterError);
        _loadResult = nil;
    }
}

- (void)abortExistingConnection:(BOOL)switchToIdle {
    [self sendError:@(ERROR_ABORT) errorMessage:@"Connection aborted" playerItem:nil switchToIdle:switchToIdle];
}

- (int)indexForItem:(IndexedPlayerItem *)playerItem {
    for (int i = 0; i < _indexedAudioSources.count; i++) {
        if (_indexedAudioSources[i].playerItem == playerItem || _indexedAudioSources[i].playerItem2 == playerItem) {
            return i;
        }
    }
    return -1;
}

- (void)play {
    [self play:nil];
}

- (void)play:(FlutterResult)result {
    if (_playing) {
        if (result) {
            result(@{});
        }
        return;
    }
    if (result) {
        if (_playResult) {
            //NSLog(@"INTERRUPTING PLAY");
            _playResult(@{});
        }
        _playResult = result;
    }
    _playing = YES;
    _player.rate = _speed;
    [self updatePosition];
    if (@available(macOS 10.12, iOS 10.0, *)) {}
    else {
        if (_bufferUnconfirmed && !_player.currentItem.playbackBufferFull) {
            [self enterBuffering:@"play, _bufferUnconfirmed && !playbackBufferFull"];
            [self broadcastPlaybackEvent];
        }
    }
}

- (void)pause {
    if (!_playing) return;
    _playing = NO;
    [_player pause];
    [self updatePosition];
    [self broadcastPlaybackEvent];
    if (_playResult) {
        //NSLog(@"PLAY FINISHED DUE TO PAUSE");
        _playResult(@{});
        _playResult = nil;
    }
}

- (void)complete {
    [self updatePosition];
    _processingState = psCompleted;
    [self broadcastPlaybackEvent];
    if (_playResult) {
        //NSLog(@"PLAY FINISHED DUE TO COMPLETE");
        _playResult(@{});
        _playResult = nil;
    }
}

- (void)setVolume:(float)volume {
    _volume = volume;
    if (_player) {
        [_player setVolume:volume];
    }
}

- (void)setSpeed:(float)speed {
    // NOTE: We ideally should check _player.currentItem.canPlaySlowForward and
    // canPlayFastForward, but these properties are unreliable and the official
    // documentation is unclear and contradictory.
    //
    // Source #1:
    // https://developer.apple.com/documentation/avfoundation/avplayer/1388846-rate?language=objc
    //
    //     Rates other than 0.0 and 1.0 can be used if the associated player
    //     item returns YES for the AVPlayerItem properties canPlaySlowForward
    //     or canPlayFastForward.
    //
    // Source #2:
    // https://developer.apple.com/library/archive/qa/qa1772/_index.html
    //
    //     An AVPlayerItem whose status property equals
    //     AVPlayerItemStatusReadyToPlay can be played at rates between 1.0 and
    //     2.0, inclusive, even if AVPlayerItem.canPlayFastForward is NO.
    //     AVPlayerItem.canPlayFastForward indicates whether the item can be
    //     played at rates greater than 2.0.
    //
    // But in practice, it appears that even if AVPlayerItem.canPlayFastForward
    // is NO, rates greater than 2.0 still work sometimes.
    //
    // So for now, we just let the app pass in any speed and hope for the best.
    // There is no way to reliably query whether the requested speed is
    // supported.
    _speed = speed;
    if (_playing && _player) {
        _player.rate = speed;
    }
    [self updatePosition];
}

- (void)setLoopMode:(int)loopMode {
    if (loopMode == _loopMode) return;
    _loopMode = loopMode;
    [self enqueueFrom:_index];
}

- (void)updateEndAction {
    // Should be called in the following situations:
    // - when the audio source changes
    // - when _index changes
    // - when the loop mode changes.
    // - when the shuffle order changes. (TODO)
    // - when the shuffle mode changes.
    if (!_player) return;
    if (_audioSource && (_loopMode != lmLoopOff || ([_order count] > 0 && [_orderInv[_index] intValue] + 1 < [_order count]))) {
        _player.actionAtItemEnd = AVPlayerActionAtItemEndAdvance;
    } else {
        _player.actionAtItemEnd = AVPlayerActionAtItemEndPause; // AVPlayerActionAtItemEndNone
    }
}

- (void)setShuffleModeEnabled:(BOOL)shuffleModeEnabled {
    //NSLog(@"setShuffleModeEnabled: %d", shuffleModeEnabled);
    _shuffleModeEnabled = shuffleModeEnabled;
    if (!_audioSource) return;

    [self updateOrder];

    [self enqueueFrom:_index];
}

- (void)setShuffleOrder:(NSDictionary *)dict {
    if (!_audioSource) return;

    [_audioSource decodeShuffleOrder:dict];

    [self updateOrder];

    [self enqueueFrom:_index];
}

- (void)dumpQueue {
    for (int i = 0; i < _player.items.count; i++) {
        IndexedPlayerItem *playerItem = (IndexedPlayerItem *)_player.items[i];
        int j = [self indexForItem:playerItem];
        NSLog(@"- %d", j);
    }
}

- (void)setAutomaticallyWaitsToMinimizeStalling:(bool)automaticallyWaitsToMinimizeStalling {
    _automaticallyWaitsToMinimizeStalling = automaticallyWaitsToMinimizeStalling;
    if (@available(macOS 10.12, iOS 10.0, *)) {
        if(_player) {
            _player.automaticallyWaitsToMinimizeStalling = automaticallyWaitsToMinimizeStalling;
        }
    }
}

- (void)setCanUseNetworkResourcesForLiveStreamingWhilePaused:(BOOL)enabled {
    _loadControl.canUseNetworkResourcesForLiveStreamingWhilePaused = enabled;
    if (!_indexedAudioSources) return;
    for (int i = 0; i < [_indexedAudioSources count]; i++) {
        [_indexedAudioSources[i] applyCanUseNetworkResourcesForLiveStreamingWhilePaused];
    }
}

- (void)setPreferredPeakBitRate:(NSNumber *)preferredPeakBitRate {
    _loadControl.preferredPeakBitRate = preferredPeakBitRate;
    if (!_indexedAudioSources) return;
    for (int i = 0; i < [_indexedAudioSources count]; i++) {
        [_indexedAudioSources[i] applyPreferredPeakBitRate];
    }
}

- (void)setAllowsExternalPlayback:(BOOL)allowsExternalPlayback {
    _allowsExternalPlayback = allowsExternalPlayback;
    if (@available(macOS 10.11, iOS 6.0, *)) {
        if (_player) {
            _player.allowsExternalPlayback = allowsExternalPlayback;
        }
    }
}

- (void)seek:(CMTime)position index:(NSNumber *)newIndex completionHandler:(void (^)(BOOL))completionHandler {
    if (_processingState == psIdle || _processingState == psLoading) {
        if (completionHandler) {
            completionHandler(NO);
        }
        return;
    }
    int index = _index;
    if (newIndex != (id)[NSNull null]) {
        index = [newIndex intValue];
    }
    if (index != _index) {
        // Jump to a new item
        /* if (_playing && index == _index + 1) { */
        /*     // Special case for jumping to the very next item */
        /*     NSLog(@"seek to next item: %d -> %d", _index, index); */
        /*     [_indexedAudioSources[_index] seek:kCMTimeZero]; */
        /*     _index = index; */
        /*     [_player advanceToNextItem]; */
        /*     [self broadcastPlaybackEvent]; */
        /* } else */
        {
            // Jump to a distant item
            //NSLog(@"seek# jump to distant item: %d -> %d", _index, index);
            if (_playing) {
                [_player pause];
            }
            [_indexedAudioSources[_index] seek:kCMTimeZero];
            // The "currentItem" key observer will respect that a seek is already in progress
            _seekPos = position;
            [self updatePosition];
            [self enqueueFrom:index];
            IndexedAudioSource *source = _indexedAudioSources[_index];
            if (abs((int)(1000 * CMTimeGetSeconds(CMTimeSubtract(source.position, position)))) > 100) {
                [self enterBuffering:@"seek to index"];
                [self updatePosition];
                [self broadcastPlaybackEvent];
                [source seek:position completionHandler:^(BOOL finished) {
                    if (@available(macOS 10.12, iOS 10.0, *)) {
                        if (self->_playing) {
                            // Handled by timeControlStatus
                        } else {
                            if (self->_bufferUnconfirmed && !self->_player.currentItem.playbackBufferFull) {
                                // Stay in buffering
                            } else if (source.playerItem.status == AVPlayerItemStatusReadyToPlay) {
                                [self leaveBuffering:@"seek to index finished, (!bufferUnconfirmed || playbackBufferFull) && ready to play"];
                                [self updatePosition];
                                [self broadcastPlaybackEvent];
                            }
                        }
                    } else {
                        if (self->_bufferUnconfirmed && !self->_player.currentItem.playbackBufferFull) {
                            // Stay in buffering
                        } else if (source.playerItem.status == AVPlayerItemStatusReadyToPlay) {
                            [self leaveBuffering:@"seek to index finished, (!bufferUnconfirmed || playbackBufferFull) && ready to play"];
                            [self updatePosition];
                            [self broadcastPlaybackEvent];
                        }
                    }
                    if (self->_playing) {
                        self->_player.rate = self->_speed;
                    }
                    self->_seekPos = kCMTimeInvalid;
                    [self broadcastPlaybackEvent];
                    if (completionHandler) {
                        completionHandler(finished);
                    }
                }];
            } else {
                _seekPos = kCMTimeInvalid;
                if (_playing) {
                    if (@available(iOS 10.0, *)) {
                        // NOTE: Re-enable this line only after figuring out
                        // how to detect buffering when buffered audio is not
                        // immediately available.
                        //[_player playImmediatelyAtRate:_speed];
                        _player.rate = _speed;
                    } else {
                        _player.rate = _speed;
                    }
                }
                [self broadcastPlaybackEvent];
                completionHandler(YES);
            }
        }
    } else {
        // Seek within an item
        if (_playing) {
            [_player pause];
        }
        _seekPos = position;
        //NSLog(@"seek. enter buffering. pos = %d", (int)(1000*CMTimeGetSeconds(_indexedAudioSources[_index].position)));
        // TODO: Move this into a separate method so it can also
        // be used in skip.
        [self enterBuffering:@"seek"];
        [self updatePosition];
        [self broadcastPlaybackEvent];
        [_indexedAudioSources[_index] seek:position completionHandler:^(BOOL finished) {
            [self updatePosition];
            if (self->_playing) {
                // If playing, buffering will be detected either by:
                // 1. checkForDiscontinuity
                // 2. timeControlStatus
                if (@available(iOS 10.0, *)) {
                    // NOTE: Re-enable this line only after figuring out how to
                    // detect buffering when buffered audio is not immediately
                    // available.
                    //[_player playImmediatelyAtRate:_speed];
                    self->_player.rate = self->_speed;
                } else {
                    self->_player.rate = self->_speed;
                }
            } else {
                // If not playing, there is no reliable way to detect
                // when buffering has completed, so we use
                // !playbackBufferEmpty. Although this always seems to
                // be full even right after a seek.
                if (self->_player.currentItem.playbackBufferEmpty) {
                    [self enterBuffering:@"seek finished, playbackBufferEmpty"];
                } else {
                    [self leaveBuffering:@"seek finished, !playbackBufferEmpty"];
                }
                [self updatePosition];
                if (self->_processingState != psBuffering) {
                    [self broadcastPlaybackEvent];
                }
            }
            self->_seekPos = kCMTimeInvalid;
            [self broadcastPlaybackEvent];
            if (completionHandler) {
                completionHandler(finished);
            }
        }];
    }
}

- (void)dispose:(BOOL)calledFromDealloc {
    if (!_player) return;
    if (_processingState != psIdle) {
        [_player pause];

        [self updatePosition];
        if (!calledFromDealloc) {
            [self broadcastPlaybackEvent];
        }
        if (_playResult) {
            //NSLog(@"PLAY FINISHED DUE TO STOP");
            _playResult(@{});
            _playResult = nil;
        }

        _processingState = psIdle;
        // If used just before destroying the current FlutterEngine, this will result in:
        // NSInternalInconsistencyException: 'Sending a message before the FlutterEngine has been run.'
        //[self broadcastPlaybackEvent];
    }
    if (_timeObserver) {
        [_player removeTimeObserver:_timeObserver];
        _timeObserver = 0;
    }
    if (_indexedAudioSources) {
        for (int i = 0; i < [_indexedAudioSources count]; i++) {
            [self removeItemObservers:_indexedAudioSources[i].playerItem];
            if (_indexedAudioSources[i].playerItem2) {
                [self removeItemObservers:_indexedAudioSources[i].playerItem2];
            }
        }
        _indexedAudioSources = nil;
    }
    _audioSource = nil;
    if (_player) {
        [_player removeObserver:self forKeyPath:@"currentItem"];
        if (@available(macOS 10.12, iOS 10.0, *)) {
            [_player removeObserver:self forKeyPath:@"timeControlStatus"];
        }
        _player = nil;
    }
    // Untested:
    [_eventChannel dispose];
    [_dataEventChannel dispose];
    [_methodChannel setMethodCallHandler:nil];
}

@end
