import { useEffect, useState } from "react";
import axios from "axios";
import { BACKEND_URL } from "../../config";
import { getAuthHeader } from "../../lib/auth";
import { fingerprintKeys, safetyNumber } from "../../lib/instantCrypto";
import {
  getRememberedPeerFingerprint,
  rememberPeerFingerprint,
} from "../../lib/instantKeystore";

// The server publishes everyone's public keys, which means it could publish its
// own instead and read everything. Comparing this number out of band — out loud,
// in person — is the only thing that actually rules that out.

export function SafetyNumberPanel({
  currentUserId,
  peerUserId,
  peerName,
}: {
  currentUserId: number | null;
  peerUserId: number;
  peerName: string;
}) {
  const [digits, setDigits] = useState<string | null>(null);
  const [changed, setChanged] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;

    const load = async () => {
      try {
        const response = await axios.get(`${BACKEND_URL}/api/v1/instant/keys/${peerUserId}`, {
          headers: { Authorization: getAuthHeader() },
        });
        if (cancelled) {
          return;
        }
        const theirKeys = (response.data?.devices ?? []) as { publicKey: string }[];
        const myKeys = (response.data?.myDevices ?? []) as { publicKey: string }[];
        if (theirKeys.length === 0) {
          setError(`${peerName} has not set up Instant yet.`);
          return;
        }

        setDigits(await safetyNumber(myKeys, theirKeys));

        const fingerprint = await fingerprintKeys(theirKeys);
        const remembered = await getRememberedPeerFingerprint(currentUserId!, peerUserId);
        if (remembered && remembered.fingerprint !== fingerprint) {
          setChanged(true);
        }
        await rememberPeerFingerprint(currentUserId!, peerUserId, fingerprint);
      } catch {
        if (!cancelled) {
          setError("Could not load keys for this person.");
        }
      }
    };

    if (currentUserId !== null) {
      void load();
    }
    return () => {
      cancelled = true;
    };
  }, [currentUserId, peerUserId, peerName]);

  if (error) {
    return <p className="text-xs text-neutral-400">{error}</p>;
  }

  return (
    <div className="rounded-xl border border-white/10 bg-neutral-900 p-3">
      {changed && (
        <p className="mb-2 rounded-md bg-amber-500/15 px-2 py-1.5 text-xs text-amber-300">
          {peerName}&apos;s keys changed since you last checked. That happens when they reinstall
          or clear their browser data — but it is also what a key substitution attack looks
          like. Compare the number below with them before sending anything sensitive.
        </p>
      )}
      <p className="text-xs font-medium text-neutral-400">Safety number with {peerName}</p>
      <p
        className="mt-1 font-mono text-xs leading-relaxed tracking-wide text-white"
        data-testid="safety.number"
      >
        {digits ?? "…"}
      </p>
      <p className="mt-2 text-[11px] text-neutral-500">
        Read this aloud together. If it matches on both screens, nobody swapped the keys.
      </p>
    </div>
  );
}
