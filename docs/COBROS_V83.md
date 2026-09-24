# Capitán Rodolfo v83 — Tablero Cobros

Punto de control anterior: versión v82 en GitHub (antes del commit
`f0964bb8db6a8d36cb19a28e85082a5d6c7f3157`). DoingLio padre: D26.

## Pantalla

En el cuadro **Cobro** se abre el tablero negro/cobre, inspirado en
la referencia facilitada por Duilio. Permite seleccionar fechas,
estación activa y rango de turnos; consulta `dbo.PA_VentasFormasPago`.

El panel de formas de pago discrimina **Efectivo, Mercado Pago, App YPF,
Clover, Cuenta Corriente, Tarjetas, PayWay, Shell Box, App Puma y Cheques**.
Solo muestra montos si la columna correspondiente existe en el resultado
real del procedimiento. Las categorías ausentes se muestran como **No
informado**, NUNCA como $0 ficticios.

Al hacer clic en una forma, presenta los movimientos del SP y el importe
de ese medio para cada comprobante. **Todos** presenta los movimientos
por medio que efectivamente devuelve el SP. Un mismo comprobante puede
aparecer más de una vez si tiene multipago: los contadores representan
movimientos/medios, no necesariamente comprobantes únicos.

## Consultas

- `dbo.PA_VentasFormasPago`: `@FechaDesde DATETIME`,
  `@FechaHasta DATETIME`, `@IdEstacion INT`,
  `@TurnoDesde INT`, `@TurnoHasta INT`. Los vendedores
  se mantienen con los valores predeterminados del SP existente.
  El intervalo finaliza a las 23:59:59.997 en fechas DATETIME.
- `dbo.MP_OrdenPagoComprobante.ID_ORDENPAGO =
  dbo.MP_OrdenPago.ID`. Identificadores optativos retornados:
  `id_sale`, `ID_PAGO`, `amount` si las columnas existen.
- `dbo.YPF_PaymentIntentionComprobante.ID_PAYMENTINTENTION =
  dbo.YPF_PaymentIntention.ID`. Identificadores optativos:
  `PaymentIntentionID`, `PaymentID`, `GatewayID`, `Gateway`.
- Antes de mostrar una operación externa se verifica
  `letra + sucursal + número` y **estación** en `MaeFac`.
  Si las tablas externas no almacenan estación, se exige que el
  comprobante no se repita en otra estación; de lo contrario
  NO se adjudica la operación.
- `dbo.PA_ListarTarjXTurno`:
  `@fechainicio`, `@fechafin`, `@idestacion`,
  `@turnodesde`, `@turnohasta`,
  `@codtardesde=0`, `@codtarhasta=99999`,
  `@lotedesde=''`, `@lotehasta='ZZZZ...'`,
  `@idPosDevice=0`.
  Su listado se muestra **por período y turno**, sin atribuir
  filas a una factura si el SP no devuelve claves comprobables.

Cada consulta usa una conexión local existente con `SiSRL` y verifica
la estación. No se registran pagos ni se modifica información comercial.
Los permisos SQL `EXECUTE` siguen bajo control del administrador.
No se modificó ningún workflow de n8n.

Para evitar dar totales falsamente completos, el reporte tiene un límite
de 5.000 filas **por conjunto de resultados**; al alcanzarlo la
interfaz alerta que los totales son parciales y solicita acotar fechas.
Si el SP devuelve varios conjuntos que parecen sumar los mismos
comprobantes, se usa uno solo y se informa.

## Puerta de salida de la prueba real

1. Abrir DoingLio D26 desde el cerebro para sincronizar el conector.
2. Conectar `SiSRL`, seleccionar una estación y abrir **Cobro**.
3. Comprobar el mismo día/turno e importe por medio contra SQL,
   incluyendo un comprobante con multipago, uno MP y uno YPF.
4. Comparar los identificadores de pasarela y, aparte, ejecutar el
   reporte de tarjetas. Verificar si el SP devuelve Cuenta Corriente.
5. Solo después de esas comprobaciones se puede cerrar la tarjeta
   Trello **Capitán Rodolfo v83**.

Código y despliegue: https://github.com/DuilioMF/capitan-rodolfo
Web: https://duiliomf.github.io/capitan-rodolfo/?v=83
