# SiSRL: índices para cobros / Capitán Rodolfo

**Diagnóstico reproducible del 28/09/2026**. SP de prueba tarda 22,057 s, CPU
21,625 s en estación 1 para el período. Lecturas lógicas: Tarjet 1.168.716;
YPF_PaymentIntentionComprobante 955.058; MP_OrdenPagoComprobante 525.046;
Clover_PaymentInvoices 211.636; Maeven 3.370. Cada una de las cuatro tablas
de medios se explora 674 veces, frente a Maeven 1 scan. Los índices visibles
aportados para pagos cubren solamente sus PK (ID) y MP un índice por
ID_OrdenPago; Tarjet no aparece indexada.

## Procedimiento controlado

1. Planificar fuera de horas pico. Validar que los objetos/columnas sigan
   coincidiendo con el esquema real y revisar índices nuevos existentes
   (podría haber otro cambio concurrente). Resguardar la base según la política
   habitual; CREATE INDEX puede bloquear modificaciones durante su construcción.
2. Ejecutar **solamente** 01_TARJET_PRIMERO.sql. Es idempotente por nombre y
   comprueba las columnas utilizadas antes de crear el índice.
3. Ejecutar nuevamente la MISMA llamada y parámetros de
   PA_VentasFormasPago_OPT_PRUEBA, con SET STATISTICS IO,TIME ON, repetir una
   segunda medición para diferenciar cache/calientamiento. Comparar 22,057 s
   iniciales y lecturas, especialmente Tarjet.
4. Si YPF, MP o Clover siguen dominando, aplicar en otro momento
   02_Y_VPF_MP_CLOVER_DESPUES.sql: 2 índices YPF, 2 MP, 1 Clover.
   Volver a medir con los mismos parámetros.
5. ANTES de instalar un SP nuevo en producción, comparar todos los
   comprobantes y columnas de la versión original y de prueba con idénticos
   parámetros en una muestra pequeña y otra con pagos mixtos. El SP previo
   puede devolver filas multiplicadas si hay pagos múltiples, por eso documentar
   discrepancias y la regla comercial antes de asumir equivalencia.
6. 90_DESHACER_INDICES_COBROS.sql contiene el rollback MANUAL de los seis
   índices nombrados. NO ejecutarlo salvo que se decida retirarlos.

Ninguno de estos archivos instala ni ejecuta automáticamente cambios en la
instancia privada SiSRL. La CI del repositorio comprueba la forma y el alcance
de estos cambios; NO mide SQL Server real ni asegura mejoras de rendimiento.
