/*
 CAPITAN RODOLFO v84 - PRUEBA DE SOLO LECTURA EN SiSRL.
 Comparar el segundo resultado con la consulta original de Duilio.
 No ejecutar actualizaciones ni modificar datos.
*/
USE [SiSRL];
GO
DECLARE @IdSale INT = 1293;

SELECT d.ID_SALE, d.ULDATE, d.ID_DESPACHO, d.ESTADOVTA
FROM dbo.Despachos d
WHERE d.ID_SALE=@IdSale;

-- Esta consulta debe devolver exactamente las mismas relaciones que la
-- expresión con las dos subconsultas escalares (si ID_SALE es único).
SELECT r.*
FROM dbo.RelacionCptsDespachos r
INNER JOIN dbo.Despachos d
  ON r.FECHA=d.ULDATE AND r.ID_DESPACHO=d.ID_DESPACHO
WHERE d.ID_SALE=@IdSale;

-- Control de ambigüedad del registro de despacho.
SELECT COUNT(*) AS CantidadDeDespachosParaIdSale
FROM dbo.Despachos WHERE ID_SALE=@IdSale;
GO

-- Firma REAL de PA_VentasFormasPago; confirmar qué representan los
-- parámetros 4 a 7 antes de permitir filtros nuevos en la pantalla.
SELECT p.parameter_id, p.name AS Parametro, TYPE_NAME(p.user_type_id) AS Tipo
FROM sys.parameters p
WHERE p.object_id=OBJECT_ID(N'dbo.PA_VentasFormasPago',N'P')
ORDER BY p.parameter_id;

-- Reproducir los siete argumentos brindados por Duilio.
EXEC dbo.PA_VentasFormasPago '20260921','20260921',1,0,999,0,999;
