import path from "node:path";
import { fileURLToPath } from "node:url";
import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

const here = path.dirname(fileURLToPath(import.meta.url));

export default defineConfig({
  plugins: [react()],
  resolve: {
    alias: { "@shared": path.resolve(here, "../shared/src") },
  },
  server: {
    port: 5173,
    // In dev the Express server runs on 3000; proxy WebSockets to it.
    proxy: { "/socket.io": { target: "http://localhost:3000", ws: true } },
  },
});
