import { Hono, type Context, type Next } from "hono";
import { Prisma } from "@prisma/client";
import { deleteCookie, getCookie, setCookie } from "hono/cookie";
import { sign, verify } from "hono/jwt";
import { deleteAccountInput, signinInput, signupInput, themeKeySchema } from "@blogging-app/common";
import z from "zod";
import { getConfig } from "../env";
import { getAdminEmails, isAdminEmail } from "../admin-config";
import { getPrismaClient } from "../prisma";
import { hashPassword, isBcryptHash, verifyPassword } from "../password";
import { sendTestNotificationToUser } from "../push";
import {
	generateVerificationToken,
	getVerificationExpiryDate,
	normalizeEmail,
	RESEND_COOLDOWN_MS,
	VERIFICATION_TOKEN_TTL_MS,
	sha256Hex
} from "../verification";
import { sendPasswordResetEmail, sendPendingApprovalEmail, sendVerificationEmail } from "../email";
import { getUserGroupId, MAIN_GROUP_KEY } from "../groups";
import { blockedUserIds } from "../blocks";

type UserRouteEnv = {
	Bindings: {
		DATABASE_URL?: string,
		JWT_SECRET?: string,
		ADMIN_EMAILS?: string,
		RESEND_API_KEY?: string,
		EMAIL_FROM?: string,
		FRONTEND_URL?: string,
		VAPID_PUBLIC_KEY?: string,
		VAPID_PRIVATE_KEY?: string,
		VAPID_SUBJECT?: string,
		R2_PUBLIC_BASE_URL?: string,
		BLOG_IMAGES?: {
			put: (key: string, value: ArrayBuffer, options?: {
				httpMetadata?: { contentType?: string },
				customMetadata?: Record<string, string>
			}) => Promise<unknown>,
			head: (key: string) => Promise<unknown | null>,
			delete: (key: string | string[]) => Promise<unknown>
		}
	},
	Variables: {
		userId: number
	},
};

const PROFILE_PICTURE_MAX_BYTES = 3 * 1024 * 1024;
const PROFILE_PICTURE_ALLOWED_MIME = new Set([
	"image/jpeg",
	"image/png",
	"image/webp",
	"image/gif",
]);
const PROFILE_PICTURE_EXTENSION_BY_MIME: Record<string, string> = {
	"image/jpeg": "jpg",
	"image/png": "png",
	"image/webp": "webp",
	"image/gif": "gif",
};

function buildPublicImageUrl(baseUrl: string | undefined, key: string | null) {
	if (!baseUrl || !key) {
		return null;
	}
	const normalizedBase = baseUrl.endsWith("/") ? baseUrl.slice(0, -1) : baseUrl;
	return `${normalizedBase}/${key}`;
}

export const userRouter = new Hono<UserRouteEnv>();

const ACCESS_TOKEN_TTL_SECONDS = 15 * 60;
const REFRESH_TOKEN_TTL_MS = 30 * 24 * 60 * 60 * 1000;
const REFRESH_COOKIE_NAME = "refresh_token";
const PASSWORD_RESET_TOKEN_TTL_MS = 60 * 60 * 1000;

function isSecureRequest(c: Context<UserRouteEnv>) {
	const url = new URL(c.req.url);
	return url.protocol === "https:";
}

function setRefreshTokenCookie(c: Context<UserRouteEnv>, token: string) {
	setCookie(c, REFRESH_COOKIE_NAME, token, {
		path: "/",
		httpOnly: true,
		secure: isSecureRequest(c),
		sameSite: "Lax",
		maxAge: Math.floor(REFRESH_TOKEN_TTL_MS / 1000),
	});
}

function clearRefreshTokenCookie(c: Context<UserRouteEnv>) {
	deleteCookie(c, REFRESH_COOKIE_NAME, {
		path: "/",
	});
}

function createRefreshToken() {
	return `${crypto.randomUUID()}${crypto.randomUUID()}`;
}

const profileAuthMiddleware = async (c: Context<UserRouteEnv>, next: Next) => {
	try {
		const authHeader = c.req.header("Authorization") || "";
		const token = authHeader.startsWith("Bearer ")
			? authHeader.slice("Bearer ".length).trim()
			: authHeader.trim();
		if (!token) {
			c.status(403);
			return c.json({ msg: "Missing authorization token" });
		}
		const { jwtSecret } = getConfig(c);
		const payload = await verify(token, jwtSecret, "HS256");
		const userId = Number(payload?.id);
		if (!Number.isFinite(userId)) {
			c.status(403);
			return c.json({ msg: "Token payload is missing a valid user id" });
		}
		c.set("userId", userId);
		await next();
	} catch (e) {
		c.status(403);
		return c.json({
			msg: "You are not logged in",
			error: e instanceof Error ? e.message : "Invalid token"
		});
	}
};

userRouter.use("/me", profileAuthMiddleware);
userRouter.use("/me/*", profileAuthMiddleware);
userRouter.use("/list", profileAuthMiddleware);

const verifyEmailInput = z.object({
	email: z.string().email(),
	token: z.string().min(10),
});

const resendVerificationInput = z.object({
	email: z.string().email(),
});

const forgotPasswordInput = z.object({
	email: z.string().email(),
});

const resetPasswordInput = z.object({
	email: z.string().email(),
	token: z.string().min(10),
	password: z.string().min(6),
});

// Web Push and APNs share this table. For Web Push, `endpoint` is the push
// service URL and `keys` carries the encryption material; for APNs, `endpoint`
// is the hex device token and there are no keys at all.
//
// The APNs environment rides in `provider` rather than a new column: the same
// device token is not valid in both sandbox and production, so they have to be
// told apart, and encoding it here avoids a migration.
const pushSubscriptionInput = z
	.object({
		endpoint: z.string().min(1),
		provider: z.enum(["webpush", "apns", "apns-sandbox"]).default("webpush"),
		keys: z
			.object({
				p256dh: z.string().min(1),
				auth: z.string().min(1),
			})
			.optional(),
		userAgent: z.string().optional(),
	})
	.refine((value) => value.provider !== "webpush" || value.keys !== undefined, {
		message: "Web Push subscriptions must include encryption keys",
		path: ["keys"],
	});

const pushUnsubscribeInput = z.object({
	endpoint: z.string().optional(),
});

const notificationSettingsInput = z.object({
	notificationsEnabled: z.boolean(),
});

const testNotificationInput = z.object({
	title: z.string().min(1).max(120).optional(),
	body: z.string().min(1).max(500).optional(),
});

userRouter.post('/signup', async (c) => {
	try {
		const body = await c.req.json();
		const parsed = signupInput.safeParse(body);
		if(!parsed.success){
			c.status(400);
			return c.json({
				msg: "Inputs are incorrect",
				errors: parsed.error.flatten()
			})
		}
		const adminEmails = getAdminEmails(c);
		const { databaseUrl } = getConfig(c);
		const prisma = getPrismaClient(databaseUrl);
		const resendApiKey = c.env?.RESEND_API_KEY ?? process.env.RESEND_API_KEY;
		const emailFrom = c.env?.EMAIL_FROM ?? process.env.EMAIL_FROM;
		const frontendUrl = c.env?.FRONTEND_URL ?? process.env.FRONTEND_URL ?? "http://localhost:5173";
		if (!resendApiKey || !emailFrom) {
			throw new Error("RESEND_API_KEY and EMAIL_FROM are required for signup");
		}

		const normalizedEmail = normalizeEmail(parsed.data.email);
		const requestedStatus = isAdminEmail(parsed.data.email, adminEmails)
			? "approved"
			: "pending";
		const verificationToken = generateVerificationToken();
		const verificationTokenHash = await sha256Hex(verificationToken);
		const verificationExpiry = getVerificationExpiryDate();
		const passwordHash = await hashPassword(parsed.data.password);

		const user = await prisma.user.create({
			data: {
				email: normalizedEmail,
				password: passwordHash,
				name: parsed.data.name ?? null,
				status: requestedStatus,
				emailVerificationTokenHash: verificationTokenHash,
				emailVerificationExpiresAt: verificationExpiry,
				group: { connect: { key: MAIN_GROUP_KEY } },
			},
			select: {
				id: true,
				name: true,
			}
		});

		const verificationUrl = new URL("/verify-email", frontendUrl);
		verificationUrl.searchParams.set("token", verificationToken);
		verificationUrl.searchParams.set("email", normalizedEmail);

		try {
			await sendVerificationEmail({
				apiKey: resendApiKey,
				from: emailFrom,
				to: normalizedEmail,
				appName: "Eddie's Lounge",
				verificationUrl: verificationUrl.toString(),
				recipientName: user.name,
			});
		} catch (emailError) {
			console.error(emailError);
			return c.json({
				msg: "Account created, but verification email could not be sent. Use resend verification after fixing email configuration.",
				userId: user.id
			});
		}

		if (requestedStatus === "pending" && adminEmails.length > 0) {
			const adminUrl = new URL("/admin", frontendUrl).toString();
			try {
				await sendPendingApprovalEmail({
					apiKey: resendApiKey,
					from: emailFrom,
					to: adminEmails,
					appName: "Eddie's Lounge",
					pendingUserEmail: normalizedEmail,
					pendingUserName: user.name,
					adminUrl,
				});
			} catch (adminEmailError) {
				// Do not block signup on admin notification failures.
				console.error(adminEmailError);
			}
		}

		return c.json({
			msg: requestedStatus === "approved"
				? "Account created. Please verify your email before signing in."
				: "Account request submitted. Verify your email, then wait for admin approval.",
			userId: user.id
		});
	
  } catch(e: unknown) {
		console.error(e);
		if (e instanceof Error && e.message.includes("RESEND_API_KEY and EMAIL_FROM are required")) {
			c.status(500);
			return c.json({ msg: "Server email configuration is missing. Set RESEND_API_KEY and EMAIL_FROM." });
		}
		if (e instanceof Prisma.PrismaClientKnownRequestError && e.code === "P2002") {
			c.status(409);
			return c.json({ msg: "Email already exists" });
		}
		c.status(500);
		return c.json({ msg: "Failed to create user" });
	}
})

userRouter.post('/signin', async (c) => {
	
	try {
		const body = await c.req.json();
		const parsed = signinInput.safeParse(body);
		if(!parsed.success){
			c.status(400);
			return c.json({
				msg: "Inputs are incorrect",
				errors: parsed.error.flatten()
			})
		}
		const { databaseUrl, jwtSecret } = getConfig(c);
		const prisma = getPrismaClient(databaseUrl);

		const user = await prisma.user.findFirst({
			where: {
				email: normalizeEmail(parsed.data.email),
			},
			select: {
				id: true,
				status: true,
				emailVerifiedAt: true,
				password: true,
			}
		});
	
		if (!user) {
			c.status(403); //unauthorised
			return c.json({ msg: "Incorrect credentials" });
		}

		const validPassword = await verifyPassword({
			plainPassword: parsed.data.password,
			storedPassword: user.password,
		});
		if (!validPassword) {
			c.status(403);
			return c.json({ msg: "Incorrect credentials" });
		}

		if (!isBcryptHash(user.password)) {
			const upgradedHash = await hashPassword(parsed.data.password);
			await prisma.user.update({
				where: { id: user.id },
				data: { password: upgradedHash },
			});
		}

		if (!user.emailVerifiedAt) {
			c.status(403);
			return c.json({ msg: "Please verify your email before signing in." });
		}

		if (user.status !== "approved") {
			c.status(403);
			return c.json({ msg: "Your account is pending admin approval." });
		}

		const refreshToken = createRefreshToken();
		const refreshTokenHash = await sha256Hex(refreshToken);
		const refreshExpiresAt = new Date(Date.now() + REFRESH_TOKEN_TTL_MS);
		await prisma.session.create({
			data: {
				userId: user.id,
				tokenHash: refreshTokenHash,
				expiresAt: refreshExpiresAt,
			},
		});
		setRefreshTokenCookie(c, refreshToken);
		const nowSeconds = Math.floor(Date.now() / 1000);
		const jwt = await sign({
			id: user.id,
			exp: nowSeconds + ACCESS_TOKEN_TTL_SECONDS
		}, jwtSecret, "HS256");
		return c.json({ token: jwt });
	
	} catch(e) {
		console.error(e);
		c.status(500);
		return c.json({ msg: "Failed to sign in" })
	}

	})

userRouter.post("/refresh", async (c) => {
	try {
		const refreshToken = getCookie(c, REFRESH_COOKIE_NAME);
		if (!refreshToken) {
			c.status(401);
			return c.json({ msg: "Missing refresh token" });
		}

		const { databaseUrl, jwtSecret } = getConfig(c);
		const prisma = getPrismaClient(databaseUrl);
		const refreshTokenHash = await sha256Hex(refreshToken);
		const now = new Date();
		const existing = await prisma.session.findFirst({
			where: {
				tokenHash: refreshTokenHash,
				revokedAt: null,
				expiresAt: {
					gt: now,
				},
			},
			select: {
				id: true,
				userId: true,
				user: {
					select: {
						emailVerifiedAt: true,
						status: true,
					},
				},
			},
		});

		if (!existing) {
			clearRefreshTokenCookie(c);
			c.status(401);
			return c.json({ msg: "Invalid refresh token" });
		}

		if (!existing.user.emailVerifiedAt || existing.user.status !== "approved") {
			await prisma.session.update({
				where: { id: existing.id },
				data: { revokedAt: now },
			});
			clearRefreshTokenCookie(c);
			c.status(403);
			return c.json({ msg: "Account is not eligible for refresh" });
		}

		const nextRefreshToken = createRefreshToken();
		const nextRefreshTokenHash = await sha256Hex(nextRefreshToken);
		const nextRefreshExpiry = new Date(Date.now() + REFRESH_TOKEN_TTL_MS);
		await prisma.$transaction([
			prisma.session.update({
				where: { id: existing.id },
				data: { revokedAt: now },
			}),
			prisma.session.create({
				data: {
					userId: existing.userId,
					tokenHash: nextRefreshTokenHash,
					expiresAt: nextRefreshExpiry,
				},
			}),
		]);

		setRefreshTokenCookie(c, nextRefreshToken);
		const nowSeconds = Math.floor(Date.now() / 1000);
		const jwt = await sign({
			id: existing.userId,
			exp: nowSeconds + ACCESS_TOKEN_TTL_SECONDS
		}, jwtSecret, "HS256");
		return c.json({ token: jwt });
	} catch (e) {
		console.error(e);
		c.status(500);
		return c.json({ msg: "Failed to refresh session" });
	}
});

userRouter.post("/logout", async (c) => {
	try {
		const refreshToken = getCookie(c, REFRESH_COOKIE_NAME);
		clearRefreshTokenCookie(c);
		if (!refreshToken) {
			return c.json({ msg: "Logged out" });
		}

		const { databaseUrl } = getConfig(c);
		const prisma = getPrismaClient(databaseUrl);
		const tokenHash = await sha256Hex(refreshToken);
		await prisma.session.updateMany({
			where: {
				tokenHash,
				revokedAt: null,
			},
			data: {
				revokedAt: new Date(),
			},
		});
		return c.json({ msg: "Logged out" });
	} catch (e) {
		console.error(e);
		c.status(500);
		return c.json({ msg: "Failed to logout" });
	}
});

userRouter.post("/verify-email", async (c) => {
	try {
		const body = await c.req.json();
		const parsed = verifyEmailInput.safeParse(body);
		if (!parsed.success) {
			c.status(400);
			return c.json({
				msg: "Invalid verification request",
				errors: parsed.error.flatten(),
			});
		}

		const { databaseUrl } = getConfig(c);
		const prisma = getPrismaClient(databaseUrl);
		const email = normalizeEmail(parsed.data.email);
		const tokenHash = await sha256Hex(parsed.data.token);
		const now = new Date();

		const user = await prisma.user.findUnique({
			where: {
				email,
			},
			select: {
				id: true,
				emailVerifiedAt: true,
				emailVerificationTokenHash: true,
				emailVerificationExpiresAt: true,
			},
		});

		if (!user) {
			c.status(400);
			return c.json({ msg: "Invalid or expired verification link." });
		}

		if (user.emailVerifiedAt) {
			return c.json({ msg: "Email already verified. You can sign in." });
		}

		const tokenMatches = user.emailVerificationTokenHash === tokenHash;
		const tokenExpired =
			!user.emailVerificationExpiresAt || user.emailVerificationExpiresAt < now;
		if (!tokenMatches || tokenExpired) {
			c.status(400);
			return c.json({ msg: "Invalid or expired verification link." });
		}

		await prisma.user.update({
			where: {
				id: user.id,
			},
			data: {
				emailVerifiedAt: now,
				emailVerificationTokenHash: null,
				emailVerificationExpiresAt: null,
			},
		});

		return c.json({ msg: "Email verified. You can now sign in." });
	} catch (e) {
		console.error(e);
		c.status(500);
		return c.json({ msg: "Failed to verify email" });
	}
});

userRouter.post("/resend-verification", async (c) => {
	try {
		const body = await c.req.json();
		const parsed = resendVerificationInput.safeParse(body);
		if (!parsed.success) {
			c.status(400);
			return c.json({
				msg: "Invalid email",
				errors: parsed.error.flatten(),
			});
		}

		const resendApiKey = c.env?.RESEND_API_KEY ?? process.env.RESEND_API_KEY;
		const emailFrom = c.env?.EMAIL_FROM ?? process.env.EMAIL_FROM;
		const frontendUrl = c.env?.FRONTEND_URL ?? process.env.FRONTEND_URL ?? "http://localhost:5173";
		if (!resendApiKey || !emailFrom) {
			throw new Error("RESEND_API_KEY and EMAIL_FROM are required for resend");
		}

		const { databaseUrl } = getConfig(c);
		const prisma = getPrismaClient(databaseUrl);
		const email = normalizeEmail(parsed.data.email);

		const user = await prisma.user.findUnique({
			where: {
				email,
			},
			select: {
				id: true,
				name: true,
				emailVerifiedAt: true,
				emailVerificationExpiresAt: true,
			},
		});

		if (!user || user.emailVerifiedAt) {
			return c.json({
				msg: "If your account exists and is unverified, a verification email has been sent.",
			});
		}

		const now = Date.now();
		const lastSentAtMs = user.emailVerificationExpiresAt
			? user.emailVerificationExpiresAt.getTime() - VERIFICATION_TOKEN_TTL_MS
			: 0;
		const elapsedMs = now - lastSentAtMs;
		if (lastSentAtMs > 0 && elapsedMs < RESEND_COOLDOWN_MS) {
			const retryAfterSeconds = Math.ceil((RESEND_COOLDOWN_MS - elapsedMs) / 1000);
			c.status(429);
			return c.json({
				msg: `Please wait ${retryAfterSeconds}s before requesting another verification email.`,
				retryAfterSeconds,
			});
		}

		const verificationToken = generateVerificationToken();
		const verificationTokenHash = await sha256Hex(verificationToken);
		const verificationExpiry = getVerificationExpiryDate();

		await prisma.user.update({
			where: {
				id: user.id,
			},
			data: {
				emailVerificationTokenHash: verificationTokenHash,
				emailVerificationExpiresAt: verificationExpiry,
			},
		});

		const verificationUrl = new URL("/verify-email", frontendUrl);
		verificationUrl.searchParams.set("token", verificationToken);
		verificationUrl.searchParams.set("email", email);

		await sendVerificationEmail({
			apiKey: resendApiKey,
			from: emailFrom,
			to: email,
			appName: "Eddie's Lounge",
			verificationUrl: verificationUrl.toString(),
			recipientName: user.name,
		});

		return c.json({
			msg: "If your account exists and is unverified, a verification email has been sent.",
		});
	} catch (e) {
		console.error(e);
		c.status(500);
		return c.json({ msg: "Failed to resend verification email" });
	}
});

userRouter.post("/forgot-password", async (c) => {
	try {
		const body = await c.req.json();
		const parsed = forgotPasswordInput.safeParse(body);
		if (!parsed.success) {
			c.status(400);
			return c.json({
				msg: "Invalid email",
				errors: parsed.error.flatten(),
			});
		}

		const resendApiKey = c.env?.RESEND_API_KEY ?? process.env.RESEND_API_KEY;
		const emailFrom = c.env?.EMAIL_FROM ?? process.env.EMAIL_FROM;
		const frontendUrl = c.env?.FRONTEND_URL ?? process.env.FRONTEND_URL ?? "http://localhost:5173";
		if (!resendApiKey || !emailFrom) {
			throw new Error("RESEND_API_KEY and EMAIL_FROM are required for forgot password");
		}

		const { databaseUrl } = getConfig(c);
		const prisma = getPrismaClient(databaseUrl);
		const email = normalizeEmail(parsed.data.email);
		const user = await prisma.user.findUnique({
			where: { email },
			select: {
				id: true,
				name: true,
				email: true,
			},
		});

		if (user) {
			const resetToken = generateVerificationToken();
			const resetTokenHash = await sha256Hex(resetToken);
			const resetExpiresAt = new Date(Date.now() + PASSWORD_RESET_TOKEN_TTL_MS);

			await prisma.user.update({
				where: { id: user.id },
				data: {
					passwordResetTokenHash: resetTokenHash,
					passwordResetExpiresAt: resetExpiresAt,
				},
			});

			const resetUrl = new URL("/reset-password", frontendUrl);
			resetUrl.searchParams.set("token", resetToken);
			resetUrl.searchParams.set("email", email);

			await sendPasswordResetEmail({
				apiKey: resendApiKey,
				from: emailFrom,
				to: user.email,
				appName: "Eddie's Lounge",
				resetUrl: resetUrl.toString(),
				recipientName: user.name,
			});
		}

		return c.json({
			msg: "If your account exists, you will receive a password reset email shortly.",
		});
	} catch (e) {
		console.error(e);
		c.status(500);
		return c.json({ msg: "Failed to process forgot password request" });
	}
});

userRouter.post("/reset-password", async (c) => {
	try {
		const body = await c.req.json();
		const parsed = resetPasswordInput.safeParse(body);
		if (!parsed.success) {
			c.status(400);
			return c.json({
				msg: "Invalid reset request",
				errors: parsed.error.flatten(),
			});
		}

		const { databaseUrl } = getConfig(c);
		const prisma = getPrismaClient(databaseUrl);
		const email = normalizeEmail(parsed.data.email);
		const tokenHash = await sha256Hex(parsed.data.token);
		const now = new Date();
		const user = await prisma.user.findUnique({
			where: { email },
			select: {
				id: true,
				passwordResetTokenHash: true,
				passwordResetExpiresAt: true,
			},
		});

		const tokenMatches = user?.passwordResetTokenHash === tokenHash;
		const tokenExpired = !user?.passwordResetExpiresAt || user.passwordResetExpiresAt < now;
		if (!user || !tokenMatches || tokenExpired) {
			c.status(400);
			return c.json({ msg: "Invalid or expired password reset link." });
		}

		const nextPasswordHash = await hashPassword(parsed.data.password);
		await prisma.$transaction([
			prisma.user.update({
				where: { id: user.id },
				data: {
					password: nextPasswordHash,
					passwordResetTokenHash: null,
					passwordResetExpiresAt: null,
				},
			}),
			prisma.session.updateMany({
				where: {
					userId: user.id,
					revokedAt: null,
				},
				data: {
					revokedAt: now,
				},
			}),
		]);
		clearRefreshTokenCookie(c);

		return c.json({ msg: "Password reset successful. Please sign in again." });
	} catch (e) {
		console.error(e);
		c.status(500);
		return c.json({ msg: "Failed to reset password" });
	}
});

userRouter.get("/me/push/key", async (c) => {
	try {
		const { vapidPublicKey } = getConfig(c);
		if (!vapidPublicKey) {
			c.status(500);
			return c.json({ msg: "Push notifications are not configured." });
		}

		return c.json({ publicKey: vapidPublicKey });
	} catch (e) {
		console.error(e);
		c.status(500);
		return c.json({ msg: "Failed to load push key." });
	}
});

userRouter.post("/me/push/subscribe", async (c) => {
	try {
		const body = await c.req.json();
		const parsed = pushSubscriptionInput.safeParse(body);
		if (!parsed.success) {
			c.status(400);
			return c.json({
				msg: "Invalid push subscription payload",
				errors: parsed.error.flatten(),
			});
		}

		const { databaseUrl } = getConfig(c);
		const prisma = getPrismaClient(databaseUrl);
		const userId = c.get("userId");
		await prisma.userPushSubscription.upsert({
			where: {
				endpoint: parsed.data.endpoint,
			},
			update: {
				userId,
				provider: parsed.data.provider,
				p256dh: parsed.data.keys?.p256dh ?? null,
				auth: parsed.data.keys?.auth ?? null,
				userAgent: parsed.data.userAgent?.trim() || null,
			},
			create: {
				userId,
				endpoint: parsed.data.endpoint,
				provider: parsed.data.provider,
				p256dh: parsed.data.keys?.p256dh ?? null,
				auth: parsed.data.keys?.auth ?? null,
				userAgent: parsed.data.userAgent?.trim() || null,
			},
		});
		return c.json({ msg: "Push subscription stored." });
	} catch (e) {
		console.error(e);
		c.status(500);
		return c.json({ msg: "Failed to store push subscription." });
	}
});

userRouter.post("/me/push/unsubscribe", async (c) => {
	try {
		const body = await c.req.json();
		const parsed = pushUnsubscribeInput.safeParse(body);
		if (!parsed.success) {
			c.status(400);
			return c.json({
				msg: "Invalid unsubscribe payload",
				errors: parsed.error.flatten(),
			});
		}

		const { databaseUrl } = getConfig(c);
		const prisma = getPrismaClient(databaseUrl);
		const userId = c.get("userId");
		const deleteResult = parsed.data.endpoint
			? await prisma.userPushSubscription.deleteMany({
				where: {
					userId,
					endpoint: parsed.data.endpoint,
				},
			  })
			: await prisma.userPushSubscription.deleteMany({
				where: {
					userId,
				},
			  });

		return c.json({
			msg: "Push subscriptions removed.",
			removed: deleteResult.count,
		});
	} catch (e) {
		console.error(e);
		c.status(500);
		return c.json({ msg: "Failed to remove push subscription." });
	}
});

userRouter.put("/me/notifications", async (c) => {
	try {
		const body = await c.req.json();
		const parsed = notificationSettingsInput.safeParse(body);
		if (!parsed.success) {
			c.status(400);
			return c.json({
				msg: "Invalid notifications settings payload",
				errors: parsed.error.flatten(),
			});
		}

		const { databaseUrl } = getConfig(c);
		const prisma = getPrismaClient(databaseUrl);
		const userId = c.get("userId");
		const updatedUser = await prisma.user.update({
			where: { id: userId },
			data: {
				notificationsEnabled: parsed.data.notificationsEnabled,
			},
			select: {
				id: true,
				notificationsEnabled: true,
			},
		});

		if (!parsed.data.notificationsEnabled) {
			await prisma.userPushSubscription.deleteMany({
				where: {
					userId,
				},
			});
		}

		return c.json({ notificationsEnabled: updatedUser.notificationsEnabled });
	} catch (e) {
		console.error(e);
		c.status(500);
		return c.json({ msg: "Failed to update notification settings." });
	}
});

userRouter.post("/me/push/test", async (c) => {
	try {
		const body = await c.req.json();
		const parsed = testNotificationInput.safeParse(body);
		if (!parsed.success) {
			c.status(400);
			return c.json({
				msg: "Invalid test notification payload",
				errors: parsed.error.flatten(),
			});
		}

		const { databaseUrl, vapidPublicKey, vapidPrivateKey, vapidSubject } = getConfig(c);
		const userId = c.get("userId");
		await sendTestNotificationToUser({
			databaseUrl,
			userId,
			vapidConfig: {
				vapidPublicKey,
				vapidPrivateKey,
				vapidSubject,
			},
			title: parsed.data.title,
			body: parsed.data.body,
		});

		return c.json({ msg: "Test notification sent." });
	} catch (e) {
		if (e instanceof Error) {
			const msg = e.message || "Failed to send test notification.";
			if (
				msg.includes("Push notifications are not configured") ||
				msg.includes("Push notifications are disabled") ||
				msg.includes("No active device") ||
				msg.includes("No valid device")
			) {
				c.status(400);
				return c.json({ msg });
			}
		}

		console.error(e);
		c.status(500);
		return c.json({ msg: "Failed to send test notification." });
	}
});

userRouter.get("/list", async (c) => {
	try {
		const { databaseUrl, r2PublicBaseUrl } = getConfig(c);
		const prisma = getPrismaClient(databaseUrl);
		const groupId = await getUserGroupId(prisma, c.get("userId"));
		if (groupId === null) {
			c.status(403);
			return c.json({ msg: "Invalid user" });
		}
		// Someone on the other side of a block is simply not in the list.
		const blocked = await blockedUserIds(prisma, c.get("userId"));
		const [recentPosters, allUsers] = await Promise.all([
			prisma.post.groupBy({
				by: ["authorId"],
				where: { author: { groupId } },
				_max: { createdAt: true },
				orderBy: { _max: { createdAt: "desc" } },
				take: 200,
			}),
			prisma.user.findMany({
				where: {
					groupId,
					...(blocked.size > 0 ? { id: { notIn: [...blocked] } } : {}),
					status: "approved",
					emailVerifiedAt: { not: null },
				},
				orderBy: [
					{ name: "asc" },
					{ id: "asc" },
				],
				take: 200,
				select: {
					id: true,
					name: true,
					themeKey: true,
					profilePictureKey: true,
				},
			}),
		]);

		const usersById = new Map(allUsers.map((user) => [user.id, user]));
		const ordered: typeof allUsers = [];
		const seen = new Set<number>();
		for (const poster of recentPosters) {
			const user = usersById.get(poster.authorId);
			if (user) {
				ordered.push(user);
				seen.add(user.id);
			}
		}
		for (const user of allUsers) {
			if (!seen.has(user.id)) {
				ordered.push(user);
			}
		}

		return c.json({
			users: ordered.map((user) => ({
				id: user.id,
				name: user.name,
				themeKey: user.themeKey,
				profilePictureUrl: buildPublicImageUrl(r2PublicBaseUrl, user.profilePictureKey),
			})),
		});
	} catch (e) {
		console.error(e);
		c.status(500);
		return c.json({ msg: "Failed to load users." });
	}
});

userRouter.get("/me", async (c) => {
	try {
		const { databaseUrl, r2PublicBaseUrl } = getConfig(c);
		const prisma = getPrismaClient(databaseUrl);
		const userId = c.get("userId");
		const user = await prisma.user.findUnique({
			where: {
				id: userId
			},
			select: {
				id: true,
				email: true,
				name: true,
				bio: true,
				themeKey: true,
				notificationsEnabled: true,
				profilePictureKey: true,
				termsAcceptedAt: true,
			}
		});
		if (!user) {
			c.status(404);
			return c.json({ msg: "User not found" });
		}
		const isAdmin = isAdminEmail(user.email, getAdminEmails(c));
		const profilePictureUrl = buildPublicImageUrl(r2PublicBaseUrl, user.profilePictureKey);
		return c.json({
			user: {
				...user,
				termsAcceptedAt: user.termsAcceptedAt ? user.termsAcceptedAt.toISOString() : null,
				isAdmin,
				profilePictureUrl,
			},
		});
	} catch (e) {
		console.error(e);
		c.status(500);
		return c.json({ msg: "Failed to load profile" });
	}
});

// The Community Guidelines. Recorded once per account, so agreeing on one
// device covers every other.
userRouter.post("/me/accept-terms", async (c) => {
	try {
		const { databaseUrl } = getConfig(c);
		const prisma = getPrismaClient(databaseUrl);
		const user = await prisma.user.update({
			where: { id: c.get("userId") },
			data: { termsAcceptedAt: new Date() },
			select: { termsAcceptedAt: true },
		});
		return c.json({ termsAcceptedAt: user.termsAcceptedAt?.toISOString() ?? null });
	} catch (e) {
		if (e instanceof Prisma.PrismaClientKnownRequestError && e.code === "P2025") {
			c.status(404);
			return c.json({ msg: "User not found" });
		}
		console.error(e);
		c.status(500);
		return c.json({ msg: "Failed to record your agreement" });
	}
});

// Deletes the account and everything it owns, immediately — App Store
// Guideline 5.1.1(v). The password is asked again so that a phone left
// unlocked cannot be used to erase someone.
//
// Objects in R2 go first. The rows are the only record of which objects belong
// to this person, so deleting the user first would strand their picture, their
// post images and any unopened ciphertext with nothing left pointing at them.
userRouter.post("/me/delete", async (c) => {
	try {
		const parsed = deleteAccountInput.safeParse(await c.req.json());
		if (!parsed.success) {
			c.status(400);
			return c.json({ msg: "Enter your password to delete your account." });
		}

		const { databaseUrl } = getConfig(c);
		const prisma = getPrismaClient(databaseUrl);
		const userId = c.get("userId");
		const user = await prisma.user.findUnique({
			where: { id: userId },
			select: { password: true, profilePictureKey: true },
		});
		if (!user) {
			c.status(404);
			return c.json({ msg: "User not found" });
		}

		const validPassword = await verifyPassword({
			plainPassword: parsed.data.password,
			storedPassword: user.password,
		});
		if (!validPassword) {
			// 400, not 403: clients treat 403 as an expired session and refresh,
			// which would turn a typo into being signed out.
			c.status(400);
			return c.json({ msg: "That password is not correct." });
		}

		const [posts, instants] = await Promise.all([
			prisma.post.findMany({
				where: { authorId: userId, imageKey: { not: null } },
				select: { imageKey: true },
			}),
			prisma.instant.findMany({
				where: {
					OR: [{ senderId: userId }, { recipientId: userId }],
					mediaKey: { not: null },
				},
				select: { mediaKey: true },
			}),
		]);
		const objectKeys = [
			user.profilePictureKey,
			...posts.map((post) => post.imageKey),
			...instants.map((instant) => instant.mediaKey),
		].filter((key): key is string => Boolean(key));

		const bucket = c.env?.BLOG_IMAGES;
		if (objectKeys.length > 0) {
			if (!bucket) {
				// Refuse rather than strand the objects: see above.
				c.status(500);
				return c.json({ msg: "BLOG_IMAGES R2 binding is not configured." });
			}
			// R2 takes up to 1000 keys per call.
			for (let i = 0; i < objectKeys.length; i += 1000) {
				await bucket.delete(objectKeys.slice(i, i + 1000));
			}
		}

		// Cascades take sessions, device keys, instants, streaks, posts, comments,
		// likes, chat messages, push subscriptions and blocks. Reports survive
		// with this side set to null.
		await prisma.user.delete({ where: { id: userId } });
		clearRefreshTokenCookie(c);

		return c.json({ msg: "Your account has been deleted." });
	} catch (e) {
		console.error(e);
		c.status(500);
		return c.json({ msg: "Failed to delete your account." });
	}
});

userRouter.post("/me/profile-picture", async (c) => {
	const bucket = c.env?.BLOG_IMAGES;
	if (!bucket) {
		c.status(500);
		return c.json({ msg: "BLOG_IMAGES R2 binding is not configured." });
	}

	try {
		const formData = await c.req.formData();
		const fileInput = formData.get("image");
		if (!(fileInput instanceof File)) {
			c.status(400);
			return c.json({ msg: "Image file is required." });
		}
		if (!PROFILE_PICTURE_ALLOWED_MIME.has(fileInput.type)) {
			c.status(400);
			return c.json({ msg: "Only JPG, PNG, WEBP, or GIF images are allowed." });
		}
		if (fileInput.size <= 0 || fileInput.size > PROFILE_PICTURE_MAX_BYTES) {
			c.status(400);
			return c.json({ msg: "Image must be between 1B and 3MB." });
		}

		const userId = c.get("userId");
		const extension = PROFILE_PICTURE_EXTENSION_BY_MIME[fileInput.type] ?? "bin";
		const key = `profile-pictures/${userId}/${Date.now()}-${crypto.randomUUID()}.${extension}`;
		const bytes = await fileInput.arrayBuffer();

		await bucket.put(key, bytes, {
			httpMetadata: { contentType: fileInput.type },
			customMetadata: { userId: String(userId) },
		});

		const { databaseUrl, r2PublicBaseUrl } = getConfig(c);
		const prisma = getPrismaClient(databaseUrl);
		const previous = await prisma.user.findUnique({
			where: { id: userId },
			select: { profilePictureKey: true },
		});
		await prisma.user.update({
			where: { id: userId },
			data: { profilePictureKey: key },
		});

		if (previous?.profilePictureKey && previous.profilePictureKey !== key) {
			c.executionCtx.waitUntil(
				Promise.resolve(bucket.delete(previous.profilePictureKey)).catch((err) => {
					console.error("Failed to delete previous profile picture", err);
				})
			);
		}

		return c.json({
			key,
			profilePictureUrl: buildPublicImageUrl(r2PublicBaseUrl, key),
		});
	} catch (e) {
		console.error(e);
		c.status(500);
		return c.json({ msg: "Failed to upload profile picture." });
	}
});

userRouter.post("/me/profile-picture/delete", async (c) => {
	try {
		const { databaseUrl } = getConfig(c);
		const prisma = getPrismaClient(databaseUrl);
		const userId = c.get("userId");
		const existing = await prisma.user.findUnique({
			where: { id: userId },
			select: { profilePictureKey: true },
		});
		if (!existing) {
			c.status(404);
			return c.json({ msg: "User not found" });
		}
		if (!existing.profilePictureKey) {
			return c.json({ msg: "No profile picture to delete." });
		}

		await prisma.user.update({
			where: { id: userId },
			data: { profilePictureKey: null },
		});

		const bucket = c.env?.BLOG_IMAGES;
		if (bucket) {
			c.executionCtx.waitUntil(
				Promise.resolve(bucket.delete(existing.profilePictureKey)).catch((err) => {
					console.error("Failed to delete profile picture from bucket", err);
				})
			);
		}

		return c.json({ msg: "Profile picture removed." });
	} catch (e) {
		console.error(e);
		c.status(500);
		return c.json({ msg: "Failed to delete profile picture." });
	}
});

userRouter.put("/me", async (c) => {
	try {
		const { databaseUrl, r2PublicBaseUrl } = getConfig(c);
		const prisma = getPrismaClient(databaseUrl);
		const body = await c.req.json();
		const bio = typeof body?.bio === "string" ? body.bio.trim() : "";
		const rawThemeKey = typeof body?.themeKey === "string" ? body.themeKey : undefined;
		const parsedThemeKey = rawThemeKey ? themeKeySchema.safeParse(rawThemeKey) : null;
		if (bio.length > 100) {
			c.status(400);
			return c.json({ msg: "Bio must be 100 characters or less" });
		}
		if (parsedThemeKey && !parsedThemeKey.success) {
			c.status(400);
			return c.json({ msg: "Invalid theme selection." });
		}
		const userId = c.get("userId");
		try {
			const user = await prisma.user.update({
				where: {
					id: userId
				},
				data: {
					bio,
					...(parsedThemeKey?.success ? { themeKey: parsedThemeKey.data } : {})
				},
				select: {
					id: true,
					name: true,
					bio: true,
					themeKey: true,
					profilePictureKey: true,
				}
			});
			const profilePictureUrl = buildPublicImageUrl(r2PublicBaseUrl, user.profilePictureKey);
			return c.json({ user: { ...user, profilePictureUrl } });
		} catch (e) {
			if (e instanceof Prisma.PrismaClientKnownRequestError && e.code === "P2025") {
				c.status(404);
				return c.json({ msg: "User not found" });
			}
			throw e;
		}
	} catch (e) {
		console.error(e);
		c.status(500);
		return c.json({ msg: "Failed to update profile" });
	}
});
