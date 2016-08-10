//
//  HysteriaPlayer.m
//
//  Created by saiday on 13/1/8.
//
//

#import "HysteriaPlayer.h"
#import <objc/runtime.h>
//#import "Spoke-Swift.h"
#if TARGET_OS_IPHONE
    #import <UIKit/UIKit.h>
    #import <AudioToolbox/AudioSession.h>
#endif

static const void *Hysteriatag = &Hysteriatag;

typedef NS_ENUM(NSInteger, PauseReason) {
    PauseReasonNone,
    PauseReasonForced,
    PauseReasonBuffering,
};

@interface HysteriaPlayer ()
{
    BOOL routeChangedWhilePlaying;
    BOOL interruptedWhilePlaying;
    BOOL isPreBuffered;
    BOOL tookAudioFocus;
    
    NSInteger prepareingItemHash;
    
    #if TARGET_OS_IPHONE
    UIBackgroundTaskIdentifier bgTaskId;
    UIBackgroundTaskIdentifier removedId;
    #endif
    
    dispatch_queue_t HBGQueue;
}


@property (nonatomic, strong, readwrite) NSArray *playerItems;
@property (nonatomic, readwrite) BOOL emptySoundPlaying;
@property (nonatomic) NSInteger lastItemIndex;

@property (nonatomic) HysteriaPlayerRepeatMode repeatMode;
@property (nonatomic) HysteriaPlayerShuffleMode shuffleMode;
@property (nonatomic) HysteriaPlayerStatus hysteriaPlayerStatus;
@property (nonatomic) PauseReason pauseReason;
@property (nonatomic, strong) NSMutableSet *playedItems;

- (void)longTimeBufferBackground;
- (void)longTimeBufferBackgroundCompleted;

@end

@implementation HysteriaPlayer


static HysteriaPlayer *sharedInstance = nil;
static dispatch_once_t onceToken;

#pragma mark -
#pragma mark ===========  Initialization, Setup  =========
#pragma mark -

+ (HysteriaPlayer *)sharedInstance {
    
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    
    return sharedInstance;
}

+ (void)showAlertWithError:(NSError *)error
{
     #if TARGET_OS_IPHONE
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Player errors"
                                                    message:[error localizedDescription]
                                                   delegate:nil
                                          cancelButtonTitle:@"OK"
                                          otherButtonTitles:nil, nil];
    [alert show];
     #endif
}

- (id)init {
    self = [super init];
    if (self) {
        HBGQueue = dispatch_queue_create("com.hysteria.queue", NULL);
        _playerItems = [NSArray array];
        
        _repeatMode = HysteriaPlayerRepeatModeOff;
        _shuffleMode = HysteriaPlayerShuffleModeOff;
        _hysteriaPlayerStatus = HysteriaPlayerStatusUnknown;
    }
    
    return self;
}

- (void)preAction
{
    tookAudioFocus = YES;
    
    [self backgroundPlayable];
    [self playEmptySound];
    [self AVAudioSessionNotification];
}

- (void)registerHandlerReadyToPlay:(ReadyToPlay)readyToPlay{}

-(void)registerHandlerFailed:(Failed)failed {}

- (void)setupSourceGetter:(SourceSyncGetter)itemBlock ItemsCount:(NSInteger)count {}

- (void)asyncSetupSourceGetter:(SourceAsyncGetter)asyncBlock ItemsCount:(NSInteger)count{}

- (void)setItemsCount:(NSInteger)count {}

- (void)playEmptySound
{
    if (self.skipEmptySoundPlaying) {
        self.audioPlayer = [[AVQueuePlayer alloc] init];
    } else {
        //play .1 sec empty sound
        NSBundle *bundle = [NSBundle bundleForClass:[self class]];
        NSString *filepath = [bundle pathForResource:@"point1sec" ofType:@"mp3"];
        if ([[NSFileManager defaultManager]fileExistsAtPath:filepath]) {
            self.emptySoundPlaying = YES;
            AVPlayerItem *playerItem = [AVPlayerItem playerItemWithURL:[NSURL fileURLWithPath:filepath]];
            self.audioPlayer = [AVQueuePlayer queuePlayerWithItems:[NSArray arrayWithObject:playerItem]];
        }
    }
}

- (void)backgroundPlayable
{
#if TARGET_OS_IPHONE
	NSString* audioCategory = AVAudioSessionCategoryPlayback;
	#ifdef SPOKEVOICE
	audioCategory = AVAudioSessionCategoryPlayAndRecord;
	#endif
	
    AVAudioSession *audioSession = [AVAudioSession sharedInstance];
    [[UIApplication sharedApplication] beginReceivingRemoteControlEvents];
    if (audioSession.category != audioCategory) {
        UIDevice *device = [UIDevice currentDevice];
        if ([device respondsToSelector:@selector(isMultitaskingSupported)]) {
            if (device.multitaskingSupported) {
                
                NSError *aError = nil;
                [audioSession setCategory:audioCategory error:&aError];
                if (aError) {
                    if (!self.disableLogs) {
                        NSLog(@"HysteriaPlayer: set category error:%@",[aError description]);
                    }
                }
                aError = nil;
                [audioSession setActive:YES error:&aError];
                if (aError) {
                    if (!self.disableLogs) {
                        NSLog(@"HysteriaPlayer: set active error:%@",[aError description]);
                    }
                }
            }
        }
    }else {
        if (!self.disableLogs) {
            NSLog(@"HysteriaPlayer: unable to register background playback");
        }
    }
    
    [self longTimeBufferBackground];
#endif
}


/*
 * Tells OS this application starts one or more long-running tasks, should end background task when completed.
 */
-(void)longTimeBufferBackground
{
#if TARGET_OS_IPHONE
    bgTaskId = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{
        [[UIApplication sharedApplication] endBackgroundTask:removedId];
        bgTaskId = UIBackgroundTaskInvalid;
    }];
    
    if (bgTaskId != UIBackgroundTaskInvalid && removedId == 0 ? YES : (removedId != UIBackgroundTaskInvalid)) {
        [[UIApplication sharedApplication] endBackgroundTask: removedId];
    }
    removedId = bgTaskId;
#endif
}

-(void)longTimeBufferBackgroundCompleted
{
#if TARGET_OS_IPHONE
    if (bgTaskId != UIBackgroundTaskInvalid && removedId != bgTaskId) {
        [[UIApplication sharedApplication] endBackgroundTask: bgTaskId];
        removedId = bgTaskId;
    }
#endif
}


#pragma mark -
#pragma mark ===========  Runtime AssociatedObject  =========
#pragma mark -

- (void)setHysteriaIndex:(AVPlayerItem *)item key:(NSNumber *)order {
    objc_setAssociatedObject(item, Hysteriatag, order, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (NSNumber *)getHysteriaIndex:(AVPlayerItem *)item {
    return objc_getAssociatedObject(item, Hysteriatag);
}

#pragma mark -
#pragma mark ===========  AVAudioSession Notifications  =========
#pragma mark -

- (void)AVAudioSessionNotification
{
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(playerItemDidReachEnd:)
                                                 name:AVPlayerItemDidPlayToEndTimeNotification
                                               object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(playerItemFailedToPlayEndTime:)
                                                 name:AVPlayerItemFailedToPlayToEndTimeNotification
                                               object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(playerItemPlaybackStall:)
                                                 name:AVPlayerItemPlaybackStalledNotification
                                               object:nil];
    
#if TARGET_OS_IPHONE
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(interruption:)
                                                 name:AVAudioSessionInterruptionNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(routeChange:)
                                                 name:AVAudioSessionRouteChangeNotification
                                               object:nil];
#endif
    
    [self.audioPlayer addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew context:nil];
    [self.audioPlayer addObserver:self forKeyPath:@"rate" options:0 context:nil];
    [self.audioPlayer addObserver:self forKeyPath:@"currentItem" options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld context:nil];
}

#pragma mark -
#pragma mark ===========  Player Methods  =========
#pragma mark -

- (void)willPlayPlayerItemAtIndex:(NSInteger)index
{
    if (!tookAudioFocus) {
        [self preAction];
    }
    self.lastItemIndex = index;
    [self.playedItems addObject:@(index)];

    if ([self.delegate respondsToSelector:@selector(hysteriaPlayerWillChangedAtIndex:)]) {
        [self.delegate hysteriaPlayerWillChangedAtIndex:self.lastItemIndex];
    }
}

// MC - this method is a bit odd. it doesn't seem to actually play a playerItem unless it happens to already by ready to play (which is why we need to do it in the delegate method hysteriaPlayerReadyToPlay). but we should start playback there only if player should not be paused
// additionally, this method was not turning off forced-pause status, so if you paused the player and moved to a different item in the ui and played, our implementation of hysteriaPlayerReadyToPlay was seeing that player should be paused, which should have become false when this method was called. fixed by setting _pauseReason = PauseReasonNone
// ^ this would all be explained if you are expected to call play() after calling fetchAndPlayPlayerItem() ... but then it wouldn't make sense for it to call audioPlayer.play() if the item status == ready
- (void)fetchAndPlayPlayerItem:(NSInteger)startAt
{
    [self willPlayPlayerItemAtIndex:startAt];
    [self.audioPlayer pause];
    [self.audioPlayer removeAllItems];
    _pauseReason = PauseReasonNone;
    BOOL findInPlayerItems = NO;
    findInPlayerItems = [self findSourceInPlayerItems:startAt];
    if (!findInPlayerItems) {
        [self getSourceURLAtIndex:startAt preBuffer:NO];
    } else if (self.audioPlayer.currentItem.status == AVPlayerStatusReadyToPlay) {
        [self.audioPlayer play];
    }
}

- (NSInteger)hysteriaPlayerItemsCount
{
    if ([self.datasource respondsToSelector:@selector(hysteriaPlayerNumberOfItems)]) {
        return [self.datasource hysteriaPlayerNumberOfItems];
    }
    return self.itemsCount;
}

- (void)getSourceURLAtIndex:(NSInteger)index preBuffer:(BOOL)preBuffer
{
    NSAssert([self.datasource respondsToSelector:@selector(hysteriaPlayerURLForItemAtIndex:preBuffer:)] || [self.datasource respondsToSelector:@selector(hysteriaPlayerAsyncSetUrlForItemAtIndex:preBuffer:)], @"You didn't implement URL getter delegate from HysteriaPlayerDelegate, hysteriaPlayerURLForItemAtIndex:preBuffer: and hysteriaPlayerAsyncSetUrlForItemAtIndex:preBuffer: provides for the use of alternatives.");
    NSAssert([self hysteriaPlayerItemsCount] > index, ([NSString stringWithFormat:@"You are about to access index: %li URL when your HysteriaPlayer items count value is %li, please check hysteriaPlayerNumberOfItems or set itemsCount directly.", (unsigned long)index, (unsigned long)[self hysteriaPlayerItemsCount]]));
    if ([self.datasource respondsToSelector:@selector(hysteriaPlayerURLForItemAtIndex:preBuffer:)] && [self.datasource hysteriaPlayerURLForItemAtIndex:index preBuffer:preBuffer]) {
        
        // DEBUG CODE
        // guard against inserting redundant item
        if ([[self urlOfPlayerItem:self.audioPlayer.currentItem] isEqual: [self.datasource hysteriaPlayerURLForItemAtIndex:index preBuffer:preBuffer]]) {
            NSLog(@"ERROR: ATTEMPTING TO INSERT ITEM WITH SAME URL AS CURRENT ITEM");
            // insert break point here. if this catches, we need to try to figure out how it happened
            return;
        }
        
        dispatch_async(HBGQueue, ^{
            // question is why it gets wrong URL here
            [self setupPlayerItemWithUrl:[self.datasource hysteriaPlayerURLForItemAtIndex:index preBuffer:preBuffer] index:index];
        });
    } else if ([self.datasource respondsToSelector:@selector(hysteriaPlayerAsyncSetUrlForItemAtIndex:preBuffer:)]) {
        [self.datasource hysteriaPlayerAsyncSetUrlForItemAtIndex:index preBuffer:preBuffer];
    } else {
        NSException *exception = [[NSException alloc] initWithName:@"HysteriaPlayer Error" reason:[NSString stringWithFormat:@"Cannot find item URL at index %li", (unsigned long)index] userInfo:nil];
        @throw exception;
    }
}

- (void)setupPlayerItemWithUrl:(NSURL *)url index:(NSInteger)index
{
    // DEBUG CODE
    // guard against inserting redundant item
    if ([[self urlOfPlayerItem:self.audioPlayer.currentItem] isEqual: url]) {
        NSLog(@"ERROR: ATTEMPTING TO INSERT ITEM WITH SAME URL AS CURRENT ITEM");
        // insert break point here. if this catches, we need to try to figure out how it happened
        return;
    }
    
//    NSLog(@"SETTING UP PLAYER ITEM WITH URL %@", url);
    AVURLAsset *asset = [[AVURLAsset alloc] initWithURL:url options:nil];
    NSArray *keys = @[@"playable", @"duration"];
    
    AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:asset];
    
    [asset loadValuesAsynchronouslyForKeys:keys completionHandler:^() {
        
        dispatch_async(dispatch_get_main_queue(), ^{
            
            [self setHysteriaIndex:item key:[NSNumber numberWithInteger:index]];
            
            if (self.isMemoryCached) {
                NSMutableArray *playerItems = [NSMutableArray arrayWithArray:self.playerItems];
                [playerItems addObject:item];
                self.playerItems = playerItems;
            }
            
            if ([self getLastItemIndex] == index) {
                [self insertPlayerItem:item];
            }
            
//            NSLog(@"queue: %@", self.playerItems);
        });
    }];
}


- (BOOL)findSourceInPlayerItems:(NSInteger)index
{
    for (AVPlayerItem *item in self.playerItems) {
        NSInteger checkIndex = [[self getHysteriaIndex:item] integerValue];
        if (checkIndex == index) {
            if (item.status == AVPlayerItemStatusReadyToPlay) {
                [item seekToTime:kCMTimeZero completionHandler:^(BOOL finished) {
                    [self insertPlayerItem:item];
                }];
                return YES;
            }
        }
    }
    return NO;
}

- (void)prepareNextPlayerItem
{
    if (_shuffleMode == HysteriaPlayerShuffleModeOn || _repeatMode == HysteriaPlayerRepeatModeOnce) {
        return;
    }

    NSInteger nowIndex = self.lastItemIndex;
    BOOL findInPlayerItems = NO;
    NSInteger itemsCount = [self hysteriaPlayerItemsCount];
    
    if (nowIndex + 1 < itemsCount) {
        findInPlayerItems = [self findSourceInPlayerItems:nowIndex + 1];
        
        if (!findInPlayerItems) {
            [self getSourceURLAtIndex:nowIndex + 1 preBuffer:YES];
        }
    }
}

- (void)insertPlayerItem:(AVPlayerItem *)item
{
    if ([self.audioPlayer.items count] > 1) {
        for (int i = 1 ; i < [self.audioPlayer.items count] ; i ++) {
            [self.audioPlayer removeItem:[self.audioPlayer.items objectAtIndex:i]];
        }
    }
    
    // DEBUG CODE
    // guard against inserting redundant item
    if ([self urlForPlayerItem:self.audioPlayer.currentItem matchesUrlForPlayerItem:item]) {
        NSLog(@"ERROR: ATTEMPTING TO INSERT ITEM WITH SAME URL AS CURRENT ITEM");
        // insert break point here. if this catches, we need to try to figure out how it happened
        return;
    }
    
    if ([self.audioPlayer canInsertItem:item afterItem:nil]) {
//        NSLog(@"INSERTING ITEM %@", item);
        [self.audioPlayer insertItem:item afterItem:nil];
    } else {
        NSLog(@"what?");
    }
}

// these 2 methods are part of stop-gaps for preventing bugs
-(NSURL *)urlOfPlayerItem:(AVPlayerItem *)playerItem {
    // get current asset
    AVAsset *currentPlayerAsset = playerItem.asset;
    // make sure the current asset is an AVURLAsset
    if (![currentPlayerAsset isKindOfClass:AVURLAsset.class]) return nil;
    // return the NSURL
    return [(AVURLAsset *)currentPlayerAsset URL];
}

-(BOOL)urlForPlayerItem:(AVPlayerItem *)playerItem1 matchesUrlForPlayerItem:(AVPlayerItem *)playerItem2 {
    return [[self urlOfPlayerItem:playerItem1] isEqual:[self urlOfPlayerItem:playerItem2]];
}

- (void)removeAllItems
{
    for (AVPlayerItem *obj in self.audioPlayer.items) {
        [obj seekToTime:kCMTimeZero];
        [[obj asset] cancelLoading];
        @try {
            [obj removeObserver:self forKeyPath:@"loadedTimeRanges" context:nil];
            [obj removeObserver:self forKeyPath:@"status" context:nil];
        } @catch(id anException) {
            //do nothing, obviously it wasn't attached because an exception was thrown
        }
    }
    
    self.playerItems = [self isMemoryCached] ? [NSArray array] : nil;
    [self.audioPlayer removeAllItems];
}

- (void)removeQueuesAtPlayer
{
    while (self.audioPlayer.items.count > 1) {
        [self.audioPlayer removeItem:[self.audioPlayer.items objectAtIndex:1]];
    }
}

- (void)refreshQueueBeyondCurrentItem
{
    for (AVPlayerItem *obj in self.audioPlayer.items) {
        if (obj != self.audioPlayer.currentItem) {
            [obj seekToTime:kCMTimeZero];
            [[obj asset] cancelLoading];
            @try {
                [obj removeObserver:self forKeyPath:@"loadedTimeRanges" context:nil];
                [obj removeObserver:self forKeyPath:@"status" context:nil];
            } @catch(id anException) {
                //do nothing, obviously it wasn't attached because an exception was thrown
            }
            [self setHysteriaIndex:obj key:nil];
            [self.audioPlayer removeItem:obj];
        } else {
            self.playerItems = [self isMemoryCached] ? [NSArray arrayWithObject:obj] : nil;
            [self setHysteriaIndex:obj key:[NSNumber numberWithInteger:0]];
//            NSLog(@"asdf item %@", obj);
//            NSLog(@"asdf index %@", [self getHysteriaIndex:obj]);
        }
    }
    self.lastItemIndex = 0;
    [self prepareNextPlayerItem];
    
//    NSLog(@"self.audioPlayer.items : %@", self.audioPlayer.items);
//    NSLog(@"self.audioPlayer.currentItem : %@", self.audioPlayer.currentItem);
//    NSLog(@"self.playerItems : %@", self.playerItems);
}

- (void)removeItemAtIndex:(NSInteger)index
{
    if ([self isMemoryCached]) {
        for (AVPlayerItem *item in [NSArray arrayWithArray:self.playerItems]) {
//            NSLog(@"item at index %li : %@", (long)index, item);
            NSInteger checkIndex = [[self getHysteriaIndex:item] integerValue];
            if (checkIndex == index) {
                NSMutableArray *playerItems = [NSMutableArray arrayWithArray:self.playerItems];
                [playerItems removeObject:item];
                self.playerItems = playerItems;
                
                if ([self.audioPlayer.items indexOfObject:item] != NSNotFound) {
                    // TODO: remove observers, cancel loading!!
                    [self.audioPlayer removeItem:item];
                }
            } else if (checkIndex > index) {
                [self setHysteriaIndex:item key:[NSNumber numberWithInteger:checkIndex -1]];
            }
        }
    } else {
        for (AVPlayerItem *item in self.audioPlayer.items) {
            NSInteger checkIndex = [[self getHysteriaIndex:item] integerValue];
            if (checkIndex == index) {
                [self.audioPlayer removeItem:item];
            } else if (checkIndex > index) {
                [self setHysteriaIndex:item key:[NSNumber numberWithInteger:checkIndex -1]];
            }
        }
    }
}

- (void)moveItemFromIndex:(NSInteger)from toIndex:(NSInteger)to
{
    for (AVPlayerItem *item in self.playerItems) {
        [self resetItemIndexIfNeeds:item fromIndex:from toIndex:to];
    }
    
    for (AVPlayerItem *item in self.audioPlayer.items) {
        if ([self resetItemIndexIfNeeds:item fromIndex:from toIndex:to]) {
            [self removeQueuesAtPlayer];
        }
    }
}

- (BOOL)resetItemIndexIfNeeds:(AVPlayerItem *)item fromIndex:(NSInteger)sourceIndex toIndex:(NSInteger)destinationIndex
{
    NSInteger checkIndex = [[self getHysteriaIndex:item] integerValue];
    BOOL found = NO;
    NSNumber *replaceOrder;
    if (checkIndex == sourceIndex) {
        replaceOrder = [NSNumber numberWithInteger:destinationIndex];
        found = YES;
    } else if (checkIndex == destinationIndex) {
        replaceOrder = sourceIndex > checkIndex ? @(checkIndex + 1) : @(checkIndex - 1);
        found = YES;
    } else if (checkIndex > destinationIndex && checkIndex < sourceIndex) {
        replaceOrder = [NSNumber numberWithInteger:(checkIndex + 1)];
        found = YES;
    } else if (checkIndex < destinationIndex && checkIndex > sourceIndex) {
        replaceOrder = [NSNumber numberWithInteger:(checkIndex - 1)];
        found = YES;
    }
    
    if (replaceOrder) {
        [self setHysteriaIndex:item key:replaceOrder];
        if (self.lastItemIndex == checkIndex) {
            self.lastItemIndex = [replaceOrder integerValue];
        }
    }
    return found;
}

- (void)seekToTime:(double)seconds
{
    [self.audioPlayer seekToTime:CMTimeMakeWithSeconds(seconds, NSEC_PER_SEC)];
}

- (void)seekToTime:(double)seconds withCompletionBlock:(void (^)(BOOL))completionBlock
{
    [self.audioPlayer seekToTime:CMTimeMakeWithSeconds(seconds, NSEC_PER_SEC) completionHandler:^(BOOL finished) {
        if (completionBlock) {
            completionBlock(finished);
        }
    }];
}

- (NSInteger)getLastItemIndex
{
    return self.lastItemIndex;
}

- (AVPlayerItem *)getCurrentItem
{
    return [self.audioPlayer currentItem];
}

- (void)play
{
    _pauseReason = PauseReasonNone;
    [self.audioPlayer play];
}

- (void)pause
{
    _pauseReason = PauseReasonForced;
    [self.audioPlayer pause];
}

- (void)playNext
{
    if (_shuffleMode == HysteriaPlayerShuffleModeOn) {
        NSInteger nextIndex = [self randomIndex];
        if (nextIndex != NSNotFound) {
            [self fetchAndPlayPlayerItem:nextIndex];
        } else {
            _pauseReason = PauseReasonForced;
            if ([self.delegate respondsToSelector:@selector(hysteriaPlayerDidReachEnd)]) {
                [self.delegate hysteriaPlayerDidReachEnd];
            }
        }
    } else {
        NSNumber *nowIndexNumber = [self getHysteriaIndex:self.audioPlayer.currentItem];
        NSInteger nowIndex = nowIndexNumber ? [nowIndexNumber integerValue] : self.lastItemIndex;
        if (nowIndex + 1 < [self hysteriaPlayerItemsCount]) {
            if (self.audioPlayer.items.count > 1) {
                [self willPlayPlayerItemAtIndex:nowIndex + 1];
                [self.audioPlayer advanceToNextItem];
            } else {
                [self fetchAndPlayPlayerItem:(nowIndex + 1)];
            }
        } else {
            if (_repeatMode == HysteriaPlayerRepeatModeOff) {
                _pauseReason = PauseReasonForced;
                if ([self.delegate respondsToSelector:@selector(hysteriaPlayerDidReachEnd)]) {
                    [self.delegate hysteriaPlayerDidReachEnd];
                }
            } else {
                [self fetchAndPlayPlayerItem:0];
            }
        }
    }
}

- (void)playPrevious
{
    NSInteger nowIndex = [[self getHysteriaIndex:self.audioPlayer.currentItem] integerValue];
    if (nowIndex == 0)
    {
        if (_repeatMode == HysteriaPlayerRepeatModeOn) {
            [self fetchAndPlayPlayerItem:[self hysteriaPlayerItemsCount] - 1];
        } else {
            [self.audioPlayer.currentItem seekToTime:kCMTimeZero];
        }
    } else {
        [self fetchAndPlayPlayerItem:(nowIndex - 1)];
    }
}

- (CMTime)playerItemDuration
{
    NSError *err = nil;
    if ([self.audioPlayer.currentItem.asset statusOfValueForKey:@"duration" error:&err] == AVKeyValueStatusLoaded) {
        AVPlayerItem *playerItem = [self.audioPlayer currentItem];
        NSArray *loadedRanges = playerItem.seekableTimeRanges;
        if (loadedRanges.count > 0)
        {
            CMTimeRange range = [[loadedRanges objectAtIndex:0] CMTimeRangeValue];
            //Float64 duration = CMTimeGetSeconds(range.start) + CMTimeGetSeconds(range.duration);
            return (range.duration);
        }else {
            return (kCMTimeInvalid);
        }
    } else {
        return (kCMTimeInvalid);
    }
}

- (void)setPlayerRepeatMode:(HysteriaPlayerRepeatMode)mode
{
    _repeatMode = mode;
}

- (HysteriaPlayerRepeatMode)getPlayerRepeatMode
{
    return _repeatMode;
}

- (void)setPlayerShuffleMode:(HysteriaPlayerShuffleMode)mode
{
    switch (mode) {
        case HysteriaPlayerShuffleModeOff:
            _shuffleMode = HysteriaPlayerShuffleModeOff;
            [_playedItems removeAllObjects];
            _playedItems = nil;
            break;
        case HysteriaPlayerShuffleModeOn:
            _shuffleMode = HysteriaPlayerShuffleModeOn;
            _playedItems = [NSMutableSet set];
            if (self.audioPlayer.currentItem) {
                [self.playedItems addObject:[self getHysteriaIndex:self.audioPlayer.currentItem]];
            }
            break;
        default:
            break;
    }
}

- (HysteriaPlayerShuffleMode)getPlayerShuffleMode
{
    return _shuffleMode;
}

- (void)pausePlayerForcibly:(BOOL)forcibly {}

#pragma mark -
#pragma mark ===========  Player info  =========
#pragma mark -

- (BOOL)isPlaying
{
    return self.emptySoundPlaying ? NO : self.audioPlayer.rate != 0.f;
}

- (HysteriaPlayerStatus)getHysteriaPlayerStatus
{
    if ([self isPlaying]) {
        return HysteriaPlayerStatusPlaying;
    } else {
        switch (_pauseReason) {
            case PauseReasonForced:
                return HysteriaPlayerStatusForcePause;
            case PauseReasonBuffering:
                return HysteriaPlayerStatusBuffering;
            default:
                return HysteriaPlayerStatusUnknown;
        }
    }
}

- (float)getPlayingItemCurrentTime
{
    CMTime itemCurrentTime = [[self.audioPlayer currentItem] currentTime];
    float current = CMTimeGetSeconds(itemCurrentTime);
    if (CMTIME_IS_INVALID(itemCurrentTime) || !isfinite(current))
        return 0.0f;
    else
        return current;
}

- (float)getPlayingItemDurationTime
{
    CMTime itemDurationTime = [self playerItemDuration];
    float duration = CMTimeGetSeconds(itemDurationTime);
    if (CMTIME_IS_INVALID(itemDurationTime) || !isfinite(duration))
        return 0.0f;
    else
        return duration;
}

- (id)addBoundaryTimeObserverForTimes:(NSArray *)times queue:(dispatch_queue_t)queue usingBlock:(void (^)(void))block
{
    id boundaryObserver = [self.audioPlayer addBoundaryTimeObserverForTimes:times queue:queue usingBlock:block];
    return boundaryObserver;
}

- (id)addPeriodicTimeObserverForInterval:(CMTime)interval
                                   queue:(dispatch_queue_t)queue
                              usingBlock:(void (^)(CMTime time))block
{
    id mTimeObserver = [self.audioPlayer addPeriodicTimeObserverForInterval:interval queue:queue usingBlock:block];
    return mTimeObserver;
}

- (void)removeTimeObserver:(id)observer
{
    [self.audioPlayer removeTimeObserver:observer];
}

#pragma mark -
#pragma mark ===========  Interruption, Route changed  =========
#pragma mark -

- (void)interruption:(NSNotification*)notification
{
#if TARGET_OS_IPHONE
    NSDictionary *interuptionDict = notification.userInfo;
    NSInteger interuptionType = [[interuptionDict valueForKey:AVAudioSessionInterruptionTypeKey] integerValue];
    
    if (interuptionType == AVAudioSessionInterruptionTypeBegan && _pauseReason != PauseReasonForced) {
        interruptedWhilePlaying = YES;
        [self pause];
    } else if (interuptionType == AVAudioSessionInterruptionTypeEnded && interruptedWhilePlaying) {
        interruptedWhilePlaying = NO;
        [self play];
    }
    if (!self.disableLogs) {
        NSLog(@"HysteriaPlayer: HysteriaPlayer interruption: %@", interuptionType == AVAudioSessionInterruptionTypeBegan ? @"began" : @"end");
    }
#endif
}

- (void)routeChange:(NSNotification *)notification
{
#if TARGET_OS_IPHONE
    NSDictionary *routeChangeDict = notification.userInfo;
    NSInteger routeChangeType = [[routeChangeDict valueForKey:AVAudioSessionRouteChangeReasonKey] integerValue];
    
    if (routeChangeType == AVAudioSessionRouteChangeReasonOldDeviceUnavailable && _pauseReason != PauseReasonForced) {
        routeChangedWhilePlaying = YES;
        [self pause];
    } else if (routeChangeType == AVAudioSessionRouteChangeReasonNewDeviceAvailable && routeChangedWhilePlaying) {
        routeChangedWhilePlaying = NO;
        [self play];
    }
    if (!self.disableLogs) {
        NSLog(@"HysteriaPlayer: HysteriaPlayer routeChanged: %@", routeChangeType == AVAudioSessionRouteChangeReasonNewDeviceAvailable ? @"New Device Available" : @"Old Device Unavailable");
    }
#endif
}

#pragma mark -
#pragma mark ===========  KVO  =========
#pragma mark -

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
                        change:(NSDictionary *)change context:(void *)context {
    if (object == self.audioPlayer && [keyPath isEqualToString:@"status"]) {
        if (self.audioPlayer.status == AVPlayerStatusReadyToPlay) {
            if ([self.delegate respondsToSelector:@selector(hysteriaPlayerReadyToPlay:)]) {
                [self.delegate hysteriaPlayerReadyToPlay:HysteriaPlayerReadyToPlayPlayer];
            }
            if (![self isPlaying]) {
                [self.audioPlayer play];
            }
        } else if (self.audioPlayer.status == AVPlayerStatusFailed) {
            if (!self.disableLogs) {
                NSLog(@"HysteriaPlayer: %@", self.audioPlayer.error);
            }
            
            if (self.popAlertWhenError) {
                [HysteriaPlayer showAlertWithError:self.audioPlayer.error];
            }
            if ([self.delegate respondsToSelector:@selector(hysteriaPlayerDidFailed:error:)]) {
                [self.delegate hysteriaPlayerDidFailed:HysteriaPlayerFailedPlayer error:self.audioPlayer.error];
            }
        }
    }
    
    if (object == self.audioPlayer && [keyPath isEqualToString:@"rate"]) {
        if (!self.emptySoundPlaying) {
            if ([self.delegate respondsToSelector:@selector(hysteriaPlayerRateChanged:)]) {
                [self.delegate hysteriaPlayerRateChanged:[self isPlaying]];
            }
        }
    }
    
    if (object == self.audioPlayer && [keyPath isEqualToString:@"currentItem"]) {
        AVPlayerItem *newPlayerItem = [change objectForKey:NSKeyValueChangeNewKey];
        AVPlayerItem *lastPlayerItem = [change objectForKey:NSKeyValueChangeOldKey];
        if (lastPlayerItem != (id)[NSNull null]) {
            @try {
                [lastPlayerItem removeObserver:self forKeyPath:@"loadedTimeRanges" context:nil];
                [lastPlayerItem removeObserver:self forKeyPath:@"status" context:nil];
            } @catch(id anException) {
                //do nothing, obviously it wasn't attached because an exception was thrown
            }
        }
        if (newPlayerItem != (id)[NSNull null]) {
            [newPlayerItem addObserver:self forKeyPath:@"loadedTimeRanges" options:NSKeyValueObservingOptionNew context:nil];
            [newPlayerItem addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionNew context:nil];
            
            if ([self.delegate respondsToSelector:@selector(hysteriaPlayerCurrentItemChanged:)]) {
                [self.delegate hysteriaPlayerCurrentItemChanged:newPlayerItem];
            }
            self.emptySoundPlaying = NO;
        }
    }
    
    if (object == self.audioPlayer.currentItem && [keyPath isEqualToString:@"status"]) {
        isPreBuffered = NO;
        if (self.audioPlayer.currentItem.status == AVPlayerItemStatusFailed) {
            if (self.popAlertWhenError) {
                [HysteriaPlayer showAlertWithError:self.audioPlayer.currentItem.error];
            }
            
            if ([self.delegate respondsToSelector:@selector(hysteriaPlayerDidFailed:error:)]) {
                [self.delegate hysteriaPlayerDidFailed:HysteriaPlayerFailedCurrentItem error:self.audioPlayer.currentItem.error];
            }
        } else if (self.audioPlayer.currentItem.status == AVPlayerItemStatusReadyToPlay) {
            if ([self.delegate respondsToSelector:@selector(hysteriaPlayerReadyToPlay:)]) {
                [self.delegate hysteriaPlayerReadyToPlay:HysteriaPlayerReadyToPlayCurrentItem];
            }
            if (![self isPlaying] && _pauseReason != PauseReasonForced) {
                [self.audioPlayer play];
            }
        }
    }
    
    if (self.audioPlayer.items.count > 1 && object == [self.audioPlayer.items objectAtIndex:1] && [keyPath isEqualToString:@"loadedTimeRanges"]) {
        isPreBuffered = YES;
    }
    
    if (object == self.audioPlayer.currentItem && [keyPath isEqualToString:@"loadedTimeRanges"]) {
        if (self.audioPlayer.currentItem.hash != prepareingItemHash) {
            [self prepareNextPlayerItem];
            prepareingItemHash = self.audioPlayer.currentItem.hash;
        }
        
        NSArray *timeRanges = (NSArray *)[change objectForKey:NSKeyValueChangeNewKey];
        if (timeRanges && [timeRanges count]) {
            CMTimeRange timerange = [[timeRanges objectAtIndex:0] CMTimeRangeValue];
            
            if ([self.delegate respondsToSelector:@selector(hysteriaPlayerCurrentItemPreloaded:)]) {
                [self.delegate hysteriaPlayerCurrentItemPreloaded:CMTimeAdd(timerange.start, timerange.duration)];
            }
            
            if (self.audioPlayer.rate == 0 && _pauseReason != PauseReasonForced) {
                _pauseReason = PauseReasonBuffering;
                [self longTimeBufferBackground];
                
                CMTime bufferdTime = CMTimeAdd(timerange.start, timerange.duration);
                CMTime milestone = CMTimeAdd(self.audioPlayer.currentTime, CMTimeMakeWithSeconds(5.0f, timerange.duration.timescale));
               
                CMTime timeTillItemEnd = CMTimeSubtract(self.audioPlayer.currentItem.duration, self.audioPlayer.currentTime);
                // following line should contain OR bufferedTime >= timeRemaining, in case there are fewer than 5 seconds left to be buffered; i'll use timeRemaining - 1 in case of imprecision
//                NSLog(@"%lld, %lld, %lld, %lld", bufferdTime.value, milestone.value, timeTillItemEnd.value, CMTimeMakeWithSeconds(4.0f, timerange.duration.timescale).value);
                if ((CMTIME_COMPARE_INLINE(bufferdTime , >, milestone) || CMTIME_COMPARE_INLINE(bufferdTime, >, CMTimeSubtract(timeTillItemEnd, CMTimeMakeWithSeconds(1.0f, timerange.duration.timescale)))) && self.audioPlayer.currentItem.status == AVPlayerItemStatusReadyToPlay && !interruptedWhilePlaying && !routeChangedWhilePlaying) {
                    if (![self isPlaying]) {
                        if (!self.disableLogs) {
                            NSLog(@"HysteriaPlayer: resume from buffering..");
                        }
                        [self play];
                        [self longTimeBufferBackgroundCompleted];
                        
                        //if (CMTIME_COMPARE_INLINE(bufferdTime, >, CMTimeSubtract(timeTillItemEnd, CMTimeMakeWithSeconds(1.0f, timerange.duration.timescale)))) {
                            //[SlackBotClass logPlaybackResume];
                        //}
                    }
                } else {
                    NSLog(@"not resuming from buffering");
                }
            }
        }
    }
}

- (void)playerItemDidReachEnd:(NSNotification *)notification
{
    AVPlayerItem *item = [notification object];
    if (![item isEqual:self.audioPlayer.currentItem]) {
        return;
    }
    
    if ([self.delegate respondsToSelector:@selector(hysterialPlayerDidReachEndOfCurrentItem)]) {
        [self.delegate hysterialPlayerDidReachEndOfCurrentItem];
    }    

    NSNumber *currentItemIndex = [self getHysteriaIndex:self.audioPlayer.currentItem];
    if (currentItemIndex) {
        if (_repeatMode == HysteriaPlayerRepeatModeOnce) {
            NSInteger currentIndex = [currentItemIndex integerValue];
            [self fetchAndPlayPlayerItem:currentIndex];
        } else if (_shuffleMode == HysteriaPlayerShuffleModeOn) {
            NSInteger nextIndex = [self randomIndex];
            if (nextIndex != NSNotFound) {
                [self fetchAndPlayPlayerItem:[self randomIndex]];
            } else {
                _pauseReason = PauseReasonForced;
                if ([self.delegate respondsToSelector:@selector(hysteriaPlayerDidReachEnd)]) {
                    [self.delegate hysteriaPlayerDidReachEnd];
                }
            }
        } else {
            // Spoke
            // Disable end of playlist precondition which did not make sense -RK
            // if (self.audioPlayer.items.count == 1 || !isPreBuffered) {
            
            NSInteger nowIndex = [currentItemIndex integerValue];
            if (nowIndex + 1 < [self hysteriaPlayerItemsCount]) {
                [self playNext];
            } else {
                if (_repeatMode == HysteriaPlayerRepeatModeOff) {
                    _pauseReason = PauseReasonForced;
                    if ([self.delegate respondsToSelector:@selector(hysteriaPlayerDidReachEnd)]) {
                        [self.delegate hysteriaPlayerDidReachEnd];
                    }
                }else {
                    [self fetchAndPlayPlayerItem:0];
                }
            }
            
            // }
        }
    }
}

- (void)playerItemFailedToPlayEndTime:(NSNotification *)notification {
    AVPlayerItem *item = [notification object];
    if (![item isEqual:self.audioPlayer.currentItem]) {
        return;
    }
    
    if ([self.delegate respondsToSelector:@selector(hysteriaPlayerItemFailedToPlayEndTime:error:)]) {
        [self.delegate hysteriaPlayerItemFailedToPlayEndTime:notification.object error:notification.userInfo[AVPlayerItemFailedToPlayToEndTimeErrorKey]];
    }
}

- (void)playerItemPlaybackStall:(NSNotification *)notification {
    AVPlayerItem *item = [notification object];
    if (![item isEqual:self.audioPlayer.currentItem]) {
        return;
    }
    
    if ([self.delegate respondsToSelector:@selector(hysteriaPlayerItemPlaybackStall:)]) {
        [self.delegate hysteriaPlayerItemPlaybackStall:notification.object];
    }
}

- (NSInteger)randomIndex
{
    NSInteger itemsCount = [self hysteriaPlayerItemsCount];
    if ([self.playedItems count] == itemsCount) {
        self.playedItems = [NSMutableSet set];
        if (_repeatMode == HysteriaPlayerRepeatModeOff) {
            return NSNotFound;
        }
    }

    NSInteger index;
    do {
        index = arc4random() % itemsCount;
    } while ([_playedItems containsObject:[NSNumber numberWithInteger:index]]);
    
    return index;
}

#pragma mark -
#pragma mark ===========   Deprecation  =========
#pragma mark -

- (void)deprecatePlayer
{
    NSError *error;
    tookAudioFocus = NO;
#if TARGET_OS_IPHONE
    [[AVAudioSession sharedInstance] setActive:NO error:&error];
    [[UIApplication sharedApplication] endReceivingRemoteControlEvents];
#endif
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    
    [self.audioPlayer removeObserver:self forKeyPath:@"status" context:nil];
    [self.audioPlayer removeObserver:self forKeyPath:@"rate" context:nil];
    [self.audioPlayer removeObserver:self forKeyPath:@"currentItem" context:nil];
    
    [self removeAllItems];
    
    [self.audioPlayer pause];
    self.delegate = nil;
    self.datasource = nil;
    self.audioPlayer = nil;
    
    onceToken = 0;
}

#pragma mark -
#pragma mark ===========   Memory cached  =========
#pragma mark -

- (BOOL)isMemoryCached
{
    return self.playerItems != nil;
}

- (void)enableMemoryCached:(BOOL)memoryCache
{
    if (self.playerItems == nil && memoryCache) {
        self.playerItems = [NSArray array];
    } else if (self.playerItems != nil && !memoryCache) {
        self.playerItems = nil;
    }
}

#pragma mark -
#pragma mark ===========   Delegation  =========
#pragma mark -

- (void)addDelegate:(id<HysteriaPlayerDelegate>)delegate{}

- (void)removeDelegate:(id<HysteriaPlayerDelegate>)delegate{}

@end
