import type { ImportRowInput } from "@blogging-app/common";

// Reading a Goodreads library export (`goodreads_library_export.csv`, from
// My Books → Import and export) into import rows. It runs in the browser, so
// the file — private notes and all — never leaves the device; only the
// columns the shelf uses are sent.
//
// The quirks this handles are all real ones:
// - ISBNs are wrapped as Excel formulas, `="9780439023481"`, or `=""` when
//   empty, which most Kindle editions are.
// - Reviews are HTML (`<br/>`, entities) and contain commas, quotes and line
//   breaks inside a quoted field.
// - Dates are `YYYY/MM/DD`; a rating of 0 means unrated.
// - "Read Count" exists, but only the last read has a date, so a book is
//   imported as read once, on that date.
// - Goodreads has no DNF. People make a shelf for it, named however they like,
//   so the reader picks which one means "did not finish".

/** RFC 4180: quoted fields, doubled quotes, line breaks inside quotes, CRLF. */
export function parseCsv(text: string): string[][] {
  const rows: string[][] = [];
  let row: string[] = [];
  let field = "";
  let quoted = false;
  const source = text.charCodeAt(0) === 0xfeff ? text.slice(1) : text;

  for (let index = 0; index < source.length; index += 1) {
    const char = source[index];
    if (quoted) {
      if (char === '"') {
        if (source[index + 1] === '"') {
          field += '"';
          index += 1;
        } else {
          quoted = false;
        }
      } else {
        field += char;
      }
    } else if (char === '"') {
      quoted = true;
    } else if (char === ",") {
      row.push(field);
      field = "";
    } else if (char === "\n" || char === "\r") {
      if (char === "\r" && source[index + 1] === "\n") index += 1;
      row.push(field);
      rows.push(row);
      row = [];
      field = "";
    } else {
      field += char;
    }
  }
  if (field !== "" || row.length > 0) {
    row.push(field);
    rows.push(row);
  }
  return rows.filter((cells) => cells.some((cell) => cell.trim() !== ""));
}

const ENTITIES: Record<string, string> = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: " " };

/** Goodreads review HTML as plain text, keeping its paragraph breaks. */
export function reviewText(html: string): string {
  return html
    .replace(/<br\s*\/?>/gi, "\n")
    .replace(/<\/p>\s*<p[^>]*>/gi, "\n\n")
    .replace(/<[^>]+>/g, "")
    .replace(/&(#\d+|#x[\da-f]+|\w+);/gi, (whole, code: string) => {
      if (code.startsWith("#x") || code.startsWith("#X")) return String.fromCodePoint(Number.parseInt(code.slice(2), 16));
      if (code.startsWith("#")) return String.fromCodePoint(Number.parseInt(code.slice(1), 10));
      return ENTITIES[code.toLowerCase()] ?? whole;
    })
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

function isbn(cell: string | undefined, length: 10 | 13) {
  const value = (cell ?? "").replace(/^="?|"$/g, "").replace(/[^\dXx]/g, "").toUpperCase();
  return length === 13 ? (/^\d{13}$/.test(value) ? value : null) : /^\d{9}[\dX]$/.test(value) ? value : null;
}

function day(cell: string | undefined) {
  const match = /^(\d{4})[/-](\d{1,2})[/-](\d{1,2})$/.exec((cell ?? "").trim());
  if (!match) return null;
  return `${match[1]}-${match[2].padStart(2, "0")}-${match[3].padStart(2, "0")}`;
}

function positiveInt(cell: string | undefined) {
  const value = Number.parseInt((cell ?? "").trim(), 10);
  return Number.isFinite(value) && value > 0 ? value : null;
}

function shelvesOf(cell: string | undefined) {
  return (cell ?? "")
    .split(",")
    .map((shelf) => shelf.trim().toLowerCase())
    .filter(Boolean);
}

/** A shelf name that probably means "did not finish", to preselect. */
export function looksLikeDnfShelf(shelf: string) {
  return /\bdnf\b|did.?not.?finish|abandon|gave.?up|unfinished|not.?finished/i.test(shelf);
}

export type GoodreadsExport = {
  /** Every row the export holds, one per book. */
  books: GoodreadsBook[];
  /** Custom shelves found, for the "which one is DNF" choice. */
  shelves: string[];
};

export type GoodreadsBook = {
  ref: string;
  title: string;
  creators: string[];
  isbn13: string | null;
  isbn10: string | null;
  totalUnits: number | null;
  year: number | null;
  exclusiveShelf: string;
  shelves: string[];
  finishedOn: string | null;
  addedOn: string | null;
  rating: number | null;
  review: string | null;
};

export class NotAGoodreadsExport extends Error {}

const BUILT_IN_SHELVES = new Set(["read", "currently-reading", "to-read"]);

export function readGoodreadsExport(text: string): GoodreadsExport {
  const [header, ...rows] = parseCsv(text);
  const column = new Map((header ?? []).map((name, index) => [name.trim(), index]));
  for (const required of ["Book Id", "Title", "Exclusive Shelf"]) {
    if (!column.has(required)) {
      throw new NotAGoodreadsExport(
        "This doesn't look like a Goodreads export. On Goodreads, go to My Books → Import and export → Export Library, and pick the file it makes."
      );
    }
  }
  const cell = (cells: string[], name: string) => {
    const index = column.get(name);
    return index === undefined ? undefined : cells[index];
  };

  const shelves = new Set<string>();
  const books: GoodreadsBook[] = [];
  for (const cells of rows) {
    const ref = cell(cells, "Book Id")?.trim();
    const title = cell(cells, "Title")?.trim();
    if (!ref || !title) continue;

    const creators = [cell(cells, "Author"), ...(cell(cells, "Additional Authors") ?? "").split(",")]
      .map((name) => (name ?? "").trim())
      .filter(Boolean)
      .slice(0, 10);
    const exclusiveShelf = (cell(cells, "Exclusive Shelf") ?? "").trim().toLowerCase();
    const bookShelves = shelvesOf(cell(cells, "Bookshelves"));
    for (const shelf of [exclusiveShelf, ...bookShelves]) {
      if (shelf && !BUILT_IN_SHELVES.has(shelf)) shelves.add(shelf);
    }
    const stars = positiveInt(cell(cells, "My Rating"));
    const review = reviewText(cell(cells, "My Review") ?? "");

    books.push({
      ref,
      title: title.slice(0, 300),
      creators,
      isbn13: isbn(cell(cells, "ISBN13"), 13),
      isbn10: isbn(cell(cells, "ISBN"), 10),
      totalUnits: positiveInt(cell(cells, "Number of Pages")),
      year: positiveInt(cell(cells, "Original Publication Year")) ?? positiveInt(cell(cells, "Year Published")),
      exclusiveShelf,
      shelves: bookShelves,
      finishedOn: day(cell(cells, "Date Read")),
      addedOn: day(cell(cells, "Date Added")),
      // Goodreads rates in whole stars, 1..5; the shelf in half stars, 1..10.
      rating: stars && stars <= 5 ? stars * 2 : null,
      review: review ? review.slice(0, 10000) : null,
    });
  }
  return { books, shelves: [...shelves].sort() };
}

export type ImportChoices = {
  /** The shelf that means "did not finish", or null for none. */
  dnfShelf: string | null;
  /** Bring ratings and reviews along, or only the books. */
  includeReviews: boolean;
};

/**
 * What each book becomes on the shelf, or null for a book on a custom
 * exclusive shelf that means nothing here — it is counted, not guessed at.
 */
export function statusOf(book: GoodreadsBook, choices: ImportChoices): ImportRowInput["status"] | null {
  if (choices.dnfShelf && (book.exclusiveShelf === choices.dnfShelf || book.shelves.includes(choices.dnfShelf))) {
    return "dnf";
  }
  if (book.exclusiveShelf === "read") return "finished";
  if (book.exclusiveShelf === "currently-reading") return "reading";
  if (book.exclusiveShelf === "to-read") return "want";
  return null;
}

export function toImportRows(books: GoodreadsBook[], choices: ImportChoices): ImportRowInput[] {
  const rows: ImportRowInput[] = [];
  for (const book of books) {
    const status = statusOf(book, choices);
    if (!status) continue;
    // A rating or review only means something on a book that was read.
    const reviewed = choices.includeReviews && (status === "finished" || status === "dnf");
    rows.push({
      ref: book.ref,
      title: book.title,
      creators: book.creators,
      isbn13: book.isbn13,
      isbn10: book.isbn10,
      totalUnits: book.totalUnits,
      year: book.year,
      status,
      finishedOn: status === "finished" || status === "dnf" ? book.finishedOn : null,
      addedOn: book.addedOn,
      rating: reviewed ? book.rating : null,
      review: reviewed ? book.review : null,
    });
  }
  return rows;
}
