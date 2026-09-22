# Capitán Rodolfo

[![Abrir Capitán Rodolfo](https://img.shields.io/badge/▶%20ABRIR-CAPITÁN%20RODOLFO-ff6b35?style=for-the-badge)](https://duiliomf.github.io/capitan-rodolfo/)

## Qué es

Especialista de DoingLio para estaciones de servicio. Tablero Vivo con estética Da Vinci para combustible → despacho → venta → cobro.

## Rol en DoingLio

- Se abre desde DoingLio.
- Vive en su repositorio independiente.
- Usa SQL Server mediante un conector local.
- Debe conservar el botón **← Volver a DoingLio**.

## Estado

- Repositorio: `DuilioMF/capitan-rodolfo`
- Rama principal: `main`
- Fuente actual: build **37**
- GitHub Pages: `https://duiliomf.github.io/capitan-rodolfo/`
- Site histórico de referencia visual: `https://capitan-rodolfo.revalsoftia.chatgpt.site/`
- Tarjeta operativa: `https://trello.com/c/M87mZT1d`

## Conexión

- Motor: **SQL Server**
- Conector local: `127.0.0.1:8787`
- Carpeta local objetivo: `C:\Sistemas\CapitanRodolfo`
- La contraseña no se guarda en GitHub.

## Archivos principales

- `index.html`: portada / Tablero Vivo.
- `conexion-sql.html`: conexión SQL y selección de base.
- `mapa-vivo.html`: mapa operativo.
- `assets/`: recursos visuales.
- `bridge/`: conector local.
- `dist/`: versión publicable.
- `VERSION`: build actual.

## Seguridad

- No guardar contraseñas SQL en GitHub.
- SQL Server permanece detrás del conector local.
- No exponer credenciales en HTML ni JavaScript público.

## Versionado

Cada cambio debe quedar en un commit recuperable antes de publicar. Conservar rollback.
