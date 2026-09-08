import { DurableObject } from "cloudflare:workers";
import type { InstantDelivery, InstantWireEvent } from "@blogging-app/common";

// One InstantInbox per user, addressed as `user:<id>`.
//
// It is a pure realtime relay: no durable state, no database access. The Worker
// owns Postgres and R2; this object only knows which sockets are currently open
// and which device each one belongs to. That keeps Prisma out of the Durable
// Object (a fresh client per object would be expensive) and means there is no
// second copy of message state to drift out of sync.
//
// Uses the WebSocket Hibernation API — ctx.acceptWebSocket rather than
// server.accept — so an idle inbox is evicted from memory without dropping its
// clients, and accrues no billable duration while it waits.

type SocketAttachment = {
  userId: number;
  deviceId: string;
};

export type DeliveryEnvelope = {
  wrappedKey: string;
  wrapIv: string;
};

// Everything about an instant except the per-device wrapped key.
export type DeliveryMeta = Omit<InstantDelivery, "envelope">;

function readAttachment(ws: WebSocket): SocketAttachment | null {
  try {
    const raw = ws.deserializeAttachment();
    if (!raw || typeof raw !== "object") {
      return null;
    }
    const { userId, deviceId } = raw as Partial<SocketAttachment>;
    if (typeof userId !== "number" || typeof deviceId !== "string" || !deviceId) {
      return null;
    }
    return { userId, deviceId };
  } catch {
    return null;
  }
}

function trySend(ws: WebSocket, event: InstantWireEvent): boolean {
  try {
    ws.send(JSON.stringify(event));
    return true;
  } catch {
    // Socket is already gone. The recipient will pick this up from GET /inbox
    // on their next connect, so there is nothing to recover here.
    return false;
  }
}

export class InstantInbox extends DurableObject {
  constructor(ctx: DurableObjectState, env: unknown) {
    super(ctx, env);
    // Answer keepalive pings in the runtime, without waking us from hibernation.
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }

  async fetch(request: Request): Promise<Response> {
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
      return new Response("Expected a WebSocket upgrade", { status: 426 });
    }

    // Identity is supplied by the Worker, which has already validated the
    // ticket and confirmed the device belongs to the user.
    const url = new URL(request.url);
    const userId = Number(url.searchParams.get("userId"));
    const deviceId = url.searchParams.get("deviceId") ?? "";
    if (!Number.isFinite(userId) || !deviceId) {
      return new Response("Missing socket identity", { status: 400 });
    }

    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];

    this.ctx.acceptWebSocket(server);
    server.serializeAttachment({ userId, deviceId } satisfies SocketAttachment);
    trySend(server, { type: "ready", deviceId });

    return new Response(null, { status: 101, webSocket: client } as WorkerResponseInit);
  }

  // RPC. Sends each connected device only the envelope wrapped for it — a
  // device we did not wrap for learns nothing, not even a ciphertext handle.
  // Returns true only if at least one such device actually received it;
  // anything else means the Worker should fall back to a push notification.
  async deliver(
    instant: DeliveryMeta,
    envelopesByDeviceId: Record<string, DeliveryEnvelope>
  ): Promise<boolean> {
    let delivered = false;
    for (const ws of this.ctx.getWebSockets()) {
      const attachment = readAttachment(ws);
      if (!attachment) {
        continue;
      }
      const envelope = envelopesByDeviceId[attachment.deviceId];
      if (!envelope) {
        continue;
      }
      if (trySend(ws, { type: "instant", instant: { ...instant, envelope } })) {
        delivered = true;
      }
    }
    return delivered;
  }

  // RPC. Read receipt fanned out to every device the sender has open.
  async notifyOpened(instantId: string, recipientId: number, openedAt: string): Promise<void> {
    for (const ws of this.ctx.getWebSockets()) {
      trySend(ws, { type: "opened", instantId, recipientId, openedAt });
    }
  }

  // RPC. Whether this user has any device connected right now.
  async isOnline(): Promise<boolean> {
    return this.ctx.getWebSockets().length > 0;
  }

  async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    // Clients only ever ping (handled by the auto-response) or ack. Anything
    // that reaches here is ignored on purpose: this object takes no commands.
    if (typeof message === "string" && message === "ping") {
      trySend(ws, { type: "ready", deviceId: readAttachment(ws)?.deviceId ?? "" });
    }
  }

  async webSocketClose(ws: WebSocket, code: number, reason: string): Promise<void> {
    // 1005 means "no status received" and may not be echoed back.
    ws.close(code === 1005 ? 1000 : code, reason);
  }
}
