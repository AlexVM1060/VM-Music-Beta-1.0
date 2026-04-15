# VMMusic YouTube Resolver (Render)

Backend de fallback para resolver URLs de audio/video cuando YouTube limita solicitudes directas desde el iPhone.

## Endpoint

- `GET /health`
- `GET /resolve?videoId=<youtube_video_id>`
- `POST /stems/separate`
- `POST /cover/animate`

Respuesta de `resolve`:

```json
{
  "ok": true,
  "videoId": "abc123",
  "sourceUrl": "https://...",
  "isVideoSource": false,
  "audio": { "url": "https://..." },
  "muxed": { "url": "https://..." }
}
```

Body de `POST /stems/separate`:

```json
{
  "trackId": "opcional_id_cancion",
  "sourceUrl": "https://url-directa-de-audio"
}
```

Respuesta:

```json
{
  "ok": true,
  "trackId": "abc123",
  "instrumentalUrl": "https://<tu-servicio>/stems-files/cache/..."
}
```

Body de `POST /cover/animate`:

```json
{
  "trackId": "opcional_id_cancion",
  "sourceUrl": "https://url-de-caratula"
}
```

Respuesta:

```json
{
  "ok": true,
  "trackId": "abc123",
  "animatedCoverUrl": "https://..."
}
```

## Deploy en Render

1. Sube esta carpeta al repo (`backend/`).
2. En Render: `New` -> `Web Service`.
3. Selecciona tu repo.
4. Configura:
   - `Root Directory`: `backend`
   - `Build Command`: `npm install`
   - `Start Command`: `npm start`
   - `Runtime`: Node
5. Variables de entorno:
   - opcional `RESOLVER_API_KEY` (si la pones, la app debe enviarla).
   - opcional `STEMS_ROOT` (default: `/tmp/vmmusic-stems`)
   - opcional `STEMS_MODEL` (default: `htdemucs_ft`)
   - opcional `STEMS_PYTHON` (default: `python3`)
   - opcional `STEMS_TIMEOUT_MS` (default: `720000`)
   - opcional `COVER_ANIMATION_PROXY_URL` (endpoint de tu servicio IA que anima carátulas)
   - opcional `COVER_ANIMATION_PROXY_KEY` (si tu proxy requiere API key)
   - opcional `COVER_ANIMATION_TIMEOUT_MS` (default: `90000`)
6. Deploy.
7. Prueba:
   - `https://<tu-servicio>.onrender.com/health`
   - `https://<tu-servicio>.onrender.com/resolve?videoId=dQw4w9WgXcQ`

## Requisitos AI Stems (Demucs)

El endpoint de stems usa `backend/scripts/stems_demucs.py`, que requiere:

- Python 3
- paquete `demucs` instalado en el servidor (`pip install demucs`)
- `ffmpeg` disponible en PATH

## Integración Flutter

Ejecuta la app con:

```bash
flutter run \
  --dart-define=YT_RESOLVER_BASE_URL=https://<tu-servicio>.onrender.com \
  --dart-define=YT_RESOLVER_API_KEY=<tu_key_opcional> \
  --dart-define=STEMS_API_BASE_URL=https://<tu-servicio>.onrender.com \
  --dart-define=STEMS_API_KEY=<tu_key_opcional> \
  --dart-define=COVER_ANIMATION_API_BASE_URL=https://<tu-servicio>.onrender.com \
  --dart-define=COVER_ANIMATION_API_KEY=<tu_key_opcional>
```

> Si no usas `RESOLVER_API_KEY` en Render, omite `YT_RESOLVER_API_KEY`.
