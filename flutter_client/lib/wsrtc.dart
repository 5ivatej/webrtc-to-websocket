/// wsrtc — WebRTC made easy for Flutter.
///
/// Drop-in WebSocket signaling wrapper for flutter_webrtc.
/// Handles offer/answer negotiation, ICE candidate exchange,
/// and room-based peer discovery so you don't have to.
///
/// Quick start:
/// ```dart
/// import 'package:wsrtc/wsrtc.dart';
///
/// final client = WsRtcClient(
///   config: WsRtcConfig(signalingUrl: 'wss://your-server.com'),
/// );
///
/// await client.connect();
/// await client.joinRoom('my-room');
///
/// client.events.listen((event) {
///   switch (event) {
///     case RoomJoined e:
///       print('Joined ${e.roomId} with peers: ${e.existingPeers}');
///     case RemoteStreamAdded e:
///       // render e.stream in an RTCVideoRenderer
///     case DataChannelMessage e:
///       print('${e.peerId}: ${e.message.text}');
///     default: break;
///   }
/// });
/// ```
library wsrtc;

export 'src/models.dart';
export 'src/wsrtc_client.dart';