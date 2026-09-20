import { useEffect, useState } from "react";
import { getCachedProfile } from "../../lib/auth";

// Who is signed in, for the account button.
//
// It reads the cache rather than fetching, so the button has a face on the
// first frame — Instant opens on the camera and the button is one of the three
// things on it. The events are the two the rest of the Lounge already fires:
// `profile-picture-changed` when the picture is replaced from the account page
// in this tab, and `storage` when it happens in another one.

export function useSignedInProfile() {
  const [profile, setProfile] = useState(getCachedProfile);

  useEffect(() => {
    const sync = () => setProfile(getCachedProfile());
    window.addEventListener("profile-picture-changed", sync);
    window.addEventListener("storage", sync);
    return () => {
      window.removeEventListener("profile-picture-changed", sync);
      window.removeEventListener("storage", sync);
    };
  }, []);

  return profile;
}
