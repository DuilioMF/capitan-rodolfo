#!/usr/bin/env python3
"""Parche reproducible, de alcance acotado. Nunca se conecta a SQL ni toca datos."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
BRIDGE = ROOT / 'bridge' / 'capitan_rodolfo_local.ps1'
INDEX = ROOT / 'index.html'
ROUTE_START = "      elseif($req.Method -eq 'POST' -and $pathOnly -eq '/api/station/circuit'){"
ROUTE_END = "      elseif($req.Method -eq 'GET' -and $pathOnly -eq '/api/station-summary'){"

NEW_ROUTE = r'''      elseif($req.Method -eq 'POST' -and $pathOnly -eq '/api/station/circuit'){
        # DOINGLIO_VERIFICABLE_V1: si falla el PA, error; nunca tablas historicas.
        try {
          $state=Ensure-ActiveSession
          if($null -eq $state -or [string]$state.database -ine 'SiSRL'){
            Send-Json $stream 409 @{error='Conectá SiSRL desde Núcleo → Datos. No se muestran datos anteriores.'}
            continue
          }
          $data=$req.Body | ConvertFrom-Json
          $station=0
          if(-not [int]::TryParse([string]$data.idEstacion,[ref]$station) -or $station -le 0){
            Send-Json $stream 400 @{error='Elegí una estación válida.'}
            continue
          }
          $cn=$Sessions[$state.sessionId].connection
          if(@(Get-StationOptions -Connection $cn -Database 'SiSRL') -notcontains $station){
            Send-Json $stream 403 @{error='La estación no está autorizada.'}
            continue
          }
          # Obtener la fecha del propio SQL Server y enviarla explicitamente al PA.
          # Un dia verificado es una fecha y estacion concretas, no TOP N historico.
          $cn.ChangeDatabase('SiSRL')
          $dayCmd=$cn.CreateCommand()
          $dayCmd.CommandText='SELECT CONVERT(VARCHAR(10),GETDATE(),23)'
          try {$sqlDay=[string]$dayCmd.ExecuteScalar()}
          finally {$dayCmd.Dispose()}
          $day=[datetime]::ParseExact($sqlDay,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture)
          $params=[pscustomobject]@{IdEstacion=$station;Fecha=$day}
          try {
            $result=Invoke-AllowedStoredProcedure -Connection $cn -Database 'SiSRL' -Procedure 'dbo.PA_CapitanRodolfo_CircuitoEstacion' -Parameters $params -MaxRows 500
            $sets=@($result.resultSets)
            if($sets.Count -lt 5){throw 'El PA no devolvió los cinco conjuntos requeridos por la interfaz.'}
            if(@($sets | Where-Object {$_.truncated}).Count -gt 0){throw 'El resultado supera el límite de lectura y está incompleto.'}
            foreach($s in $sets){if($null -eq $s.rows){throw 'El PA devolvió un conjunto incompleto.'}}
            foreach($row in @($sets[2].rows)){
              $foundStation=0
              $foundDate=([string]$row.FechaDespacho).Trim()
              if(-not [int]::TryParse([string]$row.IdEstacion,[ref]$foundStation) -or
                  $foundStation -ne $station -or
                  $foundDate.Length -lt 10 -or $foundDate.Substring(0,10) -cne $sqlDay){
                throw 'El PA devolvió un despacho de otra fecha o estación; se rechaza toda la respuesta.'
              }
            }
            Send-Json $stream 200 @{
              connected=$true;source='sp';verified=$true;fecha=$sqlDay
              database='SiSRL';station=$station
              procedure='dbo.PA_CapitanRodolfo_CircuitoEstacion'
              tanks=$sets[0];hoses=$sets[1];dispatches=$sets[2]
              receipts=$sets[3];company=$sets[4];companyAvailable=$true
              version=$Version
            }
          }catch{
            Send-Json $stream 422 @{
              connected=$true;source='sp';verified=$false;fecha=$sqlDay
              station=$station;database='SiSRL'
              error=('No se pudo verificar el circuito SQL: '+$_.Exception.Message+'. No se muestran datos anteriores.')
            }
          }
        }catch{
          Send-Json $stream 500 @{verified=$false;error=('Error al verificar PA_CapitanRodolfo_CircuitoEstacion: '+$_.Exception.Message)}
        }
      }
'''


def require_once(text: str, needle: str, filename: str) -> None:
    count = text.count(needle)
    if count != 1:
        raise RuntimeError(f'{filename}: se esperaba un único ancla ({needle[:65]}), encontrados {count}; no se aplica parche.')


def patch_bridge(text: str) -> str:
    require_once(text, ROUTE_START, str(BRIDGE))
    require_once(text, ROUTE_END, str(BRIDGE))
    start = text.index(ROUTE_START)
    end = text.index(ROUTE_END, start)
    old_route = text[start:end]
    if 'DOINGLIO_VERIFICABLE_V1' in old_route:
        return text
    if 'MaxDespachos=500;MaxRelaciones=1000' not in old_route or 'Get-StationReadOnlyCircuit -Connection' not in old_route:
        raise RuntimeError('El bridge cambió: las anclas del fallo no coinciden. No parchear automáticamente.')
    return text[:start] + NEW_ROUTE + text[end:]


def patch_index(text: str) -> str:
    if 'DOINGLIO_VERIFICABLE_UI_V1' in text:
        return text
    version_anchor = "<script>\n(async()=>{\n try{\n  const r=await fetch('VERSION?ts='+Date.now()"
    require_once(text, version_anchor, str(INDEX))
    require_once(text, ' function paint(data){\n', str(INDEX))
    require_once(text, ' function clearCircuit(){\n', str(INDEX))
    text = text.replace(version_anchor, '<script src="verificable/verified-circuit.js"></script>\n' + version_anchor, 1)
    text = text.replace(' function paint(data){\n', ''' function paint(data){
   // DOINGLIO_VERIFICABLE_UI_V1: no pintar datos de lectura_tablas ni SP sin prueba.
   if(!window.DoingLioVerificable)throw new Error('Falta el verificador de datos. No se muestran resultados.');
   window.DoingLioVerificable.verifyCircuit(data,stationSelect.value);
''', 1)
    text = text.replace(' function clearCircuit(){\n', ''' function clearCircuit(){
   closeModals();
''', 1)
    return text


def verify(bridge: str, index: str) -> None:
    start, end = bridge.index(ROUTE_START), bridge.index(ROUTE_END)
    route = bridge[start:end]
    if 'DOINGLIO_VERIFICABLE_V1' not in route or 'Get-StationReadOnlyCircuit' in route or 'MaxDespachos=' in route:
        raise RuntimeError('El circuito aún permite datos históricos o parámetros incompatibles.')
    if "verified=$true;fecha=$sqlDay" not in route or 'Send-Json $stream 422' not in route:
        raise RuntimeError('El backend no cumple con origen, fecha y error comprobable.')
    if 'DOINGLIO_VERIFICABLE_UI_V1' not in index or 'verificable/verified-circuit.js' not in index:
        raise RuntimeError('La interfaz no valida la respuesta antes de mostrarla.')
    if 'closeModals();\n   spResultSection.hidden=true' not in index:
        raise RuntimeError('El estado anterior permanece visible tras un fallo.')


def main() -> None:
    bridge = BRIDGE.read_text(encoding='utf-8-sig')
    index = INDEX.read_text(encoding='utf-8-sig')
    if '--check' not in sys.argv:
        patched_bridge = patch_bridge(bridge)
        patched_index = patch_index(index)
        verify(patched_bridge, patched_index)
        if patched_bridge != bridge:
            BRIDGE.write_text(patched_bridge, encoding='utf-8-sig')
        if patched_index != index:
            INDEX.write_text(patched_index, encoding='utf-8')
        print('Parche aplicado solo al endpoint del circuito y a la validación visual.')
    else:
        verify(bridge, index)
        print('Verificación estática OK: ruta sin fallback y UI con guardas.')


if __name__ == '__main__':
    main()
