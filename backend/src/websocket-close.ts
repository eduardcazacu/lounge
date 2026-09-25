// Kept out of src/instant-inbox.ts, which imports `cloudflare:workers` and so
// cannot be loaded under Node to be checked.

/**
 * The close code to answer a client's close with.
 *
 * The runtime hands this object whatever code the connection ended with,
 * including the ones RFC 6455 reserves for *reporting* a closure and forbids
 * *sending*: 1005 (no status), 1006 (dropped without a close frame — a phone
 * that went to sleep, lost signal or was killed, so the common case) and 1015
 * (TLS failure). Echoing one of those throws `InvalidAccessError: Invalid
 * WebSocket close code`. Anything a peer may not send is answered with 1000.
 */
export function closeCodeToEcho(code: number): number {
  const sendable =
    (code >= 1000 && code <= 1014 && code !== 1004 && code !== 1005 && code !== 1006) ||
    (code >= 3000 && code <= 4999);
  return sendable ? code : 1000;
}
