<#
.SYNOPSIS
    Librería de carga, registro y validación de capacidades.
.DESCRIPTION
    Proporciona:
      - El registro en memoria de capacidades.
      - El loader que recorre lib_caps/free|p1|p2/ y registra cada cap_*.ps1.
      - La validación del contrato de capacidad al registrar.
      - Utilidades para consultar capacidades por nombre, nivel o sección.

    CONTRATO DE CAPACIDAD (campos obligatorios):
      Nombre, SeccionJson, DependeDe, PermisosApp,
      TestDisponible, ValidarDef, Describir, Crear, Revertir, PreguntarUI

    CAMPOS OPCIONALES:
      Nivel         - si no se declara, se hereda de la carpeta
      Descripcion   - texto para el menú manual
      Alias         - nombres alternativos de SeccionJson
      ObtenerClaves - scriptblock que recibe $Def y devuelve los
                      identificadores que la capacidad va a tocar
                      (UPN, displayName, etc.). Se usa para construir
                      el snapshot pre-lab y proteger objetos preexistentes.
      PostCrear     - acción tras crear
      PreRevertir   - acción antes de revertir

    SEGURIDAD DE PREEXISTENTES:
    Si una capacidad implementa ObtenerClaves, lib_creadores.ps1 puede
    construir un snapshot pre-lab específico para esa capacidad. Si no
    lo implementa, el orquestador no puede protegerla contra objetos
    preexistentes; la capacidad debe hacerlo por su cuenta consultando
    $Contexto.SnapshotPreLab.

    Carpetas por nivel:
      lib_caps/free/  -> capacidades Free
      lib_caps/p1/    -> capacidades P1
      lib_caps/p2/    -> capacidades P2
    Renombrar una carpeta a *.disabled desactiva ese nivel.
.NOTES
    Depende de lib_ui.ps1 y lib_niveles.ps1.
    Se carga por dot-sourcing desde menu.ps1.
#>

# ============================================================
# REGISTRO EN MEMORIA
# ============================================================
if (-not (Get-Variable -Name 'LabCapacidades' -Scope Script -ErrorAction SilentlyContinue)) {
    $script:LabCapacidades = @{}
}

# Campos obligatorios del contrato de capacidad
$script:LabCapacidadCamposObligatorios = @(
    'Nombre',
    'SeccionJson',
    'DependeDe',
    'PermisosApp',
    'TestDisponible',
    'ValidarDef',
    'Describir',
    'Crear',
    'Revertir',
    'PreguntarUI'
)

# Campos opcionales que, si existen, deben ser scriptblock
$script:LabCapacidadCamposOpcionalesScriptblock = @(
    'ObtenerClaves',
    'PostCrear',
    'PreRevertir'
)

# ============================================================
# FUNCIONES PÚBLICAS: REGISTRO
# ============================================================

function Clear-LabCapacidades {
    <#
    .SYNOPSIS
        Vacía el registro de capacidades. Útil para tests o recargas.
    #>
    $script:LabCapacidades = @{}
}

function Register-LabCapacidad {
    <#
    .SYNOPSIS
        Registra una capacidad tras validar el contrato.
    .DESCRIPTION
        Valida campos obligatorios, scriptblocks, nombre único, sección
        única, dependencias existentes y sin ciclos, y nivel permitido.
        Los campos opcionales (ObtenerClaves, PostCrear, PreRevertir) se
        validan como scriptblocks si están presentes.
    .PARAMETER Capacidad
        Hashtable con los campos del contrato de capacidad.
    .PARAMETER NivelCarpeta
        Nivel heredado de la carpeta ('Free', 'P1', 'P2').
    .OUTPUTS
        $true si se registró, $false si falló la validación.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Capacidad,

        [string]$NivelCarpeta = 'Free'
    )

    # 1. Campos obligatorios
    foreach ($campo in $script:LabCapacidadCamposObligatorios) {
        if (-not $Capacidad.ContainsKey($campo)) {
            Write-LabWarn "Capacidad rechazada: falta el campo obligatorio '$campo'."
            return $false
        }
    }

    $nombre = $Capacidad.Nombre
    if ([string]::IsNullOrWhiteSpace($nombre)) {
        Write-LabWarn 'Capacidad rechazada: Nombre vacío.'
        return $false
    }

    # 2. Scriptblocks obligatorios
    foreach ($campo in @('TestDisponible','ValidarDef','Describir','Crear','Revertir','PreguntarUI')) {
        if ($Capacidad[$campo] -isnot [scriptblock]) {
            Write-LabWarn "Capacidad '$nombre' rechazada: '$campo' no es un scriptblock."
            return $false
        }
    }

    # 3. Scriptblocks opcionales (si están, deben ser scriptblock)
    foreach ($campo in $script:LabCapacidadCamposOpcionalesScriptblock) {
        if ($Capacidad.ContainsKey($campo) -and $null -ne $Capacidad[$campo]) {
            if ($Capacidad[$campo] -isnot [scriptblock]) {
                Write-LabWarn "Capacidad '$nombre' rechazada: '$campo' no es un scriptblock."
                return $false
            }
        }
    }

    # 4. Nombre duplicado
    if ($script:LabCapacidades.ContainsKey($nombre)) {
        Write-LabWarn "Capacidad '$nombre' rechazada: ya existe una capacidad con ese nombre."
        return $false
    }

    # 5. SeccionJson duplicada (si no es $null)
    if (-not [string]::IsNullOrWhiteSpace($Capacidad.SeccionJson)) {
        foreach ($existente in $script:LabCapacidades.Values) {
            if ($existente.SeccionJson -eq $Capacidad.SeccionJson) {
                Write-LabWarn "Capacidad '$nombre' rechazada: la sección '$($Capacidad.SeccionJson)' ya la reclama '$($existente.Nombre)'."
                return $false
            }
        }
    }

    # 6. Nivel: si no lo declara, hereda de la carpeta
    if (-not $Capacidad.ContainsKey('Nivel') -or [string]::IsNullOrWhiteSpace($Capacidad.Nivel)) {
        $Capacidad['Nivel'] = $NivelCarpeta
    }

    # 7. Dependencias: existen y son de nivel igual o inferior
    $ordenCap = Get-LabNivelOrden -Nivel $Capacidad.Nivel
    foreach ($dep in @($Capacidad.DependeDe)) {
        if ([string]::IsNullOrWhiteSpace($dep)) { continue }
        if (-not $script:LabCapacidades.ContainsKey($dep)) {
            Write-LabWarn "Capacidad '$nombre' rechazada: depende de '$dep', que no está registrada."
            return $false
        }
        $ordenDep = Get-LabNivelOrden -Nivel $script:LabCapacidades[$dep].Nivel
        if ($ordenDep -gt $ordenCap) {
            Write-LabWarn "Capacidad '$nombre' rechazada: depende de '$dep' (nivel superior). Las dependencias solo pueden ser de nivel igual o inferior."
            return $false
        }
    }

    # 8. Ciclos
    if (Test-LabCicloDependencias -Nombre $nombre -Capacidad $Capacidad -Visitados @()) {
        Write-LabWarn "Capacidad '$nombre' rechazada: ciclo en DependeDe."
        return $false
    }

    # 9. Registrar
    $script:LabCapacidades[$nombre] = $Capacidad
    return $true
}

function Test-LabCicloDependencias {
    <#
    .SYNOPSIS
        Detecta ciclos en DependeDe de forma recursiva.
    .OUTPUTS
        $true si hay ciclo, $false si no.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Nombre,

        [Parameter(Mandatory = $true)]
        [hashtable]$Capacidad,

        [Parameter(Mandatory = $true)]
        [array]$Visitados
    )

    if ($Visitados -contains $Nombre) { return $true }
    $Visitados += $Nombre

    foreach ($dep in @($Capacidad.DependeDe)) {
        if ([string]::IsNullOrWhiteSpace($dep)) { continue }
        if (-not $script:LabCapacidades.ContainsKey($dep)) { continue }
        if (Test-LabCicloDependencias -Nombre $dep -Capacidad $script:LabCapacidades[$dep] -Visitados $Visitados) {
            return $true
        }
    }
    return $false
}

# ============================================================
# FUNCIONES PÚBLICAS: CONSULTA
# ============================================================

function Get-LabCapacidades {
    <#
    .SYNOPSIS
        Devuelve todas las capacidades registradas.
    .PARAMETER Nivel
        Si se especifica, filtra por nivel permitido.
    .PARAMETER SoloDisponibles
        Si se especifica, filtra por TestDisponible = $true.
    .PARAMETER Contexto
        Contexto para TestDisponible. Obligatorio si SoloDisponibles.
    .OUTPUTS
        Array de hashtables de capacidad, ordenado por Nombre.
    #>
    param(
        [string]$Nivel = $null,
        [switch]$SoloDisponibles,
        [hashtable]$Contexto = $null
    )

    $resultado = @($script:LabCapacidades.Values)

    if ($Nivel) {
        $resultado = @($resultado | Where-Object { Test-LabNivelPermitido -NivelCapacidad $_.Nivel -NivelConfigurado $Nivel })
    }

    if ($SoloDisponibles -and $Contexto) {
        $resultado = @($resultado | Where-Object {
            $t = & $_.TestDisponible $Contexto
            return ($t.Disponible -eq $true)
        })
    }

    return @($resultado | Sort-Object { $_.Nombre })
}

function Get-LabCapacidad {
    <#
    .SYNOPSIS
        Devuelve una capacidad por nombre, o $null si no existe.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Nombre
    )
    if ($script:LabCapacidades.ContainsKey($Nombre)) {
        return $script:LabCapacidades[$Nombre]
    }
    return $null
}

function Get-LabCapacidadPorSeccion {
    <#
    .SYNOPSIS
        Devuelve la capacidad que reclama una sección JSON, o $null.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Seccion
    )
    foreach ($cap in $script:LabCapacidades.Values) {
        if ($cap.SeccionJson -eq $Seccion) { return $cap }
        if ($cap.ContainsKey('Alias') -and ($cap.Alias -contains $Seccion)) { return $cap }
    }
    return $null
}

function Test-LabCapacidadRegistrada {
    <#
    .SYNOPSIS
        Devuelve $true si la capacidad está registrada.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Nombre
    )
    return $script:LabCapacidades.ContainsKey($Nombre)
}

function Get-LabCapacidadClaves {
    <#
    .SYNOPSIS
        Devuelve las claves que una capacidad va a tocar para una definición.
    .DESCRIPTION
        Si la capacidad implementa ObtenerClaves, lo llama con la definición
        y devuelve el array de claves. Si no, devuelve @().
        Lo usa lib_creadores.ps1 para construir el snapshot pre-lab por
        capacidad si se necesita.
    .PARAMETER Capacidad
        Hashtable de la capacidad.
    .PARAMETER Definicion
        Sección del escenario normalizado para esa capacidad.
    .OUTPUTS
        Array de claves (strings).
    #>
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Capacidad,

        [Parameter(Mandatory = $true)]
        [object]$Definicion
    )

    if (-not $Capacidad.ContainsKey('ObtenerClaves') -or $null -eq $Capacidad.ObtenerClaves) {
        return @()
    }
    if ($Capacidad.ObtenerClaves -isnot [scriptblock]) {
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
    <#
    .SYNOPSIS
        Carga y registra todas las capacidades de lib_caps/.
    .PARAMETER Root
        Ruta raíz de capacidades (por defecto, lib_caps/ junto a este script).
    .PARAMETER Niveles
        Niveles a cargar. Si se omite, carga todos los disponibles.
    .OUTPUTS
        Número de capacidades registradas.
    #>
    param(
        [string]$Root = $null,
        [array]$Niveles = $null
    )

    if (-not $Root) {
        $Root = Join-Path $PSScriptRoot 'lib_caps'
    }

    Clear-LabCapacidades

    if (-not (Test-Path -Path $Root -PathType Container)) {
        Write-LabWarn "No existe la carpeta de capacidades: $Root"
        return 0
    }

    if (-not $Niveles -or $Niveles.Count -eq 0) {
        $Niveles = Get-LabNivelesDisponibles -RootCaps $Root
    }

    $total = 0
    foreach ($nivel in $Niveles) {
        $carpeta = Get-LabNivelCarpeta -Nivel $nivel
        $rutaNivel = Join-Path $Root $carpeta
        if (-not (Test-Path -Path $rutaNivel -PathType Container)) { continue }

        $archivos = Get-ChildItem -Path $rutaNivel -Filter 'cap_*.ps1' -File -ErrorAction SilentlyContinue
        foreach ($archivo in $archivos) {
            try {
                . $archivo.FullName

                if ($null -eq $Capacidad) {
                    Write-LabWarn "El archivo $($archivo.Name) no define `$Capacidad."
                    continue
                }

                if (Register-LabCapacidad -Capacidad $Capacidad -NivelCarpeta $nivel) {
                    $total++
                }
            } catch {
                Write-LabWarn "Error cargando $($archivo.Name): $($_.Exception.Message)"
            } finally {
                Remove-Variable -Name 'Capacidad' -ErrorAction SilentlyContinue
            }
        }
    }

    return $total
}