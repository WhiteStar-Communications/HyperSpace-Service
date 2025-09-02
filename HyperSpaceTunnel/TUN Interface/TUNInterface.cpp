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

    void TUNInterface::addKnownIPAddress(std::string ipAddress) {
        if (!knownIPAddresses.contains(ipAddress)) {
            knownIPAddresses.add(ipAddress);
        }
    }

    void TUNInterface::addKnownIPAddresses(ArrayList<std::string> ipAddresses) {
        knownIPAddresses.addAllAbsent(ipAddresses);
    }

    void TUNInterface::deleteKnownIPAddress(std::string ipAddress) {
        knownIPAddresses.remove(ipAddress);
    }

    void TUNInterface::deleteKnownIPAddresses(ArrayList<std::string> ipAddresses) {
        knownIPAddresses.removeAll(ipAddresses);
    }

    void TUNInterface::setDNSMap(ConcurrentHashMap<std::string, ArrayList<std::string>> map) {
        dnsMap = map;
    }

    void TUNInterface::addDNSEntry(std::string ipAddress,
                                    std::string hostName) {
        auto values = dnsMap.get(ipAddress);
        if (values.has_value()) {
            auto list = values.value();
            if (!list.contains(hostName)) {
                list.add(hostName);
            }
        } else {
            auto list = ArrayList<std::string>();
            list.add(hostName);
            dnsMap.put(ipAddress, list);
        }
    }

    void TUNInterface::deleteDNSEntry(std::string ipAddress) {
        dnsMap.remove(ipAddress);
    }

    void TUNInterface::onRead(evutil_socket_t fd,
                                     short events,
                                     void *arg) {
        auto* tunInterface = static_cast<TUNInterface*>(arg);
        std::vector<uint8_t> packet(2000);
        ssize_t len = read(fd, packet.data(), packet.size());
        
        if (len > 0) {
            packet.resize(len);
            
            // Remove 4-byte TUN header used by macOS/iOS
            if (packet.size() >= 4) {
                packet.erase(packet.begin(), packet.begin() + 4);
            }
            
            const struct ip* iphdr = reinterpret_cast<const struct ip*>(packet.data());
            if (iphdr->ip_p == IPPROTO_ICMP) {
                tunInterface->handleICMPPacket(packet);
                return;
            }
            
            if (!tunInterface->isDNSQuery(packet)) {
                tunInterface->sendOutgoingPacket(packet);
            }
        }
    }

    void TUNInterface::enqueueWrite(const std::vector<uint8_t> &packet) {
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

    void TUNInterface::writePacket(const std::vector<uint8_t> &packet) {
        struct ip* iphdr = reinterpret_cast<struct ip*>(const_cast<uint8_t*>(packet.data()));
        size_t ipHeaderLen = iphdr->ip_hl * 4;
        
        if (packet.size() < ipHeaderLen) return;
        
        if (iphdr->ip_p != IPPROTO_ICMP) {
            enqueueWrite(packet);
            return;
        }
        
        struct icmphdr* icmp = reinterpret_cast<struct icmphdr*>(reinterpret_cast<uint8_t*>(iphdr) + ipHeaderLen);
        size_t totalLen = ntohs(iphdr->ip_len);
        
        if (totalLen < ipHeaderLen || totalLen > packet.size()) return;
        
        if (icmp->type != 8) {
            enqueueWrite(packet);
            return;
        }
        
        uint32_t srcIP = iphdr->ip_src.s_addr;
        bool isKnownIP = false;
        for (const auto& ipAddress : knownIPAddresses) {
            in_addr tmp;
            inet_aton(ipAddress.c_str(), &tmp);
            if (tmp.s_addr == srcIP) {
                isKnownIP = true;
                break;
            }
        }
        if (!isKnownIP) {
            enqueueWrite(packet);
            return;
        }
        
        // Create an ICMP reply
        icmp->type = 0;
        icmp->checksum = 0;
        icmp->checksum = computeIPChecksum(reinterpret_cast<const uint8_t*>(icmp),
                                           totalLen - ipHeaderLen);
        in_addr tmpAddr = iphdr->ip_src;
        iphdr->ip_src = iphdr->ip_dst;
        iphdr->ip_dst = tmpAddr;

        iphdr->ip_sum = 0;
        iphdr->ip_sum = computeIPChecksum(reinterpret_cast<const uint8_t*>(iphdr),
                                          ipHeaderLen);
        
        // Send reply to be processed by HyperSpace
        sendOutgoingPacket(packet);
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

    bool TUNInterface::isDNSQuery(const std::vector<uint8_t> &packet) {
        const uint8_t* raw = packet.data();
        const struct ip* iphdr = reinterpret_cast<const struct ip*>(raw);
        
        if (iphdr->ip_v != 4 || iphdr->ip_p != IPPROTO_UDP)
            return false;
        
        size_t ipHeaderLen = iphdr->ip_hl * 4;
        if (packet.size() < ipHeaderLen + sizeof(struct udphdr))
            return false;
        
        const struct udphdr* udphdr = reinterpret_cast<const struct udphdr*>(raw + ipHeaderLen);
        uint16_t dstPort = ntohs(udphdr->uh_dport);
        if (dstPort != 53)
            return false;
        
        const uint8_t* dnsStart = raw + ipHeaderLen + sizeof(struct udphdr);
        size_t dnsLen = packet.size() - ipHeaderLen - sizeof(struct udphdr);
        if (dnsLen < 12) {
            return false;
        }
        
        size_t nameEnd = 0;
        std::string domain = extractDNSName(dnsStart, 12, dnsLen, nameEnd);
        
        if (dnsLen < nameEnd + 4) {
            return false;
        }
        
        // Iterate dnsMap and send DNS response to counterParty, if domains match
        dnsMap.forEach([&](const std::string& ipAddressStr, const ArrayList<std::string>& listOfHostNames) {
            if (listOfHostNames.contains(domain)) {
                in_addr addr;
                if (inet_aton(ipAddressStr.c_str(), &addr)) {
                    sendDNSResponse(raw, packet.size(), ipAddressStr);
                }
            }
        });
        
        return true;
    }

    void TUNInterface::sendDNSResponse(const uint8_t *packet,
                                              size_t length,
                                              const std::string &resolvedIP) {
        if (length < sizeof(struct ip)) return;
        
        const struct ip* iphdr = reinterpret_cast<const struct ip*>(packet);
        if (iphdr->ip_p != IPPROTO_UDP) return;
        
        size_t ipHeaderLen = iphdr->ip_hl * 4;
        size_t udpHeaderLen = sizeof(struct udphdr);
        const uint8_t* dnsStart = packet + ipHeaderLen + udpHeaderLen;
        size_t dnsLength = length - ipHeaderLen - udpHeaderLen;
        
        if (dnsLength < 12) return;
        
        // Extract QTYPE
        const uint16_t qtype = (dnsStart[dnsLength - 4] << 8) | dnsStart[dnsLength - 3];
        
        // First, check if this is a type AAAA or HTTPS query
        // If so, respond with an empty DNS response
        // This will cause the OS to fallback to type A queries quicker
        // Improves performance when loading a website, for example
        if (qtype == 28 || qtype == 65) {
            // Prepare empty response with ANCOUNT = 0
            std::vector<uint8_t> response(packet, packet + length);
            uint8_t* dns = response.data() + ipHeaderLen + udpHeaderLen;
            
            // Set DNS flags: QR = 1 (response), RD = 1, RA = 1, RCODE = 0
            dns[2] = 0x81;
            dns[3] = 0x80;
            
            // Set ANCOUNT = 0
            dns[6] = 0x00;
            dns[7] = 0x00;
            
            // Truncate to the end of question section
            size_t questionEnd = 12;
            while (questionEnd < dnsLength && dns[questionEnd] != 0) {
                questionEnd += dns[questionEnd] + 1;
            }
            questionEnd += 5;
            
            response.resize(ipHeaderLen + udpHeaderLen + questionEnd);
            
            struct ip* newIPH = reinterpret_cast<struct ip*>(response.data());
            struct udphdr* newUDPH = reinterpret_cast<struct udphdr*>(response.data() + ipHeaderLen);
            
            // Swap IP addresses
            in_addr tmpIP = newIPH->ip_src;
            newIPH->ip_src = newIPH->ip_dst;
            newIPH->ip_dst = tmpIP;
            
            // Swap UDP ports
            uint16_t tmpPort = newUDPH->uh_sport;
            newUDPH->uh_sport = newUDPH->uh_dport;
            newUDPH->uh_dport = tmpPort;
            
            // Update lengths and checksums
            uint16_t totalLen = response.size();
            newIPH->ip_len = htons(totalLen);
            newIPH->ip_sum = 0;
            newIPH->ip_sum = computeIPChecksum(reinterpret_cast<const uint8_t*>(newIPH), ipHeaderLen);
            newUDPH->uh_ulen = htons(totalLen - ipHeaderLen);
            newUDPH->uh_sum = 0;
            
            enqueueWrite(response);
            return;
        }
        // Only respond to type A queries
        if (qtype != 1) return;
        
        std::vector<uint8_t> response(packet, packet + length);
        uint8_t* dns = response.data() + ipHeaderLen + udpHeaderLen;
        
        // Set DNS flags: QR = 1 (response), Opcode = 0, AA = 0, TC = 0, RD = 1, RA = 1, Z = 0, RCODE = 0
        dns[2] = 0x81;
        dns[3] = 0x80;
        
        // Set ANCOUNT = 1
        dns[6] = 0x00;
        dns[7] = 0x01;
        
        // Locate end of question section
        size_t questionEnd = 12;
        while (questionEnd < dnsLength && dns[questionEnd] != 0) {
            questionEnd += dns[questionEnd] + 1;
        }
        // null byte + QTYPE (2) + QCLASS (2)
        questionEnd += 5;
        
        std::vector<uint8_t> answer;
        
        // Name: pointer to offset 0x0c (start of question name)
        answer.push_back(0xC0);
        answer.push_back(0x0C);
        
        // Type A (0x0001)
        answer.push_back(0x00);
        answer.push_back(0x01);
        
        // Class IN (0x0001)
        answer.push_back(0x00);
        answer.push_back(0x01);
        
        // TTL (300 seconds)
        answer.push_back(0x00);
        answer.push_back(0x00);
        answer.push_back(0x01);
        answer.push_back(0x2C);
        
        // RDLENGTH = 4 (IPv4)
        answer.push_back(0x00);
        answer.push_back(0x04);
        
        // RDATA (IPv4 address)
        in_addr ipAddr;
        inet_aton(resolvedIP.c_str(), &ipAddr);
        uint8_t* ipBytes = reinterpret_cast<uint8_t*>(&ipAddr);
        answer.insert(answer.end(), ipBytes, ipBytes + 4);
        
        // Truncate at end of question, insert answer
        response.resize(ipHeaderLen + udpHeaderLen + questionEnd);
        response.insert(response.end(), answer.begin(), answer.end());
        
        uint16_t totalLen = response.size();
        
        struct ip* newIPH = reinterpret_cast<struct ip*>(response.data());
        struct udphdr* newUDPH = reinterpret_cast<struct udphdr*>(response.data() + ipHeaderLen);
        
        // Swap IP addresses
        in_addr tmpIP = newIPH->ip_src;
        newIPH->ip_src = newIPH->ip_dst;
        newIPH->ip_dst = tmpIP;
        
        // Swap UDP ports
        uint16_t tmpPort = newUDPH->uh_sport;
        newUDPH->uh_sport = newUDPH->uh_dport;
        newUDPH->uh_dport = tmpPort;
        
        // Set total lengths and checksums
        newIPH->ip_len = htons(totalLen);
        newIPH->ip_sum = 0;
        newIPH->ip_sum = computeIPChecksum(reinterpret_cast<const uint8_t*>(newIPH), ipHeaderLen);
        newUDPH->uh_ulen = htons(totalLen - ipHeaderLen);
        newUDPH->uh_sum = 0;
        
        // Write response to host stack
        enqueueWrite(response);
    }

    void TUNInterface::handleICMPPacket(std::vector<uint8_t>& packet) {
        struct ip* iphdr = reinterpret_cast<struct ip*>(packet.data());
        size_t ipHeaderLen = iphdr->ip_hl * 4;
        struct icmphdr* icmp = reinterpret_cast<struct icmphdr*>(packet.data() + ipHeaderLen);
        
        if (icmp->type == 8) {
            // Create an ICMP request
            uint32_t dstIP = iphdr->ip_dst.s_addr;
            
            bool isKnownIP = false;
            for(const auto &ipAddress: knownIPAddresses) {
                in_addr tmp;
                inet_aton(ipAddress.c_str(), &tmp);
                if (tmp.s_addr == dstIP) {
                    os_log(OS_LOG_DEFAULT, "Found known ipAddress: %{public}s", ipAddress.c_str());
                    isKnownIP = true;
                    break;
                }
            }
            
            if (isKnownIP) {
                // This is a known IP address, send packet to be processed by HyperSpace
                sendOutgoingPacket(packet);
            }
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

    std::string TUNInterface::extractDNSName(const uint8_t *payload,
                                                    size_t offset,
                                                    size_t maxLen,
                                                    size_t &endOffset,
                                                    int depth) {
        if (depth > 5) return "";
        
        std::string result;
        bool jumped = false;
        size_t originalOffset = offset;
        
        while (offset < maxLen) {
            uint8_t len = payload[offset];
            if ((len & 0xC0) == 0xC0) {
                if (offset + 1 >= maxLen) break;
                
                uint16_t pointer = ((len & 0x3F) << 8) | payload[offset + 1];
                offset += 2;
                
                std::string pointedName = extractDNSName(payload, pointer, maxLen, endOffset, depth + 1);
                if (!result.empty() && !pointedName.empty()) result += ".";
                result += pointedName;
                
                jumped = true;
                break;
            }
            
            if (len == 0) {
                offset++;
                break;
            }
            
            offset++;
            if (offset + len > maxLen) break;
            
            if (!result.empty()) result += ".";
            result += std::string(reinterpret_cast<const char*>(&payload[offset]), len);
            offset += len;
        }
        
        endOffset = jumped ? originalOffset + 2 : offset;
        return result;
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

