/*
TEST COMPARATIVO, SOLO LECTURA DE NEGOCIO
Optimización PA_VentasFormasPago en Maestros, fecha 21/09/2026, estación 1.
La candidata debe instalarse previamente con:
    sql/PA_VentasFormasPago_Optimizada_CANDIDATA.sql
No se modifica el procedimiento original.
*/
USE [Maestros];
GO
SET NOCOUNT ON;
SET STATISTICS IO ON;
SET STATISTICS TIME ON;

-- Las 14 columnas y su orden se mantienen en ambas versiones.
CREATE TABLE #Antes (
    letra NVARCHAR(10) NULL,
    sucursal NVARCHAR(30) NULL,
    NCOMPRO NVARCHAR(40) NULL,
    Turno NVARCHAR(30) NULL,
    MercadoPago DECIMAL(38,2) NULL,
    AppYPF DECIMAL(38,2) NULL,
    ShellBox DECIMAL(38,2) NULL,
    AppPuma DECIMAL(38,2) NULL,
    Clover DECIMAL(38,2) NULL,
    PayWay DECIMAL(38,2) NULL,
    Cheques DECIMAL(38,2) NULL,
    Efectivo DECIMAL(38,2) NULL,
    TOTAL DECIMAL(38,2) NULL,
    Vendedor NVARCHAR(500) NULL
);
SELECT TOP (0) * INTO #Despues FROM #Antes;

PRINT 'PRUEBA DE REFERENCIA: procedimiento original';
INSERT INTO #Antes
EXEC dbo.PA_VentasFormasPago '20260921','20260921',1,0,999,0,999;

PRINT 'PRUEBA DE CANDIDATA: prefiltrado + pasarelas independientes';
INSERT INTO #Despues
EXEC dbo.PA_VentasFormasPago_Optimizada '20260921','20260921',1,0,999,0,999;

SET STATISTICS IO OFF;
SET STATISTICS TIME OFF;

SELECT Origen, COUNT(*) Filas,
       SUM(ISNULL(TOTAL,0)) Total,
       SUM(ISNULL(MercadoPago,0)) MercadoPago,
       SUM(ISNULL(AppYPF,0)) AppYPF,
       SUM(ISNULL(ShellBox,0)) ShellBox,
       SUM(ISNULL(AppPuma,0)) AppPuma,
       SUM(ISNULL(Clover,0)) Clover,
       SUM(ISNULL(PayWay,0)) PayWay,
       SUM(ISNULL(Cheques,0)) Cheques,
       SUM(ISNULL(Efectivo,0)) Efectivo
FROM (
    SELECT 'ORIGINAL' AS Origen,* FROM #Antes
    UNION ALL
    SELECT 'OPTIMIZADA',* FROM #Despues
) D
GROUP BY Origen;

-- Reportar comprobantes con diferencias, incluso filas que desaparecen
-- cuando los LEFT JOIN antiguos multiplicaban dos pasarelas.
;WITH O AS (
    SELECT letra,sucursal,NCOMPRO,Turno,Vendedor,
           COUNT(*) Filas,SUM(ISNULL(TOTAL,0)) Total,
           SUM(ISNULL(MercadoPago,0)) MercadoPago,
           SUM(ISNULL(AppYPF,0)) AppYPF,
           SUM(ISNULL(AppPuma,0)) AppPuma,
           SUM(ISNULL(PayWay,0)) PayWay,
           SUM(ISNULL(Efectivo,0)) Efectivo
    FROM #Antes GROUP BY letra,sucursal,NCOMPRO,Turno,Vendedor
), N AS (
    SELECT letra,sucursal,NCOMPRO,Turno,Vendedor,
           COUNT(*) Filas,SUM(ISNULL(TOTAL,0)) Total,
           SUM(ISNULL(MercadoPago,0)) MercadoPago,
           SUM(ISNULL(AppYPF,0)) AppYPF,
           SUM(ISNULL(AppPuma,0)) AppPuma,
           SUM(ISNULL(PayWay,0)) PayWay,
           SUM(ISNULL(Efectivo,0)) Efectivo
    FROM #Despues GROUP BY letra,sucursal,NCOMPRO,Turno,Vendedor
)
SELECT COALESCE(O.letra,N.letra) letra,
       COALESCE(O.sucursal,N.sucursal) sucursal,
       COALESCE(O.NCOMPRO,N.NCOMPRO) NCOMPRO,
       COALESCE(O.Turno,N.Turno) Turno,
       COALESCE(O.Vendedor,N.Vendedor) Vendedor,
       O.Filas OriginalFilas,N.Filas OptimizadaFilas,
       O.Total OriginalTotal,N.Total OptimizadoTotal,
       O.MercadoPago OriginalMP,N.MercadoPago OptimizadoMP,
       O.AppYPF OriginalYPF,N.AppYPF OptimizadoYPF,
       O.Efectivo OriginalEfectivo,N.Efectivo OptimizadoEfectivo
FROM O FULL OUTER JOIN N
  ON O.letra=N.letra AND O.sucursal=N.sucursal
 AND O.NCOMPRO=N.NCOMPRO AND O.Turno=N.Turno
 AND O.Vendedor=N.Vendedor
WHERE ISNULL(O.Filas,-1)<>ISNULL(N.Filas,-1)
   OR ABS(ISNULL(O.Total,0)-ISNULL(N.Total,0))>0.01
   OR ABS(ISNULL(O.MercadoPago,0)-ISNULL(N.MercadoPago,0))>0.01
   OR ABS(ISNULL(O.AppYPF,0)-ISNULL(N.AppYPF,0))>0.01
   OR ABS(ISNULL(O.AppPuma,0)-ISNULL(N.AppPuma,0))>0.01
   OR ABS(ISNULL(O.PayWay,0)-ISNULL(N.PayWay,0))>0.01
   OR ABS(ISNULL(O.Efectivo,0)-ISNULL(N.Efectivo,0))>0.01
ORDER BY 1,2,3,4;

-- No crear índices a ciegas: mirar los ya existentes y planes reales.
SELECT T.name AS Tabla,I.name AS Indice,I.is_unique,
       IC.key_ordinal,C.name AS Columna
FROM sys.tables T
INNER JOIN sys.indexes I ON I.object_id=T.object_id
INNER JOIN sys.index_columns IC ON IC.object_id=I.object_id
                              AND IC.index_id=I.index_id
INNER JOIN sys.columns C ON C.object_id=IC.object_id
                        AND C.column_id=IC.column_id
WHERE T.name IN (
  'MaeFac','MaeTic','MP_OrdenPagoComprobante','YPF_PaymentIntentionComprobante',
  'Shell_PayOrderComprobante','PUMA_PaymentComprobante',
  'Clover_PaymentInvoices','Tarjet','Maeven'
)
ORDER BY T.name,I.name,IC.key_ordinal;
GO
