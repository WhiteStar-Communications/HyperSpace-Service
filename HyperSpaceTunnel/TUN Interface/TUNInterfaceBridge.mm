//
//  TunnelDataBridge.m
//  HyperSpaceTunnel
//
//  Created by Logan Miller on 8/20/25.
//

#import <Foundation/Foundation.h>

#import "TUNInterfaceBridge.h"
#import "TUNInterface.hpp"

#import <memory>
#import <vector>

@interface TUNInterfaceBridge ()
@end

@implementation TUNInterfaceBridge {
    int32_t _tunFD;
    std::unique_ptr<hs::TUNInterface> _iface;
}

- (instancetype)initWithTunFD:(int32_t)tunFD {
    if ((self = [super init])) {
        _tunFD = tunFD;
        _iface = std::make_unique<hs::TUNInterface>(_tunFD);
        _iface->setOutgoingPacketCallBack([weakSelf = self](const std::vector<uint8_t>& bytes) {
            if (bytes.empty()) return;
            // hop back to main (or your preferred queue)
            dispatch_async(dispatch_get_main_queue(), ^{
                NSData *pkt = [NSData dataWithBytes:bytes.data() length:bytes.size()];
                id<TUNInterfaceBridgeDelegate> del = weakSelf.delegate;
                if ([del respondsToSelector:@selector(bridgeDidReadOutboundPacket:)]) {
                    [del bridgeDidReadOutboundPacket:pkt];
                }
            });
        });
    }
    return self;
}

- (void)start {
    if (_iface) _iface->start();
}

- (void)stop {
    if (_iface) _iface->stop();
    _iface.reset();
}

- (void)writePacketToTun:(NSData *)packet {
    if (!_iface || packet.length == 0) return;
    const uint8_t *p = (const uint8_t *)packet.bytes;
    std::vector<uint8_t> v;
    v.assign(p, p + packet.length);
    _iface->writePacket(v);
}

@end

