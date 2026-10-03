import z from "zod";

export const themeKeys = [
    "boring-grey",
    "sunset",
    "purple",
    "forest",
    "ocean",
    "rose",
    "indigo",
    "gold",
] as const;

export const themeKeySchema = z.enum(themeKeys);
export type ThemeKey = z.infer<typeof themeKeySchema>;

export const signupInput = z.object({
    email: z.string().email(),
    password: z.string(),
    name: z.string().optional()
})

//type inference in zod
export type SignupInput = z.infer<typeof signupInput>    

export const signinInput = z.object({
    email: z.string().email(),
    password: z.string(),
    name: z.string().optional()
})

export type SigninInput = z.infer<typeof signinInput>    

export const forgotPasswordInput = z.object({
    email: z.string().email(),
})

export type ForgotPasswordInput = z.infer<typeof forgotPasswordInput>

export const resetPasswordInput = z.object({
    email: z.string().email(),
    token: z.string().min(10),
    password: z.string().min(6),
})

export type ResetPasswordInput = z.infer<typeof resetPasswordInput>

export const createBlogInput = z.object({
    title: z.string(),
    content: z.string(),
    imageKey: z.string().optional()
})

export type CreateBlogInput = z.infer<typeof createBlogInput>    

export const updateBlogInput = z.object({
    title: z.string(),
    content: z.string(),
    id: z.number(),
})

export type UpdateBlogInput = z.infer<typeof updateBlogInput>

// ---------------------------------------------------------------------------
// Instant — expiring, end-to-end encrypted 1:1 photos.
//
// The native iOS client mirrors these shapes by hand, so keep them explicit and
// keep the field names stable.
// ---------------------------------------------------------------------------

// A photo is shown for 1s, 5s or until closed; a video plays once or loops.
// The two families never mix — `durationModeFitsMediaType` is what the send
// endpoint holds them to, because a viewer decides how to show an instant from
// the pair, and a photo told to "loop" has no answer.
export const instantPhotoDurationModes = ["1s", "5s", "infinite"] as const;
export const instantVideoDurationModes = ["once", "loop"] as const;
export const instantDurationModes = [
    ...instantPhotoDurationModes,
    ...instantVideoDurationModes,
] as const;

export const instantDurationMode = z.enum(instantDurationModes);

export type InstantDurationMode = z.infer<typeof instantDurationMode>;

export function isVideoMediaType(mediaType: string): boolean {
    return mediaType.trim().toLowerCase().startsWith("video/");
}

export function durationModeFitsMediaType(mode: InstantDurationMode, mediaType: string): boolean {
    const videoModes: readonly string[] = instantVideoDurationModes;
    return videoModes.includes(mode) === isVideoMediaType(mediaType);
}

// base64url with no padding, which is how every key/IV/ciphertext blob travels.
const base64Url = z.string().regex(/^[A-Za-z0-9_-]+$/, "Expected unpadded base64url");

export const registerInstantDeviceInput = z.object({
    // Client-generated, stable for the lifetime of the local keypair.
    deviceId: z.string().uuid(),
    // Raw uncompressed P-256 public point (65 bytes) as base64url.
    publicKey: base64Url.min(80).max(120),
})

export type RegisterInstantDeviceInput = z.infer<typeof registerInstantDeviceInput>

// One wrapped copy of the message content key, for a single recipient device.
export const instantKeyEnvelopeInput = z.object({
    deviceKeyId: z.number().int().positive(),
    wrappedKey: base64Url.min(1).max(512),
    wrapIv: base64Url.min(1).max(64),
})

export type InstantKeyEnvelopeInput = z.infer<typeof instantKeyEnvelopeInput>

// Everything except the ciphertext itself, which travels as a multipart file.
export const createInstantInput = z.object({
    recipientId: z.number().int().positive(),
    durationMode: instantDurationMode,
    mediaType: z.string().trim().min(1).max(64).default("image/webp"),
    mediaIv: base64Url.min(1).max(64),
    ephemeralPubKey: base64Url.min(80).max(120),
    envelopes: z.array(instantKeyEnvelopeInput).min(1).max(10),
})

export type CreateInstantInput = z.infer<typeof createInstantInput>

export const wsTicketInput = z.object({
    deviceId: z.string().uuid(),
})

export type WsTicketInput = z.infer<typeof wsTicketInput>

// What a client receives, over the WebSocket or from GET /inbox. `envelope` is
// always the one matching the receiving device — never the whole set.
export type InstantDelivery = {
    id: string;
    senderId: number;
    senderName: string | null;
    senderThemeKey: string;
    senderProfilePictureUrl: string | null;
    mediaType: string;
    mediaIv: string;
    ephemeralPubKey: string;
    byteSize: number;
    durationMode: InstantDurationMode;
    createdAt: string;
    expiresAt: string;
    envelope: { wrappedKey: string; wrapIv: string } | null;
};

// WebSocket frames, server -> client.
export type InstantWireEvent =
    | { type: "ready"; deviceId: string }
    | { type: "instant"; instant: InstantDelivery }
    | { type: "opened"; instantId: string; recipientId: number; openedAt: string };

// The sender's side of a photo: when it went, and whether it has been taken.
//
// `openedAt` is the moment the recipient's device claimed the media and the
// server destroyed it — not the client's `viewedAt` confirmation, which is a
// call that may never come. See wiki/decisions.md.
export type InstantSendReceipt = {
    sentAt: string;
    /// Null while it is still waiting to be opened.
    openedAt: string | null;
    /// When an unopened one is swept, 24 hours after it was sent.
    expiresAt: string;
};

// One person you have exchanged instants with, whether or not a streak is
// running. Built from the streak table, which keeps a row per pair for good —
// `recordSend` upserts one on every send and lapsing only zeroes the count.
export type InstantConversation = {
    userId: number;
    name: string | null;
    themeKey: string;
    profilePictureUrl: string | null;
    /// The most recent send in either direction.
    lastInteractionAt: string;
    lastSentAt: string | null;
    lastReceivedAt: string | null;
    /// Instants from them still waiting to be opened.
    unopenedCount: number;
    /// The newest photo *you* sent them, while it is recent enough to be worth
    /// reporting on. Null once it is older than that, so a quiet conversation
    /// does not keep showing a receipt for something nobody is thinking about.
    lastSentReceipt: InstantSendReceipt | null;
    /// 0 once a streak has lapsed; the conversation stays either way.
    streakCount: number;
    streakDeadline: string | null;
    streakAtRisk: boolean;
};

export type InstantStreakSummary = {
    userId: number;
    name: string | null;
    themeKey: string;
    profilePictureUrl: string | null;
    count: number;
    // ISO timestamp at which the streak lapses if nothing else is exchanged.
    deadline: string | null;
    atRisk: boolean;
};

// ---------------------------------------------------------------------------
// Moderation — reporting and blocking, for App Store Guideline 1.2.
// ---------------------------------------------------------------------------

export const reportReasons = ["nudity", "harassment", "violence", "spam", "other"] as const;

export const reportReason = z.enum(reportReasons);

export type ReportReason = z.infer<typeof reportReason>;

// The JSON `payload` part of POST /moderation/reports. The optional photo rides
// alongside it as the multipart `evidence` part.
export const createReportInput = z.object({
    reportedUserId: z.number().int().positive(),
    instantId: z.string().uuid().optional(),
    reason: reportReason,
    details: z.string().trim().max(1000).optional(),
    // Reporting someone blocks them too unless the reporter says otherwise.
    alsoBlock: z.boolean().default(true),
})

export type CreateReportInput = z.infer<typeof createReportInput>

export const blockUserInput = z.object({
    userId: z.number().int().positive(),
})

export type BlockUserInput = z.infer<typeof blockUserInput>

export const resolveReportInput = z.object({
    // "suspend" rejects the reported account and ends its sessions.
    action: z.enum(["dismiss", "suspend"]),
})

export type ResolveReportInput = z.infer<typeof resolveReportInput>

export const deleteAccountInput = z.object({
    password: z.string().min(1),
})

export type DeleteAccountInput = z.infer<typeof deleteAccountInput>

// ---------------------------------------------------------------------------
// Shelf — /books today. Every shape carries a `kind` or hangs off something
// that does, so movies or music arrive as a new value here rather than a new
// set of endpoints. Web only: iOS has no shelf, so nothing mirrors these.
// ---------------------------------------------------------------------------

export const shelfKinds = ["book"] as const;

export const shelfKind = z.enum(shelfKinds);

export type ShelfKind = z.infer<typeof shelfKind>;

export const catalogSources = ["openlibrary", "google", "manual"] as const;

// A calendar day in the reader's own timezone. Reading is logged by the day
// it happened to the reader, not by the UTC day the server sees.
const localDay = z.string().regex(/^\d{4}-\d{2}-\d{2}$/);

// One printing of a work: its language, publisher and cover. A reader's
// edition is their own (`ShelfEntry.editionId`); the work, and so the book
// club, is shared. Open Library is the only provider that lists editions.
export const catalogEdition = z.object({
    source: z.enum(["openlibrary"]),
    externalId: z.string().trim().min(1).max(200),
    title: z.string().trim().min(1).max(300),
    // MARC code, as Open Library gives it: "eng", "pol". Null when unrecorded,
    // which is common for English editions.
    language: z.string().trim().min(2).max(8).nullable(),
    publisher: z.string().trim().min(1).max(200).nullable(),
    year: z.number().int().min(-3000).max(3000).nullable(),
    format: z.string().trim().min(1).max(80).nullable(),
    coverUrl: z.string().url().max(500).nullable(),
    totalUnits: z.number().int().positive().max(100000).nullable(),
})

export type CatalogEdition = z.infer<typeof catalogEdition>

// What /catalog/search returns and /entries takes back. The client hands the
// chosen candidate back whole rather than an id, so adding a book costs no
// second round trip to the provider.
export const catalogCandidate = z.object({
    kind: shelfKind,
    source: z.enum(catalogSources),
    externalId: z.string().trim().min(1).max(200),
    title: z.string().trim().min(1).max(300),
    creators: z.array(z.string().trim().min(1).max(200)).max(10),
    year: z.number().int().min(-3000).max(3000).nullable(),
    coverUrl: z.string().url().max(500).nullable(),
    totalUnits: z.number().int().positive().max(100000).nullable(),
    genres: z.array(z.string().trim().min(1).max(80)).max(8),
    // The edition this reader means. Search fills in an English one where the
    // work has it; "Other editions" swaps it. The fields above stay the work's,
    // because the first sighting fixes them for everyone.
    edition: catalogEdition.nullable().optional(),
})

export type CatalogCandidate = z.infer<typeof catalogCandidate>

// Changing the edition of a book already on the shelf. Null goes back to the
// work's own cover and title.
export const setEditionInput = z.object({
    edition: catalogEdition.nullable(),
})

export type SetEditionInput = z.infer<typeof setEditionInput>

// The whole want list, in the order the reader arranged it. The whole of it,
// rather than one move, so a stale list is refused instead of half-applied.
export const wantOrderInput = z.object({
    entryIds: z.array(z.number().int().positive()).max(2000),
})

export type WantOrderInput = z.infer<typeof wantOrderInput>

export const addShelfEntryInput = z.object({
    // A candidate from search. For a manual entry the client sends source
    // "manual" and the server mints the externalId.
    candidate: catalogCandidate,
    // "finished" and "dnf" are backfills of something read, or abandoned,
    // before it was on the shelf, and need the day it ended.
    intent: z.enum(["want", "start", "finished", "dnf"]),
    startedOn: localDay.optional(),
    finishedOn: localDay.optional(),
    // For a "dnf" backfill: the page it was put down at, if remembered.
    stoppedAt: z.number().int().min(0).max(100000).optional(),
    // Pages in the reader's own copy, confirmed at Start. Absent, the
    // catalog's figure is used and marked unconfirmed.
    totalUnits: z.number().int().positive().max(100000).optional(),
    today: localDay,
})

export type AddShelfEntryInput = z.infer<typeof addShelfEntryInput>

// Either how many pages were read (`amount`) or where the reader is now
// (`position`). Exactly one.
export const logProgressInput = z.object({
    amount: z.number().int().positive().max(100000).optional(),
    position: z.number().int().min(0).max(100000).optional(),
    note: z.string().trim().max(2000).optional(),
    loggedOn: localDay,
}).refine((value) => (value.amount === undefined) !== (value.position === undefined), {
    message: "Send either amount or position.",
})

export type LogProgressInput = z.infer<typeof logProgressInput>

export const updateProgressLogInput = z.object({
    toPosition: z.number().int().min(0).max(100000).optional(),
    note: z.string().trim().max(2000).nullable().optional(),
})

export type UpdateProgressLogInput = z.infer<typeof updateProgressLogInput>

export const finishRunInput = z.object({
    status: z.enum(["finished", "dnf"]),
    finishedOn: localDay,
})

export type FinishRunInput = z.infer<typeof finishRunInput>

// Starting (or re-starting) a read of a book already on the shelf.
export const startRunInput = z.object({
    today: localDay.optional(),
    totalUnits: z.number().int().positive().max(100000).optional(),
})

export type StartRunInput = z.infer<typeof startRunInput>

// KOReader sync (/books → KOReader sync). The zone dates the logs a sync
// writes, since KOReader sends no day of its own.
export const readerSetupInput = z.object({
    timeZone: z.string().min(1).max(64),
})

export type ReaderSetupInput = z.infer<typeof readerSetupInput>

// Which book a synced file is: an entry (a read under way, or a want-list
// book, which starts it), or "not a book I track".
export const linkReaderDocumentInput = z.union([
    z.object({
        entryId: z.number().int().positive(),
        totalUnits: z.number().int().positive().max(100000).optional(),
        today: localDay.optional(),
    }),
    z.object({ ignore: z.literal(true) }),
])

export type LinkReaderDocumentInput = z.infer<typeof linkReaderDocumentInput>

export const updateRunInput = z.object({
    totalUnits: z.number().int().positive().max(100000).optional(),
    startedOn: localDay.nullable().optional(),
    finishedOn: localDay.optional(),
})

export type UpdateRunInput = z.infer<typeof updateRunInput>

// Every field optional, and null clears it: a review can be a bare thumbs-up.
export const upsertReviewInput = z.object({
    // Half stars: 1 is ½★, 10 is ★★★★★.
    rating: z.number().int().min(1).max(10).nullable().optional(),
    recommend: z.boolean().nullable().optional(),
    body: z.string().trim().max(10000).nullable().optional(),
    // Covers the review for anyone who has not finished the book.
    spoiler: z.boolean().optional(),
})

export type UpsertReviewInput = z.infer<typeof upsertReviewInput>

export const reviewCommentInput = z.object({
    content: z.string().trim().min(1).max(2000),
})

export type ReviewCommentInput = z.infer<typeof reviewCommentInput>

// One book from another service's export, already read out of its file by the
// client — the file itself never leaves the browser. Shaped for what any
// reading tracker exports rather than for Goodreads' columns, so a second
// source is a second parser, not a second endpoint.
export const importRowInput = z.object({
    // The source's own id for the book, e.g. Goodreads' Book Id. Re-importing
    // the same row is a no-op because of it.
    ref: z.string().trim().min(1).max(100),
    title: z.string().trim().min(1).max(300),
    creators: z.array(z.string().trim().min(1).max(200)).max(10),
    isbn13: z.string().regex(/^\d{13}$/).nullable(),
    isbn10: z.string().regex(/^\d{9}[\dX]$/).nullable(),
    totalUnits: z.number().int().positive().max(100000).nullable(),
    year: z.number().int().min(-3000).max(3000).nullable(),
    status: z.enum(["want", "reading", "finished", "dnf"]),
    // The one finish date the export has. A book read several times is
    // imported as one read, on this date.
    finishedOn: localDay.nullable(),
    addedOn: localDay.nullable(),
    rating: z.number().int().min(1).max(10).nullable(),
    review: z.string().trim().max(10000).nullable(),
})

export type ImportRowInput = z.infer<typeof importRowInput>

// Small batches. Matching a row can take two Open Library requests, paced
// about a second apart, two Google Books requests when Open Library refuses or
// lacks the book, and a cover copy afterwards: five each, so eight rows stay
// inside a Worker's limit of 50 outbound requests on the free plan.
export const IMPORT_BATCH_SIZE = 8;

export const importBatchInput = z.object({
    source: z.enum(["goodreads"]),
    rows: z.array(importRowInput).min(1).max(IMPORT_BATCH_SIZE),
    today: localDay,
})

export type ImportBatchInput = z.infer<typeof importBatchInput>

export type ImportRowResult = {
    ref: string;
    title: string;
    // "retry": the book catalog refused (a rate limit or an outage), so
    // nothing was written and the row should be sent again after
    // `retryAfterSeconds`.
    outcome: "added" | "skipped" | "failed" | "retry";
    // How the book was found: by ISBN, by title and author, or not at all, in
    // which case it was added from the export's own details. Null for a book
    // an earlier import already brought in.
    match: "isbn" | "title" | "manual" | null;
    entryId: number | null;
}
