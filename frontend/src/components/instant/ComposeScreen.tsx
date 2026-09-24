import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { InstantConversation, InstantDurationMode } from "@blogging-app/common";
import type { UserListItem } from "../../hooks";
import { SendToSheet } from "./SendToSheet";
import { CircleIconButton, Viewport, ViewportOverlay } from "./chrome";
import {
  IconClose,
  IconFilters,
  IconPencil,
  IconPeople,
  IconSend,
  IconText,
  IconTextBox,
  IconTrash,
  IconUndo,
} from "./icons";
import { applyFilter, filterName, FILTERS, type FilterId } from "./filters";
import {
  backingColor,
  captionBoxWidth,
  clampScale,
  drawnRotation,
  fontString,
  INKS,
  inkColor,
  MAX_CAPTION_LENGTH,
  metricsFor,
  normalizedRotation,
  placement,
  strokePath,
  strokeWidth,
  textSize,
  trimmedText,
  wrapLines,
  type Caption,
  type InkId,
  type Placement,
  type Stroke,
} from "./overlay";
import type { InstantDraft, InstantRecipient } from "./useOutbox";

// The edit surface, ported from `ios/Instant/Features/Compose/ComposeScreen.swift`
// and `ComposeModel.swift`: the photo sits in the same rounded 16:9 viewport the
// camera framed it in, the tools sit in a right-hand rail, and Send To is
// bottom-right.
//
// Everything the sender does is stored in fractions of the photo and applied
// once, at full resolution, in the outbox — so what is on screen and what goes
// on the wire are one transform at two sizes.

/// Big enough for the viewport on a dense screen, and no bigger. A library
/// photo can be 4000px on its long edge, and re-filtering that on every tap of
/// the strip is a hitch per tap for pixels no screen shows.
const PREVIEW_LONG_EDGE = 1440;
const THUMBNAIL_LONG_EDGE = 180;

const DURATIONS: InstantDurationMode[] = ["1s", "5s", "infinite"];

function durationLabel(mode: InstantDurationMode): string {
  return mode === "infinite" ? "∞" : mode;
}

type Rect = { x: number; y: number; width: number; height: number };

export function ComposeScreen({
  image,
  aimedAt,
  onDiscard,
  onSend,
  users,
  usersLoading,
  history,
  currentUserId,
}: {
  image: HTMLImageElement;
  aimedAt: InstantRecipient | null;
  onDiscard: () => void;
  onSend: (draft: InstantDraft, recipients: InstantRecipient[]) => void;
  users: UserListItem[];
  usersLoading: boolean;
  history: InstantConversation[];
  currentUserId: number | null;
}) {
  const [captions, setCaptions] = useState<Caption[]>([]);
  const [strokes, setStrokes] = useState<Stroke[]>([]);
  const [ink, setInk] = useState<InkId>("white");
  const [duration, setDuration] = useState<InstantDurationMode>("5s");
  // Film, as on the phone: the look every capture starts in.
  const [filter, setFilter] = useState<FilterId>("film");
  const [showsFilters, setShowsFilters] = useState(false);
  const [thumbnails, setThumbnails] = useState<{ id: FilterId; url: string }[]>([]);
  const [isDrawing, setIsDrawing] = useState(false);
  const [editingId, setEditingId] = useState<string | null>(null);
  const [draggingId, setDraggingId] = useState<string | null>(null);
  const [overTrash, setOverTrash] = useState(false);
  const [showsRecipients, setShowsRecipients] = useState(false);
  const [previewUrl, setPreviewUrl] = useState<string | null>(null);

  const frameRef = useRef<HTMLDivElement | null>(null);
  /// The caption being typed into, so the style button can hand the caret back
  /// after it has swapped the style — on a touch screen the tap takes the
  /// keyboard away whatever the button does about focus.
  const editorRef = useRef<HTMLTextAreaElement>(null);
  const [frame, setFrame] = useState<Rect>({ x: 0, y: 0, width: 0, height: 0 });

  // --- the photo -----------------------------------------------------------

  /// The unfiltered photo at display size, which every preview render starts
  /// from, so switching looks never compounds one on top of another.
  const base = useMemo(() => {
    const longest = Math.max(image.naturalWidth, image.naturalHeight);
    const scale = longest > PREVIEW_LONG_EDGE ? PREVIEW_LONG_EDGE / longest : 1;
    const canvas = document.createElement("canvas");
    canvas.width = Math.max(1, Math.round(image.naturalWidth * scale));
    canvas.height = Math.max(1, Math.round(image.naturalHeight * scale));
    canvas.getContext("2d")?.drawImage(image, 0, 0, canvas.width, canvas.height);
    return canvas;
  }, [image]);

  useEffect(() => {
    const rendered =
      filter === "none" ? base : applyFilter(base, base.width, base.height, filter);
    let url: string | null = null;
    let cancelled = false;
    rendered.toBlob((blob) => {
      if (!blob) {
        return;
      }
      url = URL.createObjectURL(blob);
      if (cancelled) {
        // The look changed while this one was encoding; nothing will ever draw
        // it, so it is only a leak.
        URL.revokeObjectURL(url);
        return;
      }
      setPreviewUrl((previous) => {
        if (previous) {
          URL.revokeObjectURL(previous);
        }
        return url;
      });
    });
    return () => {
      cancelled = true;
    };
  }, [base, filter]);

  /// Built when the strip is first opened rather than on every capture: seven
  /// renders is a visible pause, and it would be spent on a control most
  /// photos never touch.
  const prepareThumbnails = useCallback(() => {
    if (thumbnails.length > 0) {
      return;
    }
    const scale = THUMBNAIL_LONG_EDGE / Math.max(base.width, base.height);
    const width = Math.max(1, Math.round(base.width * scale));
    const height = Math.max(1, Math.round(base.height * scale));
    const swatch = document.createElement("canvas");
    swatch.width = width;
    swatch.height = height;
    swatch.getContext("2d")?.drawImage(base, 0, 0, width, height);
    setThumbnails(
      FILTERS.map(({ id }) => ({
        id,
        url: applyFilter(swatch, width, height, id).toDataURL("image/jpeg", 0.8),
      }))
    );
  }, [base, thumbnails.length]);

  // Where a `contain`-fitted photo actually lands inside the viewport.
  // Anchoring a caption to the container instead puts it somewhere different
  // once the photo is letterboxed, so what the sender framed is not what
  // arrives.
  useEffect(() => {
    const node = frameRef.current;
    if (!node) {
      return;
    }
    const measure = () => {
      const box = node.getBoundingClientRect();
      const scale = Math.min(box.width / image.naturalWidth, box.height / image.naturalHeight);
      const width = image.naturalWidth * scale;
      const height = image.naturalHeight * scale;
      setFrame({
        x: (box.width - width) / 2,
        y: (box.height - height) / 2,
        width,
        height,
      });
    };
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(node);
    return () => observer.disconnect();
  }, [image]);

  // --- captions ------------------------------------------------------------

  const caption = useCallback(
    (id: string | null) => captions.find((item) => item.id === id) ?? null,
    [captions]
  );

  const update = useCallback((id: string, change: (caption: Caption) => Caption) => {
    setCaptions((current) => current.map((item) => (item.id === id ? change(item) : item)));
  }, []);

  const addCaption = useCallback((at: Placement) => {
    const created: Caption = {
      id: crypto.randomUUID(),
      text: "",
      // Starts as the bar, which has no horizontal position to speak of, so
      // only the height of the tap that made it matters until it becomes a
      // plate.
      style: "bar",
      placement: at,
      scale: 1,
      rotation: 0,
    };
    setCaptions((current) => [...current, created]);
    setEditingId(created.id);
  }, []);

  /// A caption left blank is removed rather than kept as an invisible thing
  /// that can still be tapped.
  ///
  /// Both updaters are pure and neither is nested in the other: StrictMode
  /// double-invokes an updater, and one that reaches out to set other state
  /// runs its side effect twice. See wiki/gotchas.md.
  const finishEditing = useCallback(() => {
    const closing = editingId;
    setEditingId(null);
    if (closing) {
      setCaptions((all) => all.filter((item) => item.id !== closing || trimmedText(item)));
    }
  }, [editingId]);

  const pointFraction = useCallback(
    (clientX: number, clientY: number) => {
      const box = frameRef.current?.getBoundingClientRect();
      if (!box || frame.width === 0) {
        return { x: 0.5, y: 0.5 };
      }
      return {
        x: (clientX - box.left - frame.x) / frame.width,
        y: (clientY - box.top - frame.y) / frame.height,
      };
    },
    [frame]
  );

  // --- gestures on the photo ----------------------------------------------

  const pointers = useRef(new Map<number, { x: number; y: number }>());
  const twoFinger = useRef<{
    id: string;
    distance: number;
    angle: number;
    scale: number;
    rotation: number;
  } | null>(null);
  const tapCandidate = useRef<{ x: number; y: number } | null>(null);
  /// Where the pointer went down for the line being drawn. A new start is a new
  /// line; leaving it to pointerup alone means a cancelled touch joins the next
  /// line onto the last.
  const drawingPointer = useRef<number | null>(null);

  const captionBoxes = useRef(new Map<string, Rect>());

  const plateNear = useCallback(
    (x: number, y: number) => {
      const box = frameRef.current?.getBoundingClientRect();
      if (!box) {
        return null;
      }
      const localX = x - box.left;
      const localY = y - box.top;
      // The topmost plate under the pinch, with a finger's width of slack: a
      // small caption is narrower than two fingers held apart.
      return (
        [...captions]
          .reverse()
          .find((item) => {
            if (item.style !== "plate" || item.id === editingId) {
              return false;
            }
            const rect = captionBoxes.current.get(item.id);
            return (
              rect !== undefined &&
              localX >= rect.x - 44 &&
              localX <= rect.x + rect.width + 44 &&
              localY >= rect.y - 44 &&
              localY <= rect.y + rect.height + 44
            );
          }) ?? null
      );
    },
    [captions, editingId]
  );

  const photoPointerDown = (event: React.PointerEvent) => {
    if (editingId) {
      return;
    }
    (event.target as Element).setPointerCapture?.(event.pointerId);
    pointers.current.set(event.pointerId, { x: event.clientX, y: event.clientY });

    if (isDrawing) {
      if (drawingPointer.current === null) {
        drawingPointer.current = event.pointerId;
        const point = pointFraction(event.clientX, event.clientY);
        setStrokes((current) => [
          ...current,
          { id: crypto.randomUUID(), ink, points: [point] },
        ]);
      }
      return;
    }

    const points = [...pointers.current.values()];
    if (points.length === 2) {
      tapCandidate.current = null;
      const target = plateNear(
        (points[0].x + points[1].x) / 2,
        (points[0].y + points[1].y) / 2
      );
      if (target) {
        twoFinger.current = {
          id: target.id,
          distance: Math.hypot(points[0].x - points[1].x, points[0].y - points[1].y),
          angle: Math.atan2(points[1].y - points[0].y, points[1].x - points[0].x),
          scale: target.scale,
          rotation: target.rotation,
        };
      }
      return;
    }
    tapCandidate.current = { x: event.clientX, y: event.clientY };
  };

  const photoPointerMove = (event: React.PointerEvent) => {
    if (!pointers.current.has(event.pointerId)) {
      return;
    }
    pointers.current.set(event.pointerId, { x: event.clientX, y: event.clientY });

    if (isDrawing && drawingPointer.current === event.pointerId) {
      const point = pointFraction(event.clientX, event.clientY);
      setStrokes((current) => {
        if (current.length === 0) {
          return current;
        }
        const last = current[current.length - 1];
        return [...current.slice(0, -1), { ...last, points: [...last.points, point] }];
      });
      return;
    }

    const points = [...pointers.current.values()];
    const holding = twoFinger.current;
    if (points.length === 2 && holding) {
      const distance = Math.hypot(points[0].x - points[1].x, points[0].y - points[1].y);
      const angle = Math.atan2(points[1].y - points[0].y, points[1].x - points[0].x);
      update(holding.id, (item) => ({
        ...item,
        // Pinch and turn are one gesture here but two values, so a pinch that
        // never turns far enough to count as a turn still scales.
        scale: clampScale(holding.scale * (distance / holding.distance)),
        rotation: normalizedRotation(holding.rotation + (angle - holding.angle)),
      }));
      return;
    }
    if (tapCandidate.current) {
      const moved =
        Math.abs(event.clientX - tapCandidate.current.x) +
        Math.abs(event.clientY - tapCandidate.current.y);
      if (moved > 8) {
        tapCandidate.current = null;
      }
    }
  };

  const photoPointerUp = (event: React.PointerEvent) => {
    pointers.current.delete(event.pointerId);
    if (drawingPointer.current === event.pointerId) {
      drawingPointer.current = null;
    }
    if (pointers.current.size < 2) {
      twoFinger.current = null;
    }
    if (isDrawing || !tapCandidate.current) {
      return;
    }
    // Anywhere that is not already a caption starts a new one.
    const point = pointFraction(tapCandidate.current.x, tapCandidate.current.y);
    tapCandidate.current = null;
    addCaption(placement(point.x, point.y));
  };

  // --- dragging a caption --------------------------------------------------

  const dragOrigin = useRef<{ placement: Placement; x: number; y: number } | null>(null);
  const trashRef = useRef<HTMLDivElement | null>(null);

  const captionPointerDown = (event: React.PointerEvent, item: Caption) => {
    if (isDrawing || editingId) {
      return;
    }
    event.stopPropagation();
    (event.target as Element).setPointerCapture?.(event.pointerId);
    dragOrigin.current = { placement: item.placement, x: event.clientX, y: event.clientY };
  };

  const captionPointerMove = (event: React.PointerEvent, item: Caption) => {
    const origin = dragOrigin.current;
    if (!origin || frame.width === 0) {
      return;
    }
    event.stopPropagation();
    const dx = event.clientX - origin.x;
    const dy = event.clientY - origin.y;
    if (!draggingId && Math.abs(dx) + Math.abs(dy) < 4) {
      return;
    }
    setDraggingId(item.id);
    const trash = trashRef.current?.getBoundingClientRect();
    setOverTrash(
      trash !== undefined &&
        event.clientX > trash.left - 16 &&
        event.clientX < trash.right + 16 &&
        event.clientY > trash.top - 16 &&
        event.clientY < trash.bottom + 16
    );
    // A bar keeps its horizontal centre, because it has none on screen: were it
    // to take the finger's, it would jump sideways the moment it became a plate.
    const next = placement(
      origin.placement.x + dx / frame.width,
      origin.placement.y + dy / frame.height
    );
    update(item.id, (current) => ({
      ...current,
      placement:
        current.style === "bar"
          ? { x: current.placement.x, y: next.y }
          : next,
    }));
  };

  const captionPointerUp = (event: React.PointerEvent, item: Caption) => {
    event.stopPropagation();
    const wasDragging = draggingId === item.id;
    if (wasDragging && overTrash) {
      setCaptions((current) => current.filter((candidate) => candidate.id !== item.id));
    } else if (!wasDragging) {
      setEditingId(item.id);
    }
    dragOrigin.current = null;
    setDraggingId(null);
    setOverTrash(false);
  };

  // --- the drawing layer ---------------------------------------------------

  const drawingRef = useRef<HTMLCanvasElement | null>(null);
  useEffect(() => {
    const canvas = drawingRef.current;
    const context = canvas?.getContext("2d");
    if (!canvas || !context || frame.width === 0) {
      return;
    }
    // Backed at device resolution so a line is not soft on a retina screen.
    const ratio = window.devicePixelRatio || 1;
    canvas.width = Math.round(frame.width * ratio);
    canvas.height = Math.round(frame.height * ratio);
    context.scale(ratio, ratio);
    context.clearRect(0, 0, frame.width, frame.height);
    context.lineWidth = strokeWidth(frame.width);
    context.lineCap = "round";
    context.lineJoin = "round";
    for (const stroke of strokes) {
      context.strokeStyle = inkColor(stroke.ink);
      context.stroke(strokePath(stroke, frame.width, frame.height));
    }
  }, [strokes, frame]);

  // --- sending -------------------------------------------------------------

  const draft = useCallback(
    (): InstantDraft => ({
      image,
      filter,
      strokes,
      captions: captions.filter((item) => trimmedText(item)),
      duration,
    }),
    [captions, duration, filter, image, strokes]
  );

  const send = (recipients: InstantRecipient[]) => {
    if (recipients.length > 0) {
      onSend(draft(), recipients);
    }
  };

  const editing = caption(editingId);
  const hidesChrome = editingId !== null || draggingId !== null || isDrawing;

  return (
    <div className="absolute inset-0">
      <Viewport className="bg-black">
        <div
          ref={frameRef}
          // Nothing here is text to be selected, and every gesture on it is a
          // drag: without this, drawing a line paints the browser's selection
          // highlight over the photo as it goes.
          className="absolute inset-0 touch-none select-none"
          // A finger held on a photo is iOS Safari's cue to offer Save Image,
          // and holding still is exactly what drawing a dot looks like.
          style={{ WebkitTouchCallout: "none" }}
          onPointerDown={photoPointerDown}
          onPointerMove={photoPointerMove}
          onPointerUp={photoPointerUp}
          onPointerCancel={photoPointerUp}
        >
          {previewUrl && (
            <img
              src={previewUrl}
              alt="The photo you just took"
              draggable={false}
              className="pointer-events-none h-full w-full object-contain"
            />
          )}

          {/* Under the captions, on screen and in the pixels, so a scribble
              cannot make text unreadable. */}
          <canvas
            ref={drawingRef}
            className="pointer-events-none absolute"
            style={{
              left: frame.x,
              top: frame.y,
              width: frame.width,
              height: frame.height,
            }}
          />

          {captions
            .filter((item) => item.id !== editingId && trimmedText(item))
            .map((item) => (
              <CaptionView
                key={item.id}
                caption={item}
                frame={frame}
                faded={draggingId === item.id && overTrash}
                interactive={!isDrawing && editingId === null}
                onBox={(rect) => captionBoxes.current.set(item.id, rect)}
                onPointerDown={(event) => captionPointerDown(event, item)}
                onPointerMove={(event) => captionPointerMove(event, item)}
                onPointerUp={(event) => captionPointerUp(event, item)}
              />
            ))}
        </div>

        {editing && (
          <CaptionEditor
            caption={editing}
            photoWidth={frame.width}
            inputRef={editorRef}
            onChange={(text) => update(editing.id, (item) => ({ ...item, text }))}
            onDone={finishEditing}
          />
        )}
      </Viewport>

      <ViewportOverlay>
        {draggingId ? (
          <div className="flex justify-center">
            <div
              ref={trashRef}
              className="flex h-[52px] w-[52px] items-center justify-center rounded-full transition"
              style={{
                background: overTrash ? "#fff" : "rgba(0,0,0,0.45)",
                color: overTrash ? "#000" : "#fff",
                transform: overTrash ? "scale(1.25)" : "scale(1)",
              }}
              aria-label="Delete text"
            >
              <IconTrash />
            </div>
          </div>
        ) : (
          <div className="flex items-start justify-between gap-3">
            {editingId === null && !isDrawing ? (
              <CircleIconButton label="Discard this photo" onClick={onDiscard} id="compose.discard">
                <IconClose />
              </CircleIconButton>
            ) : (
              <span />
            )}

            <div className="flex items-start gap-3">
              {isDrawing && (
                <CircleIconButton
                  label="Undo"
                  disabled={strokes.length === 0}
                  onClick={() => setStrokes((current) => current.slice(0, -1))}
                  id="compose.undo"
                >
                  <IconUndo />
                </CircleIconButton>
              )}

              <div className="flex flex-col items-end gap-3">
                {isDrawing ? (
                  <>
                    <CircleIconButton
                      label="Draw"
                      isOn
                      onClick={() => setIsDrawing(false)}
                      id="compose.draw"
                    >
                      <IconPencil />
                    </CircleIconButton>
                    {/* While drawing, the pencil is the only way out, so every
                        other tool steps aside and the colours take the rail. */}
                    <div className="pointer-events-auto flex flex-col items-center gap-1.5 rounded-full bg-black/35 px-2.5 py-2">
                      {INKS.map((option) => (
                        <button
                          key={option.id}
                          type="button"
                          aria-label={option.id}
                          aria-pressed={ink === option.id}
                          onClick={() => setInk(option.id)}
                          className="flex h-[30px] w-6 items-center justify-center"
                        >
                          <span
                            className="h-6 w-6 rounded-full border-white transition"
                            style={{
                              background: option.color,
                              // White and black each vanish against half of all
                              // photos, so every swatch carries a ring.
                              borderWidth: ink === option.id ? 3 : 1.5,
                              transform: ink === option.id ? "scale(1.25)" : "scale(1)",
                            }}
                          />
                        </button>
                      ))}
                    </div>
                  </>
                ) : (
                  <>
                    <CircleIconButton
                      // A different glyph while typing, because it is a
                      // different button: the one that adds text is not the one
                      // that restyles it.
                      label={editing ? "Text style" : "Add text"}
                      isOn={editing?.style === "plate"}
                      preventsBlur
                      onClick={() => {
                        if (editing) {
                          update(editing.id, (item) => ({
                            ...item,
                            style: item.style === "bar" ? "plate" : "bar",
                          }));
                          editorRef.current?.focus();
                        } else {
                          addCaption({ x: 0.5, y: 0.5 });
                        }
                      }}
                      id="compose.caption"
                    >
                      {editing ? <IconTextBox /> : <IconText />}
                    </CircleIconButton>

                    {editingId === null && (
                      <>
                        <CircleIconButton
                          label={`Filters, ${filterName(filter)}`}
                          isOn={showsFilters}
                          onClick={() => {
                            if (!showsFilters) {
                              prepareThumbnails();
                            }
                            setShowsFilters((current) => !current);
                          }}
                          id="compose.filters"
                        >
                          <IconFilters />
                        </CircleIconButton>
                        <CircleIconButton
                          label="Draw"
                          onClick={() => setIsDrawing(true)}
                          id="compose.draw"
                        >
                          <IconPencil />
                        </CircleIconButton>
                        <button
                          type="button"
                          onClick={() =>
                            setDuration(
                              (current) =>
                                DURATIONS[(DURATIONS.indexOf(current) + 1) % DURATIONS.length]
                            )
                          }
                          aria-label={`Visible for ${duration}`}
                          data-testid="compose.duration"
                          className="pointer-events-auto flex h-11 w-11 items-center justify-center rounded-full bg-black/35 text-[17px] font-bold text-white"
                        >
                          {durationLabel(duration)}
                        </button>
                      </>
                    )}
                  </>
                )}
              </div>
            </div>
          </div>
        )}

        <div className="flex-1" />

        {!hidesChrome && (
          <>
            {showsFilters && (
              <div className="pointer-events-auto mb-3.5 flex gap-2.5 overflow-x-auto pb-1">
                {thumbnails.map((thumbnail) => {
                  const selected = filter === thumbnail.id;
                  return (
                    <button
                      key={thumbnail.id}
                      type="button"
                      onClick={() => setFilter(thumbnail.id)}
                      aria-pressed={selected}
                      className="flex shrink-0 flex-col items-center gap-1.5 drop-shadow"
                      data-testid={`compose.filter.${thumbnail.id}`}
                    >
                      <img
                        src={thumbnail.url}
                        alt=""
                        draggable={false}
                        className="h-[58px] w-[58px] rounded-xl object-cover"
                        style={{
                          outline: selected ? "2.5px solid #fff" : "1px solid rgba(255,255,255,0.25)",
                          outlineOffset: -1,
                        }}
                      />
                      <span
                        className={`text-[11px] ${selected ? "font-bold text-white" : "font-medium text-neutral-300"}`}
                      >
                        {filterName(thumbnail.id)}
                      </span>
                    </button>
                  );
                })}
              </div>
            )}

            <div className="flex items-center justify-end gap-2.5">
              {/* An aimed capture still has to be redirectable: the only other
                  way out of a wrong recipient would be discarding the photo. */}
              {aimedAt && (
                <CircleIconButton
                  label="Send to somebody else"
                  onClick={() => setShowsRecipients(true)}
                  id="compose.changeRecipient"
                >
                  <IconPeople />
                </CircleIconButton>
              )}
              <button
                type="button"
                onClick={() => {
                  if (aimedAt) {
                    send([aimedAt]);
                  } else {
                    setShowsRecipients(true);
                  }
                }}
                data-testid="compose.sendTo"
                className="pointer-events-auto flex h-12 items-center gap-2 rounded-full bg-white px-5 text-base font-bold text-black"
              >
                {aimedAt ? `Send to ${aimedAt.name}` : "Send To"}
                <IconSend size={16} />
              </button>
            </div>
          </>
        )}
      </ViewportOverlay>

      {showsRecipients && (
        <SendToSheet
          users={users}
          usersLoading={usersLoading}
          history={history}
          currentUserId={currentUserId}
          initialSelection={aimedAt ? [aimedAt.userId] : []}
          onClose={() => setShowsRecipients(false)}
          onSend={(recipients) => {
            setShowsRecipients(false);
            send(recipients);
          }}
        />
      )}
    </div>
  );
}

/// A caption on the photo, drawn from the same measurements the compositor
/// burns in — including the line breaks, which come from `wrapLines` rather
/// than from the browser, so the preview cannot wrap differently from the file.
function CaptionView({
  caption,
  frame,
  faded,
  interactive,
  onBox,
  onPointerDown,
  onPointerMove,
  onPointerUp,
}: {
  caption: Caption;
  frame: Rect;
  faded: boolean;
  interactive: boolean;
  onBox: (rect: Rect) => void;
  onPointerDown: (event: React.PointerEvent) => void;
  onPointerMove: (event: React.PointerEvent) => void;
  onPointerUp: (event: React.PointerEvent) => void;
}) {
  const ref = useRef<HTMLDivElement | null>(null);
  const text = trimmedText(caption);
  const metrics = metricsFor(caption.style, caption.scale, frame.width);
  const size = textSize(text, metrics);
  const lines = wrapLines(text, metrics);

  useEffect(() => {
    const node = ref.current;
    const container = node?.offsetParent as HTMLElement | null;
    if (!node || !container) {
      return;
    }
    const box = node.getBoundingClientRect();
    const parent = container.getBoundingClientRect();
    onBox({
      x: box.left - parent.left,
      y: box.top - parent.top,
      width: box.width,
      height: box.height,
    });
  });

  return (
    <div
      ref={ref}
      onPointerDown={onPointerDown}
      onPointerMove={onPointerMove}
      onPointerUp={onPointerUp}
      onPointerCancel={onPointerUp}
      className={`absolute select-none text-center text-white ${
        interactive ? "touch-none" : "pointer-events-none"
      }`}
      style={{
        left: caption.style === "bar" ? frame.x : frame.x + frame.width * caption.placement.x,
        top: frame.y + frame.height * caption.placement.y,
        width: captionBoxWidth(caption.style, metrics, size.width, frame.width),
        padding: `${metrics.verticalPadding}px ${metrics.horizontalPadding}px`,
        background: backingColor(caption.style),
        borderRadius: metrics.cornerRadius,
        font: fontString(metrics),
        lineHeight: `${metrics.lineHeight}px`,
        opacity: faded ? 0.4 : 1,
        transform: `translate(${caption.style === "bar" ? 0 : -50}%, -50%) rotate(${drawnRotation(caption)}rad)`,
        transformOrigin: "center",
      }}
    >
      {lines.map((line, index) => (
        <div key={index} className="whitespace-pre">
          {line}
        </div>
      ))}
    </div>
  );
}

/// The caption itself, typed into in place over a dimmed photo, with the same
/// font, the same wrap width and the same backing as the one on the photo — so
/// swapping the style mid-sentence shows exactly what the swap does.
function CaptionEditor({
  caption,
  photoWidth,
  inputRef,
  onChange,
  onDone,
}: {
  caption: Caption;
  photoWidth: number;
  inputRef: React.RefObject<HTMLTextAreaElement>;
  onChange: (text: string) => void;
  onDone: () => void;
}) {
  const metrics = metricsFor(caption.style, caption.scale, Math.max(photoWidth, 1));
  const measured = textSize(caption.text || "Add a caption", metrics);
  /// The line count comes from the wrap itself, not from dividing the measured
  /// height back down by the line height: `textSize` rounds that height up to a
  /// whole pixel, and a single line of 28.8px comes back as 29, which divides
  /// to 1.007 and rounds up to a second empty row under the text.
  const rows = Math.max(1, wrapLines(caption.text || "Add a caption", metrics).length);

  useEffect(() => {
    inputRef.current?.focus();
  }, [inputRef]);

  return (
    <div
      // No z-index: `ViewportOverlay` is a later sibling, so the rail paints
      // over this — which is the whole point. The text button restyles the
      // caption being typed, and a dim layer above it swallows that click.
      className="absolute inset-0 flex items-center justify-center bg-black/35"
      onPointerDown={(event) => {
        if (event.target === event.currentTarget) {
          onDone();
        }
      }}
    >
      <textarea
        ref={inputRef}
        value={caption.text}
        maxLength={MAX_CAPTION_LENGTH}
        placeholder="Add a caption"
        rows={rows}
        onChange={(event) => onChange(event.target.value)}
        onKeyDown={(event) => {
          // A caption is one paragraph that wraps, so Return means done.
          if (event.key === "Enter") {
            event.preventDefault();
            onDone();
          }
          if (event.key === "Escape") {
            onDone();
          }
        }}
        data-testid="compose.captionField"
        className="resize-none overflow-hidden text-center text-white placeholder:text-neutral-400 focus:outline-none"
        style={{
          // The box the caption will be drawn at, padding included —
          // `box-sizing: border-box` is on everything, so this is the same
          // number the preview and the compositor use.
          width: captionBoxWidth(
            caption.style,
            metrics,
            measured.width,
            photoWidth,
            metrics.fontSize * 0.2
          ),
          padding: `${metrics.verticalPadding}px ${metrics.horizontalPadding}px`,
          background: backingColor(caption.style),
          borderRadius: metrics.cornerRadius,
          font: fontString(metrics),
          lineHeight: `${metrics.lineHeight}px`,
          caretColor: "#fff",
        }}
      />
    </div>
  );
}
