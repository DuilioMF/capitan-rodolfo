/*
Comparación controlada: sin instalar ni modificar procedimientos ni índices.
Ejecutar en SSMS después de instalar PA_VentasFormasPago_OPT_PRUEBA.
Si el original tarda demasiado, comenzar con un turno y período pequeños.
Los resultados deben cotejarse en 14 columnas y por
letra + sucursal + NCOMPRO + turno, evitando mezclar estaciones.
*/
USE [SiSRL];
GO
SELECT @@VERSION AS VersionSQL;
SET STATISTICS IO ON;
SET STATISTICS TIME ON;
DECLARE @FechaDesde DATETIME, @FechaHasta DATETIME;
DECLARE @IdEstacion INT, @TurnoDesde INT, @TurnoHasta INT;
SET @FechaDesde='20260928';
SET @FechaHasta='20260928 23:59:59.997';
SET @IdEstacion=1;
SET @TurnoDesde=0; -- Reducir a un turno concreto si se conoce.
SET @TurnoHasta=99999;

PRINT '1 - Prueba del SP optimizado';
EXEC dbo.PA_VentasFormasPago_OPT_PRUEBA
  @FechaDesde=@FechaDesde, @FechaHasta=@FechaHasta,
  @IdEstacion=@IdEstacion, @TurnoDesde=@TurnoDesde,
  @TurnoHasta=@TurnoHasta, @VendedorDesde=0, @VendedorHasta=99999;

/* Descomentar después de verificar duración de la versión optimizada.
PRINT '2 - Comparación contra el SP original';
EXEC dbo.PA_VentasFormasPago
  @FechaDesde=@FechaDesde, @FechaHasta=@FechaHasta,
  @IdEstacion=@IdEstacion, @TurnoDesde=@TurnoDesde,
  @TurnoHasta=@TurnoHasta, @VendedorDesde=0, @VendedorHasta=99999;
*/
SET STATISTICS IO OFF;
SET STATISTICS TIME OFF;
