<#
.SYNOPSIS
    Librería de gestión del manifiesto del laboratorio (v2.1).
.DESCRIPTION
    Proporciona:
      - Ruta canónica del manifiesto (manifiesto_lab.json).
      - Estructura v2.1: metadatos + lista de objetos + lista de vulnerabilidades.
      - Normalización segura de arrays para PowerShell 7.
      - Estado resumido para el menú.
      - Guardado y renombrado como procesado (con -Path opcional).
      - Detección de manifestVersion antigua o futura.

    CONTRATO:
      - Get-LabManifiesto SIEMPRE devuelve un [pscustomobject] con
        todas las propiedades esperadas, o $null si el archivo no existe.
      - objetos y vulnerabilidades son SIEMPRE arrays (@() si vacíos).
      - Save-LabManifiesto normaliza y escribe manifestVersion explícito.
.NOTES
    Depende de lib_ui.ps1.
    Requiere PowerShell 7.
#>
#Requires -Version 7.0

# Set-StrictMode -Version Latest

# ============================================================
# RUTA CANÓNICA Y VERSIÓN SOPORTADA
# ============================================================
$script:LabManifiestoFileName = 'manifiesto_lab.json'
$script:LabManifiestoPath     = Join-Path $PSScriptRoot $script:LabManifiestoFileName
$script:LabManifiestoVersion  = '2.1'

# ============================================================
# ESTADOS
# ============================================================
# Objetos
$script:LabEstadosReversiblesObjeto = @('creado','reutilizado','fallido')
$script:LabEstadosIgnoradosObjeto   = @('preexistente','revertido','no-revertido','omitido')

# Vulnerabilidades
$script:LabEstadosReversiblesVulnerabilidad = @('aplicada','fallida')
$script:LabEstadosIgnoradosVulnerabilidad   = @('preexistente','revertida','no-revertida','omitida')

# ============================================================
# RUTAS Y EXISTENCIA
# ============================================================

function Get-LabManifiestoPath {
    return $script:LabManifiestoPath
}

function Test-LabManifiestoExists {
    return (Test-Path -Path $script:LabManifiestoPath)
}

# ============================================================
# COMPARACIÓN DE VERSIONES
# ============================================================

function Compare-LabVersion {
    <#
    .SYNOPSIS
        Compara dos strings de versión tipo 'X.Y'.
    .DESCRIPTION
        Devuelve 'mayor', 'menor' o 'igual' respecto a la versión
        soportada. Ignora sufijos no numéricos para no romper con
        versiones tipo '2.1-beta'.
    #>
    param(
        [Parameter(Mandatory = $true)] [string]$Version,
        [Parameter(Mandatory = $true)] [string]$Referencia
    )

    $limpiar = {
        param($v)
        if ([string]::IsNullOrWhiteSpace($v)) { return $null }
        $m = [regex]::Match($v, '^\s*(\d+)\.(\d+)')
        if (-not $m.Success) { return $null }
        return [version]("$($m.Groups[1].Value).$($m.Groups[2].Value)")
    }

    $v1 = & $limpiar $Version
    $v2 = & $limpiar $Referencia
    if ($null -eq $v1) { return 'desconocida' }
    if ($null -eq $v2) { return 'desconocida' }

    if ($v1 -gt $v2) { return 'mayor' }
    if ($v1 -lt $v2) { return 'menor' }
    return 'igual'
}

# ============================================================
# ESTRUCTURA BASE
# ============================================================

function New-LabManifiestoVacio {
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
        Carga y normaliza un manifiesto.
    .DESCRIPTION
        Devuelve un [pscustomobject] con las 9 propiedades esperadas.
        objetos y vulnerabilidades son arrays. Cada elemento tiene sus
        propiedades garantizadas.
    .PARAMETER Path
        Ruta del manifiesto. Si se omite, la canónica.
    .OUTPUTS
        [pscustomobject] normalizado, o $null si no existe.
    #>
    param([string]$Path = $null)

    if (-not $Path) { $Path = $script:LabManifiestoPath }
    if (-not (Test-Path -Path $Path)) { return $null }

    try {
        $raw = Get-Content -Path $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        throw "No se pudo leer el manifiesto: $($_.Exception.Message)"
    }

    # --- Versión leída del archivo ---
    $versionArchivo = $script:LabManifiestoVersion
    if ($raw.PSObject.Properties['manifestVersion'] -and -not [string]::IsNullOrWhiteSpace([string]$raw.manifestVersion)) {
        $versionArchivo = [string]$raw.manifestVersion
    }

    $comparacion = Compare-LabVersion -Version $versionArchivo -Referencia $script:LabManifiestoVersion
    switch ($comparacion) {
        'mayor' {
            Write-LabWarn "Manifiesto versión '$versionArchivo' es más nueva que la soportada ('$($script:LabManifiestoVersion)'). Se intentará cargar igualmente."
        }
        'menor' {
            Write-LabWarn "Manifiesto versión '$versionArchivo' es más antigua que la soportada ('$($script:LabManifiestoVersion)'). Algunos campos pueden faltar."
        }
        'desconocida' {
            Write-LabWarn "No se pudo interpretar manifestVersion '$versionArchivo'. Se asume '$($script:LabManifiestoVersion)'."
            $versionArchivo = $script:LabManifiestoVersion
        }
    }

    # --- Arrays normalizados ---
    $objetosRaw = if ($raw.PSObject.Properties['objetos'] -and $null -ne $raw.objetos) { @($raw.objetos) } else { @() }
    $vulnsRaw   = if ($raw.PSObject.Properties['vulnerabilidades'] -and $null -ne $raw.vulnerabilidades) { @($raw.vulnerabilidades) } else { @() }

    $objetosNorm = @()
    foreach ($o in $objetosRaw) {
        if ($null -eq $o) { continue }
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
    foreach ($v in $vulnsRaw) {
        if ($null -eq $v) { continue }
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
        manifestVersion  = $versionArchivo
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
# GUARDADO
# ============================================================

function Save-LabManifiesto {
    <#
    .SYNOPSIS
        Guarda el manifiesto normalizado en disco.
    .DESCRIPTION
        Acepta [pscustomobject] o [hashtable]. Normaliza antes de escribir
        y garantiza manifestVersion explícito en el archivo.
    .PARAMETER Manifiesto
        Manifiesto a guardar.
    .PARAMETER Path
        Ruta destino. Si se omite, la canónica.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Manifiesto,

        [string]$Path = $null
    )

    if (-not $Path) { $Path = $script:LabManifiestoPath }

    try {
        $normalizado = [pscustomobject]@{
            manifestVersion  = if ($Manifiesto.PSObject.Properties['manifestVersion'] -and -not [string]::IsNullOrWhiteSpace([string]$Manifiesto.manifestVersion)) {
                                   [string]$Manifiesto.manifestVersion
                               } else {
                                   $script:LabManifiestoVersion
                               }
            fecha            = if ($Manifiesto.PSObject.Properties['fecha'])        { $Manifiesto.fecha }        else { (Get-Date).ToString('o') }
            tenantId         = if ($Manifiesto.PSObject.Properties['tenantId'])     { $Manifiesto.tenantId }     else { $null }
            tenantDomain     = if ($Manifiesto.PSObject.Properties['tenantDomain']) { $Manifiesto.tenantDomain } else { $null }
            nivel            = if ($Manifiesto.PSObject.Properties['nivel'])        { $Manifiesto.nivel }        else { 'Free' }
            escenario        = if ($Manifiesto.PSObject.Properties['escenario'])    { $Manifiesto.escenario }    else { $null }
            semilla          = if ($Manifiesto.PSObject.Properties['semilla'])      { $Manifiesto.semilla }      else { $null }
            objetos          = @($Manifiesto.objetos)
            vulnerabilidades = @($Manifiesto.vulnerabilidades)
        }

        $normalizado | ConvertTo-Json -Depth 15 | Set-Content -Path $Path -Encoding UTF8 -Force
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
        Devuelve un resumen del manifiesto canónico para el menú.
    .OUTPUTS
        PSCustomObject con Fecha, Tenant, Nivel, Escenario, Objetos,
        Pendientes, Preexistentes, Vulnerabilidades, ManifestVersion y
        Soporte ('ok'|'antigua'|'futura'|'desconocida'|'ilegible').
    #>
    if (-not (Test-LabManifiestoExists)) { return $null }

    try {
        $m = Get-LabManifiesto -Path $script:LabManifiestoPath
        if ($null -eq $m) { return 'ilegible' }

        $pendientes = Get-LabManifiestoPendientes -Manifiesto $m
        $preexistentes = @($m.objetos | Where-Object { $_.estado -eq 'preexistente' }).Count

        $soporte = 'ok'
        switch (Compare-LabVersion -Version $m.manifestVersion -Referencia $script:LabManifiestoVersion) {
            'mayor'        { $soporte = 'futura' }
            'menor'        { $soporte = 'antigua' }
            'desconocida'  { $soporte = 'desconocida' }
        }

        return [pscustomobject]@{
            Fecha            = $m.fecha
            Tenant           = $m.tenantDomain
            Nivel            = $m.nivel
            Escenario        = $m.escenario
            Objetos          = @($m.objetos).Count
            Pendientes       = @($pendientes.objetos).Count
            Preexistentes    = $preexistentes
            Vulnerabilidades = @($pendientes.vulnerabilidades).Count
            ManifestVersion  = $m.manifestVersion
            Soporte          = $soporte
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
        Renombra el manifiesto como procesado.
    .DESCRIPTION
        Con -Path, renombra el archivo indicado (para clean.ps1 u otros
        flujos que trabajen con un manifiesto específico). Sin -Path,
        usa el manifiesto canónico.
    .PARAMETER Path
        Ruta del manifiesto a renombrar.
    .OUTPUTS
        Ruta nueva del archivo, o $null si no se pudo renombrar.
    #>
    param([string]$Path = $null)

    if (-not $Path) { $Path = $script:LabManifiestoPath }
    if (-not (Test-Path -Path $Path)) { return $null }

    try {
        $nuevoPath = $Path -replace '\.json$', "_procesado_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
        Move-Item -Path $Path -Destination $nuevoPath -Force -ErrorAction Stop
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
        Devuelve los objetos y vulnerabilidades en estado reversible.
    .OUTPUTS
        Hashtable con 'objetos' y 'vulnerabilidades' (arrays).
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
        Añade una vulnerabilidad al manifiesto.
    .PARAMETER Capacidad
        Nombre de la capacidad que aplicó la vulnerabilidad. Debe ser
        un string no vacío.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$Manifiesto,

        [Parameter(Mandatory = $true)]
        [string]$Nombre,

        [Parameter(Mandatory = $true)]
        [string]$Tipo,

        [Parameter(Mandatory = $true)]
        $Capacidad,

        [Parameter(Mandatory = $false)]
        [hashtable]$Datos = @{},

        [Parameter(Mandatory = $false)]
        [string]$Estado = 'aplicada'
    )

    if ($Capacidad -isnot [string] -or [string]::IsNullOrWhiteSpace($Capacidad)) {
        Write-LabWarn 'Add-LabManifiestoVulnerabilidad: -Capacidad debe ser un string no vacío. Se ignora la operación.'
        return $null
    }

    $id = 'vuln-{0:D4}' -f (@($Manifiesto.vulnerabilidades).Count + 1)

    $v = [pscustomobject]@{
        id        = $id
        nombre    = $Nombre
        tipo      = $Tipo
        capacidad = $Capacidad.Trim()
        estado    = $Estado
        timestamp = (Get-Date).ToString('o')
        datos     = $Datos
    }

    $Manifiesto.vulnerabilidades += $v
    return $v
}