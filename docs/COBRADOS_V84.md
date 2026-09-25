# Capitán Rodolfo v84 — corrección de cobrados

Esta modificación parte de v83 y conserva la versión previa para rollback. La página de inicio utiliza un código personal discreto `R·84` obtenido del único archivo de versión raíz `VERSION`; DoingLio y Rubén tienen versiones independientes.

## Identificación del cobro

1. La venta seleccionada viene de `Despachos.ID_SALE`; es un identificador de búsqueda, **no** una clave de unión con `RelacionCptsDespachos`.
2. Se obtienen `Despachos.ID_DESPACHO` y `Despachos.ULDATE` para esa venta y estación.
3. Solo se muestra un comprobante si coincide **ambos** con `RelacionCptsDespachos.ID_DESPACHO` (si está disponible; `DI_DESPACHO` como alternativa confirmable) y `RelacionCptsDespachos.FECHA`. No se adjudican comprobantes por `ID_SALE` igual a `DI_DESPACHO`.
4. Se muestra letra, sucursal, número y turno del comprobante relacionado y el acceso **Ver medios**.
5. Ese acceso consulta `PA_VentasFormasPago` por la estación activa, la fecha obtenida del despacho y los turnos seleccionados. Solo enseña filas cuya letra+sucursal+número coinciden con el comprobante. Se discrimina Efectivo, Mercado Pago, App YPF, tarjetas, Clover y demás columnas realmente retornadas por el SP, contemplando multipago.
6. Si faltan campos, fecha, permisos SQL o no aparece comprobante, la interfaz informa el motivo y no adjudica importes ni relaciones inventadas.

`Cobrados` en el cuadro Carga se basa exclusivamente en `ESTADOVTA=1` de **los despachos cargados**, no es un total de todo el período. El cuadro Cobro sigue siendo el reporte por fecha, estación y turno del SP, sin sumar importes desde despachos.

## Pruebas previas a dar por terminado

- [ ] Verificar columnas físicas `ID_DESPACHO` y `ULDATE` de Despachos y `ID_DESPACHO`/`DI_DESPACHO` y `FECHA` de RelacionCptsDespachos en SiSRL.
- [ ] Ejecutar el SQL actualizado como administrador y confirmar `EXECUTE` del usuario usado por el conector.
- [ ] Abrir Carga: `Todos`, `Pendientes`, `Cobrados`; confirmar que la apertura no recibe un evento como estado de filtro.
- [ ] Seleccionar una venta cobrada real con comprobante y cotejar identificador y fecha con SQL.
- [ ] Abrir `Ver medios` en un comprobante real y cotejar todos los importes con `PA_VentasFormasPago`; comprobar al menos MP, App YPF y multipago si existen.
- [ ] Probar una relación ausente o ambigua: no debe mostrar comprobantes ni pagos de otro despacho.
- [ ] Verificar que el código `R·84` aparezca discretamente al pie del inicio, sin mostrar la palabra versión.
- [ ] Confirmar carga de GitHub Pages y que el conector local se haya actualizado a v84.

**No dar por validada la lectura SQL real solo por pasar comprobaciones estáticas de GitHub Actions.** La prueba final requiere la base conectada en el equipo de la estación.
