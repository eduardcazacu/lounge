import { PostEditor } from "../components/PostEditor";

// A new post. The editor is its own full-screen page, without the app bar or
// the Lounge's bottom bar: Cancel and Post are the only ways off it.
export const Publish = () => <PostEditor />;
