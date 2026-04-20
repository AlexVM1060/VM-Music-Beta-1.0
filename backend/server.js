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

const PORT = process.env.PORT || 10000;
const API_KEY = (process.env.RESOLVER_API_KEY || "").trim();
const YTDLP_BINARY = (process.env.YTDLP_BINARY || "yt-dlp").trim();
const YTDLP_TIMEOUT_MS = Number(process.env.YTDLP_TIMEOUT_MS || 20 * 1000);
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

app.use(cors());
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

app.get("/health", (_req, res) => {
  res.json({
    ok: true,
    service: "vmmusic-yt-resolver",
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
    let ytDlpError = null;
    try {
      const resolved = await resolveWithYtDlp(videoId);
      if (resolved) {
        return res.json({ ok: true, ...resolved });
      }
    } catch (error) {
      ytDlpError = String(error?.message || error);
      // eslint-disable-next-line no-console
      console.warn(`[resolver] yt-dlp failed for ${videoId}: ${ytDlpError}`);
    }

    const info = await ytdl.getInfo(videoId);
    const formats = info.formats || [];
    const audio = pickAudioFormat(formats);
    const muxed = pickMuxedFormat(formats);

    if (!audio && !muxed) {
      return res.status(404).json({
        ok: false,
        error: "no_playable_formats",
        detail: ytDlpError || undefined,
      });
    }

    const source = audio || muxed;
    return res.json({
      ok: true,
      resolver: "ytdl-core",
      ytDlpError: ytDlpError || null,
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
      title: info.videoDetails?.title || null,
      author: info.videoDetails?.author?.name || null,
    });
  } catch (error) {
    return res.status(500).json({
      ok: false,
      error: "resolve_failed",
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

app.listen(PORT, () => {
  // eslint-disable-next-line no-console
  console.log(`[resolver] listening on :${PORT}`);
});
