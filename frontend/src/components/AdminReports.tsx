import { useEffect, useState } from "react";
import axios from "axios";
import { BACKEND_URL } from "../config";
import { getAuthHeader } from "../lib/auth";

type ReportUser = {
  id: number;
  name: string | null;
  email: string;
  status: string;
} | null;

type Report = {
  id: number;
  instantId: string | null;
  reason: string;
  details: string | null;
  hasEvidence: boolean;
  status: "open" | "resolved";
  resolution: "dismissed" | "suspended" | null;
  createdAt: string;
  resolvedAt: string | null;
  reporter: ReportUser;
  reportedUser: ReportUser;
};

function describe(user: ReportUser) {
  if (!user) return "Deleted account";
  return `${user.name?.trim() || "Unnamed"} <${user.email}>`;
}

// Reports from the Instant app. Guideline 1.2 promises people a response within
// 24 hours, so open reports are listed first with how long they have waited.
export const AdminReports = ({ onAuthError }: { onAuthError: () => void }) => {
  const [reports, setReports] = useState<Report[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [busyId, setBusyId] = useState<number | null>(null);
  // Evidence is streamed through the authenticated API, so it is fetched as a
  // blob and shown from an object URL rather than linked directly.
  const [evidenceUrls, setEvidenceUrls] = useState<Record<number, string>>({});

  function handleError(e: unknown, fallback: string) {
    if (axios.isAxiosError(e)) {
      if (e.response?.status === 401 || e.response?.status === 403) {
        onAuthError();
        return;
      }
      setError(e.response?.data?.msg || fallback);
    } else {
      setError(fallback);
    }
  }

  async function load() {
    setLoading(true);
    setError(null);
    try {
      const response = await axios.get(`${BACKEND_URL}/api/v1/admin/reports`, {
        headers: { Authorization: getAuthHeader() },
      });
      setReports(response.data?.reports ?? []);
    } catch (e) {
      handleError(e, "Failed to load reports");
    } finally {
      setLoading(false);
    }
  }

  async function showEvidence(reportId: number) {
    try {
      const response = await axios.get(`${BACKEND_URL}/api/v1/admin/reports/${reportId}/evidence`, {
        headers: { Authorization: getAuthHeader() },
        responseType: "blob",
      });
      const url = URL.createObjectURL(response.data as Blob);
      setEvidenceUrls((current) => ({ ...current, [reportId]: url }));
    } catch (e) {
      handleError(e, "Failed to load the attached photo");
    }
  }

  async function resolve(report: Report, action: "dismiss" | "suspend") {
    if (
      action === "suspend" &&
      !window.confirm(`Suspend ${describe(report.reportedUser)}? They will be signed out and unable to sign in.`)
    ) {
      return;
    }
    setBusyId(report.id);
    try {
      await axios.put(
        `${BACKEND_URL}/api/v1/admin/reports/${report.id}/resolve`,
        { action },
        { headers: { Authorization: getAuthHeader() } }
      );
      const url = evidenceUrls[report.id];
      if (url) {
        URL.revokeObjectURL(url);
        setEvidenceUrls((current) => {
          const next = { ...current };
          delete next[report.id];
          return next;
        });
      }
      await load();
    } catch (e) {
      handleError(e, "Failed to resolve the report");
    } finally {
      setBusyId(null);
    }
  }

  useEffect(() => {
    void load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useEffect(
    () => () => Object.values(evidenceUrls).forEach((url) => URL.revokeObjectURL(url)),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    []
  );

  const open = reports.filter((report) => report.status === "open");
  const resolved = reports.filter((report) => report.status === "resolved");

  return (
    <div className="mt-6 rounded-lg border border-slate-200 bg-slate-50 p-4 sm:p-5">
      <div className="flex items-center justify-between gap-3">
        <div>
          <div className="text-lg font-semibold text-slate-900">
            Reports {open.length > 0 ? <span className="ml-1 rounded-full bg-red-600 px-2 py-0.5 text-xs text-white">{open.length} open</span> : null}
          </div>
          <p className="mt-1 text-sm text-slate-600">
            Reported people and photos from the Instant app. Respond within 24 hours. A suspended account is
            signed out and can no longer sign in. Attached photos are deleted when a report is resolved.
          </p>
        </div>
        <button
          type="button"
          onClick={() => void load()}
          className="shrink-0 rounded-full border border-slate-300 px-4 py-2 text-sm font-medium text-slate-700 hover:bg-slate-100"
        >
          Refresh
        </button>
      </div>

      {loading ? <p className="mt-3 text-sm text-slate-600">Loading reports...</p> : null}
      {error ? <p className="mt-3 text-sm text-red-600">{error}</p> : null}
      {!loading && open.length === 0 ? <p className="mt-3 text-sm text-slate-600">No open reports.</p> : null}

      <div className="mt-4 grid gap-3">
        {open.map((report) => {
          const hoursWaiting = Math.floor((Date.now() - new Date(report.createdAt).getTime()) / 3_600_000);
          return (
            <div key={report.id} className="rounded-lg border border-slate-200 bg-white p-4">
              <div className="flex flex-wrap items-baseline justify-between gap-2">
                <div className="font-semibold text-slate-900">
                  #{report.id} · <span className="capitalize">{report.reason}</span>
                </div>
                <div className={`text-sm ${hoursWaiting >= 20 ? "font-semibold text-red-600" : "text-slate-500"}`}>
                  {new Date(report.createdAt).toLocaleString()} · waiting {hoursWaiting}h
                </div>
              </div>
              <div className="mt-2 text-sm text-slate-700">
                <div><span className="text-slate-500">Reported:</span> {describe(report.reportedUser)}{report.reportedUser?.status === "rejected" ? " (suspended)" : ""}</div>
                <div><span className="text-slate-500">By:</span> {describe(report.reporter)}</div>
                {report.details ? <div className="mt-1 whitespace-pre-wrap"><span className="text-slate-500">Details:</span> {report.details}</div> : null}
              </div>
              {report.hasEvidence ? (
                evidenceUrls[report.id] ? (
                  <img
                    src={evidenceUrls[report.id]}
                    alt={`Photo attached to report ${report.id}`}
                    className="mt-3 max-h-96 rounded-lg border border-slate-200"
                  />
                ) : (
                  <button
                    type="button"
                    onClick={() => void showEvidence(report.id)}
                    className="mt-3 text-sm font-medium text-slate-900 underline"
                  >
                    Show attached photo
                  </button>
                )
              ) : (
                <p className="mt-3 text-sm text-slate-500">No photo attached.</p>
              )}
              <div className="mt-4 flex flex-wrap gap-2">
                <button
                  type="button"
                  disabled={busyId === report.id || report.reportedUser === null}
                  onClick={() => void resolve(report, "suspend")}
                  className="rounded-full bg-red-600 px-4 py-2 text-sm font-medium text-white hover:bg-red-700 disabled:cursor-not-allowed disabled:opacity-60"
                >
                  Suspend account
                </button>
                <button
                  type="button"
                  disabled={busyId === report.id}
                  onClick={() => void resolve(report, "dismiss")}
                  className="rounded-full border border-slate-300 px-4 py-2 text-sm font-medium text-slate-700 hover:bg-slate-100 disabled:cursor-not-allowed disabled:opacity-60"
                >
                  Dismiss
                </button>
              </div>
            </div>
          );
        })}
      </div>

      {resolved.length > 0 ? (
        <details className="mt-4">
          <summary className="cursor-pointer text-sm font-medium text-slate-700">
            Resolved ({resolved.length})
          </summary>
          <ul className="mt-2 grid gap-1 text-sm text-slate-600">
            {resolved.map((report) => (
              <li key={report.id}>
                #{report.id} · <span className="capitalize">{report.reason}</span> · {describe(report.reportedUser)} ·{" "}
                {report.resolution} {report.resolvedAt ? `on ${new Date(report.resolvedAt).toLocaleDateString()}` : ""}
              </li>
            ))}
          </ul>
        </details>
      ) : null}
    </div>
  );
};
