import { io } from "socket.io-client";
import type { Socket } from "socket.io-client";
import type { ClientToServerEvents, ServerToClientEvents } from "@shared/index";

export const socket: Socket<ServerToClientEvents, ClientToServerEvents> = io();
