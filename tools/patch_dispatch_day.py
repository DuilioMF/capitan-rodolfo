#!/usr/bin/env python3
"""Patch both SQL deployment sources, failing closed if upstream SQL differs.

Run with: python3 tools/patch_dispatch_day.py
Edits SQL definitions in Git only. Does not connect to the user's SQL Server.
"""
from pathlib import Path

FILES = [
    Path('sql/PA_CapitanRodolfo_CircuitoEstacion.sql'),
    Path('sql/INSTALAR_Y_HABILITAR_CIRCUITO.sql'),
]


def exactly_once(src, old, new, context):
    count = src.count(old)
    if count != 1:
        raise ValueError(f'{context}: expected 1 match, found {count}')
    return src.replace(old, new, 1)


def patch(src, file):
    src = src.replace('\r\n', '\n')
    if 'CORRECCION DESPACHOS POR FECHA - 2026-09-27' in src:
        raise ValueError(f'{file}: already patched')

    # The existing SP uses @Fecha as a local NVARCHAR expression for ULTime.
    # Rename the legacy expression FIRST: the new @Fecha DATE parameter must
    # not collide with that variable, otherwise ALTER PROCEDURE cannot compile.
    src = exactly_once(src,
        '        @Fecha NVARCHAR(200), @WhereRel NVARCHAR(MAX),',
        '        @HoraExpr NVARCHAR(200), @WhereRel NVARCHAR(MAX),',
        str(file)+' legacy @Fecha declaration')
    src = exactly_once(src,
        "    SET @Fecha=CASE WHEN COL_LENGTH('dbo.Despachos','ULTIME') IS NOT NULL",
        "    SET @HoraExpr=CASE WHEN COL_LENGTH('dbo.Despachos','ULTIME') IS NOT NULL",
        str(file)+' legacy time expression')
    src = exactly_once(src,
        "+@Fecha+N' AS Hora",
        "+@HoraExpr+N' AS Hora",
        str(file)+' legacy time projection')

    src = exactly_once(src,
        '    @EstadoVta     BIT = NULL,   -- NULL=todos; 0=pendientes; 1=cobrados\n'
        '    @MaxDespachos  INT = 500,\n'
        '    @MaxRelaciones INT = 1000',
        '    @EstadoVta     BIT = NULL,   -- NULL=todos; 0=pendientes; 1=cobrados\n'
        '    @Fecha         DATE = NULL  -- NULL=fecha de hoy del servidor SQL',
        str(file)+' parameters')

    guard_start = '    IF @MaxDespachos IS NULL OR @MaxDespachos NOT BETWEEN 1 AND 10000\n'
    guard_end = "    IF OBJECT_ID(N'dbo.Tanque',N'U') IS NULL"
    if src.count(guard_start) != 1 or src.count(guard_end) != 1:
        raise ValueError(f'{file}: legacy limits guard not found unambiguously')
    a, b = src.index(guard_start), src.index(guard_end)
    if b <= a or "RAISERROR('@MaxDespachos y @MaxRelaciones deben estar entre 1 y 10000.'" not in src[a:b]:
        raise ValueError(f'{file}: unexpected guard block')
    src = src[:a] + (
        '    -- CORRECCION DESPACHOS POR FECHA - 2026-09-27\n'
        '    DECLARE @Dia DATE;\n'
        '    SET @Dia = ISNULL(@Fecha, CONVERT(date, GETDATE()));\n\n'
    ) + src[b:]

    marker = '    IF @DKey IS NULL OR @DDate IS NULL OR @RKey IS NULL OR @RDate IS NULL\n'
    src = exactly_once(src, marker, (
        "    -- Fail closed: ULDATE must have a temporal SQL type.\n"
        "    IF @DDate IS NULL OR NOT EXISTS (\n"
        "        SELECT 1 FROM sys.columns c\n"
        "        INNER JOIN sys.types ty ON ty.user_type_id=c.user_type_id\n"
        "        WHERE c.object_id=OBJECT_ID(N'dbo.Despachos') AND c.name=@DDate\n"
        "          AND ty.name IN ('date','datetime','datetime2','smalldatetime','datetimeoffset')\n"
        "    )\n"
        "    BEGIN\n"
        "        RAISERROR('ULDATE de Despachos no existe o no es fecha SQL; no se muestran historicos.',16,1);\n"
        "        RETURN;\n"
        "    END;\n"
        + marker
    ), str(file)+' date validation')

    src = exactly_once(src, 'SELECT TOP(@MaxDespachos)', 'SELECT', str(file)+' dispatch limit')
    src = exactly_once(src, 'SELECT TOP(@MaxRelaciones)', 'SELECT', str(file)+' relation limit')
    src = exactly_once(src,
        "      WHERE d.'+QUOTENAME(@DEst)+N'=@IdEstacion\n"
        "        AND (@EstadoVta IS NULL OR d.ESTADOVTA=@EstadoVta)\n",
        "      WHERE d.'+QUOTENAME(@DEst)+N'=@IdEstacion\n"
        "        AND (@EstadoVta IS NULL OR d.ESTADOVTA=@EstadoVta)\n"
        "        AND d.'+QUOTENAME(@DDate)+N' >= @Fecha\n"
        "        AND d.'+QUOTENAME(@DDate)+N' < DATEADD(day,1,@Fecha)\n",
        str(file)+' dispatch date filter')
    src = exactly_once(src,
        "      SET @WhereRel=N'(@EstadoVta IS NULL OR d.ESTADOVTA=@EstadoVta)';",
        "      SET @WhereRel=N'(@EstadoVta IS NULL OR d.ESTADOVTA=@EstadoVta)'\n"
        "        +N' AND d.'+QUOTENAME(@DDate)+N' >= @Fecha'\n"
        "        +N' AND d.'+QUOTENAME(@DDate)+N' < DATEADD(day,1,@Fecha)';",
        str(file)+' relation date filter')
    src = exactly_once(src,
        "N'@IdEstacion INT,@EstadoVta BIT,@MaxDespachos INT',\n"
        "         @IdEstacion=@IdEstacion,@EstadoVta=@EstadoVta,@MaxDespachos=@MaxDespachos;",
        "N'@IdEstacion INT,@EstadoVta BIT,@Fecha DATE',\n"
        "         @IdEstacion=@IdEstacion,@EstadoVta=@EstadoVta,@Fecha=@Dia;",
        str(file)+' dispatch exec params')
    src = exactly_once(src,
        "N'@IdEstacion INT,@EstadoVta BIT,@MaxRelaciones INT',\n"
        "         @IdEstacion=@IdEstacion,@EstadoVta=@EstadoVta,\n"
        "         @MaxRelaciones=@MaxRelaciones;",
        "N'@IdEstacion INT,@EstadoVta BIT,@Fecha DATE',\n"
        "         @IdEstacion=@IdEstacion,@EstadoVta=@EstadoVta,\n"
        "         @Fecha=@Dia;",
        str(file)+' relation exec params')

    if any(token in src for token in ('TOP(@MaxDespachos)', 'TOP(@MaxRelaciones)',
                                      '    @MaxDespachos  INT = 500',
                                      '    @MaxRelaciones INT = 1000',
                                      '@Fecha NVARCHAR(200)',
                                      'SET @Fecha=CASE')):
        raise ValueError(f'{file}: legacy limit or colliding @Fecha survived')
    if src.count("AND d.'+QUOTENAME(@DDate)+N' >= @Fecha") != 2:
        raise ValueError(f'{file}: expected exactly two day filters (dispatches and relations)')
    if src.count('@HoraExpr') != 3:
        raise ValueError(f'{file}: time expression not safely renamed')
    return src


def main():
    # Compute both results BEFORE writing any file: partial patch forbidden.
    changed = {file: patch(file.read_text(encoding='utf-8'), file) for file in FILES}
    for file, content in changed.items():
        file.write_text(content, encoding='utf-8', newline='\n')
    print('PASS: both SQL sources patched; ULDATE day range; no artificial limits; no @Fecha collision')


if __name__ == '__main__':
    main()
