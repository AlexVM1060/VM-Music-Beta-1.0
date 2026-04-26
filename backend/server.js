const express = require("express");
const cors = require("cors");
const ytdl = require("@distube/ytdl-core");
const fs = require("node:fs");
const fsp = require("node:fs/promises");
const os = require("node:os");
const path = require("node:path");
const crypto = require("node:crypto");
const { spawn } = require("node:child_process");

const app = express();

const PORT = Number(process.env.PORT || 10000);
const API_KEY = (process.env.RESOLVER_API_KEY || "").trim();
const YTDLP_BINARY_ENV = (process.env.YTDLP_BINARY || "yt-dlp").trim();
const YTDLP_TIMEOUT_MS = Number(process.env.YTDLP_TIMEOUT_MS || 20 * 1000);
const YOUTUBE_COOKIE = (process.env.YOUTUBE_COOKIE || "").trim();
const RESOLVE_CACHE_TTL_MS = Number(
  process.env.RESOLVE_CACHE_TTL_MS || 10 * 60 * 1000
);
const RESOLVE_BATCH_LIMIT = Number(process.env.RESOLVE_BATCH_LIMIT || 20);
const CORS_ALLOW_ORIGINS = (process.env.CORS_ALLOW_ORIGINS || "").trim();
const STEMS_ROOT = path.resolve(
  process.env.STEMS_ROOT || path.join(os.tmpdir(), "vmmusic-stems")
);
const STEMS_MODEL = (process.env.STEMS_MODEL || "htdemucs_ft").trim();
const STEMS_PYTHON = (process.env.STEMS_PYTHON || "python3").trim();
const STEMS_TIMEOUT_MS = Number(process.env.STEMS_TIMEOUT_MS || 12 * 60 * 1000);
const COVER_ANIMATION_PROXY_URL = (
  process.env.COVER_ANIMATION_PROXY_URL || ""
).trim();
const COVER_ANIMATION_PROXY_KEY = (
  process.env.COVER_ANIMATION_PROXY_KEY || ""
).trim();
const COVER_ANIMATION_TIMEOUT_MS = Number(
  process.env.COVER_ANIMATION_TIMEOUT_MS || 90 * 1000
);
const YOUTUBEI_PLAYER_ENDPOINT =
  "https://www.youtube.com/youtubei/v1/player?key=AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8";

const startedAt = new Date();
const resolveCache = new Map();
const YTDLP_LOCAL_BINARY = path.join(__dirname, ".bin", "yt-dlp");
const YTDLP_BINARY =
  YTDLP_BINARY_ENV === "yt-dlp" && fs.existsSync(YTDLP_LOCAL_BINARY)
    ? YTDLP_LOCAL_BINARY
    : YTDLP_BINARY_ENV;

function parseCookieHeader(rawCookie) {
  const raw = String(rawCookie || "").trim();
  if (!raw) return [];
  const parts = raw
    .split(";")
    .map((part) => part.trim())
    .filter(Boolean);
  const cookies = [];
  for (const part of parts) {
    const idx = part.indexOf("=");
    if (idx <= 0) continue;
    const name = part.slice(0, idx).trim();
    const value = part.slice(idx + 1).trim();
    if (!name || !value) continue;
    cookies.push({
      name,
      value,
      domain: ".youtube.com",
      path: "/",
      secure: true,
      httpOnly: false,
    });
  }
  return cookies;
}

const YTDL_COOKIES = parseCookieHeader(YOUTUBE_COOKIE);
const YTDL_AGENT = YTDL_COOKIES.length ? ytdl.createAgent(YTDL_COOKIES) : null;

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

function pickAudioFormat(formats) {
  const audios = formats.filter(
    (f) =>
      f.hasAudio &&
      !f.hasVideo &&
      typeof f.url === "string" &&
      f.url.length > 0
  );
  if (!audios.length) return null;
  audios.sort((a, b) => (b.audioBitrate || 0) - (a.audioBitrate || 0));
  return audios[0];
}

function pickMuxedFormat(formats) {
  const muxed = formats.filter(
    (f) =>
      f.hasAudio &&
      f.hasVideo &&
      typeof f.url === "string" &&
      f.url.length > 0
  );
  if (!muxed.length) return null;
  muxed.sort((a, b) => (b.bitrate || 0) - (a.bitrate || 0));
  const mp4 = muxed.find((f) => (f.container || "").toLowerCase() === "mp4");
  return mp4 || muxed[0];
}

function pickYtDlpAudioFormat(formats) {
  const list = Array.isArray(formats) ? formats : [];
  const audios = list.filter((f) => {
    const acodec = String(f?.acodec || "").toLowerCase();
    const vcodec = String(f?.vcodec || "").toLowerCase();
    const url = String(f?.url || "").trim();
    return url && acodec && acodec !== "none" && (!vcodec || vcodec === "none");
  });
  if (!audios.length) return null;
  audios.sort((a, b) => (Number(b?.abr || 0) || 0) - (Number(a?.abr || 0) || 0));
  return audios[0];
}

function pickYtDlpMuxedFormat(formats) {
  const list = Array.isArray(formats) ? formats : [];
  const muxed = list.filter((f) => {
    const acodec = String(f?.acodec || "").toLowerCase();
    const vcodec = String(f?.vcodec || "").toLowerCase();
    const url = String(f?.url || "").trim();
    return url && acodec && acodec !== "none" && vcodec && vcodec !== "none";
  });
  if (!muxed.length) return null;
  muxed.sort((a, b) => (Number(b?.tbr || 0) || 0) - (Number(a?.tbr || 0) || 0));
  const mp4 = muxed.find((f) =>
    String(f?.ext || "")
      .toLowerCase()
      .includes("mp4")
  );
  return mp4 || muxed[0];
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
    if (!id || !ytdl.validateID(id)) continue;
    unique.add(id);
    if (unique.size >= RESOLVE_BATCH_LIMIT) break;
  }
  return Array.from(unique);
}

function pickYoutubeiAudioFormat(formats) {
  const list = Array.isArray(formats) ? formats : [];
  const audio = list.filter((f) => {
    const mime = String(f?.mimeType || "").toLowerCase();
    const url = String(f?.url || "").trim();
    return url && mime.includes("audio/");
  });
  if (!audio.length) return null;
  audio.sort((a, b) => Number(b?.bitrate || 0) - Number(a?.bitrate || 0));
  return audio[0];
}

function pickYoutubeiMuxedFormat(formats) {
  const list = Array.isArray(formats) ? formats : [];
  const muxed = list.filter((f) => {
    const mime = String(f?.mimeType || "").toLowerCase();
    const url = String(f?.url || "").trim();
    return url && mime.includes("video/");
  });
  if (!muxed.length) return null;
  muxed.sort((a, b) => Number(b?.bitrate || 0) - Number(a?.bitrate || 0));
  const mp4 = muxed.find((f) =>
    String(f?.mimeType || "")
      .toLowerCase()
      .includes("mp4")
  );
  return mp4 || muxed[0];
}

async function resolveWithYoutubei(videoId) {
  const clients = [
    {
      name: "WEB",
      version: "2.20240224.11.00",
      userAgent:
        "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
      xClientName: "1",
      xClientVersion: "2.20240224.11.00",
    },
    {
      name: "ANDROID",
      version: "19.09.37",
      userAgent: "com.google.android.youtube/19.09.37 (Linux; U; Android 14)",
      xClientName: "3",
      xClientVersion: "19.09.37",
    },
    {
      name: "IOS",
      version: "19.09.3",
      userAgent:
        "com.google.ios.youtube/19.09.3 (iPhone16,2; U; CPU iOS 17_3 like Mac OS X;)",
      xClientName: "5",
      xClientVersion: "19.09.3",
    },
  ];

  let lastReason = null;
  for (const client of clients) {
    const headers = {
      "content-type": "application/json",
      "user-agent": client.userAgent,
      accept: "application/json",
      origin: "https://www.youtube.com",
      referer: `https://www.youtube.com/watch?v=${videoId}`,
      "x-youtube-client-name": client.xClientName,
      "x-youtube-client-version": client.xClientVersion,
    };
    if (YOUTUBE_COOKIE) {
      headers.cookie = YOUTUBE_COOKIE;
    }
    const body = {
      videoId,
      contentCheckOk: true,
      racyCheckOk: true,
      context: {
        client: {
          clientName: client.name,
          clientVersion: client.version,
          hl: "en",
          gl: "US",
        },
      },
    };
    const response = await fetch(YOUTUBEI_PLAYER_ENDPOINT, {
      method: "POST",
      headers,
      body: JSON.stringify(body),
    });
    if (!response.ok) {
      lastReason = `youtubei_status_${response.status}_${client.name}`;
      continue;
    }
    const data = await response.json().catch(() => null);
    if (!data || typeof data !== "object") {
      lastReason = `youtubei_invalid_json_${client.name}`;
      continue;
    }

    const playability = data?.playabilityStatus || {};
    const status = String(playability?.status || "").trim();
    const reason = String(playability?.reason || "").trim();
    if (status && status !== "OK") {
      lastReason = reason || `youtubei_playability_${status}_${client.name}`;
      continue;
    }

    const streamingData = data?.streamingData || {};
    const adaptiveFormats = Array.isArray(streamingData?.adaptiveFormats)
      ? streamingData.adaptiveFormats
      : [];
    const formats = Array.isArray(streamingData?.formats)
      ? streamingData.formats
      : [];

    const audio = pickYoutubeiAudioFormat(adaptiveFormats);
    const muxed = pickYoutubeiMuxedFormat(formats);
    const hlsManifestUrl = String(streamingData?.hlsManifestUrl || "").trim();
    if (!audio && !muxed && !hlsManifestUrl) {
      lastReason = `youtubei_no_formats_${client.name}`;
      continue;
    }

    const details = data?.videoDetails || {};
    if (audio) {
      return {
        resolver: `youtubei-${client.name.toLowerCase()}`,
        videoId,
        sourceUrl: String(audio.url || "").trim(),
        isVideoSource: false,
        audio: {
          url: String(audio.url || "").trim(),
          bitrate: Number(audio?.bitrate || 0) || null,
          mimeType: String(audio?.mimeType || "").trim() || null,
        },
        muxed: muxed
          ? {
              url: String(muxed.url || "").trim(),
              bitrate: Number(muxed?.bitrate || 0) || null,
              qualityLabel: String(muxed?.qualityLabel || "").trim() || null,
              mimeType: String(muxed?.mimeType || "").trim() || null,
            }
          : null,
        title: String(details?.title || "").trim() || null,
        author: String(details?.author || "").trim() || null,
      };
    }

    if (muxed) {
      return {
        resolver: `youtubei-${client.name.toLowerCase()}`,
        videoId,
        sourceUrl: String(muxed.url || "").trim(),
        isVideoSource: true,
        audio: null,
        muxed: {
          url: String(muxed.url || "").trim(),
          bitrate: Number(muxed?.bitrate || 0) || null,
          qualityLabel: String(muxed?.qualityLabel || "").trim() || null,
          mimeType: String(muxed?.mimeType || "").trim() || null,
        },
        title: String(details?.title || "").trim() || null,
        author: String(details?.author || "").trim() || null,
      };
    }

    if (hlsManifestUrl) {
      return {
        resolver: `youtubei-${client.name.toLowerCase()}`,
        videoId,
        sourceUrl: hlsManifestUrl,
        isVideoSource: true,
        audio: null,
        muxed: {
          url: hlsManifestUrl,
          bitrate: null,
          qualityLabel: "hls",
          mimeType: "application/x-mpegURL",
        },
        title: String(details?.title || "").trim() || null,
        author: String(details?.author || "").trim() || null,
      };
    }
  }

  return { error: lastReason || "youtubei_failed" };
}

async function runYtDlpJson(videoId) {
  const url = `https://www.youtube.com/watch?v=${videoId}`;
  const args = [
    "-J",
    "--no-playlist",
    "--no-warnings",
    "--skip-download",
    "--geo-bypass",
    "--geo-bypass-country",
    "US",
    url,
  ];
  if (YOUTUBE_COOKIE) {
    args.unshift(`Cookie: ${YOUTUBE_COOKIE}`);
    args.unshift("--add-header");
  }
  return await new Promise((resolve, reject) => {
    const child = spawn(YTDLP_BINARY, args, {
      cwd: __dirname,
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      reject(new Error("yt_dlp_timeout"));
    }, YTDLP_TIMEOUT_MS);
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
        reject(new Error(`yt_dlp_failed_${code}: ${stderr || stdout}`));
        return;
      }
      try {
        const parsed = JSON.parse(stdout.trim());
        resolve(parsed);
      } catch (e) {
        reject(new Error(`yt_dlp_output_parse_failed: ${String(e)}`));
      }
    });
  });
}

async function resolveWithYtDlp(videoId) {
  const info = await runYtDlpJson(videoId);
  const formats = Array.isArray(info?.formats) ? info.formats : [];
  const audio = pickYtDlpAudioFormat(formats);
  const muxed = pickYtDlpMuxedFormat(formats);
  if (!audio && !muxed) return null;
  const source = audio || muxed;
  return {
    resolver: "yt-dlp",
    videoId,
    sourceUrl: source.url,
    isVideoSource: source === muxed && source !== audio,
    audio: audio
      ? {
          url: audio.url,
          bitrate: Number(audio?.abr || 0) || null,
          mimeType: audio?.ext ? `${audio.ext}` : null,
        }
      : null,
    muxed: muxed
      ? {
          url: muxed.url,
          bitrate: Number(muxed?.tbr || 0) || null,
          qualityLabel: muxed?.format_note || muxed?.resolution || null,
          mimeType: muxed?.ext ? `${muxed.ext}` : null,
        }
      : null,
    title: info?.title || null,
    author: info?.uploader || null,
  };
}

async function resolveVideo(videoId) {
  const cached = readCachedResolve(videoId);
  if (cached) {
    return {
      ...cached,
      cached: true,
    };
  }

  let ytDlpError = null;
  try {
    const resolved = await resolveWithYtDlp(videoId);
    if (resolved) {
      const payload = { ...resolved, ytDlpError: null, cached: false };
      writeCachedResolve(videoId, payload);
      return payload;
    }
  } catch (error) {
    ytDlpError = String(error?.message || error);
    // eslint-disable-next-line no-console
    console.warn(`[resolver] yt-dlp failed for ${videoId}: ${ytDlpError}`);
  }

  let info = null;
  let ytdlError = null;
  try {
    const ytdlOptions = YTDL_AGENT ? { agent: YTDL_AGENT } : undefined;
    info = await ytdl.getInfo(videoId, ytdlOptions);
  } catch (error) {
    ytdlError = String(error?.message || error);
  }

  const formats = info?.formats || [];
  const audio = pickAudioFormat(formats);
  const muxed = pickMuxedFormat(formats);

  if (!audio && !muxed) {
    const ytInfo = await resolveWithYoutubei(videoId);
    if (ytInfo && !ytInfo.error) {
      const payload = {
        ...ytInfo,
        ytDlpError: ytDlpError || ytdlError || null,
        cached: false,
      };
      writeCachedResolve(videoId, payload);
      return payload;
    }

    const error = new Error("no_playable_formats");
    error.code = "no_playable_formats";
    error.detail =
      ytInfo?.error || ytdlError || ytDlpError || "resolver_sources_exhausted";
    throw error;
  }

  const source = audio || muxed;
  const payload = {
    resolver: "ytdl-core",
    ytDlpError,
    videoId,
    sourceUrl: source.url,
    isVideoSource: source === muxed && source !== audio,
    audio: audio
      ? {
          url: audio.url,
          bitrate: audio.audioBitrate || null,
          mimeType: audio.mimeType || null,
        }
      : null,
    muxed: muxed
      ? {
          url: muxed.url,
          bitrate: muxed.bitrate || null,
          qualityLabel: muxed.qualityLabel || null,
          mimeType: muxed.mimeType || null,
        }
      : null,
    title: info?.videoDetails?.title || null,
    author: info?.videoDetails?.author?.name || null,
    cached: false,
  };

  writeCachedResolve(videoId, payload);
  return payload;
}

app.get("/health", (_req, res) => {
  res.json({
    ok: true,
    service: "vmmusic-yt-resolver",
    version: "1.1.0",
    startedAt: startedAt.toISOString(),
    now: new Date().toISOString(),
    uptimeSeconds: Math.round(process.uptime()),
    cacheTtlMs: RESOLVE_CACHE_TTL_MS,
    batchLimit: RESOLVE_BATCH_LIMIT,
    stems: true,
    coverAnimation: Boolean(COVER_ANIMATION_PROXY_URL),
  });
});

app.get("/resolve", authMiddleware, async (req, res) => {
  const videoId = String(req.query.videoId || "").trim();
  if (!videoId || !ytdl.validateID(videoId)) {
    return res.status(400).json({ ok: false, error: "invalid_video_id" });
  }

  try {
    const payload = await resolveVideo(videoId);
    return res.json({ ok: true, ...payload });
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
  if (!videoId || !ytdl.validateID(videoId)) {
    return res.status(400).json({ ok: false, error: "invalid_video_id" });
  }

  try {
    const ytdlOptions = YTDL_AGENT ? { agent: YTDL_AGENT } : undefined;
    const info = await ytdl.getBasicInfo(videoId, ytdlOptions);
    const details = info?.videoDetails;
    return res.json({
      ok: true,
      videoId,
      title: details?.title || null,
      author: details?.author?.name || null,
      channelId: details?.channelId || null,
      durationSeconds: Number(details?.lengthSeconds || 0) || null,
      thumbnails: Array.isArray(details?.thumbnails)
        ? details.thumbnails
            .map((thumb) => String(thumb?.url || "").trim())
            .filter(Boolean)
        : [],
      isLiveContent: details?.isLiveContent === true,
      publishDate: details?.publishDate || null,
      viewCount: Number(details?.viewCount || 0) || null,
    });
  } catch (error) {
    return res.status(500).json({
      ok: false,
      error: "info_failed",
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
    await ensureDir(cacheDir);
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
});
