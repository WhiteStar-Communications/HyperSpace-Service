//
//  CommandEvent.swift
//  HyperSpaceTunnel
//
//  Created by Logan Miller on 8/25/25.
//

import Foundation
import Network

final class CommandEvent {
    private let host: NWEndpoint.Host = .ipv4(.loopback)
    private let port: NWEndpoint.Port = 5503

    func sendEvent(_ obj: [String: Any]) {
        let params = NWParameters.tcp
        let conn = NWConnection(host: host, port: port, using: params)

        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                guard let body = try? JSONSerialization.data(withJSONObject: obj) else {
                    conn.cancel(); return
                }
                var lenLE = UInt32(body.count).littleEndian
                var framed = Data(bytes: &lenLE, count: 4)
                framed.append(body)
                conn.send(content: framed, completion: .contentProcessed { _ in
                    conn.cancel()
                })
            case .failed, .cancelled:
                break
            default:
                break
            }
        }
        conn.start(queue: .global(qos: .utility))
    }

    func sendTunnelStarted() {
        sendEvent(["event": "tunnelStarted"])
    }

    func sendTunnelStopped(code: Int) {
        sendEvent([
            "event": "tunnelStopped",
            "reason": deriveNEProviderStopReason(code: code)
        ])
    }

    func deriveNEProviderStopReason(code: Int) -> String {
        switch code {
            case 0:  return "No specific reason has been given."
            case 1:  return "The user stopped the tunnel."
            case 2:  return "The tunnel failed to function correctly."
            case 3:  return "No network connectivity is currently available."
            case 4:  return "The device’s network connectivity changed."
            case 5:  return "The provider was disabled."
            case 6:  return "The authentication process was canceled."
            case 7:  return "The configuration is invalid."
            case 8:  return "The session timed out."
            case 9:  return "The configuration was disabled."
            case 10: return "The configuration was removed."
            case 11: return "Superseded by a higher-priority configuration."
            case 12: return "The user logged out."
            case 13: return "The current console user changed."
            case 14: return "The connection failed."
            default: return "Unknown reason."
        }
    }
}
