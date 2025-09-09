# HyperSpace Service

This project provides an interface for external applications, such as Java or Python clients, that are running on macOS to create a TUN interface. This project provides a host app (HyperSpace Service) and a system extension (HyperSpace Tunnel) that bridge traffic between your app and Apple's NEPacketTunnelProvider. This interface exposes two loopback TCP servers on 127.0.0.1 for your app to interact with:

- CommandServer (port 5500) – control plane: lifecycle and configuration commands.  
- DataServer (port 5501) – data plane: packet injection and extraction.
*Both servers use a length-prefixed JSON protocol. 

---

## JSON Protocol

The format to encode every JSON message is: 
[4-byte big-endian length][JSON body (UTF-8)]

- The 4-byte header gives the size of the JSON body in bytes.  
- JSON objects are used for all commands, replies, and packet transfer.

---

## Command Plane (Port 5500)

The CommandServer manages the tunnel's lifecycle and configuration. Connect to `127.0.0.1:5500`, send framed JSON commands, and read framed JSON replies.

### Commands

**Load or create a VPN configuration**

 {"cmd":"load"}

**Start the tunnel.** It is required to provide a value for `myIPv4Address`. However, the other parameters are optional.

{"cmd": "start",
 "myIPv4Address": "10.1.0.0",
 "includedRoutes": ["123.123.123.123/32"],
 "excludedRoutes": [],
 "dnsMatches": ["hs"],
 "dnsMap": { "someServer.hs": ["10.1.0.53"] }}

**Stop the tunnel**

{"cmd":"stop"}

**Returns current tunnel status**

{"cmd":"status"}

**Update the tunnel's settings.** The parameters are optional. If no value is provided for a specific parameter, then no change will take place. 

{"cmd": "update",
 "includedRoutes": ["10.1.0.0/24"],
 "excludedRoutes": [],
 "dnsMatches": ["hs"],
 "dnsMap": { "someServer.hs": ["10.1.0.53"] }}

{"cmd": "update",
 "includedRoutes": ["10.1.0.0/24", "10.10.1.250/32"]}

**The replies from the CommandServer will be formated as:**

- Success:
	{"ok": true}
	{"ok": true, "data": { ... }}

- Failure:
	{"ok": false, "error": "Message", "code": 400}

---

## Data Plane (Port 5501)

The DataServer moves raw IP packets between your Java app and the TUN interface. Connect to `127.0.0.1:5501`.

**Java → macOS (Packets to TUN)**
- Single packet:
{"cmd":"packetToTUN","packet":"<base64-encoded-packet>"}
- Multiple packets:
{"cmd":"packetsToTUN","packets":["<b64>","<b64>"]}

**macOS → Java (Packets from TUN)**
- Single packet:
{"cmd":"packetFromTUN","packet":"<b64>"}
- Multiple packets:
{"cmd":"packetsFromTUN","packets":["<b64>","<b64>"]}

---

## Startup

1) Launch the host app. Upon the first launch, a user will be prompted to allow a VPN configuration to be created and to give necessary permissions for the system extension. Once launched, the host app will open ports `5500` and `5501`. From your Java app, connect to port 5500 to issue control commands (load, start, stop, status, update) and connect to port 5501 to send/receive base64-encoded packets.
2) From your Java app, you need to first issue a `load` command. Then, you will need to issue a `start` command. After these commands are successful, your TUN interface is up and running. 
3) Send and receive packets, and update your tunnel settings accordingly.

---

## Java Example

```
import java.io.*;
import java.net.*;
import java.nio.ByteBuffer;

public class ClientExample {
    public static void main(String[] args) throws Exception {
        try (Socket sock = new Socket("127.0.0.1", 5500)) {
            DataOutputStream out = new DataOutputStream(sock.getOutputStream());
            DataInputStream in = new DataInputStream(sock.getInputStream());

            // Example command: status
            String json = "{\"op\":\"status\"}";
            byte[] body = json.getBytes("UTF-8");

            // Write length-prefixed JSON
            ByteBuffer lenBuf = ByteBuffer.allocate(4);
            lenBuf.putInt(body.length);
            out.write(lenBuf.array());
            out.write(body);
            out.flush();

            // Read 4-byte length
            byte[] hdr = in.readNBytes(4);
            int len = ByteBuffer.wrap(hdr).getInt();

            // Read JSON body
            byte[] resp = in.readNBytes(len);
            String reply = new String(resp, "UTF-8");
            System.out.println("Reply: " + reply);
        }
    }
}
```

