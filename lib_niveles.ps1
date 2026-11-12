<#
.SYNOPSIS
    Librería de gestión de niveles de licencia (Free / P1 / P2).
.DESCRIPTION
    Proporciona:
      - Definición de niveles disponibles y su orden.
      - Nivel actual (persistido en menu_config.json).
      - Nivel real del tenant (delega en lib_graph y usa su caché de SKUs).
      - Nivel efectivo (min configurado, real del tenant).
      - Nivel efectivo detallado.
      - Filtro de capacidades por nivel.
.NOTES
    Depende de lib_ui.ps1 y lib_graph.ps1.
    Requiere PowerShell 7.
#>
#Requires -Version 7.0

# Set-StrictMode -Version Latest

# ============================================================
# DEFINICIÓN DE NIVELES
# ============================================================
$script:LabNiveles = @{
    'Free' = @{
        Orden       = 0
        Carpeta     = 'free'
        Nombre      = 'Free'
        Descripcion = 'Entra ID Free (sin licencias de pago)'
    }
    'P1'   = @{
        Orden       = 1
        Carpeta     = 'p1'
        Nombre      = 'P1'
        Descripcion = 'Entra ID P1 (AAD_PREMIUM)'
    }
    'P2'   = @{
        Orden       = 2
        Carpeta     = 'p2'
        Nombre      = 'P2'
        Descripcion = 'Entra ID P2 (AAD_PREMIUM_P2)'
    }
}

$script:LabNivelPorDefecto = 'Free'

# ============================================================
# DEFINICIÓN
# ============================================================

function Get-LabNivelesDefinidos {
    return $script:LabNiveles
}

function Get-LabNivelOrden {
    param([Parameter(Mandatory = $true)][string]$Nivel)

    if (-not $script:LabNiveles.ContainsKey($Nivel)) {
        throw "Nivel desconocido: '$Nivel'. Válidos: $($script:LabNiveles.Keys -join ', ')."
    }
    return $script:LabNiveles[$Nivel].Orden
}

function Get-LabNivelDescripcion {
    param([Parameter(Mandatory = $true)][string]$Nivel)

    if (-not $script:LabNiveles.ContainsKey($Nivel)) { return $Nivel }
    return $script:LabNiveles[$Nivel].Descripcion
}

# ============================================================
# DISPONIBILIDAD
# ============================================================

function Test-LabNivelTieneCapacidades {
    param(
        [Parameter(Mandatory = $true)][string]$Nivel,
        [string]$RootCaps = $null
    )

    if (-not $RootCaps) { $RootCaps = Join-Path $PSScriptRoot 'lib_caps' }
    if (-not $script:LabNiveles.ContainsKey($Nivel)) { return $false }

    $carpeta = $script:LabNiveles[$Nivel].Carpeta
    $ruta = Join-Path $RootCaps $carpeta
    if (-not (Test-Path -Path $ruta -PathType Container)) { return $false }

    $archivos = @(Get-ChildItem -Path $ruta -Filter 'cap_*.ps1' -File -ErrorAction SilentlyContinue)
    return ($archivos.Count -gt 0)
}

function Get-LabNivelesDisponibles {
    param([string]$RootCaps = $null)

    if (-not $RootCaps) { $RootCaps = Join-Path $PSScriptRoot 'lib_caps' }

    $disponibles = @()
    foreach ($nombreNivel in $script:LabNiveles.Keys) {
        if (Test-LabNivelTieneCapacidades -Nivel $nombreNivel -RootCaps $RootCaps) {
            $disponibles += $nombreNivel
        }
    }
    return @($disponibles | Sort-Object { $script:LabNiveles[$_].Orden })
}

# ============================================================
# NIVEL ACTUAL (CONFIG)
# ============================================================

function Get-LabNivelActual {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [string]$RootCaps = $null
    )

    if (-not $Config.ContainsKey('NivelLicencia') -or
        [string]::IsNullOrWhiteSpace($Config.NivelLicencia) -or
        -not $script:LabNiveles.ContainsKey($Config.NivelLicencia)) {
        return $script:LabNivelPorDefecto
    }

    $nivelGuardado = $Config.NivelLicencia
    if (-not (Test-LabNivelTieneCapacidades -Nivel $nivelGuardado -RootCaps $RootCaps)) {
        Write-LabWarn "El nivel '$nivelGuardado' ya no está disponible. Usando '$($script:LabNivelPorDefecto)'."
        return $script:LabNivelPorDefecto
    }

    return $nivelGuardado
}

function Test-LabNivelPermitido {
    param(
        [Parameter(Mandatory = $true)][string]$NivelCapacidad,
        [Parameter(Mandatory = $true)][string]$NivelConfigurado
    )

    if (-not $script:LabNiveles.ContainsKey($NivelCapacidad)) { return $false }
    if (-not $script:LabNiveles.ContainsKey($NivelConfigurado)) { return $false }

    return ($script:LabNiveles[$NivelCapacidad].Orden -le $script:LabNiveles[$NivelConfigurado].Orden)
}

# ============================================================
# NIVEL REAL DEL TENANT Y NIVEL EFECTIVO
# ============================================================

function Get-LabNivelRealDelTenantStatus {
    <#
    .SYNOPSIS
        Devuelve el nivel real del tenant con estado detallado.
    .DESCRIPTION
        Orquestador: delega en Get-LabGraphNivelRealStatus (de lib_graph).
        Este es el nombre público que usa el resto del proyecto.
    .OUTPUTS
        PSCustomObject con Estado (Ok/SinLicencia/SinPermisos/SinSesion/Error),
        Nivel y Mensaje.
    #>
    if (-not (Get-Command Get-LabGraphNivelRealStatus -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{
            Estado  = 'SinSesion'
            Nivel   = $script:LabNivelPorDefecto
            Mensaje = 'lib_graph.ps1 no está cargada o es una versión antigua.'
        }
    }
    return (Get-LabGraphNivelRealStatus)
}

function Get-LabNivelRealDelTenant {
    <#
    .SYNOPSIS
        Devuelve el nivel real del tenant como string ('Free'|'P1'|'P2').
    .DESCRIPTION
        Wrapper de compatibilidad. Si el estado no permite determinarlo
        con fiabilidad (sin sesión, sin permisos, error), emite un aviso
        y devuelve 'Free' como fallback conservador.
    .OUTPUTS
        'Free' | 'P1' | 'P2'
    #>
    $s = Get-LabNivelRealDelTenantStatus
    switch ($s.Estado) {
        'Ok'          { return $s.Nivel }
        'SinLicencia' { return 'Free' }
        default {
            if (-not [string]::IsNullOrWhiteSpace($s.Mensaje)) {
                Write-LabWarn $s.Mensaje
            }
            return 'Free'
        }
    }
}

function Get-LabNivelEfectivoDetallado {
    <#
    .SYNOPSIS
        Devuelve el nivel efectivo (min configurado, real) con estado.
    .DESCRIPTION
        Calcula el nivel efectivo combinando el nivel configurado (config)
        con el nivel real del tenant (SKUs). Devuelve estado y mensaje para
        que la UI pueda informar correctamente.
    .OUTPUTS
        PSCustomObject con Nivel, NivelConfigurado, NivelReal, Estado, Mensaje.
    #>
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [string]$RootCaps = $null
    )

    $configurado = Get-LabNivelActual -Config $Config -RootCaps $RootCaps
    $statusReal  = Get-LabNivelRealDelTenantStatus
    $real        = $statusReal.Nivel

    $ordenConfig = Get-LabNivelOrden -Nivel $configurado
    $ordenReal   = Get-LabNivelOrden -Nivel $real

    $efectivo = if ($ordenConfig -le $ordenReal) { $configurado } else { $real }

    return [pscustomobject]@{
        Nivel            = $efectivo
        NivelConfigurado = $configurado
        NivelReal        = $real
        Estado           = $statusReal.Estado
        Mensaje          = $statusReal.Mensaje
    }
}

function Get-LabNivelEfectivo {
    <#
    .SYNOPSIS
        Devuelve el nivel efectivo (el mínimo entre el configurado y el real).
    .DESCRIPTION
        Wrapper de compatibilidad sobre Get-LabNivelEfectivoDetallado.
    .OUTPUTS
        'Free' | 'P1' | 'P2'
    #>
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [string]$RootCaps = $null
    )

    $detalle = Get-LabNivelEfectivoDetallado -Config $Config -RootCaps $RootCaps
    return $detalle.Nivel
}