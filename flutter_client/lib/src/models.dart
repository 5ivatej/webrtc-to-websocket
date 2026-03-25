import 'package:flutter_webrtc/flutter_webrtc.dart';

// ─── Enums ────────────────────────────────────────────────────────────────────

enum WsRtcConnectionState {
  /// Not connected to the signaling server.
  disconnected,

  /// WebSocket is connecting.
  connecting,

  /// Connected to the signaling server; not in a room.
  connected,

  /// Joined a room; waiting for other peers.
  inRoom,

  /// An error occurred.
  error,
}

enum PeerConnectionState {
  /// RTCPeerConnection has been created; no negotiation started.
  new_,

  /// Exchanging ICE candidates.
  connecting,

  /// P2P connection established.
  connected,

  /// Connection failed.
  failed,

  /// Connection was closed.
  closed,
}

// ─── Events emitted by WsRtcClient ────────────────────────────────────────────

sealed class WsRtcEvent {}

class SignalingConnected extends WsRtcEvent {
  final String assignedPeerId;
  SignalingConnected(this.assignedPeerId);
}

class SignalingDisconnected extends WsRtcEvent {
  final String? reason;
  SignalingDisconnected({this.reason});
}

class SignalingError extends WsRtcEvent {
  final String message;
  SignalingError(this.message);
}

class RoomJoined extends WsRtcEvent {
  final String roomId;
  final String localPeerId;
  final List<String> existingPeers;
  RoomJoined({
    required this.roomId,
    required this.localPeerId,
    required this.existingPeers,
  });
}

class PeerJoined extends WsRtcEvent {
  final String peerId;
  PeerJoined(this.peerId);
}

class PeerLeft extends WsRtcEvent {
  final String peerId;
  PeerLeft(this.peerId);
}

class PeerConnectionStateChanged extends WsRtcEvent {
  final String peerId;
  final PeerConnectionState state;
  PeerConnectionStateChanged(this.peerId, this.state);
}

class RemoteStreamAdded extends WsRtcEvent {
  final String peerId;
  final MediaStream stream;
  RemoteStreamAdded(this.peerId, this.stream);
}

class RemoteStreamRemoved extends WsRtcEvent {
  final String peerId;
  RemoteStreamRemoved(this.peerId);
}

class DataChannelMessage extends WsRtcEvent {
  final String peerId;
  final RTCDataChannelMessage message;
  DataChannelMessage(this.peerId, this.message);
}

class DataChannelStateChanged extends WsRtcEvent {
  final String peerId;
  final RTCDataChannelState state;
  DataChannelStateChanged(this.peerId, this.state);
}

// ─── Internal signaling messages ──────────────────────────────────────────────

class SignalingMessage {
  final String type;
  final Map<String, dynamic> raw;
  SignalingMessage(this.type, this.raw);

  static SignalingMessage fromJson(Map<String, dynamic> json) =>
      SignalingMessage(json['type'] as String, json);

  String? get from => raw['from'] as String?;
  String? get to => raw['to'] as String?;
  String? get peerId => raw['peerId'] as String?;
  String? get roomId => raw['roomId'] as String?;
  List<String> get peers => (raw['peers'] as List?)?.cast<String>() ?? [];

  Map<String, dynamic>? get sdp =>
      raw['sdp'] != null ? Map<String, dynamic>.from(raw['sdp'] as Map) : null;

  Map<String, dynamic>? get candidate =>
      raw['candidate'] != null
          ? Map<String, dynamic>.from(raw['candidate'] as Map)
          : null;
}