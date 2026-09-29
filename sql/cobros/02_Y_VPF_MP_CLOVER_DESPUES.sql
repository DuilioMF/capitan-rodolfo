/*
SiSRL / Capitán Rodolfo — Fase 2: índices de cobros.
NO ejecutar hasta medir la Fase 1 y revisar resultados.
Deben crearse fuera de horas pico: CREATE INDEX puede bloquear operaciones.
No altera el SP original ni los datos. Compatible con SQL Server antiguo.
Se crean claves distintas para facturas y tickets, porque se buscan por
Letra + Sucursal + Numero o por Tipo=TICKET + Sucursal + Numero.
Clover usa (Pos,InvoiceNumber) cubriendo Letter o Type con INCLUDE.
*/
USE SiSRL;
GO
SET NOCOUNT ON;
-- Prevalidación: ninguna creación si falta una tabla o una columna.
IF OBJECT_ID(N'dbo.YPF_PaymentIntentionComprobante',N'U') IS NULL
 OR OBJECT_ID(N'dbo.MP_OrdenPagoComprobante',N'U') IS NULL
 OR OBJECT_ID(N'dbo.Clover_PaymentInvoices',N'U') IS NULL
 OR COL_LENGTH(N'dbo.YPF_PaymentIntentionComprobante',N'Letra') IS NULL
 OR COL_LENGTH(N'dbo.YPF_PaymentIntentionComprobante',N'Sucursal') IS NULL
 OR COL_LENGTH(N'dbo.YPF_PaymentIntentionComprobante',N'Numero') IS NULL
 OR COL_LENGTH(N'dbo.YPF_PaymentIntentionComprobante',N'Tipo') IS NULL
 OR COL_LENGTH(N'dbo.YPF_PaymentIntentionComprobante',N'ID_PaymentIntention') IS NULL
 OR COL_LENGTH(N'dbo.MP_OrdenPagoComprobante',N'Letra') IS NULL
 OR COL_LENGTH(N'dbo.MP_OrdenPagoComprobante',N'Sucursal') IS NULL
 OR COL_LENGTH(N'dbo.MP_OrdenPagoComprobante',N'Numero') IS NULL
 OR COL_LENGTH(N'dbo.MP_OrdenPagoComprobante',N'Tipo') IS NULL
 OR COL_LENGTH(N'dbo.MP_OrdenPagoComprobante',N'ID_OrdenPago') IS NULL
 OR COL_LENGTH(N'dbo.Clover_PaymentInvoices',N'Pos') IS NULL
 OR COL_LENGTH(N'dbo.Clover_PaymentInvoices',N'InvoiceNumber') IS NULL
 OR COL_LENGTH(N'dbo.Clover_PaymentInvoices',N'Letter') IS NULL
 OR COL_LENGTH(N'dbo.Clover_PaymentInvoices',N'Type') IS NULL
 OR COL_LENGTH(N'dbo.Clover_PaymentInvoices',N'CloverPaymentId') IS NULL
BEGIN
  RAISERROR('Esquema de pagos incompleto/no visible; NO se aplicaron los indices de Fase 2.',16,1);
  RETURN;
END;

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id=OBJECT_ID(N'dbo.YPF_PaymentIntentionComprobante')
 AND name=N'IX_YPF_Cobros_Factura')
BEGIN
 PRINT 'Creando YPF facturas';
 CREATE NONCLUSTERED INDEX IX_YPF_Cobros_Factura
 ON dbo.YPF_PaymentIntentionComprobante (Letra,Sucursal,Numero)
 INCLUDE (ID_PaymentIntention);
END;

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id=OBJECT_ID(N'dbo.YPF_PaymentIntentionComprobante')
 AND name=N'IX_YPF_Cobros_Ticket')
BEGIN
 PRINT 'Creando YPF tickets';
 CREATE NONCLUSTERED INDEX IX_YPF_Cobros_Ticket
 ON dbo.YPF_PaymentIntentionComprobante (Tipo,Sucursal,Numero)
 INCLUDE (ID_PaymentIntention);
END;

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id=OBJECT_ID(N'dbo.MP_OrdenPagoComprobante')
 AND name=N'IX_MP_Cobros_Factura')
BEGIN
 PRINT 'Creando Mercado Pago facturas';
 CREATE NONCLUSTERED INDEX IX_MP_Cobros_Factura
 ON dbo.MP_OrdenPagoComprobante (Letra,Sucursal,Numero)
 INCLUDE (ID_OrdenPago);
END;

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id=OBJECT_ID(N'dbo.MP_OrdenPagoComprobante')
 AND name=N'IX_MP_Cobros_Ticket')
BEGIN
 PRINT 'Creando Mercado Pago tickets';
 CREATE NONCLUSTERED INDEX IX_MP_Cobros_Ticket
 ON dbo.MP_OrdenPagoComprobante (Tipo,Sucursal,Numero)
 INCLUDE (ID_OrdenPago);
END;

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id=OBJECT_ID(N'dbo.Clover_PaymentInvoices')
 AND name=N'IX_Clover_Cobros_Comprobante')
BEGIN
 PRINT 'Creando Clover comprobantes';
 CREATE NONCLUSTERED INDEX IX_Clover_Cobros_Comprobante
 ON dbo.Clover_PaymentInvoices (Pos,InvoiceNumber)
 INCLUDE (Letter,[Type],CloverPaymentId);
END;
GO
SELECT OBJECT_NAME(object_id) AS Tabla,name AS Indice
FROM sys.indexes
WHERE name IN (N'IX_YPF_Cobros_Factura',N'IX_YPF_Cobros_Ticket',
               N'IX_MP_Cobros_Factura',N'IX_MP_Cobros_Ticket',
               N'IX_Clover_Cobros_Comprobante');
