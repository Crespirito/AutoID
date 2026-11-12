<#
.SYNOPSIS
    Limpieza de entornos de laboratorio en Entra ID.
.DESCRIPTION
    Lee el manifiesto generado por los scripts de creación y revierte
    todos los objetos creados y las vulnerabilidades aplicadas.

    Orden de borrado (gestionado por Invoke-LabReversion):
      1. Vulnerabilidades aplicadas.
      2. Objetos en orden inverso de creación (LIFO).

    SEGURIDAD:
    - Verifica el objectId del manifiesto con el actual antes de borrar.
    - Ignora objetos con estado 'preexistente'.
    - Avisa si una capacidad no está registrada y no borra a ciegas.

    SOFT-DELETE:
    Los objetos se pueden restaurar durante 30 días desde el portal de Entra ID.

    La sesión de Graph la gestiona menu.ps1. Este script NO conecta ni
    desconecta; solo verifica que hay sesión activa.
.PARAMETER ManifiestoPath
    Ruta del manifiesto a procesar. Si se omite, se usa el estándar.
.PARAMETER Forzar
    Si se especifica, para objetos cuya capacidad no está registrada,
    intenta un borrado genérico por tipo.
.NOTES
    Requiere PowerShell 7.
#>
#Requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ManifiestoPath = $null,

    [Parameter(Mandatory = $false)]
    [switch]$Forzar
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

# ============================================================
# VERIFICACIÓN DE SESIÓN Y CAPACIDADES
# ============================================================
if (-not (Test-LabGraphSession)) {
    Write-LabError 'No hay sesión de Graph activa. Ejecuta este script desde menu.ps1.'
    exit 1
}

$config = Get-LabConfig

# Evitar doble carga si venimos desde menu.ps1
if ((Get-LabCapacidades).Count -eq 0) {
    $null = Initialize-LabCapacidades -Root (Join-Path $PSScriptRoot 'lib_caps')
}

if (-not $ManifiestoPath) {
    $ManifiestoPath = Get-LabManifiestoPath
}

# ============================================================
# VERIFICACIÓN DEL MANIFIESTO
# ============================================================
if (-not (Test-Path -Path $ManifiestoPath)) {
    Write-LabError "No se encuentra el manifiesto: $ManifiestoPath"
    Write-LabInfo 'Asegúrate de que el script de creación se ejecutó correctamente.'
    exit 1
}

# ============================================================
# CARGA DEL MANIFIESTO
# ============================================================
Write-LabBanner 'Iniciando limpieza del laboratorio'

try {
    $manifiesto = Get-LabManifiesto -Path $ManifiestoPath
} catch {
    Write-LabError "No se pudo leer el manifiesto: $($_.Exception.Message)"
    exit 1
}

if ($null -eq $manifiesto) {
    Write-LabError 'El manifiesto está vacío o no se pudo cargar.'
    exit 1
}

# Validación defensiva: objetos y vulnerabilidades deben ser arrays
# (Get-LabManifiesto ya los normaliza, pero reforzamos)
if ($null -eq $manifiesto.objetos -or $manifiesto.objetos -isnot [array]) {
    Write-LabWarn 'Manifiesto sin lista de objetos válida. Se asume lista vacía.'
    $manifiesto.objetos = @()
}
if ($null -eq $manifiesto.vulnerabilidades -or $manifiesto.vulnerabilidades -isnot [array]) {
    Write-LabWarn 'Manifiesto sin lista de vulnerabilidades válida. Se asume lista vacía.'
    $manifiesto.vulnerabilidades = @()
}

# ============================================================
# RESUMEN Y CONFIRMACIÓN
# ============================================================
$pendientes = Get-LabManifiestoPendientes -Manifiesto $manifiesto

Write-Host ''
Write-Host '--- Contenido del manifiesto ---' -ForegroundColor Yellow
Write-Host "  Versión           : $($manifiesto.manifestVersion)"
Write-Host "  Fecha             : $($manifiesto.fecha)"
Write-Host "  Tenant            : $($manifiesto.tenantDomain)"
Write-Host "  Escenario         : $($manifiesto.escenario)"
Write-Host "  Objetos totales   : $($manifiesto.objetos.Count)"
Write-Host "  Vulnerabilidades  : $($manifiesto.vulnerabilidades.Count)"
Write-Host ''
Write-Host "  Objetos pendientes         : $($pendientes.objetos.Count)" -ForegroundColor Yellow
Write-Host "  Vulnerabilidades pendientes: $($pendientes.vulnerabilidades.Count)" -ForegroundColor Yellow
Write-Host ''

if ($pendientes.objetos.Count -eq 0 -and $pendientes.vulnerabilidades.Count -eq 0) {
    Write-LabOk 'No hay objetos ni vulnerabilidades pendientes de revertir.'
    exit 0
}

if (-not $Forzar) {
    Write-Host '¿Estás seguro de que quieres REVERTIR todos estos elementos?' -ForegroundColor Yellow
    Write-Host 'Orden: primero vulnerabilidades, luego objetos (LIFO).' -ForegroundColor Gray
    Write-Host 'Los objetos preexistentes y los ya revertidos se ignoran.' -ForegroundColor Gray
    $confirmacion = Read-Host "Escribe 'SI' para confirmar"
    if ($confirmacion -ne 'SI') {
        Write-LabInfo 'Operación cancelada por el usuario.'
        exit 0
    }
}

# ============================================================
# REVERSIÓN
# ============================================================
Write-LabBanner 'Revirtiendo vulnerabilidades y objetos del manifiesto'

$resultado = Invoke-LabReversion -Manifiesto $manifiesto -Config $config -Forzar:$Forzar

# ============================================================
# RESUMEN DE REVERSIÓN
# ============================================================
Write-Host ''
Write-Host '--- Resumen de reversión ---' -ForegroundColor Cyan
Write-Host "  Revertidos     : $($resultado.Revertidos)" -ForegroundColor Green
Write-Host "  Fallidos       : $($resultado.Fallidos)" -ForegroundColor Red
Write-Host "  Omitidos       : $($resultado.Omitidos)" -ForegroundColor Yellow
Write-Host "  Preexistentes  : $($resultado.Preexistentes)" -ForegroundColor DarkGray
Write-Host "  Total objetos  : $($manifiesto.objetos.Count)" -ForegroundColor Gray
Write-Host "  Total vulns    : $($manifiesto.vulnerabilidades.Count)" -ForegroundColor Gray
Write-Host ''

# ============================================================
# GUARDAR MANIFIESTO ACTUALIZADO
# ============================================================
if (Save-LabManifiesto -Manifiesto $manifiesto -Path $ManifiestoPath) {
    Write-LabInfo "Manifiesto actualizado con el estado de reversión: $ManifiestoPath"
} else {
    Write-LabError 'No se pudo guardar el manifiesto actualizado.'
}

# ============================================================
# RENOMBRAR SI TODO SE REVIRTIÓ (N12: pasar -Path)
# ============================================================
$quedanPendientes = Get-LabManifiestoPendientes -Manifiesto $manifiesto
if ($quedanPendientes.objetos.Count -eq 0 -and $quedanPendientes.vulnerabilidades.Count -eq 0) {
    $manifiestoProcesado = Rename-LabManifiestoProcesado -Path $ManifiestoPath
    if ($manifiestoProcesado) {
        Write-LabOk "Manifiesto renombrado como procesado: $manifiestoProcesado"
    }
} else {
    Write-LabWarn "Quedan $($quedanPendientes.objetos.Count) objetos y $($quedanPendientes.vulnerabilidades.Count) vulnerabilidades pendientes."
    Write-LabInfo 'Revisa los avisos anteriores y vuelve a ejecutar la limpieza.'
}

# ============================================================
# VOLCADO DEL LOG
# ============================================================
# N8-log: nombre con escenario para distinguir limpiezas
$escenarioLog = if (-not [string]::IsNullOrWhiteSpace([string]$manifiesto.escenario)) {
    ($manifiesto.escenario -replace '[^a-zA-Z0-9_-]', '_')
} else {
    ''
}
$sufijoLog = if ($escenarioLog) { "_$escenarioLog" } else { '' }
$logPath = Join-Path $PSScriptRoot "log_cleanup$sufijoLog`_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"

try {
    $resumen = @()

    # N8-log: lectura segura de campos (PSObject.Properties)
    foreach ($o in $manifiesto.objetos) {
        $id = ''
        if ($o.PSObject.Properties['id'] -and $null -ne $o.id) { $id = [string]$o.id }

        $tipo = ''
        if ($o.PSObject.Properties['tipo'] -and $null -ne $o.tipo) { $tipo = [string]$o.tipo }

        $capacidad = ''
        if ($o.PSObject.Properties['capacidad'] -and $null -ne $o.capacidad) { $capacidad = [string]$o.capacidad }

        $estado = ''
        if ($o.PSObject.Properties['estado'] -and $null -ne $o.estado) { $estado = [string]$o.estado }

        $resumen += [pscustomobject]@{
            clase     = 'Objeto'
            id        = $id
            nombre    = ''
            tipo      = $tipo
            capacidad = $capacidad
            estado    = $estado
        }
    }

    foreach ($v in $manifiesto.vulnerabilidades) {
        $id = ''
        if ($v.PSObject.Properties['id'] -and $null -ne $v.id) { $id = [string]$v.id }

        $nombre = ''
        if ($v.PSObject.Properties['nombre'] -and $null -ne $v.nombre) { $nombre = [string]$v.nombre }

        $tipo = ''
        if ($v.PSObject.Properties['tipo'] -and $null -ne $v.tipo) { $tipo = [string]$v.tipo }

        $capacidad = ''
        if ($v.PSObject.Properties['capacidad'] -and $null -ne $v.capacidad) { $capacidad = [string]$v.capacidad }

        $estado = ''
        if ($v.PSObject.Properties['estado'] -and $null -ne $v.estado) { $estado = [string]$v.estado }

        $resumen += [pscustomobject]@{
            clase     = 'Vulnerabilidad'
            id        = $id
            nombre    = $nombre
            tipo      = $tipo
            capacidad = $capacidad
            estado    = $estado
        }
    }

    if (@($resumen).Count -gt 0) {
        $resumen | Export-Csv -Path $logPath -NoTypeInformation -Encoding UTF8
        Write-Host "Log completo: $logPath" -ForegroundColor Gray
    }
} catch {
    Write-LabWarn "No se pudo guardar el log en $logPath : $($_.Exception.Message)"
}

Write-Host ''
Write-LabOk 'Limpieza completada.'