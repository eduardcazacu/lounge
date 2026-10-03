import { useRef, useState } from "react";
import type { CSSProperties, ReactNode } from "react";
import { Link, useParams, useSearchParams } from "react-router-dom";
import {
  DndContext,
  KeyboardSensor,
  PointerSensor,
  closestCenter,
  useSensor,
  useSensors,
  type DragEndEvent,
} from "@dnd-kit/core";
import { SortableContext, arrayMove, sortableKeyboardCoordinates, useSortable, verticalListSortingStrategy } from "@dnd-kit/sortable";
import { restrictToParentElement, restrictToVerticalAxis } from "@dnd-kit/modifiers";
import { CSS } from "@dnd-kit/utilities";
import { errorMessage, invalidateShelf, patchCached, shelfSend, useShelf } from "./api";
import type { Library, LibraryEntry } from "./api";
import { Cover, EmptyNote, PersonLine, RecommendBadge, Spinner, Stars, TopBar } from "./ui";
import { byline, formatDay, percentText, usePalette } from "./format";

// A whole shelf, split four ways. The same screen shows anyone's in the group
// (/books/people/:id) — what they are reading, what they want to, and what
// they thought of the rest. On your own, each tab has its own add button, and
// a book added from it lands in it: the add screen is told which of Start,
// Want, Read it or Didn't finish you mean, so that is the only button it shows.
//
// Search and filters run here, on the shelf already fetched whole. They apply
// across the tabs, and each tab's count is its matches, so a book that is not
// in this tab says which one it is in. All of it lives in the URL, so coming
// back from a book lands on the same list.
//
// Your own want list is a queue you arrange: drag a book by its handle, or
// send it to the top. Arranging needs the whole list in its own order, so the
// handles hide while a search, a filter or another sort is on.

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

const SORTS = [
  { key: "recent", label: "Recent" },
  { key: "title", label: "Title" },
  { key: "author", label: "Author" },
  { key: "rating", label: "Rating" },
] as const;

type Sort = (typeof SORTS)[number]["key"];

/** Lower case and without accents, so "bronte" finds Brontë. */
function fold(text: string) {
  return text.normalize("NFD").replace(/\p{Diacritic}/gu, "").toLowerCase();
}

function surname(entry: LibraryEntry) {
  return fold(entry.item.creators[0]?.trim().split(/\s+/).pop() ?? "\uffff");
}

function latestRating(entry: LibraryEntry) {
  return [...entry.runs].reverse().find((run) => run.review?.rating != null)?.review?.rating ?? null;
}

/** The years a book was finished in, or for a DNF, put down. */
function yearsOf(entry: LibraryEntry, tab: Tab) {
  const runs = entry.runs.filter((run) => run.status === (tab === "dnf" ? "dnf" : "finished") && run.finishedOn);
  return new Set(runs.map((run) => run.finishedOn!.slice(0, 4)));
}

type Filters = { words: string[]; genre: string | null; year: string | null };

function matches(entry: LibraryEntry, tab: Tab, filters: Filters) {
  if (filters.words.length) {
    const haystack = fold([entry.item.title, ...entry.item.creators].join(" "));
    if (!filters.words.every((word) => haystack.includes(word))) return false;
  }
  if (filters.genre && !entry.item.genres.includes(filters.genre)) return false;
  // A year means something only where a book ended.
  if (filters.year && (tab === "read" || tab === "dnf") && !yearsOf(entry, tab).has(filters.year)) return false;
  return true;
}

/** The order the reader arranged: unranked first, newest wish first, then by rank. Home sorts the same way. */
function byWantOrder(a: LibraryEntry, b: LibraryEntry) {
  if (a.wantRank !== b.wantRank) {
    if (a.wantRank === null) return -1;
    if (b.wantRank === null) return 1;
    return a.wantRank - b.wantRank;
  }
  return (b.wantedAt ?? "").localeCompare(a.wantedAt ?? "");
}

function compare(a: LibraryEntry, b: LibraryEntry, tab: Tab, sort: Sort) {
  if (tab === "want" && sort === "recent") return byWantOrder(a, b);
  const recent = sortKey(a, tab) < sortKey(b, tab) ? 1 : sortKey(a, tab) > sortKey(b, tab) ? -1 : 0;
  if (sort === "title") return fold(a.item.title).localeCompare(fold(b.item.title)) || recent;
  if (sort === "author") return surname(a).localeCompare(surname(b)) || fold(a.item.title).localeCompare(fold(b.item.title));
  if (sort === "rating") return (latestRating(b) ?? -1) - (latestRating(a) ?? -1) || recent;
  return recent;
}

function FilterSelect({
  label,
  value,
  options,
  onChange,
}: {
  label: string;
  value: string;
  options: { value: string; label: string }[];
  onChange: (value: string) => void;
}) {
  const palette = usePalette();
  const active = value !== options[0]?.value;
  return (
    <select
      aria-label={label}
      value={value}
      onChange={(event) => onChange(event.target.value)}
      className="shrink-0 rounded-full border bg-white py-1.5 pl-3 pr-7 text-sm"
      style={active ? { borderColor: palette.accent, color: palette.accent } : { borderColor: "#e2e8f0", color: "#475569" }}
    >
      {options.map((option) => (
        <option key={option.value} value={option.value}>
          {option.label}
        </option>
      ))}
    </select>
  );
}

function Row({
  entry,
  tab,
  controls,
  rowRef,
  style,
}: {
  entry: LibraryEntry;
  tab: Tab;
  controls?: ReactNode;
  rowRef?: (node: HTMLElement | null) => void;
  style?: CSSProperties;
}) {
  const active = entry.runs.find((run) => run.status === "active");
  const finishedRuns = entry.runs.filter((run) => run.status === "finished");
  const ended = lastEnded(entry);
  const review = [...entry.runs].reverse().find((run) => run.review)?.review ?? null;

  let meta = "";
  if (tab === "reading" && active) meta = active.totalUnits ? `${percentText(active.fraction)} · p. ${active.position}` : `p. ${active.position}`;
  else if (tab === "want") meta = entry.item.totalUnits ? `${entry.item.totalUnits} pages` : "";
  else if (ended) meta = `${tab === "dnf" ? "Stopped" : "Finished"} ${formatDay(ended.finishedOn)}${finishedRuns.length > 1 ? ` · read ${finishedRuns.length}×` : ""}`;

  return (
    <li ref={rowRef} style={style} className="flex rounded-2xl bg-white shadow-sm">
      <Link to={`/books/item/${entry.id}`} className="flex min-w-0 flex-1 gap-3 p-3">
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
      {controls}
    </li>
  );
}

function SortableRow({ entry, first, onTop }: { entry: LibraryEntry; first: boolean; onTop: () => void }) {
  const { attributes, listeners, setNodeRef, setActivatorNodeRef, transform, transition, isDragging } = useSortable({
    id: entry.id,
  });
  const style: CSSProperties = {
    transform: CSS.Translate.toString(transform),
    transition,
    position: "relative",
    zIndex: isDragging ? 10 : undefined,
    boxShadow: isDragging ? "0 12px 28px rgba(15, 23, 42, 0.18)" : undefined,
  };
  return (
    <Row
      entry={entry}
      tab="want"
      rowRef={setNodeRef}
      style={style}
      controls={
        <div className="flex shrink-0 flex-col items-center justify-center pr-1 text-slate-400">
          {first ? (
            <span className="h-10 w-10" />
          ) : (
            <button type="button" onClick={onTop} aria-label={`Move ${entry.item.title} to the top`} className="flex h-10 w-10 items-center justify-center">
              <svg viewBox="0 0 24 24" className="h-5 w-5" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                <path d="M6 4h12M12 20V9M7 13l5-5 5 5" />
              </svg>
            </button>
          )}
          {/* touch-none on the handle only: the rest of the row still scrolls the page. */}
          <button
            type="button"
            ref={setActivatorNodeRef}
            {...attributes}
            {...listeners}
            aria-label={`Reorder ${entry.item.title}`}
            className="flex h-10 w-10 cursor-grab touch-none items-center justify-center active:cursor-grabbing"
          >
            <svg viewBox="0 0 24 24" className="h-5 w-5" fill="currentColor">
              {[6, 12, 18].flatMap((y) => [9, 15].map((x) => <circle key={`${x}-${y}`} cx={x} cy={y} r="1.6" />))}
            </svg>
          </button>
        </div>
      }
    />
  );
}

function ArrangeableWantList({ entries, onArrange }: { entries: LibraryEntry[]; onArrange: (ids: number[]) => void }) {
  const sensors = useSensors(
    useSensor(PointerSensor, { activationConstraint: { distance: 4 } }),
    useSensor(KeyboardSensor, { coordinateGetter: sortableKeyboardCoordinates })
  );
  const ids = entries.map((entry) => entry.id);

  function onDragEnd({ active, over }: DragEndEvent) {
    if (!over || active.id === over.id) return;
    onArrange(arrayMove(ids, ids.indexOf(Number(active.id)), ids.indexOf(Number(over.id))));
  }

  return (
    <DndContext
      sensors={sensors}
      collisionDetection={closestCenter}
      modifiers={[restrictToVerticalAxis, restrictToParentElement]}
      onDragEnd={onDragEnd}
    >
      <SortableContext items={ids} strategy={verticalListSortingStrategy}>
        <ul className="flex flex-col gap-2">
          {entries.map((entry, index) => (
            <SortableRow
              key={entry.id}
              entry={entry}
              first={index === 0}
              onTop={() => onArrange([entry.id, ...ids.filter((id) => id !== entry.id)])}
            />
          ))}
        </ul>
      </SortableContext>
    </DndContext>
  );
}

export function LibraryScreen() {
  const { userId } = useParams();
  const palette = usePalette();
  const [params, setParams] = useSearchParams();
  const current = TABS.find((option) => option.key === params.get("tab")) ?? TABS[0];
  const tab: Tab = current.key;
  const { data: library, error } = useShelf<Library>(userId ? `/entries?userId=${userId}` : "/entries");
  const [arrangeError, setArrangeError] = useState<string | null>(null);
  // One arrangement at a time, so two quick moves reach the server in the order they were made.
  const arranging = useRef(Promise.resolve());

  const query = params.get("q") ?? "";
  const ended = tab === "read" || tab === "dnf";
  const sort: Sort = SORTS.find((option) => option.key === params.get("sort") && (ended || option.key !== "rating"))?.key ?? "recent";
  const filters: Filters = {
    words: fold(query).split(/\s+/).filter(Boolean),
    genre: params.get("genre"),
    year: params.get("year"),
  };
  const filtering = filters.words.length > 0 || filters.genre !== null || (ended && filters.year !== null);

  /** Changes some of the URL's settings and keeps the rest. Empty removes one. */
  function update(changes: Record<string, string | null>) {
    const next = new URLSearchParams(params);
    for (const [key, value] of Object.entries(changes)) {
      if (value) next.set(key, value);
      else next.delete(key);
    }
    setParams(next, { replace: true });
  }

  const entries = library?.entries ?? [];
  const genres = [...new Set(entries.flatMap((entry) => entry.item.genres))].sort();
  const years = [...new Set(entries.flatMap((entry) => (tabOf(entry).includes(tab) && ended ? [...yearsOf(entry, tab)] : [])))]
    .sort()
    .reverse();

  const counts = new Map<Tab, number>();
  const shown: LibraryEntry[] = [];
  for (const entry of entries) {
    for (const entryTab of tabOf(entry)) {
      if (!matches(entry, entryTab, filters)) continue;
      counts.set(entryTab, (counts.get(entryTab) ?? 0) + 1);
      if (entryTab === tab) shown.push(entry);
    }
  }
  shown.sort((a, b) => compare(a, b, tab, sort));
  const arrangeable = !userId && tab === "want" && sort === "recent" && !filtering && shown.length > 1;

  /** Shows the new order at once, then saves it. `ids` is the whole want list. */
  function arrange(ids: number[]) {
    const ranks = new Map(ids.map((id, rank) => [id, rank]));
    patchCached<Library>("/entries", (value) => ({
      ...value,
      entries: value.entries.map((entry) => (ranks.has(entry.id) ? { ...entry, wantRank: ranks.get(entry.id)! } : entry)),
    }));
    setArrangeError(null);
    arranging.current = arranging.current.then(async () => {
      try {
        await shelfSend("put", "/want-order", { entryIds: ids });
      } catch (e) {
        setArrangeError(errorMessage(e));
        invalidateShelf();
      }
    });
  }

  // Where the matches are, when none are here.
  const elsewhere = filtering && shown.length === 0 ? TABS.filter((option) => option.key !== tab && counts.get(option.key)) : [];

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
              onClick={() => update({ tab: option.key })}
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

        {entries.length > 0 ? (
          <div className="mb-3">
            <div className="relative">
              <input
                type="search"
                value={query}
                onChange={(event) => update({ q: event.target.value })}
                placeholder="Search by title or author"
                aria-label="Search this library"
                className="w-full rounded-full border border-slate-200 bg-white py-2.5 pl-4 pr-10 text-[16px] outline-none focus:border-slate-400"
              />
              {query ? (
                <button
                  type="button"
                  onClick={() => update({ q: null })}
                  aria-label="Clear search"
                  className="absolute right-2 top-1/2 h-7 w-7 -translate-y-1/2 rounded-full text-slate-400"
                >
                  ✕
                </button>
              ) : null}
            </div>
            <div className="-mx-4 mt-2 flex items-center gap-2 overflow-x-auto px-4 pb-1 [scrollbar-width:none]">
              {genres.length ? (
                <FilterSelect
                  label="Genre"
                  value={filters.genre ?? ""}
                  options={[{ value: "", label: "All genres" }, ...genres.map((genre) => ({ value: genre, label: genre }))]}
                  onChange={(genre) => update({ genre })}
                />
              ) : null}
              {ended && years.length ? (
                <FilterSelect
                  label="Year"
                  value={filters.year ?? ""}
                  options={[{ value: "", label: "Any year" }, ...years.map((year) => ({ value: year, label: year }))]}
                  onChange={(year) => update({ year })}
                />
              ) : null}
              <FilterSelect
                label="Sort"
                value={sort}
                options={SORTS.filter((option) => ended || option.key !== "rating").map((option) => ({
                  value: option.key,
                  label: option.key === "recent" ? (tab === "want" ? "Sort: Your order" : "Sort: Recent") : `Sort: ${option.label}`,
                }))}
                onChange={(value) => update({ sort: value === "recent" ? null : value })}
              />
              {filtering ? (
                <button
                  type="button"
                  onClick={() => update({ q: null, genre: null, year: null })}
                  className="shrink-0 px-1 text-sm font-medium"
                  style={{ color: palette.accent }}
                >
                  Clear
                </button>
              ) : null}
            </div>
          </div>
        ) : null}

        {!library ? (
          error ? <EmptyNote>Couldn't load this shelf.</EmptyNote> : <Spinner />
        ) : shown.length === 0 && filtering ? (
          <EmptyNote>
            Nothing here matches.
            {elsewhere.map((option) => (
              <button
                key={option.key}
                type="button"
                onClick={() => update({ tab: option.key })}
                className="ml-2 font-medium"
                style={{ color: palette.accent }}
              >
                {counts.get(option.key)} in {option.label} ›
              </button>
            ))}
          </EmptyNote>
        ) : shown.length === 0 ? (
          <EmptyNote>{empty[tab]}</EmptyNote>
        ) : arrangeable ? (
          <>
            {arrangeError ? <p className="pb-2 text-sm text-rose-600">{arrangeError}</p> : null}
            <ArrangeableWantList entries={shown} onArrange={arrange} />
          </>
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
