/* Capitán Rodolfo v74 - Diagnóstico de permisos (lectura, sin cambiar nada).
   EJECUTAR conectado como el mismo usuario SQL que usa Núcleo -> Datos.
*/
USE [SiSRL];
GO
SELECT DB_NAME() AS BaseDatos,
       USER_NAME() AS UsuarioBase,
       SUSER_SNAME() AS LoginSQL,
       HAS_PERMS_BY_NAME('dbo.Tanque','OBJECT','SELECT') AS PuedeLeerTanque,
       HAS_PERMS_BY_NAME('dbo.ParamStock','OBJECT','SELECT') AS PuedeLeerParamStock,
       HAS_PERMS_BY_NAME('dbo.PA_CapitanRodolfo_CircuitoEstacion','OBJECT','EXECUTE') AS PuedeEjecutarCircuito;
GO
/* SOLO UN ADMINISTRADOR, en otra conexión con permisos, reemplaza
   [USUARIO_REAL_BD] por el valor UsuarioBase anterior.

GRANT EXECUTE ON OBJECT::dbo.PA_CapitanRodolfo_CircuitoEstacion TO [USUARIO_REAL_BD];

   Si también se necesita consultar Tanque desde el Explorador SQL
   directamente y no solo desde el SP, autorizar lectura explícitamente:

GRANT SELECT ON OBJECT::dbo.Tanque TO [USUARIO_REAL_BD];

   Para consultar otros objetos desde Explorador, conceder SELECT por objeto
   según las necesidades, sin asignar db_owner ni permisos globales.
*/
