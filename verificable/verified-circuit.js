/* DoingLio Verificable: un error SQL nunca se convierte en datos de muestra. */
(function (root, factory) {
  'use strict';
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  root.DoingLioVerificable = api;
})(typeof globalThis !== 'undefined' ? globalThis : this, function () {
  'use strict';
  const circuitSets = ['tanks', 'hoses', 'dispatches', 'receipts', 'company'];
  function fail(reason) {
    throw new Error('Circuito no verificado: ' + reason + '. No se muestran datos anteriores.');
  }
  function verifyCircuit(data, selectedStation) {
    const station = Number(selectedStation);
    if (!Number.isInteger(station) || station <= 0) fail('estación inválida');
    if (!data || data.source !== 'sp' || data.verified !== true) {
      fail('se necesita una ejecución correcta del procedimiento SQL; lectura_tablas no está autorizada para Carga');
    }
    if (data.connected !== true || data.database !== 'SiSRL' ||
        Number(data.station) !== station ||
        !/^\d{4}-\d{2}-\d{2}$/.test(String(data.fecha || ''))) {
      fail('base, estación o fecha SQL no confirmadas');
    }
    for (const key of circuitSets) {
      const set = data[key];
      if (!set || !Array.isArray(set.rows) || set.truncated === true ||
          (set.rowCount != null && Number(set.rowCount) !== set.rows.length)) {
        fail('resultado ' + key + ' incompleto o truncado');
      }
    }
    for (const row of data.dispatches.rows) {
      if (Number(row.IdEstacion) !== station ||
          typeof row.FechaDespacho !== 'string' ||
          !/^\d{4}-\d{2}-\d{2}(?:[ T]|$)/.test(row.FechaDespacho) ||
          row.FechaDespacho.slice(0, 10) !== data.fecha) {
        fail('se detectó un despacho de otra fecha o estación');
      }
    }
    return data;
  }
  return { verifyCircuit };
});
