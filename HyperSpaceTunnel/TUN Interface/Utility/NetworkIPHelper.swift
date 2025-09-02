//
//  IPAddressHelper.swift
//
//  Created by Logan Miller on 8/14/25.
//
//  Copyright (c) 2025, WhiteStar Communications, Inc.
//  All rights reserved.
//  Licensed under the BSD 2-Clause License.
//  See LICENSE file in the project root for details.
//

import Network
import Foundation

public class NetworkIPHelper {
    public static func ipv4ToString(_ address: IPv4Address) -> String {
        return address.rawValue.map { String($0) }.joined(separator: ".")
    }
    
    public static func endpointIDToIPv4Address(endpointID: String) -> IPv4Address? {
        guard let uuid = UUID(uuidString: endpointID) else { return nil }
        
        // Access the raw 16 bytes of the UUID
        let uuidBytes = withUnsafeBytes(of: uuid.uuid) { Array($0) }

        // Convert the most significant 8 bytes into a UInt64
        let msb = (UInt64(uuidBytes[0]) << 56) |
                  (UInt64(uuidBytes[1]) << 48) |
                  (UInt64(uuidBytes[2]) << 40) |
                  (UInt64(uuidBytes[3]) << 32) |
                  (UInt64(uuidBytes[4]) << 24) |
                  (UInt64(uuidBytes[5]) << 16) |
                  (UInt64(uuidBytes[6]) << 8)  |
                  UInt64(uuidBytes[7])
        
        // Extract the top 4 bytes as the IPv4 address
        var byteArray: [UInt8] = [
            UInt8((msb >> 24) & 0xFF),
            UInt8((msb >> 16) & 0xFF),
            UInt8((msb >> 8) & 0xFF),
            UInt8(msb & 0xFF)
        ]
        
        let topByte = byteArray[0]
        if topByte > 223 || topByte == 127 {
            // 224-239/8 are multicast addresses
            // 240-255/8 networks are reserved. 127 is loopback
            byteArray[0] = topByte &- 42
        } else if topByte == 0 {
            // zero/8 network is reserved
            byteArray[0] = topByte &+ 42
        }

        return IPv4Address(Data(byteArray))
    }
    
    public static func stringToIPv4Address(string: String) -> IPv4Address? {
        guard let uuid = UUID(uuidString: string) else { return nil }
        
        // Access the raw 16 bytes of the UUID
        let uuidBytes = withUnsafeBytes(of: uuid.uuid) { Array($0) }
        
        // Convert the most significant bits into an integer
        let msb = (UInt64(uuidBytes[0]) << 56) |
                  (UInt64(uuidBytes[1]) << 48) |
                  (UInt64(uuidBytes[2]) << 40) |
                  (UInt64(uuidBytes[3]) << 32) |
                  (UInt64(uuidBytes[4]) << 24) |
                  (UInt64(uuidBytes[5]) << 16) |
                  (UInt64(uuidBytes[6]) << 8)  |
                   UInt64(uuidBytes[7])
        
        // Use the first 4 bytes of the most significant bits for the IPv4 address
        let ipv4Data = Data([
            UInt8((msb >> 24) & 0xFF),
            UInt8((msb >> 16) & 0xFF),
            UInt8((msb >> 8) & 0xFF),
            UInt8(msb & 0xFF)
        ])
        
        return IPv4Address(ipv4Data)
    }
    
    public static func extractDestinationIP(from packet: Data) -> IPv4Address? {
        guard packet.count >= 20 else { return nil }

        let ipHeaderStart = 0
        let version = (packet[ipHeaderStart] >> 4) & 0xF

        if version == 4, packet.count >= ipHeaderStart + 20 {
            let ipData = packet.subdata(in: (ipHeaderStart + 16)..<(ipHeaderStart + 20))
            var ipAddress = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))

            let success = ipData.withUnsafeBytes { rawPtr -> Bool in
                guard let baseAddress = rawPtr.baseAddress else { return false }
                return inet_ntop(AF_INET, baseAddress, &ipAddress, socklen_t(INET_ADDRSTRLEN)) != nil
            }

            return success ? IPv4Address(String(cString: ipAddress)) : nil

        }
        return nil
    }
    
    private static func ipv4ToUInt32(_ ip: String) -> UInt32? {
        var addr = in_addr()
        if inet_pton(AF_INET, ip, &addr) == 1 {
            return UInt32(bigEndian: addr.s_addr)
        }
        return nil
    }
}
