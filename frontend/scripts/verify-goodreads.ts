// Checks the Goodreads export reader against a file shaped like a real one.
//
//   cd backend && npx tsx ../frontend/scripts/verify-goodreads.ts
//
// Every quirk below is one Goodreads' export actually has. Getting one wrong
// fails quietly: a review cut off at its first comma, a rating doubled twice,
// a Kindle book with no ISBN dropped, a re-read imported as three.

import {
  looksLikeDnfShelf,
  parseCsv,
  readGoodreadsExport,
  reviewText,
  toImportRows,
} from "../src/components/books/goodreads";

let checks = 0;
let failures = 0;
function check(label: string, ok: boolean, detail?: unknown) {
  checks += 1;
  if (ok) console.log(`  ok   ${label}`);
  else {
    failures += 1;
    console.log(`  FAIL ${label}${detail === undefined ? "" : ` -> ${JSON.stringify(detail)}`}`);
  }
}

const header =
  "Book Id,Title,Author,Author l-f,Additional Authors,ISBN,ISBN13,My Rating,Average Rating,Publisher,Binding,Number of Pages,Year Published,Original Publication Year,Date Read,Date Added,Bookshelves,Bookshelves with positions,Exclusive Shelf,My Review,Spoiler,Private Notes,Read Count,Owned Copies";
const file = [
  "﻿" + header,
  // Read three times, rated, a review with commas, quotes, HTML and a line break.
  `2767052,"The Hunger Games (The Hunger Games, #1)",Suzanne Collins,"Collins, Suzanne",,"=""0439023483""","=""9780439023481""",4,4.33,Scholastic Press,Hardcover,374,2008,2008,2024/03/15,2023/01/02,,,read,"Gripping, ""brutal"" and fast.<br/><br/>Would read again &amp; again.",,"private, never sent",3,0`,
  // Kindle: no ISBN, unrated, no review, no date read.
  `41865,Twilight,Stephenie Meyer,"Meyer, Stephenie",,"=""""","=""""",0,3.6,Little Brown,Kindle Edition,,2005,2005,,2022/11/30,,,read,,,,1,0`,
  // Want, with two authors.
  `7613,Good Omens,Terry Pratchett,"Pratchett, Terry",Neil Gaiman,"=""0060853980""","=""9780060853983""",0,4.25,,Paperback,412,2006,1990,,2024/06/01,to-read,to-read (#3),to-read,,,,0,0`,
  // Currently reading.
  `1,Piranesi,Susanna Clarke,"Clarke, Susanna",,"=""""","=""9781635575637""",0,4.2,,Hardcover,272,2020,2020,,2026/09/20,currently-reading,,currently-reading,,,,0,0`,
  // Abandoned: a custom shelf alongside "read".
  `2,Ulysses,James Joyce,"Joyce, James",,"=""""","=""""",2,3.7,,Paperback,730,1990,1922,2025/02/01,2025/01/01,"did-not-finish, classics","did-not-finish (#1)",read,Not for me.,,,1,0`,
  // A custom exclusive shelf that means nothing here.
  `3,Some Book,An Author,"Author, An",,"=""""","=""""",0,3,,Paperback,100,2001,2001,,2024/01/01,lent-out,,lent-out,,,,0,0`,
].join("\r\n") + "\r\n";

console.log("CSV");
{
  const rows = parseCsv('a,"b, c","d ""e""",\r\n"multi\nline",x,,\n');
  check("quoted commas, doubled quotes, a trailing empty field", JSON.stringify(rows[0]) === JSON.stringify(["a", "b, c", 'd "e"', ""]), rows[0]);
  check("a line break inside quotes stays in the field", rows[1][0] === "multi\nline", rows[1]);
  check("blank lines are not rows", parseCsv("a\n\n\nb\n").length === 2);
}

console.log("Reviews");
check("breaks become newlines, entities decode", reviewText("One<br/>two<br />three &amp; &quot;four&quot; &#39;five&#39;") === "One\ntwo\nthree & \"four\" 'five'");
check("tags go", reviewText("<b>bold</b> and <i>it</i>") === "bold and it");

console.log("The export");
const exported = readGoodreadsExport(file);
const byRef = new Map(exported.books.map((book) => [book.ref, book]));
const hunger = byRef.get("2767052")!;
check("every book is read", exported.books.length === 6, exported.books.length);
check("a title with a comma survives", hunger.title === "The Hunger Games (The Hunger Games, #1)", hunger.title);
check("ISBNs are unwrapped from their formulas", hunger.isbn13 === "9780439023481" && hunger.isbn10 === "0439023483", hunger);
check("an empty formula is no ISBN", byRef.get("41865")!.isbn13 === null && byRef.get("41865")!.isbn10 === null);
check("dates become days", hunger.finishedOn === "2024-03-15" && hunger.addedOn === "2023-01-02", hunger);
check("whole stars become half-star units", hunger.rating === 8, hunger.rating);
check("an unrated book is unrated", byRef.get("41865")!.rating === null);
check("the review is plain text with its paragraphs", hunger.review === 'Gripping, "brutal" and fast.\n\nWould read again & again.', hunger.review);
check("the original year wins over the edition's", byRef.get("7613")!.year === 1990);
check("additional authors are kept", byRef.get("7613")!.creators.join("|") === "Terry Pratchett|Neil Gaiman");
check("custom shelves are offered", exported.shelves.join() === "classics,did-not-finish,lent-out", exported.shelves);
check("a DNF shelf is recognised", looksLikeDnfShelf("did-not-finish") && looksLikeDnfShelf("dnf") && !looksLikeDnfShelf("classics"));

console.log("Rows");
{
  const rows = toImportRows(exported.books, { dnfShelf: "did-not-finish", includeReviews: true });
  const row = new Map(rows.map((r) => [r.ref, r]));
  check("read, reading and want map across", row.get("2767052")?.status === "finished" && row.get("1")?.status === "reading" && row.get("7613")?.status === "want");
  check("the chosen shelf makes a DNF even beside 'read'", row.get("2")?.status === "dnf", row.get("2"));
  check("a shelf that means nothing here is left out", !row.has("3"));
  check("a book read three times is one row, on its one date", rows.filter((r) => r.ref === "2767052").length === 1 && row.get("2767052")?.finishedOn === "2024-03-15");
  check("a want carries no rating or review", row.get("7613")?.rating === null && row.get("7613")?.review === null);
  check("private notes are never sent", !JSON.stringify(rows).includes("private, never sent"));

  const bare = toImportRows(exported.books, { dnfShelf: null, includeReviews: false });
  check("without a DNF shelf, the abandoned book is read", bare.find((r) => r.ref === "2")?.status === "finished");
  check("reviews can be left behind", bare.every((r) => r.rating === null && r.review === null));
}

console.log("Not an export");
{
  let threw = false;
  try {
    readGoodreadsExport("Title,Author\nDune,Herbert\n");
  } catch {
    threw = true;
  }
  check("another CSV is refused, not half-imported", threw);
}

console.log(`\n${checks - failures}/${checks} checks passed`);
if (failures > 0) process.exit(1);
