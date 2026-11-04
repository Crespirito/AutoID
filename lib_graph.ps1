<#
.SYNOPSIS
    Librería de gestión de sesión de Microsoft Graph.
.DESCRIPTION
    Proporciona:
      - Instalación del módulo Microsoft.Graph si no está presente
      - Conexión delegada con scopes para tenant Free + mecanismos P1/P2
      - Verificación de sesión activa
      - Estado de la sesión actual
      - Desconexión limpia
      - Reintento automático de operaciones si la sesión expira
.NOTES
    Depende de lib_ui.ps1 (funciones Write-Lab*).
    Se carga por dot-sourcing desde menu.ps1.

    SCOPES Y PROPÓSITO:
    - Free: User, Group, Application, AppRoleAssignment, Directory.Read
    - AdministrativeUnit.ReadWrite.All: Crear y gestionar Administrative Units.
      Son el mecanismo de Entra ID más cercano a las OUs de AD on-prem.
      Permite agrupar usuarios/grupos y asignar administradores con alcance limitado.
      Crear la AU es posible en Free; asignar roles scoped requiere P1.
    - RoleManagement.ReadWrite.Directory: Gestionar PIM (roles elegibles).
      Permite crear asignaciones elegibles, que modelan los privilegios
      acumulados y no permanentes típicos de REDIL.
#>

# ============================================================
# SCOPES REQUERIDOS
# ============================================================
# Base Free (siempre presentes)
$script:LabGraphScopesFree = @(
    'User.ReadWrite.All',
    'Group.ReadWrite.All',
    'Application.ReadWrite.All',
    'AppRoleAssignment.ReadWrite.All',
    'Directory.Read.All'
)

# Mecanismos para acercarse a REDIL (pueden requerir P1/P2)
$script:LabGraphScopesExtended = @(
    'AdministrativeUnit.ReadWrite.All',
    'RoleManagement.ReadWrite.Directory'
)

# Scopes activos por defecto: Free + Extended
$script:LabGraphScopes = $script:LabGraphScopesFree + $script:LabGraphScopesExtended

# ============================================================
# FUNCIONES PÚBLICAS
# ============================================================

function Get-LabGraphScopes {
    <#
    .SYNOPSIS
        Devuelve el array de scopes usados por la sesión de Graph.
    #>
    return $script:LabGraphScopes
}

function Get-LabGraphScopesFree {
    <#
    .SYNOPSIS
        Devuelve solo los scopes compatibles con Entra ID Free.
    #>
    return $script:LabGraphScopesFree
}

function Test-LabGraphSession {
    <#
    .SYNOPSIS
        Devuelve $true si hay una sesión de Graph activa con tenant válido.
    #>
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
    <#
    .SYNOPSIS
        Devuelve un objeto con el estado de la sesión, o $null si no hay.
    #>
    if (-not (Test-LabGraphSession)) { return $null }

    $ctx = Get-MgContext
    return [pscustomobject]@{
        Account  = $ctx.Account
        TenantId = $ctx.TenantId
        Scopes   = ($ctx.Scopes -join ', ')
    }
}

function Install-LabGraphModule {
    <#
    .SYNOPSIS
        Instala el módulo Microsoft.Graph si no está disponible.
    #>
    if (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication -ErrorAction SilentlyContinue) {
        return $true
    }

    Write-LabWarn 'Módulo Microsoft.Graph no encontrado. Instalando desde PSGallery (puede tardar)...'

    try {
        Install-Module -Name Microsoft.Graph -Scope CurrentUser -Repository PSGallery -Force -ErrorAction Stop
        Write-LabOk 'Módulo Microsoft.Graph instalado.'
        return $true
    } catch {
        Write-LabError "No se pudo instalar Microsoft.Graph: $($_.Exception.Message)"
        return $false
    }
}

function Connect-LabGraph {
    <#
    .SYNOPSIS
        Conecta a Microsoft Graph con los scopes del laboratorio.
        Si ya hay sesión activa, la reutiliza.
    .PARAMETER TenantId
        Tenant específico al que conectar. Si se omite, se usa el interactivo.
    .PARAMETER SoloFree
        Si se especifica, usa solo los scopes compatibles con Free,
        omitiendo AdministrativeUnit y RoleManagement.
    #>
    param(
        [string]$TenantId = $null,
        [switch]$SoloFree
    )

    # Si ya hay sesión, no reconectar
    if (Test-LabGraphSession) {
        Write-LabInfo 'Ya hay una sesión de Graph activa. Reutilizándola.'
        return $true
    }

    # Asegurar módulo
    if (-not (Install-LabGraphModule)) {
        return $false
    }

    # Importar módulo de autenticación
    try {
        Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    } catch {
        Write-LabError "No se pudo importar Microsoft.Graph.Authentication: $($_.Exception.Message)"
        return $false
    }

    # Determinar scopes según modo
    $scopesToUse = if ($SoloFree) { $script:LabGraphScopesFree } else { $script:LabGraphScopes }

    # Conectar
    try {
        $params = @{
            Scopes    = $scopesToUse
            NoWelcome = $true
        }
        if ($TenantId) { $params.TenantId = $TenantId }

        $null = Connect-MgGraph @params -ErrorAction Stop
    } catch {
        Write-LabError "Fallo al conectar con Microsoft Graph: $($_.Exception.Message)"
        if (-not $SoloFree) {
            Write-LabWarn 'Si el tenant no soporta los scopes extendidos, prueba con -SoloFree.'
        }
        return $false
    }

    # Verificar que la conexión ha tenido efecto
    if (-not (Test-LabGraphSession)) {
        Write-LabError 'La conexión se ejecutó pero no hay sesión válida.'
        return $false
    }

    $status = Get-LabGraphStatus
    Write-LabOk "Sesión establecida con $($status.Account) en tenant $($status.TenantId)."
    return $true
}

function Disconnect-LabGraph {
    <#
    .SYNOPSIS
        Cierra la sesión de Graph si existe. No falla si no hay sesión.
    #>
    if (-not (Test-LabGraphSession)) {
        return
    }

    try {
        $null = Disconnect-MgGraph -ErrorAction Stop
        Write-LabInfo 'Sesión de Microsoft Graph cerrada.'
    } catch {
        Write-LabWarn "No se pudo cerrar la sesión limpiamente: $($_.Exception.Message)"
    }
}

function Invoke-LabGraphWithRetry {
    <#
    .SYNOPSIS
        Ejecuta un bloque de código asegurando sesión activa.
    .PARAMETER ScriptBlock
        Bloque de código a ejecutar con sesión garantizada.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock
    )

    if (-not (Test-LabGraphSession)) {
        Write-LabWarn 'Sesión de Graph expirada o inexistente. Reconectando...'
        if (-not (Connect-LabGraph)) {
            Write-LabError 'No se pudo reconectar. Operación cancelada.'
            return $null
        }
    }

    return (& $ScriptBlock)
}