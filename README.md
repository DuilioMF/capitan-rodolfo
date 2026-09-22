# Capitán Rodolfo

[![Ver Trello](https://img.shields.io/badge/VER-TRELLO-0052CC?style=for-the-badge)](https://trello.com/c/M87mZT1d)
[![Abrir Capitán Rodolfo](https://img.shields.io/badge/▶%20ABRIR-CAPITÁN%20RODOLFO-ff6b35?style=for-the-badge)](https://capitan-rodolfo.revalsoftia.chatgpt.site/)
[![Volver a DoingLio](https://img.shields.io/badge/←%20VOLVER-DOINGLIO-111111?style=for-the-badge)](https://doinglio.revalsoftia.chatgpt.site/)

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
- Site activo: `https://capitan-rodolfo.revalsoftia.chatgpt.site/`
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
