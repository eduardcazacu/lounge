import axios from "axios"
import { Appbar } from "../components/Appbar"
import { BACKEND_URL } from "../config"
import { ChangeEvent, useEffect, useState } from "react"
import { useNavigate } from "react-router-dom"
import { clearAuthStorage, getAuthHeader, isAuthErrorStatus } from "../lib/auth"
import { getTransformedImageUrl } from "../lib/content"
import { encodeFileToWebp, loadImageDimensions } from "../lib/image";

const MAX_IMAGE_WIDTH = 1920;
const MAX_IMAGE_HEIGHT = 1080;
const MAX_UPLOAD_BYTES = 3 * 1024 * 1024;
const TARGET_NON_GIF_BYTES = 2_400_000;
const POST_DRAFT_STORAGE_KEY = "publishPostDraft";

export const Publish = () => {
    const [title, setTitle] = useState("");
    const [description, setDescription] = useState("");
    const [draftLoaded, setDraftLoaded] = useState(false);
    const [imageKey, setImageKey] = useState<string | null>(null);
    const [imageUrl, setImageUrl] = useState<string | null>(null);
    const [imageName, setImageName] = useState<string | null>(null);
    const [uploadingImage, setUploadingImage] = useState(false);
    const [imageError, setImageError] = useState<string | null>(null);
    const navigate = useNavigate()

    useEffect(() => {
      const rawDraft = localStorage.getItem(POST_DRAFT_STORAGE_KEY);
      if (!rawDraft) {
        setDraftLoaded(true);
        return;
      }
      try {
        const parsed = JSON.parse(rawDraft) as { title?: unknown; description?: unknown };
        if (typeof parsed.title === "string") {
          setTitle(parsed.title);
        }
        if (typeof parsed.description === "string") {
          setDescription(parsed.description);
        }
      } catch {
        localStorage.removeItem(POST_DRAFT_STORAGE_KEY);
      } finally {
        setDraftLoaded(true);
      }
    }, []);

    useEffect(() => {
      if (!draftLoaded) {
        return;
      }
      if (!title.trim() && !description.trim()) {
        localStorage.removeItem(POST_DRAFT_STORAGE_KEY);
        return;
      }
      localStorage.setItem(
        POST_DRAFT_STORAGE_KEY,
        JSON.stringify({
          title,
          description,
        })
      );
    }, [draftLoaded, title, description]);

    async function resizeImageFile(file: File) {
      if (file.type === "image/gif") {
        // Re-encoding through a canvas would drop the animation, so GIFs pass
        // through untouched and are simply rejected when they are too big.
        const { width, height } = await loadImageDimensions(file);
        if (width > MAX_IMAGE_WIDTH || height > MAX_IMAGE_HEIGHT) {
          throw new Error("GIF is larger than 1920x1080. Please upload a smaller GIF.");
        }
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

    async function uploadImage(file: File) {
      if (!file.type.startsWith("image/")) {
        setImageError("Please upload an image file.");
        return;
      }
      setImageError(null);
      setUploadingImage(true);
      try {
        const optimizedFile = await resizeImageFile(file);
        if (optimizedFile.size > MAX_UPLOAD_BYTES) {
          throw new Error("Image is still too large after optimization (max 3MB). Use a smaller file.");
        }

        const formData = new FormData();
        formData.append("image", optimizedFile);
        const response = await axios.post(`${BACKEND_URL}/api/v1/blog/upload-image`, formData, {
          headers: {
            Authorization: getAuthHeader(),
          },
        });

        setImageKey(response.data?.key || null);
        setImageUrl(response.data?.url || null);
        setImageName(optimizedFile.name);
      } catch (e) {
        if (axios.isAxiosError(e) && isAuthErrorStatus(e.response?.status)) {
          clearAuthStorage();
          navigate("/signin", { replace: true });
          return;
        }
        setImageError(
          axios.isAxiosError(e)
            ? e.response?.data?.msg || "Failed to upload image."
            : e instanceof Error
              ? e.message
              : "Failed to upload image."
        );
      } finally {
        setUploadingImage(false);
      }
    }

  return (
    <div><Appbar />
        <div className="flex justify-center w-full px-4 pt-6 sm:px-6 sm:pt-8">
            <div className="max-w-screen-lg w-full rounded-xl border border-slate-200 bg-white p-4 sm:p-6">
                {/* <label className="block mb-2 text-sm font-medium text-gray-900 dark:text-white">Title</label> */}
                <input value={title} onChange={(e) => {
                    setTitle(e.target.value)
                }} type="text" className="bg-gray-50 border border-gray-300 text-gray-900 text-sm rounded-lg focus:ring-blue-500 focus:border-blue-500 block w-full p-2.5  dark:bg-gray-700 dark:border-gray-600 dark:placeholder-gray-400 dark:text-white dark:focus:ring-blue-500 dark:focus:border-blue-500" placeholder="Your Title">
                </input>

                <div className="mt-4 rounded-lg border border-slate-200 p-3 sm:p-4">
                  <div className="text-sm font-medium text-slate-800">Post image (1 max)</div>
                  <div className="mt-2 text-xs text-slate-500">JPG, PNG, WEBP, or GIF. Max stored size: 1920x1080. Max upload: 3MB.</div>
                  <input
                    type="file"
                    accept="image/jpeg,image/png,image/webp,image/gif"
                    className="mt-3 block w-full text-sm text-slate-700 file:mr-3 file:rounded-md file:border-0 file:bg-slate-900 file:px-3 file:py-2 file:text-sm file:font-medium file:text-white"
                    onChange={(e) => {
                      const selected = e.target.files?.[0];
                      if (selected) {
                        void uploadImage(selected);
                      }
                    }}
                  />
                  {uploadingImage ? <div className="mt-2 text-sm text-slate-600">Uploading image...</div> : null}
                  {imageError ? <div className="mt-2 text-sm text-red-600">{imageError}</div> : null}
                  {imageKey && imageUrl ? (
                    <div className="mt-3 rounded-lg border border-slate-200 p-2">
                      <img
                        src={getTransformedImageUrl(imageUrl, { width: 1200, fit: "contain", quality: 98 })}
                        alt={title || "Uploaded post image"}
                        className="h-auto max-h-72 w-full rounded-md bg-slate-100 object-contain"
                        loading="lazy"
                      />
                      <div className="mt-2 text-xs text-slate-500">{imageName || "Image uploaded"}</div>
                    </div>
                  ) : null}
                </div>

                <TextEditor value={description} onChange={(e) => {
                  setDescription(e.target.value)
                }} />
                <button onClick={async () => {
                    try {
                        const response = await axios.post(`${BACKEND_URL}/api/v1/blog`, {
                            title,
                            content: description,
                            imageKey: imageKey || undefined
                            
                        }, {
                            headers: {
                                Authorization: getAuthHeader()
                            }
                        });
                        localStorage.removeItem(POST_DRAFT_STORAGE_KEY);
                        setTitle("");
                        setDescription("");
                        navigate(`/blog/${response.data.id}`)
                    } catch (e) {
                        if (axios.isAxiosError(e) && isAuthErrorStatus(e.response?.status)) {
                            clearAuthStorage();
                            navigate("/signin", { replace: true });
                            return;
                        }
                        alert(axios.isAxiosError(e) ? e.response?.data?.msg || "Failed to publish post" : "Failed to publish post");
                    }
                    }} disabled={uploadingImage} type="submit" className="mt-4 inline-flex items-center px-3 py-2.5 text-sm font-medium text-center text-white bg-blue-700 rounded-lg focus:ring-4 focus:ring-blue-200 hover:bg-blue-800 disabled:cursor-not-allowed disabled:opacity-60">
                    Publish post
                </button> 
            </div>   

     </div>
    </div>
  )
}

function TextEditor({ value, onChange }: { value: string; onChange: (e: ChangeEvent<HTMLTextAreaElement>) => void}){
    return(
<div className="mt-8">
   <div className="w-full mb-4">
       <div className="flex items-center justify-between px-3 py-2 border">
       
        <div className="my-2 bg-white rounded-b-lg w-full">
            <label  className="sr-only">Publish post</label>
            <textarea value={value} onChange={onChange} id="editor" rows={8} className="block w-full px-0 text-sm focus-outline-none text-gray-800 bg-white border-0  " placeholder="Write a post..." required ></textarea>
        </div>
   </div>
   
   </div>
</div>
    )
}
