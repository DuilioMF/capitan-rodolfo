# v87 — Despacho cobrado → Ver medios → Cobros

## Problema reproducido
En la ventana de comprobante, si `RelacionCptsDespachos` devolvía `Numero` vacío (captura: venta 5781, B, sucursal 17, turno 2), el componente de tabla deshabilitaba automáticamente «Ver medios» porque su propiedad `value` era `null`. Además la ruta antigua intentaba ir directamente a Cobros con esos datos incompletos.

## Corrección
1. El botón «Ver medios» siempre utiliza la venta seleccionada como valor habilitante, independientemente del número del comprobante.
2. Al pulsarlo se cierra la ventana mini y se abre **Cobros** con `ID_SALE` preseleccionado.
3. Se consulta `/api/station/payment-sale` por estación activa + `ID_SALE`. El bridge solo entrega comprobantes cuando coinciden `ID_DESPACHO` y `ULDATE = FECHA`; exige `ESTADOVTA = 1`.
4. Con comprobante verificado, se fija la fecha real del despacho en Desde/Hasta y todos los turnos (0 a 99999); se ejecuta `PA_VentasFormasPago`. Se filtran letra + sucursal + número para mostrar exclusivamente sus medios e importes.
5. Si faltan vínculos o permisos, se abre Cobros y se muestra advertencia concreta, sin asignar medios ficticios.

## Prueba automatizada
`node --test tests/ver-medios-navigation.test.js` comprueba la regresión estructural, el enlace y los controles de relación con SQL.

## Prueba funcional pendiente (SiSRL real)
- [ ] Actualizar conector y abrir la versión publicada.
- [ ] Seleccionar un despacho cobrado con Numero vacío en la ventanita y pulsar «Ver medios»: debe abrir Cobros, no quedar deshabilitado.
- [ ] Comprobar fecha Desde/Hasta del despacho y turnos 0–99999.
- [ ] Verificar letra+sucursal+número, desglose MP/App YPF/efectivo/multipago según columnas reales de `PA_VentasFormasPago`.
- [ ] Comprobar respuesta sin relación / ambigua / sin permisos, sin pagos atribuidos.
- [ ] Validar los importes contra SQL real y dejar evidencia en Trello.

Rollback: rama `rollback-v86-before-ver-medios-v87`. No se cambió la unión de SQL ni el SP.
