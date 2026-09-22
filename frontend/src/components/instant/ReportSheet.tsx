import { useState } from "react";
import type { ReportReason } from "@blogging-app/common";
import { InstantSheet } from "./chrome";
import { IconCheck } from "./icons";
import { REPORT_REASONS, reportUser } from "./moderation";
import { INSTANT_COLORS } from "./style";

// Report someone, ported from `ios/Instant/Features/Moderation/ReportScreen.swift`.
// Opened from the viewer, where the photo can be attached, and from a
// conversation row, where there is nothing to attach.

export function ReportSheet({
  reportedUserId,
  reportedName,
  instantId,
  photo,
  isVideoFrame = false,
  onClose,
  onBlocked,
}: {
  reportedUserId: number;
  reportedName: string;
  instantId?: string;
  /// The reporter's own copy of the photo, if there is one on screen.
  photo?: Blob;
  /// `photo` is one frame of a video, and the toggle says so: a reporter must
  /// not think the moderators are getting the whole clip.
  isVideoFrame?: boolean;
  onClose: () => void;
  onBlocked: (userId: number) => void;
}) {
  const [reason, setReason] = useState<ReportReason>("nudity");
  const [details, setDetails] = useState("");
  // Reporting somebody blocks them too unless the reporter says otherwise.
  const [alsoBlock, setAlsoBlock] = useState(true);
  const [includesPhoto, setIncludesPhoto] = useState(Boolean(photo));
  const [sending, setSending] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [done, setDone] = useState(false);

  const submit = async () => {
    setSending(true);
    setError(null);
    try {
      await reportUser({
        reportedUserId,
        instantId,
        reason,
        details,
        alsoBlock,
        evidence: includesPhoto ? photo : undefined,
      });
      setDone(true);
      if (alsoBlock) {
        onBlocked(reportedUserId);
      }
    } catch {
      setError("That report didn't go through. Check your connection and try again.");
    } finally {
      setSending(false);
    }
  };

  if (done) {
    return (
      <InstantSheet title="Thanks" onClose={onClose}>
        <p className="pb-8 text-[15px]" style={{ color: INSTANT_COLORS.secondaryText }}>
          The moderators have it and will look within 24 hours.
          {alsoBlock ? ` ${reportedName} is blocked.` : ""}
        </p>
      </InstantSheet>
    );
  }

  return (
    <InstantSheet
      title={`Report ${reportedName}`}
      onClose={onClose}
      footer={
        <button
          type="button"
          disabled={sending}
          onClick={() => void submit()}
          data-testid="report.submit"
          className="w-full rounded-full py-3 text-sm font-bold text-white disabled:opacity-50"
          style={{ background: INSTANT_COLORS.unread }}
        >
          {sending ? "Sending…" : "Send report"}
        </button>
      }
    >
      <h3
        className="pt-1 text-[11px] font-bold uppercase tracking-wide"
        style={{ color: INSTANT_COLORS.secondaryText }}
      >
        What&apos;s wrong?
      </h3>
      {REPORT_REASONS.map((option) => (
        <button
          key={option.id}
          type="button"
          onClick={() => setReason(option.id)}
          data-testid={`report.reason.${option.id}`}
          className="flex w-full items-center justify-between py-3 text-left text-[15px] text-white"
        >
          {option.label}
          {reason === option.id && <IconCheck size={16} />}
        </button>
      ))}

      <textarea
        value={details}
        maxLength={1000}
        onChange={(event) => setDetails(event.target.value)}
        placeholder="Anything else we should know (optional)"
        rows={3}
        data-testid="report.details"
        className="mt-3 w-full rounded-xl p-3 text-[15px] text-white placeholder:text-neutral-500 focus:outline-none"
        style={{ background: INSTANT_COLORS.surfaceRaised }}
      />

      {photo && (
        <Toggle
          label={isVideoFrame ? "Include a frame from this video" : "Include this photo"}
          checked={includesPhoto}
          onChange={setIncludesPhoto}
          id="report.includePhoto"
        />
      )}
      <Toggle
        label={`Also block ${reportedName}`}
        checked={alsoBlock}
        onChange={setAlsoBlock}
        id="report.alsoBlock"
      />

      <div className="space-y-2 pb-4 pt-2 text-[12px]" style={{ color: INSTANT_COLORS.secondaryText }}>
        {photo && (
          <p>
            Photos are end-to-end encrypted, so we can&apos;t see them. Including it sends a copy to
            the moderators, who delete it once the report is dealt with.
          </p>
        )}
        <p>
          Blocking stops you from seeing or sending to each other. Reports are reviewed within 24
          hours.
        </p>
        {error && <p style={{ color: INSTANT_COLORS.unread }}>{error}</p>}
      </div>
    </InstantSheet>
  );
}

function Toggle({
  label,
  checked,
  onChange,
  id,
}: {
  label: string;
  checked: boolean;
  onChange: (value: boolean) => void;
  id: string;
}) {
  return (
    <label className="flex items-center justify-between py-3 text-[15px] text-white">
      {label}
      <input
        type="checkbox"
        checked={checked}
        data-testid={id}
        onChange={(event) => onChange(event.target.checked)}
        className="h-5 w-5 accent-green-500"
      />
    </label>
  );
}
