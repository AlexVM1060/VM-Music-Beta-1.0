const express = require("express");
const cors = require("cors");
const fs = require("node:fs");
const fsp = require("node:fs/promises");
const os = require("node:os");
const path = require("node:path");
const crypto = require("node:crypto");
const { spawn } = require("node:child_process");
const { Readable, pipeline } = require("node:stream");

const app = express();
app.set("trust proxy", true);

const PORT = Number(process.env.PORT || 10000);
const API_KEY = (process.env.RESOLVER_API_KEY || "").trim();
const RESOLVE_CACHE_TTL_MS = Number(
  process.env.RESOLVE_CACHE_TTL_MS || 30 * 1000
);
const RESOLVE_BATCH_LIMIT = Number(process.env.RESOLVE_BATCH_LIMIT || 20);
const CORS_ALLOW_ORIGINS = (process.env.CORS_ALLOW_ORIGINS || "").trim();
const STEMS_ROOT = path.resolve(
  process.env.STEMS_ROOT || path.join(os.tmpdir(), "vmmusic-stems")
);
const STEMS_MODEL = (process.env.STEMS_MODEL || "htdemucs_ft").trim();
const STEMS_PYTHON = (process.env.STEMS_PYTHON || "python3").trim();
const STEMS_TIMEOUT_MS = Number(process.env.STEMS_TIMEOUT_MS || 12 * 60 * 1000);
const STEMS_CACHE_TTL_MS = Number(
  process.env.STEMS_CACHE_TTL_MS || 30 * 1000
);
const DART_BINARY = (process.env.DART_BINARY || "dart").trim();
const YTEXPLODE_DART_TIMEOUT_MS = Number(
  process.env.YTEXPLODE_DART_TIMEOUT_MS || 30 * 1000
);
const COVER_ANIMATION_PROXY_URL = (
  process.env.COVER_ANIMATION_PROXY_URL || ""
).trim();
const COVER_ANIMATION_PROXY_KEY = (
  process.env.COVER_ANIMATION_PROXY_KEY || ""
).trim();
const COVER_ANIMATION_TIMEOUT_MS = Number(
  process.env.COVER_ANIMATION_TIMEOUT_MS || 90 * 1000
);
const startedAt = new Date();
const resolveCache = new Map();
const YTEXPLODE_DART_ROOT = path.resolve(__dirname, "dart_resolver");
const YTEXPLODE_DART_SCRIPT = path.join(
  YTEXPLODE_DART_ROOT,
  "bin",
  "yt_resolve.dart"
);
const YTEXPLODE_DART_SEARCH_SCRIPT = path.join(
  YTEXPLODE_DART_ROOT,
  "bin",
  "yt_search.dart"
);
// eslint-disable-next-line no-console
console.info(
  `[resolver] startup youtubeExplodeDartScript=${fs.existsSync(
    YTEXPLODE_DART_SCRIPT
  )} resolveCacheTtlMs=${RESOLVE_CACHE_TTL_MS}`
);

const allowedOrigins = CORS_ALLOW_ORIGINS
  ? CORS_ALLOW_ORIGINS.split(",")
      .map((value) => value.trim())
      .filter(Boolean)
  : [];

app.use(
  cors({
    origin(origin, callback) {
      if (!origin || allowedOrigins.length === 0 || allowedOrigins.includes(origin)) {
        return callback(null, true);
      }
      return callback(new Error("cors_not_allowed"));
    },
  })
);
app.use(express.json({ limit: "2mb" }));
app.use("/stems-files", express.static(STEMS_ROOT));

function authMiddleware(req, res, next) {
  if (!API_KEY) return next();
  const incoming = (req.header("x-api-key") || "").trim();
  if (incoming !== API_KEY) {
    return res.status(401).json({ ok: false, error: "unauthorized" });
  }
  return next();
}

function isValidVideoId(videoId) {
  return /^[a-zA-Z0-9_-]{11}$/.test(String(videoId || "").trim());
}

async function runYoutubeExplodeDart(videoId) {
  if (!fs.existsSync(YTEXPLODE_DART_SCRIPT)) {
    const err = new Error("youtube_explode_dart_script_missing");
    err.code = "youtube_explode_dart_script_missing";
    throw err;
  }
  return await new Promise((resolve, reject) => {
    const args = [
      "--disable-analytics",
      "run",
      "bin/yt_resolve.dart",
      "--video-id",
      videoId,
    ];
    const child = spawn(DART_BINARY, args, {
      cwd: YTEXPLODE_DART_ROOT,
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      const err = new Error("youtube_explode_dart_timeout");
      err.code = "youtube_explode_dart_timeout";
      reject(err);
    }, YTEXPLODE_DART_TIMEOUT_MS);

    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString("utf8");
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString("utf8");
    });
    child.on("error", (err) => {
      clearTimeout(timer);
      reject(err);
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      const lines = String(stdout || "")
        .trim()
        .split(/\r?\n/)
        .map((line) => line.trim())
        .filter(Boolean);
      const raw = lines.length ? lines[lines.length - 1] : "";
      if (code !== 0) {
        reject(
          new Error(
            `youtube_explode_dart_failed_${code}: ${
              raw || stderr || stdout || "no_output"
            }`
          )
        );
        return;
      }
      try {
        const parsed = JSON.parse(raw);
        resolve(parsed);
      } catch (error) {
        reject(
          new Error(
            `youtube_explode_dart_parse_failed: ${String(
              error?.message || error
            )} | raw=${raw || stderr || stdout || "empty"}`
          )
        );
      }
    });
  });
}

async function runYoutubeExplodeSearchDart(query, limit = 30) {
  if (!fs.existsSync(YTEXPLODE_DART_SEARCH_SCRIPT)) {
    const err = new Error("youtube_explode_dart_search_script_missing");
    err.code = "youtube_explode_dart_search_script_missing";
    throw err;
  }
  return await new Promise((resolve, reject) => {
    const args = [
      "--disable-analytics",
      "run",
      "bin/yt_search.dart",
      "--query",
      query,
      "--limit",
      String(limit),
    ];
    const child = spawn(DART_BINARY, args, {
      cwd: YTEXPLODE_DART_ROOT,
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      const err = new Error("youtube_explode_dart_search_timeout");
      err.code = "youtube_explode_dart_search_timeout";
      reject(err);
    }, YTEXPLODE_DART_TIMEOUT_MS);

    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString("utf8");
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString("utf8");
    });
    child.on("error", (err) => {
      clearTimeout(timer);
      reject(err);
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      const lines = String(stdout || "")
        .trim()
        .split(/\r?\n/)
        .map((line) => line.trim())
        .filter(Boolean);
      const raw = lines.length ? lines[lines.length - 1] : "";
      if (code !== 0) {
        reject(
          new Error(
            `youtube_explode_dart_search_failed_${code}: ${
              raw || stderr || stdout || "no_output"
            }`
          )
        );
        return;
      }
      try {
        resolve(JSON.parse(raw));
      } catch (error) {
        reject(
          new Error(
            `youtube_explode_dart_search_parse_failed: ${String(
              error?.message || error
            )} | raw=${raw || stderr || stdout || "empty"}`
          )
        );
      }
    });
  });
}

async function getExplodeInfo(videoId) {
  const data = await runYoutubeExplodeDart(videoId);
  if (!data || data.ok !== true) {
    const err = new Error("youtube_explode_dart_info_failed");
    err.code = String(data?.error || "youtube_explode_dart_info_failed");
    err.detail = String(data?.detail || data?.error || "unknown");
    throw err;
  }
  return data;
}

async function resolveWithYoutubeExplode(videoId) {
  const data = await runYoutubeExplodeDart(videoId);
  if (!data || data.ok !== true) {
    const err = new Error("no_playable_formats");
    err.code = "no_playable_formats";
    err.detail = String(
      data?.detail || data?.error || "youtube_explode_dart_no_playable_formats"
    );
    throw err;
  }
  return {
    resolver: String(data.resolver || "youtube_explode_dart"),
    videoId,
    sourceUrl: String(data.sourceUrl || "").trim(),
    isVideoSource: data.isVideoSource === true,
    audio: data.audio || null,
    muxed: data.muxed || null,
    title: data.title || null,
    author: data.author || null,
  };
}

function readCachedResolve(videoId) {
  const entry = resolveCache.get(videoId);
  if (!entry) return null;
  if (entry.expiresAt <= Date.now()) {
    resolveCache.delete(videoId);
    return null;
  }
  return entry.payload;
}

function writeCachedResolve(videoId, payload) {
  if (RESOLVE_CACHE_TTL_MS <= 0) return;
  resolveCache.set(videoId, {
    payload,
    expiresAt: Date.now() + RESOLVE_CACHE_TTL_MS,
  });
}

function parseVideoIds(input) {
  if (!Array.isArray(input)) return [];
  const unique = new Set();
  for (const item of input) {
    const id = String(item || "").trim();
    if (!id || !isValidVideoId(id)) continue;
    unique.add(id);
    if (unique.size >= RESOLVE_BATCH_LIMIT) break;
  }
  return Array.from(unique);
}

async function resolveVideo(videoId, options = {}) {
  const forceFresh = options?.forceFresh === true;
  const cached = forceFresh ? null : readCachedResolve(videoId);
  if (cached) {
    return {
      ...cached,
      cached: true,
    };
  }

  try {
    const resolved = await resolveWithYoutubeExplode(videoId);
    if (resolved) {
      const payload = {
        ...resolved,
        cached: false,
      };
      writeCachedResolve(videoId, payload);
      return payload;
    }
  } catch (error) {
    const youtubeExplodeError = String(error?.detail || error?.message || error);
    // eslint-disable-next-line no-console
    console.warn(
      `[resolver] youtube_explode_dart failed for ${videoId}: ${youtubeExplodeError}`
    );
    const resolveError = new Error("no_playable_formats");
    resolveError.code = "no_playable_formats";
    resolveError.detail = [youtubeExplodeError, "resolver_sources_exhausted"]
      .filter(Boolean)
      .join(" | ");
    throw resolveError;
  }

  const resolveError = new Error("no_playable_formats");
  resolveError.code = "no_playable_formats";
  resolveError.detail = "resolver_sources_exhausted";
  throw resolveError;
}

function externalBaseUrl(req) {
  const protoHeader = String(req.header("x-forwarded-proto") || "")
    .split(",")[0]
    .trim();
  const hostHeader = String(req.header("x-forwarded-host") || "")
    .split(",")[0]
    .trim();
  const proto = protoHeader || req.protocol || "http";
  const host = hostHeader || req.get("host") || "";
  if (!host) return "";
  return `${proto}://${host}`;
}

function withProxyUrls(req, payload, videoId) {
  const base = externalBaseUrl(req);
  if (!base) return payload;
  const id = String(videoId || "").trim();
  if (!id) return payload;
  const qp = encodeURIComponent(id);
  return {
    ...payload,
    sourceProxyUrl: `${base}/stream?videoId=${qp}&kind=source`,
    audioProxyUrl: payload?.audio?.url
      ? `${base}/stream?videoId=${qp}&kind=audio`
      : null,
    muxedProxyUrl: payload?.muxed?.url
      ? `${base}/stream?videoId=${qp}&kind=muxed`
      : null,
  };
}

function pickStreamUrlByKind(payload, kind) {
  const safeKind = String(kind || "source").trim().toLowerCase();
  if (safeKind === "audio") {
    return String(payload?.audio?.url || "").trim();
  }
  if (safeKind === "muxed") {
    return String(payload?.muxed?.url || "").trim();
  }
  return String(payload?.sourceUrl || "").trim();
}

async function fetchUpstreamStream(url, rangeHeader) {
  const headerProfiles = [
    {
      "user-agent":
        "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36",
      accept: "*/*",
      "accept-language": "en-US,en;q=0.9",
      origin: "https://www.youtube.com",
      referer: "https://www.youtube.com/",
    },
    {
      "user-agent":
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_4_1) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
      accept: "*/*",
      "accept-language": "en-US,en;q=0.9",
      origin: "https://www.youtube.com",
      referer: "https://www.youtube.com/",
    },
    {
      "user-agent":
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
      accept: "*/*",
    },
  ];

  let lastResponse = null;
  for (const baseHeaders of headerProfiles) {
    const headers = { ...baseHeaders };
    if (rangeHeader) headers.range = rangeHeader;
    // eslint-disable-next-line no-await-in-loop
    const response = await fetch(url, { headers });
    if (response.ok || response.status === 206) {
      return response;
    }
    if (lastResponse?.body) {
      try {
        // Evita fuga de sockets cuando probamos varios perfiles de headers.
        await lastResponse.body.cancel();
      } catch {}
    }
    lastResponse = response;
    if (response.status !== 401 && response.status !== 403) {
      return response;
    }
  }
  return lastResponse;
}

app.get("/health", (_req, res) => {
  res.json({
    ok: true,
    service: "vmmusic-yt-resolver",
    version: "1.3.0",
    startedAt: startedAt.toISOString(),
    now: new Date().toISOString(),
    uptimeSeconds: Math.round(process.uptime()),
    cacheTtlMs: RESOLVE_CACHE_TTL_MS,
    batchLimit: RESOLVE_BATCH_LIMIT,
    youtubeExplodeDartScript: fs.existsSync(YTEXPLODE_DART_SCRIPT),
    dartBinary: DART_BINARY,
    stems: true,
    coverAnimation: Boolean(COVER_ANIMATION_PROXY_URL),
  });
});

app.get("/resolve", authMiddleware, async (req, res) => {
  const videoId = String(req.query.videoId || "").trim();
  if (!videoId || !isValidVideoId(videoId)) {
    return res.status(400).json({ ok: false, error: "invalid_video_id" });
  }

  try {
    const payload = await resolveVideo(videoId);
    return res.json({ ok: true, ...withProxyUrls(req, payload, videoId) });
  } catch (error) {
    const code = String(error?.code || "");
    if (code === "no_playable_formats") {
      return res.status(404).json({
        ok: false,
        error: "no_playable_formats",
        detail: error?.detail || undefined,
      });
    }
    return res.status(500).json({
      ok: false,
      error: "resolve_failed",
      detail: String(error?.message || error),
    });
  }
});

app.get("/stream", authMiddleware, async (req, res) => {
  const videoId = String(req.query.videoId || "").trim();
  if (!videoId || !isValidVideoId(videoId)) {
    return res.status(400).json({ ok: false, error: "invalid_video_id" });
  }
  const kind = String(req.query.kind || "source").trim().toLowerCase();
  if (!["source", "audio", "muxed"].includes(kind)) {
    return res.status(400).json({ ok: false, error: "invalid_stream_kind" });
  }

  try {
    const range = String(req.header("range") || "").trim();

    const openUpstream = async (forceFresh = false) => {
      const payload = await resolveVideo(videoId, { forceFresh });
      const targetUrl = pickStreamUrlByKind(payload, kind);
      if (!targetUrl) {
        return { missing: true, upstream: null };
      }
      const upstream = await fetchUpstreamStream(targetUrl, range);
      return { missing: false, upstream };
    };

    let attempt = await openUpstream(false);
    if (attempt.missing) {
      return res.status(404).json({
        ok: false,
        error: "stream_not_available",
        kind,
      });
    }
    // Si el enlace firmado ya venció o quedó inválido en cache, forzamos resolve
    // fresco una sola vez.
    if (
      attempt.upstream &&
      (attempt.upstream.status === 401 || attempt.upstream.status === 403)
    ) {
      resolveCache.delete(videoId);
      attempt = await openUpstream(true);
      if (attempt.missing) {
        return res.status(404).json({
          ok: false,
          error: "stream_not_available",
          kind,
        });
      }
    }

    const upstream = attempt.upstream;
    if (!upstream || (!upstream.ok && upstream.status !== 206)) {
      if (upstream?.body) {
        try {
          await upstream.body.cancel();
        } catch {}
      }
      return res.status((upstream && upstream.status) || 502).json({
        ok: false,
        error: "upstream_stream_failed",
        status: (upstream && upstream.status) || 0,
      });
    }
    if (!upstream.body) {
      return res.status(502).json({ ok: false, error: "empty_upstream_body" });
    }

    res.status(upstream.status);
    const passHeaders = [
      "content-type",
      "content-length",
      "content-range",
      "accept-ranges",
      "cache-control",
      "etag",
      "last-modified",
      "expires",
    ];
    for (const headerName of passHeaders) {
      const value = upstream.headers.get(headerName);
      if (value) res.setHeader(headerName, value);
    }
    res.setHeader("x-vmmusic-stream-proxy", "1");

    const nodeReadable = Readable.fromWeb(upstream.body);
    const abortUpstream = () => {
      try {
        nodeReadable.destroy();
      } catch {}
      try {
        upstream.body.cancel();
      } catch {}
    };
    req.on("aborted", abortUpstream);
    req.on("close", abortUpstream);
    res.on("close", abortUpstream);

    pipeline(nodeReadable, res, (error) => {
      if (error) {
        // eslint-disable-next-line no-console
        console.warn(
          `[stream] pipeline error videoId=${videoId} kind=${kind}: ${String(
            error?.message || error
          )}`
        );
      }
    });
  } catch (error) {
    return res.status(500).json({
      ok: false,
      error: "stream_proxy_failed",
      detail: String(error?.message || error),
    });
  }
});

app.post("/resolve/batch", authMiddleware, async (req, res) => {
  const videoIds = parseVideoIds(req.body?.videoIds);
  if (!videoIds.length) {
    return res.status(400).json({ ok: false, error: "invalid_video_ids" });
  }

  const settled = await Promise.allSettled(
    videoIds.map(async (videoId) => {
      const data = await resolveVideo(videoId);
      return { videoId, ok: true, data };
    })
  );

  const items = settled.map((entry, index) => {
    const videoId = videoIds[index];
    if (entry.status === "fulfilled") {
      return entry.value;
    }
    return {
      videoId,
      ok: false,
      error: "resolve_failed",
      detail: String(entry.reason?.message || entry.reason || "unknown_error"),
    };
  });

  const resolved = items.filter((item) => item.ok).length;
  return res.json({
    ok: true,
    total: items.length,
    resolved,
    failed: items.length - resolved,
    items,
  });
});

app.get("/info", authMiddleware, async (req, res) => {
  const videoId = String(req.query.videoId || "").trim();
  if (!videoId || !isValidVideoId(videoId)) {
    return res.status(400).json({ ok: false, error: "invalid_video_id" });
  }

  try {
    const details = await getExplodeInfo(videoId);
    return res.json({
      ok: true,
      videoId,
      title: details.title || null,
      author: details.author || null,
      channelId: details.channelId || null,
      durationSeconds: Number(details.durationSeconds || 0) || null,
      thumbnails: Array.isArray(details.thumbnails) ? details.thumbnails : [],
      isLiveContent: details.isLiveContent === true,
      publishDate: details.publishDate || null,
      viewCount: Number(details.viewCount || 0) || null,
    });
  } catch (error) {
    return res.status(500).json({
      ok: false,
      error: "info_failed",
      detail: String(error?.message || error),
    });
  }
});

app.get("/search", authMiddleware, async (req, res) => {
  const query = String(req.query?.q || "").trim();
  const limitRaw = String(req.query?.limit || "30").trim();
  const limit = Math.max(1, Math.min(80, Number(limitRaw) || 30));
  if (!query) {
    return res.status(400).json({ ok: false, error: "missing_query" });
  }

  try {
    const result = await runYoutubeExplodeSearchDart(query, limit);
    if (!result || result.ok !== true) {
      return res.status(502).json({
        ok: false,
        error: String(result?.error || "search_failed"),
        detail: String(result?.detail || "unknown"),
      });
    }
    return res.json({
      ok: true,
      query,
      items: Array.isArray(result.items) ? result.items : [],
    });
  } catch (error) {
    return res.status(500).json({
      ok: false,
      error: "search_failed",
      detail: String(error?.message || error),
    });
  }
});

function safeTrackId(raw) {
  const value = String(raw || "").trim().toLowerCase();
  const compact = value.replace(/[^a-z0-9_-]/g, "");
  return compact || null;
}

function sha1(input) {
  return crypto.createHash("sha1").update(input).digest("hex");
}

async function ensureDir(dirPath) {
  await fsp.mkdir(dirPath, { recursive: true });
}

async function fileExists(filePath) {
  try {
    await fsp.access(filePath, fs.constants.F_OK);
    return true;
  } catch {
    return false;
  }
}

async function getFileAgeMs(filePath) {
  try {
    const stats = await fsp.stat(filePath);
    return Math.max(0, Date.now() - stats.mtimeMs);
  } catch {
    return Number.POSITIVE_INFINITY;
  }
}

async function removeDirIfExists(dirPath) {
  try {
    await fsp.rm(dirPath, { recursive: true, force: true });
  } catch {}
}

async function cleanupStemsCacheRoot() {
  if (STEMS_CACHE_TTL_MS <= 0) return;
  const root = path.join(STEMS_ROOT, "cache");
  let trackDirs = [];
  try {
    trackDirs = await fsp.readdir(root, { withFileTypes: true });
  } catch {
    return;
  }

  for (const trackEntry of trackDirs) {
    if (!trackEntry.isDirectory()) continue;
    const trackPath = path.join(root, trackEntry.name);
    let hashDirs = [];
    try {
      hashDirs = await fsp.readdir(trackPath, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const hashEntry of hashDirs) {
      if (!hashEntry.isDirectory()) continue;
      const cacheDir = path.join(trackPath, hashEntry.name);
      const marker = path.join(cacheDir, "instrumental.wav");
      const ageMs = await getFileAgeMs(marker);
      if (!Number.isFinite(ageMs) || ageMs > STEMS_CACHE_TTL_MS) {
        await removeDirIfExists(cacheDir);
      }
    }
  }
}

async function downloadToFile(url, destination) {
  const response = await fetch(url);
  if (!response.ok || !response.body) {
    throw new Error(`download_failed_status_${response.status}`);
  }
  await ensureDir(path.dirname(destination));
  await new Promise((resolve, reject) => {
    const write = fs.createWriteStream(destination);
    response.body.pipe(write);
    response.body.on("error", reject);
    write.on("error", reject);
    write.on("finish", resolve);
  });
}

async function runDemucs({ inputPath, outputRoot, model }) {
  const scriptPath = path.join(__dirname, "scripts", "stems_demucs.py");
  const args = [
    scriptPath,
    "--input",
    inputPath,
    "--output-root",
    outputRoot,
    "--model",
    model,
  ];

  await new Promise((resolve, reject) => {
    const child = spawn(STEMS_PYTHON, args, {
      cwd: __dirname,
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      reject(new Error("stems_timeout"));
    }, STEMS_TIMEOUT_MS);
    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString("utf8");
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString("utf8");
    });
    child.on("error", (err) => {
      clearTimeout(timer);
      reject(err);
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      if (code !== 0) {
        reject(new Error(`demucs_failed_${code}: ${stderr || stdout}`));
        return;
      }
      try {
        const parsed = JSON.parse(stdout.trim());
        resolve(parsed);
      } catch (e) {
        reject(new Error(`demucs_output_parse_failed: ${String(e)}`));
      }
    });
  });
}

async function requestAnimatedCoverFromProxy({ trackId, sourceUrl }) {
  if (!COVER_ANIMATION_PROXY_URL) {
    throw new Error("cover_animation_not_configured");
  }

  const controller = new AbortController();
  const timeout = setTimeout(() => {
    controller.abort();
  }, COVER_ANIMATION_TIMEOUT_MS);

  const headers = { "content-type": "application/json" };
  if (COVER_ANIMATION_PROXY_KEY) {
    headers["x-api-key"] = COVER_ANIMATION_PROXY_KEY;
    headers.authorization = `Bearer ${COVER_ANIMATION_PROXY_KEY}`;
  }

  try {
    const response = await fetch(COVER_ANIMATION_PROXY_URL, {
      method: "POST",
      headers,
      body: JSON.stringify({ trackId, sourceUrl }),
      signal: controller.signal,
    });
    if (!response.ok) {
      throw new Error(`cover_animation_proxy_status_${response.status}`);
    }
    const data = await response.json().catch(() => null);
    if (!data || typeof data !== "object") {
      throw new Error("cover_animation_proxy_invalid_json");
    }
    const animatedCoverUrl = String(
      data.animatedCoverUrl || data.url || data.output || ""
    ).trim();
    if (!animatedCoverUrl) {
      throw new Error("cover_animation_proxy_missing_url");
    }
    return animatedCoverUrl;
  } finally {
    clearTimeout(timeout);
  }
}

app.post("/stems/separate", authMiddleware, async (req, res) => {
  const sourceUrl = String(req.body?.sourceUrl || "").trim();
  const requestedTrackId = safeTrackId(req.body?.trackId);
  if (!sourceUrl) {
    return res.status(400).json({ ok: false, error: "missing_source_url" });
  }
  if (!/^https?:\/\//i.test(sourceUrl)) {
    return res.status(400).json({ ok: false, error: "invalid_source_url" });
  }

  const sourceHash = sha1(sourceUrl);
  const trackId = requestedTrackId || sourceHash.slice(0, 14);
  const cacheDir = path.join(STEMS_ROOT, "cache", trackId, sourceHash);
  const inputPath = path.join(cacheDir, "input_audio.bin");
  const instrumentalPath = path.join(cacheDir, "instrumental.wav");

  try {
    void cleanupStemsCacheRoot();
    await ensureDir(cacheDir);
    if (await fileExists(instrumentalPath)) {
      const ageMs = await getFileAgeMs(instrumentalPath);
      if (!Number.isFinite(ageMs) || ageMs > STEMS_CACHE_TTL_MS) {
        await removeDirIfExists(cacheDir);
        await ensureDir(cacheDir);
      }
    }
    if (!(await fileExists(instrumentalPath))) {
      if (!(await fileExists(inputPath))) {
        await downloadToFile(sourceUrl, inputPath);
      }
      const result = await runDemucs({
        inputPath,
        outputRoot: cacheDir,
        model: STEMS_MODEL,
      });
      const produced = String(result.instrumental_path || "").trim();
      if (!produced || !(await fileExists(produced))) {
        return res
          .status(500)
          .json({ ok: false, error: "instrumental_not_generated" });
      }
      await fsp.copyFile(produced, instrumentalPath);
    }

    const baseUrl = `${req.protocol}://${req.get("host")}`;
    const rel = path
      .relative(STEMS_ROOT, instrumentalPath)
      .replaceAll(path.sep, "/");
    return res.json({
      ok: true,
      trackId,
      instrumentalUrl: `${baseUrl}/stems-files/${rel}`,
    });
  } catch (error) {
    return res.status(500).json({
      ok: false,
      error: "stems_failed",
      detail: String(error?.message || error),
    });
  }
});

app.post("/cover/animate", authMiddleware, async (req, res) => {
  const sourceUrl = String(req.body?.sourceUrl || "").trim();
  const requestedTrackId = safeTrackId(req.body?.trackId);
  if (!sourceUrl) {
    return res.status(400).json({ ok: false, error: "missing_source_url" });
  }
  if (!/^https?:\/\//i.test(sourceUrl)) {
    return res.status(400).json({ ok: false, error: "invalid_source_url" });
  }
  if (!COVER_ANIMATION_PROXY_URL) {
    return res
      .status(501)
      .json({ ok: false, error: "cover_animation_not_configured" });
  }

  const sourceHash = sha1(sourceUrl);
  const trackId = requestedTrackId || sourceHash.slice(0, 14);

  try {
    let animatedCoverUrl = await requestAnimatedCoverFromProxy({
      trackId,
      sourceUrl,
    });
    if (/^\//.test(animatedCoverUrl)) {
      const baseUrl = `${req.protocol}://${req.get("host")}`;
      animatedCoverUrl = `${baseUrl}${animatedCoverUrl}`;
    }
    return res.json({
      ok: true,
      trackId,
      animatedCoverUrl,
    });
  } catch (error) {
    return res.status(500).json({
      ok: false,
      error: "cover_animation_failed",
      detail: String(error?.message || error),
    });
  }
});

app.use((error, _req, res, _next) => {
  if (String(error?.message || "") === "cors_not_allowed") {
    return res.status(403).json({ ok: false, error: "cors_not_allowed" });
  }
  return res.status(500).json({
    ok: false,
    error: "internal_error",
    detail: String(error?.message || error),
  });
});

app.listen(PORT, () => {
  // eslint-disable-next-line no-console
  console.log(`[resolver] listening on :${PORT}`);
  // eslint-disable-next-line no-console
  console.log(
    `[resolver] cache policy resolveTtlMs=${RESOLVE_CACHE_TTL_MS} stemsTtlMs=${STEMS_CACHE_TTL_MS}`
  );
});

process.on("unhandledRejection", (reason) => {
  // eslint-disable-next-line no-console
  console.error("[process] unhandledRejection", reason);
});

process.on("uncaughtException", (error) => {
  // eslint-disable-next-line no-console
  console.error("[process] uncaughtException", error);
});
