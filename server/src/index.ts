import { SignalingServer } from "./SignalingServer.js";

const PORT = parseInt(process.env.PORT ?? "8080", 10);
const MAX_ROOM_SIZE = parseInt(process.env.MAX_ROOM_SIZE ?? "50", 10);

const server = new SignalingServer({
  port: PORT,
  maxRoomSize: MAX_ROOM_SIZE,
  verbose: process.env.VERBOSE !== "false",
});

process.on("SIGINT", async () => {
  console.log("\n[wsrtc] shutting down...");
  await server.close();
  process.exit(0);
});

process.on("SIGTERM", async () => {
  await server.close();
  process.exit(0);
});