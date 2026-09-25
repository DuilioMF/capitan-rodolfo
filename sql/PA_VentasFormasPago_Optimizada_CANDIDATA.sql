/*
CAPITÁN RODOLFO / OLEUM
PA_VentasFormasPago_Optimizada - CANDIDATA PARA PRUEBAS
Base: Maestros. NO reemplaza dbo.PA_VentasFormasPago original.

Qué cambia:
 - Primero filtra comprobantes por estación, fecha, turno y vendedor.
 - Agrupa tickets antes de relacionarlos con sus pagos.
 - Calcula cada pasarela por separado para evitar el producto cartesiano
   generado por varios LEFT JOIN de relaciones uno-a-muchos.
 - Mantiene nombres, orden de columnas, 7 parámetros y la regla LEGACY
   de Efectivo (NO descuenta Cheques y resta el bruto de Puma).
 - @FechaHasta es un DIA INCLUSIVO, incluso si el cliente envía
   23:59:59.997. Se filtra usando intervalo semiabierto e índices.

IMPORTANTE:
 - Si hay varios pagos legítimos por comprobante, se suman.
 - La versión original multiplicaba filas cuando coincidían varios
   pagos/pasarelas: por eso los resultados pueden DIFERIR. Validar.
 - Los enlaces de pasarela de esta versión conservan las mismas
   columnas que mostró Duilio. No se asume ID_ESTACION donde no consta.
 - Si se reutilizan números de comprobante en otra estación/turno,
   verificar claves adicionales antes de afirmar una vinculación.
 - Esta candidata necesita SQL Server 2008+ (tipo DATE).
*/
USE [Maestros];
GO
IF OBJECT_ID(N'dbo.PA_VentasFormasPago_Optimizada', N'P') IS NULL
    EXEC(N'CREATE PROCEDURE dbo.PA_VentasFormasPago_Optimizada AS BEGIN SET NOCOUNT ON; END');
GO
ALTER PROCEDURE [dbo].[PA_VentasFormasPago_Optimizada]
    @FechaDesde DATETIME,
    @FechaHasta DATETIME,
    @IdEstacion INT,
    @TurnoDesde INT,
    @TurnoHasta INT,
    @VendedorDesde INT = 0,
    @VendedorHasta INT = 99999
AS
BEGIN
    SET NOCOUNT ON;

    IF @FechaDesde IS NULL OR @FechaHasta IS NULL
       OR @FechaHasta < @FechaDesde
       OR @IdEstacion IS NULL OR @IdEstacion <= 0
       OR @TurnoDesde > @TurnoHasta
       OR @VendedorDesde > @VendedorHasta
    BEGIN
        RAISERROR('Rango de fecha, estación, turno o vendedor inválido.',16,1);
        RETURN;
    END;

    DECLARE @Inicio DATETIME = CONVERT(DATE, @FechaDesde);
    DECLARE @FinExclusivo DATETIME = DATEADD(DAY,1,CONVERT(DATE,@FechaHasta));

    -- 1. Filtrar temprano. Conservar cada fila MAEFAC original.
    --    En MAETIC, sumar exactamente por las claves del SP entregado.
    SELECT CAST(0 AS TINYINT) AS EsTicket,
           M.LETRA AS Letra,
           M.SUCURSAL AS Sucursal,
           M.NCOMPRO AS NCOMPRO,
           M.TURNO AS Turno,
           M.TOTAL AS Total,
           M.CHEQUES AS Cheques,
           M.CONDVTA AS CondVta,
           M.VENDEDOR AS Vendedor
    INTO #Documentos
    FROM dbo.Maefac M
    WHERE M.FECHA >= @Inicio AND M.FECHA < @FinExclusivo
      AND M.ID_ESTACION = @IdEstacion
      AND M.TURNO BETWEEN @TurnoDesde AND @TurnoHasta
      AND ISNULL(M.VENDEDOR,0) BETWEEN @VendedorDesde AND @VendedorHasta

    UNION ALL

    SELECT CAST(1 AS TINYINT), 'T',
           MT.Sucursal, MT.Numero, MT.Turno,
           MT.Total, CAST(0 AS DECIMAL(19,2)),
           CAST(NULL AS INT), MT.Vendedor
    FROM (
        SELECT T.Sucursal, T.Numero, T.Turno, T.Vendedor,
               SUM(T.TOTAL) AS Total
        FROM dbo.Maetic T
        WHERE T.FECHA >= @Inicio AND T.FECHA < @FinExclusivo
          AND T.ID_ESTACION = @IdEstacion
          AND T.TURNO BETWEEN @TurnoDesde AND @TurnoHasta
          AND ISNULL(T.VENDEDOR,0) BETWEEN @VendedorDesde AND @VendedorHasta
        GROUP BY T.Sucursal, T.Numero, T.Turno, T.Vendedor
    ) MT;

    CREATE CLUSTERED INDEX IX_Documentos_Cpte
        ON #Documentos (EsTicket, Letra, Sucursal, NCOMPRO, Turno);

    -- Evitar consultar las pasarelas más de una vez por comprobante.
    SELECT DISTINCT EsTicket, Letra, Sucursal, NCOMPRO
    INTO #Claves
    FROM #Documentos;

    CREATE UNIQUE CLUSTERED INDEX IX_Claves_Cpte
        ON #Claves (EsTicket, Letra, Sucursal, NCOMPRO);

    -- 2. Buscar y sumar cada medio por separado. Las condiciones
    --    para TICKET son las mismas que las del SP original.
    SELECT K.EsTicket, K.Letra, K.Sucursal, K.NCOMPRO,
           ISNULL(MP.Monto,   CONVERT(DECIMAL(38,2),0)) AS MercadoPago,
           ISNULL(YPF.Monto,  CONVERT(DECIMAL(38,2),0)) AS AppYPF,
           ISNULL(SH.Monto,   CONVERT(DECIMAL(38,2),0)) AS ShellBox,
           ISNULL(PU.Neto,    CONVERT(DECIMAL(38,2),0)) AS AppPuma,
           ISNULL(PU.Bruto,   CONVERT(DECIMAL(38,2),0)) AS PumaBruto,
           ISNULL(CL.Monto,   CONVERT(DECIMAL(38,2),0)) AS Clover,
           ISNULL(TAR.Monto,  CONVERT(DECIMAL(38,2),0)) AS PayWay
    INTO #Pagos
    FROM #Claves K

    OUTER APPLY (
        SELECT SUM(CONVERT(DECIMAL(19,2),ISNULL(ROUND(O.amount,2),0))) AS Monto
        FROM dbo.MP_OrdenPagoComprobante C
        INNER JOIN dbo.MP_OrdenPago O ON O.ID = C.ID_OrdenPago
        WHERE C.Sucursal = K.Sucursal AND C.Numero = K.NCOMPRO
          AND ((K.EsTicket = 1 AND C.Tipo = 'TICKET')
            OR (K.EsTicket = 0 AND C.Letra = K.Letra))
    ) MP

    OUTER APPLY (
        SELECT SUM(CONVERT(DECIMAL(19,2),ISNULL(ROUND(P.amount,2),0))) AS Monto
        FROM dbo.YPF_PaymentIntentionComprobante C
        INNER JOIN dbo.YPF_PaymentIntention P ON P.ID = C.ID_PaymentIntention
        WHERE C.Sucursal = K.Sucursal AND C.Numero = K.NCOMPRO
          AND ((K.EsTicket = 1 AND C.Tipo = 'TICKET')
            OR (K.EsTicket = 0 AND C.Letra = K.Letra))
    ) YPF

    OUTER APPLY (
        SELECT SUM(CONVERT(DECIMAL(19,2),ISNULL(ROUND(P.TotalAmount,2),0))) AS Monto
        FROM dbo.Shell_PayOrderComprobante C
        INNER JOIN dbo.Shell_PayOrder P ON P.ID = C.PayOrderId
        WHERE C.Sucursal = K.Sucursal AND C.Numero = K.NCOMPRO
          AND ((K.EsTicket = 1 AND C.Tipo = 'TICKET')
            OR (K.EsTicket = 0 AND C.Letra = K.Letra))
    ) SH

    OUTER APPLY (
        SELECT SUM(CONVERT(DECIMAL(19,2),
                   ISNULL(ROUND(P.TotalTransaction-P.Discounts,2),0))) AS Neto,
               SUM(CONVERT(DECIMAL(19,2),
                   ISNULL(ROUND(P.TotalTransaction,2),0))) AS Bruto
        FROM dbo.PUMA_PaymentComprobante C
        INNER JOIN dbo.PUMA_Payment P ON P.ID = C.PaymentId
        WHERE C.Sucursal = K.Sucursal AND C.Numero = K.NCOMPRO
          AND ((K.EsTicket = 1 AND C.Tipo = 'TICKET')
            OR (K.EsTicket = 0 AND C.Letra = K.Letra))
    ) PU

    OUTER APPLY (
        SELECT SUM(CONVERT(DECIMAL(19,2),ISNULL(ROUND(P.Amount,2),0))) AS Monto
        FROM dbo.Clover_PaymentInvoices C
        INNER JOIN dbo.Clover_Payments P ON P.ID = C.CloverPaymentId
        WHERE C.Pos = K.Sucursal AND C.InvoiceNumber = K.NCOMPRO
          AND ((K.EsTicket = 1 AND C.Type = 'TICKET')
            OR (K.EsTicket = 0 AND C.Letter = K.Letra))
    ) CL

    OUTER APPLY (
        SELECT SUM(CONVERT(DECIMAL(19,2),
                   ISNULL(ROUND(ISNULL(T.IMPORTETAR,0)-ISNULL(T.Extraccion,0),2),0))) AS Monto
        FROM dbo.Tarjet T
        WHERE T.Letra = K.Letra
          AND T.Sucursal = K.Sucursal
          AND T.NFACT = K.NCOMPRO
    ) TAR;

    CREATE UNIQUE CLUSTERED INDEX IX_Pagos_Cpte
        ON #Pagos (EsTicket, Letra, Sucursal, NCOMPRO);

    -- 3. Una salida por documento original, no una por combinación
    --    cartesiana de registros de las pasarelas.
    SELECT D.Letra AS letra,
           D.Sucursal AS sucursal,
           D.NCOMPRO,
           D.Turno,
           P.MercadoPago,
           P.AppYPF,
           P.ShellBox,
           P.AppPuma,
           P.Clover,
           P.PayWay,
           D.Cheques,
           CASE WHEN D.EsTicket = 0 AND D.CondVta = 2
                THEN CONVERT(DECIMAL(38,2),0)
                ELSE ROUND(
                    D.Total - (
                        P.Clover + P.MercadoPago + P.AppYPF
                        + P.PayWay + P.ShellBox + P.PumaBruto
                    ),2)
           END AS Efectivo,
           D.Total AS TOTAL,
           ISNULL(CAST(D.Vendedor AS VARCHAR(8)),'0') + ' - '
             + ISNULL(MV.RAZONSOC,'SIN VENDEDOR') AS Vendedor
    FROM #Documentos D
    INNER JOIN #Pagos P
      ON P.EsTicket = D.EsTicket AND P.Letra = D.Letra
     AND P.Sucursal = D.Sucursal AND P.NCOMPRO = D.NCOMPRO
    LEFT JOIN dbo.Maeven MV ON MV.VENDEDOR = D.Vendedor
    ORDER BY D.Letra, D.Sucursal, D.NCOMPRO, D.Turno;
END;
GO
