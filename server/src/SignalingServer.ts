import { WebSocketServer, WebSocket } from "ws";
import { v4 as uuidv4 } from "uuid";
import { Room, type Peer } from "./Room.js";

// ─── Message types ────────────────────────────────────────────────────────────

type MessageType =
  | "join"
  | "leave"
  | "offer"
  | "answer"
  | "ice_candidate"
  | "ping";

interface BaseMessage {
  type: MessageType;
}

interface JoinMessage extends BaseMessage {
  type: "join";
  roomId: string;
  peerId?: string; // optional — server assigns one if omitted
}

interface LeaveMessage extends BaseMessage {
  type: "leave";
}

interface RelayMessage extends BaseMessage {
  type: "offer" | "answer";
  to: string;
  sdp: RTCSdpInit;
}

interface IceCandidateMessage extends BaseMessage {
  type: "ice_candidate";
  to: string;
  candidate: RTCIceCandidateInit;
}

interface PingMessage extends BaseMessage {
  type: "ping";
}

type IncomingMessage =
  | JoinMessage
  | LeaveMessage
  | RelayMessage
  | IceCandidateMessage
  | PingMessage;

// ─── RTCIceCandidateInit / RTCSdpInit stubs (not available in Node) ───────────
interface RTCSdpInit {
  type: string;
  sdp?: string;
}
interface RTCIceCandidateInit {
  candidate?: string;
  sdpMid?: string | null;
  sdpMLineIndex?: number | null;
  usernameFragment?: string | null;
}

// ─── Server ───────────────────────────────────────────────────────────────────

export interface SignalingServerOptions {
  port?: number;
  maxRoomSize?: number;
  heartbeatIntervalMs?: number;
  verbose?: boolean;
}

export class SignalingServer {
  private wss: WebSocketServer;
  private rooms: Map<string, Room> = new Map();
  private peerToRoom: Map<string, string> = new Map();
  private readonly maxRoomSize: number;
  private readonly verbose: boolean;
  private heartbeatTimer?: NodeJS.Timeout;

  constructor(private readonly options: SignalingServerOptions = {}) {
    const {
      port = 8080,
      maxRoomSize = 50,
      heartbeatIntervalMs = 30_000,
      verbose = true,
    } = options;

    this.maxRoomSize = maxRoomSize;
    this.verbose = verbose;

    this.wss = new WebSocketServer({ port });
    this.wss.on("connection", (ws) => this.onConnection(ws));
    this.wss.on("listening", () =>
      this.log(`wsrtc signaling server listening on ws://localhost:${port}`)
    );

    this.heartbeatTimer = setInterval(
      () => this.runHeartbeat(),
      heartbeatIntervalMs
    );
  }

  // ─── Connection lifecycle ──────────────────────────────────────────────────

  private onConnection(ws: WebSocket & { isAlive?: boolean }): void {
    const peer: Peer = {
      id: uuidv4(),
      ws,
      roomId: null,
      joinedAt: new Date(),
    };

    ws.isAlive = true;
    ws.on("pong", () => {
      (ws as WebSocket & { isAlive?: boolean }).isAlive = true;
    });

    this.log(`[connect] peer ${peer.id}`);

    ws.on("message", (raw) => {
      try {
        const msg = JSON.parse(raw.toString()) as IncomingMessage;
        this.handleMessage(peer, msg);
      } catch {
        this.sendError(ws, "Invalid JSON");
      }
    });

    ws.on("close", () => this.onClose(peer));
    ws.on("error", (err) =>
      this.log(`[error] peer ${peer.id}: ${err.message}`)
    );

    // Notify the peer of their assigned ID immediately
    this.send(ws, { type: "connected", peerId: peer.id });
  }

  private onClose(peer: Peer): void {
    this.log(`[disconnect] peer ${peer.id}`);
    this.leavePeer(peer);
  }

  // ─── Message routing ───────────────────────────────────────────────────────

  private handleMessage(peer: Peer, msg: IncomingMessage): void {
    switch (msg.type) {
      case "join":
        return this.handleJoin(peer, msg);
      case "leave":
        return this.leavePeer(peer);
      case "offer":
      case "answer":
        return this.handleRelay(peer, msg);
      case "ice_candidate":
        return this.handleIceCandidate(peer, msg);
      case "ping":
        return this.send(peer.ws, { type: "pong" });
      default: {
        const exhaustive: never = msg;
        this.sendError(peer.ws, `Unknown message type: ${(exhaustive as BaseMessage).type}`);
      }
    }
  }

  private handleJoin(peer: Peer, msg: JoinMessage): void {
    const roomId = msg.roomId?.trim();
    if (!roomId) {
      return this.sendError(peer.ws, "roomId is required");
    }

    // Leave any existing room first
    if (peer.roomId) this.leavePeer(peer);

    let room = this.rooms.get(roomId);
    if (!room) {
      room = new Room(roomId);
      this.rooms.set(roomId, room);
    }

    if (room.size() >= this.maxRoomSize) {
      return this.sendError(peer.ws, `Room ${roomId} is full (max ${this.maxRoomSize})`);
    }

    // Override peerId if client supplied one, otherwise keep the server-assigned UUID
    if (msg.peerId && !room.has(msg.peerId)) {
      peer.id = msg.peerId;
    }

    room.add(peer);
    peer.roomId = roomId;
    this.peerToRoom.set(peer.id, roomId);

    this.log(`[join] peer ${peer.id} → room ${roomId} (${room.size()} peers)`);

    // Tell the joining peer who's already in the room
    this.send(peer.ws, {
      type: "room_joined",
      roomId,
      peerId: peer.id,
      peers: room.getPeerIds().filter((id) => id !== peer.id),
    });

    // Notify existing peers
    room.broadcast({ type: "peer_joined", peerId: peer.id }, peer.id);
  }

  private handleRelay(peer: Peer, msg: RelayMessage): void {
    if (!this.assertInRoom(peer)) return;
    const room = this.rooms.get(peer.roomId!)!;

    const delivered = room.send(msg.to, {
      type: msg.type,
      from: peer.id,
      sdp: msg.sdp,
    });

    if (!delivered) {
      this.sendError(peer.ws, `Peer ${msg.to} not found in room`);
    }
    this.log(`[${msg.type}] ${peer.id} → ${msg.to}`);
  }

  private handleIceCandidate(peer: Peer, msg: IceCandidateMessage): void {
    if (!this.assertInRoom(peer)) return;
    const room = this.rooms.get(peer.roomId!)!;

    room.send(msg.to, {
      type: "ice_candidate",
      from: peer.id,
      candidate: msg.candidate,
    });
    this.log(`[ice_candidate] ${peer.id} → ${msg.to}`);
  }

  // ─── Helpers ───────────────────────────────────────────────────────────────

  private leavePeer(peer: Peer): void {
    if (!peer.roomId) return;

    const room = this.rooms.get(peer.roomId);
    if (room) {
      room.remove(peer.id);
      room.broadcast({ type: "peer_left", peerId: peer.id });
      this.log(`[leave] peer ${peer.id} ← room ${peer.roomId} (${room.size()} remain)`);

      if (room.isEmpty()) {
        this.rooms.delete(peer.roomId);
        this.log(`[room_closed] ${peer.roomId}`);
      }
    }

    this.peerToRoom.delete(peer.id);
    peer.roomId = null;
  }

  private assertInRoom(peer: Peer): boolean {
    if (!peer.roomId) {
      this.sendError(peer.ws, "Must join a room first");
      return false;
    }
    return true;
  }

  private send(ws: WebSocket, message: object): void {
    if (ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify(message));
    }
  }

  private sendError(ws: WebSocket, message: string): void {
    this.log(`[error] ${message}`);
    this.send(ws, { type: "error", message });
  }

  private runHeartbeat(): void {
    const dead: WebSocket[] = [];
    this.wss.clients.forEach((ws) => {
      const socket = ws as WebSocket & { isAlive?: boolean };
      if (socket.isAlive === false) {
        dead.push(ws);
        ws.terminate();
        return;
      }
      socket.isAlive = false;
      ws.ping();
    });
    if (dead.length > 0) {
      this.log(`[heartbeat] terminated ${dead.length} dead connection(s)`);
    }
  }

  private log(msg: string): void {
    if (this.verbose) {
      console.log(`[wsrtc] ${new Date().toISOString()} ${msg}`);
    }
  }

  // ─── Public API ────────────────────────────────────────────────────────────

  getRoomCount(): number {
    return this.rooms.size;
  }

  getPeerCount(): number {
    return this.wss.clients.size;
  }

  close(): Promise<void> {
    if (this.heartbeatTimer) clearInterval(this.heartbeatTimer);
    return new Promise((resolve, reject) => {
      this.wss.close((err) => (err ? reject(err) : resolve()));
    });
  }
}