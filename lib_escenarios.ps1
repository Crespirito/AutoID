# ============================================================
# HELPERS INTERNOS (robustos frente a hashtable / pscustomobject)
# ============================================================

function script:Test-EsDiccionario {
    param([object]$Obj)
    return ($Obj -is [System.Collections.IDictionary])
}

function script:Get-DicValor {
    param(
        [object]$Obj,
        [string]$Clave,
        [object]$PorDefecto = $null
    )
    if ($null -eq $Obj) { return $PorDefecto }
    if (Test-EsDiccionario $Obj) {
        if ($Obj.Contains($Clave)) { return $Obj[$Clave] }
        return $PorDefecto
    }
    $prop = $Obj.PSObject.Properties[$Clave]
    if ($prop) { return $prop.Value }
    return $PorDefecto
}

function script:Get-DicTiene {
    param([object]$Obj, [string]$Clave)
    if ($null -eq $Obj) { return $false }
    if (Test-EsDiccionario $Obj) { return $Obj.Contains($Clave) }
    return ($null -ne $Obj.PSObject.Properties[$Clave])
}

function script:Resolve-Placeholders {
    param(
        [object]$Valor,
        [hashtable]$Variables
    )
    if ($null -eq $Valor) { return $null }
    if ($Valor -is [string]) {
        $resultado = $Valor
        foreach ($k in $Variables.Keys) {
            $resultado = $resultado -replace [regex]::Escape("{$k}"), [string]$Variables[$k]
        }
        return $resultado
    }
    if ($Valor -is [System.Collections.IDictionary]) {
        $nuevo = @{}
        foreach ($k in $Valor.Keys) {
            $nuevo[$k] = Resolve-Placeholders -Valor $Valor[$k] -Variables $Variables
        }
        return $nuevo
    }
    if ($Valor -is [System.Management.Automation.PSCustomObject]) {
        $nuevo = [ordered]@{}
        foreach ($p in $Valor.PSObject.Properties) {
            $nuevo[$p.Name] = Resolve-Placeholders -Valor $p.Value -Variables $Variables
        }
        return [pscustomobject]$nuevo
    }
    if ($Valor -is [System.Collections.IEnumerable]) {
        return @($Valor | ForEach-Object { Resolve-Placeholders -Valor $_ -Variables $Variables })
    }
    return $Valor
}

# ============================================================
# NORMALIZACIÓN ROBUSTA
# ============================================================

function ConvertTo-LabEscenarioNormalizado {
    param(
        [string]$Path = $null,
        [object]$Raw = $null,

        # Variables para resolver placeholders tipo {tenant} antes de validar.
        # Si no se pasan, se intentan derivar de tenantDomain.
        [hashtable]$Variables = $null
    )

    $sourcePath = $null

    if ($null -eq $Raw) {
        if ([string]::IsNullOrWhiteSpace($Path)) {
            throw 'ConvertTo-LabEscenarioNormalizado: se requiere -Path o -Raw.'
        }
        if (-not (Test-Path -Path $Path)) {
            throw "No existe el escenario: $Path"
        }
        try {
            $Raw = Get-Content -Path $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch {
            throw "El escenario '$Path' no es un JSON válido: $($_.Exception.Message)"
        }
        $sourcePath = $Path
    }

    if ($null -eq $Raw) {
        throw 'ConvertTo-LabEscenarioNormalizado: el objeto crudo es $null.'
    }

    $errores = [System.Collections.Generic.List[string]]::new()

    # ----- metadatos -----
    $nombre = $null
    foreach ($k in @('nombre','Nombre')) {
        if ((Get-DicTiene $Raw $k) -and -not [string]::IsNullOrWhiteSpace([string](Get-DicValor $Raw $k))) {
            $nombre = [string](Get-DicValor $Raw $k); break
        }
    }
    if ([string]::IsNullOrWhiteSpace($nombre) -and $sourcePath) {
        $nombre = [System.IO.Path]::GetFileNameWithoutExtension($sourcePath)
    }

    $descripcion = $null
    foreach ($k in @('descripcion','Descripcion')) {
        if (Get-DicTiene $Raw $k) { $descripcion = [string](Get-DicValor $Raw $k); break }
    }

    $version = '1.0'
    foreach ($k in @('version','Version')) {
        if (Get-DicTiene $Raw $k) { $version = [string](Get-DicValor $Raw $k); break }
    }

    $tenantDomain = $null
    foreach ($k in @('tenantDomain','TenantDomain')) {
        $v = Get-DicValor $Raw $k
        if (-not [string]::IsNullOrWhiteSpace([string]$v)) { $tenantDomain = [string]$v; break }
    }

    # Variables de resolución: lo pasado > derivado de tenantDomain
    $vars = @{}
    if ($Variables) { foreach ($k in $Variables.Keys) { $vars[$k] = $Variables[$k] } }
    if ($tenantDomain -and -not $vars.ContainsKey('tenant')) {
        $vars['tenant'] = $tenantDomain
    }
    if ($tenantDomain -and -not $vars.ContainsKey('tenantDomain')) {
        $vars['tenantDomain'] = $tenantDomain
    }

    # ----- secciones -----
    $secciones = [ordered]@{}
    $seccionesOriginales = @{}        # nombreInterno -> @{ NombreJson = ...; Alias = ... }
    $desconocidas = [System.Collections.Generic.List[string]]::new()
    $rawDesconocidas = [ordered]@{}

    $metadatos = @(
        'nombre','Nombre','descripcion','Descripcion',
        'version','Version','tenantDomain','TenantDomain'
    )

    # Acepta PSCustomObject (ConvertFrom-Json), Hashtable y diccionarios.
    $props = @()
    if ($Raw -is [System.Collections.IDictionary]) {
        $props = @($Raw.Keys | ForEach-Object { [pscustomobject]@{ Name = [string]$_; Value = $Raw[$_] } })
    } else {
        $props = @($Raw.PSObject.Properties)
    }

    foreach ($prop in $props) {
        if ($prop.Name -in $metadatos) { continue }

        $claveOriginal = $prop.Name
        $capacidad = Get-LabCapacidadPorSeccion -NombreSeccion $claveOriginal

        if (-not $capacidad) {
            $desconocidas.Add($claveOriginal)
            $rawDesconocidas[$claveOriginal] = $prop.Value
            continue
        }

        $nombreInterno = [string](Get-DicValor $capacidad 'Nombre')
        if ([string]::IsNullOrWhiteSpace($nombreInterno)) {
            $nombreInterno = $claveOriginal
        }

        # Resolver placeholders en los items
        $itemsResueltos = @()
        if ($null -ne $prop.Value) {
            $itemsResueltos = @(
                Resolve-Placeholders -Valor $prop.Value -Variables $vars
            )
        }

        # Acumular si la misma capacidad aparece con varias claves
        if ($secciones.Contains($nombreInterno)) {
            $acumulado = @($secciones[$nombreInterno]) + $itemsResueltos
            $secciones[$nombreInterno] = @($acumulado)
            $seccionesOriginales[$nombreInterno].Alias += $claveOriginal
        } else {
            $secciones[$nombreInterno] = @($itemsResueltos)
            $seccionesOriginales[$nombreInterno] = @{
                NombreJson = $claveOriginal
                Alias      = @($claveOriginal)
            }
        }
    }

    if ($desconocidas.Count -gt 0) {
        $errores.Add("Secciones sin capacidad registrada: $($desconocidas -join ', ').")
    }

    return @{
        Nombre              = $nombre
        Descripcion         = $descripcion
        Version             = $version
        SourcePath          = $sourcePath
        TenantDomain        = $tenantDomain
        Variables           = $vars
        Secciones           = $secciones
        SeccionesOriginales = $seccionesOriginales
        Desconocidas        = @($desconocidas)
        RawDesconocidas     = $rawDesconocidas
        Errores             = @($errores)
    }
}

# ============================================================
# VALIDACIÓN ROBUSTA
# ============================================================

function Invoke-LabValidacionEscenario {
    param(
        [Parameter(Mandatory = $true)]
        [object]$EscenarioNormalizado,

        [hashtable]$Contexto = @{}
    )

    $errores = [System.Collections.Generic.List[string]]::new()

    # 1) Errores arrastrados de la normalización
    if ($EscenarioNormalizado.ContainsKey('Errores')) {
        foreach ($e in @($EscenarioNormalizado['Errores'])) {
            if (-not [string]::IsNullOrWhiteSpace($e)) { $errores.Add($e) }
        }
    }

    if (-not $EscenarioNormalizado.ContainsKey('Secciones')) {
        $errores.Add('El escenario no tiene la clave Secciones.')
        return @($errores)
    }

    # 2) Contexto enriquecido (por si el ValidarDef lo necesita)
    $ctx = @{}
    foreach ($k in $Contexto.Keys) { $ctx[$k] = $Contexto[$k] }
    if (-not $ctx.ContainsKey('Escenario')) { $ctx['Escenario'] = $EscenarioNormalizado }
    if ($EscenarioNormalizado.ContainsKey('Nombre') -and -not $ctx.ContainsKey('Nombre')) {
        $ctx['Nombre'] = $EscenarioNormalizado['Nombre']
    }
    if ($EscenarioNormalizado.ContainsKey('TenantDomain') -and -not $ctx.ContainsKey('TenantDomain')) {
        $ctx['TenantDomain'] = $EscenarioNormalizado['TenantDomain']
    }
    if ($EscenarioNormalizado.ContainsKey('Variables')) {
        foreach ($k in $EscenarioNormalizado['Variables'].Keys) {
            if (-not $ctx.ContainsKey($k)) { $ctx[$k] = $EscenarioNormalizado['Variables'][$k] }
        }
    }

    $originales = if ($EscenarioNormalizado.ContainsKey('SeccionesOriginales')) {
        $EscenarioNormalizado['SeccionesOriginales']
    } else { @{} }

    # 3) Validar sección por sección
    foreach ($nombreInterno in @($EscenarioNormalizado['Secciones'].Keys)) {
        $def = @($EscenarioNormalizado['Secciones'][$nombreInterno])
        if ($def.Count -eq 0) { continue }

        $etiqueta = $nombreInterno
        if ($originales.ContainsKey($nombreInterno)) {
            $etiqueta = $originales[$nombreInterno].NombreJson
        }

        # 3a) Lookup de capacidad tolerante
        $cap = $null
        try { $cap = Get-LabCapacidad -Nombre $nombreInterno } catch { $cap = $null }
        if (-not $cap) {
            try { $cap = Get-LabCapacidadPorSeccion -NombreSeccion $etiqueta } catch { $cap = $null }
        }
        if (-not $cap) {
            $errores.Add("[$etiqueta] No hay capacidad registrada para la sección '$etiqueta' (interno: '$nombreInterno').")
            continue
        }

        # 3b) ValidarDef (compatible con hashtable y pscustomobject)
        $validarDef = Get-DicValor $cap 'ValidarDef'
        if ($validarDef -is [scriptblock]) {
            try {
                # Se pasan dos argumentos posicionales + contexto nombrado, para
                # que el scriptblock pueda elegir la firma que prefiera:
                #   param($def)
                #   param($def, $contexto)
                $errsCap = & $validarDef $def $ctx
            } catch {
                $errores.Add("[$etiqueta] Error ejecutando ValidarDef: $($_.Exception.Message)")
                continue
            }

            if ($null -ne $errsCap) {
                foreach ($e in @($errsCap)) {
                    if ([string]::IsNullOrWhiteSpace([string]$e)) { continue }
                    $errores.Add("[$etiqueta] $e")
                }
            }
        }
    }

    return @($errores)
}

# ============================================================
# RUTAS Y LISTADO DE ESCENARIOS
# ============================================================

function Get-LabEscenariosPath {
    <#
    .SYNOPSIS
        Devuelve la carpeta donde viven los escenarios JSON (escenarios/escenario).
    .DESCRIPTION
        La crea si no existe para que cualquier guardado posterior funcione.
    #>
    $ruta = Join-Path $PSScriptRoot 'escenarios/escenario'
    if (-not (Test-Path -LiteralPath $ruta -PathType Container)) {
        try { $null = New-Item -Path $ruta -ItemType Directory -Force } catch { }
    }
    return $ruta
}

function Get-LabPlantillasPath {
    <#
    .SYNOPSIS
        Devuelve la carpeta de plantillas de escenarios (escenarios/plantillas).
    #>
    $ruta = Join-Path $PSScriptRoot 'escenarios/plantillas'
    if (-not (Test-Path -LiteralPath $ruta -PathType Container)) {
        try { $null = New-Item -Path $ruta -ItemType Directory -Force } catch { }
    }
    return $ruta
}

function Get-LabEscenariosDisponibles {
    <#
    .SYNOPSIS
        Lista los nombres (sin extensión) de los escenarios disponibles.
    .DESCRIPTION
        Devuelve el nombre sin '.json', ordenado alfabéticamente. Si hay un
        escenario y una plantilla con el mismo nombre, se deduplica.
    #>
    $nombres = [System.Collections.Generic.List[string]]::new()

    foreach ($dir in @((Get-LabEscenariosPath), (Get-LabPlantillasPath))) {
        if ([string]::IsNullOrWhiteSpace($dir)) { continue }
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }

        foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
            $n = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
            if ([string]::IsNullOrWhiteSpace($n)) { continue }
            if (-not ($nombres | Where-Object { [string]::Equals($_, $n, [StringComparison]::OrdinalIgnoreCase) })) {
                $nombres.Add($n)
            }
        }
    }

    return @($nombres | Sort-Object)
}

function Resolve-LabEscenarioPath {
    <#
    .SYNOPSIS
        Devuelve la ruta completa de un escenario por nombre, buscando en
        escenarios/escenario y escenarios/plantillas. $null si no existe.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Nombre
    )

    if ([string]::IsNullOrWhiteSpace($Nombre)) { return $null }

    $nombreLimpio = [System.IO.Path]::GetFileNameWithoutExtension($Nombre.Trim())

    foreach ($dir in @((Get-LabEscenariosPath), (Get-LabPlantillasPath))) {
        if ([string]::IsNullOrWhiteSpace($dir)) { continue }
        $p = Join-Path $dir "$nombreLimpio.json"
        if (Test-Path -LiteralPath $p -PathType Leaf) { return $p }
    }
    return $null
}

# ============================================================
# EXPORTACIÓN (normalizado -> JSON del escenario)
# ============================================================

function ConvertFrom-LabEscenarioNormalizado {
    <#
    .SYNOPSIS
        Convierte un escenario normalizado (en memoria) al objeto JSON
        que se escribe en disco.
    .DESCRIPTION
        Contrapartida de ConvertTo-LabEscenarioNormalizado. Usa la clave
        JSON original (SeccionesOriginales.NombreJson) o, si no consta,
        la SeccionJson de la capacidad. Conserva las secciones desconocidas
        para no perder datos del usuario.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$EscenarioNormalizado
    )

    $obj = [ordered]@{}

    $nombre = $null
    $descripcion = $null
    $version = '1.0'
    $tenantDomain = $null

    if ($EscenarioNormalizado -is [System.Collections.IDictionary]) {
        if ($EscenarioNormalizado.Contains('Nombre')) { $nombre = $EscenarioNormalizado['Nombre'] }
        if ($EscenarioNormalizado.Contains('Descripcion')) { $descripcion = $EscenarioNormalizado['Descripcion'] }
        if ($EscenarioNormalizado.Contains('Version') -and $EscenarioNormalizado['Version']) { $version = $EscenarioNormalizado['Version'] }
        if ($EscenarioNormalizado.Contains('TenantDomain')) { $tenantDomain = $EscenarioNormalizado['TenantDomain'] }
    } else {
        $nombre = Get-DicValor $EscenarioNormalizado 'Nombre'
        $descripcion = Get-DicValor $EscenarioNormalizado 'Descripcion'
        $v = Get-DicValor $EscenarioNormalizado 'Version'
        if ($v) { $version = $v }
        $tenantDomain = Get-DicValor $EscenarioNormalizado 'TenantDomain'
    }

    $obj['nombre'] = $nombre
    $obj['descripcion'] = $descripcion
    $obj['version'] = $version
    if (-not [string]::IsNullOrWhiteSpace([string]$tenantDomain)) {
        $obj['tenantDomain'] = $tenantDomain
    }

    $secciones = Get-DicValor $EscenarioNormalizado 'Secciones'
    $originales = Get-DicValor $EscenarioNormalizado 'SeccionesOriginales'
    $desconocidas = Get-DicValor $EscenarioNormalizado 'RawDesconocidas'

    if ($secciones) {
        foreach ($nombreInterno in @($secciones.Keys)) {
            $items = @($secciones[$nombreInterno])
            if ($items.Count -eq 0) { continue }

            $clave = $nombreInterno
            if ($originales -and $originales.ContainsKey($nombreInterno)) {
                $clave = $originales[$nombreInterno].NombreJson
            } else {
                $cap = Get-LabCapacidadPorSeccion -NombreSeccion $nombreInterno
                if ($cap -and $cap.ContainsKey('SeccionJson') -and -not [string]::IsNullOrWhiteSpace([string]$cap.SeccionJson)) {
                    $clave = [string]$cap.SeccionJson
                }
            }

            $obj[$clave] = @($items)
        }
    }

    if ($desconocidas) {
        $claves = if ($desconocidas -is [System.Collections.IDictionary]) { @($desconocidas.Keys) } else { @($desconocidas.PSObject.Properties.Name) }
        foreach ($k in $claves) {
            if (-not $obj.Contains($k)) {
                $obj[$k] = Get-DicValor $desconocidas $k
            }
        }
    }

    return [pscustomobject]$obj
}
