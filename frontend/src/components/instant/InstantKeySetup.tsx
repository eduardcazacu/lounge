// Shown before anything else on this device. The guarantees and the limits both
// belong on screen — a user who does not know the key is unrecoverable will be
// surprised at exactly the wrong moment.

export function InstantKeySetup({
  state,
  error,
  nonExtractable,
}: {
  state: "working" | "ready" | "failed";
  error: string | null;
  nonExtractable: boolean | null;
}) {
  return (
    <div className="rounded-2xl border border-white/10 bg-neutral-900/95 p-4 text-sm backdrop-blur">
      <p className="font-semibold text-white">
        {state === "working" && "Setting up Instant on this device…"}
        {state === "ready" && "This device has its own Instant key"}
        {state === "failed" && "Instant could not start on this device"}
      </p>

      {state === "failed" ? (
        <p className="mt-2 text-rose-400">{error}</p>
      ) : (
        <ul className="mt-2 space-y-1.5 text-xs text-neutral-400">
          <li>
            Photos are encrypted here before upload. The server stores ciphertext and
            wrapped keys it cannot unwrap.
          </li>
          <li>
            The private key stays in this browser
            {nonExtractable === true && " and is marked non-extractable, so no script can copy it out"}
            . Clearing site data, switching browsers, or Safari evicting storage after about
            a week idle all replace it — and anything still waiting for you becomes
            permanently unopenable. There is no recovery.
          </li>
          <li>
            This web client is the weak point: it is downloaded fresh from the server each
            visit, so whoever controls the deployment could serve code that reads your
            photos. A signed native app does not have that problem.
          </li>
        </ul>
      )}
    </div>
  );
}
