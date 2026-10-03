import { cleanupOutdatedCaches, createHandlerBoundToURL, precacheAndRoute } from "workbox-precaching";
import { NavigationRoute, registerRoute } from "workbox-routing";

declare const self: ServiceWorkerGlobalScope;

// Served as /sw.js, as it always has been: an install's push subscription
// belongs to the registration, and a new URL would leave a second one behind.
//
// The build's own files are precached so a launch from the home screen draws
// without the network. Nothing else goes through here — not the API, which
// TanStack Query caches, and never Instant's one-shot media.

// Under `npm run dev` there is no build to precache, and binding a route to a
// page that is not precached throws, so the dev worker is push only.
if (import.meta.env.PROD) {
  precacheAndRoute(self.__WB_MANIFEST);
  cleanupOutdatedCaches();

  // The same table as vercel.json's rewrites, and it has to stay that way
  // (wiki/parallel-implementations.md). /books must get books.html, or Lounge
  // Books installs from a page naming the Lounge's manifest.
  registerRoute(
    new NavigationRoute(createHandlerBoundToURL("/books.html"), {
      allowlist: [/^\/books(\/[^.]*)?$/],
    })
  );
  registerRoute(
    new NavigationRoute(createHandlerBoundToURL("/index.html"), {
      allowlist: [/^\/(?!\.well-known\/)[^.]*$/],
    })
  );
}

// A deploy takes over at once, so the next launch runs it. A tab still open on
// the previous build loses its chunks to cleanupOutdatedCaches, and the
// vite:preloadError reload in main.tsx brings it forward.
self.addEventListener("install", () => {
  void self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(self.clients.claim());
});

type PushPayload = {
  title: string;
  body: string;
  data: { openUrl: string };
};

self.addEventListener("push", (event) => {
  let payload: PushPayload = {
    title: "Eddie's Lounge",
    body: "You have a new notification.",
    data: {
      openUrl: "/",
    },
  };

  if (event.data) {
    try {
      payload = event.data.json();
    } catch {
      payload = {
        ...payload,
        body: event.data.text() || payload.body,
      };
    }
  }

  event.waitUntil(
    self.registration.showNotification(payload.title, {
      body: payload.body,
      icon: "/icon-192.png",
      badge: "/icon-192.png",
      data: payload.data || { openUrl: "/" },
    })
  );
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const openUrl = event.notification?.data?.openUrl || "/";
  event.waitUntil(
    self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((clientList) => {
      for (const client of clientList) {
        if (client.url.includes(openUrl) && "focus" in client) {
          return client.focus();
        }
      }
      if (self.clients.openWindow) {
        return self.clients.openWindow(openUrl);
      }
      return undefined;
    })
  );
});
