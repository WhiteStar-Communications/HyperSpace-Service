// TunInterfaceBridge.h
#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void* TunInterfaceRef;

/// Create libevent-driven TUN interface.
/// - tun_fd: your utun/TUN fd
/// - has_proto_header: 1 if fd expects 4-byte AF_* header (utun), else 0
TunInterfaceRef TunInterfaceCreate(int tun_fd, int has_proto_header);

void TunInterfaceStart(TunInterfaceRef ref);
void TunInterfaceStop(TunInterfaceRef ref);
void TunInterfaceDestroy(TunInterfaceRef ref);
void TunInterfaceSetMTU(TunInterfaceRef ref, int mtu);

#ifdef __cplusplus
}
#endif

