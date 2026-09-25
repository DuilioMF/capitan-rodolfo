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
