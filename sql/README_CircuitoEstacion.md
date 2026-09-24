# Capitán Rodolfo — circuito v81

**SP:** [PA_CapitanRodolfo_CircuitoEstacion.sql](PA_CapitanRodolfo_CircuitoEstacion.sql)  
**Instalador para administrador:** [INSTALAR_Y_HABILITAR_CIRCUITO.sql](INSTALAR_Y_HABILITAR_CIRCUITO.sql)

Se actualiza automáticamente al abrir DoingLio desde el cerebro **solo cuando
el usuario SQL configurado posee los permisos correspondientes**. Desde
**Capitán → Núcleo → Datos** también se puede instalar o ejecutar el SP
manualmente sin abrir SSMS. Si faltan permisos, puede usarse una cuenta
administradora temporal desde la página, sin guardarla, o el archivo del
instalador en SSMS.

Los cinco resultados mantienen este orden, necesario para versiones anteriores:

1. **Tanques:** NTanque, Denominacion, Producto, Capacidad, Litros opcionales,
   Costo = PRECOMPRA y Precio = PRECIOCONIVA + IMPUESTOS + TasaOtrosImpue
   cuando esos campos existen en Prod.
2. **Surtidores:** Cara, Isla = (Cara+1)/2, Manguera, Producto, Costo, Precio,
   NTanque, Tanque, Controlador.
   Cuando se puede identificar una clave entre Surpla.CONTROLADOR y
   MP_TipoConexion, el nombre procede de MP_TipoConexion.Name. En otro
   caso queda el código sin inventar la asociación. La relación Surtan y
   Tanque está filtrada por estación y se detiene ante ambigüedades.
3. **Carga/Despachos:** IdSale, Isla, Cara, Manguera, Producto, Costo,
   PrecioProducto, Litros, PPU, Pesos, EstadoVta y Hora (desde ULTIME).
   EstadoVta 1 indica cobrado; 0 indica pendiente.
4. **Relación comprobante–despacho:** Venta, Letra, Sucursal, Numero y Turno.
   Se prioriza el vínculo documentado DI_DESPACHO -> ID_SALE si ambas
   columnas existen. Los nombres de comprobante se detectan mediante los
   metadatos de la base; Turno puede obtenerse de MaeFac solamente si
   letra, sucursal, número y estación permiten una relación inequívoca.
5. **Empresa / estación:** ParamStock filtrado por @IdEstacion.

La pantalla presenta solamente columnas operativas. Se puede tocar un
producto para ver costo y precio; un tanque para abrir Tanques; una isla,
cara o manguera para ir a Surtidores; y una venta cobrada para ver
su comprobante. Las filas no asociadas nunca se adjudican por suposición.

**Si el usuario no puede ejecutar el SP**, Capitán intenta consultar
directamente las tablas autorizadas en modo lectura, validando estación y
unicidad del producto y de las mangueras. Algunos datos relacionados pueden
no estar disponibles hasta habilitar el SP. Nunca se inventan filas.

**Instalación de una sola vez, si falta el permiso EXECUTE:** conectate
como administrador en Núcleo → Datos, o ejecutá el instalador enlazado
arriba en SQL Server Management Studio. La clave del administrador no se
guarda. El SP se ejecuta con `WITH EXECUTE AS OWNER`; su propietario debe
tener los permisos de lectura necesarios. No se requieren permisos
`db_owner` para el usuario habitual.

**Prueba real antes de dar por terminado:**

```sql
USE SiSRL;
EXEC dbo.PA_CapitanRodolfo_CircuitoEstacion @IdEstacion=1,@EstadoVta=NULL;
```

Las pruebas automatizadas verifican sintaxis e integración sin conectarse a
la instancia privada `DUILIO\SQLEXPRESS`. Es necesario confirmar la
ejecución y las relaciones de comprobantes y controladores en esa base.

## v74: error SELECT permission was denied

Si el usuario configurado en Núcleo no tiene SELECT en dbo.Tanque,
la prueba directa `SELECT * FROM dbo.Tanque` seguirá fallando.
El SP de circuito usa `WITH EXECUTE AS OWNER`; el propietario debe disponer
de los permisos de lectura sobre las tablas utilizadas. Un administrador
debe conceder al usuario de la aplicación `EXECUTE` únicamente sobre el SP.

Ejecutá [`DIAGNOSTICO_PERMISOS_CircuitoEstacion.sql`](DIAGNOSTICO_PERMISOS_CircuitoEstacion.sql)
con las credenciales de Núcleo para identificar `UsuarioBase` y los permisos
existentes. El archivo contiene ejemplos de GRANT comentados para un DBA.
No asumas que `UsuarioBase` coincide exactamente con el nombre del login.

No se considera probada la ejecución hasta correrla en `SiSRL` real.
