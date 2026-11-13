<#
.SYNOPSIS
    Librería de normalización y validación de escenarios.
.DESCRIPTION
    Proporciona:
      - ConvertTo-LabEscenarioNormalizado: convierte un JSON (o un objeto
        ya deserializado) en un objeto con todas las secciones posibles,
        agrupadas por Nombre de capacidad.
<<<<<<< Updated upstream
      - ConvertFrom-LabEscenarioNormalizado: hace el camino inverso,
        generando un objeto serializable a JSON.
      - Listado y carga de escenarios, vulnerabilidades y plantillas.

    Estructura del objeto normalizado:
      [pscustomobject]@{
        Nombre          = 'escenarioej1'
        Descripcion     = '...'
        Version         = '1.0'
        SourcePath      = 'C:\...\escenarioej1.json'   # $null si vino de memoria
        Secciones       = @{ 'Usuarios' = @(...); 'Grupos' = @(...); ... }
        Desconocidas    = @('pim', 'otraSeccion')       # nombres de secciones sin capacidad
        RawDesconocidas = @{ 'pim' = @(...) }           # valores originales de esas secciones
        Errores         = @()                           # errores de normalización
      }

    Cada sección es siempre un array (nunca $null, nunca objeto suelto).
    Las secciones desconocidas se preservan en RawDesconocidas para que
    ConvertFrom-LabEscenarioNormalizado pueda reconstruirlas sin pérdida.

    CAPACIDADES SIN SECCIONJSON:
    Algunas capacidades (por ejemplo, Vulnerabilidades) tienen
    SeccionJson = $null porque no consumen una sección del escenario:
    se aplican sobre objetos existentes desde un flujo dedicado. Esas
    capacidades NO crean entrada en Secciones. Si un escenario antiguo
    tuviera una sección con su Alias, caería en Desconocidas y se
    preservaría en RawDesconocidas.

    CATÁLOGO DE VULNERABILIDADES:
    Get-LabVulnerabilidad y Get-LabVulnerabilidadesDisponibles leen el
    catálogo de escenarios/vulnerab/*.json. Se usan desde
    cap_vulnerabilidades.ps1 [C] para cargar una vulnerabilidad por
    nombre y, opcionalmente, sobrescribir sus parámetros.
.NOTES
    Depende de lib_ui.ps1 y lib_caps.ps1.
    Se carga por dot-sourcing desde menu.ps1.
#>

# ============================================================
# RUTAS CANÓNICAS
# ============================================================
$script:LabEscenariosRoot       = Join-Path $PSScriptRoot 'escenarios'
$script:LabEscenariosPath       = Join-Path $script:LabEscenariosRoot 'escenario'
$script:LabVulnerabilidadesPath = Join-Path $script:LabEscenariosRoot 'vulnerab'
$script:LabPlantillasPath       = Join-Path $script:LabEscenariosRoot 'plantillas'
$script:LabSecretsPath          = Join-Path $script:LabEscenariosRoot '.secrets'

# ============================================================
# RUTAS
# ============================================================

function Get-LabEscenariosPath {
    <#
    .SYNOPSIS
        Devuelve la ruta absoluta de la carpeta de escenarios.
    #>
    return $script:LabEscenariosPath
}

function Get-LabVulnerabilidadesPath {
    <#
    .SYNOPSIS
        Devuelve la ruta absoluta de la carpeta de vulnerabilidades.
    #>
    return $script:LabVulnerabilidadesPath
}

function Get-LabPlantillasPath {
    <#
    .SYNOPSIS
        Devuelve la ruta absoluta de la carpeta de plantillas.
    #>
    return $script:LabPlantillasPath
}

function Get-LabSecretsPath {
    <#
    .SYNOPSIS
        Devuelve la ruta absoluta de la carpeta de semillas locales.
    #>
    return $script:LabSecretsPath
}

# ============================================================
# LISTADO
# ============================================================

function Get-LabEscenariosDisponibles {
    <#
    .SYNOPSIS
        Devuelve los nombres (sin extensión) de los escenarios disponibles.
    #>
    if (-not (Test-Path -Path $script:LabEscenariosPath)) { return @() }
    $files = Get-ChildItem -Path $script:LabEscenariosPath -Filter '*.json' -File -ErrorAction SilentlyContinue
    return @($files | ForEach-Object { $_.BaseName } | Sort-Object)
}

function Get-LabVulnerabilidadesDisponibles {
    <#
    .SYNOPSIS
        Devuelve los nombres (sin extensión) de las vulnerabilidades disponibles
        en el catálogo (escenarios/vulnerab/*.json).
    .DESCRIPTION
        Se usa desde cap_vulnerabilidades.ps1 [C] para listar las
        vulnerabilidades que el operador puede cargar por nombre.
    #>
    if (-not (Test-Path -Path $script:LabVulnerabilidadesPath)) { return @() }
    $files = Get-ChildItem -Path $script:LabVulnerabilidadesPath -Filter '*.json' -File -ErrorAction SilentlyContinue
    return @($files | ForEach-Object { $_.BaseName } | Sort-Object)
}

function Get-LabPlantillasDisponibles {
    <#
    .SYNOPSIS
        Devuelve los nombres (sin extensión) de las plantillas disponibles.
    #>
    if (-not (Test-Path -Path $script:LabPlantillasPath)) { return @() }
    $files = Get-ChildItem -Path $script:LabPlantillasPath -Filter '*.json' -File -ErrorAction SilentlyContinue
    return @($files | ForEach-Object { $_.BaseName } | Sort-Object)
}

# ============================================================
# NORMALIZACIÓN
# ============================================================

=======
      - ConvertFrom-LabEscenarioNormalizado: hace el camino inverso.
      - Listado y carga de escenarios, vulnerabilidades y plantillas.
#>

# ============================================================
# RUTAS CANÓNICAS
# ============================================================
$script:LabEscenariosRoot       = Join-Path $PSScriptRoot 'escenarios'
$script:LabEscenariosPath       = Join-Path $script:LabEscenariosRoot 'escenario'
$script:LabVulnerabilidadesPath = Join-Path $script:LabEscenariosRoot 'vulnerab'
$script:LabPlantillasPath       = Join-Path $script:LabEscenariosRoot 'plantillas'
$script:LabSecretsPath          = Join-Path $script:LabEscenariosRoot '.secrets'

# ============================================================
# RUTAS
# ============================================================
function Get-LabEscenariosPath { return $script:LabEscenariosPath }
function Get-LabVulnerabilidadesPath { return $script:LabVulnerabilidadesPath }
function Get-LabPlantillasPath { return $script:LabPlantillasPath }
function Get-LabSecretsPath { return $script:LabSecretsPath }

# ============================================================
# LISTADO
# ============================================================
function Get-LabEscenariosDisponibles {
    if (-not (Test-Path -Path $script:LabEscenariosPath)) { return @() }
    $files = Get-ChildItem -Path $script:LabEscenariosPath -Filter '*.json' -File -ErrorAction SilentlyContinue
    return @($files | ForEach-Object { $_.BaseName } | Sort-Object)
}

function Get-LabVulnerabilidadesDisponibles {
    if (-not (Test-Path -Path $script:LabVulnerabilidadesPath)) { return @() }
    $files = Get-ChildItem -Path $script:LabVulnerabilidadesPath -Filter '*.json' -File -ErrorAction SilentlyContinue
    return @($files | ForEach-Object { $_.BaseName } | Sort-Object)
}

function Get-LabPlantillasDisponibles {
    if (-not (Test-Path -Path $script:LabPlantillasPath)) { return @() }
    $files = Get-ChildItem -Path $script:LabPlantillasPath -Filter '*.json' -File -ErrorAction SilentlyContinue
    return @($files | ForEach-Object { $_.BaseName } | Sort-Object)
}

# ============================================================
# NORMALIZACIÓN
# ============================================================
function ConvertTo-LabArraySeccion {
    <#
    .SYNOPSIS
        Devuelve el contenido de una sección del JSON siempre como array.
    .DESCRIPTION
        Sustituye a `@($valor)` + `[string]::IsNullOrWhiteSpace([string]$valor)`.
        Esa conversión a [string] de un array devuelve cadena vacía, así que
        cualquier sección con datos se trataba como vacía. Aquí solo se
        considera vacío un $null o una cadena en blanco.
    #>
    param(
        [Parameter(Mandatory = $false)] $Valor
    )

    if ($null -eq $Valor) { return @() }
    if ($Valor -is [string] -and [string]::IsNullOrWhiteSpace($Valor)) { return @() }
    return @($Valor)
}

>>>>>>> Stashed changes
function ConvertTo-LabEscenarioNormalizado {
    <#
    .SYNOPSIS
        Convierte un JSON de escenario en un objeto normalizado por capacidad.
    .DESCRIPTION
        Acepta o bien la ruta de un .json, o bien un objeto ya deserializado.
        Descubre las secciones a partir de las capacidades registradas.
        Las secciones no reclamadas por ninguna capacidad van a 'Desconocidas'
        (solo nombres) y sus valores originales a 'RawDesconocidas'.

        Capacidades con SeccionJson = $null (por ejemplo, Vulnerabilidades)
        no crean entrada en Secciones: se aplican desde un flujo dedicado,
        no forman parte del escenario. Si un escenario antiguo tuviera una
        sección con su Alias, caería en Desconocidas y se preservaría en
        RawDesconocidas.
    .PARAMETER Path
        Ruta de un fichero .json.
    .PARAMETER Raw
        Objeto ya deserializado. Si se especifica, se ignora Path.
    .OUTPUTS
        PSCustomObject con la estructura normalizada.
    #>
    param(
        [string]$Path = $null,
        [object]$Raw = $null
    )

    $sourcePath = $null

    # Si no nos pasan el objeto, leemos el archivo
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

    $errores = @()
<<<<<<< Updated upstream

    $nombre = $null
    if ($Raw.PSObject.Properties['nombre'])      { $nombre = [string]$Raw.nombre }
    elseif ($Raw.PSObject.Properties['Nombre'])  { $nombre = [string]$Raw.Nombre }
    elseif ($sourcePath)                          { $nombre = [System.IO.Path]::GetFileNameWithoutExtension($sourcePath) }

    $descripcion = $null
    if ($Raw.PSObject.Properties['descripcion'])     { $descripcion = [string]$Raw.descripcion }
    elseif ($Raw.PSObject.Properties['Descripcion']) { $descripcion = [string]$Raw.Descripcion }

    $version = '1.0'
    if ($Raw.PSObject.Properties['version']) { $version = [string]$Raw.version }

    $clavesJson = @($Raw.PSObject.Properties.Name)

    $secciones = @{}
    $capacidades = Get-LabCapacidades

    foreach ($cap in $capacidades) {
        $nombreCap = $cap.Nombre

        if ([string]::IsNullOrWhiteSpace($cap.SeccionJson)) {
            continue
        }

        $candidatos = @($cap.SeccionJson)
        if ($cap.ContainsKey('Alias') -and $cap.Alias) {
            $candidatos += @($cap.Alias)
        }

        $encontrada = $null
        foreach ($c in $candidatos) {
            if ($clavesJson -contains $c) { $encontrada = $c; break }
        }

        if ($encontrada) {
            $valor = $Raw.$encontrada
            if ($null -eq $valor -or [string]::IsNullOrWhiteSpace([string]$valor)) {
                $secciones[$nombreCap] = @()
            } else {
                # IMPORTANTE: Forzamos a array incluso si solo hay un elemento o es una propiedad Count
                $secciones[$nombreCap] = @($valor)
            }
=======
    $nombre = $null
    $descripcion = $null
    $version = '1.0'

    # Extraer metadatos básicos de forma segura
    if ((Get-LabPropiedadValor -Objeto $Raw -Nombre 'nombre'))      { $nombre = [string]$Raw.nombre }
    elseif ((Get-LabPropiedadValor -Objeto $Raw -Nombre 'Nombre'))  { $nombre = [string]$Raw.Nombre }
    elseif ($sourcePath)                          { $nombre = [System.IO.Path]::GetFileNameWithoutExtension($sourcePath) }

    if ((Get-LabPropiedadValor -Objeto $Raw -Nombre 'descripcion'))     { $descripcion = [string]$Raw.descripcion }
    elseif ((Get-LabPropiedadValor -Objeto $Raw -Nombre 'Descripcion')) { $descripcion = [string]$Raw.Descripcion }
    if ((Get-LabPropiedadValor -Objeto $Raw -Nombre 'version'))         { $version = [string]$Raw.version }

    $clavesJson = @($Raw.PSObject.Properties.Name)
    $secciones = @{}
    $capacidades = @(Get-LabCapacidades)
    # $clavesJson se recalcula en cada vuelta: el Where-Object del final del
    # bucle sustituye el array, y un filtro sobre un array que cambia de
    # tamaño devuelve $null en PS7, lo que dejaba 'usuarios'/'grupos' como
    # claves desconocidas y las secciones vacías.

    foreach ($cap in $capacidades) {
        $nombreCap = $cap.Nombre
        if ([string]::IsNullOrWhiteSpace($cap.SeccionJson)) { continue }

        $candidatos = @($cap.SeccionJson)
        if ($cap.ContainsKey('Alias') -and $cap.Alias) {
            $candidatos += @($cap.Alias)
        }

        $encontrada = $null
        foreach ($c in $candidatos) {
            if ($clavesJson -contains $c) { $encontrada = $c; break }
        }

        if ($encontrada) {
            $valor = $Raw.$encontrada
            $secciones[$nombreCap] = ConvertTo-LabArraySeccion -Valor $valor
>>>>>>> Stashed changes
            $clavesJson = @($clavesJson | Where-Object { $_ -ne $encontrada })
        } else {
            $secciones[$nombreCap] = @()
        }
    }

<<<<<<< Updated upstream
    # Secciones desconocidas: guardar nombre Y valor original
    $desconocidas = @($clavesJson | Where-Object { $_ -notin @('nombre','Nombre','descripcion','Descripcion','version') })
=======
    # Secciones desconocidas
    $desconocidas = @($clavesJson | Where-Object { $_ -notmatch '^(?i)(nombre|descripcion|version)$' })
>>>>>>> Stashed changes
    $rawDesconocidas = @{}
    foreach ($d in $desconocidas) {
        $rawDesconocidas[$d] = $Raw.$d
    }

    if ($desconocidas.Count -gt 0) {
        $errores += "Secciones sin capacidad registrada: $($desconocidas -join ', '). ¿Carpeta desactivada?"
    }

    return [pscustomobject]@{
        Nombre          = $nombre
        Descripcion     = $descripcion
        Version         = $version
        SourcePath      = $sourcePath
        Secciones       = $secciones
        Desconocidas    = $desconocidas
        RawDesconocidas = $rawDesconocidas
        Errores         = $errores
    }
}

function ConvertFrom-LabEscenarioNormalizado {
<<<<<<< Updated upstream
    <#
    .SYNOPSIS
        Convierte un escenario normalizado en un objeto serializable a JSON.
    .DESCRIPTION
        Genera un objeto con 'nombre', 'descripcion', 'version' y una clave
        por cada capacidad con sección no vacía, usando su SeccionJson.
        Las secciones desconocidas se reconstruyen desde RawDesconocidas
        para no perder datos.
    .PARAMETER EscenarioNormalizado
        Resultado de ConvertTo-LabEscenarioNormalizado.
    .OUTPUTS
        PSCustomObject listo para ConvertTo-Json.
    #>
=======
>>>>>>> Stashed changes
    param(
        [Parameter(Mandatory = $true)]
        [object]$EscenarioNormalizado
    )

    $obj = [ordered]@{}
    if ($EscenarioNormalizado.Nombre)      { $obj['nombre']      = $EscenarioNormalizado.Nombre }
    if ($EscenarioNormalizado.Descripcion) { $obj['descripcion'] = $EscenarioNormalizado.Descripcion }
    if ($EscenarioNormalizado.Version)     { $obj['version']     = $EscenarioNormalizado.Version }

    foreach ($nombreCap in $EscenarioNormalizado.Secciones.Keys) {
        $def = @($EscenarioNormalizado.Secciones[$nombreCap])
        if ($def.Count -eq 0) { continue }

        $cap = Get-LabCapacidad -Nombre $nombreCap
        if (-not $cap -or [string]::IsNullOrWhiteSpace($cap.SeccionJson)) {
            $obj[$nombreCap] = $def
            continue
        }
        $obj[$cap.SeccionJson] = $def
    }

<<<<<<< Updated upstream
    # Reconstruir desconocidas con su valor original
    if ($EscenarioNormalizado.PSObject.Properties['RawDesconocidas'] -and
        $null -ne $EscenarioNormalizado.RawDesconocidas) {
=======
    if ((Get-LabPropiedadValor -Objeto $EscenarioNormalizado -Nombre 'RawDesconocidas') -and $null -ne $EscenarioNormalizado.RawDesconocidas) {
>>>>>>> Stashed changes
        foreach ($d in $EscenarioNormalizado.Desconocidas) {
            if ([string]::IsNullOrWhiteSpace($d)) { continue }
            if ($EscenarioNormalizado.RawDesconocidas.ContainsKey($d)) {
                $obj[$d] = $EscenarioNormalizado.RawDesconocidas[$d]
            } else {
                $obj[$d] = @()
            }
        }
    } else {
<<<<<<< Updated upstream
        # Fallback: sin RawDesconocidas, se ponen vacías
=======
>>>>>>> Stashed changes
        foreach ($d in @($EscenarioNormalizado.Desconocidas)) {
            if ([string]::IsNullOrWhiteSpace($d)) { continue }
            $obj[$d] = @()
        }
    }

    return [pscustomobject]$obj
}

function Test-LabEscenarioTieneSecciones {
<<<<<<< Updated upstream
    <#
    .SYNOPSIS
        Devuelve $true si el escenario normalizado tiene al menos una sección con contenido.
    .PARAMETER EscenarioNormalizado
        Resultado de ConvertTo-LabEscenarioNormalizado.
    .OUTPUTS
        $true si hay contenido, $false si todas las secciones están vacías.
    #>
=======
>>>>>>> Stashed changes
    param(
        [Parameter(Mandatory = $true)]
        [object]$EscenarioNormalizado
    )

    foreach ($nombreCap in $EscenarioNormalizado.Secciones.Keys) {
        if (@($EscenarioNormalizado.Secciones[$nombreCap]).Count -gt 0) {
            return $true
        }
    }
    return $false
}

# ============================================================
# CARGA DE VULNERABILIDADES (CATÁLOGO)
# ============================================================
<<<<<<< Updated upstream

function Get-LabVulnerabilidad {
    <#
    .SYNOPSIS
        Carga una vulnerabilidad del catálogo por nombre.
    .DESCRIPTION
        Lee escenarios/vulnerab/<Nombre>.json y devuelve un objeto con
        Nombre, Descripcion, Tipo, Parametros y RequiereLicencia.

        Se usa desde cap_vulnerabilidades.ps1 [C] para cargar una
        vulnerabilidad por nombre y, opcionalmente, sobrescribir sus
        parámetros.
    .PARAMETER Nombre
        Nombre de la vulnerabilidad (sin extensión).
    .OUTPUTS
        PSCustomObject con Nombre, Descripcion, Tipo, Parametros, RequiereLicencia.
    #>
=======
function Get-LabVulnerabilidad {
>>>>>>> Stashed changes
    param(
        [Parameter(Mandatory = $true)]
        [string]$Nombre
    )

    $path = Join-Path $script:LabVulnerabilidadesPath "$Nombre.json"
    if (-not (Test-Path -Path $path)) {
        throw "No existe la vulnerabilidad '$Nombre' en $($script:LabVulnerabilidadesPath)."
    }

    try {
        $raw = Get-Content -Path $path -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        throw "La vulnerabilidad '$Nombre' no es un JSON válido: $($_.Exception.Message)"
    }

<<<<<<< Updated upstream
    if (-not $raw.PSObject.Properties['tipo']) {
        throw "La vulnerabilidad '$Nombre' no declara 'tipo'."
    }

    # Normalizar parametros: acepta objeto o hashtable
    $parametros = @{}
    if ($raw.PSObject.Properties['parametros'] -and $null -ne $raw.parametros) {
        if ($raw.parametros -is [hashtable]) {
            foreach ($k in $raw.parametros.Keys) {
                $parametros[$k] = $raw.parametros[$k]
            }
        } else {
            foreach ($p in $raw.parametros.PSObject.Properties) {
                $parametros[$p.Name] = $p.Value
            }
=======
    if (-not ((Get-LabPropiedadValor -Objeto $raw -Nombre 'tipo'))) {
        throw "La vulnerabilidad '$Nombre' no declara 'tipo'."
    }

    $parametros = @{}
    if ((Get-LabPropiedadValor -Objeto $raw -Nombre 'parametros') -and $null -ne $raw.parametros) {
        if ($raw.parametros -is [hashtable]) {
            foreach ($k in $raw.parametros.Keys) { $parametros[$k] = $raw.parametros[$k] }
        } else {
            foreach ($p in $raw.parametros.PSObject.Properties) { $parametros[$p.Name] = $p.Value }
>>>>>>> Stashed changes
        }
    }

    return [pscustomobject]@{
        Nombre           = $Nombre
<<<<<<< Updated upstream
        Descripcion      = if ($raw.PSObject.Properties['descripcion']) { $raw.descripcion } else { $null }
        Tipo             = $raw.tipo
        Parametros       = $parametros
        RequiereLicencia = if ($raw.PSObject.Properties['requiereLicencia']) { $raw.requiereLicencia } else { $null }
=======
        Descripcion      = if ((Get-LabPropiedadValor -Objeto $raw -Nombre 'descripcion')) { $raw.descripcion } else { $null }
        Tipo             = $raw.tipo
        Parametros       = $parametros
        RequiereLicencia = if ((Get-LabPropiedadValor -Objeto $raw -Nombre 'requiereLicencia')) { $raw.requiereLicencia } else { $null }
>>>>>>> Stashed changes
    }
}

# ============================================================
# PLANTILLAS
# ============================================================
<<<<<<< Updated upstream

function Get-LabPlantilla {
    <#
    .SYNOPSIS
        Carga una plantilla por nombre y la normaliza.
    .PARAMETER Nombre
        Nombre de la plantilla (sin extensión).
    .OUTPUTS
        PSCustomObject normalizado.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Nombre
    )

=======
function Get-LabPlantilla {
    param([Parameter(Mandatory = $true)][string]$Nombre)
>>>>>>> Stashed changes
    $path = Join-Path $script:LabPlantillasPath "$Nombre.json"
    if (-not (Test-Path -Path $path)) {
        throw "No existe la plantilla '$Nombre' en $($script:LabPlantillasPath)."
    }
    return ConvertTo-LabEscenarioNormalizado -Path $path
}

function Save-LabPlantilla {
<<<<<<< Updated upstream
    <#
    .SYNOPSIS
        Guarda un escenario normalizado como plantilla.
    .PARAMETER EscenarioNormalizado
        Escenario normalizado.
    .PARAMETER Nombre
        Nombre de la plantilla (sin extensión).
    .OUTPUTS
        $true si se guardó, $false si falló.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$EscenarioNormalizado,

        [Parameter(Mandatory = $true)]
        [string]$Nombre
    )

=======
    param(
        [Parameter(Mandatory = $true)][object]$EscenarioNormalizado,
        [Parameter(Mandatory = $true)][string]$Nombre
    )
>>>>>>> Stashed changes
    try {
        if (-not (Test-Path -Path $script:LabPlantillasPath)) {
            $null = New-Item -ItemType Directory -Path $script:LabPlantillasPath -Force
        }
        $obj = ConvertFrom-LabEscenarioNormalizado -EscenarioNormalizado $EscenarioNormalizado
        $path = Join-Path $script:LabPlantillasPath "$Nombre.json"
        $obj | ConvertTo-Json -Depth 15 | Set-Content -Path $path -Encoding UTF8 -Force
        return $true
    } catch {
        Write-LabWarn "No se pudo guardar la plantilla '$Nombre': $($_.Exception.Message)"
        return $false
    }
}