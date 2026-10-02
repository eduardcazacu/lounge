import { Navigate, useLocation } from "react-router-dom";
import { BooksApp } from "../components/books/BooksApp";
import { getAuthHeader } from "../lib/auth";

// Lounge Books: a reading log, a review feed and a spoiler-safe book club.
//
// Like Instant, this is an app inside the Lounge rather than a page of it — no
// app bar, its own bottom tabs, its own home-screen icon (books.html) — and
// the way back to the Lounge is the avatar, top-left. Unlike Instant it keeps
// the Lounge's light look and the reader's palette, because it is a place for
// reading and writing rather than a camera. See wiki/books.md.

export const Books = () => {
  const location = useLocation();
  if (!getAuthHeader()) {
    const next = encodeURIComponent(location.pathname + location.search);
    return <Navigate to={`/signin?next=${next}`} replace />;
  }
  return <BooksApp />;
};
