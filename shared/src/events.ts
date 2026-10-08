// Event names and payloads shared by client and server.
// Add new events here first so both sides stay in sync.

export const EVENTS = {
  hello: "hello",
} as const;

export interface HelloPayload {
  message: string;
  serverTime: number;
}

export interface ServerToClientEvents {
  [EVENTS.hello]: (payload: HelloPayload) => void;
}

export interface ClientToServerEvents {
  // Filled in as game features are added.
}
