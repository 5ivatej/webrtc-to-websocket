# wsrtc

**WebRTC made easy for Flutter — a WebSocket signaling wrapper that handles the hard parts.**

WebRTC is powerful but notoriously hard to set up on mobile. The offer/answer dance, ICE candidate exchange, and signaling server plumbing trips up most developers before they get a single frame of video. `wsrtc` solves this with:

- A **ready-to-deploy Node.js signaling server** (WebSocket, room-based)
- A **Flutter package** that wraps `flutter_webrtc` and handles all negotiation for you
- A clean **event stream API** — just listen for `RoomJoined`, `RemoteStreamAdded`, `DataChannelMessage`, etc.
- **Auto-reconnect**, heartbeats, and graceful teardown built in

```dart
// That's the whole API for a basic video call:
final client = WsRtcClient(config: WsRtcConfig(signalingUrl: 'wss://...'));
await client.connect();
await client.joinRoom('my-room');
client.addStream(localStream);

client.events.listen((event) {
  if (event is RemoteStreamAdded) renderVideo(event.stream);
});
```

---

## Architecture

```
Flutter Client A ──┐                 ┌── Flutter Client B
                   │   WebSocket     │
                   ├──► Signaling ◄──┤   (offer / answer / ICE)
                   │     Server      │
                   │                 │
                   └──────────── WebRTC P2P ──────────────┘
                                (audio / video / data)
```

The signaling server only helps peers find each other. Once the WebRTC handshake completes, all media and data flows **directly between peers** — the signaling server carries zero media traffic.

---

## Quick Start

### 1. Run the signaling server

**Using Docker (recommended):**
```bash
cd server
docker build -t wsrtc-server .
docker run -p 8080:8080 wsrtc-server
```

**Using Node.js directly:**
```bash
cd server
npm install
npm run dev        # development with auto-reload
npm run build && npm start  # production
```

**Environment variables:**

| Variable | Default | Description |
|---|---|---|
| `PORT` | `8080` | WebSocket port |
| `MAX_ROOM_SIZE` | `50` | Max peers per room |
| `VERBOSE` | `true` | Enable request logging |

### 2. Add the Flutter package

```yaml
# pubspec.yaml
dependencies:
  wsrtc:
    git:
      url: https://github.com/your-username/wsrtc.git
      path: flutter_client
```

*(Will be published to pub.dev — then just `wsrtc: ^0.1.0`)*

### 3. Platform setup

Follow the [flutter_webrtc platform setup guide](https://github.com/flutter-webrtc/flutter-webrtc#android) for camera/mic permissions on Android and iOS — wsrtc uses it under the hood.

**Android** — `android/app/src/main/AndroidManifest.xml`:
```xml
<uses-permission android:name="android.permission.CAMERA" />
<uses-permission android:name="android.permission.RECORD_AUDIO" />
<uses-permission android:name="android.permission.INTERNET" />
```

**iOS** — `ios/Runner/Info.plist`:
```xml
<key>NSCameraUsageDescription</key>
<string>Camera access for video calls</string>
<key>NSMicrophoneUsageDescription</key>
<string>Microphone access for voice calls</string>
```

---

## Flutter Usage

### Basic video call

```dart
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:wsrtc/wsrtc.dart';

final client = WsRtcClient(
  config: WsRtcConfig(
    signalingUrl: 'wss://your-signal-server.com',
  ),
);

// 1. Connect and join a room
await client.connect();
await client.joinRoom('room-123');

// 2. Get camera + microphone
final stream = await navigator.mediaDevices.getUserMedia({
  'video': true,
  'audio': true,
});

// 3. Share the stream with all peers in the room
client.addStream(stream);

// 4. Listen for events
client.events.listen((event) {
  switch (event) {
    case RoomJoined e:
      print('Joined ${e.roomId}, peers: ${e.existingPeers}');
    case PeerJoined e:
      print('${e.peerId} joined');
    case PeerLeft e:
      print('${e.peerId} left');
    case RemoteStreamAdded e:
      // Assign e.stream to an RTCVideoRenderer
      remoteRenderer.srcObject = e.stream;
    case DataChannelMessage e:
      print('Message from ${e.peerId}: ${e.message.text}');
    case SignalingError e:
      print('Error: ${e.message}');
    default:
      break;
  }
});
```

### Rendering video

```dart
// Declare renderers
final localRenderer = RTCVideoRenderer();
final remoteRenderer = RTCVideoRenderer();

// Initialize before use
await localRenderer.initialize();
await remoteRenderer.initialize();

// In your widget tree
RTCVideoView(localRenderer, mirror: true)
RTCVideoView(remoteRenderer)

// Always dispose
localRenderer.dispose();
remoteRenderer.dispose();
```

### Data-only mode (no video)

```dart
final client = WsRtcClient(
  config: WsRtcConfig(
    signalingUrl: 'ws://localhost:8080',
    enableDataChannel: true,
    // No addStream() call needed
  ),
);

await client.connect();
await client.joinRoom('chat-room');

// Send to a specific peer
client.sendDataMessage(peerId, 'hello!');

// Broadcast to everyone
client.broadcastDataMessage('hello everyone!');
```

### Audio-only call

```dart
final stream = await navigator.mediaDevices.getUserMedia({
  'video': false,
  'audio': true,
});
client.addStream(stream);
```

### Configuration options

```dart
WsRtcConfig(
  signalingUrl: 'wss://signal.example.com',

  // Custom STUN/TURN servers
  iceServers: [
    {
      'urls': ['stun:stun.example.com:3478'],
    },
    {
      'urls': ['turn:turn.example.com:3478'],
      'username': 'user',
      'credential': 'pass',
    },
  ],

  enableDataChannel: true,       // Create data channels (default: true)
  autoReconnect: true,           // Reconnect on drop (default: true)
  reconnectDelayMs: 3000,        // Delay before reconnect (default: 3000)
  maxVideoBitrateKbps: 1000,     // Cap video bitrate
)
```

---

## WebSocket Message Protocol

If you want to integrate with your own backend or build a client in another language, here is the full protocol.

All messages are JSON. The client always sends to the server; the server relays or responds.

### Client → Server

| Message | Fields | Description |
|---|---|---|
| `join` | `roomId`, `peerId?` | Join or create a room |
| `leave` | — | Leave the current room |
| `offer` | `to`, `sdp` | SDP offer for a peer |
| `answer` | `to`, `sdp` | SDP answer for a peer |
| `ice_candidate` | `to`, `candidate` | ICE candidate for a peer |
| `ping` | — | Heartbeat |

### Server → Client

| Message | Fields | Description |
|---|---|---|
| `connected` | `peerId` | Assigned peer ID on connect |
| `room_joined` | `roomId`, `peerId`, `peers[]` | Confirmation + existing peer list |
| `peer_joined` | `peerId` | A new peer entered the room |
| `peer_left` | `peerId` | A peer disconnected |
| `offer` | `from`, `sdp` | Relayed offer |
| `answer` | `from`, `sdp` | Relayed answer |
| `ice_candidate` | `from`, `candidate` | Relayed ICE candidate |
| `error` | `message` | Something went wrong |
| `pong` | — | Heartbeat reply |

### Example flow

```
Client A → Server:  {"type":"join","roomId":"abc","peerId":"A"}
Server → Client A:  {"type":"room_joined","roomId":"abc","peerId":"A","peers":[]}

Client B → Server:  {"type":"join","roomId":"abc","peerId":"B"}
Server → Client B:  {"type":"room_joined","roomId":"abc","peerId":"B","peers":["A"]}
Server → Client A:  {"type":"peer_joined","peerId":"B"}

Client B → Server:  {"type":"offer","to":"A","sdp":{...}}
Server → Client A:  {"type":"offer","from":"B","sdp":{...}}

Client A → Server:  {"type":"answer","to":"B","sdp":{...}}
Server → Client B:  {"type":"answer","from":"A","sdp":{...}}

Client A → Server:  {"type":"ice_candidate","to":"B","candidate":{...}}
Server → Client B:  {"type":"ice_candidate","from":"A","candidate":{...}}

            ← WebRTC P2P connection established →
```

---

## Deploying the Server

### Railway / Render / Fly.io

All three support deploying from a Dockerfile with zero config. Point them at the `server/` directory.

### Environment variables for production

```bash
PORT=8080
MAX_ROOM_SIZE=50
VERBOSE=false
```

### Nginx reverse proxy (for TLS)

Flutter requires `wss://` (secure WebSocket) in production. Terminate TLS at nginx:

```nginx
server {
    listen 443 ssl;
    server_name signal.example.com;

    ssl_certificate     /etc/letsencrypt/live/signal.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/signal.example.com/privkey.pem;

    location / {
        proxy_pass http://localhost:8080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_read_timeout 86400;
    }
}
```

---

## Repository Structure

```
wsrtc/
├── server/                     # Node.js signaling server
│   ├── src/
│   │   ├── index.ts            # Entry point
│   │   ├── SignalingServer.ts  # Core server logic
│   │   └── Room.ts             # Room + peer management
│   ├── Dockerfile
│   ├── package.json
│   └── tsconfig.json
│
└── flutter_client/             # Flutter package
    ├── lib/
    │   ├── wsrtc.dart          # Package exports
    │   └── src/
    │       ├── wsrtc_client.dart   # Main client class
    │       └── models.dart         # Events + types
    ├── example/
    │   └── lib/main.dart       # Full example app
    └── pubspec.yaml
```

---

## Contributing

PRs welcome! Some ideas for contributions:

- [ ] TURN server provisioning helper
- [ ] Screen sharing support
- [ ] SFU (Selective Forwarding Unit) mode for large rooms
- [ ] Flutter Web support
- [ ] Tests for the signaling server
- [ ] pub.dev publishing

---

## License

MIT