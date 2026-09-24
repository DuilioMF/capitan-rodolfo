# SP del circuito de estación (Capitán Rodolfo v69)

**Archivo para SQL Server:** [PA_CapitanRodolfo_CircuitoEstacion.sql](PA_CapitanRodolfo_CircuitoEstacion.sql)

## Instalación

1. En la PC con SQL Server, abrí **SQL Server Management Studio** y conectate a `DUILIO\\SQLEXPRESS`.
2. Abrí el archivo `.sql`. Confirmá que la línea `USE [SiSRL]` corresponde a tu base (respetá el nombre real).
3. Ejecutá todo el script. Solo crea o actualiza **`dbo.PA_CapitanRodolfo_CircuitoEstacion`**; no modifica registros de negocio.
4. Para probar, reemplazá el ID por el de tu estación:
   ```sql
   EXEC dbo.PA_CapitanRodolfo_CircuitoEstacion
     @IdEstacion = 1,
     @EstadoVta = NULL;  -- todos los despachos
   ```
   Si querés solo despachos pendientes, pasá `@EstadoVta = 0`; cobrados, `1`.
5. Confirmá que se devuelvan **cuatro resultados**: tanques, mangueras/caras, despachos y relación con comprobantes. Guardá únicamente errores y nombres de columnas; **nunca compartas credenciales**.

El SP acepta `@MaxDespachos` (500 por defecto) y `@MaxRelaciones` (1000 por defecto), con un máximo de 10000 para cada uno.

## Validaciones

- Filtra por estación y une `Prod` por `CODART` y también por estación cuando existe esa columna.
- Detecta variantes declaradas en la conversación: `ID_ESTACION`/`ID_ESTAICION`, `CAPACIDAD`/`CAPAIDAD`, `DESCRIART`/`DESCRIIMPRESION`.
- **No inventa** la relación comprobante–despacho. Busca una clave de nombre coincidente `ID_DESPACHO`, `ID_DESPCHO` o `ID_SALE`. Si no existe y no puede filtrar la tabla de relaciones por estación, devuelve un error explicativo.
- Solo calcula `Isla = (Cara + 1) / 2` si las caras se numeran consecutivamente 1–2, 3–4, etc. Verificar esa convención con la estación real.
- Si faltan claves o una manguera es ambigua entre estaciones, devuelve error en lugar de mezclar datos.

Para encontrar columnas que no coinciden:

```sql
SELECT t.name AS Tabla, c.name AS Columna,
       TYPE_NAME(c.user_type_id) AS Tipo
FROM sys.tables t
JOIN sys.columns c ON c.object_id = t.object_id
WHERE t.name IN ('Tanque','Prod','Surpla','Surtan',
                 'Despachos','RelacionCptsDespachos')
ORDER BY t.name,c.column_id;
```

## Integración con Núcleo

El repositorio de Capitán v69 incluye el SP en la lista predeterminada de procedimientos permitidos, **sin sacar** `dbo.PA_VentasFormasPago`. El conector reconoce esa autorización al actualizar desde el acceso del cerebro. El SP aparece en Núcleo → Datos **cuando ya esté creado en SQL Server**.

La visualización actual de tanques/surtidores todavía usa sus consultas existentes. Con los cuatro resultados del SP ya confirmados en `SiSRL`, se puede conectar esa visualización al SP sin suponer relaciones incorrectas.

**Estado de verificación:** archivo generado y guardado en GitHub. La ejecución sobre tu SQL Server local requiere que lo despliegues y pruebes allí.
