#pragma once
#import <Foundation/Foundation.h>

/// C boundary between Nook's lifecycle/configuration and the original MMF analyzer.
typedef struct {
    double tickIntervalMax;
    double tickIntervalMin;
    int swipeThreshold;
    double swipeMaxInterval;
    double swipeMinTickSpeed;
    BOOL primesInterval;
} NookMMFAnalyzerConfig;

typedef struct {
    double tickInterval;
    int64_t tickCounter;
    double swipeCounter;
    BOOL directionChanged;
} NookMMFScrollAnalysis;

void NookMMFAnalyzerReset(void);
NookMMFScrollAnalysis NookMMFAnalyzerUpdate(double timestamp, int direction, NookMMFAnalyzerConfig config);
/// NaN restores CACurrentMediaTime. Tests can supply the same monotonic clock as input timestamps.
void NookMMFAnalyzerSetClockForTesting(double timestamp);
