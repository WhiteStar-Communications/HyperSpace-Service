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
@property (nonatomic, strong) dispatch_queue_t pktQueue;
@end

@implementation TUNInterfaceBridge {
    int32_t _tunFD;
    std::unique_ptr<hs::TUNInterface> _iface;
}

- (instancetype)initWithTunFD:(int32_t)tunFD {
    if ((self = [super init])) {
        _tunFD = tunFD;
        _pktQueue = dispatch_queue_create("tun.packetOut", DISPATCH_QUEUE_SERIAL);
        _iface = std::make_unique<hs::TUNInterface>(_tunFD);

        _iface->setOutgoingPacketCallBack([weakSelf = self](const std::vector<uint8_t>& bytes) {
            if (bytes.empty()) return;
            NSData *pkt = [NSData dataWithBytes:bytes.data() length:bytes.size()];
            dispatch_async(weakSelf.pktQueue, ^{
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
    _iface->enqueueWrite(v);
}

@end
