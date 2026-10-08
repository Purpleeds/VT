import { createServer } from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";
import express from "express";
import { Server } from "socket.io";
import { EVENTS } from "@shared/index";
import type { ClientToServerEvents, ServerToClientEvents } from "@shared/index";

const here = path.dirname(fileURLToPath(import.meta.url));
// Built layout: server/dist/index.js -> client/dist. Dev (tsx): server/src -> client/dist.
const clientDist = path.resolve(here, "../../client/dist");
const port = Number(process.env.PORT) || 3000;

const app = express();
const httpServer = createServer(app);
const io = new Server<ClientToServerEvents, ServerToClientEvents>(httpServer);

app.get("/healthz", (_req, res) => {
  res.json({ ok: true });
});

app.use(express.static(clientDist));
// Single-page app fallback (Express 4 wildcard).
app.get("*", (_req, res) => {
  res.sendFile(path.join(clientDist, "index.html"));
});

io.on("connection", (socket) => {
  socket.emit(EVENTS.hello, { message: "Hello from the server", serverTime: Date.now() });
});

httpServer.listen(port, () => {
  console.log(`Server listening on port ${port}`);
});
