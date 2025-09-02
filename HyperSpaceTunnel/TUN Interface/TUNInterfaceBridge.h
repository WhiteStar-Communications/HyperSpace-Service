//
//  TunnelDataBridge.h
//  Created by Logan Miller on 8/14/25.
//
//  Copyright (c) 2025, WhiteStar Communications, Inc.
//  All rights reserved.
//  Licensed under the BSD 2-Clause License.
//  See LICENSE file in the project root for details.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol TUNInterfaceBridgeDelegate <NSObject>
/// Called when a packet was read by TUNInterface that should go "outbound" to the host/app side.
- (void)bridgeDidReadOutboundPacket:(NSData *)packet;
@end

/// Wrapper around C++ TUNInterface
@interface TUNInterfaceBridge : NSObject
@property (atomic, weak) id<TUNInterfaceBridgeDelegate> delegate;

- (instancetype)initWithTunFD:(int32_t)tunFD;

/// Start/stop libevent inside the TUNInterface
- (void)start;
- (void)stop;

/// Add/remove a set of known IP addresses
- (void)addKnownIPAddresses:(NSArray<NSString *> *)ipAddresses;
- (void)deleteKnownIPAddresses:(NSArray<NSString *> *)ipAddresses;

/// Set DNS mapping where key = domain, value = array of IP strings
- (void)setDNSMap:(NSDictionary<NSString *, NSArray<NSString *> *> *)dnsMap;

/// Write a packet to the TUNInterface
- (void)writePacketToTun:(NSData *)packet;
@end

NS_ASSUME_NONNULL_END

