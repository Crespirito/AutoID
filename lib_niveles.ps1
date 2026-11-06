<#
.SYNOPSIS
    Librería de gestión de niveles de licencia (Free / P1 / P2).
.DESCRIPTION
    Proporciona:
      - Definición de niveles disponibles y su orden.
      - Mapeo nivel -> carpeta de capacidades.
      - Nivel actual (persistido en menu_config.json).
      - Listado de niveles disponibles según las carpetas activas.
      - Filtro de capacidades por nivel.

    El nivel determina qué carpetas de lib_caps/ se cargan:
      free/  -> capacidades disponibles en Entra ID Free
      p1/    -> capacidades que requieren P1
      p2/    -> capacidades que requieren P2

    Renombrar una carpeta a *.disabled (por ejemplo p2/ -> p2.disabled/)
    desactiva ese nivel sin tocar código. Si el nivel actual deja de estar
    disponible, Get-LabNivelActual cae al nivel por defecto ('Free') y avisa.

    Un nivel está disponible si su carpeta existe Y contiene al menos un
    cap_*.ps1. Una carpeta vacía no cuenta como nivel disponible.
.NOTES
    Depende de lib_ui.ps1 (Write-Lab*).
    Se carga por dot-sourcing desde menu.ps1.
#>

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
# FUNCIONES PÚBLICAS: DEFINICIÓN
# ============================================================

function Get-LabNivelesDefinidos {
    <#
    .SYNOPSIS
        Devuelve la tabla completa de niveles definidos.
    #>
    return $script:LabNiveles
}

function Get-LabNivelOrden {
    <#
    .SYNOPSIS
        Devuelve el orden numérico de un nivel (0=Free, 1=P1, 2=P2).
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Nivel
    )
    if (-not $script:LabNiveles.ContainsKey($Nivel)) {
        throw "Nivel desconocido: '$Nivel'. Válidos: $($script:LabNiveles.Keys -join ', ')."
    }
    return $script:LabNiveles[$Nivel].Orden
}

function Get-LabNivelCarpeta {
    <#
    .SYNOPSIS
        Devuelve el nombre de la carpeta asociada a un nivel.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Nivel
    )
    if (-not $script:LabNiveles.ContainsKey($Nivel)) {
        throw "Nivel desconocido: '$Nivel'."
    }
    return $script:LabNiveles[$Nivel].Carpeta
}

function Get-LabNivelDescripcion {
    <#
    .SYNOPSIS
        Devuelve la descripción legible de un nivel.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Nivel
    )
    if (-not $script:LabNiveles.ContainsKey($Nivel)) {
        return $Nivel
    }
    return $script:LabNiveles[$Nivel].Descripcion
}

# ============================================================
# FUNCIONES PÚBLICAS: DISPONIBILIDAD
# ============================================================

function Test-LabNivelTieneCapacidades {
    <#
    .SYNOPSIS
        Devuelve $true si la carpeta de un nivel existe y tiene al menos un cap_*.ps1.
    .PARAMETER Nivel
        Nombre del nivel.
    .PARAMETER RootCaps
        Ruta raíz de capacidades.
    .OUTPUTS
        $true si el nivel es cargable, $false si no.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Nivel,

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
    <#
    .SYNOPSIS
        Devuelve los niveles cuyas carpetas existen y tienen capacidades.
    .DESCRIPTION
        Un nivel está disponible si su carpeta (free/, p1/, p2/) existe
        en lib_caps/ y contiene al menos un cap_*.ps1. Una carpeta vacía
        no cuenta como nivel disponible.
    .PARAMETER RootCaps
        Ruta raíz de las capacidades.
    .OUTPUTS
        Array de nombres de nivel ordenado de menor a mayor.
    #>
    param(
        [string]$RootCaps = $null
    )

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
# FUNCIONES PÚBLICAS: NIVEL ACTUAL
# ============================================================

function Get-LabNivelActual {
    <#
    .SYNOPSIS
        Devuelve el nivel actualmente configurado.
    .DESCRIPTION
        Lee el nivel de la configuración. Si no existe, no es válido, o
        ya no está disponible (carpeta renombrada), cae al nivel por
        defecto ('Free') y avisa.
    .PARAMETER Config
        Hashtable de configuración (resultado de Get-LabConfig).
    .PARAMETER RootCaps
        Ruta raíz de capacidades. Útil para tests.
    .OUTPUTS
        String con el nombre del nivel.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,

        [string]$RootCaps = $null
    )

    if (-not $Config.ContainsKey('NivelLicencia') -or
        [string]::IsNullOrWhiteSpace($Config.NivelLicencia) -or
        -not $script:LabNiveles.ContainsKey($Config.NivelLicencia)) {
        return $script:LabNivelPorDefecto
    }

    $nivelGuardado = $Config.NivelLicencia
    if (-not (Test-LabNivelTieneCapacidades -Nivel $nivelGuardado -RootCaps $RootCaps)) {
        Write-LabWarn "El nivel '$nivelGuardado' ya no está disponible (carpeta desactivada). Usando '$($script:LabNivelPorDefecto)'."
        return $script:LabNivelPorDefecto
    }

    return $nivelGuardado
}

function Test-LabNivelPermitido {
    <#
    .SYNOPSIS
        Comprueba si una capacidad de nivel N está permitida con nivel M.
    .DESCRIPTION
        Una capacidad está permitida si su nivel es menor o igual al
        nivel configurado.
    .PARAMETER NivelCapacidad
        Nivel de la capacidad.
    .PARAMETER NivelConfigurado
        Nivel actual del operador.
    .OUTPUTS
        $true si está permitida, $false si no.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$NivelCapacidad,

        [Parameter(Mandatory = $true)]
        [string]$NivelConfigurado
    )

    if (-not $script:LabNiveles.ContainsKey($NivelCapacidad)) { return $false }
    if (-not $script:LabNiveles.ContainsKey($NivelConfigurado)) { return $false }

    return ($script:LabNiveles[$NivelCapacidad].Orden -le $script:LabNiveles[$NivelConfigurado].Orden)
}

function Set-LabNivel {
    <#
    .SYNOPSIS
        Cambia el nivel configurado y lo persiste.
    .DESCRIPTION
        Valida que el nivel esté disponible (carpeta con capacidades)
        antes de guardarlo.
    .PARAMETER Nivel
        Nuevo nivel ('Free', 'P1', 'P2').
    .PARAMETER Config
        Configuración actual (hashtable).
    .PARAMETER RootCaps
        Ruta raíz de capacidades. Útil para tests.
    .OUTPUTS
        Hashtable con la configuración actualizada.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Nivel,

        [Parameter(Mandatory = $true)]
        [hashtable]$Config,

        [string]$RootCaps = $null
    )

    if (-not $script:LabNiveles.ContainsKey($Nivel)) {
        throw "Nivel desconocido: '$Nivel'."
    }
    if (-not (Test-LabNivelTieneCapacidades -Nivel $Nivel -RootCaps $RootCaps)) {
        throw "El nivel '$Nivel' no está disponible (carpeta sin capacidades)."
    }

    $Config['NivelLicencia'] = $Nivel
    $null = Save-LabConfig -Config $Config
    return $Config
}