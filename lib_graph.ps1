<#
.SYNOPSIS
    Librería de gestión de sesión de Microsoft Graph.
.DESCRIPTION
    Proporciona:
      - Instalación y carga selectiva de módulos Microsoft.Graph (rápido).
      - Catálogo de módulos disponibles para el laboratorio.
      - Conexión App-Only (certificado) o interactiva (fallback).
      - Verificación de sesión activa.
      - Estado de la sesión actual (cacheado para refrescos rápidos).
      - Desconexión limpia.
.NOTES
    Depende de lib_ui.ps1 y lib_config.ps1.
    Se carga por dot-sourcing desde menu.ps1.
    Guardar este fichero como UTF-8 con BOM para compatibilidad con PS 5.1.
#>
#Requires -Version 5.1

# ============================================================
# SCOPES REQUERIDOS (para el modo interactivo, si se usa)
# ============================================================
$script:LabGraphScopes = @(
    "User.ReadWrite.All",
    "Group.ReadWrite.All",
    "Application.ReadWrite.All",
    "AppRoleAssignment.ReadWrite.All",
    "Directory.Read.All"
)

# ============================================================
# CACHÉ DE ESTADO DE SESIÓN
# ============================================================
$script:LabGraphSessionCache = $null

# ============================================================
# GESTIÓN DE MÓDULOS
# ============================================================
$script:LabGraphCatalogo = [ordered]@{
    "Microsoft.Graph.Authentication"               = "Autenticación (Obligatorio)"
    "Microsoft.Graph.Users"                        = "Usuarios"
    "Microsoft.Graph.Groups"                       = "Grupos"
    "Microsoft.Graph.Applications"                 = "Aplicaciones y Service Principals"
    "Microsoft.Graph.Identity.DirectoryManagement" = "Directorio y Organización"
    "Microsoft.Graph.Devices.CorporateManagement"  = "Dispositivos (Intune)"
    "Microsoft.Graph.Identity.SignIns"             = "Políticas de Acceso Condicional (SignIns)"
    "Microsoft.Graph.Reports"                      = "Reportes de auditoría"
}

$script:LabGraphModulesMinimos = @(
    "Microsoft.Graph.Authentication",
    "Microsoft.Graph.Users",
    "Microsoft.Graph.Groups",
    "Microsoft.Graph.Applications",
    "Microsoft.Graph.Identity.DirectoryManagement"
)

$script:LabGraphModulesCargados = $false

# ============================================================
# FUNCIONES PÚBLICAS
# ============================================================

function Get-LabGraphScopes {
    return $script:LabGraphScopes
}

function Get-LabGraphModulosInfo {
    $resultado = @()
    foreach ($key in $script:LabGraphCatalogo.Keys) {
        $instalado = $null -ne (Get-Module -ListAvailable -Name $key -ErrorAction SilentlyContinue)
        $cargado   = $null -ne (Get-Module -Name $key -ErrorAction SilentlyContinue)
        
        $resultado += [pscustomobject]@{
            Nombre      = $key
            Descripcion = $script:LabGraphCatalogo[$key]
            Instalado   = $instalado
            Cargado     = $cargado
        }
    }
    return $resultado
}

function Install-LabGraphModules {
    param([string[]]$Modulos = $script:LabGraphModulesMinimos)

    if ($Modulos.Count -eq 0) { return $true }

    $faltan = $false
    foreach ($mod in $Modulos) {
        if (-not (Get-Module -ListAvailable -Name $mod -ErrorAction SilentlyContinue)) {
            $faltan = $true; break
        }
    }

    if (-not $faltan) { return $true }

    Write-LabWarn "Instalando módulos de Graph..."
    try {
        foreach ($mod in $Modulos) {
            if (-not (Get-Module -ListAvailable -Name $mod -ErrorAction SilentlyContinue)) {
                Write-Host "  Instalando $mod..." -ForegroundColor Gray
                Install-Module -Name $mod -Scope CurrentUser -Repository PSGallery -Force -Verbose -ErrorAction Stop
            }
        }
        Write-LabOk "Instalación finalizada."
        return $true
    } catch {
        Write-LabError "Error al instalar módulos: $($_.Exception.Message)"
        return $false
    }
}

function Import-LabGraphModules {
    param([string[]]$Modulos = $null)

    if ($null -eq $Modulos) {
        if ($script:LabGraphModulesCargados) { return }
        $Modulos = $script:LabGraphModulesMinimos
        $script:LabGraphModulesCargados = $true
    }

    Write-Host "  Cargando módulos en memoria..." -ForegroundColor DarkGray
    foreach ($mod in $Modulos) {
        Import-Module $mod -ErrorAction SilentlyContinue
    }
}

function Clear-LabGraphSessionCache {
    $script:LabGraphSessionCache = $null
}

function Test-LabGraphSession {
    if (-not (Get-Command Get-MgContext -ErrorAction SilentlyContinue)) {
        if (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication -ErrorAction SilentlyContinue) {
            Import-Module Microsoft.Graph.Authentication -ErrorAction SilentlyContinue
        } else {
            return $false
        }
    }

    try {
        $ctx = Get-MgContext -ErrorAction Stop
        if ($null -eq $ctx) { return $false }
        if ([string]::IsNullOrWhiteSpace($ctx.TenantId)) { return $false }
        return $true
    } catch {
        return $false
    }
}

function Get-LabGraphStatus {
    if ($null -ne $script:LabGraphSessionCache) {
        return $script:LabGraphSessionCache
    }

    if (-not (Test-LabGraphSession)) { return $null }

    $ctx = Get-MgContext
    $script:LabGraphSessionCache = [pscustomobject]@{
        Account  = $ctx.Account
        TenantId = $ctx.TenantId
        Scopes   = ($ctx.Scopes -join ", ")
    }
    return $script:LabGraphSessionCache
}

function Connect-LabGraph {
    param(
        [string]$TenantId = $null,
        [switch]$Forzar
    )

    # Si ya hay sesión y no se fuerza, reutilizarla
    if (-not $Forzar -and (Test-LabGraphSession)) {
        Write-LabInfo "Ya hay una sesión de Graph activa. Reutilizándola."
        return $true
    }

    if ($Forzar -and (Test-LabGraphSession)) {
        Write-LabInfo "Cerrando sesión actual antes de reconectar..."
        Disconnect-LabGraph
    }

    # Asegurar módulos
    if (-not (Install-LabGraphModules)) { return $false }
    Import-LabGraphModules

    # --- 1. Intentar App-Only (Certificado) ---
    $config = Get-LabConfig
    if ($config.AppOnlyClientId -and $config.AppOnlyTenantId -and $config.AppOnlyThumbprint) {
        Write-LabInfo "Conectando con App-Only (Certificado)..."
        try {
            Connect-MgGraph -ClientId $config.AppOnlyClientId `
                            -TenantId $config.AppOnlyTenantId `
                            -CertificateThumbprint $config.AppOnlyThumbprint `
                            -NoWelcome -ErrorAction Stop
        } catch {
            Write-LabWarn "Fallo App-Only: $($_.Exception.Message)"
            Write-LabWarn "Pasando a método interactivo de emergencia..."
        }
    }

    # --- 2. Fallback Interactivo ---
    if (-not (Test-LabGraphSession)) {
        Write-LabInfo "Iniciando conexión interactiva (Device Code)..."
        try {
            $params = @{
                Scopes        = $script:LabGraphScopes
                NoWelcome     = $true
                UseDeviceCode = $true
            }
            if ($TenantId) { $params.TenantId = $TenantId }

            Connect-MgGraph @params -ErrorAction Stop
        } catch {
            Write-LabError "Fallo al conectar con Microsoft Graph: $($_.Exception.Message)"
            return $false
        }
    }

    # Verificar que la conexión ha tenido efecto
    if (-not (Test-LabGraphSession)) {
        Write-LabError "La conexión se ejecutó pero no hay sesión válida."
        return $false
    }

    # Invalidar y repoblar caché
    Clear-LabGraphSessionCache
    $status = Get-LabGraphStatus

    Write-LabOk "Sesión establecida con $($status.Account) en tenant $($status.TenantId)."
    return $true
}

function Disconnect-LabGraph {
    if (-not (Test-LabGraphSession)) {
        Clear-LabGraphSessionCache
        return
    }

    try {
        Disconnect-MgGraph -ErrorAction Stop | Out-Null
        Write-LabInfo "Sesión de Microsoft Graph cerrada."
    } catch {
        Write-LabWarn "No se pudo cerrar la sesión limpiamente: $($_.Exception.Message)"
    } finally {
        Clear-LabGraphSessionCache
    }
}

function Invoke-LabGraphWithRetry {
    param([Parameter(Mandatory=$true)] [scriptblock]$ScriptBlock)

    if (-not (Test-LabGraphSession)) {
        Write-LabWarn "Sesión de Graph expirada o inexistente. Reconectando..."
        if (-not (Connect-LabGraph)) {
            Write-LabError "No se pudo reconectar. Operación cancelada."
            return $null
        }
    }

    return (& $ScriptBlock)
}