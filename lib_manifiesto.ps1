<#
.SYNOPSIS
    Librería de gestión del manifiesto del laboratorio (v2).
.DESCRIPTION
    Proporciona:
      - Ruta canónica del manifiesto (manifiesto_lab.json).
      - Estructura v2: metadatos + lista plana de objetos + vulnerabilidades.
      - Migración automática desde v1 (listas por tipo) al cargar.
      - Normalización de campos (objetos y vulnerabilidades siempre arrays).
      - Estado resumido para el menú.
      - Guardado y renombrado como procesado.

    Estructura v2:
      {
        "manifestVersion": "2.0",
        "fecha": "...",
        "tenantId": "...",
        "tenantDomain": "...",
        "nivel": "P1",
        "escenario": "...",
        "semilla": "...",
        "objetos": [ { id, tipo, capacidad, estado, timestamp, tenantId, datos }, ... ],
        "vulnerabilidades": [ { id, nombre, tipo, capacidad, estado, timestamp, datos }, ... ]
      }

    ESTADOS DE OBJETOS:
      'creado'        - creado por el laboratorio en esta ejecución
      'reutilizado'   - ya existía en el tenant (creado por una ejecución
                        anterior del laboratorio), reutilizado sin crear
      'preexistente'  - ya existía ANTES del laboratorio (estaba en el
                        snapshot pre-lab). NO se adopta, NO se modifica,
                        NO se revierte.
      'fallido'       - intento de creación fallido; se puede reintentar la reversión
      'revertido'     - ya revertido
      'no-revertido'  - no se pudo revertir (capacidad no disponible, objectId distinto)
      'omitido'       - omitido por alguna razón (por ejemplo, preexistente)

    SEGURIDAD:
    El manifiesto NO contiene contraseñas. Solo guarda identificadores y
    datos necesarios para revertir. Las contraseñas se derivan de la
    semilla local del escenario y nunca se persisten aquí.

    Los objetos con estado 'preexistente' son ignorados por el cleanup.
    Ese estado lo asigna lib_creadores.ps1 cuando detecta que el objeto
    ya existía antes del laboratorio (snapshot pre-lab).
.NOTES
    Depende de lib_ui.ps1.
    Se carga por dot-sourcing desde menu.ps1.
#>

# ============================================================
# RUTA CANÓNICA
# ============================================================
$script:LabManifiestoFileName = 'manifiesto_lab.json'
$script:LabManifiestoPath     = Join-Path $PSScriptRoot $script:LabManifiestoFileName
$script:LabManifiestoVersion  = '2.0'

# Estados que el cleanup puede intentar revertir
$script:LabEstadosReversibles = @('creado','reutilizado','fallido')

# Estados que el cleanup debe ignorar
$script:LabEstadosIgnorados = @('preexistente','revertido','no-revertido','omitido')

# ============================================================
# FUNCIONES PÚBLICAS: RUTAS Y EXISTENCIA
# ============================================================

function Get-LabManifiestoPath {
    <#
    .SYNOPSIS
        Devuelve la ruta absoluta del manifiesto estándar.
    #>
    return $script:LabManifiestoPath
}

function Test-LabManifiestoExists {
    <#
    .SYNOPSIS
        Devuelve $true si existe el manifiesto estándar.
    #>
    return (Test-Path -Path $script:LabManifiestoPath)
}

# ============================================================
# ESTRUCTURA BASE
# ============================================================

function New-LabManifiestoVacio {
    <#
    .SYNOPSIS
        Devuelve un manifiesto v2 vacío, listo para rellenar.
    .PARAMETER Escenario
        Nombre del escenario o de la sesión manual.
    .PARAMETER Nivel
        Nivel de licencia elegido ('Free', 'P1', 'P2').
    .PARAMETER Semilla
        Nombre de la semilla usada (no la semilla en sí).
    .OUTPUTS
        PSCustomObject con la estructura v2 vacía.
    #>
    param(
        [string]$Escenario = $null,
        [string]$Nivel = 'Free',
        [string]$Semilla = $null
    )

    return [pscustomobject]@{
        manifestVersion  = $script:LabManifiestoVersion
        fecha            = (Get-Date).ToString('o')
        tenantId         = $null
        tenantDomain     = $null
        nivel            = $Nivel
        escenario        = $Escenario
        semilla          = $Semilla
        objetos          = @()
        vulnerabilidades = @()
    }
}

# ============================================================
# CARGA Y NORMALIZACIÓN
# ============================================================

function Get-LabManifiesto {
    <#
    .SYNOPSIS
        Lee y normaliza el manifiesto. Devuelve $null si no existe.
    .DESCRIPTION
        - Si el manifiesto es v1 (sin manifestVersion o con listas por tipo),
          lo migra a v2 automáticamente.
        - Garantiza que 'objetos' y 'vulnerabilidades' son arrays.
        - Garantiza que cada objeto tiene los campos comunes.
    .PARAMETER Path
        Ruta alternativa del manifiesto. Si se omite, se usa la estándar.
    .OUTPUTS
        PSCustomObject v2 normalizado, o $null si no existe.
    #>
    param(
        [string]$Path = $null
    )

    if (-not $Path) { $Path = $script:LabManifiestoPath }
    if (-not (Test-Path -Path $Path)) { return $null }

    $raw = Get-Content -Path $Path -Raw -Encoding UTF8 | ConvertFrom-Json

    $version = $null
    if ($raw.PSObject.Properties['manifestVersion']) {
        $version = [string]$raw.manifestVersion
    }

    if (-not $version -or $version -ne $script:LabManifiestoVersion) {
        $raw = ConvertTo-LabManifiestoV2 -Raw $raw
    }

    $objetos = @()
    if ($raw.PSObject.Properties['objetos'] -and $null -ne $raw.objetos) {
        $objetos = @($raw.objetos)
    }

    $vulns = @()
    if ($raw.PSObject.Properties['vulnerabilidades'] -and $null -ne $raw.vulnerabilidades) {
        $vulns = @($raw.vulnerabilidades)
    }

    $objetosNorm = @()
    foreach ($o in $objetos) {
        $objetosNorm += [pscustomobject]@{
            id        = if ($o.PSObject.Properties['id'])        { $o.id }        else { $null }
            tipo      = if ($o.PSObject.Properties['tipo'])      { $o.tipo }      else { 'Desconocido' }
            capacidad = if ($o.PSObject.Properties['capacidad']) { $o.capacidad } else { $null }
            estado    = if ($o.PSObject.Properties['estado'])    { $o.estado }    else { 'creado' }
            timestamp = if ($o.PSObject.Properties['timestamp']) { $o.timestamp } else { $null }
            tenantId  = if ($o.PSObject.Properties['tenantId'])  { $o.tenantId }  else { $null }
            datos     = if ($o.PSObject.Properties['datos'])     { $o.datos }     else { @{} }
        }
    }

    $vulnsNorm = @()
    foreach ($v in $vulns) {
        $vulnsNorm += [pscustomobject]@{
            id        = if ($v.PSObject.Properties['id'])        { $v.id }        else { $null }
            nombre    = if ($v.PSObject.Properties['nombre'])    { $v.nombre }    else { $null }
            tipo      = if ($v.PSObject.Properties['tipo'])      { $v.tipo }      else { 'Desconocido' }
            capacidad = if ($v.PSObject.Properties['capacidad']) { $v.capacidad } else { 'Vulnerabilidades' }
            estado    = if ($v.PSObject.Properties['estado'])    { $v.estado }    else { 'aplicada' }
            timestamp = if ($v.PSObject.Properties['timestamp']) { $v.timestamp } else { $null }
            datos     = if ($v.PSObject.Properties['datos'])     { $v.datos }     else { @{} }
        }
    }

    return [pscustomobject]@{
        manifestVersion  = $script:LabManifiestoVersion
        fecha            = if ($raw.PSObject.Properties['fecha'])        { $raw.fecha }        else { $null }
        tenantId         = if ($raw.PSObject.Properties['tenantId'])     { $raw.tenantId }     else { $null }
        tenantDomain     = if ($raw.PSObject.Properties['tenantDomain']) { $raw.tenantDomain } else { $null }
        nivel            = if ($raw.PSObject.Properties['nivel'])        { $raw.nivel }        else { 'Free' }
        escenario        = if ($raw.PSObject.Properties['escenario'])    { $raw.escenario }    else { $null }
        semilla          = if ($raw.PSObject.Properties['semilla'])      { $raw.semilla }      else { $null }
        objetos          = $objetosNorm
        vulnerabilidades = $vulnsNorm
    }
}

# ============================================================
# MIGRACIÓN v1 -> v2
# ============================================================

function ConvertTo-LabManifiestoV2 {
    <#
    .SYNOPSIS
        Convierte un manifiesto v1 (listas por tipo) a v2 (lista plana).
    .DESCRIPTION
        Los objetos migrados desde v1 se marcan como 'creado', porque v1
        no guardaba información de preexistencia. Es un compromiso: si
        el objeto era preexistente, el cleanup intentará borrarlo.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$Raw
    )

    $objetos = @()
    $script:LabContadorV2 = 0

    function New-IdV2 {
        $script:LabContadorV2++
        return ('obj-{0:D4}' -f $script:LabContadorV2)
    }

    $tenantId = if ($Raw.PSObject.Properties['TenantId']) { $Raw.TenantId } else { $null }
    $ts = if ($Raw.PSObject.Properties['Fecha']) { $Raw.Fecha } else { (Get-Date).ToString('o') }

    if ($Raw.PSObject.Properties['Usuarios'] -and $null -ne $Raw.Usuarios) {
        foreach ($upn in @($Raw.Usuarios)) {
            $objetos += [pscustomobject]@{
                id        = New-IdV2
                tipo      = 'Usuario'
                capacidad = 'Usuarios'
                estado    = 'creado'
                timestamp = $ts
                tenantId  = $tenantId
                datos     = @{ upn = [string]$upn }
            }
        }
    }

    if ($Raw.PSObject.Properties['Grupos'] -and $null -ne $Raw.Grupos) {
        foreach ($g in @($Raw.Grupos)) {
            $objetos += [pscustomobject]@{
                id        = New-IdV2
                tipo      = 'Grupo'
                capacidad = 'Grupos'
                estado    = 'creado'
                timestamp = $ts
                tenantId  = $tenantId
                datos     = @{ displayName = [string]$g }
            }
        }
    }

    if ($Raw.PSObject.Properties['Aplicaciones'] -and $null -ne $Raw.Aplicaciones) {
        foreach ($a in @($Raw.Aplicaciones)) {
            $objetos += [pscustomobject]@{
                id        = New-IdV2
                tipo      = 'Aplicacion'
                capacidad = 'Aplicaciones'
                estado    = 'creado'
                timestamp = $ts
                tenantId  = $tenantId
                datos     = @{ displayName = [string]$a }
            }
        }
    }

    if ($Raw.PSObject.Properties['ServicePrincipals'] -and $null -ne $Raw.ServicePrincipals) {
        foreach ($spId in @($Raw.ServicePrincipals)) {
            $objetos += [pscustomobject]@{
                id        = New-IdV2
                tipo      = 'ServicePrincipal'
                capacidad = 'Aplicaciones'
                estado    = 'creado'
                timestamp = $ts
                tenantId  = $tenantId
                datos     = @{ objectId = [string]$spId }
            }
        }
    }

    $vulns = @()
    if ($Raw.PSObject.Properties['Vulnerabilidades'] -and $null -ne $Raw.Vulnerabilidades) {
        $contadorV = 0
        foreach ($v in @($Raw.Vulnerabilidades)) {
            $contadorV++
            $vulns += [pscustomobject]@{
                id        = ('vuln-{0:D4}' -f $contadorV)
                nombre    = if ($v.PSObject.Properties['nombre']) { $v.nombre } else { $null }
                tipo      = if ($v.PSObject.Properties['tipo'])   { $v.tipo }   else { 'Desconocido' }
                capacidad = 'Vulnerabilidades'
                estado    = 'aplicada'
                timestamp = $ts
                datos     = if ($v.PSObject.Properties['objetosAfectados']) { @{ objetosAfectados = $v.objetosAfectados } } else { @{} }
            }
        }
    }

    return [pscustomobject]@{
        manifestVersion  = $script:LabManifiestoVersion
        fecha            = $ts
        tenantId         = $tenantId
        tenantDomain     = if ($Raw.PSObject.Properties['TenantDomain']) { $Raw.TenantDomain } else { $null }
        nivel            = 'Free'
        escenario        = $null
        semilla          = $null
        objetos          = $objetos
        vulnerabilidades = $vulns
    }
}

# ============================================================
# GUARDADO
# ============================================================

function Save-LabManifiesto {
    <#
    .SYNOPSIS
        Guarda el manifiesto en disco.
    .PARAMETER Manifiesto
        Manifiesto v2 (PSCustomObject).
    .PARAMETER Path
        Ruta destino. Si se omite, se usa la estándar.
    .OUTPUTS
        $true si se guardó, $false si falló.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$Manifiesto,

        [string]$Path = $null
    )

    if (-not $Path) { $Path = $script:LabManifiestoPath }

    try {
        $Manifiesto | ConvertTo-Json -Depth 15 | Set-Content -Path $Path -Encoding UTF8 -Force
        return $true
    } catch {
        Write-LabWarn "No se pudo guardar el manifiesto: $($_.Exception.Message)"
        return $false
    }
}

# ============================================================
# ESTADO RESUMIDO
# ============================================================

function Get-LabManifiestoStatus {
    <#
    .SYNOPSIS
        Devuelve un resumen del manifiesto para mostrar en el menú.
    .DESCRIPTION
        'Pendientes' excluye los estados ignorados por el cleanup
        ('preexistente', 'revertido', 'no-revertido', 'omitido').
        Solo cuenta 'creado', 'reutilizado' y 'fallido'.
    .OUTPUTS
        $null          si no existe manifiesto
        'ilegible'     si existe pero no se puede leer
        PSCustomObject con Fecha, Tenant, Nivel, Escenario, Objetos,
        Pendientes, Preexistentes, Vulnerabilidades
    #>
    if (-not (Test-LabManifiestoExists)) { return $null }

    try {
        $m = Get-LabManifiesto -Path $script:LabManifiestoPath

        $pendientes = @($m.objetos | Where-Object { $_.estado -in $script:LabEstadosReversibles }).Count
        $preexistentes = @($m.objetos | Where-Object { $_.estado -eq 'preexistente' }).Count
        $vulnsPend = @($m.vulnerabilidades | Where-Object { $_.estado -eq 'aplicada' }).Count

        return [pscustomobject]@{
            Fecha            = $m.fecha
            Tenant           = $m.tenantDomain
            Nivel            = $m.nivel
            Escenario        = $m.escenario
            Objetos          = $m.objetos.Count
            Pendientes       = $pendientes
            Preexistentes    = $preexistentes
            Vulnerabilidades = $vulnsPend
        }
    } catch {
        return 'ilegible'
    }
}

# ============================================================
# RENOMBRADO
# ============================================================

function Rename-LabManifiestoProcesado {
    <#
    .SYNOPSIS
        Renombra el manifiesto actual con sufijo _procesado_<timestamp>.
    .OUTPUTS
        Ruta del nuevo fichero, o $null si no había manifiesto o falló.
    #>
    if (-not (Test-LabManifiestoExists)) { return $null }

    try {
        $nuevoPath = $script:LabManifiestoPath -replace '\.json$', "_procesado_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
        $null = Move-Item -Path $script:LabManifiestoPath -Destination $nuevoPath -Force -ErrorAction Stop
        return $nuevoPath
    } catch {
        Write-LabWarn "No se pudo renombrar el manifiesto: $($_.Exception.Message)"
        return $null
    }
}

# ============================================================
# UTILIDADES
# ============================================================

function Get-LabManifiestoPendientes {
    <#
    .SYNOPSIS
        Devuelve solo los objetos y vulnerabilidades pendientes de revertir.
    .DESCRIPTION
        Excluye los estados ignorados por el cleanup:
        'preexistente', 'revertido', 'no-revertido', 'omitido'.
    .PARAMETER Manifiesto
        Manifiesto v2.
    .OUTPUTS
        Hashtable con 'objetos' y 'vulnerabilidades' pendientes.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$Manifiesto
    )

    return @{
        objetos          = @($Manifiesto.objetos | Where-Object { $_.estado -in $script:LabEstadosReversibles })
        vulnerabilidades = @($Manifiesto.vulnerabilidades | Where-Object { $_.estado -eq 'aplicada' })
    }
}

function Add-LabManifiestoVulnerabilidad {
    <#
    .SYNOPSIS
        Añade una vulnerabilidad aplicada al manifiesto.
    .PARAMETER Manifiesto
        Manifiesto v2 (se muta).
    .PARAMETER Nombre
        Nombre de la vulnerabilidad.
    .PARAMETER Tipo
        Tipo de vulnerabilidad.
    .PARAMETER Datos
        Datos específicos para revertir.
    .OUTPUTS
        El objeto añadido.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$Manifiesto,

        [Parameter(Mandatory = $true)]
        [string]$Nombre,

        [Parameter(Mandatory = $true)]
        [string]$Tipo,

        [Parameter(Mandatory = $false)]
        [hashtable]$Datos = @{}
    )

    $id = 'vuln-{0:D4}' -f ($Manifiesto.vulnerabilidades.Count + 1)
    $v = [pscustomobject]@{
        id        = $id
        nombre    = $Nombre
        tipo      = $Tipo
        capacidad = 'Vulnerabilidades'
        estado    = 'aplicada'
        timestamp = (Get-Date).ToString('o')
        datos     = $Datos
    }
    $Manifiesto.vulnerabilidades += $v
    return $v
}