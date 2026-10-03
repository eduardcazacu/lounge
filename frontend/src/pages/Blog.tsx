import { Navigate, useParams } from "react-router-dom";
import { useBlog } from "../hooks";
import { FullBlog } from "../components/FullBlog";
import { Appbar } from "../components/Appbar";
import { FullBlogSkeleton } from "../components/FullBlogSkeleton";

export const Blog = () => {
  const { id } = useParams();
  const { blog, commentsPending, authExpired } = useBlog({
    id: id || "",
  });

  if (authExpired) {
    return <Navigate to="/signin" replace />;
  }

  if (!blog) {
    return (
      <div className="min-h-screen bg-slate-100">
        <Appbar />
        <FullBlogSkeleton />
      </div>
    );
  }

  return (
    <div>
      <FullBlog blog={blog} commentsPending={commentsPending} />
    </div>
  );
};

export default Blog;
