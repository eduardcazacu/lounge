import { useCallback, useRef, useState } from "react";
import axios from "axios";
import type { InstantDurationMode } from "@blogging-app/common";
import { BACKEND_URL } from "../../config";
import { getAuthHeader } from "../../lib/auth";
import { encodeToWebp } from "../../lib/image";
import { sealForDevices, type RecipientDeviceKey } from "../../lib/instantCrypto";
import { applyFilter, type FilterId } from "./filters";
import { composite, type Caption, type Stroke } from "./overlay";

// Sends in flight, ported from `ios/Instant/Core/Store/Outbox.swift`.
//
// Tapping Send closes the compose screen at once and the work carries on here,
// because rendering and sealing a photo used to hold that screen for seconds.
// What the sender sees instead is `SendStatusPill`.
//
// **Several recipients are several instants.** The photo is rendered and
// encoded once for all of them — the encode is the slow part and the result is
// the same for everybody — then each is sealed to that person's devices and
// uploaded on its own, so each fails, retries and is read once independently.
// The wire format stays single-recipient; see wiki/decisions.md.
//
// One thing the native app has and this cannot: a send does not survive the tab
// being closed. iOS writes the sealed bytes to disk before uploading and
// finishes them on the next launch. There is no equivalent worth trusting here
// — a page that is gone runs nothing — so the pill stays up until the send
// lands, and a reload mid-send loses it.

// Portrait profile. This is the whole bandwidth story for Instant: the bytes
// are encrypted and served from an authenticated endpoint, so Cloudflare's
// image transforms cannot touch them on the way out.
const INSTANT_ENCODE_OPTIONS = {
  maxWidth: 1080,
  maxHeight: 1920,
  targetBytes: 250_000,
  qualityLevels: [0.9, 0.82, 0.74, 0.66],
  minLongEdge: 640,
};

/// How long "Sent" stays up.
const CONFIRMATION_MS = 2000;

export type InstantRecipient = { userId: number; name: string };

/// The photo and every choice made about it, none of them applied yet. The
/// render happens here, after the compose screen has already closed.
export type InstantDraft = {
  image: HTMLImageElement;
  filter: FilterId;
  strokes: Stroke[];
  captions: Caption[];
  duration: InstantDurationMode;
};

export type OutboxItem = {
  id: string;
  recipient: InstantRecipient;
  phase: "sending" | "sent" | "failed";
  /// Only on a failure, and it is the reason rather than a restatement.
  message?: string;
};

function messageFor(error: unknown): string {
  if (axios.isAxiosError(error) && typeof error.response?.data?.msg === "string") {
    return error.response.data.msg;
  }
  return error instanceof Error ? error.message : "Could not send that instant.";
}

export function useOutbox({
  currentUserId,
  onSent,
}: {
  currentUserId: number | null;
  /// Run once the server has accepted a send, so recency and the receipt move.
  /// A send that failed must not answer a streak.
  onSent: (userId: number) => void;
}) {
  const [items, setItems] = useState<OutboxItem[]>([]);
  /// What a send in flight reads, rather than the state its callback closed
  /// over — which by the time the upload starts may be a render behind.
  const itemsRef = useRef<OutboxItem[]>([]);
  itemsRef.current = items;
  const drafts = useRef(new Map<string, InstantDraft>());
  /// The encoded photo, shared by every send made from the same draft, so a
  /// photo going to five people is encoded once rather than five times.
  const renders = useRef(new Map<string, Promise<Blob>>());

  const setPhase = useCallback((id: string, phase: OutboxItem["phase"], message?: string) => {
    setItems((current) =>
      current.map((item) => (item.id === id ? { ...item, phase, message } : item))
    );
  }, []);

  const dismiss = useCallback((id: string) => {
    drafts.current.delete(id);
    renders.current.delete(id);
    setItems((current) => current.filter((item) => item.id !== id));
  }, []);

  const run = useCallback(
    async (id: string) => {
      const draft = drafts.current.get(id);
      const render = renders.current.get(id);
      const item = itemsRef.current.find((candidate) => candidate.id === id);
      if (!draft || !render || !item || currentUserId === null) {
        return;
      }
      try {
        const webp = await render;

        // Fetched at send time rather than when the picker was drawn, so a
        // device enrolled five minutes ago still gets a copy — and a retry
        // seals again, because the device list may be what changed.
        const keys = await axios.get(`${BACKEND_URL}/api/v1/instant/keys/${item.recipient.userId}`, {
          headers: { Authorization: getAuthHeader() },
        });
        const devices = (keys.data?.devices ?? []) as RecipientDeviceKey[];
        if (devices.length === 0) {
          throw new Error("They have not set up Instant yet, so nothing can be sealed for them.");
        }

        const sealed = await sealForDevices(webp, currentUserId, devices);
        const form = new FormData();
        form.append(
          "media",
          new Blob([sealed.ciphertext], { type: "application/octet-stream" }),
          "instant.bin"
        );
        form.append(
          "payload",
          JSON.stringify({
            recipientId: item.recipient.userId,
            durationMode: draft.duration,
            mediaType: "image/webp",
            mediaIv: sealed.mediaIv,
            ephemeralPubKey: sealed.ephemeralPubKey,
            envelopes: sealed.envelopes,
          })
        );
        await axios.post(`${BACKEND_URL}/api/v1/instant`, form, {
          headers: { Authorization: getAuthHeader() },
        });

        onSent(item.recipient.userId);
        setPhase(id, "sent");
        window.setTimeout(() => dismiss(id), CONFIRMATION_MS);
      } catch (error: unknown) {
        // The draft and its render are kept: a retry must not have to ask for
        // the photo again, and by now the compose screen is long gone.
        setPhase(id, "failed", messageFor(error));
      }
    },
    [currentUserId, dismiss, onSent, setPhase]
  );

  const send = useCallback(
    (draft: InstantDraft, recipients: InstantRecipient[]) => {
      if (recipients.length === 0 || currentUserId === null) {
        return;
      }
      // One render for all of them. It is deliberately started before the items
      // exist, so the encode is already under way while React commits the pill.
      const render = renderDraft(draft);
      const queued: OutboxItem[] = recipients.map((recipient) => {
        const id = crypto.randomUUID();
        drafts.current.set(id, draft);
        renders.current.set(id, render);
        return { id, recipient, phase: "sending" };
      });
      setItems((current) => [...current, ...queued]);
      itemsRef.current = [...itemsRef.current, ...queued];
      for (const item of queued) {
        void run(item.id);
      }
    },
    [currentUserId, run]
  );

  const retry = useCallback(
    (id: string) => {
      setPhase(id, "sending");
      void run(id);
    },
    [run, setPhase]
  );

  // A failure outranks everything: it is the only state that stays, and the
  // only one with something to do about it.
  const headline =
    items.find((item) => item.phase === "failed") ??
    [...items].reverse().find((item) => item.phase === "sending") ??
    [...items].reverse().find((item) => item.phase === "sent");

  return {
    items,
    headline,
    inFlight: items.filter((item) => item.phase === "sending").length,
    sentCount: items.filter((item) => item.phase === "sent").length,
    send,
    retry,
    dismiss,
  };
}

/// The filter, the drawing and the captions, in that order, at full resolution,
/// then WebP.
///
/// The order is the whole of the look: the filter is under the ink so a
/// scribble keeps its colour, and the ink is under the text so it cannot make a
/// caption unreadable. It matches `OverlayCompositor` on iOS.
async function renderDraft(draft: InstantDraft): Promise<Blob> {
  const { image } = draft;
  const width = image.naturalWidth;
  const height = image.naturalHeight;
  const filtered = applyFilter(image, width, height, draft.filter);
  const flattened = composite(filtered, width, height, draft.strokes, draft.captions);
  return encodeToWebp(flattened, INSTANT_ENCODE_OPTIONS);
}
