import { useEffect, useState } from "react";
import axios from "axios";
import { Link } from "react-router-dom";
import { BACKEND_URL } from "../../config";
import { getAuthHeader } from "../../lib/auth";
import { InstantAvatar, InstantSheet } from "./chrome";
import { unblockUser } from "./moderation";
import { INSTANT_COLORS } from "./style";

// What the account button opens.
//
// The iOS app's settings screen owns everything about the account, because on a
// phone Instant *is* the app. Here it is one page of a larger Lounge that
// already has an account page, a terms page and a way out — so this is a short
// way to each of those, plus the one thing the Lounge has nowhere else: the
// list of people this account has blocked, which is where a block made from a
// conversation row is undone.

type BlockedPerson = {
  userId: number;
  name: string | null;
  themeKey: string | null;
  profilePictureUrl: string | null;
};

export function AccountSheet({
  name,
  currentUserId,
  onClose,
  onUnblocked,
}: {
  name: string;
  currentUserId: number | null;
  onClose: () => void;
  onUnblocked: () => void;
}) {
  const [blocked, setBlocked] = useState<BlockedPerson[] | null>(null);

  useEffect(() => {
    let cancelled = false;
    void axios
      .get(`${BACKEND_URL}/api/v1/moderation/blocks`, {
        headers: { Authorization: getAuthHeader() },
      })
      .then((response) => {
        if (!cancelled) {
          setBlocked((response.data?.blocks ?? []) as BlockedPerson[]);
        }
      })
      .catch(() => {
        if (!cancelled) {
          setBlocked([]);
        }
      });
    return () => {
      cancelled = true;
    };
  }, [currentUserId]);

  return (
    <InstantSheet title={name || "You"} onClose={onClose}>
      <nav className="flex flex-col">
        <SheetLink to="/account" label="Account settings" />
        <SheetLink to="/blogs" label="Back to the Lounge" />
        <SheetLink to="/terms" label="Community guidelines" />
      </nav>

      <h3
        className="pt-4 text-[11px] font-bold uppercase tracking-wide"
        style={{ color: INSTANT_COLORS.secondaryText }}
      >
        Blocked
      </h3>
      {blocked === null ? (
        <p className="py-3 text-[13px]" style={{ color: INSTANT_COLORS.secondaryText }}>
          Loading…
        </p>
      ) : blocked.length === 0 ? (
        <p className="py-3 text-[13px]" style={{ color: INSTANT_COLORS.secondaryText }}>
          Nobody. Blocking somebody hides them from both of you.
        </p>
      ) : (
        <ul className="pb-4">
          {blocked.map((person) => (
            <li key={person.userId} className="flex items-center gap-3 py-2.5">
              <InstantAvatar
                name={person.name?.trim() || "Someone"}
                themeKey={person.themeKey ?? ""}
                url={person.profilePictureUrl}
                size={40}
              />
              <span className="flex-1 truncate text-[15px] text-white">
                {person.name?.trim() || "Someone"}
              </span>
              <button
                type="button"
                onClick={async () => {
                  await unblockUser(person.userId).catch(() => undefined);
                  setBlocked((current) =>
                    (current ?? []).filter((candidate) => candidate.userId !== person.userId)
                  );
                  // Their conversation comes back for both sides, so the inbox
                  // has to be asked again rather than waiting for the next
                  // socket event.
                  onUnblocked();
                }}
                className="rounded-full border border-white/25 px-3 py-1.5 text-[13px] font-semibold text-white"
              >
                Unblock
              </button>
            </li>
          ))}
        </ul>
      )}
    </InstantSheet>
  );
}

function SheetLink({ to, label }: { to: string; label: string }) {
  return (
    <Link to={to} className="py-3.5 text-[15px] font-semibold text-white">
      {label}
    </Link>
  );
}
