# Corrección de despachos por fecha de hoy

El error identificado el 27/09/2026 es que `dbo.PA_CapitanRodolfo_CircuitoEstacion` filtra por estación y opcionalmente `ESTADOVTA`, pero no filtra por `Despachos.ULDATE`. Por ello el tablero puede cargar 65 despachos históricos en lugar de los dos del día. El tope de 500 filas agrava el problema y tampoco debe mantenerse.

## Requisitos de la corrección

- Fecha predeterminada: día actual de SQL Server (`CONVERT(date, GETDATE())`), con parámetro opcional `@Fecha date` para futuras consultas históricas.
- Filtrar **despachos y sus relaciones con comprobantes** por la misma fecha de `Despachos.ULDATE`, usando un rango semiabierto `>= @Dia AND < DATEADD(day,1,@Dia)`.
- Conservar `@IdEstacion` como filtro obligatorio y `@EstadoVta` como filtro opcional. No fijar la cantidad de filas a 2: el total depende de las ventas reales del día.
- Quitar `TOP(@MaxDespachos)`, `TOP(@MaxRelaciones)` y los parámetros de máximos, sin limitar artificialmente resultados.
- Aplicar tanto a `sql/PA_CapitanRodolfo_CircuitoEstacion.sql` como a `sql/INSTALAR_Y_HABILITAR_CIRCUITO.sql`; el segundo es el instalador del conector local.
- Antes de ejecutar, garantizar existencia y tipo temporal de `ULDATE`. No comparar solamente hora `ULTIME`.
- No modificar ventas existentes, no suponer que hay exactamente dos despachos, no marcar funcional hasta ejecutar en la SiSRL real.

## Verificación en SQL Server

```sql
USE SiSRL;
DECLARE @Hoy date = CONVERT(date, GETDATE());
SELECT COUNT(*) AS DespachosHoy
FROM dbo.Despachos
WHERE ID_ESTACION = 1 -- reemplazar por la estación seleccionada
  AND ULDATE >= @Hoy
  AND ULDATE < DATEADD(day, 1, @Hoy);
EXEC dbo.PA_CapitanRodolfo_CircuitoEstacion @IdEstacion=1, @EstadoVta=NULL;
```

**Importante:** cambiar el ID 1 de ejemplo al de la estación seleccionada. Si aparecen diferencias, verificar zona horaria del servidor, tipo real de `ULDATE` y versión instalada del SP antes de dar por terminada la tarea.
