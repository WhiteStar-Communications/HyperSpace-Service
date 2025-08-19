//
//  DataSink.swift
//  HyperSpaceService
//
//  Created by Logan Miller on 8/14/25.
//

import Foundation

final class DataSink: DataServerDelegate {
    func dataServer(_ server: DataServer, didReceivePacket data: Data) {
        // TODO: forward to Java, write to pcap, inspect, etc.
        // print("packet \(data.count) bytes")
    }
    func dataServerDidConnect(_ server: DataServer) {
        // print("data plane connected")
    }
    func dataServerDidDisconnect(_ server: DataServer, error: Error?) {
        // print("data plane disconnected \(String(describing: error))")
    }
}
