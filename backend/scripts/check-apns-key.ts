// Asks Apple directly whether an APNs key works, and in which environments.
//
//   cd backend
//   npx tsx scripts/check-apns-key.ts ~/Downloads/AuthKey_XXXXXXXXXX.p8 \
//     --key-id XXXXXXXXXX --team-id 844S7255R5 --bundle com.eduardcazacu.instant
//
// The key never leaves this machine: it is read locally, used to sign a token,
// and only the signed token goes to Apple.
//
// It pushes to a deliberately invalid device token, so nothing is delivered to
// anyone. What matters is *which* error comes back, because Apple's reasons
// separate the possible faults cleanly:
//
//   BadDeviceToken            the key and topic are accepted — this is success
//   BadEnvironmentKeyInToken  the key is not valid for that environment
//   InvalidProviderToken      wrong key id, team id, or key contents
//   TopicDisallowed           the key is restricted and does not cover the topic
//   DeviceTokenNotForTopic    the bundle id does not match

import { readFileSync } from "node:fs";
import {
  APNS_PRODUCTION_HOST,
  APNS_SANDBOX_HOST,
  resetApnsTokenCache,
  signProviderToken,
} from "../src/apns";

function arg(name: string): string | undefined {
  const index = process.argv.indexOf(`--${name}`);
  return index > 0 ? process.argv[index + 1] : undefined;
}

async function probe(host: string, label: string, token: string, bundleId: string) {
  // Syntactically valid, deliberately not a real device.
  const deviceToken = "0".repeat(64);
  const response = await fetch(`${host}/3/device/${deviceToken}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${token}`,
      "apns-topic": bundleId,
      "apns-push-type": "alert",
      "apns-priority": "10",
      "content-type": "application/json",
    },
    body: JSON.stringify({ aps: { alert: { title: "probe", body: "probe" } } }),
  });

  let reason = "(no body)";
  try {
    reason = ((await response.json()) as { reason?: string }).reason ?? "(no reason)";
  } catch {
    // Some proxies answer without a body.
  }

  const verdict =
    reason === "BadDeviceToken"
      ? "OK — key and topic accepted here"
      : reason === "BadEnvironmentKeyInToken"
        ? "the key is NOT valid for this environment"
        : reason === "InvalidProviderToken"
          ? "wrong key id, team id, or key contents"
          : reason === "TopicDisallowed" || reason === "DeviceTokenNotForTopic"
            ? "the topic (bundle id) is not accepted by this key"
            : "unexpected";

  console.log(`  ${label.padEnd(11)} ${String(response.status).padEnd(4)} ${reason.padEnd(26)} ${verdict}`);
  return reason;
}

async function main() {
  const path = process.argv[2];
  const keyId = arg("key-id");
  const teamId = arg("team-id");
  const bundleId = arg("bundle") ?? "com.eduardcazacu.instant";

  if (!path || !keyId || !teamId) {
    console.error("usage: check-apns-key.ts <AuthKey.p8> --key-id <id> --team-id <id> [--bundle <id>]");
    process.exit(2);
  }

  const privateKey = readFileSync(path, "utf8");
  console.log(`\nkey ${keyId}, team ${teamId}, topic ${bundleId}\n`);

  resetApnsTokenCache();
  let token: string;
  try {
    token = await signProviderToken({ keyId, teamId, privateKey, bundleId }, Math.floor(Date.now() / 1000));
  } catch (error) {
    console.error("Could not sign a token with that key:", error instanceof Error ? error.message : error);
    console.error("The file is probably not a PKCS#8 .p8, or is truncated.");
    process.exit(1);
  }

  console.log("  env         code reason                     verdict");
  const sandbox = await probe(APNS_SANDBOX_HOST, "sandbox", token, bundleId);
  const production = await probe(APNS_PRODUCTION_HOST, "production", token, bundleId);

  console.log("");
  if (sandbox === "BadDeviceToken" && production === "BadDeviceToken") {
    console.log("This key works in both environments. The fault is elsewhere.");
  } else if (sandbox === "BadEnvironmentKeyInToken" && production === "BadDeviceToken") {
    console.log("This key is production-only. A development build's token can only be");
    console.log("delivered through sandbox, so this key cannot reach it. Create a key");
    console.log("enabled for Sandbox & Production, or test from TestFlight instead.");
  } else if (production === "BadEnvironmentKeyInToken" && sandbox === "BadDeviceToken") {
    console.log("This key is sandbox-only. Fine for development builds; it will not");
    console.log("work for TestFlight or the App Store.");
  } else {
    console.log("Neither environment accepted the key — check the Key ID and Team ID");
    console.log("against the key in the developer portal.");
  }
}

void main();
