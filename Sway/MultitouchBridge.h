#pragma once
#include <CoreFoundation/CoreFoundation.h>
#include <stdint.h>

// A copied, public bridge record; its layout is NOT the private framework ABI.
typedef struct {
    int32_t identifier;
    float x;
    float y;
} MTBridgeContact;

// Callbacks occur on the framework thread. The array is valid only until return.
typedef void (*MTFrameCallback)(int count, const MTBridgeContact *contacts,
                                double timestamp, uint64_t generation);
void MTBridge_SetFrameCallback(MTFrameCallback callback);
// Returns the number of successfully started devices (zero means unavailable).
int MTBridge_Start(uint64_t generation);
void MTBridge_Stop(void);
