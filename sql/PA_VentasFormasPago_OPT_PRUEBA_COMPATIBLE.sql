/*
 Capitán Rodolfo - propuesta de optimización de PA_VentasFormasPago
 Base CONFIRMADA por captura del 25/09/2026: SiSRL.
 IMPORTANTE: procedimiento separado de pruebas; NO sustituye producción.
 No ejecutado contra SiSRL: verificar importes y plan de ejecución antes de instalar.
 Puntos conservados del SP entregado:
  - los 7 parámetros y las 14 columnas finales (orden/nombres)
  - Shell: TotalAmount (facturas y tickets)
  - Puma mostrado neto (TotalTransaction-Discounts), descontado bruto del efectivo
  - condición de venta 2 => efectivo 0 en facturas
  - los cheques NO se descuentan de efectivo, igual que el original (REVISAR regla)
 Cambios deliberados:
  - agregar cada medio por comprobante antes de combinarlos, para evitar multiplicaciones
  - en tickets conservar el filtro Tipo='TICKET' del procedimiento original
  - aplicar primero filtros de documentos de la estación, fecha, turno y vendedor
*/
USE [SiSRL];
GO
-- Compatible con SQL Server anterior a 2016 SP1.
-- Crea solo el procedimiento de prueba si no existe, no altera producción.
IF OBJECT_ID(N'dbo.PA_VentasFormasPago_OPT_PRUEBA', N'P') IS NULL
    EXEC(N'CREATE PROCEDURE dbo.PA_VentasFormasPago_OPT_PRUEBA AS BEGIN SET NOCOUNT ON; END');
GO
ALTER PROCEDURE dbo.PA_VentasFormasPago_OPT_PRUEBA
(
 @FechaDesde DATETIME,
 @FechaHasta DATETIME,
 @IdEstacion INT,
 @TurnoDesde INT,
 @TurnoHasta INT,
 @VendedorDesde INT = 0,
 @VendedorHasta INT = 99999
)
AS
BEGIN
 SET NOCOUNT ON;

 -- Evita rangos invertidos. El límite superior respeta exactamente el SP original.
 IF @FechaHasta < @FechaDesde OR @TurnoHasta < @TurnoDesde
    OR @VendedorHasta < @VendedorDesde
 BEGIN
    RAISERROR('Intervalo de fechas, turnos o vendedores invalido.', 16, 1);
   RETURN;
 END;

 ;WITH Documentos AS
 (
    SELECT CAST('F' AS CHAR(1)) AS Origen,
           M.LETRA AS Letra, M.SUCURSAL AS Sucursal, M.NCOMPRO AS NCOMPRO,
           M.TURNO AS Turno, M.TOTAL AS Total, M.CHEQUES AS Cheques,
           M.CONDVTA AS CondVta, M.VENDEDOR AS CodigoVendedor
    FROM dbo.Maefac AS M
    WHERE M.FECHA BETWEEN @FechaDesde AND @FechaHasta
      AND M.ID_ESTACION = @IdEstacion
      AND M.TURNO BETWEEN @TurnoDesde AND @TurnoHasta
      AND (M.VENDEDOR BETWEEN @VendedorDesde AND @VendedorHasta
           OR (M.VENDEDOR IS NULL AND @VendedorDesde <= 0 AND @VendedorHasta >= 0))

    UNION ALL

    SELECT CAST('T' AS CHAR(1)) AS Origen,
           'T' AS Letra, MT.Sucursal, MT.Numero AS NCOMPRO,
           MT.TURNO AS Turno, SUM(MT.TOTAL) AS Total,
           0 AS Cheques, NULL AS CondVta, MT.VENDEDOR AS CodigoVendedor
    FROM dbo.Maetic AS MT
    WHERE MT.FECHA BETWEEN @FechaDesde AND @FechaHasta
      AND MT.ID_ESTACION = @IdEstacion
      AND MT.TURNO BETWEEN @TurnoDesde AND @TurnoHasta
      AND (MT.VENDEDOR BETWEEN @VendedorDesde AND @VendedorHasta
           OR (MT.VENDEDOR IS NULL AND @VendedorDesde <= 0 AND @VendedorHasta >= 0))
    GROUP BY MT.Sucursal, MT.Numero, MT.Turno, MT.Vendedor
 ),
 Pagos AS
 (
    SELECT D.Origen, D.Letra, D.Sucursal, D.NCOMPRO, D.Turno,
           D.Total, D.Cheques, D.CondVta, D.CodigoVendedor,
           ISNULL(ROUND(MP.Importe,2),0) AS MercadoPago,
           ISNULL(ROUND(YP.Importe,2),0) AS AppYPF,
           ISNULL(ROUND(SH.Importe,2),0) AS ShellBox,
           ISNULL(ROUND(PU.ImporteBruto - PU.Descuentos,2),0) AS AppPuma,
           ISNULL(ROUND(CL.Importe,2),0) AS Clover,
           ISNULL(ROUND(TJ.Importe - TJ.Extraccion,2),0) AS PayWay,
           -- Igual que el original: efectivo descuenta importe BRUTO Puma.
           ISNULL(ROUND(PU.ImporteBruto,2),0) AS PumaBruto
    FROM Documentos AS D

    OUTER APPLY (
       SELECT SUM(O.amount) AS Importe
       FROM dbo.MP_OrdenPagoComprobante AS L
       INNER JOIN dbo.MP_OrdenPago AS O ON O.ID = L.ID_OrdenPago
       WHERE L.Sucursal = D.Sucursal AND L.Numero = D.NCOMPRO
         AND (D.Origen='F' AND L.Letra=D.Letra
              OR D.Origen='T' AND L.Tipo='TICKET')
    ) AS MP
    OUTER APPLY (
       SELECT SUM(P.amount) AS Importe
       FROM dbo.YPF_PaymentIntentionComprobante AS L
       INNER JOIN dbo.YPF_PaymentIntention AS P ON P.ID=L.ID_PaymentIntention
       WHERE L.Sucursal=D.Sucursal AND L.Numero=D.NCOMPRO
         AND (D.Origen='F' AND L.Letra=D.Letra
              OR D.Origen='T' AND L.Tipo='TICKET')
    ) AS YP
    OUTER APPLY (
       SELECT SUM(P.TotalAmount) AS Importe
       FROM dbo.Shell_PayOrderComprobante AS L
       INNER JOIN dbo.Shell_PayOrder AS P ON P.ID=L.PayOrderId
       WHERE L.Sucursal=D.Sucursal AND L.Numero=D.NCOMPRO
         AND (D.Origen='F' AND L.Letra=D.Letra
              OR D.Origen='T' AND L.Tipo='TICKET')
    ) AS SH
    OUTER APPLY (
       SELECT SUM(P.TotalTransaction) AS ImporteBruto,
              SUM(P.Discounts) AS Descuentos
       FROM dbo.PUMA_PaymentComprobante AS L
       INNER JOIN dbo.PUMA_Payment AS P ON P.ID=L.PaymentId
       WHERE L.Sucursal=D.Sucursal AND L.Numero=D.NCOMPRO
         AND (D.Origen='F' AND L.Letra=D.Letra
              OR D.Origen='T' AND L.Tipo='TICKET')
    ) AS PU
    OUTER APPLY (
       SELECT SUM(P.Amount) AS Importe
       FROM dbo.Clover_PaymentInvoices AS L
       INNER JOIN dbo.Clover_Payments AS P ON P.Id=L.CloverPaymentId
       WHERE L.Pos=D.Sucursal AND L.InvoiceNumber=D.NCOMPRO
         AND (D.Origen='F' AND L.Letter=D.Letra
              OR D.Origen='T' AND L.Type='TICKET')
    ) AS CL
    OUTER APPLY (
       SELECT SUM(ISNULL(T.IMPORTETAR,0)) AS Importe,
              SUM(ISNULL(T.Extraccion,0)) AS Extraccion
       FROM dbo.Tarjet AS T
       WHERE T.Letra=D.Letra AND T.Sucursal=D.Sucursal AND T.NFACT=D.NCOMPRO
    ) AS TJ
 )
 SELECT P.Letra AS letra,
        P.Sucursal AS sucursal,
        P.NCOMPRO,
        P.Turno,
        P.MercadoPago,
        P.AppYPF,
        P.ShellBox,
        P.AppPuma,
        P.Clover,
        P.PayWay,
        P.Cheques,
        CASE WHEN P.Origen='F' AND P.CondVta=2 THEN 0
             ELSE ROUND(P.Total-(P.Clover+P.MercadoPago+P.AppYPF+
                                  P.PayWay+P.ShellBox+P.PumaBruto),2)
        END AS Efectivo,
        P.Total AS TOTAL,
        ISNULL(CAST(P.CodigoVendedor AS VARCHAR(8)),'0') + ' - ' +
           ISNULL(MV.RAZONSOC,'SIN VENDEDOR') AS Vendedor
 FROM Pagos AS P
 LEFT JOIN dbo.Maeven AS MV ON MV.VENDEDOR=P.CodigoVendedor
 ORDER BY letra, sucursal, NCOMPRO, Turno;
END;
GO

/*
 PASO DE PRUEBA: ejecutar sql/COMPARAR_PA_VentasFormasPago.sql con un rango y
 turno pequeños. No ampliar tiempos sin mediciones. Los resultados deben
 coincidir con el procedimiento original antes de llevar nada a producción.

 IMPORTANTE: si múltiples comprobantes de distintas estaciones comparten
 letra+sucursal+número y las tablas de pagos carecen de estación, la
 asociación ES AMBIGUA. El SP original también tiene ese problema.
 No promover a producción sin comprobar esta situación.
 Para fechas finales: BETWEEN conserva la semántica del original; una fecha
 pasada como medianoche NO incluye el resto de ese día. El conector debe
 enviar el final del día si la ventana pide días enteros.
*/