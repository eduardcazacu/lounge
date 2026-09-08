export const APP_NAME = "Eddie's Lounge";
export const BACKEND_URL = import.meta.env.VITE_BACKEND_URL || "http://localhost:8787";
export const IMAGE_TRANSFORM_BASE_URL = import.meta.env.VITE_IMAGE_TRANSFORM_BASE_URL || "";

// WebSocket origin for Instant's realtime inbox. Derived rather than configured
// separately so there is only ever one backend URL to set.
export const WS_BASE_URL = BACKEND_URL.replace(/^http/, "ws");
