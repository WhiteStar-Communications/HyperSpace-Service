# HyperSpace Service

HyperSpace Service provides a macOS host app (headless agent) and a system extension (HyperSpace Tunnel) that together expose a TUN interface through Apple’s NEPacketTunnelProvider. It allows external apps (Java, Python, etc.) to interact with the tunnel through two local servers:

- CommandServer (TCP, 127.0.0.1:5500) – control plane (lifecycle + configuration, JSON protocol)
- DataServer (UDP, 127.0.0.1:5501) – data plane (raw IPv4 packets)

---

## Command Plane (TCP, Port 5500)

The CommandServer manages the tunnel's lifecycle and configuration. Connect to `127.0.0.1:5500`, send JSON commands, and read JSON replies. The CommandServer recognizes either `\n` or `\r\n` as a delimiter to mark the end of a JSON command.

### Commands

**Load or create a VPN configuration**

 - {"cmd":"load"}

**Start the tunnel.** It is required to provide a value for `myIPv4Address`. However, the other parameters are optional.

- {"cmd": "start",
   "myIPv4Address": "10.1.0.0",
   "includedRoutes": ["123.123.123.123/32"],
   "excludedRoutes": [],
   "dnsMatches": ["hs"],
   "dnsMap": { "someServer.hs": ["10.1.0.53"] }}

**Stop the tunnel**

- {"cmd":"stop"}

**Returns current tunnel status**

- {"cmd":"status"}

**Update the tunnel's settings.** The parameters are optional. If no value is provided for a specific parameter, then no change will take place. 

- {"cmd": "update",
   "includedRoutes": ["10.1.0.0/24"],
   "excludedRoutes": [],
   "dnsMatches": ["hs"],
   "dnsMap": { "someServer.hs": ["10.1.0.53"] }}

- {"cmd": "update",
   "includedRoutes": ["10.1.0.0/24", "10.10.1.250/32"]}

**The replies from the CommandServer will be formated as:**

- Success:
	{"ok": true}
	{"ok": true, "data": { ... }}

- Failure:
	{"ok": false, "error": "Message", "code": 400}

---

## Data Plane (UDP, Port 5501)

- External applications will send packets on port `5501`
- External applications will receive packets on port `5502`
  
The DataServer moves raw IP packets between your external application and the TUN interface. The external application will send raw IPv4 packets as datagrams to `127.0.0.1:5501`. HyperSpace Service validates the datagram and injects it into the TUN interface. Outgoing packets from the TUN interface will be sent to `127.0.0.1:5502`.

---

## Startup

1) Launch the host app. Upon the first launch, a user will be prompted to allow a VPN configuration to be created and to give necessary permissions for the system extension. 
2) From your external app, you need to first issue a `load` command. Then, you will need to issue a `start` command. After these commands are successful, your TUN interface is up and running. 
3) Send and receive packets, and update your tunnel settings accordingly.

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

