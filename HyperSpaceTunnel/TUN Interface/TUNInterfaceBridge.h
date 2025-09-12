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
- (void)bridgeDidReadOutboundPacket:(NSData *)packet;
@end

@interface TUNInterfaceBridge : NSObject
@property (atomic, weak) id<TUNInterfaceBridgeDelegate> delegate;

- (instancetype)initWithTunFD:(int32_t)tunFD;

- (void)start;
- (void)stop;

- (void)addKnownIPAddresses:(NSArray<NSString *> *)ipAddresses;
- (void)deleteKnownIPAddresses:(NSArray<NSString *> *)ipAddresses;

- (void)setDNSMap:(NSDictionary<NSString *, NSArray<NSString *> *> *)dnsMap;
- (void)addAllAbsentDNSEntries:(NSDictionary<NSString *, NSArray<NSString *> *> *)dnsMap;

- (void)writePacketToTun:(NSData *)packet;
@end

NS_ASSUME_NONNULL_END

