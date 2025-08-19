// TunInterfaceBridge.mm
#import <Foundation/Foundation.h>
#import "TunInterfaceBridge.hpp"
#import "TunnelIOBridge.h"

// libevent (from your XCFramework)
#import <event2/event.h>
#import <event2/util.h>

#include <sys/uio.h>
#include <unistd.h>
#include <atomic>
#include <thread>
#include <vector>
#include <stdexcept>

namespace hs {

static constexpr int kDefaultMTU = 1500;
static constexpr int kMaxBurstReads = 32;

class TunInterface {
public:
    TunInterface(int tun_fd, bool hasProtoHeader)
    : tunfd_(tun_fd)
    , hasProtoHeader_(hasProtoHeader)
    , mtu_(kDefaultMTU)
    {
        base_ = event_base_new();
        if (!base_) throw std::runtime_error("event_base_new failed");

        io_ = TunnelIOCreate(&TunInterface::OnHostPacketThunk, this);
        if (!io_) throw std::runtime_error("TunnelIOCreate failed");

        evRead_ = event_new(base_, tunfd_, EV_READ | EV_PERSIST, &TunInterface::OnTunReadableThunk, this);
        if (!evRead_) throw std::runtime_error("event_new failed for tun fd");

        readBuf_.resize(mtu_ + 64);
    }

    ~TunInterface() {
        if (evRead_) { event_free(evRead_); evRead_ = nullptr; }
        if (base_)   { event_base_free(base_); base_ = nullptr; }
        if (io_)     { TunnelIODestroy(io_); io_ = nullptr; }
        // fd ownership: if you need to close(tunfd_), do it here.
    }

    void start() {
        if (running_.exchange(true)) return;
        event_add(evRead_, nullptr);
        loopThread_ = std::thread([this] {
            (void)event_base_dispatch(base_);
        });
    }

    void stop() {
        if (!running_.exchange(false)) return;
        if (base_) {
            event_base_loopexit(base_, nullptr);
        }
        if (loopThread_.joinable()) loopThread_.join();
    }

    void setMTU(int mtu) {
        mtu_ = (mtu > 0 ? mtu : kDefaultMTU);
        readBuf_.resize(mtu_ + 64);
    }

private:
    static void OnTunReadableThunk(evutil_socket_t fd, short, void* ctx) {
        static_cast<TunInterface*>(ctx)->onTunReadable(fd);
    }

    void onTunReadable(evutil_socket_t fd) {
        int bursts = 0;
        while (bursts++ < kMaxBurstReads) {
            if (hasProtoHeader_) {
                if (readBuf_.size() < (size_t)mtu_ + 4) readBuf_.resize(mtu_ + 64);
                ssize_t n = ::read(fd, readBuf_.data(), readBuf_.size());
                if (n <= 0) break;
                if (n <= 4) continue;
                const uint8_t* payload = reinterpret_cast<const uint8_t*>(readBuf_.data()) + 4;
                size_t plen = (size_t)n - 4;
                TunnelIOSendPacket(io_, payload, plen);
            } else {
                if (readBuf_.size() < (size_t)mtu_) readBuf_.resize(mtu_ + 64);
                ssize_t n = ::read(fd, readBuf_.data(), readBuf_.size());
                if (n <= 0) break;
                TunnelIOSendPacket(io_, reinterpret_cast<const uint8_t*>(readBuf_.data()), (size_t)n);
            }
        }
    }

    static void OnHostPacketThunk(const uint8_t* bytes, size_t len, void* ctx) {
        static_cast<TunInterface*>(ctx)->onHostPacket(bytes, len);
    }

    void onHostPacket(const uint8_t* bytes, size_t len) {
        if (!bytes || len == 0) return;

        if (hasProtoHeader_) {
            uint8_t version = (bytes[0] >> 4);
            uint32_t af = (version == 6) ? AF_INET6 : AF_INET;
            struct iovec iov[2];
            iov[0].iov_base = &af;
            iov[0].iov_len  = 4;
            iov[1].iov_base = const_cast<uint8_t*>(bytes);
            iov[1].iov_len  = len;
            (void)writev(tunfd_, iov, 2);
        } else {
            (void)::write(tunfd_, bytes, len);
        }
    }

private:
    int tunfd_;
    bool hasProtoHeader_;
    int mtu_;

    event_base* base_ = nullptr;
    event* evRead_ = nullptr;
    std::thread loopThread_;
    std::atomic<bool> running_{false};

    std::vector<char> readBuf_;

    TunnelIORef io_ = nullptr; // Data plane TCP client
};

} // namespace hs

using hs::TunInterface;

TunInterfaceRef TunInterfaceCreate(int tun_fd, int has_proto_header) {
    try {
        auto* obj = new TunInterface(tun_fd, has_proto_header != 0);
        return (TunInterfaceRef)obj;
    } catch (const std::exception& e) {
        NSLog(@"TunInterfaceCreate failed: %s", e.what());
        return nullptr;
    }
}

void TunInterfaceStart(TunInterfaceRef ref) {
    if (!ref) return;
    ((TunInterface*)ref)->start();
}

void TunInterfaceStop(TunInterfaceRef ref) {
    if (!ref) return;
    ((TunInterface*)ref)->stop();
}

void TunInterfaceDestroy(TunInterfaceRef ref) {
    if (!ref) return;
    auto* p = (TunInterface*)ref;
    delete p;
}

void TunInterfaceSetMTU(TunInterfaceRef ref, int mtu) {
    if (!ref) return;
    ((TunInterface*)ref)->setMTU(mtu);
}
