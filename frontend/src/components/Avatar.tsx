import { getThemePalette } from "../themes";
import { getTransformedImageUrl } from "../lib/content";

// Its own module, not BlogCard's: Books, the app bar and Account draw avatars,
// and importing one from BlogCard brought react-markdown along with it.
export function Avatar({ name, size = "small", themeKey, imageUrl }: { name: string, size: "small" | "big", themeKey?: string | null, imageUrl?: string | null }){
    const initial = name?.trim()?.[0]?.toUpperCase() || "?";
    const theme = getThemePalette(themeKey);
    const sizeClass = size === "small" ? "w-6 h-6" : "w-10 h-10";
    const transformedImageUrl = imageUrl
        ? getTransformedImageUrl(imageUrl, { width: size === "small" ? 96 : 160, fit: "cover", quality: 85 })
        : null;
    return <div className={`relative inline-flex items-center justify-center
    overflow-hidden rounded-full border ${sizeClass}`}
    style={{ backgroundColor: theme.softBg, borderColor: theme.border }}>
        {transformedImageUrl ? (
            <img
                src={transformedImageUrl}
                alt={name || "Profile picture"}
                loading="lazy"
                className="h-full w-full object-cover"
            />
        ) : (
            <span className={`${size === "small" ? "text-xs" : "text-md"} font-small`} style={{ color: theme.text }}>
                {initial}
            </span>
        )}
    </div>

}
