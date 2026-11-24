#ifndef Launchly_Bridging_Header_h
#define Launchly_Bridging_Header_h

#include <CoreFoundation/CoreFoundation.h>

typedef struct {
    float x;
    float y;
} MTPoint;

typedef struct {
    MTPoint position;
    MTPoint velocity;
} MTVector;

typedef struct {
    int frame;
    double timestamp;
    int identifier;
    int state;
    int fingerId;
    int handId;
    MTVector normalized;
    float zTotal;
    int field9;
    float angle;
    float majorAxis;
    float minorAxis;
    MTVector absolute;
    int field14;
    int field15;
    float zDensity;
} MTTouch;

typedef void *MTDeviceRef;
typedef int (*MTContactCallbackFunction)(MTDeviceRef, MTTouch *, int, double, int);
typedef CFMutableArrayRef (*MTDeviceCreateListFn)(void);
typedef void (*MTRegisterContactFrameCallbackFn)(MTDeviceRef, MTContactCallbackFunction);
typedef void (*MTUnregisterContactFrameCallbackFn)(MTDeviceRef, MTContactCallbackFunction);
typedef void (*MTDeviceStartFn)(MTDeviceRef, int);
typedef void (*MTDeviceStopFn)(MTDeviceRef);

#endif /* Launchly_Bridging_Header_h */
