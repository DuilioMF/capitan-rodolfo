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
- Versión actual del código: **84** (validación final contra la base SQL local pendiente)
- Web activa: `https://duiliomf.github.io/capitan-rodolfo/`
- Tarjeta operativa: `https://trello.com/c/Ju1hmWW9`

## Conexión

- Motor: **SQL Server**
- Conector local: `127.0.0.1:8787`
- Carpeta local objetivo: `C:\Sistemas\CapitanRodolfo`
- La contraseña no se guarda en GitHub.

## Archivos principales

- `index.html`: portada / Tablero Vivo.
- `nucleo.html`: centro de Datos e Inteligencia.
- `conexion-sql.html`: conexión SQL y selección de base.
- `mapa-vivo.html`: mapa operativo.
- `assets/`: recursos visuales.
- `bridge/`: conector local.

## Voz con OpenAI (revisión 48)

- La conversación usa OpenAI Realtime por WebRTC: micrófono continuo, respuesta de audio y transcripción visible.
- La clave estándar de OpenAI nunca se publica en GitHub ni se entrega al navegador. El conector local la cifra con la protección del usuario de Windows y crea credenciales efímeras.
- Configuración: iniciar/actualizar `CAPITAN_RODOLFO.bat`, abrir `Núcleo → Inteligencia` y guardar la clave API una sola vez.
- Rodolfo puede solicitar datos a la sesión SQL activa mediante `consultar_sql_lectura`. El conector solo acepta consultas que comiencen con `SELECT` o `WITH`, bloquea operaciones de escritura/administración y limita la salida a 50 filas.
- Para construir la estación visual, Rodolfo debe inspeccionar el esquema real (`sys.tables`, `sys.views`, `sys.columns`, relaciones y procedimientos), probar cada consulta y documentar la evidencia antes de afirmar el mapeo Tanque → Surtidor → Pico/Manguera → Despacho → Estado → Cobro → Forma de pago.
- El motor predeterminado es OpenAI; la interfaz entre voz, motor y herramientas queda separada para incorporar otros motores más adelante.
- `dist/`: versión publicable.
- `VERSION`: build actual.

## Seguridad

- No guardar contraseñas SQL en GitHub.
- SQL Server permanece detrás del conector local.
- No exponer credenciales en HTML ni JavaScript público.

## Versionado

Cada cambio debe quedar en un commit recuperable antes de publicar. Conservar rollback.

## Arquitectura de cuenta

- Una identidad Supabase por usuario.
- Un usuario puede tener acceso a varios especialistas.
- Los permisos de especialistas no dependen del proveedor de pagos.
- Cada especialista puede habilitar varios motores de IA y conservar uno predeterminado.

## Publicación vigente — 22/09/2026

GitHub es la fuente de código y GitHub Pages publica `main`. No usar copias de Sites como origen ni destino de navegación. Cada cambio se integra por PR y conserva su commit para rollback. Tema claro/oscuro compartido entre páginas; control arriba y regreso debajo.

## Visualización del SP (v84)

La vista Estación muestra directamente la respuesta de `dbo.PA_CapitanRodolfo_CircuitoEstacion`: tanques, caras/mangueras, despachos, relaciones con comprobantes y ParamStock de la estación seleccionada. También permite copiar el JSON real de los cinco conjuntos. El servicio local consulta `SiSRL` con la sesión guardada. Los datos reales sólo estarán disponibles si el equipo tiene SQL accesible, el SP instalado y los permisos adecuados. Ningún dato real se inventa desde GitHub Pages.

## Cobros v84

La relación para mostrar formas de pago por despacho usa `Despachos.ID_SALE` para ubicar la venta y obtiene `ID_DESPACHO` y `ULDATE`. Para adjudicar un comprobante exige `RelacionCptsDespachos.ID_DESPACHO` (o `DI_DESPACHO`) y `FECHA`, con coincidencia de ambas claves y estación. El botón Cobrado abre el comprobante verificado y, desde este, filtra los movimientos reales de `PA_VentasFormasPago` por letra, sucursal, número y fecha. No identifica por `ID_SALE` solo. Si falta relación o fecha, indica qué falta y no muestra importes de otras ventas. La validación con SQL local todavía debe ejecutarse en el equipo con permiso EXECUTE.

El código propio de Capitán aparece discretamente como `R·84`, leído de `VERSION`, al pie de la pantalla de inicio; DoingLio conserva su propia build D independiente.
