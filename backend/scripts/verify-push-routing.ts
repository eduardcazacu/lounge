// Checks which Web Push rows an app-first notification still sends to.
//
//   cd backend && npx tsx scripts/verify-push-routing.ts
//
// An Instant push goes to the iOS app first, and to the browser only for
// someone Apple did not accept it for — otherwise the same person gets two
// banners for one photo. No database needed: the rule is a pure function.

import { webPushFallback } from "../src/push";

let failures = 0;
let checks = 0;

function check(label: string, ok: boolean, detail?: unknown) {
  checks += 1;
  if (ok) {
    console.log(`  ok   ${label}`);
  } else {
    failures += 1;
    console.log(`  FAIL ${label}${detail === undefined ? "" : ` -> ${JSON.stringify(detail)}`}`);
  }
}

const row = (id: number, userId: number, provider: string) => ({ id, userId, provider });
const ids = (rows: { id: number }[]) => rows.map((r) => r.id).sort((a, b) => a - b);

// User 1 has the app and a browser; user 2 has only a browser.
const subscriptions = [
  row(1, 1, "apns"),
  row(2, 1, "webpush"),
  row(3, 1, "webpush"),
  row(4, 2, "webpush"),
];

console.log("app-first routing");

const reached = webPushFallback(subscriptions, [{ subscriptionId: 1, success: true }]);
check("someone the app reached gets no browser push", ids(reached).every((id) => id === 4), ids(reached));
check("someone with only a browser still gets one", ids(reached).includes(4), ids(reached));

const deadToken = webPushFallback(subscriptions, [{ subscriptionId: 1, success: false }]);
check("a rejected APNs token falls back to every browser", ids(deadToken).join() === "2,3,4", ids(deadToken));

const crashed = webPushFallback(subscriptions, [{ subscriptionId: null, success: false }]);
check("a send that threw falls back too", ids(crashed).join() === "2,3,4", ids(crashed));

const sandbox = [row(5, 3, "apns-sandbox"), row(6, 3, "webpush")];
const debugBuild = webPushFallback(sandbox, [{ subscriptionId: 5, success: true }]);
check("a sandbox (Debug build) token counts as the app", debugBuild.length === 0, ids(debugBuild));

const twoPhones = [row(7, 4, "apns"), row(8, 4, "apns"), row(9, 4, "webpush")];
const onePhoneLive = webPushFallback(twoPhones, [
  { subscriptionId: 7, success: false },
  { subscriptionId: 8, success: true },
]);
check("one live device of several is enough", onePhoneLive.length === 0, ids(onePhoneLive));

const neverApns = webPushFallback(subscriptions, []);
check("never returns an APNs row", neverApns.every((r) => r.provider === "webpush"), neverApns);

console.log(`\n${checks - failures}/${checks} checks passed`);
process.exit(failures === 0 ? 0 : 1);
