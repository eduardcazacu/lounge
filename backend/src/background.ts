import type { Context } from "hono";

// Schedule fire-and-forget background work. On Cloudflare Workers this defers via
// executionCtx.waitUntil; on the Node dev runtime accessing executionCtx throws, so
// we fall back to a detached promise.
export function scheduleBackgroundWork(c: Context<any>, work: Promise<unknown>) {
  try {
    if (c.executionCtx?.waitUntil) {
      c.executionCtx.waitUntil(work);
      return;
    }
  } catch {
    // No ExecutionContext (Node runtime).
  }
  void work.catch((e) => console.error(e));
}
