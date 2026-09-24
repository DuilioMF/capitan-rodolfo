/*
 CAPITAN RODOLFO - CIRCUITO DE ESTACION
 Archivo de despliegue. Ejecutar en SSMS sobre la base SiSRL.
 Requiere SQL Server 2016 SP1 o superior (CREATE OR ALTER).
 NO borra ni modifica datos de negocio.

 Resultado 1: Tanques con nombre de producto.
 Resultado 2: Caras/surtidores y mangueras con su tanque.
 Resultado 3: Despachos (opcionalmente filtrados por estado de venta).
 Resultado 4: Relaciones con comprobantes (solo si existe una clave de filtro segura).

 NOTA: Isla=(Cara+1)/2 presupone numeracion de caras 1-2, 3-4, etc.
*/

USE [SiSRL];
GO

CREATE OR ALTER PROCEDURE dbo.PA_CapitanRodolfo_CircuitoEstacion
    @IdEstacion    INT,
    @EstadoVta     BIT = NULL,   -- NULL=todos; 0=pendientes; 1=cobrados
    @MaxDespachos  INT = 500,
    @MaxRelaciones INT = 1000
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
    BEGIN
        RAISERROR('Falta una tabla requerida. Verificá esquema dbo de Tanque, Prod, Surpla, Surtan, Despachos y RelacionCptsDespachos.',16,1);
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
        @RKey SYSNAME, @DKey SYSNAME,
        @Sql NVARCHAR(MAX), @JoinProd NVARCHAR(MAX),
        @JoinSt NVARCHAR(MAX), @JoinTank NVARCHAR(MAX),
        @Controlador NVARCHAR(200), @DManguera NVARCHAR(200),
        @Fecha NVARCHAR(200), @WhereRel NVARCHAR(MAX),
        @Ambiguo BIT = 0;

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

    -- Buscar vínculo con Despachos sin asumir que ID_SALE = ID_DESPACHO.
    SELECT TOP(1) @RKey=rc.name,@DKey=dc.name
    FROM sys.columns rc
    JOIN sys.columns dc ON dc.object_id=OBJECT_ID(N'dbo.Despachos')
      AND REPLACE(LOWER(dc.name),'_','')=REPLACE(LOWER(rc.name),'_','')
    WHERE rc.object_id=OBJECT_ID(N'dbo.RelacionCptsDespachos')
      AND REPLACE(LOWER(rc.name),'_','') IN ('iddespacho','iddespcho','idsale')
    ORDER BY CASE REPLACE(LOWER(rc.name),'_','')
             WHEN 'iddespacho' THEN 0 WHEN 'iddespcho' THEN 1 ELSE 2 END;

    IF @REst IS NULL AND @RKey IS NULL
    BEGIN
        RAISERROR('RelacionCptsDespachos no tiene ID_ESTACION ni clave compartida confirmada con Despachos. No se envían datos sin filtro.',16,1);
        RETURN;
    END;
    IF @EstadoVta IS NOT NULL AND @RKey IS NULL
    BEGIN
        RAISERROR('No hay clave confirmada para filtrar los comprobantes por ESTADOVTA. Ejecutá con @EstadoVta=NULL o verificá el vínculo.',16,1);
        RETURN;
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
             t.'+QUOTENAME(@Capacidad)+N' AS Capacidad
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
    SET @Controlador=CASE WHEN COL_LENGTH('dbo.Surpla','CONTROLADOR') IS NOT NULL
      THEN N's.CONTROLADOR' ELSE N'CAST(NULL AS NVARCHAR(100))' END;
    SET @Sql=N'
      SELECT s.'+QUOTENAME(@SEst)+N' AS IdEstacion,
             s.SURTIDOR AS Cara,
             CASE WHEN TRY_CONVERT(INT,s.SURTIDOR)>0
               THEN (TRY_CONVERT(INT,s.SURTIDOR)+1)/2 ELSE NULL END AS Isla,
             s.MANGUERA AS Manguera, s.CODART AS CodArt,
             p.'+QUOTENAME(@ProdDesc)+N' AS Producto,
             st.N_TANQUE AS NTanque, t.DENOMINACION AS Tanque,
             '+@Controlador+N' AS Controlador
      FROM dbo.Surpla s '+@JoinProd+N'
      '+@JoinSt+N'
      '+@JoinTank+N'
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
      THEN N'd.ULTIME' ELSE N'CAST(NULL AS DATETIME)' END;
    SET @Sql=N'
      SELECT TOP(@MaxDespachos)
             d.'+QUOTENAME(@DEst)+N' AS IdEstacion,
             d.ID_SALE AS IdSale, d.SURTIDOR AS Cara,
             CASE WHEN TRY_CONVERT(INT,d.SURTIDOR)>0
               THEN (TRY_CONVERT(INT,d.SURTIDOR)+1)/2 ELSE NULL END AS Isla,
             '+@DManguera+N' AS Manguera, d.CODART AS CodArt,
             p.'+QUOTENAME(@ProdDesc)+N' AS Producto,
             d.LITROS AS Litros,d.PPU AS PPU,d.PESOS AS Pesos,
             d.ESTADOVTA AS EstadoVta,'+@Fecha+N' AS Fecha
      FROM dbo.Despachos d '+@JoinProd+N'
      WHERE d.'+QUOTENAME(@DEst)+N'=@IdEstacion
        AND (@EstadoVta IS NULL OR d.ESTADOVTA=@EstadoVta)
      ORDER BY '+CASE WHEN COL_LENGTH('dbo.Despachos','ULTIME') IS NOT NULL
                       THEN N'd.ULTIME DESC,' ELSE N'' END+N' d.ID_SALE DESC;';
    EXEC sys.sp_executesql @Sql,
         N'@IdEstacion INT,@EstadoVta BIT,@MaxDespachos INT',
         @IdEstacion=@IdEstacion,@EstadoVta=@EstadoVta,@MaxDespachos=@MaxDespachos;

    -- Resultado 4: RELACION COMPROBANTE/DESPACHO
    -- Si existe clave compartida, usa EXISTS y también el filtro de EstadoVta.
    -- Si no existe pero la tabla lleva estación, devuelve relaciones de esa estación
    -- únicamente cuando EstadoVta es NULL. Nunca asume columnas de factura.
    IF @RKey IS NOT NULL
    BEGIN
      SET @WhereRel=N'EXISTS (
         SELECT 1 FROM dbo.Despachos d
         WHERE d.'+QUOTENAME(@DKey)+N'=r.'+QUOTENAME(@RKey)+N'
           AND d.'+QUOTENAME(@DEst)+N'=@IdEstacion
           AND (@EstadoVta IS NULL OR d.ESTADOVTA=@EstadoVta)
      )';
      IF @REst IS NOT NULL
        SET @WhereRel=N'r.'+QUOTENAME(@REst)+N'=@IdEstacion AND '+@WhereRel;
    END
    ELSE
      SET @WhereRel=N'r.'+QUOTENAME(@REst)+N'=@IdEstacion';

    SET @Sql=N'
      SELECT TOP(@MaxRelaciones) r.*
      FROM dbo.RelacionCptsDespachos r
      WHERE '+@WhereRel+N';';
    EXEC sys.sp_executesql @Sql,
         N'@IdEstacion INT,@EstadoVta BIT,@MaxRelaciones INT',
         @IdEstacion=@IdEstacion,@EstadoVta=@EstadoVta,
         @MaxRelaciones=@MaxRelaciones;
END;
GO

/*
 PASO 1 - Comprobar qué estaciones existen (sin cambiar datos):
 SELECT DISTINCT ID_ESTACION FROM dbo.Tanque;

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
                  'Despachos','RelacionCptsDespachos')
 ORDER BY t.name,c.column_id;
*/
