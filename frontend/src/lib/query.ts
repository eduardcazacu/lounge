import { QueryClient, type Query } from "@tanstack/react-query";
import { createAsyncStoragePersister } from "@tanstack/query-async-storage-persister";
import type { PersistQueryClientProviderProps } from "@tanstack/react-query-persist-client";
import axios from "axios";
import { del, get, set } from "idb-keyval";

// The one data cache for the web client, and the reason going Back shows the
// page you left rather than a skeleton. See wiki/web-client.md.
//
// It is written to IndexedDB so a launch from the home screen draws the last
// feed and shelf before the network answers. IndexedDB, not localStorage: ten
// pages of posts with their comments approach localStorage's quota, and its
// writes block the main thread.

const SEVEN_DAYS = 7 * 24 * 60 * 60 * 1000;
const STORAGE_KEY = "lounge-query-cache";

// Only these are written to disk. Anything new — admin, Instant — stays in
// memory unless it is added here on purpose.
const PERSISTED = new Set(["blogs", "blog", "users", "shelf"]);

export const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 30_000,
      // At least the persister's maxAge. A query collected from memory is
      // silently dropped from the persisted cache too (wiki/gotchas.md).
      gcTime: SEVEN_DAYS,
      // Once, but never for a 401/403: the axios interceptor has already
      // refreshed and retried, and the page should go to sign-in now.
      retry: (failures, error) =>
        failures < 1 && !(axios.isAxiosError(error) && [401, 403].includes(error.response?.status ?? 0)),
    },
  },
});

/**
 * Every key starts with the account. One localStorage token is shared by every
 * tab, so another account can sign in under an open page, and a key without the
 * id would hand it the last account's posts (wiki/gotchas.md).
 */
export function accountKey(userId: number | null, ...parts: unknown[]) {
  return ["u", userId ?? "-", ...parts] as const;
}

const persister = createAsyncStoragePersister({
  storage: { getItem: get, setItem: set, removeItem: del },
  key: STORAGE_KEY,
});

export const persistOptions: PersistQueryClientProviderProps["persistOptions"] = {
  persister,
  maxAge: SEVEN_DAYS,
  // A deploy can change a response's shape; a cache written by another build
  // is discarded rather than drawn.
  buster: __BUILD_ID__,
  dehydrateOptions: {
    shouldDehydrateQuery: (query: Query) =>
      query.state.status === "success" && PERSISTED.has(String(query.queryKey[2])),
  },
};

/** Forget everything, in memory and on disk. Called when the token is cleared. */
export function clearQueryCache() {
  queryClient.clear();
  void del(STORAGE_KEY);
}
