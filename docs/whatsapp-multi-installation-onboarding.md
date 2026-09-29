# Capitán Rodolfo — alta por teléfono y vinculación por instalación

Estado: diseño para prueba, **sin activar usuarios ni alterar el flujo en producción**.

## Flujo esperado
1. Abrir Capitán Rodolfo en la PC de la estación, iniciar el conector local y entrar a Núcleo → Conexión con DoingLio.
2. Descubrir las estaciones **reales** del SQL local (ParamStock). El administrador elige explícitamente una o varias estaciones.
3. Escribir teléfono en E.164. El servidor emite desafío OTP y entrega el código por **WhatsApp** mediante un proveedor autorizado, con expiración, límites de envío y de intentos. El cliente jamás decide que el OTP es válido.
4. Ingresar código; backend verifica prueba de control del número. El número verificado no obtiene acceso por sí solo: administrador con permisos sobre esa instalación debe aprobar la asociación solicitada.
5. Registrar membresía por installation_id + station_id + phone_e164 y rol. Conservar instalaciones históricas y registrar auditoría.
6. WhatsApp: número verificado + activo + habilitado para especialista + membresía habilitada + instalación online. Si existen varias, solicitar selección sin tomar por defecto una estación homónima en otro cliente; correlacionar trabajo SQL con installation_id, station_id y teléfono.
7. Ejecución local: worker instalado y autenticado atiende **solo** las consultas encoladas para su installation_id y las station_id descubiertas y autorizadas. No enviar credenciales SQL a Supabase, WhatsApp ni navegador.

## Limitación del esquema existente confirmada el 28/09/2026
- public.doinglio_core_installations tiene UNIQUE(specialist_key, admin_phone_e164): impide asociar dos instalaciones del mismo especialista al mismo administrador.
- public.doinglio_phone_access tiene PRIMARY KEY(phone_e164, specialist_key) y station_ids int[]: mezcla IDs locales de distintas instalaciones.
- Núcleo v94 envía phone, station_ids y confirmed a /api/doinglio/link: **confirmed es una casilla, no verificación OTP**.
- El gateway doinglio-wa-gateway comprueba permisos por teléfono y station_ids, pero no correlaciona todas las rutas con installation_id.
- No convertir el alta de números existentes en autorización implícita.

## Fases de implementación y aceptación
A. Migración aditiva con memberships por instalación y desafío verificado; mantener tablas antiguas mientras opera el flujo anterior.
B. Endpoint privado para alta/invitación, inicio/confirmación OTP WhatsApp, aprobación de administrador y baja, con protección antiabuso. Elegir proveedor WhatsApp compatible; nunca simular entrega de códigos.
C. Cambios versionados en Núcleo y servicio local para verificar que la estación real corresponde a la instalación que se vincula.
D. Gateway y cola con autorización y enrutamiento por installation_id + station_id (sin mezclar el mismo station_id en PCs distintas).
E. Pruebas: teléfono no registrado denegado; OTP inválido/caducado/bloqueado; OTP correcto pendiente de aprobación; doble estación misma PC; dos instalaciones mismo admin; permisos revocados; sin SQL local; reinicio sin perder credenciales; consulta real por WhatsApp y conciliación con SQL. Publicar solo cuando el circuito E2E apruebe.

## Precaución
No crear usuarios de prueba usando números reales sin autorización, ni enviar códigos antes de confirmar proveedor y secretos. No migrar en caliente el UNIQUE existente ni cambiar el enrutamiento productivo hasta comprobar el nuevo modelo extremo a extremo.