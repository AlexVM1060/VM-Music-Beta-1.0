# Blueprint de la Aplicación de Reproducción de Vídeos

## Descripción General

Esta aplicación es un reproductor de vídeo avanzado para Flutter, diseñado para ofrecer una experiencia de usuario fluida y rica en funciones. Permite a los usuarios buscar y reproducir vídeos de YouTube, gestionar su historial de reproducción, crear playlists personalizadas y descargar vídeos para verlos sin conexión. La aplicación está construida con un enfoque en la modularidad y el rendimiento, utilizando componentes modernos y una arquitectura de estado bien definida.

## Características Principales

### 1. Búsqueda y Reproducción de Vídeos
- **Búsqueda en YouTube:** Los usuarios pueden buscar cualquier vídeo en YouTube por título o palabras clave.
- **Reproducción Fluida:** El reproductor de vídeo integrado (basado en `chewie` y `video_player`) ofrece una reproducción de alta calidad.
- **Calidad de Vídeo Ajustable:** Los usuarios pueden cambiar la calidad del vídeo sobre la marcha.
- **Reproducción en Segundo Plano:** El audio de los vídeos puede seguir reproduciéndose en segundo plano, permitiendo a los usuarios realizar otras tareas en su dispositivo.

### 2. Gestión de Historial y Playlists
- **Historial de Reproducción:** La aplicación guarda automáticamente un historial de todos los vídeos vistos, facilitando el acceso a contenido previo.
- **Creación de Playlists:** Los usuarios pueden crear un número ilimitado de playlists personalizadas.
- **Playlist de "Favoritos":** Un botón de "Me gusta" permite añadir vídeos a una playlist especial de "Videos favoritos".
- **Gestión de Contenido:** Es posible añadir o eliminar vídeos de las playlists en cualquier momento.

### 3. Funcionalidades Avanzadas
- **Modo Picture-in-Picture (PiP):** El reproductor de vídeo puede minimizarse a una pequeña ventana flotante, permitiendo la navegación por otras partes de la aplicación sin interrumpir la reproducción.
- **Descarga de Vídeos:** Los vídeos pueden descargarse para su visualización sin conexión, con un gestor que muestra el progreso de la descarga.
- **Tema Oscuro y Claro:** La aplicación es compatible con los modos de tema del sistema, y también permite al usuario cambiar manualmente entre un tema claro y oscuro.

## Diseño y Estructura

### Arquitectura
- **Gestión de Estado:** La aplicación utiliza `provider` para la gestión del estado, lo que garantiza una separación clara entre la lógica de negocio y la interfaz de usuario.
- **Servicios Modulares:** La lógica se organiza en servicios (`HistoryService`, `PlaylistService`, `DownloadService`), lo que facilita el mantenimiento y las pruebas.
- **Navegación con `go_router`:** Se utiliza `go_router` para gestionar la navegación de forma declarativa, lo que permite rutas limpias y una gestión sencilla del estado de la navegación.

### Estructura de Archivos
```
lib/
├── models/           # Modelos de datos (Video, Playlist, etc.)
├── services/         # Lógica de negocio (History, Playlist, etc.)
├── pages/            # Pantallas principales de la aplicación
├── widgets/          # Widgets reutilizables
├── main.dart         # Punto de entrada de la aplicación
└── router.dart       # Configuración de rutas con go_router
```

### Almacenamiento Local
- **Hive:** Se utiliza `Hive` para el almacenamiento local de datos estructurados como el historial y las playlists. Es una base de datos NoSQL rápida y ligera, ideal para aplicaciones móviles.

## Plan de Desarrollo Futuro

- **Sincronización en la Nube:** Integración con un servicio en la nube (como Firebase) para sincronizar el historial y las playlists entre dispositivos.
- **Recomendaciones Personalizadas:** Implementación de un sistema de recomendaciones basado en el historial de reproducción del usuario.
- **Soporte para Más Plataformas:** Adaptación de la interfaz para tabletas y ordenadores de escritorio.
