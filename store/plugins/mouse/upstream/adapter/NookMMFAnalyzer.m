#import "NookMMFAnalyzer.h"
#import "ScrollAnalyzer.h"
#import <QuartzCore/QuartzCore.h>
#import <math.h>

@implementation ScrollConfig
@end

static double testClock = NAN;

CFTimeInterval NookMMFAnalyzerClock(void) {
    return isnan(testClock) ? CACurrentMediaTime() : testClock;
}

void NookMMFAnalyzerSetClockForTesting(double timestamp) {
    testClock = timestamp;
}

void NookMMFAnalyzerReset(void) {
    [ScrollAnalyzer resetState];
}

NookMMFScrollAnalysis NookMMFAnalyzerUpdate(double timestamp, int direction, NookMMFAnalyzerConfig config) {
    ScrollConfig *settings = [ScrollConfig new];
    settings.consecutiveScrollTickIntervalMax = config.tickIntervalMax;
    settings.consecutiveScrollTickIntervalMin = config.tickIntervalMin;
    settings.scrollSwipeThreshold_inTicks = config.swipeThreshold;
    settings.consecutiveScrollSwipeMaxInterval = config.swipeMaxInterval;
    settings.consecutiveScrollSwipeMinTickSpeed = config.swipeMinTickSpeed;
    settings.scrollSwipeMax_inTicks = 30; // Upstream's free-wheel increment is disabled.
    settings.u_smoothness = config.primesInterval ? kMFScrollSmoothnessHigh : kMFScrollSmoothnessRegular;
    settings.u_precise = NO;
    ScrollAnalysisResult result = [ScrollAnalyzer updateWithTickOccuringAt:timestamp direction:(MFDirection)direction config:settings];
    return (NookMMFScrollAnalysis){
        .tickInterval = result.timeBetweenTicks,
        .tickCounter = result.consecutiveScrollTickCounter,
        .swipeCounter = result.consecutiveScrollSwipeCounter,
        .directionChanged = result.scrollDirectionDidChange,
    };
}
