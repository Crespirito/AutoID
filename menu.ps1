<#
.SYNOPSIS
    Menú orquestador para entornos de laboratorio en Entra ID (Free).
.DESCRIPTION
    Gestiona la sesión de Microsoft Graph (persistente hasta salir con 0),
    la configuración y el manifiesto, y delega la creación/limpieza en
    los scripts hijos:
      - creacion_automatica.ps1
      - creacion_personalizada.ps1
      - clean_up.ps1
.NOTES
    Requiere que estén presentes en la misma carpeta:
      lib_ui.ps1, lib_graph.ps1, lib_config.ps1, lib_manifiesto.ps1
#>
#Requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================
# VALIDACIÓN DE CONTEXTO
# ============================================================
if (-not $PSScriptRoot) {
    throw "Ejecuta este script como archivo .ps1, no pegado en consola."
}

# ============================================================
# CARGA DE LIBRERÍAS
# ============================================================
. (Join-Path $PSScriptRoot "lib_ui.ps1")
. (Join-Path $PSScriptRoot "lib_graph.ps1")
. (Join-Path $PSScriptRoot "lib_config.ps1")
. (Join-Path $PSScriptRoot "lib_manifiesto.ps1")

# ============================================================
# RUTAS A LOS SCRIPTS HIJOS
# ============================================================
$ScriptAuto    = Join-Path $PSScriptRoot "creacion_automatica.ps1"
$ScriptManual  = Join-Path $PSScriptRoot "creacion_personalizada.ps1"
$ScriptCleanup = Join-Path $PSScriptRoot "clean_up.ps1"

# ============================================================
# ESTADO DEL MENÚ
# ============================================================
# Se usa $script:config para que las funciones que modifican la
# configuración (Invoke-ToggleVerbose, Invoke-ResetConfig) alteren
# la MISMA variable y los cambios persistan durante la sesión.
$script:config = Get-LabConfig

# ============================================================
# FUNCIONES AUXILIARES
# ============================================================

function Invoke-EnsureSession {
    # Garantiza sesión antes de una operación. Si expiró, intenta reconectar.
    if (Test-LabGraphSession) { return $true }
    Write-LabWarn "No hay sesión de Graph activa. Conectando..."
    return (Connect-LabGraph)
}

function Test-ScriptHijo {
    param([string]$Path, [string]$Nombre)
    if (-not (Test-Path $Path)) {
        Write-LabError "No se encuentra el script '$Nombre' en: $Path"
        return $false
    }
    return $true
}

function Invoke-ScriptHijo {
    param(
        [string]$Path,
        [hashtable]$Argumentos
    )

    Write-Host ""
    Write-Host "Ejecutando: $(Split-Path $Path -Leaf)" -ForegroundColor Green
    Write-Host "------------------------------------------------------------" -ForegroundColor Gray

    # Resetear $LASTEXITCODE antes de la llamada: si el script hijo no
    # hace `exit`, $LASTEXITCODE conservaría un valor de una ejecución
    # nativa anterior y produciría falsos positivos/negativos.
    $exitCode = 0
    $global:LASTEXITCODE = 0
    try {
        & $Path @Argumentos
        if ($null -ne $LASTEXITCODE) { $exitCode = $LASTEXITCODE }
    } catch {
        Write-LabError "Fallo durante la ejecución: $($_.Exception.Message)"
        $exitCode = 1
    }

    if ($exitCode -ne 0) {
        Write-LabWarn "El script finalizó con código $exitCode."
    }

    Write-Host "------------------------------------------------------------" -ForegroundColor Gray
}

# ============================================================
# ACCIONES DEL MENÚ
# ============================================================

function Invoke-GestionSesion {
    Show-LabHeader -Titulo "GESTION DE SESION DE GRAPH"
    $status = Get-LabGraphStatus

    if ($status) {
        Write-LabOk "Sesión activa."
        Write-Host "  Usuario : $($status.Account)"
        Write-Host "  Tenant  : $($status.TenantId)"
        Write-Host "  Scopes  : $($status.Scopes)"
        Write-Host ""
        $resp = Read-Host "¿Quieres reconectar (cerrar y abrir sesión)? (SI/N)"
        if ($resp -eq "SI") {
            Disconnect-LabGraph
            $null = Connect-LabGraph
        }
    } else {
        Write-LabWarn "No hay sesión activa."
        $null = Connect-LabGraph
    }
    Wait-LabKey
}

function Invoke-CrearAutomatica {
    if (-not (Test-ScriptHijo -Path $ScriptAuto -Nombre "creacion_automatica.ps1")) {
        Wait-LabKey; return
    }
    if (-not (Invoke-EnsureSession)) { Wait-LabKey; return }

    if (Test-LabManifiestoExists) {
        Write-LabWarn "Ya existe un manifiesto pendiente. Se sobrescribirá si creas un nuevo entorno."
        $resp = Read-Host "Escribe 'SI' para continuar"
        if ($resp -ne "SI") {
            Write-LabInfo "Operación cancelada."
            Start-Sleep -Seconds 1
            return
        }
    }

    $argumentos = @{}
    if ($script:config.Verbose) { $argumentos["Verbose"] = $true }

    Invoke-ScriptHijo -Path $ScriptAuto -Argumentos $argumentos
    Wait-LabKey
}

function Invoke-CrearPersonalizada {
    if (-not (Test-ScriptHijo -Path $ScriptManual -Nombre "creacion_personalizada.ps1")) {
        Wait-LabKey; return
    }
    if (-not (Invoke-EnsureSession)) { Wait-LabKey; return }

    if (Test-LabManifiestoExists) {
        Write-LabWarn "Ya existe un manifiesto pendiente. Se sobrescribirá si creas un nuevo entorno."
        $resp = Read-Host "Escribe 'SI' para continuar"
        if ($resp -ne "SI") {
            Write-LabInfo "Operación cancelada."
            Start-Sleep -Seconds 1
            return
        }
    }

    $argumentos = @{}
    if ($script:config.Verbose) { $argumentos["Verbose"] = $true }

    Invoke-ScriptHijo -Path $ScriptManual -Argumentos $argumentos
    Wait-LabKey
}

function Invoke-Limpiar {
    if (-not (Test-ScriptHijo -Path $ScriptCleanup -Nombre "clean_up.ps1")) {
        Wait-LabKey; return
    }
    if (-not (Invoke-EnsureSession)) { Wait-LabKey; return }

    if (-not (Test-LabManifiestoExists)) {
        Write-LabWarn "No hay manifiesto pendiente. Nada que limpiar."
        Wait-LabKey; return
    }

    $argumentos = @{ ManifiestoPath = (Get-LabManifiestoPath) }
    if ($script:config.Verbose) { $argumentos["Verbose"] = $true }

    Invoke-ScriptHijo -Path $ScriptCleanup -Argumentos $argumentos
    Wait-LabKey
}

function Invoke-VerManifiesto {
    Show-LabHeader -Titulo "MANIFIESTO"

    if (-not (Test-LabManifiestoExists)) {
        Write-LabWarn "No hay manifiesto pendiente."
        Wait-LabKey; return
    }

    try {
        $m = Get-LabManifiesto

        Write-Host "Fecha             : $($m.Fecha)"
        Write-Host "Tenant ID         : $($m.TenantId)"
        Write-Host "Tenant Domain     : $($m.TenantDomain)"
        Write-Host ""

        Write-Host "Usuarios ($($m.Usuarios.Count)):" -ForegroundColor Cyan
        if ($m.Usuarios.Count -gt 0) {
            $m.Usuarios | ForEach-Object { Write-Host "  - $_" }
        } else {
            Write-Host "  (ninguno)" -ForegroundColor DarkGray
        }
        Write-Host ""

        Write-Host "Grupos ($($m.Grupos.Count)):" -ForegroundColor Cyan
        if ($m.Grupos.Count -gt 0) {
            $m.Grupos | ForEach-Object { Write-Host "  - $_" }
        } else {
            Write-Host "  (ninguno)" -ForegroundColor DarkGray
        }
        Write-Host ""

        Write-Host "Aplicaciones ($($m.Aplicaciones.Count)):" -ForegroundColor Cyan
        if ($m.Aplicaciones.Count -gt 0) {
            $m.Aplicaciones | ForEach-Object { Write-Host "  - $_" }
        } else {
            Write-Host "  (ninguna)" -ForegroundColor DarkGray
        }
        Write-Host ""

        Write-Host "Service Principals ($($m.ServicePrincipals.Count)):" -ForegroundColor Cyan
        if ($m.ServicePrincipals.Count -gt 0) {
            $m.ServicePrincipals | ForEach-Object { Write-Host "  - $_" }
        } else {
            Write-Host "  (ninguno)" -ForegroundColor DarkGray
        }
    } catch {
        Write-LabError "No se pudo leer el manifiesto: $($_.Exception.Message)"
    }

    Wait-LabKey
}

function Invoke-ToggleVerbose {
    $script:config.Verbose = -not $script:config.Verbose
    $null = Save-LabConfig -Config $script:config
    Write-LabOk "Modo Verbose: $($script:config.Verbose)"
    Start-Sleep -Seconds 1
}

function Invoke-ResetConfig {
    $script:config = Reset-LabConfig
    Write-LabOk "Configuración reseteada a valores por defecto."
    Start-Sleep -Seconds 1
}

function Invoke-InfoLicencia {
    Show-LabHeader -Titulo "INFORMACION - TENANT FREE"

    Write-Host "Esta versión está adaptada a tenants Microsoft Entra ID Free." -ForegroundColor White
    Write-Host ""

    Write-Host "Disponible en Free:" -ForegroundColor Green
    Write-Host "  - Creación de usuarios"
    Write-Host "  - Creación de grupos de seguridad"
    Write-Host "  - Creación de aplicaciones y service principals"
    Write-Host "  - Asignación de miembros a grupos"
    Write-Host "  - Asignación de propietarios a service principals"
    Write-Host "  - Añadir credenciales a aplicaciones"
    Write-Host ""

    Write-Host "NO disponible en Free (requiere P1/P2):" -ForegroundColor Red
    Write-Host "  - Asignación de roles de directorio"
    Write-Host "  - Grupos con asignación de roles"
    Write-Host "  - Grupos dinámicos"
    Write-Host "  - Acceso condicional avanzado"
    Write-Host "  - Gestión de PIM"

    Wait-LabKey
}

# ============================================================
# PANTALLAS DE ESTADO
# ============================================================

function Show-EstadoSesion {
    Write-Host "--- Sesion Graph ---" -ForegroundColor Yellow
    $s = Get-LabGraphStatus
    if ($s) {
        Write-Host "  Conectado : $($s.Account)" -ForegroundColor Green
        Write-Host "  Tenant    : $($s.TenantId)"
    } else {
        Write-Host "  Sin sesion activa" -ForegroundColor Red
    }
    Write-Host ""
}

function Show-EstadoConfig {
    Write-Host "--- Configuracion ---" -ForegroundColor Yellow
    Write-Host "  Verbose   : $($script:config.Verbose)"
    Write-Host ""
}

function Show-EstadoManifiesto {
    Write-Host "--- Manifiesto ---" -ForegroundColor Yellow
    $m = Get-LabManifiestoStatus
    if ($null -eq $m) {
        Write-Host "  Sin manifiesto pendiente" -ForegroundColor DarkGray
    } elseif ($m -eq "ilegible") {
        Write-Host "  Manifiesto presente pero ilegible" -ForegroundColor Red
    } else {
        Write-Host "  Fecha     : $($m.Fecha)"
        Write-Host "  Tenant    : $($m.Tenant)"
        Write-Host "  Usuarios  : $($m.Usuarios) | Grupos: $($m.Grupos) | Apps: $($m.Apps)"
    }
    Write-Host ""
}

# ============================================================
# ARRANQUE: CONEXIÓN INICIAL A GRAPH
# ============================================================
Show-LabHeader -Titulo "GESTOR DE ENTORNOS DE LABORATORIO - ENTRA ID (FREE)"

Write-LabInfo "Iniciando sesión de Microsoft Graph..."
if (-not (Connect-LabGraph)) {
    Write-LabError "No se pudo establecer la sesión inicial."
    Write-LabWarn "El menú arrancará sin sesión. Usa la opción [C] para conectar manualmente."
    Wait-LabKey
}

# ============================================================
# BUCLE PRINCIPAL
# ============================================================
while ($true) {
    Show-LabHeader
    Show-EstadoSesion
    Show-EstadoConfig
    Show-EstadoManifiesto

    Write-Host "--- Creacion ---" -ForegroundColor Cyan
    Write-Host "  [1] Creacion automatica"
    Write-Host "  [2] Creacion personalizada"
    Write-Host ""
    Write-Host "--- Limpieza ---" -ForegroundColor Cyan
    Write-Host "  [3] Limpiar entorno"
    Write-Host ""
    Write-Host "--- Manifiesto ---" -ForegroundColor Cyan
    Write-Host "  [4] Ver manifiesto"
    Write-Host ""
    Write-Host "--- Sesion / Configuracion ---" -ForegroundColor Cyan
    Write-Host "  [C] Gestionar sesion de Graph"
    Write-Host "  [V] Alternar Verbose"
    Write-Host "  [R] Resetear configuracion"
    Write-Host "  [I] Info sobre tenant Free"
    Write-Host ""
    Write-Host "  [0] Salir"
    Write-Host ""

    $opcion = Read-Host "Selecciona una opcion"
    # Normalizar: Read-Host puede devolver $null en algunos hosts y
    # .ToUpper() lanzaría NullReferenceException con StrictMode.
    $opcion = if ($null -eq $opcion) { "" } else { $opcion.Trim() }

    switch ($opcion.ToUpper()) {
        "1" { Invoke-CrearAutomatica }
        "2" { Invoke-CrearPersonalizada }
        "3" { Invoke-Limpiar }
        "4" { Invoke-VerManifiesto }
        "C" { Invoke-GestionSesion }
        "V" { Invoke-ToggleVerbose }
        "R" { Invoke-ResetConfig }
        "I" { Invoke-InfoLicencia }
        "0" {
            $null = Save-LabConfig -Config $script:config
            Disconnect-LabGraph
            Write-Host ""
            Write-LabOk "Sesión cerrada. Saliendo..."
            exit 0
        }
        default {
            Write-LabError "Opcion no valida."
            Start-Sleep -Seconds 1
        }
    }
}