# HyperSpace Service

HyperSpace Service provides a macOS host app (headless agent) and a system extension (HyperSpace Tunnel) that together expose a TUN interface through Apple’s NEPacketTunnelProvider. It allows external apps (Java, Python, etc.) to interact with the tunnel through two local servers:

- Command Server (TCP, 127.0.0.1:5500) – control plane (lifecycle + configuration, JSON protocol)
- Data Server (UDP, 127.0.0.1:5501) – data plane (raw IPv4/IPv6 packets)

---

## Command Plane (TCP, Port 5500)

The Command Server manages the TUN interface's lifecycle and configuration. Connect to `127.0.0.1:5500`, send JSON commands, and read JSON replies. The Command Server recognizes either `\n` or `\r\n` as a delimiter to mark the end of a JSON command. When you first connect to the Command Server, you will receive the status of the VPN configuration and network extension permissions. For the VPN configuration, you will receive either a `vpnPending` or `vpnApproved` tunnel event. For the network extension, you will receive either an `extensionNotApproved` or `extensionApproved` tunnel event.

### Commands

**Start the TUN interface**. The value provided for `myIPv4Address` will be used as the TUN interface's address.

- {"cmd": "start", "myIPv4Address": "5.5.5.5"}

**Shutdowns the host app and the TUN interface**. This command is issued automatically when you disconnect from the established TCP connection to the Command Server.

- {"cmd":"shutdown"}

**Show the Add VPN Configuration permission window, if not already allowed**

- {"cmd":"loadConfig"}

**Show the Use a New Network Extension permission window, if not already allowed**

- {"cmd":"loadExtension"}

**Bring the Login Items and Extensions settings screen to the foreground**

- {"cmd":"openExtensionSettings"}

**Add included routes to the TUN interface's routing table**

- {"cmd": "addIncludedRoutes", "routes": ["5.5.5.6"]}

**Remove included routes from the TUN interface's routing table**

- {"cmd": "removeIncludedRoutes", "routes": ["5.5.5.6"]}

**Add excluded routes to the TUN interface's routing table**

- {"cmd": "addExcludedRoutes", "routes": ["5.5.5.6"]}

**Remove excluded routes from the TUN interface's routing table**

- {"cmd": "removeExcludedRoutes", "routes": ["5.5.5.6"]}

**Turns on capturing all DNS traffic**

- {"cmd":"turnOnDNS"}

**Turns off capturing all DNS traffic**

- {"cmd":"turnOffDNS"}

**Returns current tunnel status**

- {"cmd":"status"}

**Get the TUN interface's name**

- {"cmd":"getName"}

**Show the current version number**

- {"cmd":"showVersion"}

**Uninstalls the VPN configuration, System Extension(TUN interface), and Host App**

- {"cmd":"uninstall"}

### Command Responses
The command server will return a JSON response after receiving a valid or invalid command. 

- You will receive `{"ok":true}` if the command sent was valid and successful. The commands `getName`, `status`, and `showVersion` will return additional data. The command `status` will return a response like `{"ok":true,"status":"connected"}`. The `status` will be either `connected`, `disconnected`, `connecting`, `disconnecting`,`invalid`, `reasserting`, or `unknown`. The command `getName` will return a response like `{"ok":true,"name":"utun8"}`. The command `showVersion` will return a response like `{"ok":true,"version":"1.0.6"}`.

- You will receive `{"ok":false}` if the command is invalid or valid but cannot be executed successfully. Failed command responses also include additional details explaining the error. For example, a valid but unsuccessful command would be sending `{"cmd":"addIncludedRoutes","routes":""}`, which results in `{"ok":false,"error":"No included routes were provided"}`. An invalid command results in `{"ok":false,"error":"unknown cmd"}`.

### Tunnel Events

The command server will return a JSON response for specifc events. 
- If a user approves the VPN configuration, you will receive `{"cmd":"event", "event":"vpnApproved"}`. If a user denies the VPN configuration, you will receive `{"cmd":"event", "event":"vpnDenied"}`. When you create a valid TCP connection to the Command Server, it will send you either `{"cmd":"event", "event":"vpnPending"}` or `{"cmd":"event", "event":"vpnApproved"}`.
- If a user approves the network extension, you will receive `{"cmd":"event", "event":"extensionApproved"}`. When you create a valid TCP connection to the Command Server, it will send you either `{"cmd":"event", "event":"extensionNotApproved"}` or `{"cmd":"event", "event":"extensionApproved"}`.
- When the tunnel starts, you will receive `{"cmd":"event", "event":"tunnelStarted"}`.
- When the tunnel stops, you will receive an event similar to `{"cmd":"event", "event":"tunnelStopped", "reason":"providerDisabled"}`. There are various reasons on why the tunnel has stopped, and a reason will be provided in the event. The following reasons will trigger a tunnelStopped event:
    - stoppedByUser
    - tunnelFailed
    - noConnectivity
    - connectivityChanged
    - providerDisabled
    - authenticationCancelled
    - invalidVPN
    - timedOut
    - vpnDisabled
    - vpnRemoved
    - superseded
    - loggedOut
    - currentUserchanged
    - connectionFailed
    - noReason
    - unknown
⚠️ **Warning:** In almost all cases, it is highly recommended that you issue a `shutdown` command, OR disconnect from the established TCP connection to the Command Server, which automatically executes a `shutdown` command. Then once shutting down, relaunch the service. For a lot of the tunnelStopped events, the TUN interface cannot be recovered without shutting down then relaunching.

- In addition to the tunnelStopped events, there is a monitor that checks for a valid VPN configuration. Some actions such as deleting the network extension, disabling the Network Extension, and deleting the VPN configuration, can get you into a state where there no longer is a valid VPN configuration for the app to use. In this event, you will receive `{"cmd":"event", "event":"vpnRemoved"}`.
⚠️ **Warning:** It is also highly recommended that you shutdown then relaunch the service for these events. Some actions will trigger both a `tunnelStopped` event and a `vpnRemoved` event.

---

## Data Plane (UDP, Port 5501)

- External applications will send packets on port `5501`
- External applications will receive packets on port `5502`
- All DNS queries are captured and forwarded to your external application for processing. This behavior can be toggled on and off using the `turnOnDNS` and `turnOffDNS` commands.
  
The Data Server moves raw IP packets between your external application and the TUN interface. The external application will send raw IPv4 packets as datagrams to `127.0.0.1:5501`. HyperSpace Service validates the datagram and injects it into the TUN interface. Outgoing packets from the TUN interface will be sent to `127.0.0.1:5502`.

---

## Startup

1) Launch the host app. Upon first launch, a user will be required to give permissions for the VPN configuration and system extension to be created. It is recommended to wait for the `vpnApproved` and `extensionApproved` events before proceeding.
2) From your external app, you will need to issue a successful `start` command.
3) After issuing a successful `start` command , your TUN interface is running. Use the commands `addIncludedRoutes`, `removeIncludedRoutes`, `addExcludedRoutes`, and `removeExcludedRoutes` to configure the TUN interface's routing table.
4) Once the TUN interface is running and configured, send and receive packets via the Data Server.

---

## Java Example

```
import java.io.*;
import java.net.*;

public class ClientExample {
    public static void main(String[] args) throws Exception {
        try (Socket sock = new Socket("127.0.0.1", 5500)) {
            // Writers/Readers with UTF-8 encoding
            BufferedWriter out = new BufferedWriter(
                new OutputStreamWriter(sock.getOutputStream(), "UTF-8")
            );
            BufferedReader in = new BufferedReader(
                new InputStreamReader(sock.getInputStream(), "UTF-8")
            );

            // Example command: status
            String json = "{\"op\":\"status\"}";

            // Send JSON with delimiter (\n or \r\n)
            out.write(json);
            out.write("\r\n");
            out.flush();

            // Read reply until delimiter
            String reply = in.readLine();
            if (reply != null) {
                System.out.println("Reply: " + reply);
            } else {
                System.out.println("No reply received.");
            }
        }
    }
}
```

