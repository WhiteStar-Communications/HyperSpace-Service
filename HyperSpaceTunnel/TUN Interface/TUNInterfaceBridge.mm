//
//  TunnelDataBridge.m
//  HyperSpaceTunnel
//
//  Created by Logan Miller on 8/20/25.
//

#import <Foundation/Foundation.h>

#import "TUNInterfaceBridge.h"
#import "TUNInterface.hpp"
#import "ArrayList.hpp"

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

- (void)addKnownIPAddresses:(NSArray<NSString *> *)ipAddresses {
    if (_iface) {
        __block hs::ArrayList<std::string> cList;
        [ipAddresses enumerateObjectsUsingBlock:^(NSString* _Nonnull obj,
                                                  NSUInteger idx,
                                                  BOOL * _Nonnull stop) {
            cList.add([obj UTF8String]);
        }];
        _iface->addKnownIPAddresses(cList);
    }
}

- (void)removeKnownIPAddresses:(NSArray<NSString *> *)ipAddresses {
    if (_iface) {
        __block hs::ArrayList<std::string> cList;
        [ipAddresses enumerateObjectsUsingBlock:^(NSString* _Nonnull obj,
                                                  NSUInteger idx,
                                                  BOOL * _Nonnull stop) {
            cList.add([obj UTF8String]);
        }];
        _iface->removeKnownIPAddresses(cList);
    }
}

- (void)setDNSMatchMap:(NSDictionary<NSString *, NSArray<NSString *> *> *)dnsMap {
    if (_iface) {
        __block hs::ConcurrentHashMap<std::string, hs::ArrayList<std::string>> cMap;
        [dnsMap enumerateKeysAndObjectsUsingBlock:^(NSString* _Nonnull key,
                                                    NSArray<NSString *> *_Nonnull value,
                                                    BOOL * _Nonnull stop) {
            __block hs::ArrayList<std::string> cList;
            [value enumerateObjectsUsingBlock:^(NSString* _Nonnull obj,
                                                NSUInteger idx,
                                                BOOL * _Nonnull stop) {
                cList.add([obj UTF8String]);
            }];
            cMap.put_fast(key.UTF8String, cList);
        }];
        _iface->setDNSMatchMap(cMap);
    }
}

- (void)addAllAbsentDNSEntries:(NSDictionary<NSString *, NSArray<NSString *> *> *)dnsMap {
    if (_iface) {
        __block hs::ConcurrentHashMap<std::string, hs::ArrayList<std::string>> cMap;
        [dnsMap enumerateKeysAndObjectsUsingBlock:^(NSString* _Nonnull key,
                                                    NSArray<NSString *> *_Nonnull value,
                                                    BOOL * _Nonnull stop) {
            __block hs::ArrayList<std::string> cList;
            [value enumerateObjectsUsingBlock:^(NSString* _Nonnull obj,
                                                NSUInteger idx,
                                                BOOL * _Nonnull stop) {
                cList.add([obj UTF8String]);
            }];
            cMap.put_fast(key.UTF8String, cList);
        }];
        _iface->addAllAbsentDNSEntries(cMap);
    }
}

- (void)writePacketToTun:(NSData *)packet {
    if (!_iface || packet.length == 0) return;
    const uint8_t *p = (const uint8_t *)packet.bytes;
    std::vector<uint8_t> v;
    v.assign(p, p + packet.length);
    _iface->writePacket(v);
}

@end
