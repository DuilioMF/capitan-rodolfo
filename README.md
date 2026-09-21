# Capitán Rodolfo v16

Aplicación de DoingLio para estaciones de servicio.

- Sitio previsto: `https://rodolfo.doinglio.com.ar`
- Portal principal previsto: `https://doinglio.com.ar`
- Repositorio: `DuilioMF/capitan-rodolfo`

Cambios de esta versión:

- La página inicial ya **no muestra ni pide conexión SQL**.
- La conexión quedó en **Configuración de datos** (`conexion-sql.html`).
- Versionado visible actualizado a **v16**.
- Se conserva `rodolfo.doinglio.com.ar` y se admiten los previews propios de DoingLio/Revalsoft IA para evitar `Failed to fetch`.
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


## v16

- La pantalla SQL prueba automáticamente 127.0.0.1:8787 y localhost:8787.
- Se agregó el botón **Probar bridge local** para habilitar/verificar el acceso local del navegador.
- Las solicitudes locales declaran targetAddressSpace=local cuando el navegador lo admite.
- El error diferencia bridge inaccesible de error SQL.
- La contraseña incorpora el botón 👁 / 🙈 para mostrar u ocultar, igual que RevalSoftIA.
