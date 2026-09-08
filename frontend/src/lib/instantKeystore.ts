// This device's Instant identity.
//
// The private key is generated with `extractable: false` and stored as a live
// CryptoKey object in IndexedDB. That means script running on this page can ask
// the browser to decrypt with it, but cannot read the key bytes out to use
// somewhere else. It is a real mitigation and not a complete one — see the
// threat model in backend/README.md.
//
// There is NO key recovery. Clearing site data, using a different browser, or
// Safari's ITP evicting IndexedDB after ~7 idle days all produce a brand new
// identity, and anything already wrapped to the old key can never be opened.
//
// Identities are scoped to the signed-in account, so switching accounts in one
// browser yields a different device rather than reusing the first one's key.

const DB_NAME = "eddies-lounge-instant";
const DB_VERSION = 1;
const STORE = "identity";
const PEER_STORE = "peer-fingerprints";

// Keyed per account, not per browser. Two accounts used in the same browser
// profile must never share a keypair: sharing one would let either of them
// decrypt instants addressed to the other.
const identityKey = (userId: number) => `device:${userId}`;
const peerKey = (userId: number, peerUserId: number) => `${userId}:${peerUserId}`;

export type InstantDevice = {
  deviceId: string;
  publicKeyB64: string;
  privateKey: CryptoKey;
  publicKey: CryptoKey;
};

type StoredIdentity = {
  deviceId: string;
  publicKeyB64: string;
  privateKey: CryptoKey;
  publicKey: CryptoKey;
};

function openDatabase(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(DB_NAME, DB_VERSION);
    request.onupgradeneeded = () => {
      const db = request.result;
      if (!db.objectStoreNames.contains(STORE)) {
        db.createObjectStore(STORE);
      }
      if (!db.objectStoreNames.contains(PEER_STORE)) {
        db.createObjectStore(PEER_STORE);
      }
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error ?? new Error("Could not open IndexedDB"));
  });
}

async function readRecord<T>(store: string, key: string): Promise<T | undefined> {
  const db = await openDatabase();
  try {
    return await new Promise<T | undefined>((resolve, reject) => {
      const request = db.transaction(store, "readonly").objectStore(store).get(key);
      request.onsuccess = () => resolve(request.result as T | undefined);
      request.onerror = () => reject(request.error ?? new Error("IndexedDB read failed"));
    });
  } finally {
    db.close();
  }
}

async function writeRecord(store: string, key: string, value: unknown): Promise<void> {
  const db = await openDatabase();
  try {
    await new Promise<void>((resolve, reject) => {
      const transaction = db.transaction(store, "readwrite");
      transaction.objectStore(store).put(value, key);
      transaction.oncomplete = () => resolve();
      transaction.onerror = () => reject(transaction.error ?? new Error("IndexedDB write failed"));
    });
  } finally {
    db.close();
  }
}

export function toBase64Url(bytes: ArrayBuffer | Uint8Array): string {
  const view = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  let binary = "";
  for (const byte of view) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function fromBase64Url(value: string): Uint8Array {
  const padded = value.replace(/-/g, "+").replace(/_/g, "/");
  const binary = atob(padded + "=".repeat((4 - (padded.length % 4)) % 4));
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

async function generateIdentity(): Promise<StoredIdentity> {
  const pair = await crypto.subtle.generateKey(
    { name: "ECDH", namedCurve: "P-256" },
    // Non-extractable: the private half can be used but never exported.
    false,
    ["deriveBits"]
  );
  const rawPublic = await crypto.subtle.exportKey("raw", pair.publicKey);
  return {
    deviceId: crypto.randomUUID(),
    publicKeyB64: toBase64Url(rawPublic),
    privateKey: pair.privateKey,
    publicKey: pair.publicKey,
  };
}

const identityPromises = new Map<number, Promise<InstantDevice>>();

// This account's device identity on this browser, created on first use.
export function getOrCreateDevice(userId: number): Promise<InstantDevice> {
  const cached = identityPromises.get(userId);
  if (cached) {
    return cached;
  }
  const pending = (async () => {
    const existing = await readRecord<StoredIdentity>(STORE, identityKey(userId));
    if (
      existing?.deviceId &&
      existing.publicKeyB64 &&
      existing.privateKey instanceof CryptoKey
    ) {
      return existing;
    }
    const identity = await generateIdentity();
    await writeRecord(STORE, identityKey(userId), identity);
    return identity;
  })().catch((error) => {
    // Let the next call retry rather than caching a failure forever.
    identityPromises.delete(userId);
    throw error;
  });
  identityPromises.set(userId, pending);
  return pending;
}

// Was the private key generated non-extractably? Surfaced in the UI so the
// guarantee is verifiable rather than merely claimed.
export async function isPrivateKeyNonExtractable(userId: number): Promise<boolean> {
  const device = await getOrCreateDevice(userId);
  return device.privateKey.extractable === false;
}

export type PeerFingerprintRecord = {
  fingerprint: string;
  seenAt: string;
};

export async function getRememberedPeerFingerprint(userId: number, peerUserId: number) {
  return readRecord<PeerFingerprintRecord>(PEER_STORE, peerKey(userId, peerUserId));
}

export async function rememberPeerFingerprint(
  userId: number,
  peerUserId: number,
  fingerprint: string
) {
  await writeRecord(PEER_STORE, peerKey(userId, peerUserId), {
    fingerprint,
    seenAt: new Date().toISOString(),
  } satisfies PeerFingerprintRecord);
}
