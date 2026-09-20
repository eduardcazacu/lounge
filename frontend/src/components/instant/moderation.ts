import axios from "axios";
import type { ReportReason } from "@blogging-app/common";
import { BACKEND_URL } from "../../config";
import { getAuthHeader } from "../../lib/auth";

// Blocking and reporting, the same two calls the iOS app makes
// (`ios/Instant/Core/Networking/ModerationAPI.swift`).
//
// The Lounge is invite-only and these exist because App Review requires them of
// anything carrying user photos — but they are not iOS paperwork: a block cuts
// both directions for both clients, so somebody blocked from a phone has to be
// blocked in the browser too, and somebody who only ever uses the browser needs
// a way to do it at all.

export const REPORT_REASONS: { id: ReportReason; label: string }[] = [
  { id: "nudity", label: "Nudity or sexual content" },
  { id: "harassment", label: "Harassment or bullying" },
  { id: "violence", label: "Violence or threats" },
  { id: "spam", label: "Spam or scam" },
  { id: "other", label: "Something else" },
];

export async function blockUser(userId: number): Promise<void> {
  await axios.post(
    `${BACKEND_URL}/api/v1/moderation/blocks`,
    { userId },
    { headers: { Authorization: getAuthHeader() } }
  );
}

export async function unblockUser(userId: number): Promise<void> {
  await axios.delete(`${BACKEND_URL}/api/v1/moderation/blocks/${userId}`, {
    headers: { Authorization: getAuthHeader() },
  });
}

export async function reportUser(draft: {
  reportedUserId: number;
  instantId?: string;
  reason: ReportReason;
  details?: string;
  alsoBlock: boolean;
  /// The reporter's own copy of the photo. The one way an instant's plaintext
  /// ever reaches the server, and only when they chose to attach it.
  evidence?: Blob;
}): Promise<void> {
  const form = new FormData();
  form.append(
    "payload",
    JSON.stringify({
      reportedUserId: draft.reportedUserId,
      instantId: draft.instantId,
      reason: draft.reason,
      details: draft.details || undefined,
      alsoBlock: draft.alsoBlock,
    })
  );
  if (draft.evidence) {
    form.append("evidence", draft.evidence, "evidence.webp");
  }
  await axios.post(`${BACKEND_URL}/api/v1/moderation/reports`, form, {
    headers: { Authorization: getAuthHeader() },
  });
}
