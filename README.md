# myapp

## Backend para reproduccion de videos

Este proyecto incluye un backend en `backend/` para resolver streams de YouTube y soportar funciones AI auxiliares.

Endpoints principales:

- `GET /health`
- `GET /resolve?videoId=<youtube_video_id>`
- `POST /resolve/batch`
- `GET /info?videoId=<youtube_video_id>`
- `POST /stems/separate`
- `POST /cover/animate`

### Ejecutar backend local

```bash
cd backend
npm install
npm start
```

Por defecto corre en `http://localhost:10000`.

### Conectar Flutter al backend

```bash
flutter run \
  --dart-define=YT_RESOLVER_BASE_URL=http://localhost:10000 \
  --dart-define=YT_RESOLVER_API_KEY=
```

Si configuras `RESOLVER_API_KEY` en el backend, envia el mismo valor en `YT_RESOLVER_API_KEY`.

### Variables sugeridas

Revisa `backend/.env.example` para una plantilla de configuracion (API key, CORS, cache, stems, cover animation).

### Publicarlo en linea con Render

Este repo ya trae `render.yaml`. Publica asi:

1. Sube este proyecto a GitHub.
2. En Render crea `New` -> `Blueprint`.
3. Conecta tu repo y confirma el servicio.
4. Verifica con `https://<tu-servicio>.onrender.com/health`.

## Notas

- La app usa `/resolve` para fallback de reproduccion.
- `/resolve/batch` sirve para precarga de cola.
