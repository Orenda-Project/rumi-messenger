#!/usr/bin/env node
// bot-cross-sign.mjs -- give a bot account cross-signing keys and sign the bot's EXISTING device,
// so Element stops showing a red "encrypted by a device not verified by its owner" shield on its
// messages (rumi-messenger#15). Run through ../bot-cross-sign.sh, which installs deps if needed.
//
// Why out-of-band: the Rumi bot runs matrix-bot-sdk 0.8.0, which never calls bootstrapCrossSigning
// and whose RustEngine throws on SignatureUpload/KeysBackup requests. So instead of touching the
// bot process, this script logs in as the bot on a NEW temporary device with matrix-js-sdk (rust
// crypto, in-memory store), creates the cross-signing keys there, signs the bot's device with the
// self-signing key, stores the private keys in secret storage (4S) under a recovery key, and logs
// the temporary device out. The bot's own device, access token and .matrix-storage are never
// touched.
//
// Idempotent:
//   * master key on server and target device already signed by the self-signing key -> no-op.
//   * master key on server but device not signed (e.g. the bot got a new device) -> keys are read
//     back from 4S with the recovery key file, then the device is signed. Never re-creates keys.
//   * master key on server and no recovery key file -> refuses (re-creating keys would be an
//     identity reset, which teachers see as "Rumi's identity changed").
//   * no master key -> creates keys + 4S, writes the recovery key file (chmod 600) BEFORE upload.
//
// Usage: XSIGN_PASSWORD=... node bot-cross-sign.mjs --hs URL --user @x:server --device DEVICEID
//                                                   --recovery-key-file PATH
// (password comes from the environment so it never shows up in `ps`)
import { readFileSync, writeFileSync, existsSync, chmodSync } from "node:fs";
import * as sdk from "matrix-js-sdk";
import { decodeRecoveryKey } from "matrix-js-sdk/lib/crypto-api/recovery-key.js";

const arg = (n) => { const i = process.argv.indexOf(`--${n}`); return i > 0 ? process.argv[i + 1] : undefined; };
const HS = arg("hs"), USER = arg("user"), PASSWORD = process.env.XSIGN_PASSWORD;
const DEVICE = arg("device"), KEYFILE = arg("recovery-key-file");
if (!HS || !USER || !PASSWORD || !DEVICE || !KEYFILE) { console.error("missing args; see header"); process.exit(64); }
const log = (...a) => console.log("[bot-cross-sign]", ...a);

async function api(method, path, token, body) {
  const r = await fetch(HS + path, { method, headers: { "Content-Type": "application/json", ...(token ? { Authorization: `Bearer ${token}` } : {}) }, body: body ? JSON.stringify(body) : undefined });
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(`${method} ${path} -> HTTP ${r.status} ${JSON.stringify(j)}`);
  return j;
}

// Server-side truth: does USER have a master key, and is DEVICE signed by the self-signing key?
async function serverState(token) {
  const q = await api("POST", "/_matrix/client/v3/keys/query", token, { device_keys: { [USER]: [] } });
  const master = q.master_keys?.[USER], ssk = q.self_signing_keys?.[USER];
  const sskId = ssk && Object.keys(ssk.keys)[0];
  const dev = q.device_keys?.[USER]?.[DEVICE];
  return { master: !!master, sskId, deviceExists: !!dev, deviceSigned: !!(sskId && dev?.signatures?.[USER]?.[sskId]) };
}

const login = await api("POST", "/_matrix/client/v3/login", null, {
  type: "m.login.password", identifier: { type: "m.id.user", user: USER }, password: PASSWORD,
  initial_device_display_name: "bot-cross-sign (temporary, logged out after run)",
});
const tmpToken = login.access_token, tmpDevice = login.device_id;
log(`temporary device ${tmpDevice} logged in (target device ${DEVICE} untouched)`);
let client;
try {
  const before = await serverState(tmpToken);
  log("server state before:", JSON.stringify(before));
  if (!before.deviceExists) throw new Error(`device ${DEVICE} has no device keys on the server -- wrong device id?`);
  if (before.master && before.deviceSigned) { log("already cross-signed; nothing to do"); process.exitCode = 0; }
  else {
    if (before.master && !existsSync(KEYFILE))
      throw new Error(`${USER} already has cross-signing keys but ${KEYFILE} is missing; refusing to reset the identity`);
    let recoveryKey = existsSync(KEYFILE) ? readFileSync(KEYFILE, "utf8").trim() : null;
    let privKey = recoveryKey ? decodeRecoveryKey(recoveryKey) : null;
    client = sdk.createClient({
      baseUrl: HS, userId: USER, deviceId: tmpDevice, accessToken: tmpToken,
      logger: { ...console, debug() {}, trace() {}, info() {}, getChild() { return this; } },
      cryptoCallbacks: {
        getSecretStorageKey: async ({ keys }) => (privKey ? [Object.keys(keys)[0], privKey] : null),
        cacheSecretStorageKey: (_id, _info, k) => { privKey = k; },
      },
    });
    await client.initRustCrypto({ useIndexedDB: false });
    const crypto = client.getCrypto();
    // The rust crypto outgoing-request loop (device upload, /keys/query) only runs while syncing.
    // Sync with a filter that excludes every room, so this temp device never touches room history.
    const filter = new sdk.Filter(USER);
    filter.setDefinition({ room: { rooms: [] }, presence: { not_types: ["*"] }, account_data: { types: ["m.secret_storage.*", "m.cross_signing.*"] } });
    const synced = new Promise((r) => client.on(sdk.ClientEvent.Sync, (s) => s === "PREPARED" && r()));
    await client.startClient({ filter, initialSyncLimit: 0 });
    await synced;
    let known = false; // wait until our own device list (incl. DEVICE) has been downloaded
    for (let i = 0; i < 30 && !known; i++) {
      known = (await crypto.getUserDeviceInfo([USER], true)).get(USER)?.has(DEVICE) ?? false;
      if (!known) await new Promise((r) => setTimeout(r, 1000));
    }
    if (!known) throw new Error(`device ${DEVICE} never showed up in the local device list`);
    const auth = (makeRequest) => makeRequest({ type: "m.login.password", identifier: { type: "m.id.user", user: USER }, password: PASSWORD });
    if (!before.master) {
      log("no cross-signing keys yet: creating secret storage, then master/self-signing/user-signing keys");
      // 4S first, so the recovery key is on disk before any public key is published; the
      // cross-signing bootstrap below then exports the new private keys straight into 4S.
      await crypto.bootstrapSecretStorage({
        setupNewSecretStorage: true,
        createSecretStorageKey: async () => {
          const k = await crypto.createRecoveryKeyFromPassphrase();
          writeFileSync(KEYFILE, k.encodedPrivateKey + "\n", { mode: 0o600 }); chmodSync(KEYFILE, 0o600);
          privKey = k.privateKey;
          log(`recovery key written to ${KEYFILE} (chmod 600) -- back it up, it is the only copy`);
          return k;
        },
      });
      await crypto.bootstrapCrossSigning({ authUploadDeviceSigningKeys: auth });
      if (!(await crypto.isSecretStorageReady())) throw new Error("cross-signing keys were not exported to secret storage");
    } else {
      log("cross-signing keys exist: loading private keys from secret storage with the recovery key");
      if (!(await crypto.isSecretStorageReady())) throw new Error("secret storage not ready/unlockable with this recovery key; refusing");
      await crypto.bootstrapCrossSigning({}); // imports from 4S, never resets (guarded above)
    }
    const st = await crypto.getCrossSigningStatus();
    if (!st.privateKeysCachedLocally.selfSigningKey) throw new Error("self-signing private key not available; aborting before signing");
    await crypto.crossSignDevice(DEVICE);
    const after = await serverState(tmpToken);
    log("server state after:", JSON.stringify(after));
    if (!after.master || !after.deviceSigned) throw new Error("device signature not visible in /keys/query");
    log(`OK: ${DEVICE} is signed by ${after.sskId}`);
  }
} catch (e) {
  console.error("[bot-cross-sign] FAILED:", e.message); process.exitCode = 1;
} finally {
  try { client?.stopClient(); } catch {}
  await api("POST", "/_matrix/client/v3/logout", tmpToken, {}).then(() => log(`temporary device ${tmpDevice} logged out`), (e) => console.error("logout failed:", e.message));
  process.exit(process.exitCode ?? 0);
}
