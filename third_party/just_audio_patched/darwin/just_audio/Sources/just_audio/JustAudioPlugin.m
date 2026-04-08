#import "./include/just_audio/JustAudioPlugin.h"
#import "./include/just_audio/AudioPlayer.h"
#import <AVFoundation/AVFoundation.h>
#include <TargetConditionals.h>

@implementation JustAudioPlugin {
    NSObject<FlutterPluginRegistrar>* _registrar;
    NSMutableDictionary<NSString *, AudioPlayer *> *_players;
    FlutterMethodChannel *_bassChannel;
    BOOL _bassBoostEnabled;
    float _bassBoostAmount;
}

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
    FlutterMethodChannel* channel = [FlutterMethodChannel
        methodChannelWithName:@"com.ryanheise.just_audio.methods"
              binaryMessenger:[registrar messenger]];
    JustAudioPlugin* instance = [[JustAudioPlugin alloc] initWithRegistrar:registrar];
    [registrar addMethodCallDelegate:instance channel:channel];
}

- (instancetype)initWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
    self = [super init];
    NSAssert(self, @"super init cannot be nil");
    _registrar = registrar;
    _players = [[NSMutableDictionary alloc] init];
    _bassBoostEnabled = NO;
    _bassBoostAmount = 0.95f;
    _bassChannel = [FlutterMethodChannel
        methodChannelWithName:@"com.vm.music.beta/ios_bass_boost"
              binaryMessenger:[registrar messenger]];
    __weak __typeof__(self) weakSelf = self;
    [_bassChannel setMethodCallHandler:^(FlutterMethodCall* call, FlutterResult result) {
        [weakSelf handleBassMethodCall:call result:result];
    }];
    return self;
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
    //NSLog(@"plugin method: %@", call.method);
    if ([@"init" isEqualToString:call.method]) {
        NSDictionary *request = (NSDictionary *)call.arguments;
        NSString *playerId = (NSString *)request[@"id"];
        NSDictionary *loadConfiguration = (NSDictionary *)request[@"audioLoadConfiguration"];
        BOOL useLazyPreparation = [((NSNumber *)request[@"useLazyPreparation"]) boolValue];
        if ([_players objectForKey:playerId] != nil) {
            FlutterError *flutterError = [FlutterError errorWithCode:@"error" message:@"Platform player already exists" details:nil];
            result(flutterError);
        } else {
            AudioPlayer* player = [[AudioPlayer alloc] initWithRegistrar:_registrar playerId:playerId loadConfiguration:loadConfiguration useLazyPreparation:useLazyPreparation];
            [player setBassBoostEnabled:_bassBoostEnabled amount:_bassBoostAmount];
            [_players setValue:player forKey:playerId];
            result(nil);
        }
    } else if ([@"disposePlayer" isEqualToString:call.method]) {
        NSDictionary *request = (NSDictionary *)call.arguments;
        NSString *playerId = request[@"id"];
        [_players[playerId] dispose:NO];
        [_players setValue:nil forKey:playerId];
        result(@{});
    } else if ([@"disposeAllPlayers" isEqualToString:call.method]) {
        for (NSString *playerId in _players) {
            [_players[playerId] dispose:NO];
        }
        [_players removeAllObjects];
        result(@{});
    } else {
        result(FlutterMethodNotImplemented);
    }
}

- (void)handleBassMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
    if ([@"setBassBoost" isEqualToString:call.method]) {
        NSDictionary *request = (NSDictionary *)call.arguments;
        BOOL enabled = [((NSNumber *)request[@"enabled"]) boolValue];
        NSNumber *amountNumber = (NSNumber *)request[@"amount"];
        float amount = amountNumber != (id)[NSNull null] ? [amountNumber floatValue] : _bassBoostAmount;
        if (amount < 0.0f) amount = 0.0f;
        if (amount > 2.2f) amount = 2.2f;

        _bassBoostEnabled = enabled;
        _bassBoostAmount = amount;
        for (NSString *playerId in _players) {
            [_players[playerId] setBassBoostEnabled:_bassBoostEnabled amount:_bassBoostAmount];
        }
        result(@{
            @"ok": @YES,
            @"players": @(_players.count),
        });
        return;
    }

    result(FlutterMethodNotImplemented);
}

- (void)dealloc {
    [_bassChannel setMethodCallHandler:nil];
    for (NSString *playerId in _players) {
        [_players[playerId] dispose:YES];
    }
    [_players removeAllObjects];
}

@end
