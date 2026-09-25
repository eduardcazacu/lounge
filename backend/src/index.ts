import { Hono } from 'hono'
import { userRouter } from './route/user'
import { blogRouter } from './route/blog'
import { adminRouter } from './route/admin'
import { chatRouter } from './route/chat'
import { instantRouter } from './route/instant'
import { moderationRouter } from './route/moderation'
import type { InstantInbox } from './instant-inbox'
import { cors } from 'hono/cors'

// Create the main Hono app
const app = new Hono<{
	Bindings: {
		DATABASE_URL?: string,
		HYPERDRIVE?: Hyperdrive,
		JWT_SECRET?: string,
		ADMIN_EMAILS?: string,
		RESEND_API_KEY?: string,
		EMAIL_FROM?: string,
		FRONTEND_URL?: string,
		VAPID_PUBLIC_KEY?: string,
		VAPID_PRIVATE_KEY?: string,
		VAPID_SUBJECT?: string,
		R2_PUBLIC_BASE_URL?: string,
		// Declared in src/cloudflare.d.ts. Instant needs get/delete as well as
		// put, so the binding is typed properly rather than inline here.
		BLOG_IMAGES?: R2Bucket,
		INSTANT_INBOX?: DurableObjectNamespace<InstantInbox>
	}
}>();

app.use('/*', (c, next) => {
  const frontendUrl = c.env?.FRONTEND_URL ?? process.env.FRONTEND_URL ?? "http://localhost:5173";
  const frontendOrigin = (() => {
    try {
      return new URL(frontendUrl).origin;
    } catch {
      return frontendUrl;
    }
  })();

  const corsMiddleware = cors({
    origin: [frontendOrigin, "http://localhost:5173", "http://127.0.0.1:5173"],
    allowMethods: ["GET", "POST", "PUT", "DELETE", "OPTIONS"],
    allowHeaders: ["Content-Type", "Authorization"],
    credentials: true,
  });
  return corsMiddleware(c, next);
})
app.route("api/v1/user", userRouter)
app.route("api/v1/blog", blogRouter)
app.route("api/v1/admin", adminRouter)
app.route("api/v1/chat", chatRouter)
app.route("api/v1/instant", instantRouter)
app.route("api/v1/moderation", moderationRouter)

app.use('/message/*', async (c, next) => {
  await next()
})

// This module stays runnable under plain Node (src/server.ts): it must not pull
// in anything from `cloudflare:workers`. The Worker entrypoint is src/worker.ts,
// which adds the Durable Object and the cron handler on top of this app.
export { app }
export default app
