/*
SiSRL / Capitán Rodolfo — Fase 1: índice de tarjetas.
Ejecutar SOLO fuera de horas pico. No cambia datos ni SP de producción.
La primera medición (28/09/2026) mostró 1.168.716 lecturas lógicas en Tarjet.
Antes de aplicar: comprobar que no haya mantenimiento de base en curso.
*/
USE SiSRL;
GO
SET NOCOUNT ON;
IF OBJECT_ID(N'dbo.Tarjet',N'U') IS NULL
BEGIN
  RAISERROR('No existe dbo.Tarjet en SiSRL. No se aplico ningun cambio.',16,1);
  RETURN;
END;
IF COL_LENGTH(N'dbo.Tarjet',N'Letra') IS NULL
  OR COL_LENGTH(N'dbo.Tarjet',N'Sucursal') IS NULL
  OR COL_LENGTH(N'dbo.Tarjet',N'NFACT') IS NULL
  OR COL_LENGTH(N'dbo.Tarjet',N'IMPORTETAR') IS NULL
  OR COL_LENGTH(N'dbo.Tarjet',N'Extraccion') IS NULL
BEGIN
  RAISERROR('Falta alguna columna de Tarjet. Verificar esquema antes de aplicar.',16,1);
  RETURN;
END;
IF NOT EXISTS (SELECT 1 FROM sys.indexes
  WHERE object_id=OBJECT_ID(N'dbo.Tarjet')
  AND name=N'IX_Tarjet_Cobros_Comprobante')
BEGIN
  PRINT 'Creando indice IX_Tarjet_Cobros_Comprobante ...';
  CREATE NONCLUSTERED INDEX IX_Tarjet_Cobros_Comprobante
    ON dbo.Tarjet (Letra, Sucursal, NFACT)
    INCLUDE (IMPORTETAR, Extraccion);
  PRINT 'Indice Tarjet creado.';
END
ELSE
  PRINT 'Indice Tarjet ya existe; no se duplica.';
GO
SELECT OBJECT_NAME(object_id) AS Tabla,name AS Indice
FROM sys.indexes
WHERE object_id=OBJECT_ID(N'dbo.Tarjet')
  AND name=N'IX_Tarjet_Cobros_Comprobante';
