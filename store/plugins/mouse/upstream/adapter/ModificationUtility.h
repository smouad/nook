#pragma once
#import "Constants.h"

/// Verbatim directionChanged from MMF ModificationUtility.m.
static inline BOOL directionChanged(MFDirection direction1, MFDirection direction2) {
    if (direction1 == kMFDirectionNone || direction2 == kMFDirectionNone) {
        return NO;
    }
    if (direction1 == direction2) {
        return NO;
    }
    return YES;
}
