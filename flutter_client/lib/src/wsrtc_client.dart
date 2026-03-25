import 'dart:async';
import 'dart:convert';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'models.dart';

// ─── Configuration ────────────────────────────────────────────────────────────

/// Configuration for a [WsRtcClient].
class WsRtcConfig {
  /// WebSocket URL of your wsrtc signaling server.
  /// e.g. `ws://localhost:8080` or `wss://signal.example.com`
  final String signalingUrl;

  /// ICE servers used by WebRTC (STUN / TURN).
  /// Defaults to Google's public STUN server.
  final List<Map<String, dynamic>> iceServers;

  /// Whether to create a data channel on every peer connection.
  final bool enableDataChannel;

  /// Maximum bitrate for video in kbps (null = unlimited).
  final int? maxVideoBitrateKbps;

  /// Reconnect on unexpected WebSocket close. Defaults to true.
  final bool autoReconnect;

  /// Milliseconds between reconnect attempts. Defaults to 3000.
  final int reconnectDelayMs;

  const WsRtcConfig({
    required this.signalingUrl,
    this.iceServers = const [
      {
        'urls': ['stun:stun.l.google.com:19302', 'stun:stun1.l.google.com:19302'],
      }
    ],
    this.enableDataChannel = true,
    this.maxVideoBitrateKbps,
    this.autoReconnect = true,
    this.reconnectDelayMs = 3000,
  });
}

// ─── WsRtcClient ──────────────────────────────────────────────────────────────

/// The main entry point for wsrtc.
///
/// Usage:
/// ```dart
/// final client = WsRtcClient(config: WsRtcConfig(signalingUrl: 'ws://...'));
/// await client.connect();
/// await client.joinRoom('my-room');
/// client.events.listen((event) { ... });
/// ```
class WsRtcClient {
  final WsRtcConfig config;

  WsRtcClient({required this.config});

  // ─── State ─────────────────────────────────────────────────────────────────

  String _localPeerId = const Uuid().v4();
  String? _currentRoomId;
  WsRtcConnectionState _connectionState = WsRtcConnectionState.disconnected;

  WebSocketChannel? _channel;
  StreamSubscription? _wsSubscription;
  Timer? _reconnectTimer;
  bool _manualDisconnect = false;

  /// Active RTCPeerConnections keyed by remote peer ID.
  final Map<String, RTCPeerConnection> _peerConnections = {};

  /// Data channels keyed by remote peer ID.
  final Map<String, RTCDataChannel> _dataChannels = {};

  // ─── Public streams ────────────────────────────────────────────────────────

  final StreamController<WsRtcEvent> _eventController =
      StreamController.broadcast();

  /// Stream of [WsRtcEvent]s. Listen here for all signaling and peer events.
  Stream<WsRtcEvent> get events => _eventController.stream;

  String get localPeerId => _localPeerId;
  String? get currentRoomId => _currentRoomId;
  WsRtcConnectionState get connectionState => _connectionState;
  List<String> get connectedPeers => List.unmodifiable(_peerConnections.keys);

  // ─── Connect / Disconnect ──────────────────────────────────────────────────

  /// Connect to the signaling server.
  Future<void> connect() async {
    if (_connectionState == WsRtcConnectionState.connecting ||
        _connectionState == WsRtcConnectionState.connected ||
        _connectionState == WsRtcConnectionState.inRoom) {
      return;
    }

    _manualDisconnect = false;
    _setConnectionState(WsRtcConnectionState.connecting);

    try {
      _channel = WebSocketChannel.connect(Uri.parse(config.signalingUrl));
      await _channel!.ready;

      _setConnectionState(WsRtcConnectionState.connected);

      _wsSubscription = _channel!.stream.listen(
        _onWsMessage,
        onError: _onWsError,
        onDone: _onWsDone,
      );
    } catch (e) {
      _setConnectionState(WsRtcConnectionState.error);
      _emit(SignalingError('Failed to connect: $e'));
      _scheduleReconnect();
    }
  }

  /// Disconnect from the signaling server and close all peer connections.
  Future<void> disconnect() async {
    _manualDisconnect = true;
    _reconnectTimer?.cancel();
    await _leaveRoom();
    await _channel?.sink.close();
    _setConnectionState(WsRtcConnectionState.disconnected);
    _emit(SignalingDisconnected());
  }

  // ─── Room management ───────────────────────────────────────────────────────

  /// Join a room. Will auto-connect to the signaling server if not already.
  ///
  /// When other peers are already in the room, this client will initiate
  /// offers to each of them automatically.
  Future<void> joinRoom(String roomId) async {
    if (_connectionState == WsRtcConnectionState.disconnected ||
        _connectionState == WsRtcConnectionState.error) {
      await connect();
    }
    _currentRoomId = roomId;
    _send({'type': 'join', 'roomId': roomId, 'peerId': _localPeerId});
  }

  /// Leave the current room without disconnecting from the server.
  Future<void> leaveRoom() async {
    await _leaveRoom();
  }

  Future<void> _leaveRoom() async {
    if (_currentRoomId == null) return;
    _send({'type': 'leave'});
    await _closeAllPeerConnections();
    _currentRoomId = null;
    _setConnectionState(WsRtcConnectionState.connected);
  }

  // ─── Media ─────────────────────────────────────────────────────────────────

  /// Add a local [MediaStream] (audio/video) to all existing peer connections.
  /// Call this after joining a room.
  void addStream(MediaStream stream) {
    for (final pc in _peerConnections.values) {
      _addStreamToPc(pc, stream);
    }
  }

  void _addStreamToPc(RTCPeerConnection pc, MediaStream stream) {
    stream.getTracks().forEach((track) {
      pc.addTrack(track, stream);
    });
  }

  // ─── Data channel ──────────────────────────────────────────────────────────

  /// Send a text message to a specific peer via the data channel.
  bool sendDataMessage(String peerId, String message) {
    final dc = _dataChannels[peerId];
    if (dc == null || dc.state != RTCDataChannelState.RTCDataChannelOpen) {
      return false;
    }
    dc.send(RTCDataChannelMessage(message));
    return true;
  }

  /// Broadcast a text message to all peers via their data channels.
  void broadcastDataMessage(String message) {
    for (final peerId in _dataChannels.keys) {
      sendDataMessage(peerId, message);
    }
  }

  // ─── WebSocket inbound ─────────────────────────────────────────────────────

  void _onWsMessage(dynamic raw) {
    final Map<String, dynamic> json;
    try {
      json = jsonDecode(raw as String) as Map<String, dynamic>;
    } catch (_) {
      return;
    }

    final msg = SignalingMessage.fromJson(json);

    switch (msg.type) {
      case 'connected':
        if (msg.peerId != null) _localPeerId = msg.peerId!;
        _emit(SignalingConnected(_localPeerId));

      case 'room_joined':
        _setConnectionState(WsRtcConnectionState.inRoom);
        _emit(RoomJoined(
          roomId: msg.roomId ?? _currentRoomId!,
          localPeerId: _localPeerId,
          existingPeers: msg.peers,
        ));
        // Initiate offers to all peers already in the room
        for (final peerId in msg.peers) {
          _initiateConnection(peerId);
        }

      case 'peer_joined':
        if (msg.peerId != null) {
          _emit(PeerJoined(msg.peerId!));
          // The new peer will receive an offer from us (the existing peer)
          _initiateConnection(msg.peerId!);
        }

      case 'peer_left':
        if (msg.peerId != null) {
          _closePeerConnection(msg.peerId!);
          _emit(PeerLeft(msg.peerId!));
        }

      case 'offer':
        if (msg.from != null && msg.sdp != null) {
          _handleOffer(msg.from!, msg.sdp!);
        }

      case 'answer':
        if (msg.from != null && msg.sdp != null) {
          _handleAnswer(msg.from!, msg.sdp!);
        }

      case 'ice_candidate':
        if (msg.from != null && msg.candidate != null) {
          _handleIceCandidate(msg.from!, msg.candidate!);
        }

      case 'error':
        _emit(SignalingError(json['message'] as String? ?? 'Unknown error'));

      case 'pong':
        // heartbeat reply — no-op
        break;
    }
  }

  void _onWsError(Object error) {
    _emit(SignalingError('WebSocket error: $error'));
    _setConnectionState(WsRtcConnectionState.error);
    _scheduleReconnect();
  }

  void _onWsDone() {
    if (_manualDisconnect) return;
    _emit(SignalingDisconnected(reason: 'Connection closed unexpectedly'));
    _setConnectionState(WsRtcConnectionState.disconnected);
    _scheduleReconnect();
  }

  // ─── WebRTC negotiation ────────────────────────────────────────────────────

  Future<RTCPeerConnection> _getOrCreatePc(String peerId) async {
    if (_peerConnections.containsKey(peerId)) {
      return _peerConnections[peerId]!;
    }

    final pc = await createPeerConnection({
      'iceServers': config.iceServers,
      'sdpSemantics': 'unified-plan',
    });

    _peerConnections[peerId] = pc;

    pc.onIceCandidate = (candidate) {
      _send({
        'type': 'ice_candidate',
        'to': peerId,
        'candidate': candidate.toMap(),
      });
    };

    pc.onConnectionState = (state) {
      final mapped = _mapConnectionState(state);
      _emit(PeerConnectionStateChanged(peerId, mapped));
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        _closePeerConnection(peerId);
      }
    };

    pc.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        _emit(RemoteStreamAdded(peerId, event.streams[0]));
      }
    };

    if (config.enableDataChannel) {
      pc.onDataChannel = (channel) {
        _setupDataChannel(peerId, channel);
      };
    }

    return pc;
  }

  Future<void> _initiateConnection(String remotePeerId) async {
    final pc = await _getOrCreatePc(remotePeerId);

    if (config.enableDataChannel) {
      final dc = await pc.createDataChannel(
        'wsrtc',
        RTCDataChannelInit()..ordered = true,
      );
      _setupDataChannel(remotePeerId, dc);
    }

    final offer = await pc.createOffer();
    await pc.setLocalDescription(offer);

    _send({
      'type': 'offer',
      'to': remotePeerId,
      'sdp': offer.toMap(),
    });
  }

  Future<void> _handleOffer(
    String fromPeerId,
    Map<String, dynamic> sdpMap,
  ) async {
    final pc = await _getOrCreatePc(fromPeerId);

    await pc.setRemoteDescription(
      RTCSessionDescription(sdpMap['sdp'] as String?, sdpMap['type'] as String?),
    );

    final answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);

    _send({
      'type': 'answer',
      'to': fromPeerId,
      'sdp': answer.toMap(),
    });
  }

  Future<void> _handleAnswer(
    String fromPeerId,
    Map<String, dynamic> sdpMap,
  ) async {
    final pc = _peerConnections[fromPeerId];
    if (pc == null) return;

    await pc.setRemoteDescription(
      RTCSessionDescription(sdpMap['sdp'] as String?, sdpMap['type'] as String?),
    );
  }

  Future<void> _handleIceCandidate(
    String fromPeerId,
    Map<String, dynamic> candidateMap,
  ) async {
    final pc = _peerConnections[fromPeerId];
    if (pc == null) return;

    await pc.addCandidate(
      RTCIceCandidate(
        candidateMap['candidate'] as String?,
        candidateMap['sdpMid'] as String?,
        candidateMap['sdpMLineIndex'] as int?,
      ),
    );
  }

  // ─── Data channel setup ────────────────────────────────────────────────────

  void _setupDataChannel(String peerId, RTCDataChannel channel) {
    _dataChannels[peerId] = channel;

    channel.onDataChannelState = (state) {
      _emit(DataChannelStateChanged(peerId, state));
    };

    channel.onMessage = (msg) {
      _emit(DataChannelMessage(peerId, msg));
    };
  }

  // ─── Cleanup ───────────────────────────────────────────────────────────────

  Future<void> _closePeerConnection(String peerId) async {
    _dataChannels.remove(peerId)?.close();
    final pc = _peerConnections.remove(peerId);
    if (pc != null) await pc.close();
    _emit(RemoteStreamRemoved(peerId));
  }

  Future<void> _closeAllPeerConnections() async {
    final peers = List<String>.from(_peerConnections.keys);
    for (final peerId in peers) {
      await _closePeerConnection(peerId);
    }
  }

  /// Dispose the client — close all connections and free resources.
  Future<void> dispose() async {
    await disconnect();
    await _eventController.close();
  }

  // ─── Utility ───────────────────────────────────────────────────────────────

  void _send(Map<String, dynamic> message) {
    if (_channel != null) {
      _channel!.sink.add(jsonEncode(message));
    }
  }

  void _emit(WsRtcEvent event) {
    if (!_eventController.isClosed) {
      _eventController.add(event);
    }
  }

  void _setConnectionState(WsRtcConnectionState state) {
    _connectionState = state;
  }

  void _scheduleReconnect() {
    if (_manualDisconnect || !config.autoReconnect) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(
      Duration(milliseconds: config.reconnectDelayMs),
      () async {
        if (!_manualDisconnect) {
          await connect();
          if (_currentRoomId != null) await joinRoom(_currentRoomId!);
        }
      },
    );
  }

  PeerConnectionState _mapConnectionState(RTCPeerConnectionState state) {
    return switch (state) {
      RTCPeerConnectionState.RTCPeerConnectionStateNew => PeerConnectionState.new_,
      RTCPeerConnectionState.RTCPeerConnectionStateConnecting =>
        PeerConnectionState.connecting,
      RTCPeerConnectionState.RTCPeerConnectionStateConnected =>
        PeerConnectionState.connected,
      RTCPeerConnectionState.RTCPeerConnectionStateFailed =>
        PeerConnectionState.failed,
      RTCPeerConnectionState.RTCPeerConnectionStateClosed =>
        PeerConnectionState.closed,
      _ => PeerConnectionState.new_,
    };
  }
}