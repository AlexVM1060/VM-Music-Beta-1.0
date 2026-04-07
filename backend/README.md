# VMMusic YouTube Resolver (Render)

Backend de fallback para resolver URLs de audio/video cuando YouTube limita solicitudes directas desde el iPhone.

## Endpoint

- `GET /health`
- `GET /resolve?videoId=<youtube_video_id>`

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
6. Deploy.
7. Prueba:
   - `https://<tu-servicio>.onrender.com/health`
   - `https://<tu-servicio>.onrender.com/resolve?videoId=dQw4w9WgXcQ`

## Integración Flutter

Ejecuta la app con:

```bash
flutter run \
  --dart-define=YT_RESOLVER_BASE_URL=https://<tu-servicio>.onrender.com \
  --dart-define=YT_RESOLVER_API_KEY=<tu_key_opcional>
```

> Si no usas `RESOLVER_API_KEY` en Render, omite `YT_RESOLVER_API_KEY`.
