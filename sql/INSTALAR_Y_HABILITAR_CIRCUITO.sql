/*
CAPITAN RODOLFO v84 - INSTALADOR PARA ADMINISTRADOR SQL
Incluye los ajustes de Tanques, Surtidores, Carga y comprobantes.
Requiere privilegios para ALTER PROCEDURE y GRANT EXECUTE sobre el SP.
No modifica movimientos comerciales.
Verificá USER_NAME() de la conexión DUI antes de ejecutar el GRANT.
*/

/*
 CAPITAN RODOLFO - CIRCUITO DE ESTACION
 Archivo de despliegue. Ejecutar en SSMS sobre la base SiSRL.
 Compatible con SQL Server 2008+ y bases de compatibilidad anterior a 110.
 El script usa creacion condicional y ALTER PROCEDURE.
 NO borra ni modifica datos de negocio.
 Se ejecuta con el contexto del propietario para leer las tablas del circuito.
 Requiere que el propietario tenga permisos y que el usuario del sistema
 tenga permiso EXECUTE sobre este SP (concedido por el administrador).

 Resultado 1: Tanques con nombre de producto.
 Resultado 2: Caras/surtidores y mangueras con su tanque.
 Resultado 3: Despachos (opcionalmente filtrados por estado de venta).
 Resultado 4: Relaciones con comprobantes (solo si existe una clave de filtro segura).
 Resultado 5: Empresa / estación desde dbo.ParamStock (mismo @IdEstacion).

 NOTA: Isla=(Cara+1)/2 presupone numeracion de caras 1-2, 3-4, etc.
*/

USE [SiSRL];
GO

-- Crear firma vacia unicamente si es la primera instalacion.
IF OBJECT_ID(N'dbo.PA_CapitanRodolfo_CircuitoEstacion',N'P') IS NULL
    EXEC(N'CREATE PROCEDURE dbo.PA_CapitanRodolfo_CircuitoEstacion AS BEGIN SET NOCOUNT ON; END');
GO

ALTER PROCEDURE dbo.PA_CapitanRodolfo_CircuitoEstacion
    @IdEstacion    INT,
    @EstadoVta     BIT = NULL,   -- NULL=todos; 0=pendientes; 1=cobrados
    @MaxDespachos  INT = 500,
    @MaxRelaciones INT = 1000,
    @IdSale        INT = NULL  -- NULL = todos; ID_SALE = consulta individual
WITH EXECUTE AS OWNER
AS
BEGIN
    SET NOCOUNT ON;

    IF @IdEstacion IS NULL OR @IdEstacion <= 0
    BEGIN
        RAISERROR('Indicá un @IdEstacion válido. No se permite mezclar estaciones.',16,1);
        RETURN;
    END;
    IF @MaxDespachos IS NULL OR @MaxDespachos NOT BETWEEN 1 AND 10000
       OR @MaxRelaciones IS NULL OR @MaxRelaciones NOT BETWEEN 1 AND 10000
    BEGIN
        RAISERROR('@MaxDespachos y @MaxRelaciones deben estar entre 1 y 10000.',16,1);
        RETURN;
    END;

    IF OBJECT_ID(N'dbo.Tanque',N'U') IS NULL
       OR OBJECT_ID(N'dbo.Prod',N'U') IS NULL
       OR OBJECT_ID(N'dbo.Surpla',N'U') IS NULL
       OR OBJECT_ID(N'dbo.Surtan',N'U') IS NULL
       OR OBJECT_ID(N'dbo.Despachos',N'U') IS NULL
       OR OBJECT_ID(N'dbo.RelacionCptsDespachos',N'U') IS NULL
       OR OBJECT_ID(N'dbo.ParamStock',N'U') IS NULL
    BEGIN
        RAISERROR('Falta una tabla requerida. Verificá esquema dbo de Tanque, Prod, Surpla, Surtan, Despachos, RelacionCptsDespachos y ParamStock.',16,1);
        RETURN;
    END;

    -- Las uniones NO se basan en SELECT * para evitar columnas duplicadas.
    IF COL_LENGTH('dbo.Tanque','N_TANQUE') IS NULL
       OR COL_LENGTH('dbo.Tanque','DENOMINACION') IS NULL
       OR COL_LENGTH('dbo.Tanque','CODART') IS NULL
       OR COL_LENGTH('dbo.Prod','CODART') IS NULL
       OR COL_LENGTH('dbo.Surpla','SURTIDOR') IS NULL
       OR COL_LENGTH('dbo.Surpla','MANGUERA') IS NULL
       OR COL_LENGTH('dbo.Surpla','CODART') IS NULL
       OR COL_LENGTH('dbo.Surtan','MANGUERA') IS NULL
       OR COL_LENGTH('dbo.Surtan','N_TANQUE') IS NULL
       OR COL_LENGTH('dbo.Despachos','ID_SALE') IS NULL
       OR COL_LENGTH('dbo.Despachos','SURTIDOR') IS NULL
       OR COL_LENGTH('dbo.Despachos','CODART') IS NULL
       OR COL_LENGTH('dbo.Despachos','LITROS') IS NULL
       OR COL_LENGTH('dbo.Despachos','PPU') IS NULL
       OR COL_LENGTH('dbo.Despachos','PESOS') IS NULL
       OR COL_LENGTH('dbo.Despachos','ESTADOVTA') IS NULL
    BEGIN
        RAISERROR('Alguna columna principal difiere de la consulta informada. Ejecutá el diagnóstico de columnas al final del archivo y ajustamos el mapeo.',16,1);
        RETURN;
    END;

    DECLARE
        @TEst SYSNAME, @PEst SYSNAME, @SEst SYSNAME, @StEst SYSNAME,
        @DEst SYSNAME, @REst SYSNAME,
        @ProdDesc SYSNAME, @Capacidad SYSNAME,
        @Sql NVARCHAR(MAX), @JoinProd NVARCHAR(MAX),
        @JoinSt NVARCHAR(MAX), @JoinTank NVARCHAR(MAX),
        @Controlador NVARCHAR(200), @DManguera NVARCHAR(200),
        @Fecha NVARCHAR(200), @WhereRel NVARCHAR(MAX),
        @ParamEst SYSNAME, @TipoEstCol SYSNAME, @NombreEstCol SYSNAME,
        @DomicilioCol SYSNAME, @TelefonoCol SYSNAME, @LocalidadCol SYSNAME,
        @TipoExpr NVARCHAR(600), @NombreExpr NVARCHAR(600),
        @DomicilioExpr NVARCHAR(600), @TelefonoExpr NVARCHAR(600),
        @LocalidadExpr NVARCHAR(600),
        @SCaraType SYSNAME, @DCaraType SYSNAME,
        @IslaSurplaExpr NVARCHAR(400), @IslaDespachosExpr NVARCHAR(400),
        @CostoExpr NVARCHAR(400), @PrecioExpr NVARCHAR(700),
        @LitrosTanqueExpr NVARCHAR(250),
        @TipoConexionKey SYSNAME, @ControladorJoin NVARCHAR(700),
        @ControladorExpr NVARCHAR(400), @RLetra SYSNAME,
        @RSucursal SYSNAME, @RNumero SYSNAME, @RTurno SYSNAME,
        @RelVentaExpr NVARCHAR(300), @RelLetraExpr NVARCHAR(300),
        @RelSucExpr NVARCHAR(300), @RelNumExpr NVARCHAR(300),
        @RelTurnoExpr NVARCHAR(300), @ComprobanteJoin NVARCHAR(MAX),
        @MfEst SYSNAME,
        @ParamHasRow BIT = 0, @Ambiguo BIT = 0;

    -- Acepta ID_ESTACION e ID_ESTAICION (error de tipeo mencionado);
    -- NUNCA supone que un ID de otra tabla corresponde a esta estación.
    SELECT TOP(1) @TEst=c.name FROM sys.columns c
      WHERE c.object_id=OBJECT_ID(N'dbo.Tanque')
        AND REPLACE(LOWER(c.name),'_','') IN ('idestacion','idestaicion')
      ORDER BY CASE WHEN REPLACE(LOWER(c.name),'_','')='idestacion' THEN 0 ELSE 1 END;
    SELECT TOP(1) @PEst=c.name FROM sys.columns c
      WHERE c.object_id=OBJECT_ID(N'dbo.Prod')
        AND REPLACE(LOWER(c.name),'_','') IN ('idestacion','idestaicion')
      ORDER BY CASE WHEN REPLACE(LOWER(c.name),'_','')='idestacion' THEN 0 ELSE 1 END;
    SELECT TOP(1) @SEst=c.name FROM sys.columns c
      WHERE c.object_id=OBJECT_ID(N'dbo.Surpla')
        AND REPLACE(LOWER(c.name),'_','') IN ('idestacion','idestaicion')
      ORDER BY CASE WHEN REPLACE(LOWER(c.name),'_','')='idestacion' THEN 0 ELSE 1 END;
    SELECT TOP(1) @StEst=c.name FROM sys.columns c
      WHERE c.object_id=OBJECT_ID(N'dbo.Surtan')
        AND REPLACE(LOWER(c.name),'_','') IN ('idestacion','idestaicion')
      ORDER BY CASE WHEN REPLACE(LOWER(c.name),'_','')='idestacion' THEN 0 ELSE 1 END;
    SELECT TOP(1) @DEst=c.name FROM sys.columns c
      WHERE c.object_id=OBJECT_ID(N'dbo.Despachos')
        AND REPLACE(LOWER(c.name),'_','') IN ('idestacion','idestaicion')
      ORDER BY CASE WHEN REPLACE(LOWER(c.name),'_','')='idestacion' THEN 0 ELSE 1 END;
    SELECT TOP(1) @REst=c.name FROM sys.columns c
      WHERE c.object_id=OBJECT_ID(N'dbo.RelacionCptsDespachos')
        AND REPLACE(LOWER(c.name),'_','') IN ('idestacion','idestaicion')
      ORDER BY CASE WHEN REPLACE(LOWER(c.name),'_','')='idestacion' THEN 0 ELSE 1 END;

    SELECT TOP(1) @ProdDesc=c.name FROM sys.columns c
      WHERE c.object_id=OBJECT_ID(N'dbo.Prod')
        AND REPLACE(LOWER(c.name),'_','') IN ('descriart','descriimpresion')
      ORDER BY CASE WHEN REPLACE(LOWER(c.name),'_','')='descriart' THEN 0 ELSE 1 END;
    SELECT TOP(1) @Capacidad=c.name FROM sys.columns c
      WHERE c.object_id=OBJECT_ID(N'dbo.Tanque')
        AND REPLACE(LOWER(c.name),'_','') IN ('capacidad','capaidad')
      ORDER BY CASE WHEN LOWER(c.name)='capacidad' THEN 0 ELSE 1 END;

    IF @TEst IS NULL OR @SEst IS NULL OR @DEst IS NULL
    BEGIN
        RAISERROR('Falta identificar ID_ESTACION en Tanque, Surpla o Despachos. No se ejecuta para evitar mezclar estaciones.',16,1);
        RETURN;
    END;
    IF @ProdDesc IS NULL OR @Capacidad IS NULL
    BEGIN
        RAISERROR('Falta identificar descripción de Prod o capacidad de Tanque. Ejecutá el diagnóstico de columnas.',16,1);
        RETURN;
    END;

    -- Identificar la estación y sus datos de ParamStock antes de emitir resultados.
    -- Los campos de texto pueden tener variantes de nombre según la instalación.
    SELECT TOP(1) @ParamEst=c.name
      FROM sys.columns c WHERE c.object_id=OBJECT_ID(N'dbo.ParamStock')
      AND REPLACE(LOWER(c.name),'_','') IN ('idestacion','idestaicion')
      ORDER BY CASE WHEN REPLACE(LOWER(c.name),'_','')='idestacion' THEN 0 ELSE 1 END;

    SELECT TOP(1) @TipoEstCol=c.name
      FROM sys.columns c WHERE c.object_id=OBJECT_ID(N'dbo.ParamStock')
      AND REPLACE(LOWER(c.name),'_','') IN ('tipoestacion','tipoestaicion','tipoestaicon','tipoestac')
      ORDER BY CASE WHEN REPLACE(LOWER(c.name),'_','')='tipoestacion' THEN 0 ELSE 1 END;

    SELECT TOP(1) @NombreEstCol=c.name
      FROM sys.columns c WHERE c.object_id=OBJECT_ID(N'dbo.ParamStock')
      AND REPLACE(LOWER(c.name),'_','') IN ('nombreestacion','nombestacion','nomestacion','nombre','razonsocial')
      ORDER BY CASE WHEN REPLACE(LOWER(c.name),'_','')='nombreestacion' THEN 0 ELSE 1 END;

    SELECT TOP(1) @DomicilioCol=c.name
      FROM sys.columns c WHERE c.object_id=OBJECT_ID(N'dbo.ParamStock')
      AND REPLACE(LOWER(c.name),'_','') IN ('domicilio','direccion')
      ORDER BY CASE WHEN REPLACE(LOWER(c.name),'_','')='domicilio' THEN 0 ELSE 1 END;

    SELECT TOP(1) @TelefonoCol=c.name
      FROM sys.columns c WHERE c.object_id=OBJECT_ID(N'dbo.ParamStock')
      AND REPLACE(LOWER(c.name),'_','') IN ('telefono','telfono','tel')
      ORDER BY CASE WHEN REPLACE(LOWER(c.name),'_','')='telefono' THEN 0 ELSE 1 END;

    SELECT TOP(1) @LocalidadCol=c.name
      FROM sys.columns c WHERE c.object_id=OBJECT_ID(N'dbo.ParamStock')
      AND REPLACE(LOWER(c.name),'_','') IN ('localidad','ciudad')
      ORDER BY CASE WHEN REPLACE(LOWER(c.name),'_','')='localidad' THEN 0 ELSE 1 END;

    IF @ParamEst IS NULL
    BEGIN
       RAISERROR('ParamStock no tiene un ID_ESTACION identificable. Revisá los nombres de las columnas; no se mostrarán datos de otra estación.',16,1);
       RETURN;
    END;

    -- Comprobar que el ID seleccionado realmente existe en ParamStock.
    SET @Sql=N'SELECT @found=CASE WHEN EXISTS (
      SELECT 1 FROM dbo.ParamStock WHERE CONVERT(VARCHAR(30),'+QUOTENAME(@ParamEst)+N')=CONVERT(VARCHAR(30),@IdEstacion)
    ) THEN 1 ELSE 0 END;';
    EXEC sys.sp_executesql @Sql,N'@IdEstacion INT,@found BIT OUTPUT',
         @IdEstacion=@IdEstacion,@found=@ParamHasRow OUTPUT;

    IF @ParamHasRow=0
    BEGIN
       RAISERROR('No existe ese ID de estación en ParamStock. Revisá el ID seleccionado.',16,1);
       RETURN;
    END;

    -- Si Prod no tiene ID_ESTACION, CODART debe ser único globalmente.
    IF @PEst IS NULL AND EXISTS (
        SELECT 1 FROM dbo.Prod GROUP BY CODART HAVING COUNT(*) > 1
    )
    BEGIN
        RAISERROR('Prod tiene CODART repetidos y no se detecta ID_ESTACION. Falta definir la clave real.',16,1);
        RETURN;
    END;

    -- Si Surtan no tiene estación, MANGUERA debe ser única entre estaciones.
    IF @StEst IS NULL
    BEGIN
        SET @Sql=N'SELECT @flag=CASE WHEN EXISTS (
          SELECT 1 FROM dbo.Surpla
          GROUP BY MANGUERA
          HAVING COUNT(DISTINCT '+QUOTENAME(@SEst)+N') > 1
        ) THEN 1 ELSE 0 END;';
        EXEC sys.sp_executesql @Sql,N'@flag BIT OUTPUT',@flag=@Ambiguo OUTPUT;
        IF @Ambiguo=1
        BEGIN
            RAISERROR('Surtan no indica estación y hay mangueras repetidas entre estaciones. Se necesita la clave adicional de la relación.',16,1);
            RETURN;
        END;
    END;

    -- Clave confirmada por el sistema: ID_SALE busca primero en Despachos;
    -- la relacion comercial usa FECHA=ULDATE Y ID_DESPACHO=ID_DESPACHO.
    IF COL_LENGTH('dbo.Despachos','ULDATE') IS NULL
       OR COL_LENGTH('dbo.Despachos','ID_DESPACHO') IS NULL
       OR COL_LENGTH('dbo.RelacionCptsDespachos','FECHA') IS NULL
       OR COL_LENGTH('dbo.RelacionCptsDespachos','ID_DESPACHO') IS NULL
    BEGIN
       RAISERROR('Para vincular comprobantes se necesitan Despachos(ULDATE,ID_DESPACHO) y RelacionCptsDespachos(FECHA,ID_DESPACHO).',16,1);
       RETURN;
    END;

    -- Nombres de comprobante por metadatos: jamás suponer que TURNO existe.
    SELECT TOP (1) @RLetra=c.name FROM sys.columns c
      WHERE c.object_id=OBJECT_ID(N'dbo.RelacionCptsDespachos')
        AND REPLACE(LOWER(c.name),'_','') IN ('letra') ORDER BY c.name;
    SELECT TOP (1) @RSucursal=c.name FROM sys.columns c
      WHERE c.object_id=OBJECT_ID(N'dbo.RelacionCptsDespachos')
        AND REPLACE(LOWER(c.name),'_','') IN ('sucursal','ptovta')
      ORDER BY CASE REPLACE(LOWER(c.name),'_','') WHEN 'sucursal' THEN 0 ELSE 1 END;
    SELECT TOP (1) @RNumero=c.name FROM sys.columns c
      WHERE c.object_id=OBJECT_ID(N'dbo.RelacionCptsDespachos')
        AND REPLACE(LOWER(c.name),'_','') IN ('ncompro','ncomp','numero','numerocomprobante','nrocomprobante')
      ORDER BY CASE REPLACE(LOWER(c.name),'_','')
        WHEN 'ncompro' THEN 0 WHEN 'ncomp' THEN 1
        WHEN 'numero' THEN 2 ELSE 3 END;
    SELECT TOP (1) @RTurno=c.name FROM sys.columns c
      WHERE c.object_id=OBJECT_ID(N'dbo.RelacionCptsDespachos')
        AND REPLACE(LOWER(c.name),'_','')='turno';

    SET @RelVentaExpr=N'd.ID_SALE';
    SET @RelLetraExpr=CASE WHEN @RLetra IS NOT NULL
      THEN N'r.'+QUOTENAME(@RLetra) ELSE N'CAST(NULL AS NVARCHAR(10))' END;
    SET @RelSucExpr=CASE WHEN @RSucursal IS NOT NULL
      THEN N'r.'+QUOTENAME(@RSucursal) ELSE N'CAST(NULL AS NVARCHAR(20))' END;
    SET @RelNumExpr=CASE WHEN @RNumero IS NOT NULL
      THEN N'r.'+QUOTENAME(@RNumero) ELSE N'CAST(NULL AS NVARCHAR(30))' END;
    SET @ComprobanteJoin=N'';
    SET @RelTurnoExpr=CASE WHEN @RTurno IS NOT NULL
      THEN N'r.'+QUOTENAME(@RTurno) ELSE N'CAST(NULL AS NVARCHAR(30))' END;
    -- Si turno no está en la relación, buscarlo en MAEFAC solo cuando
    -- letra + sucursal + número y el ID de estación estén verificados.
    IF @RTurno IS NULL
       AND @RLetra IS NOT NULL AND @RSucursal IS NOT NULL AND @RNumero IS NOT NULL
       AND OBJECT_ID(N'dbo.MaeFac',N'U') IS NOT NULL
       AND COL_LENGTH('dbo.MaeFac','LETRA') IS NOT NULL
       AND COL_LENGTH('dbo.MaeFac','SUCURSAL') IS NOT NULL
       AND COL_LENGTH('dbo.MaeFac','NCOMPRO') IS NOT NULL
       AND COL_LENGTH('dbo.MaeFac','TURNO') IS NOT NULL
    BEGIN
      SELECT TOP(1) @MfEst=c.name
        FROM sys.columns c WHERE c.object_id=OBJECT_ID(N'dbo.MaeFac')
          AND REPLACE(LOWER(c.name),'_','') IN ('idestacion','idestaicion')
        ORDER BY CASE WHEN REPLACE(LOWER(c.name),'_','')='idestacion' THEN 0 ELSE 1 END;
      IF @MfEst IS NOT NULL
      BEGIN
        SET @ComprobanteJoin=N' OUTER APPLY (
          SELECT CASE WHEN COUNT(DISTINCT CONVERT(NVARCHAR(30),mf.TURNO))=1
             THEN MAX(CONVERT(NVARCHAR(30),mf.TURNO)) ELSE NULL END AS Turno
          FROM dbo.MaeFac mf
          WHERE mf.LETRA=r.'+QUOTENAME(@RLetra)+N'
            AND mf.SUCURSAL=r.'+QUOTENAME(@RSucursal)+N'
            AND mf.NCOMPRO=r.'+QUOTENAME(@RNumero)+N'
            AND mf.'+QUOTENAME(@MfEst)+N'=@IdEstacion
        ) mfTurno';
        SET @RelTurnoExpr=N'mfTurno.Turno';
      END;
    END;

    -- La estacion de Despachos es el filtro obligatorio.
    -- Si la tabla de relaciones tambien lleva estacion, filtrarla adicionalmente.

    -- Solo calcular isla cuando SURTIDOR es numerico entero.
    -- Si es texto, no se inventa una relacion: el campo Isla sera NULL.
    SELECT @SCaraType=TYPE_NAME(c.system_type_id)
      FROM sys.columns c
      WHERE c.object_id=OBJECT_ID(N'dbo.Surpla') AND c.name='SURTIDOR';
    SELECT @DCaraType=TYPE_NAME(c.system_type_id)
      FROM sys.columns c
      WHERE c.object_id=OBJECT_ID(N'dbo.Despachos') AND c.name='SURTIDOR';
    SET @IslaSurplaExpr=CASE WHEN @SCaraType IN ('tinyint','smallint','int','bigint')
      THEN N'CASE WHEN s.SURTIDOR BETWEEN 1 AND 9999 THEN (CONVERT(INT,s.SURTIDOR)+1)/2 ELSE NULL END'
      ELSE N'CAST(NULL AS INT)' END;
    SET @IslaDespachosExpr=CASE WHEN @DCaraType IN ('tinyint','smallint','int','bigint')
      THEN N'CASE WHEN d.SURTIDOR BETWEEN 1 AND 9999 THEN (CONVERT(INT,d.SURTIDOR)+1)/2 ELSE NULL END'
      ELSE N'CAST(NULL AS INT)' END;

    -- PRECIOS reales de Prod: sin inventar impuestos que no existan.
    SET @CostoExpr=CASE WHEN COL_LENGTH('dbo.Prod','PRECOMPRA') IS NOT NULL
      THEN N'p.PRECOMPRA' ELSE N'CAST(NULL AS DECIMAL(18,2))' END;
    SET @PrecioExpr=CASE WHEN COL_LENGTH('dbo.Prod','PRECIOCONIVA') IS NOT NULL
      AND COL_LENGTH('dbo.Prod','IMPUESTOS') IS NOT NULL
      AND COL_LENGTH('dbo.Prod','TasaOtrosImpue') IS NOT NULL
      THEN N'(ISNULL(p.PRECIOCONIVA,0)+ISNULL(p.IMPUESTOS,0)+ISNULL(p.TasaOtrosImpue,0))'
      ELSE N'CAST(NULL AS DECIMAL(18,2))' END;
    SET @LitrosTanqueExpr=CASE WHEN COL_LENGTH('dbo.Tanque','LITROS') IS NOT NULL
      THEN N't.LITROS' ELSE N'CAST(NULL AS DECIMAL(18,2))' END;

    -- MP_TipoConexion: identificar clave documentada por metadatos, si existe.
    -- No relacionar códigos con nombres arbitrariamente cuando falta una clave.
    IF OBJECT_ID(N'dbo.MP_TipoConexion',N'U') IS NOT NULL
       AND COL_LENGTH('dbo.MP_TipoConexion','Name') IS NOT NULL
       AND COL_LENGTH('dbo.Surpla','CONTROLADOR') IS NOT NULL
    BEGIN
      SELECT TOP(1) @TipoConexionKey=c.name
      FROM sys.columns c WHERE c.object_id=OBJECT_ID(N'dbo.MP_TipoConexion')
        AND REPLACE(LOWER(c.name),'_','') IN
            ('controlador','idtipoconexion','tipoconexion','idconexion','id','codigo')
      ORDER BY CASE REPLACE(LOWER(c.name),'_','')
        WHEN 'controlador' THEN 1
        WHEN 'idtipoconexion' THEN 2
        WHEN 'tipoconexion' THEN 3
        WHEN 'idconexion' THEN 4
        WHEN 'id' THEN 5 ELSE 6 END;
    END;
    SET @ControladorJoin=N'';
    SET @ControladorExpr=CASE WHEN COL_LENGTH('dbo.Surpla','CONTROLADOR') IS NOT NULL
      THEN N'CONVERT(NVARCHAR(100),s.CONTROLADOR)' ELSE N'CAST(NULL AS NVARCHAR(100))' END;
    IF @TipoConexionKey IS NOT NULL
    BEGIN
      SET @ControladorJoin=N' OUTER APPLY (
        SELECT CASE WHEN COUNT(*)=1 THEN MAX(CONVERT(NVARCHAR(100),mpx.[Name]))
                    ELSE NULL END AS [Name]
        FROM dbo.MP_TipoConexion mpx
        WHERE CONVERT(NVARCHAR(100),mpx.'+QUOTENAME(@TipoConexionKey)+N')
              =CONVERT(NVARCHAR(100),s.CONTROLADOR)
      ) mp';
      SET @ControladorExpr=N'COALESCE(mp.[Name],CONVERT(NVARCHAR(100),s.CONTROLADOR))';
    END;

    -- Resultado 1: TANQUES
    SET @JoinProd=N'INNER JOIN dbo.Prod p ON p.CODART=t.CODART';
    IF @PEst IS NOT NULL
      SET @JoinProd+=N' AND p.'+QUOTENAME(@PEst)+N'=t.'+QUOTENAME(@TEst);
    SET @Sql=N'
      SELECT t.'+QUOTENAME(@TEst)+N' AS IdEstacion,
             t.N_TANQUE AS NTanque,
             t.DENOMINACION AS Denominacion,
             t.CODART AS CodArt,
             p.'+QUOTENAME(@ProdDesc)+N' AS Producto,
             '+@CostoExpr+N' AS Costo,
             '+@PrecioExpr+N' AS Precio,
             t.'+QUOTENAME(@Capacidad)+N' AS Capacidad,
             '+@LitrosTanqueExpr+N' AS Litros
      FROM dbo.Tanque t '+@JoinProd+N'
      WHERE t.'+QUOTENAME(@TEst)+N'=@IdEstacion
      ORDER BY t.N_TANQUE;';
    EXEC sys.sp_executesql @Sql,N'@IdEstacion INT',@IdEstacion=@IdEstacion;

    -- Resultado 2: MANGUERAS/CARAS. Isla derivada: caras 1/2=>isla 1.
    SET @JoinProd=N'INNER JOIN dbo.Prod p ON p.CODART=s.CODART';
    IF @PEst IS NOT NULL
      SET @JoinProd+=N' AND p.'+QUOTENAME(@PEst)+N'=s.'+QUOTENAME(@SEst);
    SET @JoinSt=N'INNER JOIN dbo.Surtan st ON st.MANGUERA=s.MANGUERA';
    IF @StEst IS NOT NULL
      SET @JoinSt+=N' AND st.'+QUOTENAME(@StEst)+N'=s.'+QUOTENAME(@SEst);
    IF COL_LENGTH('dbo.Surtan','SURTIDOR') IS NOT NULL
      SET @JoinSt+=N' AND st.SURTIDOR=s.SURTIDOR';
    SET @JoinTank=N'INNER JOIN dbo.Tanque t
                    ON t.N_TANQUE=st.N_TANQUE
                   AND t.'+QUOTENAME(@TEst)+N'=s.'+QUOTENAME(@SEst);
    SET @Controlador=@ControladorExpr;
    SET @Sql=N'
      SELECT s.'+QUOTENAME(@SEst)+N' AS IdEstacion,
             s.SURTIDOR AS Cara,
             '+@IslaSurplaExpr+N' AS Isla,
             s.MANGUERA AS Manguera, s.CODART AS CodArt,
             p.'+QUOTENAME(@ProdDesc)+N' AS Producto,
             '+@CostoExpr+N' AS Costo,
             '+@PrecioExpr+N' AS Precio,
             st.N_TANQUE AS NTanque, t.DENOMINACION AS Tanque,
             '+@Controlador+N' AS Controlador
      FROM dbo.Surpla s '+@JoinProd+N'
      '+@JoinSt+N'
      '+@JoinTank+N'
      '+@ControladorJoin+N'
      WHERE s.'+QUOTENAME(@SEst)+N'=@IdEstacion
      ORDER BY s.SURTIDOR,s.MANGUERA;';
    EXEC sys.sp_executesql @Sql,N'@IdEstacion INT',@IdEstacion=@IdEstacion;

    -- Resultado 3: DESPACHOS
    SET @JoinProd=N'INNER JOIN dbo.Prod p ON p.CODART=d.CODART';
    IF @PEst IS NOT NULL
      SET @JoinProd+=N' AND p.'+QUOTENAME(@PEst)+N'=d.'+QUOTENAME(@DEst);
    SET @DManguera=CASE WHEN COL_LENGTH('dbo.Despachos','MANGUERA') IS NOT NULL
      THEN N'd.MANGUERA' ELSE N'CAST(NULL AS INT)' END;
    SET @Fecha=CASE WHEN COL_LENGTH('dbo.Despachos','ULTIME') IS NOT NULL
      THEN N'CONVERT(VARCHAR(8),d.ULTIME,108)' ELSE N'CAST(NULL AS VARCHAR(8))' END;
    SET @Sql=N'
      SELECT TOP(@MaxDespachos)
             d.'+QUOTENAME(@DEst)+N' AS IdEstacion,
             d.ID_SALE AS IdSale, d.SURTIDOR AS Cara,
             '+@IslaDespachosExpr+N' AS Isla,
             '+@DManguera+N' AS Manguera, d.CODART AS CodArt,
             p.'+QUOTENAME(@ProdDesc)+N' AS Producto,
             '+@CostoExpr+N' AS Costo,
             '+@PrecioExpr+N' AS PrecioProducto,
             d.LITROS AS Litros,d.PPU AS PPU,d.PESOS AS Pesos,
             d.ESTADOVTA AS EstadoVta,'+@Fecha+N' AS Hora
      FROM dbo.Despachos d '+@JoinProd+N'
      WHERE d.'+QUOTENAME(@DEst)+N'=@IdEstacion
        AND (@EstadoVta IS NULL OR d.ESTADOVTA=@EstadoVta)
        AND (@IdSale IS NULL OR d.ID_SALE=@IdSale)
      ORDER BY '+CASE WHEN COL_LENGTH('dbo.Despachos','ULTIME') IS NOT NULL
                       THEN N'd.ULTIME DESC,' ELSE N'' END+N' d.ID_SALE DESC;';
    EXEC sys.sp_executesql @Sql,
         N'@IdEstacion INT,@EstadoVta BIT,@MaxDespachos INT,@IdSale INT',
         @IdEstacion=@IdEstacion,@EstadoVta=@EstadoVta,@MaxDespachos=@MaxDespachos,@IdSale=@IdSale;

    -- Resultado 4: los comprobantes se enlazan por las DOS claves exactas.
    SET @WhereRel=N'd.'+QUOTENAME(@DEst)+N'=@IdEstacion
      AND (@EstadoVta IS NULL OR d.ESTADOVTA=@EstadoVta)
      AND (@IdSale IS NULL OR d.ID_SALE=@IdSale)';
    IF @REst IS NOT NULL
      SET @WhereRel=@WhereRel+N' AND r.'+QUOTENAME(@REst)+N'=@IdEstacion';

    SET @Sql=N'
      SELECT TOP(@MaxRelaciones)
          '+@RelVentaExpr+N' AS Venta,
          '+@RelLetraExpr+N' AS Letra,
          '+@RelSucExpr+N' AS Sucursal,
          '+@RelNumExpr+N' AS Numero,
          '+@RelTurnoExpr+N' AS Turno
      FROM dbo.RelacionCptsDespachos r
      INNER JOIN dbo.Despachos d
        ON r.FECHA=d.ULDATE AND r.ID_DESPACHO=d.ID_DESPACHO
      '+@ComprobanteJoin+N'
      WHERE '+@WhereRel+N'
      ORDER BY d.ULDATE DESC, d.ID_SALE DESC;';
    EXEC sys.sp_executesql @Sql,
         N'@IdEstacion INT,@EstadoVta BIT,@MaxRelaciones INT,@IdSale INT',
         @IdEstacion=@IdEstacion,@EstadoVta=@EstadoVta,
         @MaxRelaciones=@MaxRelaciones,@IdSale=@IdSale;

    -- Resultado 5: EMPRESA/ESTACIÓN. Se agrega al final para no alterar el
    -- orden de los cuatro conjuntos consumidos por las versiones previas.
    -- Los campos no detectados vuelven como NULL, nunca como un dato supuesto.
    SET @TipoExpr=CASE WHEN @TipoEstCol IS NULL
      THEN N'CAST(NULL AS NVARCHAR(200))'
      ELSE N'CONVERT(NVARCHAR(200),ps.'+QUOTENAME(@TipoEstCol)+N')' END;
    SET @NombreExpr=CASE WHEN @NombreEstCol IS NULL
      THEN N'CAST(NULL AS NVARCHAR(250))'
      ELSE N'CONVERT(NVARCHAR(250),ps.'+QUOTENAME(@NombreEstCol)+N')' END;
    SET @DomicilioExpr=CASE WHEN @DomicilioCol IS NULL
      THEN N'CAST(NULL AS NVARCHAR(250))'
      ELSE N'CONVERT(NVARCHAR(250),ps.'+QUOTENAME(@DomicilioCol)+N')' END;
    SET @TelefonoExpr=CASE WHEN @TelefonoCol IS NULL
      THEN N'CAST(NULL AS NVARCHAR(100))'
      ELSE N'CONVERT(NVARCHAR(100),ps.'+QUOTENAME(@TelefonoCol)+N')' END;
    SET @LocalidadExpr=CASE WHEN @LocalidadCol IS NULL
      THEN N'CAST(NULL AS NVARCHAR(200))'
      ELSE N'CONVERT(NVARCHAR(200),ps.'+QUOTENAME(@LocalidadCol)+N')' END;

    SET @Sql=N'
      SELECT TOP (1)
             @IdEstacion AS IdEstacion,
             '+@TipoExpr+N' AS TipoEstacion,
             '+@NombreExpr+N' AS NombreEstacion,
             '+@DomicilioExpr+N' AS Domicilio,
             '+@TelefonoExpr+N' AS Telefono,
             '+@LocalidadExpr+N' AS Localidad
      FROM dbo.ParamStock ps
      WHERE CONVERT(VARCHAR(30),ps.'+QUOTENAME(@ParamEst)+N')=CONVERT(VARCHAR(30),@IdEstacion);';
    EXEC sys.sp_executesql @Sql,N'@IdEstacion INT',@IdEstacion=@IdEstacion;
END;
GO

/*
 PASO 1 - Diagnóstico de tu usuario SQL (sin cambiar datos):
 SELECT DB_NAME() AS Base,
        USER_NAME() AS UsuarioBD,
        SUSER_SNAME() AS LoginSQL,
        HAS_PERMS_BY_NAME('dbo.Tanque','OBJECT','SELECT') AS PuedeLeerTanque,
        HAS_PERMS_BY_NAME('dbo.PA_CapitanRodolfo_CircuitoEstacion','OBJECT','EXECUTE') AS PuedeEjecutarSP;

 Para ejecutar SELECT directamente sobre Tanque desde el Explorador SQL,
 pedí al DBA permiso SELECT SOLO en los objetos necesarios.
 No uses db_owner ni db_datareader salvo decisión expresa del DBA.
 Para ejecutar el SP, el DBA debe conceder EXECUTE sobre este procedimiento.

 PASO 1b - Obtener estaciones con el usuario autorizado (sólo si tiene SELECT):
 SELECT DISTINCT ID_ESTACION FROM dbo.ParamStock;

 PASO 2 - Ejecutar con el ID real (ejemplo 1, AJUSTAR):
 EXEC dbo.PA_CapitanRodolfo_CircuitoEstacion
      @IdEstacion=1, @EstadoVta=NULL;

 PASO 3 - Despachos pendientes:
 EXEC dbo.PA_CapitanRodolfo_CircuitoEstacion
      @IdEstacion=1, @EstadoVta=0;

 Si recibís un error de columnas, ejecutá este diagnóstico y compartí
 sólo los nombres de columnas (NO usuarios ni contraseñas):
 SELECT t.name AS Tabla,c.name AS Columna,TYPE_NAME(c.user_type_id) AS Tipo
 FROM sys.tables t
 JOIN sys.columns c ON c.object_id=t.object_id
 WHERE t.name IN ('Tanque','Prod','Surpla','Surtan',
                  'Despachos','RelacionCptsDespachos','ParamStock')
 ORDER BY t.name,c.column_id;
*/

-- Habilitar al usuario de la aplicación para ejecutar SOLAMENTE este SP.
-- Un administrador debe verificar el nombre del usuario de BASE, no del login.
USE [SiSRL];
GO
DECLARE @UsuarioBD SYSNAME = N'dui';
IF USER_ID(@UsuarioBD) IS NULL
BEGIN
    RAISERROR('El usuario dui no existe como principal en SiSRL. Revisá USER_NAME() con su conexión y cambiá @UsuarioBD.',10,1);
END
ELSE
BEGIN
    DECLARE @GrantSql NVARCHAR(MAX)=N'GRANT EXECUTE ON OBJECT::dbo.PA_CapitanRodolfo_CircuitoEstacion TO '+QUOTENAME(@UsuarioBD);
    EXEC sys.sp_executesql @GrantSql;
    PRINT 'Listo: permiso EXECUTE otorgado exclusivamente al SP de circuito.';
END;
GO
