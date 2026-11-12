<#
.SYNOPSIS
    Librería de carga y registro de capacidades para PowerShell 7.
.DESCRIPTION
    Proporciona el registro en memoria y el loader de lib_caps/.
    BLINDADO: rechaza cualquier objeto que no sea un Hashtable.
.NOTES
    Depende de lib_ui.ps1.
    Requiere PowerShell 7.
#>
#Requires -Version 7.0

# Set-StrictMode -Version Latest

# ============================================================
# REGISTRO EN MEMORIA
# ============================================================
if (-not (Get-Variable -Name 'LabCapacidades' -Scope Script -ErrorAction SilentlyContinue)) {
    $script:LabCapacidades = @{}
}

# ============================================================
# FUNCIONES PÚBLICAS: REGISTRO Y CONSULTA
# ============================================================

function Clear-LabCapacidades {
    $script:LabCapacidades = @{}
}

function Register-LabCapacidad {
    param(
        [Parameter(Mandatory = $true)]
        $Capacidad,

        [string]$NivelCarpeta = 'Free'
    )

    # BLINDAJE 1: Debe ser un Hashtable
    if ($Capacidad -isnot [hashtable]) {
        Write-LabWarn "Capacidad rechazada: el objeto no es un Hashtable. Tipo recibido: $(if ($null -eq $Capacidad) { 'null' } else { $Capacidad.GetType().Name })"
        return $false
    }

    if (-not $Capacidad.ContainsKey('Nombre') -or [string]::IsNullOrWhiteSpace($Capacidad.Nombre)) {
        Write-LabWarn "Capacidad rechazada: falta el campo obligatorio 'Nombre'."
        return $false
    }

    if (-not $Capacidad.ContainsKey('Descripcion') -or [string]::IsNullOrWhiteSpace($Capacidad.Descripcion)) {
        Write-LabWarn "Capacidad '$($Capacidad.Nombre)' rechazada: falta el campo obligatorio 'Descripcion'."
        return $false
    }

    $nombre = $Capacidad.Nombre

    if ($script:LabCapacidades.ContainsKey($nombre)) {
        Write-LabWarn "Capacidad '$nombre' rechazada: ya existe una capacidad con ese nombre."
        return $false
    }

    if (-not $Capacidad.ContainsKey('Nivel') -or [string]::IsNullOrWhiteSpace($Capacidad.Nivel)) {
        $Capacidad['Nivel'] = $NivelCarpeta
    }

    $script:LabCapacidades[$nombre] = $Capacidad
    return $true
}

function Get-LabCapacidades {
    param(
        [string]$Nivel = $null,
        [switch]$SoloDisponibles,
        [hashtable]$Contexto = @{}
    )

    # BLINDAJE 2: Solo devolver Hashtables válidos
    $resultado = @($script:LabCapacidades.Values | Where-Object { $_ -is [hashtable] -and $_.ContainsKey('Nombre') })

    if ($Nivel) {
        if (-not (Test-Path variable:script:LabNiveles)) {
            Write-LabWarn "Get-LabCapacidades -Nivel: lib_niveles.ps1 no está cargada. Devuelvo @()."
            return @()
        }
        $resultado = @($resultado | Where-Object {
            Test-LabNivelPermitido -NivelCapacidad $_.Nivel -NivelConfigurado $Nivel
        })
    }

    if ($SoloDisponibles) {
        $filtradas = @()
        foreach ($cap in $resultado) {
            try {
                if ($cap.ContainsKey('TestDisponible') -and $cap.TestDisponible -is [scriptblock]) {
                    $t = & $cap.TestDisponible $Contexto
                    if ($t -and $t.PSObject.Properties['Disponible'] -and $t.Disponible) {
                        $filtradas += $cap
                    }
                } else {
                    $filtradas += $cap
                }
            } catch {
                Write-LabWarn "TestDisponible de '$($cap.Nombre)' falló: $($_.Exception.Message). Se descarta."
            }
        }
        $resultado = $filtradas
    }

    return @($resultado | Sort-Object { $_.Nombre })
}

function Get-LabCapacidadPorSeccion {
    <#
    .SYNOPSIS
        Devuelve la capacidad registrada para una clave de sección del JSON.
    .DESCRIPTION
        Acepta indistintamente:
          - el nombre interno de la capacidad ('Usuarios')
          - la clave del JSON (SeccionJson: 'usuarios')
          - cualquier alias declarado en la capacidad ('apps', 'guests'...)
        La comparación no distingue mayúsculas/minúsculas.
        Devuelve $null si ninguna capacidad coincide.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$NombreSeccion
    )

    if ([string]::IsNullOrWhiteSpace($NombreSeccion)) { return $null }
    if ($null -eq $script:LabCapacidades) { return $null }

    foreach ($cap in @($script:LabCapacidades.Values)) {
        if ($cap -isnot [hashtable] -or -not $cap.ContainsKey('Nombre')) { continue }

        if ([string]::Equals([string]$cap.Nombre, $NombreSeccion, [StringComparison]::OrdinalIgnoreCase)) {
            return $cap
        }

        if ($cap.ContainsKey('SeccionJson') -and
            -not [string]::IsNullOrWhiteSpace([string]$cap.SeccionJson) -and
            [string]::Equals([string]$cap.SeccionJson, $NombreSeccion, [StringComparison]::OrdinalIgnoreCase)) {
            return $cap
        }

        if ($cap.ContainsKey('Alias') -and $null -ne $cap.Alias) {
            foreach ($a in @($cap.Alias)) {
                if ([string]::IsNullOrWhiteSpace([string]$a)) { continue }
                if ([string]::Equals([string]$a, $NombreSeccion, [StringComparison]::OrdinalIgnoreCase)) {
                    return $cap
                }
            }
        }
    }

    return $null
}

function Get-LabCapacidad {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Nombre
    )
    if ($script:LabCapacidades.ContainsKey($Nombre)) {
        $cap = $script:LabCapacidades[$Nombre]
        if ($cap -is [hashtable]) { return $cap }
    }
    return $null
}

function Test-LabCapacidadRegistrada {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Nombre
    )
    if (-not $script:LabCapacidades.ContainsKey($Nombre)) { return $false }
    return ($script:LabCapacidades[$Nombre] -is [hashtable])
}

function Get-LabCapacidadClaves {
    param(
        [Parameter(Mandatory = $true)]
        $Capacidad,

        [Parameter(Mandatory = $true)]
        [object]$Definicion
    )

    if ($Capacidad -isnot [hashtable] -or -not $Capacidad.ContainsKey('ObtenerClaves')) {
        return @()
    }

    try {
        $claves = & $Capacidad.ObtenerClaves $Definicion
        return @($claves | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    } catch {
        Write-LabWarn "ObtenerClaves de '$($Capacidad.Nombre)' falló: $($_.Exception.Message)"
        return @()
    }
}

# ============================================================
# LOADER
# ============================================================

function Initialize-LabCapacidades {
    param(
        [string]$Root = $null,
        [switch]$Forzar
    )

    if (-not $Root) {
        $Root = Join-Path $PSScriptRoot 'lib_caps'
    }

    if (-not $Forzar -and $script:LabCapacidades.Count -gt 0) {
        return [int]$script:LabCapacidades.Count
    }

    Clear-LabCapacidades

    if (-not (Test-Path -Path $Root -PathType Container)) {
        Write-LabWarn "No existe la carpeta de capacidades: $Root"
        return 0
    }

    $archivos = @(Get-ChildItem -Path $Root -Filter 'cap_*.ps1' -File -Recurse -ErrorAction SilentlyContinue)

    # Se acumula en $script: porque 'return' dentro de un foreach solo sale del
    # bucle, y porque las variables locales de la función no sobreviven al
    # cuerpo del foreach cuando este contiene un '& { }'.
    $script:LabTotalCargadas = 0

    foreach ($archivo in $archivos) {
        $nivelCarpeta = if ($archivo.Directory.Name -match '^(free|p1|p2)$') { $archivo.Directory.Name } else { 'Free' }

        # Cada capacidad se evalúa en un scope de script hijo propio: $Capacidad
        # queda privada de ese bloque y el Hashtable no se cuela en la salida
        # de esta función (si se colara, falsearía el valor devuelto).
        $cargada = & {
            $Capacidad = $null
            $null = . $archivo.FullName
            if ($Capacidad -is [hashtable]) { return $Capacidad }
            return $null
        }

        if ($null -eq $cargada) {
            Write-LabWarn "El archivo $($archivo.Name) no definió un Hashtable válido en `$Capacidad."
            continue
        }

        # Cada cap_*.ps1 ya se registra a sí misma al final del archivo, así que
        # aquí solo se comprueba que quedó registrada (no se vuelve a registrar).
        if (-not $script:LabCapacidades.ContainsKey([string]$cargada.Nombre)) {
            $null = Register-LabCapacidad -Capacidad $cargada -NivelCarpeta $nivelCarpeta
        }

        if ($script:LabCapacidades.ContainsKey([string]$cargada.Nombre)) {
            $script:LabTotalCargadas = $script:LabTotalCargadas + 1
        }
    }

    return [int]$script:LabTotalCargadas
}