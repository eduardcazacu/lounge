import { useState } from "react";
import type { KeyboardEvent, MouseEvent } from "react";
import { reviewSegments } from "@blogging-app/common";

// A review's text with the passages its reviewer marked as spoilers ("||like
// this||", `reviewSegments` in common/). For a reader the server says hasn't
// finished the book (`mask`), each passage is a bar that one tap reveals, on
// its own: the sentence next to it might be the one they wanted. For everyone
// else it reads as text, tinted, so the reviewer and those who have finished
// can see what was hidden. Outside Books' code because the Lounge's review card
// draws it too, and would otherwise pull Books into the blog's chunk.

function Passage({ text, mask }: { text: string; mask: boolean }) {
  const [shown, setShown] = useState(false);
  if (!mask || shown) {
    return <span className="rounded bg-amber-50 px-0.5 [box-decoration-break:clone]">{text}</span>;
  }
  const reveal = (event: MouseEvent | KeyboardEvent) => {
    // Inside cards and links that open on click.
    event.preventDefault();
    event.stopPropagation();
    setShown(true);
  };
  return (
    <span
      role="button"
      tabIndex={0}
      aria-label="Spoiler, tap to show"
      title="Spoiler, tap to show"
      onClick={reveal}
      onKeyDown={(event) => {
        if (event.key === "Enter" || event.key === " ") reveal(event);
      }}
      className="cursor-pointer select-none rounded bg-slate-300 px-0.5 text-transparent [box-decoration-break:clone]"
    >
      {text}
    </span>
  );
}

export function SpoilerText({ body, mask }: { body: string; mask: boolean }) {
  return (
    <>
      {reviewSegments(body).map((segment, index) =>
        segment.spoiler ? <Passage key={index} text={segment.text} mask={mask} /> : segment.text
      )}
    </>
  );
}
