import { useCallback, useEffect, useRef, useState } from "react";
import type { InstantDelivery } from "@blogging-app/common";
import { useUsers } from "../../hooks";
import { useInstant, type InstantRow } from "../../hooks/useInstant";
import { AccountSheet } from "./AccountSheet";
import { CameraScreen } from "./CameraScreen";
import { InboxScreen } from "./InboxScreen";
import { InstantKeySetup } from "./InstantKeySetup";
import { InstantViewer } from "./InstantViewer";
import { SendStatusPill } from "./SendStatusPill";
import { InstantAvatar } from "./chrome";
import { INSTANT_COLORS, VIEWPORT_INSET, viewportStyle } from "./style";
import { useOutbox, type InstantRecipient } from "./useOutbox";
import { useDarkChrome } from "./useDarkChrome";
import { useSignedInProfile } from "./useSignedInProfile";

// Snapchat's spine, ported from `ios/Instant/App/RootView.swift`: the camera is
// the app, and conversations are one swipe away to the *left* of it — which is
// why the camera's chat button also sits in the bottom-left corner. The two
// gestures point the same way.
//
// On a phone the viewport fills the window and this is indistinguishable from
// the native app. On a desktop the same 16:9 rectangle becomes a phone-shaped
// card on black and every control stays inside the frame it belongs to, so
// there is one layout rather than two.

/// How far a drag has to go sideways before it counts as a page turn rather
/// than a scroll or a pinch.
const SWIPE_THRESHOLD = 60;

export function InstantApp({ authExpiredRedirect }: { authExpiredRedirect: () => void }) {
  const {
    device,
    enrollError,
    instants,
    history,
    rows,
    hasLoaded,
    connection,
    authExpired,
    currentUserId,
    dismissInstant,
    noteOpened,
    noteSent,
    forgetUser,
    refreshHistory,
    refreshAll,
  } = useInstant(true);
  const { users, loading: usersLoading } = useUsers();
  const profile = useSignedInProfile();
  // Instant is black to the edges of the window, including the parts the system
  // paints. The rest of the Lounge is not, so this is undone on the way out.
  useDarkChrome();

  const [showsInbox, setShowsInbox] = useState(false);
  const [isComposing, setIsComposing] = useState(false);
  const [showsAccount, setShowsAccount] = useState(false);
  const [viewing, setViewing] = useState<InstantDelivery | null>(null);
  /// Who the next photo is for. It lives here rather than on the camera because
  /// it outlives it: it is set before there is a photo and survives a retake.
  const [aimedAt, setAimedAt] = useState<InstantRecipient | null>(null);

  const outbox = useOutbox({ currentUserId, onSent: noteSent });

  const send = useCallback(
    (draft: Parameters<typeof outbox.send>[0], recipients: InstantRecipient[]) => {
      outbox.send(draft, recipients);
      // Sending spends the aim, whichever path sent it.
      setAimedAt(null);
    },
    [outbox]
  );

  const openRow = useCallback((row: InstantRow) => {
    if (row.pending) {
      setViewing(row.pending);
    }
  }, []);

  const aimAt = useCallback((row: InstantRow) => {
    // Nothing to read, so the tap means the other direction: the camera,
    // already aimed at them. The photo does not exist yet — tapping a person
    // has answered who it is for before there is anything to send.
    setAimedAt({ userId: row.userId, name: row.name });
    setShowsInbox(false);
  }, []);

  const onBlocked = useCallback(
    (userId: number) => {
      forgetUser(userId);
      setAimedAt((current) => (current?.userId === userId ? null : current));
    },
    [forgetUser]
  );

  // --- the page turn -------------------------------------------------------

  const swipe = useRef<{ x: number; y: number } | null>(null);

  const onPointerDown = (event: React.PointerEvent) => {
    // Not while composing, and not from inside anything drawn over the pager: a
    // drag across a sheet is a drag across a sheet, not a page turn.
    const inSheet = (event.target as Element).closest?.("[data-sheet]") !== null;
    swipe.current = isComposing || inSheet ? null : { x: event.clientX, y: event.clientY };
  };

  const onPointerUp = (event: React.PointerEvent) => {
    const start = swipe.current;
    swipe.current = null;
    if (!start) {
      return;
    }
    const dx = event.clientX - start.x;
    const dy = event.clientY - start.y;
    if (Math.abs(dx) < SWIPE_THRESHOLD || Math.abs(dx) < Math.abs(dy)) {
      return;
    }
    setShowsInbox(dx > 0);
  };

  useEffect(() => {
    if (authExpired) {
      authExpiredRedirect();
    }
  }, [authExpired, authExpiredRedirect]);

  const unreadCount = instants.length;

  return (
    <div
      className="fixed inset-0 overflow-hidden"
      style={{ background: INSTANT_COLORS.background }}
      onPointerDown={onPointerDown}
      onPointerUp={onPointerUp}
    >
      <div
        className="flex h-full w-[200%] transition-transform duration-300 ease-out"
        style={{ transform: showsInbox ? "translateX(0)" : "translateX(-50%)" }}
      >
        <div className="relative h-full w-1/2">
          <InboxScreen
            rows={rows}
            hasLoaded={hasLoaded}
            connection={connection}
            currentUserId={currentUserId}
            onOpen={openRow}
            onAim={aimAt}
            onRefresh={() => void refreshAll()}
            onOpenCamera={() => setShowsInbox(false)}
            onBlocked={onBlocked}
          />
        </div>
        <div className="relative h-full w-1/2">
          <CameraScreen
            aimedAt={aimedAt}
            onClearAim={() => setAimedAt(null)}
            unreadCount={unreadCount}
            onOpenInbox={() => setShowsInbox(true)}
            onComposingChange={setIsComposing}
            onSend={send}
            users={users}
            usersLoading={usersLoading}
            history={history}
            currentUserId={currentUserId}
          />
        </div>
      </div>

      {/* Above the pager rather than on a page: the way into settings should
          not slide off with whichever page happens to be under it, and the
          inbox is exactly where somebody is most likely to want it. Not while a
          photo is being composed, though — being above the pager puts it above
          that screen too, in the corner the discard cross already occupies. */}
      {!isComposing && (
        <div className="pointer-events-none absolute inset-0 flex items-center justify-center">
          <div
            className="pointer-events-none relative flex flex-col"
            style={{ ...viewportStyle, padding: VIEWPORT_INSET }}
          >
            <button
              type="button"
              onClick={() => setShowsAccount(true)}
              aria-label="Your account"
              data-testid="camera.profile"
              className="pointer-events-auto self-start rounded-full"
            >
              <InstantAvatar
                name={profile.name}
                themeKey={profile.themeKey ?? ""}
                url={profile.profilePictureUrl}
                size={44}
              />
            </button>

            <span className="flex-1" />

            {/* Over the camera's bottom bar and clear of the shutter: a send
                started from the camera is still worth hearing about after a
                swipe to the inbox. */}
            <div className="flex justify-center pb-[92px]">
              <SendStatusPill
                item={outbox.headline}
                inFlight={outbox.inFlight}
                sentCount={outbox.sentCount}
                onRetry={outbox.retry}
                onDismiss={outbox.dismiss}
              />
            </div>
          </div>
        </div>
      )}

      {/* The honest disclosure: the key is local, non-extractable and
          unrecoverable, and this client is itself the weak link because it is
          re-downloaded on every visit. It sits over the camera until the device
          is enrolled, because nothing can be sent or opened before then. */}
      {(enrollError || !device) && (
        <div className="absolute inset-x-0 bottom-0 z-20 p-4">
          <InstantKeySetup
            state={enrollError ? "failed" : "working"}
            error={enrollError}
            nonExtractable={null}
          />
        </div>
      )}

      {showsAccount && (
        <AccountSheet
          // The button only has room for initials, so the sheet it opens is
          // where the name is actually spelled out.
          name={profile.name}
          currentUserId={currentUserId}
          onClose={() => setShowsAccount(false)}
          onUnblocked={() => void refreshHistory()}
        />
      )}

      {viewing && device && (
        <InstantViewer
          instant={viewing}
          device={device}
          onBlocked={onBlocked}
          onClose={(seen, untouched) => {
            // A clip this browser could not play was never fetched, so it is
            // still waiting — for the phone.
            if (!untouched) {
              dismissInstant(viewing.id);
            }
            // Closing an instant lands back on the inbox rather than the
            // camera, with the sender's row now offering a reply — the one
            // thing somebody who has just looked at a photo is likely to want.
            if (seen) {
              noteOpened(viewing.senderId);
            }
            setShowsInbox(true);
            setViewing(null);
            void refreshHistory();
          }}
        />
      )}
    </div>
  );
}
