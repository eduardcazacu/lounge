import { Hono } from "hono";
import { Prisma } from "@prisma/client";
import { verify } from 'hono/jwt'
import { createBlogInput, postLabel, updateBlogInput, type PostImageInput } from "@blogging-app/common";
import z from "zod";
import { getConfig } from "../env";
import { getPrismaClient } from "../prisma";
import { notifyFollowersOfNewPost, notifyPostAuthorOfReply, notifyMentionedUsers } from "../push";
import { scheduleBackgroundWork } from "../background";
import { getUserGroupId } from "../groups";
import { coveredFor, finishedItemIds, gatesSpoilers, masksSpoilersFor } from "../shelf-spoilers";

const MAX_MENTIONS_PER_COMMENT = 10;

// Defensively normalize a client-supplied mentionedUserIds payload into a
// deduped list of positive integers, capped to a sane maximum.
function parseMentionedUserIds(raw: unknown): number[] {
  if (!Array.isArray(raw)) {
    return [];
  }
  const ids: number[] = [];
  for (const value of raw) {
    const id = Number(value);
    if (Number.isInteger(id) && id > 0 && !ids.includes(id)) {
      ids.push(id);
    }
    if (ids.length >= MAX_MENTIONS_PER_COMMENT) {
      break;
    }
  }
  return ids;
}

type BlogImagesBucket = {
  put: (key: string, value: ArrayBuffer, options?: {
    httpMetadata?: { contentType?: string },
    customMetadata?: Record<string, string>
  }) => Promise<unknown>,
  head: (key: string) => Promise<unknown | null>,
  delete: (keys: string | string[]) => Promise<void>
};

export const blogRouter = new Hono<{
	Bindings: {
		DATABASE_URL?: string,
		JWT_SECRET?: string,
    R2_PUBLIC_BASE_URL?: string,
    BLOG_IMAGES?: BlogImagesBucket
	},
    Variables: {
        userId: number
    }
}>();

const MAX_IMAGE_FILE_SIZE_BYTES = 3 * 1024 * 1024;
const allowedImageMimeTypes = new Set([
  "image/jpeg",
  "image/png",
  "image/webp",
  "image/gif",
]);
const updateCommentInput = z.object({
  content: z.string().min(1),
});

function buildPublicImageUrl(baseUrl: string | undefined, key: string) {
  if (!baseUrl) {
    return null;
  }
  const normalizedBase = baseUrl.endsWith("/") ? baseUrl.slice(0, -1) : baseUrl;
  return `${normalizedBase}/${key}`;
}

// A post's photos, in carousel order.
const postImagesSelect = {
  orderBy: { position: "asc" },
  select: { key: true, width: true, height: true },
} satisfies Prisma.Post$imagesArgs;

function postImagesView(images: { key: string; width: number | null; height: number | null }[], baseUrl: string | undefined) {
  return images.map((image) => ({
    // The key too, so the author's editor can send the photos back in a new order.
    key: image.key,
    url: buildPublicImageUrl(baseUrl, image.key),
    width: image.width,
    height: image.height,
  }));
}

/**
 * Checks that every photo is one this author uploaded and that it is there.
 * Answers with the error to send, or null. The prefix is the ownership test:
 * uploads are stored under `posts/<author>/` and nowhere else.
 */
async function checkPostImages(bucket: BlogImagesBucket | undefined, authorId: number, images: PostImageInput[]) {
  if (images.length === 0) return null;
  const keys = images.map((image) => image.key);
  if (new Set(keys).size !== keys.length) return "The same photo is in the post twice.";
  if (keys.some((key) => !key.startsWith(`posts/${authorId}/`))) return "Invalid image key.";
  if (!bucket) return "BLOG_IMAGES R2 binding is not configured.";
  const found = await Promise.all(keys.map((key) => bucket.head(key)));
  return found.every(Boolean) ? null : "A photo didn't finish uploading. Remove it and add it again.";
}

function imageRows(images: PostImageInput[]) {
  return images.map((image, position) => ({
    key: image.key,
    position,
    width: image.width ?? null,
    height: image.height ?? null,
  }));
}

// A post cross-posted from /books carries its review, and the card is drawn
// from that rather than from the post's own text, so editing the review on
// /books edits the card here too. See wiki/books.md.
const shelfReviewCardSelect = {
  select: {
    id: true,
    rating: true,
    recommend: true,
    body: true,
    spoiler: true,
    run: {
      select: {
        status: true,
        entry: {
          select: {
            userId: true,
            item: { select: { id: true, title: true, creators: true, coverUrl: true, kind: true } },
            // The reviewer's edition, as on /books (itemView in route/shelf.ts).
            edition: { select: { title: true, coverUrl: true } },
          },
        },
      },
    },
  },
} as const;

// An ask cross-posted from /books, drawn from the ask the same way.
const shelfAskCardSelect = {
  select: { id: true, body: true, _count: { select: { comments: true } } },
} as const;

function shelfAskCard(ask: { id: number; body: string; _count: { comments: number } } | null) {
  return ask ? { id: ask.id, body: ask.body, commentCount: ask._count.comments } : null;
}

function shelfReviewCard(
  review: {
    id: number;
    rating: number | null;
    recommend: boolean | null;
    body: string | null;
    spoiler: boolean;
    run: {
      status: string;
      entry: {
        userId: number;
        item: { id: number; title: string; creators: string[]; coverUrl: string | null; kind: string };
        edition: { title: string; coverUrl: string | null } | null;
      };
    };
  } | null,
  viewerId: number,
  finished: Set<number>
) {
  if (!review) return null;
  const { id: itemId, ...item } = review.run.entry.item;
  return {
    id: review.id,
    rating: review.rating,
    recommend: review.recommend,
    body: review.body,
    spoiler: review.spoiler,
    covered: coveredFor(review, review.run.entry.userId, itemId, viewerId, finished),
    maskSpoilers: masksSpoilersFor(review, review.run.entry.userId, itemId, viewerId, finished),
    status: review.run.status,
    item: {
      ...item,
      title: review.run.entry.edition?.title ?? review.run.entry.item.title,
      coverUrl: review.run.entry.edition?.coverUrl ?? review.run.entry.item.coverUrl,
    },
  };
}

blogRouter.use("/*", async (c, next) => {
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
        const user = await verify(token, jwtSecret, "HS256");
        // Any audience marks Instant's socket ticket, which travels in a URL and
        // must never work as an API credential (wiki/accounts.md).
        if (user?.aud !== undefined) {
          c.status(403);
          return c.json({ msg: "This token cannot be used for API requests" });
        }
        const userId = Number(user?.id);
        if(Number.isFinite(userId)){
            c.set("userId", userId);
            return await next();
        }
        else{
            c.status(403) //unauthorized
            return c.json({
                msg: "Token payload is missing a valid user id"
            })
        }
    } catch(e){
        c.status(403) //unauthorized
        return c.json({
            msg: "You are not logged in",
            error: e instanceof Error ? e.message : "Invalid token"
        })
    }
    
});

blogRouter.post("/upload-image", async (c) => {
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

    if (!allowedImageMimeTypes.has(fileInput.type)) {
      c.status(400);
      return c.json({ msg: "Only JPG, PNG, WEBP, or GIF images are allowed." });
    }

    if (fileInput.size <= 0 || fileInput.size > MAX_IMAGE_FILE_SIZE_BYTES) {
      c.status(400);
      return c.json({ msg: "Image must be between 1B and 3MB." });
    }

    const authorId = c.get("userId");
    const extensionByMime: Record<string, string> = {
      "image/jpeg": "jpg",
      "image/png": "png",
      "image/webp": "webp",
      "image/gif": "gif",
    };
    const extension = extensionByMime[fileInput.type] ?? "bin";
    const key = `posts/${authorId}/${Date.now()}-${crypto.randomUUID()}.${extension}`;
    const bytes = await fileInput.arrayBuffer();

    await bucket.put(key, bytes, {
      httpMetadata: {
        contentType: fileInput.type,
      },
      customMetadata: {
        authorId: String(authorId),
      },
    });

    const { r2PublicBaseUrl } = getConfig(c);
    return c.json({
      key,
      url: buildPublicImageUrl(r2PublicBaseUrl, key),
    });
  } catch (e) {
    console.error(e);
    c.status(500);
    return c.json({ msg: "Failed to upload image." });
  }
});

/**
 * Deletes a photo uploaded for a post that was never posted with it: removed
 * from the composer, or part of a discarded draft. Only the uploader's own,
 * and only while no post holds it — a photo already in a post goes when it is
 * edited out of it.
 */
blogRouter.delete("/upload-image", async (c) => {
  const key = c.req.query("key")?.trim() ?? "";
  const authorId = c.get("userId");
  if (!key.startsWith(`posts/${authorId}/`)) {
    c.status(400);
    return c.json({ msg: "Invalid image key." });
  }
  const bucket = c.env?.BLOG_IMAGES;
  if (!bucket) {
    c.status(500);
    return c.json({ msg: "BLOG_IMAGES R2 binding is not configured." });
  }
  const { databaseUrl } = getConfig(c);
  const prisma = getPrismaClient(databaseUrl);
  const inUse = await prisma.postImage.findUnique({ where: { key }, select: { id: true } });
  if (inUse) {
    c.status(409);
    return c.json({ msg: "That photo is part of a post." });
  }
  await bucket.delete(key);
  return c.json({ ok: true });
});

blogRouter.post('/:id/comments', async (c) => {
    const postId = Number(c.req.param("id"));
    if (!Number.isFinite(postId)) {
      c.status(400);
      return c.json({ msg: "Invalid blog id" });
    }

    const body = await c.req.json();
    const content = typeof body?.content === "string" ? body.content.trim() : "";
    if (!content) {
      c.status(400);
      return c.json({ msg: "Comment content is required" });
    }

    const authorId = c.get("userId");
    const { databaseUrl, vapidPublicKey, vapidPrivateKey, vapidSubject } = getConfig(c);
    const prisma = getPrismaClient(databaseUrl);
    try {
      const groupId = await getUserGroupId(prisma, authorId);
      if (groupId === null) {
        c.status(403);
        return c.json({ msg: "Invalid user" });
      }
      // A post outside the caller's group is reported as missing, not forbidden,
      // so its existence is not disclosed.
      const post = await prisma.post.findFirst({
        where: { id: postId, author: { groupId } },
        select: {
          id: true,
          title: true,
          content: true,
          authorId: true,
          _count: { select: { images: true } },
        },
      });
      if (!post) {
        c.status(404);
        return c.json({ msg: "Blog not found" });
      }
      const comment = await prisma.comment.create({
        data: {
          content,
          postId,
          authorId,
        },
        select: {
          id: true,
          content: true,
          createdAt: true,
          editedAt: true,
          author: {
            select: {
              id: true,
              name: true,
            },
          },
        },
      });
      const vapidConfig = { vapidPublicKey, vapidPrivateKey, vapidSubject };
      const replyNotificationJob = notifyPostAuthorOfReply({
        databaseUrl,
        postId: post.id,
        postTitle: postLabel({ ...post, imageCount: post._count.images }),
        postAuthorId: post.authorId,
        commentId: comment.id,
        commentAuthorId: authorId,
        commentAuthorName: comment.author.name?.trim() || "Someone",
        vapidConfig,
      });
      scheduleBackgroundWork(c, replyNotificationJob);

      // Resolve @mentions: only notify users actually referenced as "@name" in the
      // text, excluding the comment author (self) and the post author (who already
      // gets the reply push) so nobody is double-notified.
      const requestedMentionIds = parseMentionedUserIds(body?.mentionedUserIds);
      if (requestedMentionIds.length > 0) {
        const candidates = await prisma.user.findMany({
          where: {
            id: { in: requestedMentionIds },
            groupId,
            status: "approved",
            emailVerifiedAt: { not: null },
          },
          select: { id: true, name: true },
        });
        const mentionedUserIds = candidates
          .filter(
            (user) =>
              user.id !== authorId &&
              user.id !== post.authorId &&
              typeof user.name === "string" &&
              user.name.trim().length > 0 &&
              content.includes(`@${user.name}`)
          )
          .map((user) => user.id);

        if (mentionedUserIds.length > 0) {
          scheduleBackgroundWork(
            c,
            notifyMentionedUsers({
              databaseUrl,
              postId: post.id,
              postTitle: postLabel({ ...post, imageCount: post._count.images }),
              commentId: comment.id,
              commenterName: comment.author.name?.trim() || "Someone",
              mentionedUserIds,
              vapidConfig,
            })
          );
        }
      }

      return c.json({
        comment: {
          id: comment.id,
          content: comment.content,
          createdAt: comment.createdAt.toISOString(),
          editedAt: comment.editedAt ? comment.editedAt.toISOString() : null,
          likeCount: 0,
          likedByMe: false,
          author: {
            id: comment.author.id,
            name: comment.author.name
          }
        }
      });
    } catch (e: unknown) {
      if (e instanceof Prisma.PrismaClientKnownRequestError && e.code === "P2003") {
        c.status(404);
        return c.json({ msg: "Blog not found" });
      }
      console.error(e);
      c.status(500);
      return c.json({ msg: "Failed to create comment" });
    }
});

blogRouter.post('/:id/likes/toggle', async (c) => {
    const postId = Number(c.req.param("id"));
    if (!Number.isFinite(postId)) {
      c.status(400);
      return c.json({ msg: "Invalid blog id" });
    }

    const userId = c.get("userId");
    const { databaseUrl } = getConfig(c);
    const prisma = getPrismaClient(databaseUrl);

    const groupId = await getUserGroupId(prisma, userId);
    const post = groupId === null ? null : await prisma.post.findFirst({
      where: { id: postId, author: { groupId } },
      select: { id: true },
    });
    if (!post) {
      c.status(404);
      return c.json({ msg: "Blog not found" });
    }

    const existing = await prisma.postLike.findUnique({
      where: {
        postId_userId: {
          postId,
          userId,
        },
      },
      select: { id: true },
    });

    if (existing) {
      await prisma.postLike.delete({
        where: {
          postId_userId: {
            postId,
            userId,
          },
        },
      });
    } else {
      try {
        await prisma.postLike.create({
          data: {
            postId,
            userId,
          },
        });
      } catch (e) {
        if (e instanceof Prisma.PrismaClientKnownRequestError && e.code === "P2003") {
          c.status(404);
          return c.json({ msg: "Blog not found" });
        }
        throw e;
      }
    }

    const likeCount = await prisma.postLike.count({
      where: { postId },
    });

    return c.json({
      likedByMe: !existing,
      likeCount,
    });
});

blogRouter.post('/:id/comments/:commentId/likes/toggle', async (c) => {
    const postId = Number(c.req.param("id"));
    const commentId = Number(c.req.param("commentId"));
    if (!Number.isFinite(postId) || !Number.isFinite(commentId)) {
      c.status(400);
      return c.json({ msg: "Invalid ids" });
    }

    const userId = c.get("userId");
    const { databaseUrl } = getConfig(c);
    const prisma = getPrismaClient(databaseUrl);

    const groupId = await getUserGroupId(prisma, userId);
    const comment = groupId === null ? null : await prisma.comment.findFirst({
      where: { id: commentId, post: { author: { groupId } } },
      select: { postId: true },
    });
    if (!comment || comment.postId !== postId) {
      c.status(404);
      return c.json({ msg: "Comment not found" });
    }

    const existing = await prisma.commentLike.findUnique({
      where: {
        commentId_userId: {
          commentId,
          userId,
        },
      },
      select: { id: true },
    });

    if (existing) {
      await prisma.commentLike.delete({
        where: {
          commentId_userId: {
            commentId,
            userId,
          },
        },
      });
    } else {
      await prisma.commentLike.create({
        data: {
          commentId,
          userId,
        },
      });
    }

    const likeCount = await prisma.commentLike.count({
      where: { commentId },
    });

    return c.json({
      likedByMe: !existing,
      likeCount,
      commentId,
    });
});

  blogRouter.post('/',async (c) => {
    const body = await c.req.json()
    const parsed = createBlogInput.safeParse(body)
    if(!parsed.success){
        c.status(400);
        return c.json({
            msg: parsed.error.issues.find((issue) => issue.code === "custom")?.message ?? "Inputs are Incorrect"
        })
    }
    const authorId = c.get("userId")
    const { databaseUrl } = getConfig(c);
    const { title, content, imageKey } = parsed.data;
    const images = parsed.data.images.length > 0 || !imageKey ? parsed.data.images : [{ key: imageKey }];
    const imageError = await checkPostImages(c.env?.BLOG_IMAGES, authorId, images);
    if (imageError) {
      c.status(imageError.startsWith("BLOG_IMAGES") ? 500 : 400);
      return c.json({ msg: imageError });
    }
    const prisma = getPrismaClient(databaseUrl);
    const blog = await prisma.post.create({
      data: {
        title,
        content,
        authorId,
        images: { create: imageRows(images) },
      },
      select: {
        id: true,
      },
    });
    const author = await prisma.user.findUnique({
      where: {
        id: authorId,
      },
      select: {
        name: true,
      },
    });
    const authorName = (author?.name?.trim()) || "Someone";
    const config = getConfig(c);
    console.log("[push] post created, scheduling notification fan-out", {
      postId: blog.id,
      authorId,
      hasVapidPublicKey: Boolean(config.vapidPublicKey),
      hasVapidPrivateKey: Boolean(config.vapidPrivateKey),
      hasVapidSubject: Boolean(config.vapidSubject),
    });
    const notificationJob = notifyFollowersOfNewPost({
      databaseUrl,
      authorId,
      authorName,
      postId: blog.id,
      postTitle: postLabel({ title, content, imageCount: images.length }),
      vapidConfig: {
        vapidPublicKey: config.vapidPublicKey,
        vapidPrivateKey: config.vapidPrivateKey,
        vapidSubject: config.vapidSubject,
      },
    });
    c.executionCtx.waitUntil(notificationJob);
        return c.json({
            id: blog.id,
        })
    })
  
  blogRouter.put('/:id',async (c) => {
    const postId = Number(c.req.param("id"));
    if (!Number.isFinite(postId)) {
      c.status(400);
      return c.json({ msg: "Invalid blog id" });
    }

    const body = await c.req.json()
    const parsed = updateBlogInput.safeParse({
      ...body,
      id: postId,
    })
    if(!parsed.success){
        c.status(400);
        return c.json({
            msg: parsed.error.issues.find((issue) => issue.code === "custom")?.message ?? "Inputs are Incorrect"
        })
    }
    const authorId = c.get("userId")
    const { databaseUrl } = getConfig(c);
    const prisma = getPrismaClient(databaseUrl);
    const post = await prisma.post.findFirst({
      where: { id: postId, authorId },
      select: { images: { select: { key: true } } },
    });
    if (!post) {
      c.status(404);
      return c.json({
        msg: "Blog not found"
      });
    }
    const { images } = parsed.data;
    const bucket = c.env?.BLOG_IMAGES;
    if (images) {
      const imageError = await checkPostImages(bucket, authorId, images);
      if (imageError) {
        c.status(imageError.startsWith("BLOG_IMAGES") ? 500 : 400);
        return c.json({ msg: imageError });
      }
    }
    const editedAt = new Date();
    await prisma.$transaction([
      prisma.post.update({
        where: { id: postId },
        data: { title: parsed.data.title, content: parsed.data.content, editedAt },
      }),
      // Rewritten whole: ten rows at most, and the order is the point of them.
      ...(images
        ? [
            prisma.postImage.deleteMany({ where: { postId } }),
            prisma.postImage.createMany({ data: imageRows(images).map((row) => ({ ...row, postId })) }),
          ]
        : []),
    ]);
    // Photos edited out of the post go from storage once the edit has stuck.
    // Before it, a failed save would leave the post pointing at nothing.
    const kept = new Set(images?.map((image) => image.key));
    const removed = images ? post.images.map((image) => image.key).filter((key) => !kept.has(key)) : [];
    if (removed.length > 0 && bucket) scheduleBackgroundWork(c, bucket.delete(removed));
        return c.json({
            id: postId,
            editedAt: editedAt.toISOString(),
        })
    })

  blogRouter.put('/:id/comments/:commentId', async (c) => {
    const postId = Number(c.req.param("id"));
    const commentId = Number(c.req.param("commentId"));
    if (!Number.isFinite(postId) || !Number.isFinite(commentId)) {
      c.status(400);
      return c.json({ msg: "Invalid ids" });
    }

    const body = await c.req.json();
    const parsed = updateCommentInput.safeParse({
      content: typeof body?.content === "string" ? body.content.trim() : "",
    });
    if (!parsed.success) {
      c.status(400);
      return c.json({
        msg: "Comment content is required",
      });
    }

    const authorId = c.get("userId");
    const { databaseUrl } = getConfig(c);
    const prisma = getPrismaClient(databaseUrl);
    const editedAt = new Date();
    const updated = await prisma.comment.updateMany({
      where: {
        id: commentId,
        postId,
        authorId,
      },
      data: {
        content: parsed.data.content,
        editedAt,
      },
    });

    if (updated.count === 0) {
      c.status(404);
      return c.json({ msg: "Comment not found" });
    }

    return c.json({
      id: commentId,
      content: parsed.data.content,
      editedAt: editedAt.toISOString(),
    });
  });

    blogRouter.get('/bulk',async (c) => {
        const rawCursor = c.req.query("cursor");
        const rawLimit = c.req.query("limit");
        const rawAuthorId = c.req.query("authorId");
        const parsedCursor = rawCursor ? Number(rawCursor) : undefined;
        const parsedLimit = rawLimit ? Number(rawLimit) : 10;
        const parsedAuthorId = rawAuthorId ? Number(rawAuthorId) : undefined;
        const limit = Number.isFinite(parsedLimit)
          ? Math.max(1, Math.min(25, parsedLimit))
          : 10;
        const cursor = Number.isFinite(parsedCursor) ? parsedCursor : undefined;
        const filterAuthorId = Number.isFinite(parsedAuthorId) ? parsedAuthorId : undefined;

        const userId = c.get("userId");
        const { databaseUrl, r2PublicBaseUrl } = getConfig(c);
        const prisma = getPrismaClient(databaseUrl);
        const groupId = await getUserGroupId(prisma, userId);
        if (groupId === null) {
          c.status(403);
          return c.json({ msg: "Invalid user" });
        }
        const blogRows = await prisma.post.findMany({
          where: {
            author: { groupId },
            ...(cursor ? { id: { lt: cursor } } : {}),
            ...(filterAuthorId !== undefined ? { authorId: filterAuthorId } : {}),
          },
          take: limit + 1,
          orderBy: {
            id: "desc",
          },
          select: {
            id: true,
            title: true,
            content: true,
            images: postImagesSelect,
            createdAt: true,
            editedAt: true,
            shelfReview: shelfReviewCardSelect,
            shelfAsk: shelfAskCardSelect,
            author: {
              select: {
                id: true,
                name: true,
                bio: true,
                themeKey: true,
                profilePictureKey: true,
              },
            },
            comments: {
              orderBy: {
                createdAt: "asc",
              },
              take: 3,
              select: {
                id: true,
                content: true,
                createdAt: true,
                editedAt: true,
                author: {
                  select: {
                    id: true,
                    name: true,
                  },
                },
                _count: {
                  select: {
                    likes: true,
                  },
                },
                likes: {
                  where: {
                    userId,
                  },
                  select: {
                    id: true,
                  },
                  take: 1,
                },
              },
            },
            likes: {
              where: {
                userId,
              },
              select: {
                id: true,
              },
              take: 1,
            },
            _count: {
              select: {
                comments: true,
                likes: true,
              },
            },
          },
        });

        const hasMore = blogRows.length > limit;
        const pageRows = hasMore ? blogRows.slice(0, limit) : blogRows;
        const nextCursor = hasMore ? pageRows[pageRows.length - 1]?.id ?? null : null;

        const finished = await finishedItemIds(
          prisma,
          userId,
          pageRows.flatMap((blog) => (blog.shelfReview && gatesSpoilers(blog.shelfReview) ? [blog.shelfReview.run.entry.item.id] : []))
        );
        const blogs = pageRows.map((blog) => ({
          id: blog.id,
          title: blog.title,
          content: blog.content,
          images: postImagesView(blog.images, r2PublicBaseUrl),
          createdAt: blog.createdAt.toISOString(),
          editedAt: blog.editedAt ? blog.editedAt.toISOString() : null,
          shelfReview: shelfReviewCard(blog.shelfReview, userId, finished),
          shelfAsk: shelfAskCard(blog.shelfAsk),
          author: {
            id: blog.author.id,
            name: blog.author.name,
            bio: blog.author.bio,
            themeKey: blog.author.themeKey,
            profilePictureUrl: blog.author.profilePictureKey ? buildPublicImageUrl(r2PublicBaseUrl, blog.author.profilePictureKey) : null
          },
          likeCount: blog._count.likes,
          likedByMe: blog.likes.length > 0,
          commentCount: blog._count.comments,
          topComments: blog.comments.map((comment) => ({
            id: comment.id,
            content: comment.content,
            createdAt: comment.createdAt.toISOString(),
            editedAt: comment.editedAt ? comment.editedAt.toISOString() : null,
            likeCount: comment._count.likes,
            likedByMe: comment.likes.length > 0,
            author: {
              id: comment.author.id,
              name: comment.author.name
            }
          }))
        }));

        return c.json({
            blogs,
            nextCursor,
            hasMore
        })
    })
  
  blogRouter.get('/:id',async (c) => {
    const id = Number(c.req.param("id"))
    if (!Number.isFinite(id)) {
      c.status(400);
      return c.json({ msg: "Invalid blog id" });
    }
    const userId = c.get("userId");
    const { databaseUrl, r2PublicBaseUrl } = getConfig(c);
    const prisma = getPrismaClient(databaseUrl);
    try {
    const groupId = await getUserGroupId(prisma, userId);
    const blog = groupId === null ? null : await prisma.post.findFirst({
      where: { id, author: { groupId } },
      select: {
        id: true,
        title: true,
        content: true,
        images: postImagesSelect,
        createdAt: true,
        editedAt: true,
        shelfReview: shelfReviewCardSelect,
        shelfAsk: shelfAskCardSelect,
        author: {
          select: {
            id: true,
            name: true,
            bio: true,
            themeKey: true,
            profilePictureKey: true,
          },
        },
        comments: {
          orderBy: {
            createdAt: "asc",
          },
          select: {
            id: true,
            content: true,
            createdAt: true,
            editedAt: true,
            author: {
              select: {
                id: true,
                name: true,
              },
            },
            _count: {
              select: {
                likes: true,
              },
            },
            likes: {
              where: {
                userId,
              },
              select: {
                id: true,
              },
              take: 1,
            },
          },
        },
        likes: {
          where: {
            userId,
          },
          select: {
            id: true,
          },
          take: 1,
        },
        _count: {
          select: {
            likes: true,
          },
        },
      },
    });
    if (!blog) {
      c.status(404);
      return c.json({
        msg: "Blog not found"
      });
    }
        return c.json({
            blog: {
              id: blog.id,
              title: blog.title,
              content: blog.content,
              images: postImagesView(blog.images, r2PublicBaseUrl),
              createdAt: blog.createdAt.toISOString(),
              editedAt: blog.editedAt ? blog.editedAt.toISOString() : null,
              shelfReview: shelfReviewCard(
                blog.shelfReview,
                userId,
                blog.shelfReview && gatesSpoilers(blog.shelfReview) ? await finishedItemIds(prisma, userId, [blog.shelfReview.run.entry.item.id]) : new Set()
              ),
              shelfAsk: shelfAskCard(blog.shelfAsk),
              author: {
                id: blog.author.id,
                name: blog.author.name,
                bio: blog.author.bio,
                themeKey: blog.author.themeKey,
                profilePictureUrl: blog.author.profilePictureKey ? buildPublicImageUrl(r2PublicBaseUrl, blog.author.profilePictureKey) : null
              },
              likeCount: blog._count.likes,
              likedByMe: blog.likes.length > 0,
              comments: blog.comments.map((comment) => ({
                id: comment.id,
                content: comment.content,
                createdAt: comment.createdAt.toISOString(),
                editedAt: comment.editedAt ? comment.editedAt.toISOString() : null,
                likeCount: comment._count.likes,
                likedByMe: comment.likes.length > 0,
                author: {
                  id: comment.author.id,
                  name: comment.author.name
                }
              }))
            }
        });
    } catch(e){
        console.error(e);
        c.status(500);
        return c.json({
            msg: "Error while fetching the blog post"
        })
    }
})
