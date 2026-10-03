import { useState } from "react";
import { errorMessage, invalidateShelf, shelfSend, useShelf } from "./api";
import type { ReaderSettings } from "./api";
import { ReaderLinkSheet } from "./ReaderLinkSheet";
import { Card, Cover, EmptyNote, SectionTitle, Spinner, TopBar } from "./ui";
import { agoText, percentText, usePalette } from "./format";

// KOReader sync: the Lounge as KOReader's progress sync server, so reading on
// a Kindle moves Books. The login is made here and the password shown once;
// KOReader keeps only a hash of it, and so do we
// (backend/src/route/kosync.ts).

type Login = { serverUrl: string; username: string; password: string };

function CopyRow({ label, value, large }: { label: string; value: string; large?: boolean }) {
  const [copied, setCopied] = useState(false);
  return (
    <div className="flex items-center gap-3 border-b border-slate-100 py-2.5 last:border-0">
      <div className="min-w-0 flex-1">
        <div className="text-xs text-slate-500">{label}</div>
        <div className={`break-all font-mono text-slate-900 ${large ? "text-xl tracking-wide" : "text-[15px]"}`}>{value}</div>
      </div>
      <button
        type="button"
        onClick={async () => {
          try {
            await navigator.clipboard.writeText(value);
            setCopied(true);
            setTimeout(() => setCopied(false), 1500);
          } catch {
            // Nothing to do: the value is on screen to type.
          }
        }}
        className="shrink-0 rounded-full border border-slate-200 px-3 py-1 text-xs font-medium text-slate-600"
      >
        {copied ? "Copied" : "Copy"}
      </button>
    </div>
  );
}

const STEPS = [
  "Open a book in KOReader, then the top menu → Tools (the wrench) → Progress sync.",
  "Custom sync server: enter the server address above.",
  "Register / Login: enter the username and password, and choose Login — not Register.",
  "Turn on “Auto sync”, and “Send document metadata” so Books can tell which book it is by itself.",
  "Read. Each book is linked once: Books asks which book a new file is, unless its title already says.",
];

export function KoreaderScreen() {
  const palette = usePalette();
  const { data, error } = useShelf<ReaderSettings>("/reader");
  const [login, setLogin] = useState<Login | null>(null);
  const [busy, setBusy] = useState(false);
  const [problem, setProblem] = useState<string | null>(null);
  const [linking, setLinking] = useState<ReaderSettings["documents"][number] | null>(null);

  async function makePassword() {
    if (data?.login && !window.confirm("Make a new password? KOReader will need to log in again with it.")) return;
    setBusy(true);
    setProblem(null);
    try {
      const timeZone = Intl.DateTimeFormat().resolvedOptions().timeZone;
      setLogin(await shelfSend<Login>("post", "/reader/password", { timeZone }));
      invalidateShelf();
    } catch (e) {
      setProblem(errorMessage(e));
    } finally {
      setBusy(false);
    }
  }

  async function turnOff() {
    if (!window.confirm("Turn off KOReader sync? KOReader will be logged out. Linked books stay linked.")) return;
    setBusy(true);
    try {
      await shelfSend("delete", "/reader");
      setLogin(null);
      invalidateShelf();
    } catch (e) {
      setProblem(errorMessage(e));
    } finally {
      setBusy(false);
    }
  }

  const serverUrl = login?.serverUrl ?? data?.serverUrl ?? "";
  // A server on localhost is this computer, which the Kindle cannot reach.
  const unreachable = /\/\/(localhost|127\.0\.0\.1)[:/]/.test(serverUrl);

  return (
    <>
      <TopBar title="KOReader sync" />
      <main className="mx-auto max-w-xl px-4 pb-8">
        {!data ? (
          error ? <EmptyNote>Couldn't load your sync settings.</EmptyNote> : <Spinner />
        ) : (
          <>
            <p className="mt-4 text-sm text-slate-600">
              Reading in KOReader on your Kindle moves your progress here, with no logging by hand. Your book club sees
              it like any other progress.
            </p>

            <SectionTitle>Your login</SectionTitle>
            <Card>
              {data.login || login ? (
                <>
                  <CopyRow label="Server address" value={serverUrl} />
                  <CopyRow label="Username" value={login?.username ?? data.login!.username} />
                  {login ? (
                    <CopyRow label="Password — shown only now" value={login.password} large />
                  ) : (
                    <div className="py-2.5 text-sm text-slate-500">Password: hidden. Make a new one if you need it again.</div>
                  )}
                  {data.login?.lastSeenAt ? (
                    <p className="pt-1 text-xs text-slate-500">KOReader last synced {agoText(data.login.lastSeenAt)}.</p>
                  ) : (
                    <p className="pt-1 text-xs text-slate-500">KOReader hasn't connected yet.</p>
                  )}
                </>
              ) : (
                <p className="text-sm text-slate-600">Make a login for KOReader. You'll type it on the Kindle once.</p>
              )}
              {unreachable ? (
                <p className="mt-2 text-xs text-amber-700">
                  This address is this computer, which your Kindle can't reach. Use the deployed Lounge, or your computer's
                  address on your network.
                </p>
              ) : null}
              {problem ? <p className="mt-2 text-sm text-rose-600">{problem}</p> : null}
              <div className="mt-3 flex gap-2">
                <button
                  type="button"
                  disabled={busy}
                  onClick={makePassword}
                  className="rounded-full px-4 py-2 text-sm font-semibold text-white disabled:opacity-60"
                  style={{ background: palette.accent }}
                >
                  {data.login || login ? "New password" : busy ? "Setting up…" : "Set up"}
                </button>
                {data.login ? (
                  <button type="button" disabled={busy} onClick={turnOff} className="rounded-full px-4 py-2 text-sm font-medium text-slate-600">
                    Turn off
                  </button>
                ) : null}
              </div>
            </Card>

            <SectionTitle>On the Kindle</SectionTitle>
            <Card>
              <ol className="flex flex-col gap-2.5">
                {STEPS.map((step, index) => (
                  <li key={step} className="flex gap-3 text-sm text-slate-700">
                    <span
                      className="flex h-6 w-6 shrink-0 items-center justify-center rounded-full text-xs font-semibold text-white"
                      style={{ background: palette.accent }}
                    >
                      {index + 1}
                    </span>
                    <span>{step}</span>
                  </li>
                ))}
              </ol>
              <p className="mt-3 text-xs text-slate-500">
                Progress only moves forward: paging back to check something doesn't undo any reading. KOReader syncs when
                you close a book or the Kindle sleeps, and every few pages if you set “Sync every # pages”.
              </p>
            </Card>

            <SectionTitle>Books KOReader has synced</SectionTitle>
            {data.documents.length === 0 ? (
              <EmptyNote>None yet. Open a book in KOReader once it's logged in.</EmptyNote>
            ) : (
              <Card className="!py-1">
                <ul>
                  {data.documents.map((doc) => (
                    <li key={doc.id} className="flex items-center gap-3 border-b border-slate-100 py-2.5 last:border-0">
                      {doc.entry ? <Cover item={doc.entry.item} size="xs" /> : <div className="h-12 w-8 shrink-0 rounded bg-slate-100" />}
                      <div className="min-w-0 flex-1">
                        <div className="truncate text-[15px] font-medium text-slate-900">
                          {doc.entry?.item.title ?? doc.title ?? "Unidentified book"}
                        </div>
                        <div className="truncate text-xs text-slate-500">
                          {percentText(doc.percentage)} · {doc.device} · {agoText(doc.syncedAt)}
                          {doc.ignored ? " · ignored" : doc.entry ? "" : " · not linked"}
                        </div>
                      </div>
                      <button
                        type="button"
                        onClick={() => setLinking(doc)}
                        className="shrink-0 text-xs font-medium"
                        style={{ color: palette.accent }}
                      >
                        {doc.entry ? "Change" : "Which book?"}
                      </button>
                    </li>
                  ))}
                </ul>
              </Card>
            )}
          </>
        )}
      </main>
      {linking ? <ReaderLinkSheet doc={linking} onClose={() => setLinking(null)} /> : null}
    </>
  );
}
