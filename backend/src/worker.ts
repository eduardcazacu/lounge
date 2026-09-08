import { app } from "./index";
import { scheduled } from "./scheduled";

// The Cloudflare Workers entrypoint.
//
// Kept separate from src/index.ts because the Durable Object below imports
// `cloudflare:workers`, which does not exist under Node — re-exporting it from
// index.ts would break `tsx src/server.ts` for the whole app, not just Instant.
export { InstantInbox } from "./instant-inbox";

export default {
  fetch: app.fetch,
  scheduled,
};
