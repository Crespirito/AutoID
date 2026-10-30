<#
.SYNOPSIS
    Creación automática de entorno de laboratorio en Entra ID basada en escenarios.
.DESCRIPTION
    Lee las definiciones de escenario de la carpeta escenarios/escenario/ y las
    vulnerabilidades de escenarios/vulnerab/. Muestra al usuario los escenarios
    disponibles, crea los objetos del escenario elegido y, si el escenario declara
    una vulnerabilidad, pregunta si aplicarla. Todo lo creado (incluida la
    vulnerabilidad aplicada) se registra en el manifiesto para que clean_up.ps1
    pueda revertirlo.

    La sesión de Microsoft Graph la gestiona menu.ps1. Este script NO conecta ni
    desconecta; solo verifica que hay sesión activa y falla con código 1 si no la hay.
.PARAMETER Escenario
    Nombre del escenario a crear (sin extensión). Si se omite, se muestra un menú.
.PARAMETER SinVulnerabilidad
    Si se especifica, no aplica la vulnerabilidad aunque el escenario la declare.
.NOTES
    Depende de lib_ui.ps1, lib_manifiesto.ps1 y lib_escenarios.ps1.
#>
#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$Escenario = $null,

    [Parameter(Mandatory = $false)]
    [switch]$SinVulnerabilidad
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================
# CARGA DE LIBRERÍAS
# ============================================================
. (Join-Path $PSScriptRoot "lib_ui.ps1")
. (Join-Path $PSScriptRoot "lib_manifiesto.ps1")
. (Join-Path $PSScriptRoot "lib_escenarios.ps1")

# ============================================================
# VERIFICACIÓN DE SESIÓN (gestionada por el menú)
# ============================================================
if (-not (Get-MgContext -ErrorAction SilentlyContinue)) {
    Write-LabError "No hay sesión de Graph activa. Ejecuta este script desde menu.ps1."
    exit 1
}

# ============================================================
# FASE 0: LOG Y MANIFIESTO
# ============================================================
$log = [System.Collections.Generic.List[object]]::new()

function Add-LogEntry {
    param(
        [string]$Categoria,
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

$manifiesto = New-LabManifiestoVacio

# ============================================================
# INFORMACIÓN DEL TENANT
# ============================================================
Write-Verbose "[*] Obteniendo información del tenant..."

try {
    $Organization = Get-MgOrganization -ErrorAction Stop
    $TenantDomain = ($Organization.VerifiedDomains | Where-Object IsDefault).Name

    $context = Get-MgContext
    $manifiesto.TenantId     = $context.TenantId
    $manifiesto.TenantDomain = $TenantDomain

    Add-LogEntry -Categoria "Info" -Mensaje "Información del tenant obtenida." -Detalle @{
        Tenant = $TenantDomain
        Id     = $context.TenantId
    }
} catch {
    Add-LogEntry -Categoria "Error" -Mensaje "No se pudo obtener información del tenant." -Detalle $_.Exception.Message
    exit 1
}

# ============================================================
# SELECCIÓN DE ESCENARIO
# ============================================================
$disponibles = Get-LabEscenariosDisponibles
if ($disponibles.Count -eq 0) {
    Write-LabError "No hay escenarios en la carpeta escenarios/escenario/."
    exit 1
}

if (-not $Escenario) {
    Show-LabHeader -Titulo "SELECCION DE ESCENARIO"
    Write-Host "Escenarios disponibles:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $disponibles.Count; $i++) {
        Write-Host ("  [{0}] {1}" -f $i, $disponibles[$i])
    }
    Write-Host ""
    $sel = Read-Host "Selecciona un escenario"
    if (-not ($sel -match '^\d+$') -or [int]$sel -ge $disponibles.Count) {
        Write-LabError "Selección inválida."
        exit 1
    }
    $Escenario = $disponibles[[int]$sel]
}

Write-LabInfo "Escenario seleccionado: $Escenario"

try {
    $def = Get-LabEscenario -Nombre $Escenario
    Add-LogEntry -Categoria "Info" -Mensaje "Escenario cargado." -Detalle $Escenario
} catch {
    Add-LogEntry -Categoria "Error" -Mensaje "No se pudo cargar el escenario." -Detalle @{
        Escenario = $Escenario
        Error     = $_.Exception.Message
    }
    exit 1
}

# ============================================================
# FUNCIONES AUXILIARES DE CREACIÓN
# ============================================================

function New-EntraGoatUser {
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
        if ($null -eq $User) { throw "New-MgUser no devolvió objeto para $UserPrincipalName" }
        if ($User -is [array]) { $User = $User[0] }
        Write-Verbose "      CREATED"
        Add-LogEntry -Categoria "Info" -Mensaje "Usuario creado." -Detalle $UserPrincipalName
        $manifiesto.Usuarios += $UserPrincipalName
    }

    return $User
}

function New-EntraGoatApplication {
    param(
        [Parameter(Mandatory=$true)] [string]$DisplayName,
        [Parameter(Mandatory=$true)] [string]$Description,
        [Parameter(Mandatory=$false)] [string]$SignInAudience = "AzureADMyOrg",
        [Parameter(Mandatory=$false)] [array]$RedirectUris = @("https://hr-analytics.contoso.com/callback"),
        [Parameter(Mandatory=$false)] [array]$Tags = @("WindowsAzureActiveDirectoryIntegratedApp")
    )

    Write-Verbose "[*] Creating application: $DisplayName"
    $ExistingApp = Get-MgApplication -Filter "displayName eq '$DisplayName'" -ErrorAction SilentlyContinue

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
        if ($null -eq $App) { throw "New-MgApplication no devolvió objeto para $DisplayName" }
        if ($App -is [array]) { $App = $App[0] }
        Write-Verbose "   -> Application created: $DisplayName"
        Add-LogEntry -Categoria "Info" -Mensaje "Aplicación creada." -Detalle $DisplayName
        $manifiesto.Aplicaciones += $DisplayName
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
        $CurrentTags = $null
        if ($SP.PSObject.Properties['Tags']) { $CurrentTags = $SP.Tags }
        if (-not ($CurrentTags -contains "WindowsAzureActiveDirectoryIntegratedApp")) {
            if ($Tags) {
                Update-MgServicePrincipal -ServicePrincipalId $SP.Id -Tags $Tags -ErrorAction SilentlyContinue
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
        if ($null -eq $SP) { throw "New-MgServicePrincipal no devolvió objeto para $DisplayName" }
        if ($SP -is [array]) { $SP = $SP[0] }
        Write-Verbose "   -> Service principal created"
        Add-LogEntry -Categoria "Info" -Mensaje "Service Principal creado." -Detalle $SP.Id
        $manifiesto.ServicePrincipals += $SP.Id
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
    param(
        [Parameter(Mandatory=$true)] [string]$DisplayName,
        [Parameter(Mandatory=$false)] [string]$Description = "",
        [Parameter(Mandatory=$false)] [string]$MailNickname = ""
    )

    Write-Verbose "[*] Creating group: $DisplayName"
    $ExistingGroup = Get-MgGroup -Filter "displayName eq '$DisplayName'" -ErrorAction SilentlyContinue

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

    $GroupParams = @{
        DisplayName     = $DisplayName
        Description     = $Description
        MailNickname    = $MailNickname
        MailEnabled     = $false
        SecurityEnabled = $true
    }

    $Group = New-MgGroup @GroupParams -ErrorAction Stop
    if ($null -eq $Group) { throw "New-MgGroup no devolvió objeto para $DisplayName" }
    if ($Group -is [array]) { $Group = $Group[0] }
    Write-Verbose "   -> Group created: $DisplayName"
    Add-LogEntry -Categoria "Info" -Mensaje "Grupo creado." -Detalle $DisplayName
    $manifiesto.Grupos += $DisplayName

    return $Group
}

function Add-EntraGoatGroupMember {
    param(
        [Parameter(Mandatory=$true)] [string]$GroupId,
        [Parameter(Mandatory=$true)] [string]$MemberId
    )

    Write-Verbose "[*] Adding member $MemberId to group $GroupId..."

    $ExistingMembers = Get-MgGroupMember -GroupId $GroupId -All -ErrorAction SilentlyContinue
    foreach ($member in $ExistingMembers) {
        if ($member.Id -eq $MemberId) {
            Write-Verbose "   -> Member already present"
            return
        }
    }

    $MemberParams = @{
        "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$MemberId"
    }
    New-MgGroupMemberByRef -GroupId $GroupId -BodyParameter $MemberParams -ErrorAction Stop
    Add-LogEntry -Categoria "Info" -Mensaje "Miembro añadido al grupo." -Detalle @{
        Grupo   = $GroupId
        Miembro = $MemberId
    }
}

# ============================================================
# CREACIÓN DE USUARIOS DEL ESCENARIO
# ============================================================
Write-Verbose "[*] Creating users..."

$usuariosCreados = @{}
foreach ($u in $def.Usuarios) {
    $upn = $u.upn -replace '\{tenant\}', $TenantDomain
    $user = New-EntraGoatUser `
        -DisplayName       $u.displayName `
        -UserPrincipalName $upn `
        -MailNickname      $u.mailNickname `
        -Password          $u.password `
        -Department        $u.department `
        -JobTitle          $u.jobTitle
    $usuariosCreados[$u.upn] = $user
}

# ============================================================
# CREACIÓN DE GRUPOS DEL ESCENARIO
# ============================================================
Write-Verbose "[*] Creating groups..."

$gruposCreados = @{}
foreach ($g in $def.Grupos) {
    $group = New-EntraGoatGroup `
        -DisplayName  $g.displayName `
        -Description  $g.description `
        -MailNickname $g.mailNickname
    $gruposCreados[$g.displayName] = $group
}

# ============================================================
# CREACIÓN DE APLICACIONES DEL ESCENARIO
# ============================================================
Write-Verbose "[*] Creating applications..."

$aplicacionesCreadas = @{}
foreach ($a in $def.Aplicaciones) {
    $result = New-EntraGoatApplication `
        -DisplayName    $a.displayName `
        -Description    $a.description `
        -SignInAudience $a.signInAudience `
        -RedirectUris   $a.redirectUris
    $aplicacionesCreadas[$a.displayName] = $result
}

# ============================================================
# RELACIONES DEL ESCENARIO
# ============================================================
Write-Verbose "[*] Creating relations..."

foreach ($r in $def.Relaciones) {
    switch ($r.tipo) {
        "membresia" {
            $uKey = $r.usuario
            $gKey = $r.grupo
            if (-not $usuariosCreados.ContainsKey($uKey)) {
                Add-LogEntry -Categoria "Warning" -Mensaje "Usuario no encontrado para membresía." -Detalle $uKey
                continue
            }
            if (-not $gruposCreados.ContainsKey($gKey)) {
                Add-LogEntry -Categoria "Warning" -Mensaje "Grupo no encontrado para membresía." -Detalle $gKey
                continue
            }
            Add-EntraGoatGroupMember -GroupId $gruposCreados[$gKey].Id -MemberId $usuariosCreados[$uKey].Id
        }
        default {
            Add-LogEntry -Categoria "Warning" -Mensaje "Tipo de relación no soportado." -Detalle $r.tipo
        }
    }
}

# ============================================================
# VULNERABILIDAD (OPCIONAL)
# ============================================================
if ($def.Vulnerabilidad -and -not $SinVulnerabilidad) {
    Write-Host ""
    Write-LabInfo "El escenario declara la vulnerabilidad: $($def.Vulnerabilidad)"
    $resp = Read-Host "¿Aplicar la vulnerabilidad? (SI/N)"
    if ($resp -eq "SI") {
        try {
            $vuln = Get-LabVulnerabilidad -Nombre $def.Vulnerabilidad
            $contexto = @{
                TenantDomain      = $TenantDomain
                Usuarios          = $usuariosCreados
                Grupos            = $gruposCreados
                Aplicaciones      = $aplicacionesCreadas
                Manifiesto        = $manifiesto
            }
            $resultado = Invoke-LabVulnerabilidad -Vulnerabilidad $vuln -Contexto $contexto
            Add-LogEntry -Categoria "Info" -Mensaje "Vulnerabilidad aplicada." -Detalle @{
                Nombre     = $vuln.nombre
                Tipo       = $vuln.tipo
                Resultado  = $resultado
            }
            if (-not $manifiesto.Contains('Vulnerabilidades')) {
                $manifiesto['Vulnerabilidades'] = @()
            }
            $manifiesto['Vulnerabilidades'] += [pscustomobject]@{
                nombre          = $vuln.nombre
                tipo            = $vuln.tipo
                parametros      = $vuln.parametros
                objetosAfectados = $resultado
            }
        } catch {
            Add-LogEntry -Categoria "Error" -Mensaje "No se pudo aplicar la vulnerabilidad." -Detalle @{
                Vulnerabilidad = $def.Vulnerabilidad
                Error          = $_.Exception.Message
            }
        }
    } else {
        Write-LabInfo "Vulnerabilidad omitida por el usuario."
    }
} elseif ($SinVulnerabilidad -and $def.Vulnerabilidad) {
    Write-LabInfo "Vulnerabilidad omitida por parámetro -SinVulnerabilidad."
}

# ============================================================
# VERIFICACIÓN FINAL
# ============================================================
Write-Verbose "[*] Running final verification..."

$AllChecks = @()
foreach ($u in $def.Usuarios) {
    $upn = $u.upn -replace '\{tenant\}', $TenantDomain
    $exists = Get-MgUser -Filter "userPrincipalName eq '$upn'" -ErrorAction SilentlyContinue
    $AllChecks += [bool]$exists
}
foreach ($g in $def.Grupos) {
    $exists = Get-MgGroup -Filter "displayName eq '$($g.displayName)'" -ErrorAction SilentlyContinue
    $AllChecks += [bool]$exists
}

$SetupSuccessful = -not ($AllChecks -contains $false)
if ($SetupSuccessful) { Write-Verbose "[+] Final verification passed" }
else {
    Write-Verbose "[-] Final verification failed"
    Add-LogEntry -Categoria "Warning" -Mensaje "Verificación final con fallos." -Detalle "Algunos checks no se superaron."
}

# ============================================================
# RESUMEN EN PANTALLA
# ============================================================
Write-Host ""
if ($SetupSuccessful) {
    Write-LabOk "Escenario '$Escenario' configurado correctamente"
} else {
    Write-LabError "Fallo al configurar el escenario '$Escenario'."
}

Write-Host ""
Write-Host "--- Resumen del escenario ---" -ForegroundColor Cyan
Write-Host "  Usuarios     : $($manifiesto.Usuarios.Count)"
Write-Host "  Grupos       : $($manifiesto.Grupos.Count)"
Write-Host "  Aplicaciones : $($manifiesto.Aplicaciones.Count)"
Write-Host "  SPs          : $($manifiesto.ServicePrincipals.Count)"
if ($manifiesto.Contains('Vulnerabilidades')) {
    Write-Host "  Vulnerabilidades aplicadas: $($manifiesto.Vulnerabilidades.Count)"
}
Write-Host ""

if ($manifiesto.Usuarios.Count -gt 0) {
    Write-Host "Credenciales de usuarios del escenario:" -ForegroundColor Yellow
    foreach ($u in $def.Usuarios) {
        $upn = $u.upn -replace '\{tenant\}', $TenantDomain
        Write-Host "  $upn / $($u.password)" -ForegroundColor Gray
    }
    Write-Host ""
}

# ============================================================
# GUARDADO DEL MANIFIESTO Y LOG
# ============================================================
$manifiestoPath = Get-LabManifiestoPath

if (Save-LabManifiesto -Manifiesto $manifiesto -Path $manifiestoPath) {
    Add-LogEntry -Categoria "Info" -Mensaje "Manifiesto guardado correctamente." -Detalle $manifiestoPath
} else {
    Add-LogEntry -Categoria "Error" -Mensaje "No se pudo guardar el manifiesto." -Detalle $manifiestoPath
}

$logPath = Join-Path $PSScriptRoot "log_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"

try {
    $log | Export-Csv -Path $logPath -NoTypeInformation -Encoding UTF8
} catch {
    Write-LabError "No se pudo guardar el log en $logPath : $($_.Exception.Message)"
}

$errores = ($log | Where-Object Categoria -eq "Error").Count
$avisos  = ($log | Where-Object Categoria -eq "Warning").Count
$total   = $log.Count

Write-Host ""
Write-Host "--- Resumen de ejecucion ---" -ForegroundColor Cyan
Write-Host "Eventos totales: $total"
Write-Host "Avisos:          $avisos" -ForegroundColor Yellow
Write-Host "Errores:         $errores" -ForegroundColor Red
Write-Host "Log completo:    $logPath" -ForegroundColor Gray
Write-Host "Manifiesto:      $manifiestoPath" -ForegroundColor Gray
Write-Host ""