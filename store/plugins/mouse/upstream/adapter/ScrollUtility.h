#pragma once
#import <QuartzCore/QuartzCore.h>

/// Preserve the production clock while allowing deterministic, input-free tests.
CFTimeInterval NookMMFAnalyzerClock(void);
#define CACurrentMediaTime NookMMFAnalyzerClock
