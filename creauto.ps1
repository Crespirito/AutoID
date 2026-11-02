<#
.SYNOPSIS
    Creación automática de entorno de laboratorio en Entra ID (Free).
.DESCRIPTION
    Crea un escenario predefinido: dos usuarios, una aplicación con su
    service principal, un grupo de seguridad y una membresía. Guarda un
    manifiesto con todos los objetos creados para que clean_up.ps1 los
    pueda eliminar después.

    La sesión de Microsoft Graph la gestiona menu.ps1. Este script NO
    conecta ni desconecta; solo verifica que hay sesión activa y falla
    con código 1 si no la hay.
.PARAMETER TenantId
    Tenant al que conectar. Se conserva por compatibilidad, pero en el
    flujo normal el menú ya tiene sesión y este parámetro no se usa.
.NOTES
    Depende de lib_ui.ps1, lib_log.ps1 y lib_manifiesto.ps1.
    Guardar este fichero como UTF-8 con BOM para compatibilidad con PS 5.1.
#>
#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$TenantId = $null
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================
# CARGA DE LIBRERÍAS
# ============================================================
. (Join-Path $PSScriptRoot "lib_ui.ps1")
. (Join-Path $PSScriptRoot "lib_log.ps1")
. (Join-Path $PSScriptRoot "lib_manifiesto.ps1")

# ============================================================
# VERIFICACIÓN DE SESIÓN (gestionada por el menú)
# ============================================================
if (-not (Get-MgContext -ErrorAction SilentlyContinue)) {
    Write-LabError "No hay sesión de Graph activa. Ejecuta este script desde menu.ps1."
    exit 1
}

# ============================================================
# LOG
# ============================================================
Reset-LabLog

# ============================================================
# CONFIGURACIÓN DEL ESCENARIO
# ============================================================
# --- Credenciales del escenario (SOLO LAB) ---
$AdminPassword    = "AdminP@ssw0rd#2025!"
$LowPrivPassword  = "UserAccess!123"

# --- Parámetros de ejecución ---
$standardDelay    = 2

Write-Host ""
Write-Host "|--------------------------------------------------------------|" -ForegroundColor Cyan
Write-Host "|              CREACION AUTOMATICA - SETUP INICIAL             |" -ForegroundColor Cyan
Write-Host "|                      [Scenario Name Here]                    |" -ForegroundColor Cyan
Write-Host "|--------------------------------------------------------------|" -ForegroundColor Cyan
Write-Host ""

# ============================================================
# INFORMACIÓN DEL TENANT
# ============================================================
Write-Verbose "[*] Obteniendo información del tenant..."

try {
    $Organization = Get-MgOrganization -ErrorAction Stop
    $TenantDomain = ($Organization.VerifiedDomains | Where-Object { $_.IsDefault -eq $true }).Name
    if (-not $TenantDomain) { $TenantDomain = $Organization.VerifiedDomains[0].Name }

    $context = Get-MgContext
    $manifiesto = New-LabManifiestoVacio
    $manifiesto.TenantId     = $context.TenantId
    $manifiesto.TenantDomain = $TenantDomain

    Add-LabLogEntry -Categoria "Info" -Mensaje "Información del tenant obtenida." -Detalle @{
        Tenant = $TenantDomain
        Id     = $context.TenantId
    }
    Write-Verbose "[+] Tenant: $TenantDomain"
} catch {
    Add-LabLogEntry -Categoria "Error" -Mensaje "No se pudo obtener información del tenant." -Detalle $_.Exception.Message
    exit 1
}

# ============================================================
# SIMULACIÓN GLOBAL DEL ESCENARIO
# ============================================================
$LowPrivUPN = "pepito.sl@$TenantDomain"
$AdminUPN   = "jose.juan.valdero@$TenantDomain"
$PrivilegedAppName = "Panel de Analisis Comercial"
$SalesGroupName = "Departamento de Ventas"

Write-Host ""
Write-Host "--- Simulacion del escenario automatico ---" -ForegroundColor Yellow
Write-Host "  Se van a crear (o reutilizar si ya existen) los siguientes objetos:"
Write-Host ""
Write-Host "  [Usuarios]" -ForegroundColor Cyan
Write-Host "    - $LowPrivUPN (Rol: Comercial)"
Write-Host "    - $AdminUPN (Rol: Administrador de Sistemas)"
Write-Host ""
Write-Host "  [Aplicaciones]" -ForegroundColor Cyan
Write-Host "    - $PrivilegedAppName (con su Service Principal)"
Write-Host ""
Write-Host "  [Grupos]" -ForegroundColor Cyan
Write-Host "    - $SalesGroupName"
Write-Host ""
Write-Host "  [Relaciones]" -ForegroundColor Cyan
Write-Host "    - $LowPrivUPN sera miembro de $SalesGroupName"
Write-Host ""
Write-Host "  NOTA: Cualquier objeto que ya exista con el mismo nombre/UPN se reutilizara." -ForegroundColor DarkGray
Write-Host ""

if (-not (Read-LabConfirm "¿Deseas continuar con la creacion del escenario?")) {
    Write-LabInfo "Operación cancelada por el usuario antes de crear nada."
    exit 0
}

# ============================================================
# FUNCIONES AUXILIARES DE CREACIÓN
# ============================================================

function New-EntraGoatUser {
    <#
    .SYNOPSIS
        Crea (o reutiliza) un usuario y lo registra en el manifiesto.
    #>
    param(
        [Parameter(Mandatory=$true)] [string]$DisplayName,
        [Parameter(Mandatory=$true)] [string]$UserPrincipalName,
        [Parameter(Mandatory=$true)] [string]$MailNickname,
        [Parameter(Mandatory=$true)] [string]$Password,
        [Parameter(Mandatory=$false)] [string]$Department = "",
        [Parameter(Mandatory=$false)] [string]$JobTitle = ""
    )

    Write-Verbose "   -> $DisplayName : $UserPrincipalName"
    $ExistingUser = Get-MgUser -Filter "userPrincipalName eq '$UserPrincipalName'" -ErrorAction SilentlyContinue

    if ($ExistingUser) {
        if ($ExistingUser -is [array]) { $ExistingUser = $ExistingUser[0] }
        $User = $ExistingUser
        Write-Verbose "      EXISTS (using existing)"

        $passwordProfile = @{
            Password = $Password
            ForceChangePasswordNextSignIn = $false
        }
        Update-MgUser -UserId $User.Id -PasswordProfile $passwordProfile -ErrorAction Stop

        # Se añade al manifiesto igualmente: si ya existía, queremos poder limpiarlo
        if ($manifiesto.Usuarios -notcontains $UserPrincipalName) {
            $manifiesto.Usuarios += $UserPrincipalName
        }
    } else {
        $UserParams = @{
            DisplayName       = $DisplayName
            UserPrincipalName = $UserPrincipalName
            MailNickname      = $MailNickname
            AccountEnabled    = $true
            PasswordProfile   = @{
                ForceChangePasswordNextSignIn = $false
                Password = $Password
            }
        }

        if ($Department) { $UserParams.Department = $Department }
        if ($JobTitle)   { $UserParams.JobTitle   = $JobTitle }

        $User = New-MgUser @UserParams -ErrorAction Stop
        Write-Verbose "      CREATED"
        Add-LabLogEntry -Categoria "Info" -Mensaje "Usuario creado." -Detalle $UserPrincipalName
        $manifiesto.Usuarios += $UserPrincipalName
        Start-Sleep -Seconds $standardDelay
    }

    return $User
}

function New-EntraGoatApplication {
    <#
    .SYNOPSIS
        Crea (o reutiliza) una aplicación y su service principal,
        registrando ambos en el manifiesto.
    #>
    param(
        [Parameter(Mandatory=$true)] [string]$DisplayName,
        [Parameter(Mandatory=$true)] [string]$Description,
        [Parameter(Mandatory=$false)] [string]$SignInAudience = "AzureADMyOrg",
        [Parameter(Mandatory=$false)] [array]$RedirectUris = @("https://hr-analytics.contoso.com/callback"),
        [Parameter(Mandatory=$false)] [array]$Tags = @("WindowsAzureActiveDirectoryIntegratedApp")
    )

    # Normalizar RedirectUris por si viene vacío
    if ($null -eq $RedirectUris) { $RedirectUris = @() }

    Write-Verbose "[*] Creating application: $DisplayName"
    $ExistingApp = Get-MgApplication -Filter "displayName eq '$($DisplayName -replace "'", "''")'" -ErrorAction SilentlyContinue

    if ($ExistingApp) {
        if ($ExistingApp -is [array]) { $ExistingApp = $ExistingApp[0] }
        $App = $ExistingApp
        Write-Verbose "   -> Application exists: $DisplayName"
        if ($manifiesto.Aplicaciones -notcontains $DisplayName) {
            $manifiesto.Aplicaciones += $DisplayName
        }
    } else {
        $AppParams = @{
            DisplayName    = $DisplayName
            SignInAudience = $SignInAudience
            Description    = $Description
            Web            = @{ RedirectUris = $RedirectUris }
        }
        $App = New-MgApplication @AppParams -ErrorAction Stop
        Write-Verbose "   -> Application created: $DisplayName"
        Add-LabLogEntry -Categoria "Info" -Mensaje "Aplicación creada." -Detalle $DisplayName
        $manifiesto.Aplicaciones += $DisplayName
        Start-Sleep -Seconds $standardDelay
    }

    $AppId = $App.AppId
    if ($AppId -is [array]) { $AppId = $AppId[0] }
    $AppId = $AppId.ToString()

    Write-Verbose "[*] Creating service principal for $DisplayName..."
    $ExistingSP = Get-MgServicePrincipal -Filter "appId eq '$AppId'" -ErrorAction SilentlyContinue

    if ($ExistingSP) {
        if ($ExistingSP -is [array]) { $ExistingSP = $ExistingSP[0] }
        $SP = $ExistingSP
        Write-Verbose "   -> Service principal exists"

        $CurrentTags = $SP.Tags
        if (-not ($CurrentTags -contains "WindowsAzureActiveDirectoryIntegratedApp")) {
            if ($Tags) {
                Update-MgServicePrincipal -ServicePrincipalId $SP.Id -Tags $Tags -ErrorAction SilentlyContinue
                Write-Verbose "   -> Updated visibility tags"
            }
        }
        if ($manifiesto.ServicePrincipals -notcontains $SP.Id) {
            $manifiesto.ServicePrincipals += $SP.Id
        }
    } else {
        $SPParams = @{
            AppId       = $AppId
            DisplayName = $DisplayName
        }
        $SP = New-MgServicePrincipal @SPParams -ErrorAction Stop
        Write-Verbose "   -> Service principal created"
        Add-LabLogEntry -Categoria "Info" -Mensaje "Service Principal creado." -Detalle $SP.Id
        $manifiesto.ServicePrincipals += $SP.Id
        Start-Sleep -Seconds $standardDelay
        if ($Tags) {
            Update-MgServicePrincipal -ServicePrincipalId $SP.Id -Tags $Tags -ErrorAction SilentlyContinue
        }
    }

    return @{
        Application      = $App
        ServicePrincipal = $SP
        AppId            = $AppId
    }
}

function New-EntraGoatGroup {
    <#
    .SYNOPSIS
        Crea (o reutiliza) un grupo de seguridad y lo registra en el manifiesto.
    #>
    param(
        [Parameter(Mandatory=$true)] [string]$DisplayName,
        [Parameter(Mandatory=$false)] [string]$Description = "",
        [Parameter(Mandatory=$false)] [string]$MailNickname = ""
    )

    Write-Verbose "[*] Creating group: $DisplayName"
    $ExistingGroup = Get-MgGroup -Filter "displayName eq '$($DisplayName -replace "'", "''")'" -ErrorAction SilentlyContinue

    if ($ExistingGroup) {
        if ($ExistingGroup -is [array]) { $ExistingGroup = $ExistingGroup[0] }
        $Group = $ExistingGroup
        Write-Verbose "   -> Group exists: $DisplayName"
        if ($manifiesto.Grupos -notcontains $DisplayName) {
            $manifiesto.Grupos += $DisplayName
        }
        return $Group
    }

    if (-not $MailNickname) {
        $MailNickname = $DisplayName -replace '[^a-zA-Z0-9]', ''
    }

    # NOTA: IsAssignableToRole se omite porque requiere P1/P2.
    $GroupParams = @{
        DisplayName     = $DisplayName
        Description     = $Description
        MailNickname    = $MailNickname
        MailEnabled     = $false
        SecurityEnabled = $true
    }

    $Group = New-MgGroup @GroupParams -ErrorAction Stop
    Write-Verbose "   -> Group created: $DisplayName"
    Add-LabLogEntry -Categoria "Info" -Mensaje "Grupo creado." -Detalle $DisplayName
    $manifiesto.Grupos += $DisplayName
    Start-Sleep -Seconds $standardDelay

    return $Group
}

function Add-EntraGoatGroupMember {
    <#
    .SYNOPSIS
        Añade un miembro a un grupo si no lo estaba ya.
    #>
    param(
        [Parameter(Mandatory=$true)] [string]$GroupId,
        [Parameter(Mandatory=$true)] [string]$MemberId
    )

    Write-Verbose "[*] Adding member $MemberId to group $GroupId..."

    $ExistingMembers = Get-MgGroupMember -GroupId $GroupId -All -ErrorAction SilentlyContinue
    foreach ($member in @($ExistingMembers)) {
        if ($member.Id -eq $MemberId) {
            Write-Verbose "   -> Member already present"
            return
        }
    }

    $MemberParams = @{
        "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$MemberId"
    }
    New-MgGroupMemberByRef -GroupId $GroupId -BodyParameter $MemberParams -ErrorAction Stop
    Write-Verbose "   -> Member added"
    Add-LabLogEntry -Categoria "Info" -Mensaje "Miembro añadido al grupo." -Detalle @{
        Grupo   = $GroupId
        Miembro = $MemberId
    }
    Start-Sleep -Seconds $standardDelay
}

# ============================================================
# CREACIÓN DE USUARIOS
# ============================================================
Write-Verbose "[*] Setting up users..."

Write-Verbose "    -> Regular user: $LowPrivUPN"
$LowPrivUser = New-EntraGoatUser `
    -DisplayName "Pepito SL" `
    -UserPrincipalName $LowPrivUPN `
    -MailNickname "pepito.sl" `
    -Password $LowPrivPassword `
    -Department "Ventas" `
    -JobTitle "Comercial"

Write-Verbose "    -> Admin user: $AdminUPN"
$AdminUser = New-EntraGoatUser `
    -DisplayName "Jose Juan Valdero" `
    -UserPrincipalName $AdminUPN `
    -MailNickname "jose.juan.valdero" `
    -Password $AdminPassword `
    -Department "Administracion IT" `
    -JobTitle "Administrador de Sistemas"

# ============================================================
# CREACIÓN DE APLICACIÓN Y SERVICE PRINCIPAL
# ============================================================
Write-Verbose "[*] Creating application and service principal..."

$PrivilegedAppResult = New-EntraGoatApplication `
    -DisplayName $PrivilegedAppName `
    -Description "Panel interno de analisis y reportes comerciales" `
    -SignInAudience "AzureADMyOrg" `
    -RedirectUris @("https://panel-analisis.empresa.local/callback") `
    -Tags @("WindowsAzureActiveDirectoryIntegratedApp")

$PrivilegedApp    = $PrivilegedAppResult.Application
$ServicePrincipal = $PrivilegedAppResult.ServicePrincipal
$AppId            = $PrivilegedAppResult.AppId

Write-Verbose "    -> Application: $PrivilegedAppName"
Write-Verbose "    -> SP ID: $($ServicePrincipal.Id)"
Write-Verbose "    -> App ID: $AppId"

# ============================================================
# CREACIÓN DE GRUPO
# ============================================================
Write-Verbose "[*] Creating groups..."

$SalesGroup = New-EntraGoatGroup `
    -DisplayName $SalesGroupName `
    -Description "Usuarios del departamento de ventas" `
    -MailNickname "departamento-ventas"

Write-Verbose "    -> Group: $SalesGroupName"
Write-Verbose "    -> Group ID: $($SalesGroup.Id)"

# ============================================================
# MEMBRESÍA DE GRUPO
# ============================================================
Write-Verbose "[*] Assigning group memberships..."

Add-EntraGoatGroupMember `
    -GroupId $SalesGroup.Id `
    -MemberId $LowPrivUser.Id

Write-Verbose "    -> Added $($LowPrivUser.DisplayName) to $($SalesGroup.DisplayName)"

# ============================================================
# INYECCIÓN DE VULNERABILIDAD
# ============================================================
Write-Verbose "[!] Injecting scenario vulnerability..."

# ------------------------------------------------------------------
# Aquí va la lógica específica del escenario.
#
# Todos los ejemplos están comentados. Al crear un escenario nuevo,
# descomenta el o los bloques que necesites y adapta los valores.
#
# IMPORTANTE: esta versión está limitada a tenant Free. Las
# operaciones con roles de directorio NO están disponibles.
#
# Ejemplos válidos en Free:
#   - Asignar un propietario a un Service Principal
#   - Añadir credenciales a una app
#   - Conceder permisos de API a una app
#   - Añadir miembros a grupos
# ------------------------------------------------------------------

# ------------------------------------------------------------------
# Ejemplo 1: asignar propietario a un Service Principal
# ------------------------------------------------------------------
# $OwnerParams = @{
#     "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$($LowPrivUser.Id)"
# }
# New-MgServicePrincipalOwnerByRef -ServicePrincipalId $ServicePrincipal.Id -BodyParameter $OwnerParams
# Add-LabLogEntry -Categoria "Info" -Mensaje "Propietario asignado al Service Principal." -Detalle $LowPrivUser.Id

# ------------------------------------------------------------------
# Ejemplo 2: añadir credenciales (secret) a una aplicación
# ------------------------------------------------------------------
# $PasswordCredential = @{
#     displayName = "Scenario credential"
#     endDateTime = (Get-Date).AddYears(1)
# }
# $Credential = Add-MgApplicationPassword -ApplicationId $PrivilegedApp.Id -PasswordCredential $PasswordCredential
# Add-LabLogEntry -Categoria "Info" -Mensaje "Credencial añadida a la aplicación." -Detalle $PrivilegedApp.DisplayName

# ------------------------------------------------------------------
# Ejemplo 3: conceder permisos de API a una aplicación
# ------------------------------------------------------------------
# (Requiere buscar el AppRole del recurso, crear el assignment, etc.)

Write-Verbose "[+] Vulnerability injected"

# ============================================================
# VERIFICACIÓN FINAL
# ============================================================
Write-Verbose "[*] Running final verification..."

$AllChecks = @()

# 1. Usuario de bajo privilegio
$Check1 = $false
$ExistingLowPriv = Get-MgUser -Filter "userPrincipalName eq '$LowPrivUPN'" -ErrorAction SilentlyContinue
if ($ExistingLowPriv) { $Check1 = $true; Write-Verbose "    -> [+] Low-priv user exists: $LowPrivUPN" }
else { Write-Verbose "    -> [-] Low-priv user NOT found: $LowPrivUPN" }
$AllChecks += $Check1

# 2. Usuario administrador
$Check2 = $false
$ExistingAdmin = Get-MgUser -Filter "userPrincipalName eq '$AdminUPN'" -ErrorAction SilentlyContinue
if ($ExistingAdmin) { $Check2 = $true; Write-Verbose "    -> [+] Admin user exists: $AdminUPN" }
else { Write-Verbose "    -> [-] Admin user NOT found: $AdminUPN" }
$AllChecks += $Check2

# 3. Aplicación + SP
$Check3 = $false
$ExistingApp = Get-MgApplication -Filter "displayName eq '$PrivilegedAppName'" -ErrorAction SilentlyContinue
if ($ExistingApp) {
    if ($ExistingApp -is [array]) { $ExistingApp = $ExistingApp[0] }
    $ExistingSPCheck = Get-MgServicePrincipal -Filter "appId eq '$($ExistingApp.AppId)'" -ErrorAction SilentlyContinue
    if ($ExistingSPCheck) {
        $Check3 = $true
        Write-Verbose "    -> [+] Application and SP exist: $PrivilegedAppName"
    } else {
        Write-Verbose "    -> [-] Application exists but SP NOT found: $PrivilegedAppName"
    }
} else {
    Write-Verbose "    -> [-] Application NOT found: $PrivilegedAppName"
}
$AllChecks += $Check3

# 4. Grupo
$Check4 = $false
$ExistingGroup = Get-MgGroup -Filter "displayName eq '$SalesGroupName'" -ErrorAction SilentlyContinue
if ($ExistingGroup) {
    if ($ExistingGroup -is [array]) { $ExistingGroup = $ExistingGroup[0] }
    $Check4 = $true
    Write-Verbose "    -> [+] Group exists: $SalesGroupName"
} else {
    Write-Verbose "    -> [-] Group NOT found: $SalesGroupName"
}
$AllChecks += $Check4

# 5. Membresía
$Check5 = $false
if ($ExistingGroup -and $ExistingLowPriv) {
    $Members = Get-MgGroupMember -GroupId $ExistingGroup.Id -All -ErrorAction SilentlyContinue
    foreach ($member in @($Members)) {
        if ($member.Id -eq $ExistingLowPriv.Id) { $Check5 = $true; break }
    }
}
if ($Check5) { Write-Verbose "    -> [+] Low-priv user is member of the group" }
else         { Write-Verbose "    -> [-] Low-priv user is NOT member of the group" }
$AllChecks += $Check5

$SetupSuccessful = -not ($AllChecks -contains $false)
if ($SetupSuccessful) {
    Write-Verbose "[+] Final verification passed"
} else {
    Write-Verbose "[-] Final verification failed"
    Add-LabLogEntry -Categoria "Warning" -Mensaje "Verificación final con fallos." -Detalle "Algunos checks no se superaron."
}

# ============================================================
# RESUMEN EN PANTALLA
# ============================================================
# Mostrar resumen verbose solo si se invocó con -Verbose
$modoVerbose = $false
if ($PSBoundParameters.ContainsKey('Verbose') -and $PSBoundParameters['Verbose']) {
    $modoVerbose = $true
}

if ($modoVerbose) {
    Write-Host ""
    Write-Host "|--------------------------------------------------------------|" -ForegroundColor Cyan
    Write-Host "|       CONFIGURACION AUTOMATICA COMPLETADA (VERBOSE)          |" -ForegroundColor Cyan
    Write-Host "|--------------------------------------------------------------|" -ForegroundColor Cyan
    Write-Host ""

    Write-Host "`nDETALLES DE LA VULNERABILIDAD:" -ForegroundColor Yellow
    Write-Host "----------------------------" -ForegroundColor DarkGray
    Write-Host "  - [Descripcion de la vulnerabilidad inyectada]" -ForegroundColor White

    Write-Host "`nCREDENCIALES DEL ATACANTE:" -ForegroundColor Red
    Write-Host "----------------------------" -ForegroundColor DarkGray
    Write-Host "  Usuario: " -ForegroundColor White -NoNewline
    Write-Host "$LowPrivUPN" -ForegroundColor Cyan
    Write-Host "  Contrasena: " -ForegroundColor White -NoNewline
    Write-Host "$LowPrivPassword" -ForegroundColor Cyan

    Write-Host "`nOBJETIVO:" -ForegroundColor Magenta
    Write-Host "----------------------------" -ForegroundColor DarkGray
    Write-Host "  Usuario: " -ForegroundColor White -NoNewline
    Write-Host "$AdminUPN" -ForegroundColor Cyan

    Write-Host "`n=====================================================" -ForegroundColor DarkGray
    Write-Host ""
} else {
    Write-Host ""
    if ($SetupSuccessful) {
        Write-LabOk "Escenario configurado correctamente"
        Write-Host ""
        Write-Host "Objetivo: entorno creado. Listo para probar." -ForegroundColor Gray
        Write-Host ""
        Write-Host "`nTUS CREDENCIALES:" -ForegroundColor Red
        Write-Host "----------------------------" -ForegroundColor DarkGray
        Write-Host "  Usuario: " -ForegroundColor White -NoNewline
        Write-Host "$LowPrivUPN" -ForegroundColor Cyan
        Write-Host "  Contrasena: " -ForegroundColor White -NoNewline
        Write-Host "$LowPrivPassword" -ForegroundColor Cyan

        Write-Host "`nOBJETIVO:" -ForegroundColor Magenta
        Write-Host "----------------------------" -ForegroundColor DarkGray
        Write-Host "  Usuario: " -ForegroundColor White -NoNewline
        Write-Host "$AdminUPN" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "Pista: [pista del escenario]" -ForegroundColor DarkGray
    } else {
        Write-LabError "Fallo al configurar el escenario - intentalo de nuevo o ejecuta con -Verbose para mas informacion."
    }
    Write-Host ""
}

Write-Host "`nProceso de configuracion completado." -ForegroundColor White
Write-Host "=====================================================" -ForegroundColor DarkGray
Write-Host ""

# ============================================================
# GUARDADO DEL MANIFIESTO Y LOG
# ============================================================
$manifiestoPath = Get-LabManifiestoPath

if (Save-LabManifiesto -Manifiesto $manifiesto -Path $manifiestoPath) {
    Add-LabLogEntry -Categoria "Info" -Mensaje "Manifiesto guardado correctamente." -Detalle $manifiestoPath
} else {
    Add-LabLogEntry -Categoria "Error" -Mensaje "No se pudo guardar el manifiesto." -Detalle $manifiestoPath
}

$logPath = Save-LabLog -Prefijo "log_creauto"
$resumen = Get-LabLogSummary

Write-Host ""
Write-Host "--- Resumen de ejecucion ---" -ForegroundColor Cyan
Write-Host "Eventos totales: $($resumen.Total)"
Write-Host "Avisos:          $($resumen.Avisos)" -ForegroundColor Yellow
Write-Host "Errores:         $($resumen.Errores)" -ForegroundColor Red
if ($logPath) {
    Write-Host "Log completo:    $logPath" -ForegroundColor Gray
}
Write-Host "Manifiesto:      $manifiestoPath" -ForegroundColor Gray
Write-Host ""