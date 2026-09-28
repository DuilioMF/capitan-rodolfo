# Capitán Rodolfo v93 — Cobros en una sola conexión SiSRL

## Motivo

La página de Cobros mostraba «Falta acceso SQL» aunque el circuito de Despachos ya usaba una sesión activa de SiSRL. El endpoint de Cobros y la evidencia MP/YPF exigían erróneamente una segunda base. Se elimina ese requisito.

## Contrato corregido

- `/api/station/payment-sale`: la venta, el despacho y el comprobante se vinculan por ID_DESPACHO y ULDATE/FECHA en SiSRL. ESTADOVTA=1 habilita la presentación de pagos como cobrados.
- `/api/station/payments`: ejecuta `dbo.PA_VentasFormasPago` en SiSRL reutilizando la conexión SQL activa, controlando estación y manteniendo los siete parámetros originales, sin credenciales adicionales.
- `/api/station/payment-evidence`: verifica MP/App YPF y MaeFac exclusivamente en SiSRL, comprobando letra, sucursal, número y estación. Si faltan tablas, columnas o una relación única, no atribuye operaciones a otro comprobante.
- La fecha por defecto de Cobros es la fecha del día en zona `America/Argentina/Buenos_Aires`. Al consultar por período, se utiliza exactamente el período elegido por el usuario. Al buscar una venta se utilizan la fecha y comprobante reales del despacho, incluso si son de otro día; nunca se fuerza el día anterior ni el actual.
- La distribución web usa `cobros.js?v=93` y el conector v93, obligando a actualizar copias anteriores. La instalación conserva el perfil SQL y sus contraseñas locales.

## Validación necesaria antes de cerrar

1. Ejecutar `CAPITAN_RODOLFO.bat` desde Núcleo > Datos en la PC conectada a SiSRL. Reiniciar el conector y comprobar su versión 93.
2. Comprobar en Cobros que la fecha inicial sea 28/09/2026 cuando la consulta se realiza el 28/09/2026 en Argentina y que las fechas configuradas por el usuario viajen al SP (no hay fecha fija).
3. Verificar en SQL local que `SiSRL.dbo.PA_VentasFormasPago` existe y es ejecutable por el usuario de la conexión; si no existe o el esquema real difiere, informarlo y no mostrar montos fabricados.
4. Comparar un despacho realmente cobrado, su comprobante y al menos un cobro MP/YPF/multipago contra los datos reales del mismo período y estación. Probar también ausencia de relación y permisos insuficientes.

Las pruebas estáticas y CI no tienen acceso a la base de la estación: hasta realizar esta prueba local no se declara el circuito funcionalmente validado.
