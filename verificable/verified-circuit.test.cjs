const test = require('node:test');
const assert = require('node:assert/strict');
const {verifyCircuit} = require('./verified-circuit.js');

const emptySet = () => ({rows: [], columns: [], rowCount: 0, truncated: false});
function validCircuit() {
  return {
    source: 'sp', verified: true, connected: true, database: 'BASE_ACTIVA',
    station: 1, fecha: '2026-09-27',
    tanks: emptySet(), hoses: emptySet(), receipts: emptySet(), company: emptySet(),
    dispatches: {rows: [
      {IdEstacion: 1, FechaDespacho: '2026-09-27 10:25:00', IdDespacho: 123},
      {IdEstacion: 1, FechaDespacho: '2026-09-27 11:30:00', IdDespacho: 124}
    ], columns: ['IdEstacion', 'FechaDespacho', 'IdDespacho'], rowCount: 2, truncated: false}
  };
}

test('acepta dos despachos verificados del día y la estación', () => {
  const payload = validCircuit();
  assert.equal(verifyCircuit(payload, 1), payload);
});
test('cero despachos solo es válido cuando lo confirma el SP', () => {
  const payload = validCircuit();
  payload.dispatches = emptySet();
  assert.equal(verifyCircuit(payload, 1), payload);
});
test('rechaza lectura general aunque reporte conexión', () => {
  const payload = validCircuit();
  payload.source = 'lectura_tablas';
  assert.throws(() => verifyCircuit(payload, 1), /no verificado/i);
});
test('rechaza un SP que falló o no está comprobado', () => {
  const payload = validCircuit();
  payload.verified = false;
  assert.throws(() => verifyCircuit(payload, 1), /no verificado/i);
});
test('rechaza registros históricos mezclados con los actuales', () => {
  const payload = validCircuit();
  payload.dispatches.rows[0].FechaDespacho = '2026-07-04 00:00:00';
  assert.throws(() => verifyCircuit(payload, 1), /otra fecha/i);
});
test('rechaza registros de otra estación', () => {
  const payload = validCircuit();
  payload.dispatches.rows[1].IdEstacion = 2;
  assert.throws(() => verifyCircuit(payload, 1), /otra fecha o estación/i);
});
test('rechaza datos truncados y conteos incongruentes', () => {
  const payload = validCircuit();
  payload.dispatches.truncated = true;
  assert.throws(() => verifyCircuit(payload, 1), /incompleto/);
  payload.dispatches.truncated = false;
  payload.dispatches.rowCount = 99;
  assert.throws(() => verifyCircuit(payload, 1), /incompleto/);
});
test('rechaza falta de estación, fecha o quinto conjunto', () => {
  const payload = validCircuit();
  assert.throws(() => verifyCircuit(payload, 2), /fecha SQL|estación/i);
  assert.throws(() => verifyCircuit(payload, 0), /estación inválida/i);
  payload.station = 2;
  assert.throws(() => verifyCircuit(payload, 1), /estación/i);
  payload.station = 1;
  payload.fecha = '';
  assert.throws(() => verifyCircuit(payload, 1), /fecha SQL/i);
  payload.fecha = '2026-09-27';
  delete payload.company;
  assert.throws(() => verifyCircuit(payload, 1), /company incompleto/i);
});
