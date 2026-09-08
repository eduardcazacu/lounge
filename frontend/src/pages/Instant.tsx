import { useEffect, useMemo, useState } from "react";
import { Navigate } from "react-router-dom";
import type { InstantDelivery } from "@blogging-app/common";
import { Appbar } from "../components/Appbar";
import { Avatar } from "../components/BlogCard";
import { InstantCapture } from "../components/instant/InstantCapture";
import { InstantComposer } from "../components/instant/InstantComposer";
import { InstantKeySetup } from "../components/instant/InstantKeySetup";
import { InstantViewer } from "../components/instant/InstantViewer";
import { SafetyNumberPanel } from "../components/instant/SafetyNumberPanel";
import { useUsers } from "../hooks";
import { useInstant } from "../hooks/useInstant";
import { getAuthHeader } from "../lib/auth";
import { isPrivateKeyNonExtractable } from "../lib/instantKeystore";
import { getThemePalette } from "../themes";

export const Instant = () => {
  const authed = Boolean(getAuthHeader());
  const {
    device,
    enrollError,
    instants,
    streaks,
    connection,
    authExpired,
    currentUserId,
    dismissInstant,
    refreshStreaks,
  } = useInstant(authed);
  const { users, loading: usersLoading } = useUsers();

  const [captured, setCaptured] = useState<Blob | null>(null);
  const [viewing, setViewing] = useState<InstantDelivery | null>(null);
  const [toast, setToast] = useState<string | null>(null);
  const [nonExtractable, setNonExtractable] = useState<boolean | null>(null);
  const [verifying, setVerifying] = useState<number | null>(null);

  useEffect(() => {
    if (!device || currentUserId === null) {
      return;
    }
    void isPrivateKeyNonExtractable(currentUserId).then(setNonExtractable);
  }, [device, currentUserId]);

  useEffect(() => {
    if (!toast) {
      return;
    }
    const timer = window.setTimeout(() => setToast(null), 4000);
    return () => window.clearTimeout(timer);
  }, [toast]);

  const setupState = enrollError ? "failed" : device ? "ready" : "working";
  const connectionNote = useMemo(() => {
    switch (connection) {
      case "open":
        return "Connected — instants arrive live.";
      case "connecting":
        return "Connecting…";
      case "unsupported":
        return "Realtime is off (backend running without the Durable Object). Instants still arrive when you reopen this page.";
      default:
        return "Offline — reconnecting.";
    }
  }, [connection]);

  if (!authed || authExpired) {
    return <Navigate to="/signin" replace />;
  }

  return (
    <div className="min-h-screen bg-slate-100 pb-16">
      <Appbar />

      <div className="mx-auto flex max-w-xl flex-col gap-4 px-4 py-5">
        <div>
          <h1 className="text-xl font-semibold text-slate-900">Instant</h1>
          <p className="text-xs text-slate-500">{connectionNote}</p>
        </div>

        {setupState !== "ready" || nonExtractable === false ? (
          <InstantKeySetup state={setupState} error={enrollError} nonExtractable={nonExtractable} />
        ) : null}

        {streaks.length > 0 && (
          <section className="rounded-xl bg-white p-3 shadow-sm">
            <h2 className="mb-2 text-xs font-semibold uppercase tracking-wide text-slate-500">
              Streaks
            </h2>
            <ul className="flex flex-wrap gap-2">
              {streaks.map((streak) => {
                const theme = getThemePalette(streak.themeKey);
                const name = streak.name?.trim() || "Anonymous";
                return (
                  <li key={streak.userId}>
                    <button
                      type="button"
                      onClick={() =>
                        setVerifying((current) => (current === streak.userId ? null : streak.userId))
                      }
                      className={`flex items-center gap-2 rounded-full border px-3 py-1.5 text-xs ${
                        streak.atRisk ? "border-amber-400 bg-amber-50" : "border-slate-200"
                      }`}
                      style={{ color: theme.accent }}
                      title={
                        streak.atRisk
                          ? "About to lapse — send something back"
                          : "Tap to check the safety number"
                      }
                    >
                      <Avatar
                        size="small"
                        name={name}
                        themeKey={streak.themeKey}
                        imageUrl={streak.profilePictureUrl}
                      />
                      <span className="font-semibold">{name}</span>
                      <span className="text-slate-700">🔥 {streak.count}</span>
                      {streak.atRisk && <span className="text-amber-700">ending soon</span>}
                    </button>
                  </li>
                );
              })}
            </ul>
            {verifying !== null && (
              <div className="mt-3">
                <SafetyNumberPanel
                  currentUserId={currentUserId}
                  peerUserId={verifying}
                  peerName={
                    streaks.find((streak) => streak.userId === verifying)?.name?.trim() ||
                    "them"
                  }
                />
              </div>
            )}
          </section>
        )}

        <section className="rounded-xl bg-white p-3 shadow-sm">
          <h2 className="mb-2 text-xs font-semibold uppercase tracking-wide text-slate-500">
            Waiting for you
          </h2>
          {instants.length === 0 ? (
            <p className="text-sm text-slate-500">Nothing right now.</p>
          ) : (
            <ul className="flex flex-col gap-2">
              {instants.map((instant) => {
                const name = instant.senderName?.trim() || "Someone";
                return (
                  <li key={instant.id}>
                    <button
                      type="button"
                      onClick={() => setViewing(instant)}
                      className="flex w-full items-center gap-3 rounded-lg border border-slate-200 px-3 py-2 text-left hover:bg-slate-50"
                    >
                      <Avatar
                        size="big"
                        name={name}
                        themeKey={instant.senderThemeKey}
                        imageUrl={instant.senderProfilePictureUrl}
                      />
                      <span className="flex-1">
                        <span className="block text-sm font-medium text-slate-800">{name}</span>
                        <span className="block text-[11px] text-slate-500">
                          {instant.durationMode === "infinite"
                            ? "Open until you close it"
                            : `Visible for ${instant.durationMode}`}
                          {" · opens once"}
                        </span>
                      </span>
                      <span className="text-xs font-semibold text-slate-900">Open</span>
                    </button>
                  </li>
                );
              })}
            </ul>
          )}
        </section>

        <section className="rounded-xl bg-white p-3 shadow-sm">
          <h2 className="mb-2 text-xs font-semibold uppercase tracking-wide text-slate-500">
            Send one
          </h2>
          {!device || currentUserId === null ? (
            // The sender's own id is bound into the HKDF info string, so a
            // wrong one here would produce envelopes nobody can open.
            <p className="text-sm text-slate-500">Waiting for this device's key…</p>
          ) : captured ? (
            <InstantComposer
              image={captured}
              currentUserId={currentUserId}
              users={users}
              usersLoading={usersLoading}
              onSent={(recipientName) => {
                setCaptured(null);
                setToast(`Sent to ${recipientName}.`);
                void refreshStreaks();
              }}
              onDiscard={() => setCaptured(null)}
            />
          ) : (
            <InstantCapture onCaptured={setCaptured} />
          )}
        </section>
      </div>

      {viewing && device && (
        <InstantViewer
          instant={viewing}
          device={device}
          onClose={() => {
            dismissInstant(viewing.id);
            setViewing(null);
            void refreshStreaks();
          }}
        />
      )}

      {toast && (
        <div className="fixed bottom-6 left-1/2 -translate-x-1/2 rounded-full bg-slate-900 px-4 py-2 text-sm text-white shadow-lg">
          {toast}
        </div>
      )}
    </div>
  );
};
