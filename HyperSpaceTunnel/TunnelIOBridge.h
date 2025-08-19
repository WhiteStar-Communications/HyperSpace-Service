//
//  TunnelIOBridge.h
//  HyperSpaceService
//
//  Created by Logan Miller on 8/19/25.
//

// TunnelIOBridge.h
#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void* TunnelIORef;

/// Callback for packets arriving from host (DataServer → extension).
typedef void (*TunnelPacketCallback)(const uint8_t* bytes, size_t len, void* user_ctx);

/// Create the bridge and start the TCP client (127.0.0.1:5501).
TunnelIORef TunnelIOCreate(TunnelPacketCallback cb, void* user_ctx);

/// Stop and destroy the bridge.
void TunnelIODestroy(TunnelIORef ref);

/// Send one packet from extension (libevent) → host (DataServer).
void TunnelIOSendPacket(TunnelIORef ref, const uint8_t* bytes, size_t len);

/// Send many packets in one write.
void TunnelIOSendPackets(TunnelIORef ref, const uint8_t* const* bufs, const size_t* lens, size_t count);

#ifdef __cplusplus
} // extern "C"
#endif

