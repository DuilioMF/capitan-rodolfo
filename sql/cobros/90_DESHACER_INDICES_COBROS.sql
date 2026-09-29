/*
Roll-back manual. SOLO si alguno de estos índices se creó con los scripts
01 o 02 y está aprobado retirarlo. Borrar índices puede tener impacto en
otros planes; no lanzar automáticamente en producción.
*/
USE SiSRL;
GO
IF EXISTS (SELECT 1 FROM sys.indexes WHERE object_id=OBJECT_ID(N'dbo.Tarjet')
 AND name=N'IX_Tarjet_Cobros_Comprobante')
 DROP INDEX IX_Tarjet_Cobros_Comprobante ON dbo.Tarjet;
IF EXISTS (SELECT 1 FROM sys.indexes WHERE object_id=OBJECT_ID(N'dbo.YPF_PaymentIntentionComprobante')
 AND name=N'IX_YPF_Cobros_Factura')
 DROP INDEX IX_YPF_Cobros_Factura ON dbo.YPF_PaymentIntentionComprobante;
IF EXISTS (SELECT 1 FROM sys.indexes WHERE object_id=OBJECT_ID(N'dbo.YPF_PaymentIntentionComprobante')
 AND name=N'IX_YPF_Cobros_Ticket')
 DROP INDEX IX_YPF_Cobros_Ticket ON dbo.YPF_PaymentIntentionComprobante;
IF EXISTS (SELECT 1 FROM sys.indexes WHERE object_id=OBJECT_ID(N'dbo.MP_OrdenPagoComprobante')
 AND name=N'IX_MP_Cobros_Factura')
 DROP INDEX IX_MP_Cobros_Factura ON dbo.MP_OrdenPagoComprobante;
IF EXISTS (SELECT 1 FROM sys.indexes WHERE object_id=OBJECT_ID(N'dbo.MP_OrdenPagoComprobante')
 AND name=N'IX_MP_Cobros_Ticket')
 DROP INDEX IX_MP_Cobros_Ticket ON dbo.MP_OrdenPagoComprobante;
IF EXISTS (SELECT 1 FROM sys.indexes WHERE object_id=OBJECT_ID(N'dbo.Clover_PaymentInvoices')
 AND name=N'IX_Clover_Cobros_Comprobante')
 DROP INDEX IX_Clover_Cobros_Comprobante ON dbo.Clover_PaymentInvoices;
GO
