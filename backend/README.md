# VMMusic Backend (YouTube Resolver + AI helpers)

Backend para tu app de reproducción de videos/audio. Resuelve URLs directas de YouTube, permite separación de stems y animación de carátulas.

## Endpoints

- `GET /health`
- `GET /resolve?videoId=<youtube_video_id>`
- `POST /resolve/batch`
- `GET /info?videoId=<youtube_video_id>`
- `POST /stems/separate`
- `POST /cover/animate`

## Ejemplos

### Resolver 1 video

```bash
curl "http://localhost:10000/resolve?videoId=dQw4w9WgXcQ"
```

### Resolver varios videos

```bash
curl -X POST "http://localhost:10000/resolve/batch" \
  -H "Content-Type: application/json" \
  -d '{"videoIds":["dQw4w9WgXcQ","kJQP7kiw5Fk"]}'
```

### Obtener metadata rápida

```bash
curl "http://localhost:10000/info?videoId=dQw4w9WgXcQ"
```

## Variables de entorno

Copia `backend/.env.example` como referencia para configurar:

- `PORT`
- `RESOLVER_API_KEY`
- `CORS_ALLOW_ORIGINS`
- `YTDLP_BINARY`
- `YTDLP_TIMEOUT_MS`
- `YTDLP_CLIENT_PROFILES`
- `YTDLP_PROXY_URL` (opcional, proxy único para yt-dlp)
- `YTDLP_PROXY_POOL` (opcional, proxies separados por coma para rotación)
- `YTDLP_MAX_ATTEMPTS` (máximo intentos por video combinando perfil+proxy)
- `YOUTUBE_COOKIE` (opcional, recomendado si YouTube responde bot-check)
- `YOUTUBE_COOKIES_FILE` (ruta a `cookies.txt` exportado del navegador en formato Netscape)
- `YOUTUBE_COOKIES_B64` (contenido base64 de `cookies.txt`; útil para plataformas sin filesystem persistente)
- `RESOLVE_CACHE_TTL_MS`
- `RESOLVE_BATCH_LIMIT`
- `STEMS_ROOT`
- `STEMS_MODEL`
- `STEMS_PYTHON`
- `STEMS_TIMEOUT_MS`
- `COVER_ANIMATION_PROXY_URL`
- `COVER_ANIMATION_PROXY_KEY`
- `COVER_ANIMATION_TIMEOUT_MS`

## Correr local

```bash
cd backend
npm install
npm start
```

Servidor: `http://localhost:10000`

## Deploy en Render

1. Crea un `Web Service`.
2. `Root Directory`: `backend`
3. `Build Command`: `npm install`
4. `Start Command`: `npm start`
5. Configura tus variables de entorno.

### Opcion recomendada: Blueprint (`render.yaml`)

Este repo ya incluye `render.yaml` en la raiz. Puedes desplegarlo asi:

1. Sube tus cambios a GitHub.
2. En Render: `New` -> `Blueprint`.
3. Selecciona tu repo y branch.
4. Confirma la creacion del servicio `vmmusic-backend`.
5. Cuando termine, abre `https://<tu-servicio>.onrender.com/health`.

## Integración Flutter

```bash
flutter run \
  --dart-define=YT_RESOLVER_BASE_URL=https://<tu-servicio>.onrender.com \
  --dart-define=YT_RESOLVER_API_KEY=<tu_key_opcional> \
  --dart-define=STEMS_API_BASE_URL=https://<tu-servicio>.onrender.com \
  --dart-define=STEMS_API_KEY=<tu_key_opcional> \
  --dart-define=COVER_ANIMATION_API_BASE_URL=https://<tu-servicio>.onrender.com \
  --dart-define=COVER_ANIMATION_API_KEY=<tu_key_opcional>
```

## Notas

- El endpoint `/resolve` se mantiene compatible con tu app actual.
- `/resolve/batch` te ayuda para precargar colas o playlists.
- Para stems necesitas Python + `demucs` + `ffmpeg` en el servidor.
