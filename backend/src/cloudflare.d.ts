// Minimal hand-rolled Workers runtime types.
//
// The backend compiles with `types: ["node"]` so that `tsx src/server.ts` works.
// Pulling in @cloudflare/workers-types would redeclare fetch/Request/Response on
// top of Node's, so we declare only the Workers-specific surface Instant uses.
// This follows the existing convention of describing bindings inline (see the
// BLOG_IMAGES shape that used to live in src/index.ts).

interface R2HTTPMetadata {
  contentType?: string;
  cacheControl?: string;
}

interface R2Object {
  key: string;
  size: number;
  httpMetadata?: R2HTTPMetadata;
  customMetadata?: Record<string, string>;
}

interface R2ObjectBody extends R2Object {
  body: ReadableStream;
  arrayBuffer(): Promise<ArrayBuffer>;
}

interface R2PutOptions {
  httpMetadata?: R2HTTPMetadata;
  customMetadata?: Record<string, string>;
}

interface R2Bucket {
  put(
    key: string,
    value: ArrayBuffer | ReadableStream | string | null,
    options?: R2PutOptions
  ): Promise<R2Object | null>;
  get(key: string): Promise<R2ObjectBody | null>;
  head(key: string): Promise<R2Object | null>;
  delete(keys: string | string[]): Promise<void>;
}

// A WebSocket handed to us by the runtime. Merges with Node's global
// WebSocket declaration; these are the Workers-only additions.
interface WebSocket {
  accept(): void;
  serializeAttachment(value: unknown): void;
  deserializeAttachment(): unknown;
}

const WebSocketPair: {
  new (): { 0: WebSocket; 1: WebSocket };
};

const WebSocketRequestResponsePair: {
  new (request: string, response: string): WebSocketRequestResponsePair;
};
interface WebSocketRequestResponsePair {
  readonly request: string;
  readonly response: string;
}

// `webSocket` is how a Worker returns the client half of a 101 response. Node's
// ResponseInit is a type alias, so it cannot be merged into — hence a distinct
// name rather than an augmentation.
type WorkerResponseInit = ResponseInit & {
  webSocket?: WebSocket | null;
};

interface DurableObjectStorage {
  setAlarm(scheduledTime: number | Date): Promise<void>;
  deleteAlarm(): Promise<void>;
}

interface DurableObjectState {
  readonly id: DurableObjectId;
  storage: DurableObjectStorage;
  waitUntil(promise: Promise<unknown>): void;
  blockConcurrencyWhile<T>(callback: () => Promise<T>): Promise<T>;
  acceptWebSocket(ws: WebSocket, tags?: string[]): void;
  getWebSockets(tag?: string): WebSocket[];
  setWebSocketAutoResponse(pair?: WebSocketRequestResponsePair | null): void;
}

interface DurableObjectId {
  toString(): string;
  readonly name?: string;
}

// `T` exposes the Durable Object's own RPC methods on the stub.
type DurableObjectStub<T = unknown> = T & {
  fetch(input: Request | string, init?: RequestInit): Promise<Response>;
  readonly id: DurableObjectId;
};

interface DurableObjectNamespace<T = unknown> {
  idFromName(name: string): DurableObjectId;
  idFromString(id: string): DurableObjectId;
  newUniqueId(): DurableObjectId;
  get(id: DurableObjectId): DurableObjectStub<T>;
}

interface ExecutionContext {
  waitUntil(promise: Promise<unknown>): void;
  passThroughOnException(): void;
}

interface ScheduledController {
  readonly scheduledTime: number;
  readonly cron: string;
  noRetry(): void;
}

declare module "cloudflare:workers" {
export abstract class DurableObject<Env = unknown> {
  protected ctx: DurableObjectState;
  protected env: Env;
  constructor(ctx: DurableObjectState, env: Env);
  fetch?(request: Request): Response | Promise<Response>;
  alarm?(): void | Promise<void>;
  webSocketMessage?(ws: WebSocket, message: string | ArrayBuffer): void | Promise<void>;
  webSocketClose?(
    ws: WebSocket,
    code: number,
    reason: string,
    wasClean: boolean
  ): void | Promise<void>;
  webSocketError?(ws: WebSocket, error: unknown): void | Promise<void>;
}
}
