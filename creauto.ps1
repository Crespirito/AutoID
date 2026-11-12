<#
.SYNOPSIS
    Creación automática de entorno de laboratorio en Entra ID.
.DESCRIPTION
    Lee un archivo JSON de escenario y lo despliega en Entra ID.
    Flujo:
      1. Mostrar escenarios disponibles y seleccionar uno (con números).
      2. Confirmar acción con la letra G o salir con X.
      3. Generar contraseñas a partir de la semilla.
      4. Desplegar usando Invoke-LabCreacion.
      5. Guardar manifiesto y mostrar credenciales.
.NOTES
    Depende de lib_ui.ps1, lib_graph.ps1, lib_config.ps1,
    lib_manifiesto.ps1, lib_escenarios.ps1, lib_niveles.ps1,
    lib_caps.ps1, lib_creadores.ps1.
    Requiere PowerShell 7.
#>
#Requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$Escenario = $null,

    [Parameter(Mandatory = $false)]
    [switch]$DryRun
)

# Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================
# CARGA DE LIBRERÍAS
# ============================================================
. (Join-Path $PSScriptRoot 'lib_ui.ps1')
. (Join-Path $PSScriptRoot 'lib_graph.ps1')
. (Join-Path $PSScriptRoot 'lib_config.ps1')
. (Join-Path $PSScriptRoot 'lib_manifiesto.ps1')
. (Join-Path $PSScriptRoot 'lib_escenarios.ps1')
. (Join-Path $PSScriptRoot 'lib_niveles.ps1')
. (Join-Path $PSScriptRoot 'lib_caps.ps1')
. (Join-Path $PSScriptRoot 'lib_creadores.ps1')
. (Join-Path $PSScriptRoot 'lib_helpers.ps1')

# ============================================================
# HELPERS DE ACCESO SEGURO A PROPIEDADES
# ============================================================

function Get-LabPropSegura {
    <#
    .SYNOPSIS
        Devuelve el valor de una propiedad de un objeto, o $null si no existe.
    .DESCRIPTION
        Evita errores de StrictMode cuando se accede a propiedades que
        pueden no existir. Acepta objetos PSCustomObject y Hashtable.
    #>
    param(
        [Parameter(Mandatory = $true)] $Objeto,
        [Parameter(Mandatory = $true)] [string]$Nombre,
        $PorDefecto = $null
    )

    if ($null -eq $Objeto) { return $PorDefecto }

    if ($Objeto -is [hashtable]) {
        if ($Objeto.ContainsKey($Nombre)) {
            $v = $Objeto[$Nombre]
            if ($null -ne $v) { return $v }
            return $PorDefecto
        }
        return $PorDefecto
    }

    if ($Objeto.PSObject.Properties[$Nombre]) {
        $v = $Objeto.$Nombre
        if ($null -ne $v) { return $v }
        return $PorDefecto
    }

    return $PorDefecto
}

function Get-LabTenantDomainSafe {
    <#
    .SYNOPSIS
        Devuelve el dominio verificado del tenant con fallback a TenantId.
    #>
    $dominio = $null
    try {
        $dominio = Get-LabTenantDomain
    } catch {
        $dominio = $null
    }
    if (-not [string]::IsNullOrWhiteSpace($dominio)) {
        return $dominio
    }
    try {
        $ctx = Get-MgContext
        if ($ctx -and -not [string]::IsNullOrWhiteSpace($ctx.TenantId)) {
            return $ctx.TenantId
        }
    } catch { }
    return $null
}

# ============================================================
# VERIFICACIÓN DE SESIÓN
# ============================================================
if (-not $DryRun) {
    if (-not (Test-LabGraphSession)) {
        Write-LabError 'No hay sesión de Graph activa. Ejecuta este script desde menu.ps1.'
        exit 1
    }
} else {
    Write-LabInfo 'Modo -DryRun: no se requiere sesión de Graph.'
}

# ============================================================
# ESTADO Y CONFIGURACIÓN
# ============================================================
$config = Get-LabConfig
$totalCaps = Initialize-LabCapacidades -Root (Join-Path $PSScriptRoot 'lib_caps')
if ($totalCaps -eq 0) {
    Write-LabError 'No se han cargado capacidades. Revisa la carpeta lib_caps.'
    exit 1
}


# ============================================================
# FLUJO PRINCIPAL
# ============================================================

# 1. Si no se pasó un escenario por parámetro, mostrar menú
if (-not $Escenario) {
    $escenarios = @(Get-LabEscenariosDisponibles)

    if ($escenarios.Count -eq 0) {
        Write-LabError "No hay escenarios disponibles en $(Get-LabEscenariosPath)."
        Write-LabInfo 'Usa [2] Creación manual o generar_biblioteca.ps1 para crear uno.'
        exit 1
    }

    $seleccionado = $null
    $salirMenu = $false

    while (-not $salirMenu) {
        Show-LabHeader -Titulo 'SELECCION DE ESCENARIO'

        for ($i = 0; $i -lt $escenarios.Count; $i++) {
            $marca = if ($seleccionado -eq $escenarios[$i]) { ' [*]' } else { '' }
            Write-Host ('  [{0}] {1}{2}' -f ($i + 1), $escenarios[$i], $marca)
        }

        Write-Host ''
        Write-Host '  [G] Guardar y crear en Entra ID (requiere selección)'
        Write-Host '  [X] Salir sin hacer nada'
        Write-Host ''

        if ($seleccionado) {
            Write-Host "  Escenario seleccionado: $seleccionado" -ForegroundColor Green
        } else {
            Write-Host "  Ningún escenario seleccionado." -ForegroundColor DarkGray
        }
        Write-Host ''

        $opcion = Read-Host 'Selecciona una opción (número, G o X)'

        if ([string]::IsNullOrWhiteSpace($opcion)) { continue }

        $opcionUpper = $opcion.ToUpper()

        if ($opcionUpper -eq 'X') {
            Write-LabInfo 'Operación cancelada por el usuario.'
            exit 0
        }
        elseif ($opcionUpper -eq 'G') {
            if (-not $seleccionado) {
                Write-LabWarn 'Primero debes seleccionar un escenario de la lista con un número.'
                Start-Sleep -Seconds 2
            } else {
                $Escenario = $seleccionado
                $salirMenu = $true
            }
        }
        elseif ($opcion -match '^\d+$') {
            $idx = [int]$opcion - 1
            if ($idx -ge 0 -and $idx -lt $escenarios.Count) {
                $seleccionado = $escenarios[$idx]
            } else {
                Write-LabWarn 'Número de escenario fuera de rango.'
                Start-Sleep -Seconds 2
            }
        }
        else {
            Write-LabWarn 'Opción no válida.'
            Start-Sleep -Seconds 2
        }
    }
}

# 2. Cargar el escenario normalizado
$path = Resolve-LabEscenarioPath -Nombre $Escenario
if (-not $path) { $path = Join-Path (Get-LabEscenariosPath) "$Escenario.json" }
if (-not (Test-Path -Path $path)) {
    Write-LabError "No existe el archivo del escenario: $path"
    exit 1
}

try {
    $esc = ConvertTo-LabEscenarioNormalizado -Path $path
} catch {
    Write-LabError "No se pudo cargar el escenario '$Escenario': $($_.Exception.Message)"
    exit 1
}

# 3. Resumen visual y validación de vacío
$nombreEsc = if ($null -ne $esc -and (Get-DicTiene $esc 'Nombre') -and -not [string]::IsNullOrWhiteSpace([string](Get-DicValor $esc 'Nombre'))) { [string](Get-DicValor $esc 'Nombre') } else { $Escenario }
Show-LabHeader -Titulo ('RESUMEN DEL ESCENARIO: ' + $nombreEsc)

$nivelActual = Get-LabNivelActual -Config $config
Write-Host "Descripción: $($esc.Descripcion)" -ForegroundColor Gray
Write-Host "Nivel actual: $nivelActual" -ForegroundColor Gray
Write-Host ''

$tieneDatos = $false
foreach ($nombreCap in $esc.Secciones.Keys) {
    $def = @($esc.Secciones[$nombreCap])
    if ($def.Count -eq 0) { continue }

    $tieneDatos = $true
    $cap = Get-LabCapacidad -Nombre $nombreCap
    if (-not $cap) {
        Write-Host "  [$nombreCap] (capacidad no registrada)" -ForegroundColor Red
        continue
    }

    try {
        $texto = & $cap.Describir $def
        Write-Host "  $texto" -ForegroundColor Gray
    } catch {
        Write-Host "  [$nombreCap] $($def.Count) objetos (error en Describir)" -ForegroundColor Yellow
    }
}

if (-not $tieneDatos) {
    Write-LabWarn 'El escenario no tiene ningún objeto para crear (todas las secciones están vacías).'
    exit 0
}

if ($esc.Desconocidas.Count -gt 0) {
    Write-Host ''
    Write-LabWarn "Secciones desconocidas ignoradas: $($esc.Desconocidas -join ', ')"
}
Write-Host ''

# Validar con las capacidades (FORZADO)
$errores = @()
foreach ($nombreSeccion in $esc.Secciones.Keys) {
    $def = @($esc.Secciones[$nombreSeccion])
    if ($def.Count -eq 0) { continue }

    $cap = Get-LabCapacidadPorSeccion -NombreSeccion $nombreSeccion
    if (-not $cap) {
        $errores += "No hay capacidad para la sección '$nombreSeccion'."
        continue
    }

    if ($cap.ContainsKey('ValidarDef') -and $cap.ValidarDef -is [scriptblock]) {
        try {
            $errsCap = & $cap.ValidarDef $def
            foreach ($e in @($errsCap)) {
                if (-not [string]::IsNullOrWhiteSpace($e)) {
                    $errores += "[$($cap.Nombre)] $e"
                }
            }
        } catch {
            $errores += "[$($cap.Nombre)] Error ejecutando ValidarDef: $($_.Exception.Message)"
        }
    }
}

if (@($errores).Count -gt 0) {
    Write-LabError 'El escenario tiene errores de validación:'
    foreach ($e in @($errores)) { Write-Host "  - $e" -ForegroundColor Red }
    exit 1
}
# 4. Confirmación final
if ($DryRun) {
    Write-Host '*** MODO SIMULACION (-DryRun): NO se modificara Entra ID ***' -ForegroundColor Yellow
    Write-Host ''
    Write-LabOk 'Simulación completada.'
    exit 0
}

Write-Host '¿Crear este escenario en Entra ID?' -ForegroundColor Yellow
$resp = Read-Host "Escribe 'SI' para confirmar"
if ($resp -ne 'SI') {
    Write-LabInfo 'Operación cancelada por el usuario.'
    exit 0
}

# 5. Derivar contraseñas e inyectarlas
$nombreEscenarioSeguro = "manual_" + (Get-Date -Format 'yyyyMMdd_HHmmss')
if ($null -ne $esc -and (Get-DicTiene $esc 'Nombre') -and -not [string]::IsNullOrWhiteSpace([string](Get-DicValor $esc 'Nombre'))) {
    $nombreEscenarioSeguro = [string](Get-DicValor $esc 'Nombre')
}

$nombreSemilla = $nombreEscenarioSeguro
$semilla = Get-LabSeed -NombreEscenario $nombreSemilla

$passwords = @{}
if ($esc.Secciones.Contains('Usuarios')) {
    foreach ($u in @($esc.Secciones['Usuarios'])) {
        if ($null -eq $u) { continue }
        if ((Get-DicTiene $u 'upn') -and -not [string]::IsNullOrWhiteSpace([string](Get-DicValor $u 'upn'))) {
            $upn = [string](Get-DicValor $u 'upn') -replace '\{tenant\}', [string](Get-DicValor $esc 'TenantDomain')
            $passwords[$upn] = New-LabPasswordFromSeed -Semilla $semilla -Upn $upn
        }
    }
}

# Copia defensiva del hashtable antes de mutarlo
$config = $config.Clone()
$config['Passwords'] = $passwords

# 6. Manifiesto y Creación
$manifiesto = New-LabManifiestoVacio -Escenario $nombreEscenarioSeguro -Nivel $nivelActual -Semilla $nombreSemilla

# N6: TenantDomain real, con fallback a TenantId
$tenantDomainActual = Get-LabTenantDomainSafe
$manifiesto.TenantDomain = $tenantDomainActual

Write-Host ''
Write-LabBanner 'Iniciando despliegue en Entra ID'
$resultado = Invoke-LabCreacion -EscenarioNormalizado $esc -Manifiesto $manifiesto -Config $config

# 7. Guardar manifiesto
$manifiestoPath = Get-LabManifiestoPath
if (Save-LabManifiesto -Manifiesto $manifiesto -Path $manifiestoPath) {
    Write-LabOk "Manifiesto guardado en: $manifiestoPath"
} else {
    Write-LabError 'No se pudo guardar el manifiesto.'
}

# 8. Mostrar credenciales finales
if ($passwords.Count -gt 0) {
    Write-Host ''
    Write-Host '=== CONTRASEÑAS DERIVADAS (MOSTRAR UNA SOLA VEZ) ===' -ForegroundColor Yellow
    Write-Host 'Anota estas credenciales. No se guardan en el manifiesto ni en el JSON.' -ForegroundColor Yellow
    Write-Host "Semilla: $nombreSemilla" -ForegroundColor Yellow
    Write-Host ''
    foreach ($upn in $passwords.Keys) {
        Write-Host ("  {0} / {1}" -f $upn, $passwords[$upn]) -ForegroundColor Gray
    }
    Write-Host ''
}

Write-Host ''
Write-LabOk 'Creación automática finalizada.'