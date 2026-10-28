#pragma once
/// CircularBuffer's only log is diagnostic. Never write into Nook's stdout JSON-RPC stream.
#define DDLogDebug(...) ((void)0)
