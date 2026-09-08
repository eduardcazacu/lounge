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

export const createChatMessageInput = z.object({
    content: z.string().trim().min(1).max(1000),
})

export type CreateChatMessageInput = z.infer<typeof createChatMessageInput>

export const chatSettingsInput = z.object({
    retentionHours: z.number().int().min(1).max(720), // 1h .. 30d
})

export type ChatSettingsInput = z.infer<typeof chatSettingsInput>

// ---------------------------------------------------------------------------
// Instant — expiring, end-to-end encrypted 1:1 photos.
//
// The native iOS client mirrors these shapes by hand, so keep them explicit and
// keep the field names stable.
// ---------------------------------------------------------------------------

export const instantDurationModes = ["1s", "5s", "infinite"] as const;

export const instantDurationMode = z.enum(instantDurationModes);

export type InstantDurationMode = z.infer<typeof instantDurationMode>;

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
