#pragma once
#import <Foundation/Foundation.h>

/// Values from MMF Shared/Constants.h, limited to the analyzer's ABI.
typedef enum {
    kMFDirectionNone,
    kMFDirectionUp,
    kMFDirectionRight,
    kMFDirectionDown,
    kMFDirectionLeft,
} MFDirection;

/// Nook's config adapter exposes just the fields used by ScrollAnalyzer.m.
@interface ScrollConfig : NSObject
@property double consecutiveScrollTickIntervalMax;
@property double consecutiveScrollTickIntervalMin;
@property int scrollSwipeThreshold_inTicks;
@property double consecutiveScrollSwipeMaxInterval;
@property double consecutiveScrollSwipeMinTickSpeed;
@property int scrollSwipeMax_inTicks;
@property int u_smoothness;
@property BOOL u_precise;
@end

#define stringf(...) [NSString stringWithFormat:__VA_ARGS__]
#define DDLogError(...) NSLog(@__VA_ARGS__)
