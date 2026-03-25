import type WebSocket from "ws";

export interface Peer {
  id: string;
  ws: WebSocket;
  roomId: string | null;
  joinedAt: Date;
}

export class Room {
  readonly id: string;
  private peers: Map<string, Peer> = new Map();

  constructor(id: string) {
    this.id = id;
  }

  add(peer: Peer): void {
    this.peers.set(peer.id, peer);
  }

  remove(peerId: string): void {
    this.peers.delete(peerId);
  }

  get(peerId: string): Peer | undefined {
    return this.peers.get(peerId);
  }

  has(peerId: string): boolean {
    return this.peers.has(peerId);
  }

  getPeerIds(): string[] {
    return Array.from(this.peers.keys());
  }

  getPeers(): Peer[] {
    return Array.from(this.peers.values());
  }

  isEmpty(): boolean {
    return this.peers.size === 0;
  }

  size(): number {
    return this.peers.size;
  }

  /**
   * Broadcast a message to all peers in the room except the sender.
   */
  broadcast(message: object, excludePeerId?: string): void {
    const payload = JSON.stringify(message);
    for (const peer of this.peers.values()) {
      if (peer.id !== excludePeerId && peer.ws.readyState === peer.ws.OPEN) {
        peer.ws.send(payload);
      }
    }
  }

  /**
   * Send a message to a specific peer by ID.
   */
  send(toPeerId: string, message: object): boolean {
    const peer = this.peers.get(toPeerId);
    if (!peer || peer.ws.readyState !== peer.ws.OPEN) return false;
    peer.ws.send(JSON.stringify(message));
    return true;
  }
}