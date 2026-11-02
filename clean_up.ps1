<#
.SYNOPSIS
    Limpieza de entornos de laboratorio en Entra ID.
.DESCRIPTION
    Lee el manifiesto JSON generado por los scripts de creación y elimina
    todos los objetos creados. El orden es:
      1. Revertir vulnerabilidades aplicadas (owners, credenciales, PIM, etc.)
      2. Eliminar aplicaciones y service principals
      3. Eliminar grupos (vaciando miembros y owners)
      4. Eliminar usuarios
    Este orden rompe dependencias y evita errores de "objeto en uso".

    La sesión de Microsoft Graph la gestiona menu.ps1. Este script NO
    conecta ni desconecta; solo verifica que hay sesión activa y falla
    con código 1 si no la hay.
.PARAMETER ManifiestoPath
    Ruta del manifiesto a procesar. Si se omite, se usa el manifiesto
    estándar en la carpeta del script.
.PARAMETER Forzar
    Si se especifica, no pide confirmación al usuario antes de eliminar.
.NOTES
    Depende de lib_ui.ps1 y lib_manifiesto.ps1.
#>
#Requires -Version 5.1

[CmdletBinding()]
param (
    [string]$ManifiestoPath = $null,
    [switch]$Forzar
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================
# CARGA DE LIBRERÍAS
# ============================================================
. (Join-Path $PSScriptRoot "lib_ui.ps1")
. (Join-Path $PSScriptRoot "lib_manifiesto.ps1")

# ============================================================
# VERIFICACIÓN DE SESIÓN (gestionada por el menú)
# ============================================================
if (-not (Get-MgContext -ErrorAction SilentlyContinue)) {
    Write-LabError "No hay sesión de Graph activa. Ejecuta este script desde menu.ps1."
    exit 1
}

# Resolver ruta del manifiesto
if (-not $ManifiestoPath) {
    $ManifiestoPath = Get-LabManifiestoPath
}

# ============================================================
# FASE 0: SISTEMA DE LOG
# ============================================================
$log = [System.Collections.Generic.List[object]]::new()

function Add-LogEntry {
    param(
        [string]$Categoria,   # "Info", "Warning", "Error"
        [string]$Mensaje,
        [object]$Detalle
    )
    $log.Add([pscustomobject]@{
        Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Categoria = $Categoria
        Mensaje   = $Mensaje
        Detalle   = $Detalle
    })
    switch ($Categoria) {
        "Error"   { Write-LabError $Mensaje }
        "Warning" { Write-LabWarn  $Mensaje }
        default   { Write-LabInfo  $Mensaje }
    }
}

# ============================================================
# FASE 1: LECTURA DEL MANIFIESTO
# ============================================================
Write-LabBanner "Iniciando limpieza del laboratorio"

if (-not (Test-Path $ManifiestoPath)) {
    Add-LogEntry -Categoria "Error" -Mensaje "No se encuentra el manifiesto." -Detalle $ManifiestoPath
    Write-Host "Asegúrate de que el script de creación se ejecutó correctamente." -ForegroundColor Gray
    exit 1
}

try {
    $manifiesto = Get-LabManifiesto -Path $ManifiestoPath
    if ($null -eq $manifiesto) {
        Add-LogEntry -Categoria "Error" -Mensaje "El manifiesto está vacío o es nulo." -Detalle $ManifiestoPath
        exit 1
    }
    Add-LogEntry -Categoria "Info" -Mensaje "Manifiesto cargado correctamente." -Detalle @{
        Fecha    = $manifiesto.Fecha
        Tenant   = $manifiesto.TenantDomain
        Usuarios = $manifiesto.Usuarios.Count
        Grupos   = $manifiesto.Grupos.Count
        Apps     = $manifiesto.Aplicaciones.Count
        SPs      = $manifiesto.ServicePrincipals.Count
    }
} catch {
    Add-LogEntry -Categoria "Error" -Mensaje "Error al leer el manifiesto." -Detalle $_.Exception.Message
    exit 1
}

# ============================================================
# FASE 2: RESUMEN Y CONFIRMACIÓN
# ============================================================
# Get-LabManifiesto normaliza Vulnerabilidades a array siempre.
$vulns = $manifiesto.Vulnerabilidades

Write-Host ""
Write-Host "--- Contenido del manifiesto ---" -ForegroundColor Yellow
Write-Host "  Fecha del manifiesto : $($manifiesto.Fecha)"
Write-Host "  Tenant               : $($manifiesto.TenantDomain)"
Write-Host "  Usuarios             : $($manifiesto.Usuarios.Count)"
Write-Host "  Grupos               : $($manifiesto.Grupos.Count)"
Write-Host "  Aplicaciones         : $($manifiesto.Aplicaciones.Count)"
Write-Host "  Service Principals   : $($manifiesto.ServicePrincipals.Count)"
Write-Host "  Vulnerabilidades     : $($vulns.Count)"
Write-Host ""

if (-not $Forzar) {
    Write-Host "¿Estás seguro de que quieres ELIMINAR todos estos objetos?" -ForegroundColor Yellow
    $confirmacion = Read-Host "Escribe 'SI' para confirmar"
    if ($confirmacion -ne "SI") {
        Write-LabInfo "Operación cancelada por el usuario."
        exit 0
    }
}

# ============================================================
# FASE 3: REVERSIÓN DE VULNERABILIDADES
# ============================================================
# Se revierten ANTES de borrar objetos, para que las relaciones
# (owners, credenciales, PIM) desaparezcan limpiamente.
if ($vulns.Count -gt 0) {
    Write-LabBanner "Revirtiendo vulnerabilidades aplicadas"

    foreach ($v in $vulns) {
        try {
            $tipo = $v.tipo
            $afectados = @($v.objetosAfectados)

            Write-Host "  Revirtiendo: $($v.nombre) ($tipo)" -ForegroundColor Gray

            switch ($tipo) {
                "ServicePrincipalOwner" {
                    foreach ($o in $afectados) {
                        try {
                            Remove-MgServicePrincipalOwnerByRef -ServicePrincipalId $o.servicePrincipalId -DirectoryObjectId $o.directoryObjectId -Confirm:$false -ErrorAction Stop
                            Add-LogEntry -Categoria "Info" -Mensaje "Owner de SP revertido." -Detalle $o
                        } catch {
                            Add-LogEntry -Categoria "Warning" -Mensaje "No se pudo revertir owner de SP." -Detalle @{ Objeto = $o; Error = $_.Exception.Message }
                        }
                    }
                }
                "GroupOwner" {
                    foreach ($o in $afectados) {
                        try {
                            Remove-MgGroupOwnerByRef -GroupId $o.groupId -DirectoryObjectId $o.directoryObjectId -Confirm:$false -ErrorAction Stop
                            Add-LogEntry -Categoria "Info" -Mensaje "Owner de grupo revertido." -Detalle $o
                        } catch {
                            Add-LogEntry -Categoria "Warning" -Mensaje "No se pudo revertir owner de grupo." -Detalle @{ Objeto = $o; Error = $_.Exception.Message }
                        }
                    }
                }
                "ApplicationSecret" {
                    foreach ($o in $afectados) {
                        try {
                            Remove-MgApplicationPassword -ApplicationId $o.applicationId -KeyId $o.keyId -Confirm:$false -ErrorAction Stop
                            Add-LogEntry -Categoria "Info" -Mensaje "Credencial de app revertida." -Detalle $o
                        } catch {
                            Add-LogEntry -Categoria "Warning" -Mensaje "No se pudo revertir credencial de app." -Detalle @{ Objeto = $o; Error = $_.Exception.Message }
                        }
                    }
                }
                "PimEligibleRole" {
                    foreach ($o in $afectados) {
                        # La reversión de PIM requiere buscar las schedules del
                        # principal y cancelarlas una a una. Remove-... solo
                        # acepta el ID de la schedule (no BodyParameter).
                        try {
                            $schedules = Get-MgRoleManagementDirectoryRoleEligibilitySchedule `
                                -Filter "principalId eq '$($o.principalId)'" -All -ErrorAction Stop
                            foreach ($s in $schedules) {
                                Remove-MgRoleManagementDirectoryRoleEligibilityScheduleRequest `
                                    -UnifiedRoleEligibilityScheduleRequestId $s.Id `
                                    -Confirm:$false -ErrorAction Stop
                            }
                            Add-LogEntry -Categoria "Info" -Mensaje "Rol PIM revertido." -Detalle $o
                        } catch {
                            Add-LogEntry -Categoria "Warning" -Mensaje "No se pudo revertir rol PIM." -Detalle @{ Objeto = $o; Error = $_.Exception.Message }
                        }
                    }
                }
                default {
                    Add-LogEntry -Categoria "Warning" -Mensaje "Tipo de vulnerabilidad desconocido; se omite reversión." -Detalle $tipo
                }
            }
        } catch {
            Add-LogEntry -Categoria "Error" -Mensaje "Error al revertir vulnerabilidad." -Detalle @{
                Vulnerabilidad = $v.nombre
                Error          = $_.Exception.Message
            }
        }
    }
} else {
    Write-LabInfo "No hay vulnerabilidades registradas en el manifiesto."
}

# ============================================================
# FASE 4: ELIMINACIÓN DE APLICACIONES Y SERVICE PRINCIPALS
# ============================================================
Write-LabBanner "Eliminando aplicaciones y service principals"

foreach ($nombreApp in $manifiesto.Aplicaciones) {
    try {
        $app = Get-MgApplication -Filter "displayName eq '$nombreApp'" -ErrorAction Stop

        if ($app) {
            if ($app -is [array]) { $app = $app[0] }

            Write-Host "  Procesando aplicación: $nombreApp" -ForegroundColor Gray

            # 1. Eliminar SP asociado
            $sp = Get-MgServicePrincipal -Filter "appId eq '$($app.AppId)'" -ErrorAction SilentlyContinue
            if ($sp) {
                if ($sp -is [array]) { $sp = $sp[0] }

                $asignaciones = Get-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $sp.Id -All -ErrorAction SilentlyContinue
                foreach ($asig in $asignaciones) {
                    Remove-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $sp.Id -AppRoleAssignmentId $asig.Id -Confirm:$false -ErrorAction SilentlyContinue
                }

                Remove-MgServicePrincipal -ServicePrincipalId $sp.Id -Confirm:$false -ErrorAction Stop
                Add-LogEntry -Categoria "Info" -Mensaje "Service Principal eliminado." -Detalle $sp.Id
            }

            # 2. Eliminar la aplicación
            Remove-MgApplication -ApplicationId $app.Id -Confirm:$false -ErrorAction Stop
            Add-LogEntry -Categoria "Info" -Mensaje "Aplicación eliminada." -Detalle $nombreApp
        } else {
            Add-LogEntry -Categoria "Warning" -Mensaje "Aplicación no encontrada." -Detalle $nombreApp
        }
    } catch {
        Add-LogEntry -Categoria "Error" -Mensaje "Error al eliminar aplicación." -Detalle @{
            App   = $nombreApp
            Error = $_.Exception.Message
        }
    }
}

# SPs huérfanos registrados directamente en el manifiesto
foreach ($spId in $manifiesto.ServicePrincipals) {
    try {
        $sp = Get-MgServicePrincipal -ServicePrincipalId $spId -ErrorAction SilentlyContinue
        if ($sp) {
            if ($sp -is [array]) { $sp = $sp[0] }
            $asignaciones = Get-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $spId -All -ErrorAction SilentlyContinue
            foreach ($asig in $asignaciones) {
                Remove-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $spId -AppRoleAssignmentId $asig.Id -Confirm:$false -ErrorAction SilentlyContinue
            }
            Remove-MgServicePrincipal -ServicePrincipalId $spId -Confirm:$false -ErrorAction Stop
            Add-LogEntry -Categoria "Info" -Mensaje "Service Principal huérfano eliminado." -Detalle $spId
        }
    } catch {
        Add-LogEntry -Categoria "Warning" -Mensaje "No se pudo eliminar SP huérfano." -Detalle @{
            SP    = $spId
            Error = $_.Exception.Message
        }
    }
}

# ============================================================
# FASE 5: ELIMINACIÓN DE GRUPOS
# ============================================================
Write-LabBanner "Eliminando grupos"

foreach ($nombreGrupo in $manifiesto.Grupos) {
    try {
        $grupo = Get-MgGroup -Filter "displayName eq '$nombreGrupo'" -ErrorAction Stop
        if ($grupo -is [array]) { $grupo = $grupo[0] }

        if ($grupo) {
            Write-Host "  Procesando grupo: $nombreGrupo" -ForegroundColor Gray

            # Vaciar miembros
            $miembros = Get-MgGroupMember -GroupId $grupo.Id -All -ErrorAction SilentlyContinue
            foreach ($miembro in $miembros) {
                Remove-MgGroupMemberByRef -GroupId $grupo.Id -DirectoryObjectId $miembro.Id -Confirm:$false -ErrorAction SilentlyContinue
            }

            # Eliminar propietarios
            $propietarios = Get-MgGroupOwner -GroupId $grupo.Id -All -ErrorAction SilentlyContinue
            foreach ($prop in $propietarios) {
                Remove-MgGroupOwnerByRef -GroupId $grupo.Id -DirectoryObjectId $prop.Id -Confirm:$false -ErrorAction SilentlyContinue
            }

            # Eliminar grupo
            Remove-MgGroup -GroupId $grupo.Id -Confirm:$false -ErrorAction Stop
            Add-LogEntry -Categoria "Info" -Mensaje "Grupo eliminado." -Detalle $nombreGrupo
        } else {
            Add-LogEntry -Categoria "Warning" -Mensaje "Grupo no encontrado." -Detalle $nombreGrupo
        }
    } catch {
        Add-LogEntry -Categoria "Error" -Mensaje "Error al eliminar grupo." -Detalle @{
            Grupo = $nombreGrupo
            Error = $_.Exception.Message
        }
    }
}

# ============================================================
# FASE 6: ELIMINACIÓN DE USUARIOS
# ============================================================
Write-LabBanner "Eliminando usuarios"

foreach ($upn in $manifiesto.Usuarios) {
    try {
        $usuario = Get-MgUser -UserId $upn -ErrorAction SilentlyContinue
        if ($usuario) {
            if ($usuario -is [array]) { $usuario = $usuario[0] }
            Remove-MgUser -UserId $upn -Confirm:$false -ErrorAction Stop
            Add-LogEntry -Categoria "Info" -Mensaje "Usuario eliminado." -Detalle $upn
        } else {
            Add-LogEntry -Categoria "Warning" -Mensaje "Usuario no encontrado." -Detalle $upn
        }
    } catch {
        Add-LogEntry -Categoria "Error" -Mensaje "Error al eliminar usuario." -Detalle @{
            Usuario = $upn
            Error   = $_.Exception.Message
        }
    }
}

# ============================================================
# FASE 7: RENOMBRAR EL MANIFIESTO COMO PROCESADO
# ============================================================
# Solo se renombra el manifiesto estándar. Si el usuario pasó -ManifiestoPath
# con una ruta alternativa, se respeta y no se toca.
$esEstandar = ($ManifiestoPath -eq (Get-LabManifiestoPath))
if ($esEstandar) {
    try {
        $manifiestoProcesado = Rename-LabManifiestoProcesado
        if ($manifiestoProcesado) {
            Add-LogEntry -Categoria "Info" -Mensaje "Manifiesto renombrado como procesado." -Detalle $manifiestoProcesado
        } else {
            Add-LogEntry -Categoria "Warning" -Mensaje "No se pudo renombrar el manifiesto estándar."
        }
    } catch {
        Add-LogEntry -Categoria "Warning" -Mensaje "No se pudo renombrar el manifiesto." -Detalle $_.Exception.Message
    }
} else {
    Add-LogEntry -Categoria "Info" -Mensaje "Manifiesto alternativo: no se renombra." -Detalle $ManifiestoPath
}

# ============================================================
# FASE 8: VOLCADO DEL LOG Y RESUMEN
# ============================================================
$logPath = Join-Path $PSScriptRoot "log_cleanup_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"

try {
    $log | Export-Csv -Path $logPath -NoTypeInformation -Encoding UTF8
} catch {
    Write-LabError "No se pudo guardar el log en $logPath : $($_.Exception.Message)"
}

$errores = ($log | Where-Object Categoria -eq "Error").Count
$avisos  = ($log | Where-Object Categoria -eq "Warning").Count
$total   = $log.Count

Write-Host ""
Write-Host "--- Resumen de limpieza ---" -ForegroundColor Cyan
Write-Host "Eventos totales: $total"
Write-Host "Avisos:          $avisos" -ForegroundColor Yellow
Write-Host "Errores:         $errores" -ForegroundColor Red
Write-Host "Log completo:    $logPath" -ForegroundColor Gray
Write-Host ""
Write-LabOk "Limpieza completada."

# Propagar el fallo al orquestador: menu.ps1 comprueba $LASTEXITCODE.
if ($errores -gt 0) {
    exit 1
}