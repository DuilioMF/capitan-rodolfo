# Capitán Rodolfo

<p align="center"><img src="brain-davinci.svg" width="86" alt="Icono cerebro Da Vinci"></p>

[![Ver Trello](https://img.shields.io/badge/VER-TRELLO-0052CC?style=for-the-badge)](https://trello.com/c/Ju1hmWW9)
[![Abrir Capitán Rodolfo](https://img.shields.io/badge/▶%20ABRIR-CAPITÁN%20RODOLFO-ff6b35?style=for-the-badge)](https://duiliomf.github.io/capitan-rodolfo/)
[![Volver a DoingLio](https://img.shields.io/badge/←%20VOLVER-DOINGLIO-111111?style=for-the-badge)](https://duiliomf.github.io/doinglio/)

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
- Fuente actual: build **38**
- Web activa: `https://duiliomf.github.io/capitan-rodolfo/`
- Tarjeta operativa: `https://trello.com/c/Ju1hmWW9`

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

## Publicación vigente — 22/09/2026

GitHub es la fuente de código y GitHub Pages publica `main`. No usar copias de Sites como origen ni destino de navegación. Cada cambio se integra por PR y conserva su commit para rollback. Tema claro/oscuro compartido entre páginas; control arriba y regreso debajo.
