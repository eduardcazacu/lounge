import { useState } from "react";
import { useSearchParams } from "react-router-dom";
import { localDay, useShelf } from "./api";
import type { GenreStats, Stats } from "./api";
import { Card, Cover, EmptyNote, SectionTitle, Spinner, Stars, TopBar } from "./ui";
import { formatDay, usePalette } from "./format";

// The expanded stats, for one year or for all time — the same screen either
// way, picked from the row at the top. Headline numbers are tiles, not charts;
// the two series over time get a chart each on their own axis rather than one
// chart with two scales. Every bar is a single series in the reader's accent,
// and hovering or tapping one reads its value out above the chart, so nothing
// depends on judging a bar's height.

const MONTH_INITIALS = ["J", "F", "M", "A", "M", "J", "J", "A", "S", "O", "N", "D"];
const MONTH_NAMES = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];

const plural = (value: number, word: string) => `${value.toLocaleString()} ${word}${value === 1 ? "" : "s"}`;

function Tile({ value, label, sub }: { value: string; label: string; sub?: string }) {
  const palette = usePalette();
  return (
    <div className="rounded-2xl bg-white p-3 shadow-sm">
      <div className="truncate text-2xl font-semibold tabular-nums" style={{ color: palette.text }}>
        {value}
      </div>
      <div className="text-xs leading-tight text-slate-500">{label}</div>
      {sub ? <div className="mt-0.5 text-[11px] text-slate-400">{sub}</div> : null}
    </div>
  );
}

type Bar = { short: string; long: string; value: number };

function Bars({ bars, unit, color }: { bars: Bar[]; unit: (value: number) => string; color: string }) {
  const [selected, setSelected] = useState<number | null>(null);
  const max = Math.max(1, ...bars.map((bar) => bar.value));
  const total = bars.reduce((sum, bar) => sum + bar.value, 0);
  return (
    <Card>
      <div className="h-5 text-sm text-slate-600">
        {selected !== null ? (
          <>
            <span className="font-medium text-slate-900">{bars[selected].long}</span> · {unit(bars[selected].value)}
          </>
        ) : (
          <span className="text-slate-400">Tap a bar</span>
        )}
      </div>
      <div className="mt-2 flex h-32 items-end gap-[2px]" onMouseLeave={() => setSelected(null)} role="list">
        {bars.map((bar, index) => (
          <button
            key={bar.long}
            type="button"
            role="listitem"
            aria-label={`${bar.long}: ${unit(bar.value)}`}
            onMouseEnter={() => setSelected(index)}
            onFocus={() => setSelected(index)}
            onClick={() => setSelected(index)}
            className="flex h-full flex-1 items-end"
          >
            <span
              className="block w-full rounded-t transition-opacity"
              style={{
                height: bar.value > 0 ? `${Math.max(3, (bar.value / max) * 100)}%` : "2px",
                background: bar.value > 0 ? color : "#e2e8f0",
                opacity: selected === null || selected === index ? 1 : 0.45,
              }}
            />
          </button>
        ))}
      </div>
      <div className="mt-1 flex gap-[2px] border-t border-slate-200 pt-1 text-center text-[10px] text-slate-400">
        {bars.map((bar) => (
          <span key={bar.long} className="flex-1 truncate">
            {bar.short}
          </span>
        ))}
      </div>
      <details className="mt-2 text-xs text-slate-500">
        <summary className="cursor-pointer">As a table · {unit(total)} in all</summary>
        <table className="mt-1 w-full tabular-nums">
          <tbody>
            {bars.map((bar) => (
              <tr key={bar.long} className="border-t border-slate-100">
                <td className="py-0.5">{bar.long}</td>
                <td className="py-0.5 text-right text-slate-700">{unit(bar.value)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </details>
    </Card>
  );
}

/**
 * Genres, by books finished or by pages read. A book counts toward each of
 * its genres, so the rows add up to more than the totals; the note says so.
 */
function Genres({ genres }: { genres: GenreStats[] }) {
  const palette = usePalette();
  const [measure, setMeasure] = useState<"books" | "pages">(genres.some((genre) => genre.books > 0) ? "books" : "pages");
  const rows = [...genres].sort((a, b) => b[measure] - a[measure] || a.genre.localeCompare(b.genre)).filter((row) => row[measure] > 0);
  const max = Math.max(1, ...rows.map((row) => row[measure]));
  const top = rows[0];
  const rated = [...genres].filter((row) => row.averageRating !== null).sort((a, b) => b.averageRating! - a.averageRating!);
  const favourite = rated.length > 1 ? rated[0] : null;

  return (
    <Card>
      <div className="flex items-center justify-between gap-2">
        <div className="min-w-0 text-sm text-slate-600">
          {top ? (
            <>
              Mostly <span className="font-semibold text-slate-900">{top.genre}</span>
              {favourite && favourite.genre !== top.genre ? (
                <>
                  , rated highest: <span className="font-semibold text-slate-900">{favourite.genre}</span>
                </>
              ) : null}
            </>
          ) : null}
        </div>
        <div className="flex shrink-0 rounded-full bg-slate-100 p-0.5 text-xs font-medium">
          {(["books", "pages"] as const).map((option) => (
            <button
              key={option}
              type="button"
              onClick={() => setMeasure(option)}
              className={`rounded-full px-2.5 py-1 ${measure === option ? "bg-white text-slate-900 shadow-sm" : "text-slate-500"}`}
            >
              {option === "books" ? "Books" : "Pages"}
            </button>
          ))}
        </div>
      </div>
      <ul className="mt-3 flex flex-col gap-2.5">
        {rows.map((row) => (
          <li key={row.genre} className="text-sm">
            <div className="flex items-baseline justify-between gap-2">
              <span className="truncate text-slate-800">{row.genre}</span>
              <span className="flex shrink-0 items-center gap-2 tabular-nums text-slate-500">
                {row.averageRating !== null ? (
                  <span className="text-xs text-amber-600" title="Average stars">
                    ★ {(row.averageRating / 2).toFixed(1)}
                  </span>
                ) : null}
                {measure === "books" ? plural(row.books, "book") : plural(row.pages, "page")}
              </span>
            </div>
            <div className="mt-1 h-2 rounded bg-slate-100">
              <div className="h-full rounded" style={{ width: `${(row[measure] / max) * 100}%`, background: palette.accent }} />
            </div>
          </li>
        ))}
      </ul>
      <p className="mt-3 text-[11px] text-slate-400">A book counts toward each of its genres.</p>
    </Card>
  );
}

export function StatsScreen() {
  const palette = usePalette();
  const [params, setParams] = useSearchParams();
  const thisYear = String(new Date().getFullYear());
  const period = params.get("year") ?? thisYear;
  const allTime = period === "all";
  const { data, error } = useShelf<Stats>(`/stats?year=${period}&today=${localDay()}`);

  if (!data) {
    return (
      <>
        <TopBar title="Stats" />
        {error ? <p className="p-8 text-center text-sm text-slate-500">Couldn't load your stats.</p> : <Spinner />}
      </>
    );
  }

  const { stats } = data;
  const nothing = stats.booksFinished === 0 && stats.pages === 0 && stats.dnf === 0;
  const periods = ["all", ...data.years.map(String)];
  const bars = (pick: (bucket: Stats["stats"]["buckets"][number]) => number): Bar[] =>
    stats.buckets.map((bucket) =>
      allTime
        ? { short: `'${String(bucket.key).slice(2)}`, long: String(bucket.key), value: pick(bucket) }
        : { short: MONTH_INITIALS[bucket.key - 1], long: MONTH_NAMES[bucket.key - 1], value: pick(bucket) }
    );
  const over = allTime ? "year" : "month";

  return (
    <>
      <TopBar title="Stats" />
      <main className="mx-auto max-w-xl px-4 pb-10">
        <div className="-mx-4 flex gap-2 overflow-x-auto px-4 py-3 [scrollbar-width:none]">
          {periods.map((option) => (
            <button
              key={option}
              type="button"
              onClick={() => setParams(option === thisYear ? {} : { year: option }, { replace: true })}
              className="shrink-0 rounded-full px-4 py-1.5 text-sm font-medium shadow-sm"
              style={option === period ? { background: palette.accent, color: "white" } : { background: "white", color: "#475569" }}
            >
              {option === "all" ? "All time" : option}
            </button>
          ))}
        </div>

        {nothing ? (
          <EmptyNote>{allTime ? "Nothing logged yet." : `Nothing logged in ${period}.`}</EmptyNote>
        ) : (
          <>
            <div className="grid grid-cols-2 gap-2 sm:grid-cols-3">
              <Tile
                value={stats.booksFinished.toLocaleString()}
                label={`book${stats.booksFinished === 1 ? "" : "s"} finished`}
                sub={stats.rereads > 0 ? `${stats.distinctBooks} different · ${stats.rereads} re-read${stats.rereads === 1 ? "" : "s"}` : undefined}
              />
              <Tile value={stats.pages.toLocaleString()} label="pages read" />
              <Tile value={stats.pagesPerReadingDay.toLocaleString()} label="pages a reading day" sub={plural(stats.readingDays, "reading day")} />
              <Tile
                value={data.currentStreak.toLocaleString()}
                label="day streak now"
                sub={`best ${allTime ? "ever" : "this year"}: ${stats.longestStreak}`}
              />
              <Tile
                value={stats.averageRating !== null ? (stats.averageRating / 2).toFixed(1) : "–"}
                label="average stars"
                sub={plural(stats.ratings.length, "rated book")}
              />
              <Tile value={stats.dnf.toLocaleString()} label="did not finish" />
            </div>

            {stats.buckets.length > 0 ? (
              <>
                <SectionTitle>Pages by {over}</SectionTitle>
                <Bars bars={bars((bucket) => bucket.pages)} unit={(value) => plural(value, "page")} color={palette.accent} />

                <SectionTitle>Books by {over}</SectionTitle>
                <Bars bars={bars((bucket) => bucket.books)} unit={(value) => plural(value, "book")} color={palette.accent} />
              </>
            ) : null}

            {stats.genres.length ? (
              <>
                <SectionTitle>Genres</SectionTitle>
                <Genres key={period} genres={stats.genres} />
              </>
            ) : null}

            {stats.recommended + stats.notRecommended > 0 ? (
              <>
                <SectionTitle>Would recommend</SectionTitle>
                <Card>
                  <p className="text-sm text-slate-700">
                    👍 {stats.recommended} · 👎 {stats.notRecommended}
                  </p>
                </Card>
              </>
            ) : null}

            {stats.longest || stats.bestDay ? (
              <>
                <SectionTitle>Records</SectionTitle>
                <div className="flex flex-col gap-2">
                  {stats.longest ? (
                    <Card className="!p-3">
                      <div className="flex items-center gap-3">
                        <Cover item={stats.longest} size="xs" />
                        <div className="min-w-0">
                          <div className="text-xs text-slate-500">Longest book</div>
                          <div className="truncate font-medium">{stats.longest.title}</div>
                          <div className="text-xs text-slate-500">{plural(stats.longest.totalUnits, "page")}</div>
                        </div>
                      </div>
                    </Card>
                  ) : null}
                  {stats.shortest && stats.shortest.title !== stats.longest?.title ? (
                    <Card className="!p-3">
                      <div className="flex items-center gap-3">
                        <Cover item={stats.shortest} size="xs" />
                        <div className="min-w-0">
                          <div className="text-xs text-slate-500">Shortest book</div>
                          <div className="truncate font-medium">{stats.shortest.title}</div>
                          <div className="text-xs text-slate-500">{plural(stats.shortest.totalUnits, "page")}</div>
                        </div>
                      </div>
                    </Card>
                  ) : null}
                  {stats.bestDay ? (
                    <Card className="!p-3">
                      <div className="text-xs text-slate-500">Best day</div>
                      <div className="font-medium">
                        {plural(stats.bestDay.pages, "page")} on {formatDay(stats.bestDay.day)}
                      </div>
                    </Card>
                  ) : null}
                </div>
              </>
            ) : null}

            {stats.ratings.length ? (
              <>
                <SectionTitle>Ratings</SectionTitle>
                <Card>
                  <ul className="flex flex-col gap-1">
                    {[10, 9, 8, 7, 6, 5, 4, 3, 2, 1].map((rating) => {
                      const count = stats.ratings.filter((value) => value === rating).length;
                      if (count === 0) return null;
                      return (
                        <li key={rating} className="flex items-center justify-between text-sm">
                          <Stars rating={rating} size={13} />
                          <span className="tabular-nums text-slate-600">{count}</span>
                        </li>
                      );
                    })}
                  </ul>
                </Card>
              </>
            ) : null}
          </>
        )}
      </main>
    </>
  );
}
