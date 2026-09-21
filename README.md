# Capitán Rodolfo v15

Aplicación de DoingLio para estaciones de servicio.

- Sitio previsto: `https://rodolfo.doinglio.com.ar`
- Portal principal previsto: `https://doinglio.com.ar`
- Repositorio: `DuilioMF/capitan-rodolfo`

Cambios de esta versión:

- Se incorporó **Estación Viva**: recorrido energético animado, activación secuencial del circuito, niveles de tanques, surtidor, auto, cobro y KPIs en movimiento.
- Se respetan las preferencias de movimiento reducido del dispositivo.
- Se autorizó el dominio publicado de Capitán Rodolfo en el bridge local y se mejoró el diagnóstico de conexión.
- La página inicial ya **no muestra ni pide conexión SQL**.
- La conexión quedó en **Configuración de datos** (`conexion-sql.html`).
- Se agregó versionado visible: **v14**.
- Se agregó `rodolfo.doinglio.com.ar` como origen autorizado.
- Se recuerdan servidor y usuario SQL en el equipo; la contraseña nunca se guarda.
- Servidor sugerido: `DUILIO\SQLEXPRESS`.
- El bridge local usa `Encrypt=yes;TrustServerCertificate=yes`.
- La contraseña no está escrita en el HTML.

## Probar la conexión real

1. En Windows, abrir `bridge\iniciar_bridge.bat`.
2. Dejar esa ventana abierta.
3. Abrir `conexion-sql.html`.
4. Completar usuario y contraseña SQL.
5. Presionar **Conectar y ver bases**.
6. Elegir una base para listar sus tablas.

El bridge escucha únicamente en `127.0.0.1:8787`, por lo que no expone SQL Server directamente a Internet.

## Estructura

- `index.html`: tablero visual de Capitán Rodolfo.
- `conexion-sql.html`: configuración, selección de base y listado de tablas.
- `bridge/`: conector local principal para Windows y SQL Server.
- `connector-node/`: conector alternativo conservado para trazabilidad; no es el conector que usa actualmente la página.

## Seguridad

- No se versionan usuarios, contraseñas ni cadenas de conexión.
- SQL Server permanece detrás del bridge local.
- La contraseña vive solamente durante la sesión del bridge.
- Antes de usarlo fuera de una red controlada debe agregarse autenticación entre la página y el bridge.
