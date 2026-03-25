import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:wsrtc/wsrtc.dart';

void main() => runApp(const WsRtcExampleApp());

class WsRtcExampleApp extends StatelessWidget {
  const WsRtcExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'wsrtc Example',
      theme: ThemeData.dark(useMaterial3: true),
      home: const CallScreen(),
    );
  }
}

// ─── CallScreen ───────────────────────────────────────────────────────────────

class CallScreen extends StatefulWidget {
  const CallScreen({super.key});

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  late final WsRtcClient _client;

  // Local camera
  MediaStream? _localStream;
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();

  // Remote peers: peerId → renderer
  final Map<String, RTCVideoRenderer> _remoteRenderers = {};

  // Data channel chat log
  final List<String> _messages = [];
  final TextEditingController _msgCtrl = TextEditingController();

  // UI state
  String _status = 'Not connected';
  final _roomCtrl = TextEditingController(text: 'demo-room');

  @override
  void initState() {
    super.initState();
    _localRenderer.initialize();
    _setupClient();
  }

  void _setupClient() {
    _client = WsRtcClient(
      config: WsRtcConfig(
        // Change to your server address
        signalingUrl: 'ws://localhost:8080',
        enableDataChannel: true,
      ),
    );

    _client.events.listen(_onEvent);
  }

  void _onEvent(WsRtcEvent event) {
    switch (event) {
      case SignalingConnected e:
        _setStatus('Connected (${e.assignedPeerId})');

      case SignalingDisconnected e:
        _setStatus('Disconnected${e.reason != null ? ': ${e.reason}' : ''}');

      case SignalingError e:
        _setStatus('Error: ${e.message}');

      case RoomJoined e:
        _setStatus('Room: ${e.roomId} · peers: ${e.existingPeers.length}');

      case PeerJoined e:
        _setStatus('${e.peerId} joined');
        _addRemoteRenderer(e.peerId);

      case PeerLeft e:
        _setStatus('${e.peerId} left');
        _removeRemoteRenderer(e.peerId);

      case RemoteStreamAdded e:
        _setRemoteStream(e.peerId, e.stream);

      case RemoteStreamRemoved e:
        _removeRemoteRenderer(e.peerId);

      case DataChannelMessage e:
        setState(() => _messages.add('${e.peerId}: ${e.message.text}'));

      default:
        break;
    }
  }

  Future<void> _joinRoom() async {
    // Get camera + mic
    _localStream = await navigator.mediaDevices.getUserMedia({
      'video': {'facingMode': 'user'},
      'audio': true,
    });
    _localRenderer.srcObject = _localStream;

    await _client.connect();
    await _client.joinRoom(_roomCtrl.text.trim());

    // Add the local stream to all new peer connections
    _client.addStream(_localStream!);

    setState(() {});
  }

  Future<void> _leaveRoom() async {
    await _client.leaveRoom();
    _localStream?.dispose();
    _localStream = null;
    _localRenderer.srcObject = null;

    for (final r in _remoteRenderers.values) {
      r.dispose();
    }
    _remoteRenderers.clear();
    setState(() {});
  }

  void _addRemoteRenderer(String peerId) async {
    final renderer = RTCVideoRenderer();
    await renderer.initialize();
    setState(() => _remoteRenderers[peerId] = renderer);
  }

  void _removeRemoteRenderer(String peerId) {
    final r = _remoteRenderers.remove(peerId);
    r?.dispose();
    setState(() {});
  }

  void _setRemoteStream(String peerId, MediaStream stream) {
    final r = _remoteRenderers[peerId];
    if (r != null) {
      r.srcObject = stream;
      setState(() {});
    }
  }

  void _setStatus(String status) => setState(() => _status = status);

  void _sendMessage() {
    final text = _msgCtrl.text.trim();
    if (text.isEmpty) return;
    _client.broadcastDataMessage(text);
    setState(() => _messages.add('Me: $text'));
    _msgCtrl.clear();
  }

  @override
  void dispose() {
    _client.dispose();
    _localRenderer.dispose();
    for (final r in _remoteRenderers.values) {
      r.dispose();
    }
    _msgCtrl.dispose();
    _roomCtrl.dispose();
    super.dispose();
  }

  // ─── UI ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final inRoom = _client.connectionState == WsRtcConnectionState.inRoom;

    return Scaffold(
      appBar: AppBar(title: const Text('wsrtc example'), centerTitle: true),
      body: Column(
        children: [
          // Status bar
          Container(
            width: double.infinity,
            color: Colors.black26,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(_status,
                style: const TextStyle(fontSize: 12, color: Colors.white70)),
          ),

          // Room controls
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _roomCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Room ID',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    enabled: !inRoom,
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: inRoom ? _leaveRoom : _joinRoom,
                  child: Text(inRoom ? 'Leave' : 'Join'),
                ),
              ],
            ),
          ),

          // Video grid
          Expanded(
            child: inRoom
                ? _VideoGrid(
                    localRenderer: _localRenderer,
                    remoteRenderers: _remoteRenderers,
                  )
                : const Center(
                    child: Text('Enter a room ID and tap Join',
                        style: TextStyle(color: Colors.white54)),
                  ),
          ),

          // Chat
          if (inRoom) ...[
            const Divider(height: 1),
            SizedBox(
              height: 140,
              child: Column(
                children: [
                  Expanded(
                    child: ListView.builder(
                      padding: const EdgeInsets.all(8),
                      itemCount: _messages.length,
                      itemBuilder: (_, i) => Text(_messages[i],
                          style: const TextStyle(fontSize: 13)),
                    ),
                  ),
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _msgCtrl,
                            decoration: const InputDecoration(
                              hintText: 'Message',
                              isDense: true,
                              border: OutlineInputBorder(),
                            ),
                            onSubmitted: (_) => _sendMessage(),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.send),
                          onPressed: _sendMessage,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ─── Video grid ───────────────────────────────────────────────────────────────

class _VideoGrid extends StatelessWidget {
  final RTCVideoRenderer localRenderer;
  final Map<String, RTCVideoRenderer> remoteRenderers;

  const _VideoGrid({
    required this.localRenderer,
    required this.remoteRenderers,
  });

  @override
  Widget build(BuildContext context) {
    final all = [
      _VideoTile(renderer: localRenderer, label: 'You', isLocal: true),
      ...remoteRenderers.entries.map(
        (e) => _VideoTile(
          renderer: e.value,
          label: e.key.substring(0, 8),
          isLocal: false,
        ),
      ),
    ];

    return GridView.count(
      crossAxisCount: all.length > 2 ? 2 : 1,
      children: all,
    );
  }
}

class _VideoTile extends StatelessWidget {
  final RTCVideoRenderer renderer;
  final String label;
  final bool isLocal;

  const _VideoTile({
    required this.renderer,
    required this.label,
    required this.isLocal,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        RTCVideoView(
          renderer,
          mirror: isLocal,
          objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
        ),
        Positioned(
          left: 8,
          bottom: 8,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(label,
                style:
                    const TextStyle(color: Colors.white, fontSize: 12)),
          ),
        ),
      ],
    );
  }
}