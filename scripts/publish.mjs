#!/usr/bin/env node
// Upkan Sideload publisher — uploads an .ipa (and its store listing) to sideload.upkan.id.
// No dependencies, Node 18+.
//
//   SIDELOAD_KEY=upk_xxx node publish.mjs MyApp.ipa \
//     [--changelog "Perbaikan bug"] [--changelog-file CHANGES.md] \
//     [--metadata app.json] [--icon icon.png] \
//     [--screenshots shots/iphone] [--ipad-screenshots shots/ipad] \
//     [--replace] [--url https://sideload.upkan.id]
//
// Update only the listing (metadata, icon, screenshots) of an existing app, without an IPA:
//
//   SIDELOAD_KEY=upk_xxx node publish.mjs --bundle-id com.example.myapp --screenshots shots/iphone
//
// app.json may contain: name, subtitle, description, developerName, category,
// websiteUrl, sourceCodeUrl, tintColor.
//
// SIDELOAD_KEY and SIDELOAD_URL are also read from the nearest .env, searched from the current
// directory up to the repository root (variables already set in the environment win), so the
// script can live in scripts/ and be run from anywhere in the project.
//
// --screenshots / --ipad-screenshots take a folder (images sorted by file name)
// or a file, and can be repeated. The app's set for that device becomes exactly
// these images in this order: unchanged images are kept, missing ones are
// uploaded, and the rest are removed. Max 10 per device, PNG/JPEG/WebP ≤ 8 MB.

import { createHash } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { open, readdir, readFile, stat } from "node:fs/promises";
import { basename, dirname, extname, join } from "node:path";
import { parseArgs } from "node:util";

const { values, positionals } = parseArgs({
  allowPositionals: true,
  options: {
    changelog: { type: "string" },
    "changelog-file": { type: "string" },
    metadata: { type: "string" },
    icon: { type: "string" },
    screenshots: { type: "string", multiple: true },
    "ipad-screenshots": { type: "string", multiple: true },
    "bundle-id": { type: "string" },
    replace: { type: "boolean", default: false },
    url: { type: "string" },
    key: { type: "string" },
    help: { type: "boolean", short: "h" },
  },
});

const usage = `Usage:
  SIDELOAD_KEY=upk_… node publish.mjs <file.ipa> [options]
  SIDELOAD_KEY=upk_… node publish.mjs --bundle-id <id> [--metadata app.json] [--icon icon.png] [--screenshots dir]

Options:
  --changelog <text>            Release notes for this version
  --changelog-file <path>       Read release notes from a file
  --metadata <app.json>         name, subtitle, description, category, websiteUrl, …
  --icon <icon.png>             PNG/JPEG/WebP, max 2 MB
  --screenshots <dir|file>      iPhone screenshots (repeatable; folders sorted by name)
  --ipad-screenshots <dir|file> iPad screenshots (repeatable)
  --bundle-id <id>              Update an existing app's listing without uploading an IPA
  --replace                     Admin only: overwrite an approved version+build
  --url <origin>                Server (default https://sideload.upkan.id)`;

const file = positionals[0];
const bundleIdOnly = values["bundle-id"];
if (values.help || positionals.length > 1 || (!file && !bundleIdOnly) || (file && bundleIdOnly)) {
  console.log(usage);
  process.exit(values.help ? 0 : 1);
}

if (bundleIdOnly && !values.metadata && !values.icon && !values.screenshots && !values["ipad-screenshots"]) {
  console.error("--bundle-id needs at least one of --metadata, --icon, --screenshots, --ipad-screenshots.");
  process.exit(1);
}

loadDotEnv(findDotEnv());

const base = (values.url ?? process.env.SIDELOAD_URL ?? "https://sideload.upkan.id").replace(/\/+$/, "");
const key = values.key ?? process.env.SIDELOAD_KEY;
if (!key) {
  console.error("Missing API key: set SIDELOAD_KEY (environment or .env) or pass --key.");
  process.exit(1);
}

const auth = { Authorization: `Bearer ${key}` };

async function api(method, path, body, headers = {}) {
  for (let attempt = 1; ; attempt++) {
    try {
      const res = await fetch(base + path, { method, body, headers: { ...auth, ...headers } });
      const text = await res.text();
      let json;
      try {
        json = JSON.parse(text);
      } catch {
        json = { error: text.slice(0, 300) };
      }
      if (res.ok) return json;
      // Client errors are final; retry server/network errors.
      if (res.status < 500 || attempt >= 3) throw Object.assign(new Error(json.error ?? res.statusText), { final: true });
    } catch (error) {
      if (error.final || attempt >= 3) throw error;
    }
    await new Promise((r) => setTimeout(r, attempt * 2000));
  }
}

const jsonHeaders = { "Content-Type": "application/json" };
const fmt = (n) => `${(n / 1024 / 1024).toFixed(1)} MB`;
const IMAGE_TYPES = { ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".webp": "image/webp" };
const appPath = (bundleId) => `/api/v1/apps/${encodeURIComponent(bundleId)}`;

/** Expands folders into their images, sorted naturally by file name (2.png before 10.png). */
async function collectImages(inputs) {
  const files = [];
  for (const input of inputs) {
    if ((await stat(input)).isDirectory()) {
      const names = (await readdir(input))
        .filter((n) => !n.startsWith(".") && IMAGE_TYPES[extname(n).toLowerCase()])
        .sort((a, b) => a.localeCompare(b, undefined, { numeric: true }));
      files.push(...names.map((n) => join(input, n)));
    } else {
      if (!IMAGE_TYPES[extname(input).toLowerCase()]) throw new Error(`${input}: screenshot harus .png, .jpg, atau .webp`);
      files.push(input);
    }
  }
  return files;
}

async function uploadIpa() {
  const { size } = await stat(file);
  let changelog = values.changelog ?? null;
  if (values["changelog-file"]) changelog = await readFile(values["changelog-file"], "utf8");
  const app = values.metadata ? JSON.parse(await readFile(values.metadata, "utf8")) : undefined;

  console.log(`→ ${basename(file)} (${fmt(size)}) → ${base}`);
  const upload = await api("POST", "/api/v1/uploads", JSON.stringify({ fileName: basename(file), size }), jsonHeaders);

  const handle = await open(file, "r");
  const parts = [];
  try {
    for (let n = 1; n <= upload.partCount; n++) {
      const offset = (n - 1) * upload.partSize;
      const length = Math.min(upload.partSize, size - offset);
      const buffer = Buffer.alloc(length);
      await handle.read(buffer, 0, length, offset);
      const part = await api("PUT", `/api/v1/uploads/${upload.id}/parts/${n}`, buffer, {
        "Content-Type": "application/octet-stream",
      });
      parts.push(part);
      console.log(`  part ${n}/${upload.partCount} ✓ (${fmt(offset + length)})`);
    }
  } catch (error) {
    await api("DELETE", `/api/v1/uploads/${upload.id}`).catch(() => {});
    throw error;
  } finally {
    await handle.close();
  }

  const result = await api(
    "POST",
    `/api/v1/uploads/${upload.id}/complete`,
    JSON.stringify({ parts, changelog, app, replace: values.replace }),
    jsonHeaders,
  );
  console.log(
    `✓ ${result.created ? "Created" : "Updated"} ${result.app.name} ${result.version.version} (${result.version.build})`,
  );
  if (result.status === "pending") console.log("  Versi menunggu review admin sebelum tayang.");
  return result.app;
}

/** Makes the app's set for one device exactly `files`, in order, uploading only what changed. */
async function syncScreenshots(bundleId, device, files) {
  const label = device === "ipad" ? "iPad" : "iPhone";
  if (files.length > 10) throw new Error(`Maksimal 10 screenshot ${label}, ada ${files.length}.`);
  const images = await Promise.all(
    files.map(async (path) => {
      const bytes = await readFile(path);
      return { path, bytes, sha256: createHash("sha256").update(bytes).digest("hex") };
    }),
  );

  const { screenshots } = await api("GET", `${appPath(bundleId)}/screenshots`);
  const existing = new Map(screenshots[device].map((s) => [s.sha256, s]));
  const wanted = new Set(images.map((i) => i.sha256));

  // Remove what is no longer wanted first, so the 10-per-device limit has room for new uploads.
  const keep = screenshots[device].filter((s) => wanted.has(s.sha256)).map((s) => s.id);
  if (keep.length !== screenshots[device].length) {
    await api("PUT", `${appPath(bundleId)}/screenshots`, JSON.stringify({ device, ids: keep }), jsonHeaders);
  }

  const ids = [];
  let uploaded = 0;
  for (const image of images) {
    let shot = existing.get(image.sha256);
    if (!shot) {
      const res = await api("POST", `${appPath(bundleId)}/screenshots?device=${device}`, image.bytes, {
        "Content-Type": IMAGE_TYPES[extname(image.path).toLowerCase()],
      });
      shot = res.screenshot;
      existing.set(image.sha256, shot);
      uploaded++;
    }
    if (shot.status === "rejected") {
      console.warn(`  ! ${basename(image.path)} pernah ditolak${shot.reviewNote ? `: ${shot.reviewNote}` : ""}`);
    }
    if (!ids.includes(shot.id)) ids.push(shot.id);
  }

  await api("PUT", `${appPath(bundleId)}/screenshots`, JSON.stringify({ device, ids }), jsonHeaders);
  const pending = ids.filter((id) => [...existing.values()].find((s) => s.id === id)?.status === "pending").length;
  console.log(
    `  screenshot ${label} ✓ ${ids.length} total, ${uploaded} baru` + (pending ? ` (${pending} menunggu review)` : ""),
  );
}

try {
  const iphoneShots = values.screenshots ? await collectImages(values.screenshots) : null;
  const ipadShots = values["ipad-screenshots"] ? await collectImages(values["ipad-screenshots"]) : null;

  let app;
  if (file) {
    app = await uploadIpa();
  } else {
    console.log(`→ ${bundleIdOnly} → ${base}`);
    if (values.changelog || values["changelog-file"] || values.replace) {
      console.warn("  ! --changelog dan --replace hanya berlaku saat upload IPA, diabaikan.");
    }
    if (values.metadata) {
      const patch = JSON.parse(await readFile(values.metadata, "utf8"));
      app = (await api("PATCH", appPath(bundleIdOnly), JSON.stringify(patch), jsonHeaders)).app;
      console.log("  metadata ✓");
    } else {
      app = { bundleId: bundleIdOnly, pageUrl: null };
    }
  }

  if (values.icon) {
    await api("PUT", `${appPath(app.bundleId)}/icon`, await readFile(values.icon), {
      "Content-Type": IMAGE_TYPES[extname(values.icon).toLowerCase()] ?? "image/png",
    });
    console.log("  icon ✓");
  }
  if (iphoneShots) await syncScreenshots(app.bundleId, "iphone", iphoneShots);
  if (ipadShots) await syncScreenshots(app.bundleId, "ipad", ipadShots);

  if (app.pageUrl && app.latest) console.log(`  ${app.pageUrl}`);
} catch (error) {
  console.error(`✗ ${error.message}`);
  process.exit(1);
}

/** Nearest .env from the working directory upward, stopping at the repository root (.git). */
function findDotEnv() {
  let dir = process.cwd();
  for (;;) {
    const candidate = join(dir, ".env");
    if (existsSync(candidate)) return candidate;
    const parent = dirname(dir);
    if (existsSync(join(dir, ".git")) || parent === dir) return null;
    dir = parent;
  }
}

/** Minimal .env reader (Node 18 has no built-in one) for the SIDELOAD_* variables. */
function loadDotEnv(path) {
  if (!path) return;
  let text;
  try {
    text = readFileSync(path, "utf8");
  } catch {
    return;
  }
  for (const line of text.split(/\r?\n/)) {
    const match = line.match(/^\s*(?:export\s+)?(SIDELOAD_[A-Z_]+)\s*=\s*(.*?)\s*$/);
    if (!match || process.env[match[1]] !== undefined) continue;
    let value = match[2];
    const quoted = value.match(/^(['"])(.*)\1$/);
    value = quoted ? quoted[2] : value.replace(/\s+#.*$/, "");
    process.env[match[1]] = value;
  }
}
