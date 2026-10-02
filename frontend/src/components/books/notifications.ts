import { useCallback, useEffect, useState } from "react";
import { getAuthHeader } from "../../lib/auth";
import { isPushNotificationSupported, subscribePushDevice } from "../../lib/push";

// Notifications, as Books asks for them.
//
// The Lounge's banner is kept off /books (it would sit over the tabs), and on
// an iPhone each web app on the home screen has its own permission — allowing
// notifications in the Lounge's icon does nothing for the Books icon. So Books
// asks for itself: a row in the avatar menu, and a card once there is
// something worth being told about. Which kinds arrive is set per account, in
// Account settings.

export type PushState =
  /** Can be asked for. */
  | "off"
  | "on"
  | "blocked"
  /** An iPhone browser tab: Safari only offers push to a web app on the home screen. */
  | "install-first"
  | "unsupported";

function isIosBrowserTab() {
  const ios = /iPhone|iPad|iPod/.test(navigator.userAgent);
  const standalone =
    (navigator as Navigator & { standalone?: boolean }).standalone === true || window.matchMedia("(display-mode: standalone)").matches;
  return ios && !standalone;
}

function currentState(): PushState {
  if (!isPushNotificationSupported()) return isIosBrowserTab() ? "install-first" : "unsupported";
  if (Notification.permission === "granted") return "on";
  if (Notification.permission === "denied") return "blocked";
  return "off";
}

export function usePushState() {
  const [state, setState] = useState<PushState>(currentState);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    const sync = () => setState(currentState());
    window.addEventListener("push-subscription-changed", sync);
    document.addEventListener("visibilitychange", sync);
    return () => {
      window.removeEventListener("push-subscription-changed", sync);
      document.removeEventListener("visibilitychange", sync);
    };
  }, []);

  const turnOn = useCallback(async () => {
    setBusy(true);
    setError(null);
    try {
      const permission = await Notification.requestPermission();
      if (permission !== "granted") {
        setState(permission === "denied" ? "blocked" : "off");
        return false;
      }
      const authHeader = getAuthHeader();
      if (!authHeader) return false;
      await subscribePushDevice(authHeader);
      setState("on");
      return true;
    } catch {
      setError("Couldn't turn notifications on. Try again in a moment.");
      return false;
    } finally {
      setBusy(false);
    }
  }, []);

  return { state, busy, error, turnOn };
}

const CARD_DISMISSED_KEY = "books.notificationsCardDismissed";

export function isNotificationsCardDismissed() {
  try {
    return localStorage.getItem(CARD_DISMISSED_KEY) === "1";
  } catch {
    return false;
  }
}

export function dismissNotificationsCard() {
  try {
    localStorage.setItem(CARD_DISMISSED_KEY, "1");
  } catch {
    // Private mode: the card simply comes back next time.
  }
}
