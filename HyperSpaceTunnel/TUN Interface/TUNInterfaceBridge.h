//
//  TunnelDataBridge.h
//  HyperSpaceTunnel
//
//  Created by Logan Miller on 8/20/25.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol TUNInterfaceBridgeDelegate <NSObject>
/// Called when a packet was read by TUNInterface that should go "outbound" to the host/app side.
- (void)bridgeDidReadOutboundPacket:(NSData *)packet;
@end

/// Small wrapper around your C++ TUNInterface
@interface TUNInterfaceBridge : NSObject
@property (atomic, weak) id<TUNInterfaceBridgeDelegate> delegate;

// The bridge does NOT dup() the fd; you own lifecycle (close in stopTunnel).
- (instancetype)initWithTunFD:(int32_t)tunFD;

/// Start/stop libevent inside your TUNInterface (thread inside C++ is fine)
- (void)start;
- (void)stop;

/// Add/remove a set of known IP addresses (Swift [String])
- (void)addKnownIPAddresses:(NSArray<NSString *> *)ipAddresses;
- (void)deleteKnownIPAddresses:(NSArray<NSString *> *)ipAddresses;

/// Set DNS mapping where key = domain, value = array of IP strings
/// (Swift type: [String: [String]])
- (void)setDNSMap:(NSDictionary<NSString *, NSArray<NSString *> *> *)dnsMap;

/// Write a packet into the tun (toward host stack)
- (void)writePacketToTun:(NSData *)packet;
@end

NS_ASSUME_NONNULL_END

