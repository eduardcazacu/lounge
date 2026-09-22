// The glyphs, drawn rather than imported.
//
// The Lounge has no icon package and this is not the place to add one: these
// stand in for the SF Symbols the iOS screens use, and there are only as many
// as those screens actually name. Each takes its size and colour from the text
// it sits in, so a control can be sized in one place.

type IconProps = { size?: number; className?: string };

function Glyph({
  size = 20,
  className,
  children,
  fill = false,
}: IconProps & { children: React.ReactNode; fill?: boolean }) {
  return (
    <svg
      viewBox="0 0 24 24"
      width={size}
      height={size}
      className={className}
      fill={fill ? "currentColor" : "none"}
      stroke={fill ? "none" : "currentColor"}
      strokeWidth={2}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
    >
      {children}
    </svg>
  );
}

export const IconBolt = (props: IconProps) => (
  <Glyph {...props} fill>
    <path d="M13 2 4 14h6l-1 8 9-12h-6z" />
  </Glyph>
);

export const IconBoltOff = (props: IconProps) => (
  <Glyph {...props}>
    <path d="M13 2 4 14h6l-1 8 9-12h-6z" />
    <path d="M3 3l18 18" />
  </Glyph>
);

export const IconFlip = (props: IconProps) => (
  <Glyph {...props}>
    <path d="M4 8a8 8 0 0 1 13-3l2 2" />
    <path d="M19 4v4h-4" />
    <path d="M20 16a8 8 0 0 1-13 3l-2-2" />
    <path d="M5 20v-4h4" />
  </Glyph>
);

export const IconClose = (props: IconProps) => (
  <Glyph {...props}>
    <path d="M6 6l12 12M18 6L6 18" />
  </Glyph>
);

export const IconSend = (props: IconProps) => (
  <Glyph {...props} fill>
    <path d="M3 11.5 21 3l-8.5 18-2.2-7.3z" />
  </Glyph>
);

export const IconText = (props: IconProps) => (
  <Glyph {...props}>
    <path d="M4 6h16M9 6v13M15 6v13" />
  </Glyph>
);

export const IconTextBox = (props: IconProps) => (
  <Glyph {...props}>
    <rect x="3" y="6" width="18" height="12" rx="3" />
    <path d="M8 10h8M12 10v5" />
  </Glyph>
);

export const IconFilters = (props: IconProps) => (
  <Glyph {...props}>
    <circle cx="9" cy="9" r="6" />
    <circle cx="15" cy="15" r="6" />
  </Glyph>
);

export const IconPencil = (props: IconProps) => (
  <Glyph {...props}>
    <path d="M16 3.5 20.5 8 8 20.5 3 21l.5-5z" />
  </Glyph>
);

export const IconUndo = (props: IconProps) => (
  <Glyph {...props}>
    <path d="M4 8h10a5 5 0 0 1 0 10H8" />
    <path d="M4 8l4-4M4 8l4 4" />
  </Glyph>
);

export const IconTrash = (props: IconProps) => (
  <Glyph {...props}>
    <path d="M4 7h16M9 7V4h6v3M6 7l1 13h10l1-13" />
  </Glyph>
);

export const IconChat = (props: IconProps) => (
  <Glyph {...props} fill>
    <path d="M12 3c5 0 9 3.4 9 7.6s-4 7.6-9 7.6c-1 0-2-.1-2.9-.4L4 20l1.2-3.3C3.8 15.4 3 13.1 3 10.6 3 6.4 7 3 12 3z" />
  </Glyph>
);

export const IconCamera = (props: IconProps) => (
  <Glyph {...props} fill>
    <path d="M9 4h6l1.2 2H20a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h3.8z" />
    <circle cx="12" cy="12.5" r="3.6" fill="#000" />
  </Glyph>
);

export const IconChevron = (props: IconProps) => (
  <Glyph {...props}>
    <path d="M9 5l7 7-7 7" />
  </Glyph>
);

export const IconEye = (props: IconProps) => (
  <Glyph {...props} fill>
    <path d="M12 5c5 0 9 4.2 10 7-1 2.8-5 7-10 7S3 14.8 2 12c1-2.8 5-7 10-7zm0 3.5a3.5 3.5 0 1 0 0 7 3.5 3.5 0 0 0 0-7z" />
  </Glyph>
);

export const IconExpired = (props: IconProps) => (
  <Glyph {...props}>
    <circle cx="11" cy="12" r="8" />
    <path d="M11 7.5V12l3 2" />
    <path d="M17.5 17.5l4 4M21.5 17.5l-4 4" />
  </Glyph>
);

export const IconCheck = (props: IconProps) => (
  <Glyph {...props}>
    <path d="M4 12.5 9.5 18 20 6.5" />
  </Glyph>
);

export const IconWarning = (props: IconProps) => (
  <Glyph {...props} fill>
    <path d="M12 3 1.5 21h21zM12 9v6M12 17.5v.5" stroke="#000" strokeWidth={1.6} />
  </Glyph>
);

export const IconMore = (props: IconProps) => (
  <Glyph {...props} fill>
    <circle cx="5" cy="12" r="2" />
    <circle cx="12" cy="12" r="2" />
    <circle cx="19" cy="12" r="2" />
  </Glyph>
);

export const IconReply = (props: IconProps) => (
  <Glyph {...props} fill>
    <path d="M10 5 3 11l7 6v-3.5c5 0 8 1.5 9.5 4.5.3-6.5-3-10-9.5-10.5z" />
  </Glyph>
);

export const IconPeople = (props: IconProps) => (
  <Glyph {...props} fill>
    <circle cx="9" cy="8" r="3.6" />
    <circle cx="17" cy="9" r="2.8" />
    <path d="M2.5 19c.6-3.4 3.3-5.2 6.5-5.2s5.9 1.8 6.5 5.2z" />
    <path d="M17 13.2c2.3.1 4 1.6 4.5 4.3H18z" />
  </Glyph>
);

export const IconShield = (props: IconProps) => (
  <Glyph {...props}>
    <path d="M12 3l7 3v5.5c0 4.3-2.9 7.8-7 9.5-4.1-1.7-7-5.2-7-9.5V6z" />
    <path d="M9 12l2 2 4-4" />
  </Glyph>
);

export const IconFlag = (props: IconProps) => (
  <Glyph {...props}>
    <path d="M5 21V4M5 5h12l-2 4 2 4H5" />
  </Glyph>
);

export const IconBlock = (props: IconProps) => (
  <Glyph {...props}>
    <circle cx="12" cy="12" r="9" />
    <path d="M5.6 5.6l12.8 12.8" />
  </Glyph>
);

export const IconRefresh = (props: IconProps) => (
  <Glyph {...props}>
    <path d="M20 12a8 8 0 1 1-2.3-5.7" />
    <path d="M20 4v5h-5" />
  </Glyph>
);

export const IconPerson = (props: IconProps) => (
  <Glyph {...props} fill>
    <circle cx="12" cy="8" r="4" />
    <path d="M4 20c.7-4 3.9-6 8-6s7.3 2 8 6z" />
  </Glyph>
);

export const IconPhotos = (props: IconProps) => (
  <Glyph {...props}>
    <rect x="3" y="5" width="18" height="14" rx="3" />
    <path d="M3 16l5-4 4 3 3-2 6 4" />
  </Glyph>
);

// `speaker.slash.fill` and `speaker.wave.2.fill`, the viewer's sound button.
export const IconSoundOff = (props: IconProps) => (
  <Glyph {...props}>
    <path d="M11 5 6 9H3v6h3l5 4z" fill="currentColor" />
    <path d="m16 9 5 6M21 9l-5 6" />
  </Glyph>
);

export const IconSoundOn = (props: IconProps) => (
  <Glyph {...props}>
    <path d="M11 5 6 9H3v6h3l5 4z" fill="currentColor" />
    <path d="M15.5 8.5a5 5 0 0 1 0 7M18.5 5.5a9 9 0 0 1 0 13" />
  </Glyph>
);
