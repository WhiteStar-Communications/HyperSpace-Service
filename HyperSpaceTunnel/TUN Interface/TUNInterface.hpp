//
//  TUNInterface.hpp
//  HyperSpaceTunnel
//
//  Created by Logan Miller on 8/20/25.
//

#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include <event2/event.h>
#include "ConcurrentHashMap.hpp"
#include "ArrayList.hpp"
#include "LinkedBlockingDeque.hpp"

namespace hs {
    struct icmphdr {
        uint8_t  type;
        uint8_t  code;
        uint16_t checksum;
        uint16_t id;
        uint16_t sequence;
    };

    class TUNInterface final {

    public:
        ~TUNInterface() = default;
        explicit TUNInterface(int32_t tunFD);
        
        ArrayList<std::string> knownIPAddresses;
        ConcurrentHashMap<std::string, ArrayList<std::string>> dnsMap;
        LinkedBlockingDeque<std::vector<uint8_t>> writeQueue;

        int tunFD;
        struct event_base* base;
        struct event* readEvent;
        struct event* writeEvent;
        std::mutex callBackMutex;
        using OutgoingPacketCallBack = std::function<void(const std::vector<uint8_t>&)>;
        OutgoingPacketCallBack callBack;

        // Tunnel Functions
        void start();
        void stop();
        void setOutgoingPacketCallBack(OutgoingPacketCallBack callBack);
        void sendOutgoingPacket(const std::vector<uint8_t>& packet);
        void writePacket(const std::vector<uint8_t> &packet);
        void enqueueWrite(const std::vector<uint8_t> &packet);
        static void onRead(evutil_socket_t fd,
                           short events,
                           void* arg);
        static void onWrite(evutil_socket_t fd,
                            short events,
                            void* arg);
        
        void addKnownIPAddress(std::string ipAddress);
        void addKnownIPAddresses(ArrayList<std::string> ipAddresses);
        void deleteKnownIPAddress(std::string ipAddress);
        void deleteKnownIPAddresses(ArrayList<std::string> ipAddresses);
        
        // DNS Handling
        void setDNSMap(ConcurrentHashMap<std::string, ArrayList<std::string>> map);
        void addDNSEntry(std::string ipAddress,
                         std::string hostName);
        void deleteDNSEntry(std::string ipAddress);
        bool isDNSQuery(const std::vector<uint8_t> &packet);
        void sendDNSResponse(const uint8_t *packet,
                             size_t length,
                             const std::string &resolvedIP);
        std::string extractDNSName(const uint8_t *payload,
                                   size_t offset,
                                   size_t maxLen,
                                   size_t &endOffset,
                                   int depth = 0);
        
        void handleICMPPacket(std::vector<uint8_t>& packet);
        
        void printPacketDump(const uint8_t *data,
                             size_t length,
                             const std::string &label = "");
        uint16_t computeIPChecksum(const uint8_t *data,
                                   size_t length);
    };
}


