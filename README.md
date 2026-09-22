# Capitán Rodolfo

[![Abrir Capitán Rodolfo](https://img.shields.io/badge/▶%20ABRIR-CAPITÁN%20RODOLFO-ff6b35?style=for-the-badge)](https://duiliomf.github.io/capitan-rodolfo/)

[![Dominio Rodolfo](https://img.shields.io/badge/🌐%20RODOLFO-DOINGLIO.COM.AR-111111?style=for-the-badge)](https://rodolfo.doinglio.com.ar)

Centro de control visual de DoingLio para estaciones de servicio.

## Arranque rápido SQL

Descargá y ejecutá `INICIAR_CAPITAN_RODOLFO.bat`. El launcher actualiza el bridge desde GitHub, lo inicia en `127.0.0.1:8787` y abre la pantalla de conexión SQL automáticamente.

[Descargar INICIAR_CAPITAN_RODOLFO.bat](https://raw.githubusercontent.com/DuilioMF/capitan-rodolfo/main/INICIAR_CAPITAN_RODOLFO.bat)

## Estado verificable

- Build actual en GitHub: **36**.
- Repositorio: `DuilioMF/capitan-rodolfo`.
- Rama principal: `main`.
- Tarjeta operativa: https://trello.com/c/M87mZT1d
- Conexión SQL local: `DUILIO\\SQLEXPRESS` mediante bridge en `127.0.0.1:8787`.
- Nuevo dominio GitHub Pages: https://duiliomf.github.io/capitan-rodolfo/ (**activo**).
- Dominio DoingLio: https://rodolfo.doinglio.com.ar (**registrado en Trello; pendiente de verificación pública**).

> La **v18 está versionada en GitHub**, pero todavía **no está publicada en web**. El intento temporal con Supabase Edge Functions no sirve como hosting HTML porque el dominio compartido entrega HTML como texto.

## Flujo v19

1. **DoingLio** — pantalla inicial.
2. **Conexión SQL** — servidor, usuario, contraseña, selección de base y validación de tablas.
3. **Mapa Vivo** — se habilita únicamente cuando existe una sesión SQL válida y una base seleccionada.

## Proyecto

- `index.html`: pantalla inicial DoingLio.
- `conexion-sql.html`: conexión obligatoria, selección de base y listado de tablas.
- `mapa-vivo.html`: pantalla visual habilitada solo después de validar SQL.
- `assets/capitan-rodolfo-mapa-vivo.svg`: diseño del mapa vivo aprobado por Duilio.
- `dist/`: versión publicable.
- `bridge/`: bridge Python local para SQL Server.
- `connector-node/`: conector alternativo conservado para trazabilidad.

## Seguridad

- No se guardan contraseñas SQL en GitHub.
- La contraseña no queda escrita en el HTML.
- El bridge local mantiene SQL Server fuera de exposición directa a Internet.
- El Mapa Vivo valida la sesión SQL antes de mostrarse.

## Historial reciente

- **v14**: primera publicación verificada por Sites.
- **v15**: evolución visual de estación viva.
- **v16**: corrección del acceso al bridge local, prueba `127.0.0.1` / `localhost`, diagnóstico mejorado y botón 👁 / 🙈 en contraseña.
- **v19**: flujo obligatorio DoingLio → SQL → base validada → Mapa Vivo.
