import { Navigate, useNavigate } from "react-router-dom";
import { InstantApp } from "../components/instant/InstantApp";
import { getAuthHeader } from "../lib/auth";

// Instant is the one page of the Lounge that is not a page.
//
// Everything else here is a document with an app bar over it; this is a camera,
// and it takes the whole window — black, full-bleed, no chrome from the rest of
// the site. That is not a style choice: the shape is the iOS app's, screen for
// screen, so somebody who uses both is not learning it twice. See
// wiki/web-client.md.
//
// The way back to the Lounge is the account button, top-left, where the app bar
// used to be.

export const Instant = () => {
  const navigate = useNavigate();

  if (!getAuthHeader()) {
    return <Navigate to="/signin" replace />;
  }

  return <InstantApp authExpiredRedirect={() => navigate("/signin", { replace: true })} />;
};
