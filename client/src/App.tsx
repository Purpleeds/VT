import { useEffect, useState } from "react";
import { EVENTS } from "@shared/index";
import { socket } from "./socket";

export function App() {
  const [connected, setConnected] = useState(socket.connected);
  const [message, setMessage] = useState("Connecting…");

  useEffect(() => {
    const onConnect = () => setConnected(true);
    const onDisconnect = () => setConnected(false);
    socket.on("connect", onConnect);
    socket.on("disconnect", onDisconnect);
    socket.on(EVENTS.hello, (payload) => setMessage(payload.message));
    return () => {
      socket.off("connect", onConnect);
      socket.off("disconnect", onDisconnect);
      socket.off(EVENTS.hello);
    };
  }, []);

  return (
    <main className="hello">
      <h1>Hello</h1>
      <p>{message}</p>
      <p className={connected ? "status on" : "status off"}>
        {connected ? "Connected" : "Disconnected"}
      </p>
    </main>
  );
}
