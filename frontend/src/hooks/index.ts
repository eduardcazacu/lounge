import axios from "axios";
import { useCallback, useEffect, useMemo, useState } from "react"
import { useInfiniteQuery, useQuery, type InfiniteData } from "@tanstack/react-query";
import { BACKEND_URL } from "../config";
import { clearAuthStorage, getAuthHeader, getCurrentUserId, isAuthErrorStatus } from "../lib/auth";
import { accountKey, queryClient } from "../lib/query";

export interface Comment {
    id: number;
    content: string;
    createdAt: string;
    editedAt?: string | null;
    likeCount?: number;
    likedByMe?: boolean;
    author: {
        id?: number;
        name: string | null;
    };
}

// A review cross-posted from /books. Present only on such posts.
export interface ShelfReviewCard {
    id: number;
    rating: number | null;
    recommend: boolean | null;
    body: string | null;
    spoiler?: boolean;
    /** A spoiler this viewer hasn't finished the book for. */
    covered?: boolean;
    status: string;
    item: { title: string; creators: string[]; coverUrl: string | null; kind: string };
}

// An ask for a recommendation cross-posted from /books. Present only on such posts.
export interface ShelfAskCard {
    id: number;
    body: string;
    commentCount: number;
}

export  interface Blog{
    "content": string;
    "title": string;
    "id": number;
    "createdAt": string;
    "editedAt"?: string | null;
    "imageKey"?: string | null;
    "imageUrl"?: string | null;
    "shelfReview"?: ShelfReviewCard | null;
    "shelfAsk"?: ShelfAskCard | null;
    "likeCount"?: number;
    "likedByMe"?: boolean;
    "commentCount"?: number;
    "comments"?: Comment[];
    "topComments"?: Comment[];
    "author": {
        "id"?: number;
        "name": string | null;
        "bio": string;
        "themeKey"?: string | null;
        "profilePictureUrl"?: string | null;
    }
}



// The blog's reads, through the app's query cache (src/lib/query.ts). What was
// fetched once is drawn at once on the way back, and refreshed behind it.

const PAGE_SIZE = 10;

interface BlogsPage {
    blogs: Blog[];
    nextCursor: number | null;
    hasMore: boolean;
}

/**
 * A 401/403 that survived the axios interceptor's one refresh means the session
 * is gone. Clearing the token also clears the query cache, which would take the
 * error with it, so whether it happened is kept here.
 */
function useAuthExpired(error: unknown) {
    const [authExpired, setAuthExpired] = useState(false);
    const expired = axios.isAxiosError(error) && isAuthErrorStatus(error.response?.status);
    useEffect(() => {
        if (expired) {
            clearAuthStorage();
            setAuthExpired(true);
        }
    }, [expired]);
    return authExpired || expired;
}

/**
 * After a write from a post or a feed card. Marks the blog's reads stale without
 * refetching them now: the open post holds its own edits in state, and the feed
 * refreshes when it is next shown.
 */
export function markBlogsStale() {
    const userId = getCurrentUserId();
    void queryClient.invalidateQueries({ queryKey: accountKey(userId, "blogs"), refetchType: "none" });
    void queryClient.invalidateQueries({ queryKey: accountKey(userId, "blog"), refetchType: "none" });
}

/** The post as some cached feed page already has it: its body, without its comments. */
function blogFromFeeds(userId: number | null, id: string): Blog | undefined {
    const feeds = queryClient.getQueriesData<InfiniteData<BlogsPage>>({ queryKey: accountKey(userId, "blogs") });
    for (const [, feed] of feeds) {
        for (const page of feed?.pages ?? []) {
            const blog = page.blogs.find((b) => String(b.id) === id);
            if (blog) return { ...blog, comments: undefined };
        }
    }
    return undefined;
}

export const useBlog = ({ id }: { id: string }) => {
    const userId = getCurrentUserId();
    const query = useQuery({
        queryKey: accountKey(userId, "blog", id),
        queryFn: async () => {
            const response = await axios.get(`${BACKEND_URL}/api/v1/blog/${id}`, {
                headers: { Authorization: getAuthHeader() },
            });
            return response.data.blog as Blog;
        },
        // Opened from the feed, the post is on screen before its fetch returns.
        placeholderData: () => blogFromFeeds(userId, id),
        // FullBlog copies the post into state for editing; a refetch that
        // changed it would reset an edit in progress.
        refetchOnWindowFocus: false,
    });
    const authExpired = useAuthExpired(query.error);

    return {
        loading: query.isPending,
        blog: query.data,
        /** The post is the feed's copy, and its comments are still on the way. */
        commentsPending: query.isPlaceholderData,
        authExpired,
    };
};

export interface UserListItem {
    id: number;
    name: string | null;
    themeKey: string | null;
    profilePictureUrl: string | null;
}


export const useUsers = () => {
    const query = useQuery({
        queryKey: accountKey(getCurrentUserId(), "users"),
        queryFn: async () => {
            const response = await axios.get(`${BACKEND_URL}/api/v1/user/list`, {
                headers: { Authorization: getAuthHeader() },
            });
            return Array.isArray(response.data?.users) ? (response.data.users as UserListItem[]) : [];
        },
        staleTime: 5 * 60_000,
    });
    const authExpired = useAuthExpired(query.error);

    return { loading: query.isPending, users: query.data ?? EMPTY_USERS, authExpired };
};

const EMPTY_USERS: UserListItem[] = [];

export const useBlogs = (authorId: number | null = null) => {
    const userId = getCurrentUserId();
    const query = useInfiniteQuery({
        queryKey: accountKey(userId, "blogs", authorId),
        queryFn: async ({ pageParam }) => {
            const response = await axios.get(`${BACKEND_URL}/api/v1/blog/bulk`, {
                headers: { Authorization: getAuthHeader() },
                params: {
                    limit: PAGE_SIZE,
                    ...(pageParam !== null ? { cursor: pageParam } : {}),
                    ...(authorId != null ? { authorId } : {}),
                },
            });
            return {
                blogs: (response.data?.blogs ?? []) as Blog[],
                nextCursor: typeof response.data?.nextCursor === "number" ? response.data.nextCursor : null,
                hasMore: Boolean(response.data?.hasMore),
            } satisfies BlogsPage;
        },
        initialPageParam: null as number | null,
        getNextPageParam: (last) => (last.hasMore && last.nextCursor !== null ? last.nextCursor : undefined),
    });
    const authExpired = useAuthExpired(query.error);
    const { data, hasNextPage, isFetchingNextPage, isPending, fetchNextPage: fetchNext } = query;

    const fetchNextPage = useCallback(() => {
        if (!hasNextPage || isPending || isFetchingNextPage || authExpired) {
            return;
        }
        void fetchNext();
    }, [authExpired, fetchNext, hasNextPage, isFetchingNextPage, isPending]);

    // Back to the newest page, without blanking the feed while it loads: keep
    // the first page that is already drawn, drop the rest, and refetch it.
    const refreshBlogs = useCallback(() => {
        const queryKey = accountKey(userId, "blogs", authorId);
        queryClient.setQueryData<InfiniteData<BlogsPage, number | null>>(queryKey, (feed) =>
            feed && { pages: feed.pages.slice(0, 1), pageParams: feed.pageParams.slice(0, 1) }
        );
        void queryClient.invalidateQueries({ queryKey, exact: true });
    }, [authorId, userId]);

    const blogs = useMemo(() => data?.pages.flatMap((page) => page.blogs) ?? EMPTY_BLOGS, [data]);

    return {
        loading: isPending,
        loadingMore: isFetchingNextPage,
        blogs,
        authExpired,
        hasMore: Boolean(hasNextPage),
        fetchNextPage,
        refreshBlogs,
    };
};

const EMPTY_BLOGS: Blog[] = [];
