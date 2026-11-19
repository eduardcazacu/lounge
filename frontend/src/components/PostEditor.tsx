import axios from "axios";
import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import type { ReactNode } from "react";
import {
  DndContext,
  KeyboardSensor,
  MouseSensor,
  TouchSensor,
  closestCenter,
  useSensor,
  useSensors,
  type DragEndEvent,
} from "@dnd-kit/core";
import { SortableContext, rectSortingStrategy, sortableKeyboardCoordinates, useSortable } from "@dnd-kit/sortable";
import { CSS } from "@dnd-kit/utilities";
import { createPortal } from "react-dom";
import { useNavigate } from "react-router-dom";
import { MAX_POST_CONTENT, MAX_POST_IMAGES, MAX_POST_TITLE } from "@blogging-app/common";
import { BACKEND_URL } from "../config";
import { clearAuthStorage, getAuthHeader, getCachedProfile, isAuthErrorStatus } from "../lib/auth";
import { encodeFileToWebp, loadImageDimensions } from "../lib/image";
import { getThemePalette } from "../themes";
import { markBlogsStale, type PostImage } from "../hooks";
import { Avatar } from "./Avatar";
import { BlogCard } from "./BlogCard";

// Writing a post, new or edited. Words come first, photos are added from the
// toolbar and arranged as thumbnails (the first is the cover), and Preview draws
// the post exactly as the feed's card will. A new post's draft — photos
// included — is kept on this device until it is posted or discarded; an edit
// is not, because the post itself is the copy to come back to. See
// wiki/web-client.md.

const DRAFT_KEY = "publishPostDraft";
const MAX_IMAGE_WIDTH = 1920;
const MAX_IMAGE_HEIGHT = 1080;
const MAX_UPLOAD_BYTES = 3 * 1024 * 1024;
const TARGET_NON_GIF_BYTES = 2_400_000;
const PARALLEL_UPLOADS = 3;
const ACCEPTED = "image/jpeg,image/png,image/webp,image/gif";

type Photo = {
  id: string;
  status: "queued" | "uploading" | "ready" | "failed";
  /** What the thumbnail draws: the local file while uploading, the stored copy after. */
  preview: string;
  file?: File;
  key?: string;
  url?: string | null;
  width: number | null;
  height: number | null;
  /** Uploaded here and not yet part of a saved post, so deleting it is ours to do. */
  unposted: boolean;
  error?: string;
};

type Draft = {
  title: string;
  description: string;
  images?: { key: string; url: string | null; width: number | null; height: number | null }[];
  savedAt?: number;
};

export type EditablePost = {
  id: number;
  title: string;
  content: string;
  images: { key: string; url: string | null; width: number | null; height: number | null }[];
};

function newId() {
  return Math.random().toString(36).slice(2);
}

function readDraft(): Draft | null {
  try {
    const raw = localStorage.getItem(DRAFT_KEY);
    if (!raw) return null;
    const parsed = JSON.parse(raw) as Partial<Draft>;
    return {
      title: typeof parsed.title === "string" ? parsed.title : "",
      description: typeof parsed.description === "string" ? parsed.description : "",
      images: Array.isArray(parsed.images) ? parsed.images.filter((image) => typeof image?.key === "string") : [],
      savedAt: typeof parsed.savedAt === "number" ? parsed.savedAt : undefined,
    };
  } catch {
    return null;
  }
}

function writeDraft(draft: Draft | null) {
  try {
    if (draft) localStorage.setItem(DRAFT_KEY, JSON.stringify(draft));
    else localStorage.removeItem(DRAFT_KEY);
  } catch {
    // A full or blocked storage only loses the draft, never the post.
  }
}

function draftAge(savedAt: number) {
  const day = 86_400_000;
  const days = Math.floor((Date.now() - savedAt) / day);
  if (days < 1) return "earlier today";
  if (days < 2) return "yesterday";
  if (days < 7) return new Date(savedAt).toLocaleDateString(undefined, { weekday: "long" });
  return new Date(savedAt).toLocaleDateString(undefined, { day: "numeric", month: "short" });
}

async function shrink(file: File) {
  if (file.type === "image/gif") {
    // Re-encoding through a canvas would drop the animation, so a GIF goes up
    // as it is and is refused when it is too big.
    const { width, height } = await loadImageDimensions(file);
    if (width > MAX_IMAGE_WIDTH || height > MAX_IMAGE_HEIGHT) throw new Error("This GIF is bigger than 1920×1080.");
    return file;
  }
  return encodeFileToWebp(file, {
    maxWidth: MAX_IMAGE_WIDTH,
    maxHeight: MAX_IMAGE_HEIGHT,
    targetBytes: TARGET_NON_GIF_BYTES,
    qualityLevels: [0.96, 0.9, 0.84, 0.78],
    minLongEdge: 640,
  });
}

function forgetUpload(key: string) {
  // Best effort: a photo that stays behind costs storage, not correctness.
  void axios
    .delete(`${BACKEND_URL}/api/v1/blog/upload-image`, { params: { key }, headers: { Authorization: getAuthHeader() } })
    .catch(() => undefined);
}

/** How far the on-screen keyboard reaches up from the bottom of the layout viewport. */
function useKeyboardInset() {
  const [inset, setInset] = useState(0);
  useEffect(() => {
    const viewport = window.visualViewport;
    if (!viewport) return;
    const update = () => setInset(Math.max(0, window.innerHeight - viewport.height - viewport.offsetTop));
    viewport.addEventListener("resize", update);
    viewport.addEventListener("scroll", update);
    update();
    return () => {
      viewport.removeEventListener("resize", update);
      viewport.removeEventListener("scroll", update);
    };
  }, []);
  return inset;
}

export function PostEditor({ editing }: { editing?: EditablePost }) {
  const navigate = useNavigate();
  const profile = getCachedProfile();
  const palette = getThemePalette(profile.themeKey);
  const [restored] = useState(() => (editing ? null : readDraft()));
  const [title, setTitle] = useState(editing?.title ?? restored?.title ?? "");
  const [content, setContent] = useState(editing?.content ?? restored?.description ?? "");
  const [photos, setPhotos] = useState<Photo[]>(() =>
    (editing?.images ?? restored?.images ?? []).map((image) => ({
      id: newId(),
      status: "ready",
      preview: image.url ?? "",
      key: image.key,
      url: image.url,
      width: image.width,
      height: image.height,
      unposted: !editing,
    }))
  );
  const [showDraftNote, setShowDraftNote] = useState(Boolean(restored && (restored.title || restored.description || restored.images?.length)));
  const [previewing, setPreviewing] = useState(false);
  const [posting, setPosting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [leaving, setLeaving] = useState(false);
  const body = useRef<HTMLTextAreaElement>(null);
  const picker = useRef<HTMLInputElement>(null);
  const keyboard = useKeyboardInset();

  const uploading = photos.some((photo) => photo.status === "queued" || photo.status === "uploading");
  const failed = photos.some((photo) => photo.status === "failed");
  const hasSomething = title.trim().length > 0 || content.trim().length > 0 || photos.length > 0;
  const changed = editing
    ? title !== editing.title ||
      content !== editing.content ||
      photos.map((photo) => photo.key).join() !== editing.images.map((image) => image.key).join()
    : hasSomething;
  const canPost = hasSomething && !uploading && !failed && !posting;

  // The draft follows every change, photos included once they are stored.
  useEffect(() => {
    if (editing) return;
    const stored = photos.filter((photo) => photo.status === "ready" && photo.key);
    if (!title.trim() && !content.trim() && stored.length === 0) {
      writeDraft(null);
      return;
    }
    writeDraft({
      title,
      description: content,
      images: stored.map((photo) => ({ key: photo.key!, url: photo.url ?? null, width: photo.width, height: photo.height })),
      savedAt: Date.now(),
    });
  }, [editing, title, content, photos]);

  // The text grows with what is written rather than scrolling inside a box.
  useLayoutEffect(() => {
    const element = body.current;
    if (!element) return;
    element.style.height = "auto";
    element.style.height = `${Math.max(element.scrollHeight, 160)}px`;
  }, [content, previewing]);

  const update = useCallback((id: string, change: Partial<Photo>) => {
    setPhotos((current) => current.map((photo) => (photo.id === id ? { ...photo, ...change } : photo)));
  }, []);

  const upload = useCallback(
    async (photo: Photo) => {
      if (!photo.file) return;
      update(photo.id, { status: "uploading", error: undefined });
      try {
        const small = await shrink(photo.file);
        if (small.size > MAX_UPLOAD_BYTES) throw new Error("Still over 3 MB after shrinking it.");
        const { width, height } = await loadImageDimensions(small);
        const form = new FormData();
        form.append("image", small);
        const response = await axios.post(`${BACKEND_URL}/api/v1/blog/upload-image`, form, {
          headers: { Authorization: getAuthHeader() },
        });
        update(photo.id, { status: "ready", key: response.data?.key, url: response.data?.url ?? null, width, height });
      } catch (e) {
        if (axios.isAxiosError(e) && isAuthErrorStatus(e.response?.status)) {
          clearAuthStorage();
          navigate("/signin", { replace: true });
          return;
        }
        const message = axios.isAxiosError(e) ? e.response?.data?.msg || "Couldn't upload." : e instanceof Error ? e.message : "Couldn't upload.";
        update(photo.id, { status: "failed", error: message });
      }
    },
    [navigate, update]
  );

  // A few at a time: ten photos at once would starve each other on a phone.
  useEffect(() => {
    const running = photos.filter((photo) => photo.status === "uploading").length;
    photos
      .filter((photo) => photo.status === "queued")
      .slice(0, Math.max(0, PARALLEL_UPLOADS - running))
      .forEach((photo) => void upload(photo));
  }, [photos, upload]);

  // Object URLs are released with the photo they were made for.
  const previews = useRef(new Set<string>());
  useEffect(() => {
    const urls = previews.current;
    return () => urls.forEach((url) => URL.revokeObjectURL(url));
  }, []);

  function addFiles(files: FileList | null) {
    if (!files || files.length === 0) return;
    const room = MAX_POST_IMAGES - photos.length;
    const picked = Array.from(files).filter((file) => ACCEPTED.split(",").includes(file.type));
    setNotice(
      picked.length < files.length
        ? "Only JPG, PNG, WEBP and GIF photos can be added."
        : picked.length > room
          ? `A post holds ${MAX_POST_IMAGES} photos, so ${room === 0 ? "none" : `only the first ${room}`} were added.`
          : null
    );
    const added = picked.slice(0, Math.max(0, room)).map((file): Photo => {
      const preview = URL.createObjectURL(file);
      previews.current.add(preview);
      return { id: newId(), status: "queued", preview, file, width: null, height: null, unposted: true };
    });
    if (added.length) setPhotos((current) => [...current, ...added]);
  }

  function remove(photo: Photo) {
    setPhotos((current) => current.filter((other) => other.id !== photo.id));
    if (photo.unposted && photo.key) forgetUpload(photo.key);
  }

  function move(from: number, to: number) {
    setPhotos((current) => {
      const next = [...current];
      const [photo] = next.splice(from, 1);
      next.splice(to, 0, photo);
      return next;
    });
  }

  // Wraps the selection in a markdown mark, or drops in an empty pair to type
  // into. Line-level marks (a heading, a list, a quote) go at the start of each
  // selected line. The buttons keep the field's focus, so the selection holds.
  function format(kind: "bold" | "italic" | "heading" | "link" | "list" | "quote" | "code") {
    const field = body.current;
    if (!field) return;
    const { selectionStart: start, selectionEnd: end } = field;
    const selected = content.slice(start, end);
    let next = content;
    let from = start;
    let to = end;
    const wrap = (before: string, after: string, fallback: string) => {
      const inner = selected || fallback;
      next = content.slice(0, start) + before + inner + after + content.slice(end);
      from = start + before.length;
      to = from + inner.length;
    };
    if (kind === "bold") wrap("**", "**", "bold");
    if (kind === "italic") wrap("_", "_", "italic");
    if (kind === "code") {
      if (selected.includes("\n")) wrap("```\n", "\n```", "");
      else wrap("`", "`", "code");
    }
    if (kind === "link") {
      const text = selected || "link text";
      next = `${content.slice(0, start)}[${text}](https://)${content.slice(end)}`;
      from = start + text.length + 3;
      to = from + "https://".length;
    }
    if (kind === "heading" || kind === "list" || kind === "quote") {
      const prefix = kind === "heading" ? "## " : kind === "list" ? "- " : "> ";
      const lineStart = content.lastIndexOf("\n", start - 1) + 1;
      const block = content.slice(lineStart, end);
      const marked = block
        .split("\n")
        .map((line) => (line.startsWith(prefix) ? line.slice(prefix.length) : prefix + line))
        .join("\n");
      next = content.slice(0, lineStart) + marked + content.slice(end);
      from = lineStart;
      to = lineStart + marked.length;
    }
    setContent(next);
    requestAnimationFrame(() => {
      field.focus();
      field.setSelectionRange(from, to);
    });
  }

  function goBack() {
    const state = window.history.state as { idx?: number } | null;
    if (state?.idx && state.idx > 0) navigate(-1);
    else navigate(editing ? `/blog/${editing.id}` : "/blogs", { replace: true });
  }

  function discard() {
    if (!editing) writeDraft(null);
    photos.forEach((photo) => {
      if (photo.unposted && photo.key) forgetUpload(photo.key);
    });
    goBack();
  }

  async function post() {
    if (!canPost) return;
    setPosting(true);
    setError(null);
    const payload = {
      title: title.trim(),
      content: content.trim(),
      images: photos.map((photo) => ({ key: photo.key!, width: photo.width, height: photo.height })),
    };
    try {
      if (editing) {
        await axios.put(`${BACKEND_URL}/api/v1/blog/${editing.id}`, payload, { headers: { Authorization: getAuthHeader() } });
        markBlogsStale();
        navigate(`/blog/${editing.id}`, { replace: true });
      } else {
        await axios.post(`${BACKEND_URL}/api/v1/blog`, payload, { headers: { Authorization: getAuthHeader() } });
        writeDraft(null);
        markBlogsStale();
        // To the feed, refreshed, where the post now sits at the top.
        navigate("/blogs", { replace: true, state: { refreshFeedAt: Date.now(), posted: true } });
      }
    } catch (e) {
      if (axios.isAxiosError(e) && isAuthErrorStatus(e.response?.status)) {
        clearAuthStorage();
        navigate("/signin", { replace: true });
        return;
      }
      const reason = axios.isAxiosError(e) ? e.response?.data?.msg : null;
      setError(
        reason
          ? `${reason}${editing ? "" : " Your draft is kept."}`
          : editing
            ? "Couldn't save. Check your connection and try again."
            : "Couldn't post. Your draft is kept, so try again when you're back online."
      );
      setPosting(false);
    }
  }

  const previewImages: PostImage[] = photos.map((photo) => ({ url: photo.preview || photo.url || null, width: photo.width, height: photo.height }));

  return (
    <div className="min-h-dvh bg-white">
      <header
        className="sticky top-0 z-30 border-b border-slate-200/70 bg-white/90 backdrop-blur"
        style={{ paddingTop: "env(safe-area-inset-top)" }}
      >
        <div className="mx-auto flex h-14 max-w-2xl items-center gap-2 px-3">
          <button
            type="button"
            onClick={() => (changed ? setLeaving(true) : goBack())}
            className="rounded-full px-3 py-1.5 text-[15px] font-medium text-slate-600 hover:bg-slate-100"
          >
            Cancel
          </button>
          <h1 className="flex-1 text-center text-[17px] font-semibold text-slate-900">{editing ? "Edit post" : "New post"}</h1>
          <button
            type="button"
            onClick={() => void post()}
            disabled={!canPost}
            className="rounded-full px-4 py-1.5 text-[15px] font-semibold text-white shadow-sm transition-opacity disabled:opacity-40"
            style={{ background: palette.accent }}
          >
            {posting ? (editing ? "Saving…" : "Posting…") : editing ? "Save" : "Post"}
          </button>
        </div>
      </header>

      <main className="mx-auto max-w-2xl px-4 pb-40 pt-4">
        {error ? (
          <p role="alert" className="mb-3 rounded-xl bg-rose-50 px-3 py-2.5 text-sm text-rose-700">
            {error}
          </p>
        ) : null}
        {showDraftNote && restored?.savedAt ? (
          <p className="mb-3 flex items-center justify-between gap-2 rounded-xl bg-slate-50 px-3 py-2 text-sm text-slate-600">
            <span>Your draft from {draftAge(restored.savedAt)}.</span>
            <span className="flex gap-1">
              <button type="button" onClick={() => setShowDraftNote(false)} className="rounded-full px-2 py-1 font-medium text-slate-700 hover:bg-slate-200">
                Keep
              </button>
              <button
                type="button"
                onClick={() => {
                  photos.forEach((photo) => photo.unposted && photo.key && forgetUpload(photo.key));
                  setTitle("");
                  setContent("");
                  setPhotos([]);
                  setShowDraftNote(false);
                }}
                className="rounded-full px-2 py-1 font-medium text-rose-700 hover:bg-rose-100"
              >
                Discard
              </button>
            </span>
          </p>
        ) : null}

        {previewing ? (
          <div className="rounded-2xl p-3" style={{ background: palette.softBg }}>
            <p className="mb-2 text-center text-xs font-medium uppercase tracking-wide text-slate-500">As it shows in the feed</p>
            <BlogCard
              preview
              id={editing?.id ?? 0}
              authorname={profile.name || "You"}
              title={title}
              content={content}
              images={previewImages}
              publishedDate="Just now"
              themeKey={profile.themeKey}
              authorProfilePictureUrl={profile.profilePictureUrl}
            />
            {!hasSomething ? <p className="mt-3 text-center text-sm text-slate-500">Nothing to show yet.</p> : null}
          </div>
        ) : (
          <>
            <div className="flex items-center gap-2.5">
              <Avatar size="small" name={profile.name || "You"} themeKey={profile.themeKey} imageUrl={profile.profilePictureUrl} />
              <span className="text-sm font-medium text-slate-700">{profile.name || "You"}</span>
            </div>
            <input
              value={title}
              onChange={(event) => setTitle(event.target.value)}
              maxLength={MAX_POST_TITLE}
              placeholder="Title (optional)"
              aria-label="Title"
              className="mt-4 w-full border-0 bg-transparent p-0 text-2xl font-bold text-slate-900 placeholder:text-slate-300 focus:outline-none focus:ring-0"
            />
            <textarea
              ref={body}
              value={content}
              onChange={(event) => setContent(event.target.value)}
              maxLength={MAX_POST_CONTENT}
              placeholder="What's on your mind?"
              aria-label="Post"
              autoFocus={!editing}
              className="mt-3 block w-full resize-none overflow-hidden border-0 bg-transparent p-0 text-[17px] leading-relaxed text-slate-800 placeholder:text-slate-400 focus:outline-none focus:ring-0"
            />
            {content.length > MAX_POST_CONTENT * 0.9 ? (
              <p className="mt-1 text-right text-xs text-slate-500">
                {content.length.toLocaleString()} / {MAX_POST_CONTENT.toLocaleString()}
              </p>
            ) : null}
            {photos.length > 0 ? <PhotoGrid photos={photos} onRemove={remove} onRetry={(photo) => void upload(photo)} onMove={move} /> : null}
            {notice ? <p className="mt-2 text-sm text-amber-700">{notice}</p> : null}
          </>
        )}
      </main>

      <input
        ref={picker}
        type="file"
        accept={ACCEPTED}
        multiple
        className="hidden"
        onChange={(event) => {
          addFiles(event.target.files);
          event.target.value = "";
        }}
      />

      {/* Riding on the keyboard when it is up, so formatting is a thumb away. */}
      <div
        className="fixed inset-x-0 z-30 border-t border-slate-200 bg-white/95 backdrop-blur"
        style={{ bottom: keyboard, paddingBottom: keyboard > 0 ? 0 : "env(safe-area-inset-bottom)" }}
      >
        <div className="mx-auto flex h-12 max-w-2xl items-center gap-0.5 overflow-x-auto px-2 [scrollbar-width:none]">
          <ToolButton
            label="Add photos"
            onClick={() => picker.current?.click()}
            disabled={photos.length >= MAX_POST_IMAGES || previewing}
            accent={palette.accent}
          >
            <svg viewBox="0 0 24 24" className="h-5 w-5" fill="none" stroke="currentColor" strokeWidth="2" strokeLinejoin="round">
              <rect x="3" y="5" width="18" height="15" rx="2.5" />
              <circle cx="8.5" cy="10" r="1.6" />
              <path d="M21 16l-5-5-8 9" />
            </svg>
            <span className="text-xs tabular-nums">{photos.length > 0 ? `${photos.length}/${MAX_POST_IMAGES}` : ""}</span>
          </ToolButton>
          <span className="mx-1 h-6 w-px bg-slate-200" />
          <ToolButton label="Bold" onClick={() => format("bold")} disabled={previewing}>
            <b className="text-[17px]">B</b>
          </ToolButton>
          <ToolButton label="Italic" onClick={() => format("italic")} disabled={previewing}>
            <i className="font-serif text-[18px]">I</i>
          </ToolButton>
          <ToolButton label="Heading" onClick={() => format("heading")} disabled={previewing}>
            <span className="text-[15px] font-bold">H</span>
          </ToolButton>
          <ToolButton label="Link" onClick={() => format("link")} disabled={previewing}>
            <svg viewBox="0 0 24 24" className="h-5 w-5" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round">
              <path d="M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1" />
            </svg>
          </ToolButton>
          <ToolButton label="List" onClick={() => format("list")} disabled={previewing}>
            <svg viewBox="0 0 24 24" className="h-5 w-5" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round">
              <path d="M9 6h11M9 12h11M9 18h11" />
              <circle cx="4.5" cy="6" r="1" fill="currentColor" />
              <circle cx="4.5" cy="12" r="1" fill="currentColor" />
              <circle cx="4.5" cy="18" r="1" fill="currentColor" />
            </svg>
          </ToolButton>
          <ToolButton label="Quote" onClick={() => format("quote")} disabled={previewing}>
            <span className="font-serif text-[22px] leading-none">❝</span>
          </ToolButton>
          <ToolButton label="Code" onClick={() => format("code")} disabled={previewing}>
            <span className="font-mono text-[13px] font-semibold">{"</>"}</span>
          </ToolButton>
          <span className="flex-1" />
          <button
            type="button"
            onClick={() => setPreviewing((value) => !value)}
            className="shrink-0 rounded-full px-3 py-1.5 text-sm font-semibold"
            style={previewing ? { background: palette.accent, color: "white" } : { color: palette.accent }}
            aria-pressed={previewing}
          >
            {previewing ? "Edit" : "Preview"}
          </button>
        </div>
      </div>

      {leaving ? (
        <LeaveSheet
          editing={Boolean(editing)}
          onKeep={() => {
            setLeaving(false);
            goBack();
          }}
          onDiscard={discard}
          onStay={() => setLeaving(false)}
        />
      ) : null}
    </div>
  );
}

function ToolButton({
  label,
  onClick,
  disabled,
  accent,
  children,
}: {
  label: string;
  onClick: () => void;
  disabled?: boolean;
  accent?: string;
  children: ReactNode;
}) {
  return (
    <button
      type="button"
      aria-label={label}
      title={label}
      // Keeps the text field focused and its selection where it was.
      onMouseDown={(event) => event.preventDefault()}
      onClick={onClick}
      disabled={disabled}
      className="flex h-10 min-w-10 shrink-0 items-center justify-center gap-1 rounded-lg px-2 text-slate-700 hover:bg-slate-100 disabled:opacity-35"
      style={accent ? { color: accent } : undefined}
    >
      {children}
    </button>
  );
}

/**
 * The post's photos as thumbnails, in carousel order, arranged by dragging
 * with dnd-kit, as the want list is (wiki/decisions.md). With a mouse a drag
 * starts at once; on a touch screen after a press and hold, so a swipe that
 * starts on a photo still scrolls the page. The arrow keys move a focused one.
 */
function PhotoGrid({
  photos,
  onRemove,
  onRetry,
  onMove,
}: {
  photos: Photo[];
  onRemove: (photo: Photo) => void;
  onRetry: (photo: Photo) => void;
  onMove: (from: number, to: number) => void;
}) {
  const sensors = useSensors(
    useSensor(MouseSensor, { activationConstraint: { distance: 4 } }),
    useSensor(TouchSensor, { activationConstraint: { delay: 250, tolerance: 8 } }),
    useSensor(KeyboardSensor, { coordinateGetter: sortableKeyboardCoordinates })
  );

  function onDragEnd({ active, over }: DragEndEvent) {
    if (!over || active.id === over.id) return;
    const from = photos.findIndex((photo) => photo.id === active.id);
    const to = photos.findIndex((photo) => photo.id === over.id);
    if (from !== -1 && to !== -1) onMove(from, to);
  }

  return (
    <DndContext sensors={sensors} collisionDetection={closestCenter} onDragEnd={onDragEnd}>
      <SortableContext items={photos.map((photo) => photo.id)} strategy={rectSortingStrategy}>
        <div className="mt-5 grid grid-cols-3 gap-2 sm:grid-cols-5">
          {photos.map((photo, index) => (
            <Thumbnail key={photo.id} photo={photo} cover={index === 0} onRemove={onRemove} onRetry={onRetry} />
          ))}
          {photos.length > 1 ? (
            <p className="col-span-full text-xs text-slate-500">The first photo is the cover. Hold and drag to reorder.</p>
          ) : null}
        </div>
      </SortableContext>
    </DndContext>
  );
}

function Thumbnail({
  photo,
  cover,
  onRemove,
  onRetry,
}: {
  photo: Photo;
  cover: boolean;
  onRemove: (photo: Photo) => void;
  onRetry: (photo: Photo) => void;
}) {
  const { attributes, listeners, setNodeRef, transform, transition, isDragging } = useSortable({ id: photo.id });
  return (
    <div
      ref={setNodeRef}
      {...attributes}
      {...listeners}
      aria-label={`${cover ? "Cover photo" : "Photo"}, drag to reorder`}
      onContextMenu={(event) => event.preventDefault()}
      style={{ transform: CSS.Translate.toString(transform), transition }}
      className={`relative aspect-square touch-manipulation select-none overflow-hidden rounded-xl bg-slate-100 [-webkit-touch-callout:none] ${
        isDragging ? "z-10 cursor-grabbing shadow-lg ring-2 ring-slate-900/20" : "cursor-grab"
      }`}
    >
      {photo.preview ? <img src={photo.preview} alt="" draggable={false} className="h-full w-full object-cover" /> : null}
      {photo.status === "queued" || photo.status === "uploading" ? (
        <div className="absolute inset-0 animate-pulse bg-white/50" aria-label="Uploading" />
      ) : null}
      {photo.status === "failed" ? (
        <button
          type="button"
          onPointerDown={(event) => event.stopPropagation()}
          onClick={() => onRetry(photo)}
          className="absolute inset-0 flex flex-col items-center justify-center gap-1 bg-rose-900/60 p-2 text-center text-xs font-medium text-white"
        >
          <span className="text-lg leading-none">↻</span>
          {photo.error || "Couldn't upload"}
        </button>
      ) : null}
      {cover ? (
        <span className="pointer-events-none absolute bottom-1.5 left-1.5 rounded-full bg-black/60 px-2 py-0.5 text-[11px] font-semibold text-white">
          Cover
        </span>
      ) : null}
      <button
        type="button"
        // Not a drag: the remove button is its own press.
        onPointerDown={(event) => event.stopPropagation()}
        onMouseDown={(event) => event.stopPropagation()}
        onTouchStart={(event) => event.stopPropagation()}
        onKeyDown={(event) => event.stopPropagation()}
        onClick={() => onRemove(photo)}
        aria-label="Remove photo"
        className="absolute right-1.5 top-1.5 flex h-7 w-7 items-center justify-center rounded-full bg-black/60 text-white"
      >
        <svg viewBox="0 0 24 24" className="h-4 w-4" fill="none" stroke="currentColor" strokeWidth="2.6" strokeLinecap="round">
          <path d="M6 6l12 12M18 6L6 18" />
        </svg>
      </button>
    </div>
  );
}

function LeaveSheet({
  editing,
  onKeep,
  onDiscard,
  onStay,
}: {
  editing: boolean;
  onKeep: () => void;
  onDiscard: () => void;
  onStay: () => void;
}) {
  return createPortal(
    <div className="fixed inset-0 z-50 flex items-end justify-center sm:items-center" role="dialog" aria-modal aria-label="Leave this post?">
      <button type="button" aria-label="Keep writing" onClick={onStay} className="absolute inset-0 bg-slate-900/40" />
      <div className="relative w-full max-w-md rounded-t-3xl bg-white p-5 shadow-xl sm:rounded-3xl" style={{ paddingBottom: "max(env(safe-area-inset-bottom), 20px)" }}>
        <h2 className="text-lg font-semibold text-slate-900">{editing ? "Discard your changes?" : "Keep this as a draft?"}</h2>
        <p className="mt-1 text-sm text-slate-500">
          {editing ? "The post stays as it was." : "It'll be here next time you start a post, on this device."}
        </p>
        <div className="mt-4 flex flex-col gap-2">
          {editing ? null : (
            <button type="button" onClick={onKeep} className="rounded-xl bg-slate-900 py-3 text-[15px] font-semibold text-white">
              Keep draft
            </button>
          )}
          <button type="button" onClick={onDiscard} className="rounded-xl bg-rose-50 py-3 text-[15px] font-semibold text-rose-700">
            {editing ? "Discard changes" : "Discard"}
          </button>
          <button type="button" onClick={onStay} className="rounded-xl py-3 text-[15px] font-medium text-slate-600">
            Keep writing
          </button>
        </div>
      </div>
    </div>,
    document.body
  );
}
