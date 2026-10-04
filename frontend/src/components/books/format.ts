import { useEffect, useState } from "react";
import { getThemePalette } from "../../themes";
import type { CatalogEdition, Item, ShelfStatus } from "./api";

// Formatting and the reader's palette: the non-component half of ui.tsx.

/** The signed-in reader's palette, following the account page's theme picker. */
export function usePalette() {
  const [themeKey, setThemeKey] = useState(() => localStorage.getItem("themeKey"));
  useEffect(() => {
    const sync = () => setThemeKey(localStorage.getItem("themeKey"));
    window.addEventListener("storage", sync);
    window.addEventListener("profile-picture-changed", sync);
    return () => {
      window.removeEventListener("storage", sync);
      window.removeEventListener("profile-picture-changed", sync);
    };
  }, []);
  return getThemePalette(themeKey);
}

/** Where a book stands on a shelf, as a tag says it. */
export const SHELF_LABEL: Record<ShelfStatus, string> = {
  reading: "Reading",
  read: "Read",
  dnf: "Didn't finish",
  want: "Want to read",
};

export function byline(item: Pick<Item, "creators">) {
  return item.creators.length ? item.creators.slice(0, 2).join(", ") : "";
}

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

/** "3 Mar", or "3 Mar 2024" outside the current year. Days are local already. */
export function formatDay(day: string | null, today = new Date()) {
  if (!day) return "";
  const [year, month, date] = day.split("-").map(Number);
  const base = `${date} ${MONTHS[month - 1]}`;
  return year === today.getFullYear() ? base : `${base} ${year}`;
}

export function percentText(fraction: number | null) {
  return fraction === null ? "" : `${Math.round(fraction * 100)}%`;
}

/** "just now", "12 min ago", "3 h ago", then the day. */
export function agoText(iso: string, now = new Date()) {
  const minutes = Math.floor((now.getTime() - new Date(iso).getTime()) / 60000);
  if (minutes < 1) return "just now";
  if (minutes < 60) return `${minutes} min ago`;
  if (minutes < 24 * 60) return `${Math.floor(minutes / 60)} h ago`;
  const date = new Date(iso);
  const day = `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
  return formatDay(day, now);
}

const LANGUAGES: Record<string, string> = {
  eng: "English",
  pol: "Polish",
  ger: "German",
  fre: "French",
  spa: "Spanish",
  ita: "Italian",
  por: "Portuguese",
  dut: "Dutch",
  rus: "Russian",
  ukr: "Ukrainian",
  cze: "Czech",
  slo: "Slovak",
  hun: "Hungarian",
  rum: "Romanian",
  bul: "Bulgarian",
  hrv: "Croatian",
  srp: "Serbian",
  swe: "Swedish",
  nor: "Norwegian",
  dan: "Danish",
  fin: "Finnish",
  gre: "Greek",
  tur: "Turkish",
  heb: "Hebrew",
  ara: "Arabic",
  chi: "Chinese",
  jpn: "Japanese",
  kor: "Korean",
};

export function languageName(code: string | null) {
  return code ? LANGUAGES[code] ?? code.toUpperCase() : null;
}

/** "English · Orbit · 2022 · Paperback · 352 pages", leaving out what is unknown. */
export function editionLine(edition: Pick<CatalogEdition, "language" | "publisher" | "year" | "format" | "totalUnits">) {
  return [
    languageName(edition.language),
    edition.publisher,
    edition.year,
    edition.format,
    edition.totalUnits ? `${edition.totalUnits} pages` : null,
  ]
    .filter(Boolean)
    .join(" · ");
}
