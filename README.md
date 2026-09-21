# Capitán Rodolfo

[![Abrir Capitán Rodolfo](https://img.shields.io/badge/▶%20ABRIR-Capitán%20Rodolfo-ff6b35?style=for-the-badge)](https://apqgrwudkfytwikrsivd.supabase.co/functions/v1/capitan-rodolfo-v16)

Centro de control visual de DoingLio para estaciones de servicio.

## Estado verificable

- Versión actual en GitHub: **v16**.
- Repositorio: `DuilioMF/capitan-rodolfo`.
- Rama principal: `main`.
- Tarjeta operativa: https://trello.com/c/M87mZT1d
- Conexión SQL local: `DUILIO\\SQLEXPRESS` mediante bridge en `127.0.0.1:8787`.
- URL web de prueba v16: https://apqgrwudkfytwikrsivd.supabase.co/functions/v1/capitan-rodolfo-v16
- Dominio objetivo: https://rodolfo.doinglio.com.ar

> La v16 está versionada en GitHub. La publicación definitiva en el dominio objetivo todavía requiere verificación final desde tu PC.

## Cómo abrir

1. Entrá a este repositorio.
2. Arriba del README vas a ver el botón **ABRIR CAPITÁN RODOLFO**.
3. Para usar SQL Server local, primero ejecutá `bridge/iniciar_bridge.bat`.
4. Después entrá en **Configuración de datos** y probá el bridge.

## Proyecto

- `index.html`: tablero visual.
- `conexion-sql.html`: conexión, selección de base y listado de tablas.
- `dist/`: versión publicable.
- `bridge/`: bridge Python local para SQL Server.
- `connector-node/`: conector alternativo conservado para trazabilidad.

## Seguridad

- No se guardan contraseñas SQL en GitHub.
- La contraseña no queda escrita en el HTML.
- El bridge local mantiene SQL Server fuera de exposición directa a Internet.

## Historial reciente

- **v14**: primera publicación verificada por Sites.
- **v15**: evolución visual de estación viva.
- **v16**: corrección del acceso al bridge local, prueba `127.0.0.1` / `localhost`, diagnóstico mejorado y botón 👁 / 🙈 en contraseña.
