import { Link, useParams, useSearchParams } from "react-router-dom";
import { useShelf } from "./api";
import type { Library, LibraryEntry } from "./api";
import { Cover, EmptyNote, PersonLine, RecommendBadge, Spinner, Stars, TopBar } from "./ui";
import { byline, formatDay, percentText, usePalette } from "./format";

// A whole shelf, split four ways. The same screen shows anyone's in the group
// (/books/people/:id) — what they are reading, what they want to, and what
// they thought of the rest. On your own, each tab has its own add button, and
// a book added from it lands in it: the add screen is told which of Start,
// Want, Read it or Didn't finish you mean, so that is the only button it shows.

const TABS = [
  { key: "reading", label: "Reading", intent: "start", add: "Start a book" },
  { key: "want", label: "Want", intent: "want", add: "Add to want to read" },
  { key: "read", label: "Read", intent: "finished", add: "Add a book you've read" },
  { key: "dnf", label: "DNF", intent: "dnf", add: "Add a book you put down" },
] as const;

type Tab = (typeof TABS)[number]["key"];

function lastEnded(entry: LibraryEntry) {
  return [...entry.runs].reverse().find((run) => run.status !== "active") ?? null;
}

function tabOf(entry: LibraryEntry): Tab[] {
  const tabs: Tab[] = [];
  if (entry.runs.some((run) => run.status === "active")) tabs.push("reading");
  else if (entry.wantedAt) tabs.push("want");
  if (entry.runs.some((run) => run.status === "finished")) tabs.push("read");
  // A book given up on and later finished is a read book, not a DNF.
  else if (lastEnded(entry)?.status === "dnf") tabs.push("dnf");
  return tabs;
}

function sortKey(entry: LibraryEntry, tab: Tab) {
  if (tab === "want") return entry.wantedAt ?? "";
  if (tab === "reading") return entry.runs.find((run) => run.status === "active")?.startedOn ?? "";
  return lastEnded(entry)?.finishedOn ?? "";
}

function Row({ entry, tab }: { entry: LibraryEntry; tab: Tab }) {
  const active = entry.runs.find((run) => run.status === "active");
  const finishedRuns = entry.runs.filter((run) => run.status === "finished");
  const ended = lastEnded(entry);
  const review = [...entry.runs].reverse().find((run) => run.review)?.review ?? null;

  let meta = "";
  if (tab === "reading" && active) meta = active.totalUnits ? `${percentText(active.fraction)} · p. ${active.position}` : `p. ${active.position}`;
  else if (tab === "want") meta = entry.item.totalUnits ? `${entry.item.totalUnits} pages` : "";
  else if (ended) meta = `${tab === "dnf" ? "Stopped" : "Finished"} ${formatDay(ended.finishedOn)}${finishedRuns.length > 1 ? ` · read ${finishedRuns.length}×` : ""}`;

  return (
    <li>
      <Link to={`/books/item/${entry.id}`} className="flex gap-3 rounded-2xl bg-white p-3 shadow-sm">
        <Cover item={entry.item} size="sm" />
        <div className="min-w-0 flex-1">
          <div className="line-clamp-2 font-semibold leading-snug">{entry.item.title}</div>
          <div className="truncate text-sm text-slate-500">{byline(entry.item)}</div>
          <div className="mt-1 flex flex-wrap items-center gap-2 text-xs text-slate-500">
            {meta ? <span>{meta}</span> : null}
            {tab === "read" || tab === "dnf" ? (
              <>
                <Stars rating={review?.rating ?? null} size={12} />
                <RecommendBadge recommend={review?.recommend ?? null} />
              </>
            ) : null}
          </div>
        </div>
      </Link>
    </li>
  );
}

export function LibraryScreen() {
  const { userId } = useParams();
  const palette = usePalette();
  const [params, setParams] = useSearchParams();
  const current = TABS.find((option) => option.key === params.get("tab")) ?? TABS[0];
  const tab: Tab = current.key;
  const { data: library, error } = useShelf<Library>(userId ? `/entries?userId=${userId}` : "/entries");

  const counts = new Map<Tab, number>();
  const shown: LibraryEntry[] = [];
  for (const entry of library?.entries ?? []) {
    for (const entryTab of tabOf(entry)) {
      counts.set(entryTab, (counts.get(entryTab) ?? 0) + 1);
      if (entryTab === tab) shown.push(entry);
    }
  }
  shown.sort((a, b) => (sortKey(a, tab) < sortKey(b, tab) ? 1 : -1));

  const empty: Record<Tab, string> = {
    reading: "Nothing in progress.",
    want: "Nothing on the want list.",
    read: userId ? "Nothing finished yet." : "Finished books land here. Add ones you read before with the button above.",
    dnf: "No abandoned books. Yet.",
  };

  return (
    <>
      <TopBar title={userId && library ? <PersonLine person={library.owner} /> : "Library"} back={Boolean(userId)} />
      <main className="mx-auto max-w-xl px-4 pb-8">
        <div className="my-3 grid grid-cols-4 rounded-full bg-white p-1 text-sm font-medium shadow-sm">
          {TABS.map((option) => (
            <button
              key={option.key}
              type="button"
              onClick={() => setParams({ tab: option.key }, { replace: true })}
              className="rounded-full py-2"
              style={tab === option.key ? { background: palette.accent, color: "white" } : { color: "#64748b" }}
            >
              {option.label}
              {counts.get(option.key) ? <span className="ml-1 text-xs opacity-75">{counts.get(option.key)}</span> : null}
            </button>
          ))}
        </div>

        {!userId ? (
          <Link
            to={`/books/add?intent=${current.intent}`}
            className="mb-3 flex items-center justify-center gap-1.5 rounded-2xl border border-dashed py-3 text-sm font-medium"
            style={{ borderColor: palette.border, color: palette.accent }}
          >
            <span aria-hidden className="text-lg leading-none">+</span> {current.add}
          </Link>
        ) : null}

        {!library ? (
          error ? <EmptyNote>Couldn't load this shelf.</EmptyNote> : <Spinner />
        ) : shown.length === 0 ? (
          <EmptyNote>{empty[tab]}</EmptyNote>
        ) : (
          <ul className="flex flex-col gap-2">
            {shown.map((entry) => (
              <Row key={entry.id} entry={entry} tab={tab} />
            ))}
          </ul>
        )}

        {!userId ? (
          <Link to="/books/import" className="mt-6 block text-center text-sm font-medium" style={{ color: palette.accent }}>
            Import from Goodreads
          </Link>
        ) : null}
      </main>
    </>
  );
}
