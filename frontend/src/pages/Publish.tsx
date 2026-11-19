import { Navigate, useSearchParams } from "react-router-dom";
import { PostEditor } from "../components/PostEditor";
import { useBlog } from "../hooks";
import { getCurrentUserId } from "../lib/auth";

// A new post, or with `?edit=<id>` one of your own. Either way the editor is
// its own full-screen page, without the app bar or the Lounge's bottom bar:
// Cancel and Post are the only ways off it.
export const Publish = () => {
  const [params] = useSearchParams();
  const editId = params.get("edit");
  return editId ? <EditPost id={editId} /> : <PostEditor />;
};

function EditPost({ id }: { id: string }) {
  const { blog, commentsPending, authExpired } = useBlog({ id });
  if (authExpired) return <Navigate to="/signin" replace />;
  // The feed's copy of a post is enough to show it, but only the post's own
  // fetch is certain to carry each photo's key.
  if (!blog || commentsPending) return <div className="min-h-dvh bg-white" />;
  // Someone else's post, or a review or ask from Books, which is edited there.
  if (blog.author.id !== getCurrentUserId() || blog.shelfReview || blog.shelfAsk) {
    return <Navigate to={`/blog/${id}`} replace />;
  }
  return (
    <PostEditor
      key={blog.id}
      editing={{
        id: blog.id,
        title: blog.title,
        content: blog.content,
        images: (blog.images ?? [])
          .filter((image) => image.key)
          .map((image) => ({ key: image.key!, url: image.url, width: image.width, height: image.height })),
      }}
    />
  );
}
