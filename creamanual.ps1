<#
.SYNOPSIS
    Creación manual de entorno de laboratorio en Entra ID (Constructor de Escenarios).
.DESCRIPTION
    Construcción interactiva de un escenario a medida. El menú muestra
    el estado actual del escenario en todo momento.

    Funcionalidades:
      - Añadir objetos de cualquier capacidad disponible.
      - Ver el estado actual del escenario en el menú.
      - Guardar el escenario como JSON reutilizable.
      - Opción de lanzar la creación en Entra ID inmediatamente delegando
        en creauto.ps1.

    CONTRASEÑAS:
    Para cada usuario, se puede generar la contraseña desde la semilla de
    la sesión manual. La contraseña no se guarda en el JSON.

    La sesión de Graph la gestiona menu.ps1.
.NOTES
    Depende de lib_ui.ps1, lib_graph.ps1, lib_config.ps1,
    lib_manifiesto.ps1, lib_escenarios.ps1, lib_niveles.ps1,
    lib_caps.ps1, lib_creadores.ps1.
    Requiere PowerShell 7.
#>
#Requires -Version 7.0

[CmdletBinding()]
param()

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
# VERIFICACIÓN DE SESIÓN
# ============================================================
if (-not (Test-LabGraphSession)) {
    Write-LabError 'No hay sesión de Graph activa. Ejecuta este script desde menu.ps1.'
    exit 1
}

# ============================================================
# ESTADO Y CONFIGURACIÓN
# ============================================================
$config = Get-LabConfig
$nivel = Get-LabNivelActual -Config $config
$null = Initialize-LabCapacidades -Root (Join-Path $PSScriptRoot 'lib_caps')


# ============================================================
# CARGA O CREACIÓN DE ESCENARIO
# ============================================================

function Select-LabEscenarioInicial {
    Show-LabHeader -Titulo 'CREACION MANUAL - INICIO'
    Write-Host '  [1] Empezar de cero'
    Write-Host '  [2] Cargar un escenario existente'
    Write-Host ''

    $op = Read-Host 'Selecciona una opción'

    if ($op -eq '2') {
        $escenarios = @(Get-LabEscenariosDisponibles)
        if ($escenarios.Count -eq 0) {
            Write-LabWarn 'No hay escenarios disponibles. Se empieza de cero.'
            return (ConvertTo-LabEscenarioNormalizado -Raw ([pscustomobject]@{}))
        }

        Write-Host ''
        Write-Host '  Escenarios disponibles:' -ForegroundColor Cyan
        for ($i = 0; $i -lt $escenarios.Count; $i++) {
            Write-Host ('    [{0}] {1}' -f $i, $escenarios[$i])
        }
        $sel = Read-Host 'Selecciona un escenario'
        if ($sel -match '^\d+$' -and [int]$sel -lt $escenarios.Count) {
            $path = Resolve-LabEscenarioPath -Nombre $escenarios[[int]$sel]
            if (-not $path) { $path = Join-Path (Get-LabEscenariosPath) "$($escenarios[[int]$sel]).json" }
            return (ConvertTo-LabEscenarioNormalizado -Path $path)
        }
    }

    return (ConvertTo-LabEscenarioNormalizado -Raw ([pscustomobject]@{}))
}

# ============================================================
# MENÚ GENERADO DESDE CAPACIDADES
# ============================================================

function Show-LabMenuCapacidades {
    param(
        [Parameter(Mandatory = $true)] [string]$Nivel,
        [Parameter(Mandatory = $true)] [hashtable]$Contexto
    )

    $capacidades = @(Get-LabCapacidades -Nivel $Nivel -SoloDisponibles -Contexto $Contexto)
    if ($capacidades.Count -eq 0) {
        Write-LabWarn 'No hay capacidades disponibles para el nivel actual.'
        return $null
    }

    Show-LabHeader -Titulo 'AÑADIR OBJETOS'
    for ($i = 0; $i -lt $capacidades.Count; $i++) {
        $cap = $capacidades[$i]
        $nombre = if ($cap.ContainsKey('Descripcion') -and $cap.Descripcion) { $cap.Descripcion } else { $cap.Nombre }
        Write-Host ('  [{0}] {1}' -f $i, $nombre)
    }
    Write-Host ''

    $sel = Read-Host 'Selecciona una capacidad (Enter para volver)'
    if ([string]::IsNullOrWhiteSpace($sel)) { return $null }
    if (-not ($sel -match '^\d+$') -or [int]$sel -ge $capacidades.Count) {
        Write-LabWarn 'Selección inválida.'
        return $null
    }
    return $capacidades[[int]$sel]
}

# ============================================================
# ESTADO DEL ESCENARIO (PANEL VISUAL)
# ============================================================

function Show-LabEstadoEscenario {
    param(
        [Parameter(Mandatory = $true)] [object]$Escenario
    )

    Write-Host '  --- Objetos en el escenario ---' -ForegroundColor Yellow
    $total = 0
    foreach ($nombreCap in $Escenario.Secciones.Keys) {
        $def = @($Escenario.Secciones[$nombreCap])
        if ($def.Count -eq 0) { continue }

        $cap = Get-LabCapacidad -Nombre $nombreCap
        $nombreVisible = if ($cap -and $cap.ContainsKey('Descripcion') -and $cap.Descripcion) { $cap.Descripcion } else { $nombreCap }

        Write-Host "  $nombreVisible ($($def.Count)):" -ForegroundColor Cyan
        foreach ($d in $def) {
            $resumen = ''
            switch ($nombreCap) {
                'Usuarios' {
                    $dn  = Get-LabPropSegura -Objeto $d -Nombre 'displayName' -PorDefecto '(sin displayName)'
                    $upn = Get-LabPropSegura -Objeto $d -Nombre 'upn'         -PorDefecto '(sin upn)'
                    $resumen = "$dn ($upn)"
                }
                'Grupos' {
                    $dn = Get-LabPropSegura -Objeto $d -Nombre 'displayName' -PorDefecto '(sin displayName)'
                    $resumen = $dn
                }
                'Aplicaciones' {
                    $dn = Get-LabPropSegura -Objeto $d -Nombre 'displayName' -PorDefecto '(sin displayName)'
                    $resumen = $dn
                }
                'Relaciones' {
                    $u = Get-LabPropSegura -Objeto $d -Nombre 'usuario' -PorDefecto '(sin usuario)'
                    $g = Get-LabPropSegura -Objeto $d -Nombre 'grupo'   -PorDefecto '(sin grupo)'
                    $resumen = "$u -> $g"
                }
                default {
                    try { $resumen = ($d | ConvertTo-Json -Compress -Depth 3) }
                    catch { $resumen = '(no serializable)' }
                }
            }
            Write-Host "    - $resumen" -ForegroundColor Gray
        }
        $total += $def.Count
    }

    if ($total -eq 0) {
        Write-Host '  (escenario vacío)' -ForegroundColor DarkGray
    }
    Write-Host ''
}

# ============================================================
# FLUJO PRINCIPAL
# ============================================================

# N3: un único timestamp para el nombre del escenario y la semilla
$timestampSesion = Get-Date -Format 'yyyyMMdd_HHmmss'

# 1. Cargar o empezar de cero
$esc = Select-LabEscenarioInicial
if ([string]::IsNullOrWhiteSpace($esc.Nombre)) {
    $esc.Nombre = "manual_$timestampSesion"
}

# 2. Semilla de la sesión manual (mismo timestamp que $esc.Nombre)
$nombreSemilla = "manual_$timestampSesion"
$semilla = Get-LabSeed -NombreEscenario $nombreSemilla
Write-LabInfo "Semilla de esta sesión: $nombreSemilla"
Write-Host ''

# 3. Contexto para PreguntarUI
# N6: TenantDomain es el dominio verificado, no el GUID
$tenantIdActual     = $null
$tenantDomainActual = $null
try {
    $mgCtx = Get-MgContext
    if ($mgCtx) { $tenantIdActual = $mgCtx.TenantId }
} catch { }
$tenantDomainActual = Get-LabTenantDomainSafe
if ([string]::IsNullOrWhiteSpace($tenantDomainActual)) {
    $tenantDomainActual = $tenantIdActual
}

$ctx = @{
    TenantId        = $tenantIdActual
    TenantDomain    = $tenantDomainActual
    Nivel           = $nivel
    Manifiesto      = $null
    ObjetosCreados  = @{}
    Config          = $config
    SnapshotPreLab  = @{}
    PasswordsPorUpn = @{}
    DerivarPassword = {
        param($upn)
        return (New-LabPasswordFromSeed -Semilla $semilla -Upn $upn)
    }.GetNewClosure()
    Semilla         = $semilla
}

# 4. Bucle de construcción
$salir = $false
while (-not $salir) {
    # N2: pequeña pausa para mitigar el parpadeo del Clear-LabScreen
    Start-Sleep -Milliseconds 150
    Show-LabHeader -Titulo 'CREACION MANUAL - CONSTRUCCION DEL ESCENARIO'
    Show-LabEstadoEscenario -Escenario $esc

    Write-Host '  --- Acciones ---' -ForegroundColor Cyan
    Write-Host '  [A] Añadir objeto'
    Write-Host '  [X] Guardar escenario en JSON y finalizar'
    Write-Host '  [S] Salir sin guardar'
    Write-Host ''

    $op = Read-Host 'Selecciona una opción'

    switch ($op.ToUpper()) {
        'A' {
            $cap = Show-LabMenuCapacidades -Nivel $nivel -Contexto $ctx
            if ($cap) {
                try {
                    $def = & $cap.PreguntarUI $ctx
                    if ($null -ne $def) {
                        if (-not $esc.Secciones.Contains($cap.Nombre)) {
                            $esc.Secciones[$cap.Nombre] = @()
                        }
                        $esc.Secciones[$cap.Nombre] += $def
                        Write-LabOk "Objeto añadido a '$($cap.Nombre)'."
                    }
                } catch {
                    Write-LabError "Error en PreguntarUI de '$($cap.Nombre)': $($_.Exception.Message)"
                }
            }
            Wait-LabKey
        }
        'X' {
            $nombreExport = Read-Host 'Nombre del escenario a guardar (sin extensión)'
            if (-not [string]::IsNullOrWhiteSpace($nombreExport)) {
                $path = Join-Path (Get-LabEscenariosPath) "$nombreExport.json"
                try {
                    $obj = ConvertFrom-LabEscenarioNormalizado -EscenarioNormalizado $esc
                    $obj | ConvertTo-Json -Depth 15 | Set-Content -Path $path -Encoding UTF8 -Force
                    Write-LabOk "Escenario exportado: $path"

                    if ($ctx.PasswordsPorUpn.Count -gt 0) {
                        Write-Host ''
                        Write-Host '=== CONTRASEÑAS DERIVADAS (MOSTRAR UNA SOLA VEZ) ===' -ForegroundColor Yellow
                        Write-Host 'Anota estas credenciales. No se guardan en el manifiesto ni en el JSON.' -ForegroundColor Yellow
                        Write-Host "Semilla de esta sesión: $nombreSemilla" -ForegroundColor Yellow
                        Write-Host ''
                        foreach ($upn in $ctx.PasswordsPorUpn.Keys) {
                            Write-Host ("  {0} / {1}" -f $upn, $ctx.PasswordsPorUpn[$upn]) -ForegroundColor Gray
                        }
                        Write-Host ''
                    }

                    Write-Host '¿Quieres crear este escenario en Entra ID ahora?' -ForegroundColor Yellow
                    $resp = Read-Host "Escribe 'SI' para confirmar"
                    if ($resp -eq 'SI') {
                        $scriptAuto = Join-Path $PSScriptRoot 'creauto.ps1'
                        & $scriptAuto -Escenario $nombreExport
                    }
                    $salir = $true
                } catch {
                    Write-LabError "No se pudo exportar: $($_.Exception.Message)"
                }
            }
            Wait-LabKey
        }
        'S' {
            if (Read-LabConfirm '¿Salir sin guardar el escenario?') {
                $salir = $true
            }
        }
        default {
            Write-LabWarn 'Opción no válida.'
            Start-Sleep -Seconds 1
        }
    }
}

Write-Host ''
Write-LabOk 'Creación manual finalizada.'