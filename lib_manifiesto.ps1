<#
.SYNOPSIS
    Librería de gestión del manifiesto del laboratorio (v2.1).
.DESCRIPTION
    Proporciona:
      - Ruta canónica del manifiesto (manifiesto_lab.json).
      - Estructura v2.1: metadatos + lista plana de objetos + lista de
        vulnerabilidades.
      - Migración automática desde v1 (listas por tipo) y v2 (vulnerabilidades
        dentro de objetos) al cargar.
      - Normalización de campos (objetos y vulnerabilidades siempre arrays).
      - Estado resumido para el menú.
      - Guardado y renombrado como procesado.

    Estructura v2.1:
      {
        "manifestVersion": "2.1",
        "fecha": "...",
        "tenantId": "...",
        "tenantDomain": "...",
        "nivel": "P1",
        "escenario": "...",
        "semilla": "...",
        "objetos": [ { id, tipo, capacidad, estado, timestamp, tenantId, datos }, ... ],
        "vulnerabilidades": [ { id, nombre, tipo, capacidad, estado, timestamp, datos }, ... ]
      }

    DIFERENCIAS CON v2:
      - Las vulnerabilidades viven SIEMPRE en 'vulnerabilidades', nunca en
        'objetos'. La migración v2 -> v2.1 mueve los objetos con
        capacidad = 'Vulnerabilidades' al array correcto.
      - 'capacidad' de una vulnerabilidad es la capacidad que la aplicó
        ('Vulnerabilidades' o 'Pim'). Ya no se hardcodea.
      - Estados unificados en listas separadas para objetos y vulnerabilidades.

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

    ESTADOS DE VULNERABILIDADES:
      'aplicada'      - aplicada y pendiente de revertir
      'preexistente'  - no se aplicó porque el objeto objetivo era preexistente
      'fallida'       - intento de aplicación fallido; se puede reintentar la reversión
      'revertida'     - ya revertida
      'no-revertida'  - no se pudo revertir
      'omitida'       - omitida por configuración (exclusión)

    SEGURIDAD:
    El manifiesto NO contiene contraseñas. Solo guarda identificadores y
    datos necesarios para revertir. Las contraseñas se derivan de la
    semilla local del escenario y nunca se persisten aquí.
    Los client secrets y los códigos TAP TAMPOCO se guardan: solo su keyId
    o methodId, para poder revocarlos.

    Los objetos con estado 'preexistente' son ignorados por el cleanup.
.NOTES
    Depende de lib_ui.ps1.
    Se carga por dot-sourcing desde menu.ps1.
#>

# ============================================================
# RUTA CANÓNICA
# ============================================================
$script:LabManifiestoFileName = 'manifiesto_lab.json'
$script:LabManifiestoPath     = Join-Path $PSScriptRoot $script:LabManifiestoFileName
$script:LabManifiestoVersion  = '2.1'

# ============================================================
# ESTADOS (LISTAS UNIFICADAS)
# ============================================================

# Objetos: estados que el cleanup puede intentar revertir
$script:LabEstadosReversiblesObjeto = @('creado','reutilizado','fallido')

# Objetos: estados que el cleanup debe ignorar
$script:LabEstadosIgnoradosObjeto = @('preexistente','revertido','no-revertido','omitido')

# Vulnerabilidades: estados que el cleanup puede intentar revertir
$script:LabEstadosReversiblesVulnerabilidad = @('aplicada','fallida')

# Vulnerabilidades: estados que el cleanup debe ignorar
$script:LabEstadosIgnoradosVulnerabilidad = @('preexistente','revertida','no-revertida','omitida')

# Alias de compatibilidad (código antiguo que consulte las listas globales)
$script:LabEstadosReversibles = $script:LabEstadosReversiblesObjeto
$script:LabEstadosIgnorados   = $script:LabEstadosIgnoradosObjeto

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
        Devuelve un manifiesto v2.1 vacío, listo para rellenar.
    .PARAMETER Escenario
        Nombre del escenario o de la sesión manual.
    .PARAMETER Nivel
        Nivel de licencia elegido ('Free', 'P1', 'P2').
    .PARAMETER Semilla
        Nombre de la semilla usada (no la semilla en sí).
    .OUTPUTS
        PSCustomObject con la estructura v2.1 vacía.
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
          lo migra a v2 y luego a v2.1.
        - Si el manifiesto es v2 (vulnerabilidades en objetos), lo migra a v2.1.
        - Garantiza que 'objetos' y 'vulnerabilidades' son arrays.
        - Garantiza que cada objeto tiene los campos comunes.
    .PARAMETER Path
        Ruta alternativa del manifiesto. Si se omite, se usa la estándar.
    .OUTPUTS
        PSCustomObject v2.1 normalizado, o $null si no existe.
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

    # v1 -> v2
    if (-not $version -or $version -notmatch '^2\.') {
        $raw = ConvertTo-LabManifiestoV2 -Raw $raw
        $version = '2.0'
    }

    # v2 -> v2.1 (mover vulnerabilidades de objetos a su array)
    if ($version -eq '2.0') {
        $raw = ConvertTo-LabManifiestoV21 -Raw $raw
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

        Las vulnerabilidades v1 se migran con capacidad = 'Vulnerabilidades'
        como fallback, porque v1 no guardaba la capacidad aplicadora.
        Es una deuda histórica: si la carpeta cambia de nombre, el cleanup
        no podrá revertirlas. El operador debe revisarlas antes de limpiar.
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
        manifestVersion  = '2.0'
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
# MIGRACIÓN v2 -> v2.1
# ============================================================

function ConvertTo-LabManifiestoV21 {
    <#
    .SYNOPSIS
        Convierte un manifiesto v2 (vulnerabilidades en objetos) a v2.1.
    .DESCRIPTION
        En v2, cap_vulnerabilidades.Crear devolvía objetos con
        tipo = 'VulnerabilidadAplicada' y capacidad = 'Vulnerabilidades',
        y Add-LabObjetoAlManifiesto los metía en 'objetos'. En v2.1 viven
        en 'vulnerabilidades'.

        Esta migración:
          1. Separa los objetos con capacidad = 'Vulnerabilidades' (o
             tipo que empiece por 'Vulnerabilidad').
          2. Los convierte a la forma de vulnerabilidad (id, nombre, tipo,
             capacidad, estado, timestamp, datos).
          3. Mapea el estado:
               'creado'        -> 'aplicada'
               'preexistente'  -> 'preexistente'
               'fallido'       -> 'fallida'
               'revertido'     -> 'revertida'
               'no-revertido'  -> 'no-revertida'
               'omitido'       -> 'omitida'
          4. Deja el resto de objetos intactos.
          5. Marca manifestVersion = '2.1'.
    .PARAMETER Raw
        Manifiesto v2 cargado desde disco.
    .OUTPUTS
        PSCustomObject v2.1.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$Raw
    )

    $objetosOriginales = @()
    if ($Raw.PSObject.Properties['objetos'] -and $null -ne $Raw.objetos) {
        $objetosOriginales = @($Raw.objetos)
    }

    $vulnsOriginales = @()
    if ($Raw.PSObject.Properties['vulnerabilidades'] -and $null -ne $Raw.vulnerabilidades) {
        $vulnsOriginales = @($Raw.vulnerabilidades)
    }

    $objetos = @()
    $vulns = @()

    # Vulnerabilidades ya existentes en v2 (array propio): conservar
    foreach ($v in $vulnsOriginales) {
        $vulns += [pscustomobject]@{
            id        = if ($v.PSObject.Properties['id'])        { $v.id }        else { $null }
            nombre    = if ($v.PSObject.Properties['nombre'])    { $v.nombre }    else { $null }
            tipo      = if ($v.PSObject.Properties['tipo'])      { $v.tipo }      else { 'Desconocido' }
            capacidad = if ($v.PSObject.Properties['capacidad']) { $v.capacidad } else { 'Vulnerabilidades' }
            estado    = if ($v.PSObject.Properties['estado'])    { $v.estado }    else { 'aplicada' }
            timestamp = if ($v.PSObject.Properties['timestamp']) { $v.timestamp } else { $null }
            datos     = if ($v.PSObject.Properties['datos'])     { $v.datos }     else { @{} }
        }
    }

    # Separar objetos: vulnerabilidades mal ubicadas vs objetos reales
    foreach ($o in $objetosOriginales) {
        $tipo = if ($o.PSObject.Properties['tipo']) { [string]$o.tipo } else { '' }
        $capacidad = if ($o.PSObject.Properties['capacidad']) { [string]$o.capacidad } else { '' }

        $esVulnerabilidad = ($capacidad -eq 'Vulnerabilidades') -or
                            ($tipo -eq 'VulnerabilidadAplicada') -or
                            ($tipo -like 'Vulnerab*')

        if (-not $esVulnerabilidad) {
            $objetos += $o
            continue
        }

        # Convertir objeto-vulnerabilidad a vulnerabilidad
        $estadoV2 = if ($o.PSObject.Properties['estado']) { [string]$o.estado } else { 'creado' }
        $estadoV21 = switch ($estadoV2) {
            'creado'       { 'aplicada' }
            'preexistente' { 'preexistente' }
            'fallido'      { 'fallida' }
            'revertido'    { 'revertida' }
            'no-revertido' { 'no-revertida' }
            'omitido'      { 'omitida' }
            default        { 'aplicada' }
        }

        $datosOriginales = if ($o.PSObject.Properties['datos']) { $o.datos } else { @{} }

        # El tipo real de la vulnerabilidad estaba en datos.tipoVulnerabilidad
        $tipoVuln = if ($datosOriginales.PSObject.Properties['tipoVulnerabilidad']) {
            [string]$datosOriginales.tipoVulnerabilidad
        } else {
            $tipo
        }

        $nombreVuln = if ($datosOriginales.PSObject.Properties['nombre']) {
            [string]$datosOriginales.nombre
        } else {
            $null
        }

        $vulns += [pscustomobject]@{
            id        = if ($o.PSObject.Properties['id'])        { $o.id }        else { $null }
            nombre    = $nombreVuln
            tipo      = $tipoVuln
            capacidad = if ($capacidad) { $capacidad } else { 'Vulnerabilidades' }
            estado    = $estadoV21
            timestamp = if ($o.PSObject.Properties['timestamp']) { $o.timestamp } else { $null }
            datos     = $datosOriginales
        }
    }

    return [pscustomobject]@{
        manifestVersion  = '2.1'
        fecha            = if ($Raw.PSObject.Properties['fecha'])        { $Raw.fecha }        else { $null }
        tenantId         = if ($Raw.PSObject.Properties['tenantId'])     { $Raw.tenantId }     else { $null }
        tenantDomain     = if ($Raw.PSObject.Properties['tenantDomain']) { $Raw.tenantDomain } else { $null }
        nivel            = if ($Raw.PSObject.Properties['nivel'])        { $Raw.nivel }        else { 'Free' }
        escenario        = if ($Raw.PSObject.Properties['escenario'])    { $Raw.escenario }    else { $null }
        semilla          = if ($Raw.PSObject.Properties['semilla'])      { $Raw.semilla }      else { $null }
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
        Manifiesto v2.1 (PSCustomObject).
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
        Usa Get-LabManifiestoPendientes para que la definición de
        "pendiente" sea única (objetos y vulnerabilidades).
    .OUTPUTS
        $null          si no existe manifiesto
        'ilegible'     si existe pero no se puede leer
        PSCustomObject con Fecha, Tenant, Nivel, Escenario, Objetos,
        Pendientes, Preexistentes, Vulnerabilidades
    #>
    if (-not (Test-LabManifiestoExists)) { return $null }

    try {
        $m = Get-LabManifiesto -Path $script:LabManifiestoPath
        $pendientes = Get-LabManifiestoPendientes -Manifiesto $m

        $preexistentes = @($m.objetos | Where-Object { $_.estado -eq 'preexistente' }).Count

        return [pscustomobject]@{
            Fecha            = $m.fecha
            Tenant           = $m.tenantDomain
            Nivel            = $m.nivel
            Escenario        = $m.escenario
            Objetos          = $m.objetos.Count
            Pendientes       = $pendientes.objetos.Count
            Preexistentes    = $preexistentes
            Vulnerabilidades = $pendientes.vulnerabilidades.Count
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
        Usa las listas unificadas:
          - Objetos: $script:LabEstadosReversiblesObjeto
          - Vulnerabilidades: $script:LabEstadosReversiblesVulnerabilidad

        Es la ÚNICA fuente de verdad sobre qué es "pendiente". Ningún otro
        sitio debe duplicar esta lógica.
    .PARAMETER Manifiesto
        Manifiesto v2.1.
    .OUTPUTS
        Hashtable con 'objetos' y 'vulnerabilidades' pendientes.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$Manifiesto
    )

    return @{
        objetos          = @($Manifiesto.objetos | Where-Object { $_.estado -in $script:LabEstadosReversiblesObjeto })
        vulnerabilidades = @($Manifiesto.vulnerabilidades | Where-Object { $_.estado -in $script:LabEstadosReversiblesVulnerabilidad })
    }
}

function Add-LabManifiestoVulnerabilidad {
    <#
    .SYNOPSIS
        Añade una vulnerabilidad aplicada al manifiesto.
    .DESCRIPTION
        La capacidad aplicadora es OBLIGATORIA. Ya no se hardcodea
        'Vulnerabilidades': si una vulnerabilidad la aplica 'Pim' (por
        delegación), se registra con capacidad = 'Pim'. El cleanup usará
        esa capacidad para despachar la reversión.

        El estado por defecto es 'aplicada'. Se puede sobrescribir con
        -Estado (por ejemplo, 'preexistente' si el objeto objetivo ya
        existía antes del laboratorio y no se ha tocado).
    .PARAMETER Manifiesto
        Manifiesto v2.1 (se muta).
    .PARAMETER Nombre
        Nombre de la vulnerabilidad (el que el operador le dio).
    .PARAMETER Tipo
        Tipo de vulnerabilidad (ServicePrincipalOwner, GroupOwner,
        ApplicationSecret, PimEligibleRole...).
    .PARAMETER Capacidad
        NOMBRE de la capacidad que la aplicó. Obligatorio.
    .PARAMETER Datos
        Datos específicos para revertir. Debe incluir el objectId del
        objeto afectado si se conoce, para que el cleanup pueda verificar.
    .PARAMETER Estado
        Estado inicial. Por defecto 'aplicada'.
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

        [Parameter(Mandatory = $true)]
        [string]$Capacidad,

        [Parameter(Mandatory = $false)]
        [hashtable]$Datos = @{},

        [Parameter(Mandatory = $false)]
        [string]$Estado = 'aplicada'
    )

    if ([string]::IsNullOrWhiteSpace($Capacidad)) {
        throw 'Add-LabManifiestoVulnerabilidad: -Capacidad es obligatorio.'
    }

    $id = 'vuln-{0:D4}' -f ($Manifiesto.vulnerabil
    $v = [pscustomobject]@{
        id        = $id
        nombre    = $Nombre
        tipo      = $Tipo
        capacidad = $Capacidad
        estado    = $Estado
        timestamp = (Get-Date).ToString('o')
        datos     = $Datos
    }
    $Manifiesto.vulnerabilidades += $v
    return $v
}