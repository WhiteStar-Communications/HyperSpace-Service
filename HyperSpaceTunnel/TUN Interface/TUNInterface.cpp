//
//  TUNInterface.cpp
//  HyperSpaceTunnel
//
//  Created by Logan Miller on 8/20/25.
//

#include "TUNInterface.hpp"
#include "Thread.hpp"

#include <os/log.h>
#include <arpa/inet.h>
#include <netinet/ip.h>
#include <netinet/udp.h>
#include <netinet/tcp.h>
#include <event2/thread.h>

namespace hs {

    TUNInterface::TUNInterface(int32_t tunFD) {
        this->tunFD = tunFD;
    }

    void TUNInterface::start() {
        auto thread = new Thread("TUNInterface " + std::to_string(tunFD), [&]() {
            // Set buffer sizes to 128 KB before handing off to LibEvent
            int bufferSize = 128 * 1024;

            if (setsockopt(tunFD, SOL_SOCKET, SO_RCVBUF, &bufferSize, sizeof(bufferSize)) < 0) {
                os_log(OS_LOG_DEFAULT, "Failed to set receive buffer size: %{public}s", strerror(errno));
            }

            if (setsockopt(tunFD, SOL_SOCKET, SO_SNDBUF, &bufferSize, sizeof(bufferSize)) < 0) {
                os_log(OS_LOG_DEFAULT, "Failed to set send buffer size: %{public}s", strerror(errno));
            }
            
            // Set non-blocking mode
            evutil_make_socket_nonblocking(tunFD);
            
            evthread_use_pthreads();
            
            // Create event base
            base = event_base_new();
            if (!base) {
                os_log(OS_LOG_DEFAULT, "Failed to create event base, %{public}s: ", strerror(errno));
                return;
            }
            
            // Create read event
            readEvent = event_new(base, tunFD, EV_READ | EV_PERSIST, TUNInterface::onRead, this);
            if (!readEvent) {
                os_log(OS_LOG_DEFAULT, "Failed to create read event, %{public}s: ", strerror(errno));
                return;
            }
            event_add(readEvent, nullptr);
            
            // Create write event (disabled until needed)
            writeEvent = event_new(base, tunFD, EV_WRITE | EV_PERSIST, TUNInterface::onWrite, this);
            if (!writeEvent) {
                os_log(OS_LOG_DEFAULT, "Failed to create write event, %{public}s: ", strerror(errno));
                return;
            }
            
            os_log(OS_LOG_DEFAULT, "Beginning to dispatch read/write events...");
            event_base_dispatch(base);
            
            // This code only is reached once the event_base_dispatch loop is broken
            os_log(OS_LOG_DEFAULT, "Event loop exited, cleaning up...");
            
            if (readEvent) {
                event_free(readEvent);
                readEvent = nullptr;
            }
            
            if (writeEvent) {
                event_free(writeEvent);
                writeEvent = nullptr;
            }
            
            if (base) {
                event_base_free(base);
                base = nullptr;
            }
            
            if (tunFD >= 0) {
                close(tunFD);
                tunFD = -1;
            }
            
            os_log(OS_LOG_DEFAULT, "TUN thread cleanup complete");
        });
        thread->start();
    }

    void TUNInterface::stop() {
        os_log(OS_LOG_DEFAULT, "Requested to stop TUN interface");
        if (base) {
            event_base_loopbreak(base);
        }
    }

    void TUNInterface::setOutgoingPacketCallBack(OutgoingPacketCallBack callBack){
        std::lock_guard<std::mutex> lock(callBackMutex);
        this->callBack = std::move(callBack);
    }

    void TUNInterface::sendOutgoingPacket(const std::vector<uint8_t> &packet) {
        OutgoingPacketCallBack cb;
        {
            std::lock_guard<std::mutex> lock(callBackMutex);
            cb = callBack;
        }
        if (cb) cb(packet);
    }

    void TUNInterface::onRead(evutil_socket_t fd,
                                     short events,
                                     void *arg) {
        auto* tunInterface = static_cast<TUNInterface*>(arg);
        std::vector<uint8_t> packet(2000);
        ssize_t len = read(fd, packet.data(), packet.size());
        
        if (len > 4) {
            const uint8_t* payload = packet.data() + 4;
            size_t payloadLen = static_cast<size_t>(len - 4);
            std::vector<uint8_t> rawPacket(payload, payload + payloadLen);
            tunInterface->sendOutgoingPacket(rawPacket);
        }
    }

    void TUNInterface::enqueueWrite(const std::vector<uint8_t>& packet) {
        if (packet.empty()) return;
        
        // Add 4-byte TUN header on macOS/iOS
        std::vector<uint8_t> packetWithHeader;
        packetWithHeader.reserve(4 + packet.size());
        packetWithHeader.insert(packetWithHeader.end(), {0x00, 0x00, 0x00, 0x02});
        packetWithHeader.insert(packetWithHeader.end(), packet.begin(), packet.end());
        
        writeQueue.put(packetWithHeader);
        
        if (writeEvent && !event_pending(writeEvent, EV_WRITE, nullptr)) {
            event_add(writeEvent, nullptr);
        }
    }

    void TUNInterface::onWrite(evutil_socket_t fd,
                                      short events,
                                      void *arg) {
        auto* self = static_cast<TUNInterface*>(arg);
        
        while (!self->writeQueue.empty()) {
            auto optPacket = self->writeQueue.take();
            if (optPacket.has_value()) {
                std::vector<uint8_t> packet = optPacket.value();
                ssize_t written = write(fd, packet.data(), packet.size());
                if (written < 0) {
                    if (errno == EAGAIN || errno == EWOULDBLOCK) {
                        // Can't write now, try later
                        os_log(OS_LOG_DEFAULT, "Can't write now, trying again");
                        self->writeQueue.putFirst(packet);
                        break;
                    }
                    os_log(OS_LOG_DEFAULT, "Write error to TUN");
                }
            }
        }
        
        // If queue is empty, disable the write event
        if (self->writeQueue.empty() && self->writeEvent) {
            event_del(self->writeEvent);
        }
    }

    uint16_t TUNInterface::computeIPChecksum(const uint8_t *data, size_t length) {
        uint32_t sum = 0;
        const uint16_t* words = reinterpret_cast<const uint16_t*>(data);

        while (length > 1) {
            sum += *words++;
            length -= 2;
        }

        if (length == 1) {
            sum += static_cast<uint16_t>(*reinterpret_cast<const uint8_t*>(words) << 8);
        }

        while (sum >> 16) {
            sum = (sum & 0xFFFF) + (sum >> 16);
        }

        return static_cast<uint16_t>(~sum);
    }

    void TUNInterface::printPacketDump(const uint8_t *data,
                                              size_t length,
                                              const std::string &label) {
        if (!label.empty()) {
            os_log(OS_LOG_DEFAULT, "---- %{public}s (len: %zu) ----", label.c_str(), length);
        }
        
        char line[128];
        for (size_t i = 0; i < length; i += 16) {
            size_t offset = snprintf(line, sizeof(line), "%04zx  ", i);
            
            // Hex part
            for (size_t j = 0; j < 16; ++j) {
                if (i + j < length) {
                    offset += snprintf(line + offset, sizeof(line) - offset, "%02x ", data[i + j]);
                } else {
                    offset += snprintf(line + offset, sizeof(line) - offset, "   ");
                }
            }
            
            offset += snprintf(line + offset, sizeof(line) - offset, " ");
            
            // ASCII part
            for (size_t j = 0; j < 16; ++j) {
                if (i + j < length) {
                    uint8_t byte = data[i + j];
                    offset += snprintf(line + offset, sizeof(line) - offset, "%c",
                                       (byte >= 32 && byte <= 126) ? byte : '.');
                }
            }
            
            os_log(OS_LOG_DEFAULT, "%{public}s", line);
        }
        
        os_log(OS_LOG_DEFAULT, "----------------------------");
    }
}

