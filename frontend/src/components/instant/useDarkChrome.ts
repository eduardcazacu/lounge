import { useEffect } from "react";

// Makes the browser's own furniture dark for as long as Instant is on screen,
// and puts it back afterwards.
//
// Installed to the home screen on iOS, the strip under the Dynamic Island is
// painted by the system rather than by the page, and it stayed white while the
// app under it was black. The colour it uses is not the fixed black element
// filling the window — it is the **document's** background, which nothing in
// the Lounge ever sets, so it is the default white canvas. A page that paints
// itself black over a white document is still a white document.
//
// Three things are set, and each is correct on its own terms rather than being
// a guess at which one iOS reads this year:
//
// - the document background, which is what a standalone web app samples for the
//   area above the content, and which also removes the white flash a rubber
//   band scroll can show at either end;
// - `color-scheme: dark`, which tells the engine this surface is dark so the
//   system draws its text and controls for a dark background;
// - the `theme-color` meta, which is the documented lever on iOS 15+ and on
//   Android, where it colours the status bar directly.
//
// All of it is undone on the way out, because the rest of the Lounge is a light
// page that follows the system.

const BLACK = "#000000";

export function useDarkChrome() {
  useEffect(() => {
    const root = document.documentElement;
    const { body } = document;

    const previous = {
      rootBackground: root.style.backgroundColor,
      bodyBackground: body.style.backgroundColor,
      colorScheme: root.style.colorScheme,
    };

    root.style.backgroundColor = BLACK;
    body.style.backgroundColor = BLACK;
    root.style.colorScheme = "dark";

    // The Lounge ships one of these already. If that ever changes, this still
    // works: it makes its own and takes it away again.
    let meta = document.querySelector<HTMLMetaElement>('meta[name="theme-color"]');
    const ownsMeta = meta === null;
    const previousContent = meta?.content ?? null;
    if (!meta) {
      meta = document.createElement("meta");
      meta.name = "theme-color";
      document.head.appendChild(meta);
    }
    meta.content = BLACK;

    return () => {
      root.style.backgroundColor = previous.rootBackground;
      body.style.backgroundColor = previous.bodyBackground;
      root.style.colorScheme = previous.colorScheme;
      if (ownsMeta) {
        meta?.remove();
      } else if (meta && previousContent !== null) {
        meta.content = previousContent;
      }
    };
  }, []);
}
