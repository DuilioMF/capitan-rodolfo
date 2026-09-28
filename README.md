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
- Versión actual del código: **94** (visibilidad de versión; la validación de Cobros con SiSRL real sigue pendiente)
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


## Antecedente v85 (obsoleto; corregido en v93)

Ese antecedente exigía erróneamente una segunda base. Desde v93, `dbo.PA_VentasFormasPago` y la evidencia MP/YPF usan la misma sesión autorizada de **SiSRL** que los despachos. Se preservan vínculos verificados de ID_DESPACHO y fecha, autorización de estación y comprobante. No se adjudican cobros si faltan datos. **Pendiente:** cotejar resultados contra la base SiSRL real en la PC antes de confirmar la prueba funcional.

## v86 — CAP-SQL-DISCOVERY

Tarjeta: https://trello.com/c/ZzeiPPPy. El conector residente expone GET `/api/discover-servers` para enumerar servicios SQL realmente instalados y registro de Windows. POST (botón explícito) consulta los anuncios SQL Browser de red con 6 segundos de límite, sin barridos de IP. Núcleo > Datos ofrece un selector de servidores detectados y conserva ingreso manual. La conexión guardada y su contraseña cifrada no se reemplazan automáticamente. La versión esperada de web y conector vuelve a coincidir: v86. La prueba de autenticación y selección de base en el equipo real permanece pendiente.

## v88 — Conexión de núcleos con DoingLio (27/09/2026)

- Núcleo muestra un tercer apartado **Conexión de núcleos**; **Datos** e **Inteligencia** mantienen sus conexiones sin cambios.
- Un conector local v88 descubre las estaciones reales mediante `GET /api/station/ids` / `ParamStock`; el administrador elige expresamente cuáles vincular a DoingLio y escribe su número WhatsApp completo.
- El nuevo módulo `bridge/doinglio_core_link.ps1` lee localmente el token protegido del trabajador y llama por HTTPS a la acción `link_installation` de `doinglio-sql-queue`. No expone el token al navegador ni toca las credenciales SQL guardadas.
- Supabase valida que el número ya sea administrador habilitado de `capitan-rodolfo`, registra un identificador de instalación y actualiza `doinglio_phone_access.station_ids` **únicamente después de la confirmación explícita**.
- La actualización requiere **ejecutar una vez** `CAPITAN_RODOLFO.bat` en la PC de la estación: descarga el módulo nuevo y arranca la versión 88 sin borrar las credenciales de Datos.
- Tras instalarlo: Capitán → Núcleo → Conexión de núcleos → Comprobar estado → elegir estaciones → ingresar WhatsApp → confirmar → Vincular con DoingLio. Estado final debe decir `Núcleo vinculado`.
- **Pendiente de prueba real:** instalación de v88 en la PC, registro con el teléfono autorizado, consulta de tanques por WhatsApp y validación de resultado SQL. La versión v88 incorpora el registro de una instalación administrativa; el enrutamiento universal entre múltiples instalaciones de distintos clientes todavía no está habilitado.

## v89 — Recuperación de SQL y Conexión de núcleos (27/09/2026)

Incidente: Núcleo en v88 apuntaba a una conexión SQL web v86, mientras que `dist/` aún guardaba componentes de v76. La comparación estricta de versión descartaba conectores SQL válidos, y la búsqueda secuencial de puertos podía demorar la interfaz.

- **Datos SQL:** `conexion-sql.html` admite conector compatible desde v86, revisa puertos en paralelo y prioriza los que ya tengan sesión SQL; no modifica el perfil existente. Incluye temas compartidos y enlaces de descarga corregidos.
- **Conexión de núcleos:** `nucleo.html` exige servicio local v89, descubre puertos en paralelo y muestra por separado si falla SQL, la credencial del trabajador o el descubrimiento de estaciones desde `ParamStock`. No da de alta estaciones automáticamente: el administrador selecciona las autorizadas.
- **Servicio local:** la ruta `/api/doinglio/status` informa SQL conectado aunque falle descubrir estaciones; el descubrimiento SQL tiene dos consultas de 7 s máximo. El instalador primero descarga todos los componentes, después cierra solamente sus procesos obsoletos conocidos y reinicia bridge y worker. Los downloads utilizan parámetro anti-caché.
- **Distribución:** HTML, temas, instalador y VERSION sincronizados con la raíz en v89. `dist/` referencia los recursos compartidos de la raíz para evitar duplicar pantallas antiguas.
- **Sin cambios** en `C:\Sistemas\DoingLio\data\capitan` ni en contraseñas SQL, autorizaciones históricas o claves de OpenAI.

**Validación pendiente en la PC:** ejecutar la descarga v89 desde Núcleo → Datos (una sola vez), esperar conector local v89 y base conectada, abrir Núcleo → Conexión de núcleos, seleccionar estaciones descubiertas y confirmar la vinculación con la cuenta de administrador. Solo entonces probar WhatsApp → consulta SQL → respuesta real. Los controles automáticos de sintaxis web y estructura no sustituyen esta prueba. Ver tarjeta https://trello.com/c/P9P2rXjv.

## v91 — Despachos por fecha en DoingLio (27/09/2026)

- Gateway WhatsApp v18: reconoce "despachos del 27/09/2026", "despachos de hoy", "despachos de ayer" y "cargas de hoy"; la fecha relativa usa zona horaria `America/Argentina/Buenos_Aires`, las fechas explícitas aceptan formato DD/MM/AAAA o AAAA-MM-DD. Sin fecha pregunta cuál consultar. Verifica teléfono y estación antes de encolar.
- Cola SQL v10: conserva el parámetro `fecha` al tomar y completar cada trabajo; la consulta por fecha no se confunde con otros días. El mensaje "resultado" consulta el último trabajo del teléfono autorizado, con fecha de solicitud y estado real; "actualizá" pide otra lectura.
- Conector local `POST /api/station/today-dispatches`: SQL parametrizado sobre `dbo.Despachos`, filtra `ULDATE >= fecha AND ULDATE < fecha+1` y estación real. Devuelve `COUNT_BIG(*)` sin límite artificial y muestra los últimos 5 registros ordenados por ULDATE, ULTIME (si existe) e ID_SALE; consulta de solo lectura.
- Trabajador SQL actualizado: maneja `today_dispatches` y `latest_dispatch`, solicita la lectura al conector de la PC y responde usando solamente registros devueltos por SQL; se reparó un archivo anterior con estructura rota.
- El instalador valida sintaxis PowerShell de los scripts descargados antes de reiniciar el servicio, sin borrar `C:\Sistemas\DoingLio\data\capitan`. Las pantallas y copia `dist/` muestran versión 91.
- **Prueba local pendiente:** ejecutar una vez `CAPITAN_RODOLFO.bat?v=91` en la PC que tiene SQL. Desde WhatsApp enviar "despachos del 27/09/2026 de la estación 1"; luego "resultado" unos segundos después. Verificar en cola `today_dispatches` y `answered` con metadatos `fecha`, y cotejar registros con SQL. No declarar E2E completo hasta validar esos datos reales.

## v93 — Cobros en SiSRL (28/09/2026)

Se eliminó el requisito de otra base en las rutas `/api/station/payments` y `/api/station/payment-evidence`. Ambas usan la sesión SQL activa de SiSRL, sin cambiar claves ni credenciales. Las fechas de Cobros se inicializan en `America/Argentina/Buenos_Aires` y se envían desde el formulario, sin días fijos. La búsqueda por ID_SALE utiliza la fecha verdadera del despacho verificado, aunque no sea la de hoy. Pendiente prueba funcional con la PC conectada.

## v94 — Identificación visible de cada ventana (28/09/2026)

El HTML de Inicio, Núcleo, Datos, Mapa Vivo y Lector identifica **su propia versión cargada**, y las siete ventanas superpuestas de Estación (Camión, Tanques, Surtidores, Carga, Producto, Comprobante y Cobros) muestran versión y estado del conector en el encabezado. `VERSION` remoto se usa solo para advertir sobre una publicación más reciente; nunca etiqueta una pantalla vieja como nueva. El indicador identifica la versión real devuelta por `/health`, informa si SQL está conectado, y pide actualizar cuando la versión del conector difiere de la pantalla. En todas las páginas se usa el mismo número canónico `VERSION`, con recursos web `?v=94` para evitar caché antigua. Esto no altera relaciones de cobros, credenciales ni contenido SQL. Para comprobar la instalación local, descargar y ejecutar el BAT desde Núcleo → Datos, y cotejar la conexión con `SiSRL`.
