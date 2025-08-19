//
//  TunnelIOBridge.m
//  HyperSpaceTunnel
//
//  Created by Logan Miller on 8/19/25.
//

// TunnelIOBridge.mm
#import <Foundation/Foundation.h>
#import <NetworkExtension/NetworkExtension.h>
#import "TunnelIOBridge.h"
#import "com_whiteStar_HyperSpaceService_HyperSpaceTunnel-Swift.h"

@protocol TunnelDataBridgeSink;
@interface TunnelBridgeHolder : NSObject <TunnelDataBridgeSink>
@property(nonatomic, strong) TunnelDataBridge *swiftBridge;
@property(nonatomic, assign) TunnelPacketCallback cb;
@property(nonatomic, assign) void* userCtx;
@end

@implementation TunnelBridgeHolder

- (instancetype)initWithCallback:(TunnelPacketCallback)cb userCtx:(void*)ctx {
    self = [super init];
    if (self) {
        _cb = cb;
        _userCtx = ctx;
        _swiftBridge = [TunnelDataBridge new];
        _swiftBridge.sink = self;
        [_swiftBridge start];
    }
    return self;
}

- (void)dealloc {
    [_swiftBridge stop];
    _swiftBridge.sink = nil;
    _swiftBridge = nil;
}

- (void)tunnelBridgeDidReceivePacket:(NSData *)packet {
    if (_cb && packet.length > 0) {
        _cb((const uint8_t*)packet.bytes, packet.length, _userCtx);
    }
}

@end

// C API
TunnelIORef TunnelIOCreate(TunnelPacketCallback cb, void* user_ctx) {
    @autoreleasepool {
        TunnelBridgeHolder* holder = [[TunnelBridgeHolder alloc] initWithCallback:cb userCtx:user_ctx];
        return (TunnelIORef)CFBridgingRetain(holder);
    }
}

void TunnelIODestroy(TunnelIORef ref) {
    if (!ref) return;
    @autoreleasepool {
        id obj = CFBridgingRelease(ref);
        (void)obj;
    }
}

void TunnelIOSendPacket(TunnelIORef ref, const uint8_t* bytes, size_t len) {
    if (!ref || !bytes || len == 0) return;
    @autoreleasepool {
        TunnelBridgeHolder* holder = (__bridge TunnelBridgeHolder*)ref;
        NSData* pkt = [NSData dataWithBytes:bytes length:len];
        [holder.swiftBridge sendPacketToHost:pkt];
    }
}

void TunnelIOSendPackets(TunnelIORef ref, const uint8_t* const* bufs, const size_t* lens, size_t count) {
    if (!ref || !bufs || !lens || count == 0) return;
    @autoreleasepool {
        TunnelBridgeHolder* holder = (__bridge TunnelBridgeHolder*)ref;
        NSMutableArray<NSData*>* arr = [NSMutableArray arrayWithCapacity:count];
        for (size_t i = 0; i < count; ++i) {
            const uint8_t* b = bufs[i];
            size_t l = lens[i];
            if (b && l) {
                [arr addObject:[NSData dataWithBytes:b length:l]];
            }
        }
        [holder.swiftBridge sendPacketsToHost:arr];
    }
}

