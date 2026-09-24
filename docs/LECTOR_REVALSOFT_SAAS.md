# Lector de comprobantes de Capitán Rodolfo v78

## Reutilización real de Revalsoft SaaS

Se verificó en el repositorio `DuilioMF/revalsoft-saas` y en el proyecto
Supabase `apqgrwudkfytwikrsivd` que la Edge Function **extract-document-json**
está activa y configurada para exigir JWT (`verify_jwt=true`).
Esta función utiliza `Deno.env.get("OPENAI_API_KEY")` en el servidor.
**No lee esa clave desde SiSRL ni la envía al navegador.** No duplicar
su valor en SQL Server, páginas estáticas ni GitHub.

Flujo compartido:

1. El usuario selecciona PDF/JPG/PNG/WEBP en `documentos.html`
   desde el camión de Descarga de combustible.
2. Capitán reutiliza la sesión del usuario de **ese proyecto de Supabase**.
   Si no hay sesión local vigente, pide iniciar sesión con esa cuenta.
3. Envía `file_name`, `mime_type` y `base64` a
   `/functions/v1/extract-document-json` utilizando JWT y la clave
   **publicable** del proyecto (distinta de la clave secreta de OpenAI).
4. La función toma `OPENAI_API_KEY` de sus secretos y solicita a OpenAI
   datos estructurados en el mismo JSON Schema de Revalsoft SaaS.
5. Capitán conserva el JSON original bajo `datosExtraidos` y lo presenta
   con una vista resumida (Factura / Recibo / Transferencia), items e IVA.
   La extracción puede equivocarse: todos los datos quedan
   **pendientes de revisión**.

## Qué NO hace

- No guarda ni modifica automáticamente facturas, transferencias, bancos,
  despachos o existencias en `SiSRL`.
- No registra la clave privada de OpenAI en HTML, JavaScript o SQL Server.
- No da por probada la extracción real sin procesar un comprobante autorizado.

Si la Edge Function informa que falta `OPENAI_API_KEY`, revisar los
**secretos de Supabase** con un administrador; no pedir ni pegar el
valor en el chat o en el código.

## Control de compatibilidad SQL

El conector v78 lee `ParamStock` sin `TRY_CONVERT`. Para la visualización
completa, instalar también
[`sql/PA_CapitanRodolfo_CircuitoEstacion.sql`](../sql/PA_CapitanRodolfo_CircuitoEstacion.sql)
v78, con script condicional + `ALTER PROCEDURE` compatible con
instancias SQL que no reconozcan `TRY_CONVERT`.
