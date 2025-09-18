# HyperSpace Service

HyperSpace Service provides a macOS host app (headless agent) and a system extension (HyperSpace Tunnel) that together expose a TUN interface through Apple’s NEPacketTunnelProvider. It allows external apps (Java, Python, etc.) to interact with the tunnel through two local servers:

- CommandServer (TCP, 127.0.0.1:5500) – control plane (lifecycle + configuration, JSON protocol)
- DataServer (UDP, 127.0.0.1:5501) – data plane (raw IPv4 packets)

---

## Command Plane (TCP, Port 5500)

The CommandServer manages the tunnel's lifecycle and configuration. Connect to `127.0.0.1:5500`, send JSON commands, and read JSON replies. The CommandServer recognizes either `\n` or `\r\n` as a delimiter to mark the end of a JSON command.

### Commands

**Starts the tunnel.** It is required to provide a value for `myIPv4Address`. However, the other parameters are optional.

- {"cmd": "start",
   "myIPv4Address": "5.5.5.5",
   "includedRoutes": ["5.5.5.6/32"],
   "excludedRoutes": [],
   "dnsMatches": ["hs"],
   "dnsMap": { "someServer.hs": ["10.1.0.53"] }}

**Stop the tunnel**

- {"cmd":"stop"}

**Add included routes to the TUN interface's routing table**

- {"cmd": "addIncludedRoutes", "routes": ["5.5.5.6"]}

**Remove included routes from the TUN interface's routing table**

- {"cmd": "removeIncludedRoutes", "routes": ["5.5.5.6"]}

**Add excluded routes to the TUN interface's routing table**

- {"cmd": "addExcludedRoutes", "routes": ["5.5.5.6"]}

**Remove excluded routes from the TUN interface's routing table**

- {"cmd": "removeExcludedRoutes", "routes": ["5.5.5.6"]}

**Add DNS match entries used by the TUN interface's internal DNS servers**

- {"cmd": "addDNSMatchEntries", "map": { "someServer.hs": ["10.1.0.53"] }}

**Remove DNS match entries used by the TUN interface's internal DNS servers**

- {"cmd": "removeDNSMatchEntries", "map": { "someServer.hs": ["10.1.0.53"] }}

**Add DNS match domains used by the TUN interface's internal DNS servers**

- {"cmd": "addDNSMatchDomains", "domains": ["hs"]}

**Remove DNS match domains used by the TUN interface's internal DNS servers**

- {"cmd": "removeDNSMatchDomains", "domains": ["hs"]}

**Add internal DNS servers used by the TUN interface**

- {"cmd": "addDNSServers", "servers": ["10.0.1.57"]}

**Remove internal DNS servers used by the TUN interface**

- {"cmd": "removeDNSServers", "servers": ["10.0.1.57"]}

**Returns current tunnel status**

- {"cmd":"status"}

**Get the TUN interface's name**

- {"cmd":"getName"}

**Show the service's version number**

- {"cmd":"showVersion"}

**Shutdown the service**

- {"cmd":"shutdown"}

**Uninstalls the VPN configuration, System Extension, and Host App**

- {"cmd":"uninstall"}

### Server Responses
The command server will return a JSON response after receiving a valid or invalid command. 

**Command responses**
-You will receive `{"ok":true}` if the command sent was valid and successful. The response may have additional data, which will be included in a seperate field. For example, `{"cmd":"status"}` will return `{"ok":true,"status":"connected"}`.

-You will receive `{"ok":false}` if the command is invalid or valid but cannot be executed successfully. Failed command responses also include additional details explaining the error. For example, a valid but unsuccessful command would be sending `{"cmd":"addIncludedRoutes","routes":""}`, which results in `{"ok":false,"error":"No included routes were provided"}`. An invalid command results in `{"ok":false,"error":"unknown cmd"}`.

---

## Data Plane (UDP, Port 5501)

- External applications will send packets on port `5501`
- External applications will receive packets on port `5502`
  
The DataServer moves raw IP packets between your external application and the TUN interface. The external application will send raw IPv4 packets as datagrams to `127.0.0.1:5501`. HyperSpace Service validates the datagram and injects it into the TUN interface. Outgoing packets from the TUN interface will be sent to `127.0.0.1:5502`.

---

## Startup

1) Launch the host app. Upon the first launch, a user will be prompted to allow a VPN configuration to be created and to give necessary permissions for the system extension. 
2) From your external app, you will need to issue a successful `start` command. Upon completion of the command, your TUN interface is up and running. Use the commands `addIncludedRoutes`, `removeIncludedRoutes`, `addExcludedRoutes`, `removeExcludedRoutes`, `addDNSMatchEntries`, `removeDNSMatchEntries`, `addDNSMatchDomains`, `removeDNSMatchDomains`, `addDNSServers`, and `removeDNSServers` to configure the TUN interface to your specific requirements.
3) Once the TUN interface is running and initially configured, send and receive packets via the DataServer. Update any configurations as your requirements change.

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

