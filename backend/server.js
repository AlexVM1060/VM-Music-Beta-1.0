const express = require("express");
const cors = require("cors");
const ytdl = require("@distube/ytdl-core");

const app = express();

const PORT = process.env.PORT || 10000;
const API_KEY = (process.env.RESOLVER_API_KEY || "").trim();

app.use(cors());

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

app.get("/health", (_req, res) => {
  res.json({ ok: true, service: "vmmusic-yt-resolver" });
});

app.get("/resolve", authMiddleware, async (req, res) => {
  const videoId = String(req.query.videoId || "").trim();
  if (!videoId || !ytdl.validateID(videoId)) {
    return res.status(400).json({ ok: false, error: "invalid_video_id" });
  }

  try {
    const info = await ytdl.getInfo(videoId);
    const formats = info.formats || [];
    const audio = pickAudioFormat(formats);
    const muxed = pickMuxedFormat(formats);

    if (!audio && !muxed) {
      return res.status(404).json({ ok: false, error: "no_playable_formats" });
    }

    const source = audio || muxed;
    return res.json({
      ok: true,
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

app.listen(PORT, () => {
  // eslint-disable-next-line no-console
  console.log(`[resolver] listening on :${PORT}`);
});
