<#
.SYNOPSIS
    Limpieza de entornos de laboratorio en Entra ID.
.DESCRIPTION
    Lee el manifiesto generado por los scripts de creación y revierte
    todos los objetos creados y las vulnerabilidades aplicadas.

    Orden de borrado (gestionado por Invoke-LabReversion):
      1. Vulnerabilidades aplicadas (owners, credenciales, roles PIM).
         - Verifica objectId del objeto afectado.
         - Llama a PreRevertir de la capacidad si existe.
      2. Objetos en orden inverso de creación (LIFO).
      3. Cada objeto/vulnerabilidad se revierte llamando a la capacidad
         que lo creó/aplicó.

    SEGURIDAD:
    - Antes de borrar cada objeto, se verifica que el objectId del
      manifiesto coincide con el actual. Si no coincide (objeto borrado
      y recreado externamente), se omite y se avisa.
    - Los objetos con estado 'preexistente' se ignoran. Eran anteriores
      al laboratorio y no se tocan.
    - Si una capacidad no está registrada (carpeta desactivada), el
      objeto/vulnerabilidad se deja en el manifiesto con estado
      'no-revertido'/'no-revertida' y se avisa.

    SOFT-DELETE:
    Remove-MgUser, Remove-MgGroup, Remove-MgApplication y
    Remove-MgServicePrincipal hacen soft-delete. Los objetos se pueden
    restaurar durante 30 dias desde el portal de Entra ID o con
    Restore-MgDirectoryDeletedItem.
    Nota: restaurar una aplicacion no restaura automaticamente su
    service principal; hay que restaurarlos por separado.

    La sesion de Graph la gestiona menu.ps1. Este script NO conecta ni
    desconecta; solo verifica que hay sesion activa.
.PARAMETER ManifiestoPath
    Ruta del manifiesto a procesar. Si se omite, se usa el estandar.
.PARAMETER Forzar
    Si se especifica, para objetos cuya capacidad no esta registrada,
    intenta un borrado generico por tipo. No se recomienda: puede borrar
    objetos que no son del laboratorio si el objectId no coincide.
.NOTES
    Depende de lib_ui.ps1, lib_graph.ps1, lib_config.ps1,
    lib_manifiesto.ps1, lib_escenarios.ps1, lib_niveles.ps1,
    lib_caps.ps1, lib_creadores.ps1.
#>
#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ManifiestoPath = $null,

    [Parameter(Mandatory = $false)]
    [switch]$Forzar
)

Set-StrictMode -Version Latest
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
# VERIFICACIÓN DE SESIÓN
# ============================================================
if (-not (Test-LabGraphSession)) {
    Write-LabError 'No hay sesión de Graph activa. Ejecuta este script desde menu.ps1.'
    exit 1
}

# ============================================================
# CONFIGURACIÓN Y CAPACIDADES
# ============================================================
$config = Get-LabConfig
$null = Initialize-LabCapacidades -Root (Join-Path $PSScriptRoot 'lib_caps')

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

# ============================================================
# RESUMEN Y CONFIRMACIÓN
# ============================================================
$pendientes = Get-LabManifiestoPendientes -Manifiesto $manifiesto

Write-Host ''
Write-Host '--- Contenido del manifiesto ---' -ForegroundColor Yellow
Write-Host "  Versión           : $($manifiesto.manifestVersion)"
Write-Host "  Fecha             : $($manifiesto.fecha)"
Write-Host "  Tenant            : $($manifiesto.tenantDomain)"
Write-Host "  Nivel             : $($manifiesto.nivel)"
Write-Host "  Escenario         : $($manifiesto.escenario)"
Write-Host "  Objetos totales   : $($manifiesto.objetos.Count)"
Write-Host "  Vulnerabilidades  : $($manifiesto.vulnerabilidades.Count)"
Write-Host ''
Write-Host "  Objetos pendientes        : $($pendientes.objetos.Count)" -ForegroundColor Yellow
Write-Host "  Vulnerabilidades pendientes: $($pendientes.vulnerabilidades.Count)" -ForegroundColor Yellow
Write-Host ''

# Desglose por capacidad (objetos)
$objetosPorCapacidad = @{}
foreach ($o in $pendientes.objetos) {
    $cap = if ($o.capacidad) { $o.capacidad } else { 'Desconocida' }
    if (-not $objetosPorCapacidad.ContainsKey($cap)) { $objetosPorCapacidad[$cap] = 0 }
    $objetosPorCapacidad[$cap]++
}
if ($objetosPorCapacidad.Count -gt 0) {
    Write-Host '  Objetos pendientes por capacidad:' -ForegroundColor Cyan
    foreach ($cap in ($objetosPorCapacidad.Keys | Sort-Object)) {
        Write-Host "    $cap : $($objetosPorCapacidad[$cap])"
    }
    Write-Host ''
}

# Desglose por capacidad (vulnerabilidades)
$vulnsPorCapacidad = @{}
foreach ($v in $pendientes.vulnerabilidades) {
    $cap = if ($v.capacidad) { $v.capacidad } else { 'Desconocida' }
    if (-not $vulnsPorCapacidad.ContainsKey($cap)) { $vulnsPorCapacidad[$cap] = 0 }
    $vulnsPorCapacidad[$cap]++
}
if ($vulnsPorCapacidad.Count -gt 0) {
    Write-Host '  Vulnerabilidades pendientes por capacidad:' -ForegroundColor Cyan
    foreach ($cap in ($vulnsPorCapacidad.Keys | Sort-Object)) {
        Write-Host "    $cap : $($vulnsPorCapacidad[$cap])"
    }
    Write-Host ''
}

if ($pendientes.objetos.Count -eq 0 -and $pendientes.vulnerabilidades.Count -eq 0) {
    Write-LabOk 'No hay objetos ni vulnerabilidades pendientes de revertir en el manifiesto.'
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
# RENOMBRAR SI TODO SE REVIRTIÓ
# ============================================================
$quedanPendientes = Get-LabManifiestoPendientes -Manifiesto $manifiesto
if ($quedanPendientes.objetos.Count -eq 0 -and $quedanPendientes.vulnerabilidades.Count -eq 0) {
    $manifiestoProcesado = Rename-LabManifiestoProcesado
    if ($manifiestoProcesado) {
        Write-LabOk "Manifiesto renombrado como procesado: $manifiestoProcesado"
    }
} else {
    Write-LabWarn "Quedan $($quedanPendientes.objetos.Count) objetos y $($quedanPendientes.vulnerabilidades.Count) vulnerabilidades pendientes. El manifiesto se conserva para reintentar."
    Write-LabInfo 'Revisa los avisos anteriores y vuelve a ejecutar la limpieza.'
}

# ============================================================
# VOLCADO DEL LOG
# ============================================================
$logPath = Join-Path $PSScriptRoot "log_cleanup_$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"

try {
    $resumen = @()

    # Objetos
    foreach ($o in $manifiesto.objetos) {
        $resumen += [pscustomobject]@{
            clase     = 'Objeto'
            id        = $o.id
            nombre    = ''
            tipo      = $o.tipo
            capacidad = $o.capacidad
            estado    = $o.estado
        }
    }

    # Vulnerabilidades
    foreach ($v in $manifiesto.vulnerabilidades) {
        $resumen += [pscustomobject]@{
            clase     = 'Vulnerabilidad'
            id        = $v.id
            nombre    = if ($v.nombre) { $v.nombre } else { '' }
            tipo      = $v.tipo
            capacidad = $v.capacidad
            estado    = $v.estado
        }
    }

    if ($resumen.Count -gt 0) {
        $resumen | Export-Csv -Path $logPath -NoTypeInformation -Encoding UTF8
        Write-Host "Log completo: $logPath" -ForegroundColor Gray
    }
} catch {
    Write-LabWarn "No se pudo guardar el log en $logPath : $($_.Exception.Message)"
}

Write-Host ''
Write-LabOk 'Limpieza completada.'