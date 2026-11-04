<#
.SYNOPSIS
    Creación automática de entorno de laboratorio en Entra ID basada en escenarios.
.DESCRIPTION
    Lee las definiciones de escenario de escenarios/escenario/ y las
    vulnerabilidades de escenarios/vulnerab/. Muestra al usuario los escenarios
    disponibles, crea los objetos del escenario elegido y, si el escenario declara
    una vulnerabilidad, pregunta si aplicarla. Todo lo creado (incluida la
    vulnerabilidad aplicada) se registra en el manifiesto para que clean_up.ps1
    pueda revertirlo.

    GESTIÓN DE CONTRASEÑAS:
    Los JSON de escenario NO contienen contraseñas. Cada escenario tiene una
    semilla local en escenarios/.secrets/<escenario>.seed (fuera de Git). La
    contraseña de cada usuario se deriva de forma determinista con
    HMAC-SHA256(semilla, UPN). Al final de la creación se muestran las
    contraseñas UNA SOLA VEZ; no se guardan en el manifiesto ni en el JSON.

    Con -DryRun no se crea nada en Entra ID: solo se muestra un resumen de lo que
    se crearía y se pide confirmación. Útil para validar escenarios antes de
    ejecutarlos de verdad. En -DryRun no se deriva ninguna contraseña ni se
    requiere semilla.

    La sesión de Microsoft Graph la gestiona menu.ps1. Este script NO conecta ni
    desconecta; solo verifica que hay sesión activa y falla con código 1 si no la hay
    (salvo en -DryRun, donde la sesión es opcional).
.PARAMETER Escenario
    Nombre del escenario a crear (sin extensión). Si se omite, se muestra un menú.
.PARAMETER SinVulnerabilidad
    Si se especifica, no aplica la vulnerabilidad aunque el escenario la declare.
.PARAMETER DryRun
    Si se especifica, no crea nada en Entra ID. Solo muestra el resumen de lo que
    se crearía y pide confirmación. No requiere sesión de Graph ni semilla.
.NOTES
    Depende de lib_ui.ps1, lib_manifiesto.ps1 y lib_escenarios.ps1.
#>
#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$Escenario = $null,

    [Parameter(Mandatory = $false)]
    [switch]$SinVulnerabilidad,

    [Parameter(Mandatory = $false)]
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================
# CARGA DE LIBRERÍAS
# ============================================================
. (Join-Path $PSScriptRoot 'lib_ui.ps1')
. (Join-Path $PSScriptRoot 'lib_manifiesto.ps1')
. (Join-Path $PSScriptRoot 'lib_escenarios.ps1')

# ============================================================
# VERIFICACIÓN DE SESIÓN
# ============================================================
# En -DryRun la sesión es opcional: no se va a escribir nada.
if (-not $DryRun) {
    if (-not (Get-MgContext -ErrorAction SilentlyContinue)) {
        Write-LabError 'No hay sesión de Graph activa. Ejecuta este script desde menu.ps1.'
        exit 1
    }
} else {
    if (Get-MgContext -ErrorAction SilentlyContinue) {
        Write-LabInfo 'Modo -DryRun: sesión de Graph detectada pero NO se usará para escribir.'
    } else {
        Write-LabInfo 'Modo -DryRun: sin sesión de Graph. Solo se mostrará el resumen.'
    }
}

# ============================================================
# FASE 0: LOG Y MANIFIESTO
# ============================================================
$log = [System.Collections.Generic.List[object]]::new()

function Add-LogEntry {
    <#
    .SYNOPSIS
        Añade una entrada al log interno y la muestra por consola.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Categoria,

        [Parameter(Mandatory = $true)]
        [string]$Mensaje,

        [Parameter(Mandatory = $false)]
        [object]$Detalle = $null
    )

    $log.Add([pscustomobject]@{
        Timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Categoria = $Categoria
        Mensaje   = $Mensaje
        Detalle   = $Detalle
    })

    switch ($Categoria) {
        'Error'   { Write-LabError $Mensaje }
        'Warning' { Write-LabWarn  $Mensaje }
        default   { Write-LabInfo  $Mensaje }
    }
}

$manifiesto = New-LabManifiestoVacio

# ============================================================
# GESTIÓN DE SEMILLA Y DERIVACIÓN DE CONTRASEÑAS
# ============================================================
# La semilla vive en escenarios/.secrets/<escenario>.seed, fuera de Git.
# De ella se derivan contraseñas deterministas por usuario.

function Get-LabSecretsDir {
    <#
    .SYNOPSIS
        Devuelve la ruta de la carpeta de secretos locales (fuera de Git).
    #>
    $escenariosRoot = Split-Path -Path (Get-LabEscenariosPath) -Parent
    return (Join-Path $escenariosRoot '.secrets')
}

function Get-LabSeedPath {
    <#
    .SYNOPSIS
        Devuelve la ruta del fichero de semilla para un escenario concreto.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$NombreEscenario
    )
    return (Join-Path (Get-LabSecretsDir) "$NombreEscenario.seed")
}

function Get-LabSeed {
    <#
    .SYNOPSIS
        Obtiene la semilla de un escenario. Si no existe, la genera y la guarda.
    .DESCRIPTION
        La semilla es un array de 32 bytes aleatorios criptográficamente seguros,
        almacenado en Base64. Se guarda con permisos restrictivos si el sistema
        lo permite.
    .OUTPUTS
        Byte[] con la semilla.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$NombreEscenario
    )

    $seedPath = Get-LabSeedPath -NombreEscenario $NombreEscenario
    $seedDir  = Split-Path -Path $seedPath -Parent

    if (-not (Test-Path -Path $seedDir)) {
        $null = New-Item -ItemType Directory -Path $seedDir -Force
    }

    if (Test-Path -Path $seedPath) {
        $b64 = (Get-Content -Path $seedPath -Raw -Encoding UTF8).Trim()
        return [Convert]::FromBase64String($b64)
    }

    # Generar nueva semilla
    $bytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($bytes)
    } finally {
        $rng.Dispose()
    }

    $b64 = [Convert]::ToBase64String($bytes)
    Set-Content -Path $seedPath -Value $b64 -Encoding UTF8 -Force

    # Intentar restringir permisos (solo en Windows con ACL)
    try {
        if ($IsWindows -or $PSVersionTable.PSEdition -eq 'Desktop') {
            $acl = Get-Acl -Path $seedPath
            $acl.SetAccessRuleProtection($true, $false)
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                [System.Security.Principal.WindowsIdentity]::GetCurrent().Name,
                'FullControl',
                'Allow'
            )
            $acl.SetAccessRule($rule)
            Set-Acl -Path $seedPath -AclObject $acl
        }
    } catch {
        Write-LabWarn "No se pudieron restringir los permisos de $seedPath : $($_.Exception.Message)"
    }

    Write-LabInfo "Semilla generada para el escenario '$NombreEscenario' en $seedPath"
    return $bytes
}

function New-LabPasswordFromSeed {
    <#
    .SYNOPSIS
        Deriva una contraseña determinista a partir de la semilla y el UPN.
    .DESCRIPTION
        Usa HMAC-SHA256(semilla, UPN) y construye una contraseña que cumple
        la política de complejidad de Entra ID: mayúscula, minúscula, dígito
        y símbolo, longitud 20.
    .OUTPUTS
        String con la contraseña derivada.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Semilla,

        [Parameter(Mandatory = $true)]
        [string]$Upn
    )

    $hmac = New-Object System.Security.Cryptography.HMACSHA256
    try {
        $hmac.Key = $Semilla
        $hash = $hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Upn.ToLowerInvariant()))
    } finally {
        $hmac.Dispose()
    }

    # Base64 sin caracteres problemáticos, truncado a 16 y sufijo de complejidad
    $b64 = [Convert]::ToBase64String($hash)
    $core = ($b64 -replace '[^A-Za-z0-9]', '').Substring(0, 16)
    return "$core!Aa1"
}

# ============================================================
# INFORMACIÓN DEL TENANT
# ============================================================
$TenantDomain = $null
$context = $null

if (-not $DryRun) {
    Write-Verbose '[*] Obteniendo información del tenant...'
    try {
        $Organization = Get-MgOrganization -ErrorAction Stop
        $TenantDomain = ($Organization.VerifiedDomains | Where-Object IsDefault).Name
        $context = Get-MgContext
        $manifiesto.TenantId     = $context.TenantId
        $manifiesto.TenantDomain = $TenantDomain
        Add-LogEntry -Categoria 'Info' -Mensaje 'Información del tenant obtenida.' -Detalle @{
            Tenant = $TenantDomain
            Id     = $context.TenantId
        }
    } catch {
        Add-LogEntry -Categoria 'Error' -Mensaje 'No se pudo obtener información del tenant.' -Detalle $_.Exception.Message
        exit 1
    }
} else {
    # En DryRun intentamos obtener el dominio si hay sesión; si no, usamos placeholder.
    if (Get-MgContext -ErrorAction SilentlyContinue) {
        try {
            $Organization = Get-MgOrganization -ErrorAction Stop
            $TenantDomain = ($Organization.VerifiedDomains | Where-Object IsDefault).Name
            $manifiesto.TenantDomain = $TenantDomain
        } catch {
            $TenantDomain = '{tenant}'
            Write-LabWarn 'No se pudo obtener el dominio del tenant. Se usará {tenant} en el resumen.'
        }
    } else {
        $TenantDomain = '{tenant}'
        Write-LabWarn 'Sin sesión: se usará {tenant} como placeholder en el resumen.'
    }
}

# ============================================================
# SELECCIÓN DE ESCENARIO
# ============================================================
$disponibles = Get-LabEscenariosDisponibles
if ($disponibles.Count -eq 0) {
    Write-LabError 'No hay escenarios en la carpeta escenarios/escenario/.'
    exit 1
}

if (-not $Escenario) {
    Show-LabHeader -Titulo 'SELECCION DE ESCENARIO'
    Write-Host 'Escenarios disponibles:' -ForegroundColor Cyan
    for ($i = 0; $i -lt $disponibles.Count; $i++) {
        Write-Host ('  [{0}] {1}' -f $i, $disponibles[$i])
    }
    Write-Host ''
    $sel = Read-Host 'Selecciona un escenario'
    if (-not ($sel -match '^\d+$') -or [int]$sel -ge $disponibles.Count) {
        Write-LabError 'Selección inválida.'
        exit 1
    }
    $Escenario = $disponibles[[int]$sel]
}

Write-LabInfo "Escenario seleccionado: $Escenario"

try {
    $def = Get-LabEscenario -Nombre $Escenario
    Add-LogEntry -Categoria 'Info' -Mensaje 'Escenario cargado.' -Detalle $Escenario
} catch {
    Add-LogEntry -Categoria 'Error' -Mensaje 'No se pudo cargar el escenario.' -Detalle @{
        Escenario = $Escenario
        Error     = $_.Exception.Message
    }
    exit 1
}

# ============================================================
# FASE PREVIA: RESUMEN Y CONFIRMACIÓN
# ============================================================
$vulnDef = $null
if ($def.Vulnerabilidad -and -not $SinVulnerabilidad) {
    try {
        $vulnDef = Get-LabVulnerabilidad -Nombre $def.Vulnerabilidad
    } catch {
        Add-LogEntry -Categoria 'Error' -Mensaje 'No se pudo cargar la vulnerabilidad declarada.' -Detalle @{
            Vulnerabilidad = $def.Vulnerabilidad
            Error          = $_.Exception.Message
        }
        exit 1
    }
}

Show-LabHeader -Titulo ('RESUMEN DEL ESCENARIO: ' + $Escenario)

if ($DryRun) {
    Write-Host '*** MODO SIMULACION (-DryRun): NO se creara nada en Entra ID ***' -ForegroundColor Yellow
    Write-Host ''
}

Write-Host "Descripcion: $($def.Descripcion)" -ForegroundColor Gray
Write-Host ''

Write-Host "Usuarios ($($def.Usuarios.Count)):" -ForegroundColor Cyan
foreach ($u in $def.Usuarios) {
    $upn = $u.upn -replace '\{tenant\}', $TenantDomain
    Write-Host ('  - {0} <{1}> ({2} / {3})' -f $u.displayName, $upn, $u.department, $u.jobTitle) -ForegroundColor Gray
}
Write-Host ''

Write-Host "Grupos ($($def.Grupos.Count)):" -ForegroundColor Cyan
foreach ($g in $def.Grupos) {
    Write-Host ('  - {0}' -f $g.displayName) -ForegroundColor Gray
}
Write-Host ''

Write-Host "Aplicaciones ($($def.Aplicaciones.Count)):" -ForegroundColor Cyan
foreach ($a in $def.Aplicaciones) {
    Write-Host ('  - {0}' -f $a.displayName) -ForegroundColor Gray
}
Write-Host ''

Write-Host "Relaciones ($($def.Relaciones.Count)):" -ForegroundColor Cyan
foreach ($r in $def.Relaciones) {
    switch ($r.tipo) {
        'membresia' {
            $upnRel = $r.usuario -replace '\{tenant\}', $TenantDomain
            Write-Host ('  - membresia: {0} -> {1}' -f $upnRel, $r.grupo) -ForegroundColor Gray
        }
        default {
            Write-Host ('  - {0}: {1}' -f $r.tipo, ($r | ConvertTo-Json -Compress)) -ForegroundColor Gray
        }
    }
}
Write-Host ''

if ($vulnDef) {
    Write-Host 'Vulnerabilidad declarada:' -ForegroundColor Cyan
    Write-Host ('  - {0} ({1})' -f $vulnDef.Nombre, $vulnDef.Tipo) -ForegroundColor Gray
    Write-Host ('    Parametros: {0}' -f ($vulnDef.Parametros | ConvertTo-Json -Compress)) -ForegroundColor Gray
    if ($vulnDef.RequiereLicencia) {
        Write-Host ('    Requiere licencia: {0}' -f $vulnDef.RequiereLicencia) -ForegroundColor Gray
    }
} elseif ($SinVulnerabilidad -and $def.Vulnerabilidad) {
    Write-Host 'Vulnerabilidad declarada pero OMITIDA por -SinVulnerabilidad.' -ForegroundColor Yellow
} else {
    Write-Host 'Sin vulnerabilidad declarada (entorno benigno).' -ForegroundColor Gray
}
Write-Host ''

# Aviso de contraseñas (solo si se va a crear de verdad)
if (-not $DryRun -and $def.Usuarios.Count -gt 0) {
    Write-Host 'GESTION DE CONTRASEÑAS:' -ForegroundColor Yellow
    Write-Host '  Las contraseñas se derivan de la semilla local del escenario.' -ForegroundColor Yellow
    Write-Host '  Se mostraran UNA SOLA VEZ al finalizar. Anotalas.' -ForegroundColor Yellow
    Write-Host ''
}

# ============================================================
# CONFIRMACIÓN
# ============================================================
if ($DryRun) {
    Write-Host 'Esto es solo una simulacion. No se creara nada.' -ForegroundColor Yellow
    Write-Host 'Para crear de verdad, ejecuta este script SIN -DryRun.' -ForegroundColor Yellow
    Write-Host ''
    $resp = Read-Host '¿Quieres continuar en modo simulacion? (SI/N)'
    if ($resp -ne 'SI') {
        Write-LabInfo 'Operación cancelada por el usuario.'
        exit 0
    }
    Write-Host ''
    Write-LabOk 'Simulación completada. No se ha modificado Entra ID.'
    exit 0
} else {
    Write-Host '¿Crear este escenario en Entra ID?' -ForegroundColor Yellow
    $resp = Read-Host "Escribe 'SI' para confirmar"
    if ($resp -ne 'SI') {
        Write-LabInfo 'Operación cancelada por el usuario.'
        exit 0
    }
}

# ============================================================
# OBTENCIÓN DE LA SEMILLA Y DERIVACIÓN DE CONTRASEÑAS
# ============================================================
$semilla = Get-LabSeed -NombreEscenario $Escenario

$passwordsDerivadas = @{}
foreach ($u in $def.Usuarios) {
    $upn = $u.upn -replace '\{tenant\}', $TenantDomain
    $passwordsDerivadas[$upn] = New-LabPasswordFromSeed -Semilla $semilla -Upn $upn
}

# ============================================================
# FUNCIONES AUXILIARES DE CREACIÓN
# ============================================================

function New-EntraGoatUser {
    <#
    .SYNOPSIS
        Crea o actualiza un usuario en Entra ID con la contraseña indicada.
    #>
    param(
        [Parameter(Mandatory = $true)] [string]$DisplayName,
        [Parameter(Mandatory = $true)] [string]$UserPrincipalName,
        [Parameter(Mandatory = $true)] [string]$MailNickname,
        [Parameter(Mandatory = $true)] [string]$Password,
        [Parameter(Mandatory = $false)] [string]$Department = '',
        [Parameter(Mandatory = $false)] [string]$JobTitle = ''
    )

    Write-Verbose "   -> $DisplayName : $UserPrincipalName"
    $ExistingUser = Get-MgUser -Filter "userPrincipalName eq '$UserPrincipalName'" -ErrorAction SilentlyContinue

    if ($ExistingUser) {
        if ($ExistingUser -is [array]) { $ExistingUser = $ExistingUser[0] }
        $User = $ExistingUser
        Write-Verbose '      EXISTS (using existing)'
        $passwordProfile = @{
            Password                      = $Password
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
                Password                      = $Password
            }
        }
        if ($Department) { $UserParams.Department = $Department }
        if ($JobTitle)   { $UserParams.JobTitle   = $JobTitle }

        $User = New-MgUser @UserParams -ErrorAction Stop
        if ($null -eq $User) { throw "New-MgUser no devolvió objeto para $UserPrincipalName" }
        if ($User -is [array]) { $User = $User[0] }
        Write-Verbose '      CREATED'
        Add-LogEntry -Categoria 'Info' -Mensaje 'Usuario creado.' -Detalle $UserPrincipalName
        $manifiesto.Usuarios += $UserPrincipalName
    }

    return $User
}

function New-EntraGoatApplication {
    <#
    .SYNOPSIS
        Crea o reutiliza una aplicación y su service principal.
    #>
    param(
        [Parameter(Mandatory = $true)] [string]$DisplayName,
        [Parameter(Mandatory = $true)] [string]$Description,
        [Parameter(Mandatory = $false)] [string]$SignInAudience = 'AzureADMyOrg',
        [Parameter(Mandatory = $false)] [array]$RedirectUris = @('https://hr-analytics.contoso.com/callback'),
        [Parameter(Mandatory = $false)] [array]$Tags = @('WindowsAzureActiveDirectoryIntegratedApp')
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
        Add-LogEntry -Categoria 'Info' -Mensaje 'Aplicación creada.' -Detalle $DisplayName
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
        Write-Verbose '   -> Service principal exists'
        $CurrentTags = $null
        if ($SP.PSObject.Properties['Tags']) { $CurrentTags = $SP.Tags }
        if (-not ($CurrentTags -contains 'WindowsAzureActiveDirectoryIntegratedApp')) {
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
        Write-Verbose '   -> Service principal created'
        Add-LogEntry -Categoria 'Info' -Mensaje 'Service Principal creado.' -Detalle $SP.Id
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
    <#
    .SYNOPSIS
        Crea o reutiliza un grupo de seguridad.
    #>
    param(
        [Parameter(Mandatory = $true)] [string]$DisplayName,
        [Parameter(Mandatory = $false)] [string]$Description = '',
        [Parameter(Mandatory = $false)] [string]$MailNickname = ''
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
    Add-LogEntry -Categoria 'Info' -Mensaje 'Grupo creado.' -Detalle $DisplayName
    $manifiesto.Grupos += $DisplayName

    return $Group
}

function Add-EntraGoatGroupMember {
    <#
    .SYNOPSIS
        Añade un miembro a un grupo si no lo está ya.
    #>
    param(
        [Parameter(Mandatory = $true)] [string]$GroupId,
        [Parameter(Mandatory = $true)] [string]$MemberId
    )

    Write-Verbose "[*] Adding member $MemberId to group $GroupId..."

    $ExistingMembers = Get-MgGroupMember -GroupId $GroupId -All -ErrorAction SilentlyContinue
    foreach ($member in $ExistingMembers) {
        if ($member.Id -eq $MemberId) {
            Write-Verbose '   -> Member already present'
            return
        }
    }

    $MemberParams = @{
        '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$MemberId"
    }
    New-MgGroupMemberByRef -GroupId $GroupId -BodyParameter $MemberParams -ErrorAction Stop
    Add-LogEntry -Categoria 'Info' -Mensaje 'Miembro añadido al grupo.' -Detalle @{
        Grupo   = $GroupId
        Miembro = $MemberId
    }
}

# ============================================================
# CREACIÓN DE USUARIOS DEL ESCENARIO
# ============================================================
Write-Verbose '[*] Creating users...'

$usuariosCreados = @{}
foreach ($u in $def.Usuarios) {
    $upn = $u.upn -replace '\{tenant\}', $TenantDomain
    $pwd = $passwordsDerivadas[$upn]
    $user = New-EntraGoatUser `
        -DisplayName       $u.displayName `
        -UserPrincipalName $upn `
        -MailNickname      $u.mailNickname `
        -Password          $pwd `
        -Department        $u.department `
        -JobTitle          $u.jobTitle
    $usuariosCreados[$u.upn] = $user
}

# ============================================================
# CREACIÓN DE GRUPOS DEL ESCENARIO
# ============================================================
Write-Verbose '[*] Creating groups...'

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
Write-Verbose '[*] Creating applications...'

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
Write-Verbose '[*] Creating relations...'

foreach ($r in $def.Relaciones) {
    switch ($r.tipo) {
        'membresia' {
            $uKey = $r.usuario
            $gKey = $r.grupo
            if (-not $usuariosCreados.ContainsKey($uKey)) {
                Add-LogEntry -Categoria 'Warning' -Mensaje 'Usuario no encontrado para membresía.' -Detalle $uKey
                continue
            }
            if (-not $gruposCreados.ContainsKey($gKey)) {
                Add-LogEntry -Categoria 'Warning' -Mensaje 'Grupo no encontrado para membresía.' -Detalle $gKey
                continue
            }
            Add-EntraGoatGroupMember -GroupId $gruposCreados[$gKey].Id -MemberId $usuariosCreados[$uKey].Id
        }
        default {
            Add-LogEntry -Categoria 'Warning' -Mensaje 'Tipo de relación no soportado.' -Detalle $r.tipo
        }
    }
}

# ============================================================
# VULNERABILIDAD (OPCIONAL)
# ============================================================
if ($vulnDef) {
    try {
        $contexto = @{
            TenantDomain = $TenantDomain
            Usuarios     = $usuariosCreados
            Grupos       = $gruposCreados
            Aplicaciones = $aplicacionesCreadas
            Manifiesto   = $manifiesto
        }
        $resultado = Invoke-LabVulnerabilidad -Vulnerabilidad $vulnDef -Contexto $contexto
        Add-LogEntry -Categoria 'Info' -Mensaje 'Vulnerabilidad aplicada.' -Detalle @{
            Nombre    = $vulnDef.Nombre
            Tipo      = $vulnDef.Tipo
            Resultado = $resultado
        }
        if (-not $manifiesto.Contains('Vulnerabilidades')) {
            $manifiesto['Vulnerabilidades'] = @()
        }
        $manifiesto['Vulnerabilidades'] += [pscustomobject]@{
            nombre           = $vulnDef.Nombre
            tipo             = $vulnDef.Tipo
            parametros       = $vulnDef.Parametros
            objetosAfectados = $resultado
        }
    } catch {
        Add-LogEntry -Categoria 'Error' -Mensaje 'No se pudo aplicar la vulnerabilidad.' -Detalle @{
            Vulnerabilidad = $vulnDef.Nombre
            Error          = $_.Exception.Message
        }
    }
} elseif ($SinVulnerabilidad -and $def.Vulnerabilidad) {
    Write-LabInfo 'Vulnerabilidad omitida por parámetro -SinVulnerabilidad.'
}

# ============================================================
# VERIFICACIÓN FINAL
# ============================================================
Write-Verbose '[*] Running final verification...'

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
if ($SetupSuccessful) {
    Write-Verbose '[+] Final verification passed'
} else {
    Write-Verbose '[-] Final verification failed'
    Add-LogEntry -Categoria 'Warning' -Mensaje 'Verificación final con fallos.' -Detalle 'Algunos checks no se superaron.'
}

# ============================================================
# RESUMEN EN PANTALLA
# ============================================================
Write-Host ''
if ($SetupSuccessful) {
    Write-LabOk "Escenario '$Escenario' configurado correctamente"
} else {
    Write-LabError "Fallo al configurar el escenario '$Escenario'."
}

Write-Host ''
Write-Host '--- Resumen del escenario ---' -ForegroundColor Cyan
Write-Host "  Usuarios     : $($manifiesto.Usuarios.Count)"
Write-Host "  Grupos       : $($manifiesto.Grupos.Count)"
Write-Host "  Aplicaciones : $($manifiesto.Aplicaciones.Count)"
Write-Host "  SPs          : $($manifiesto.ServicePrincipals.Count)"
if ($manifiesto.Contains('Vulnerabilidades')) {
    Write-Host "  Vulnerabilidades aplicadas: $($manifiesto.Vulnerabilidades.Count)"
}
Write-Host ''

# Contraseñas derivadas: mostrar UNA SOLA VEZ
if ($manifiesto.Usuarios.Count -gt 0) {
    Write-Host '=== CONTRASEÑAS DERIVADAS (MOSTRAR UNA SOLA VEZ) ===' -ForegroundColor Yellow
    Write-Host 'Anota estas credenciales. No se guardan en el manifiesto ni en el JSON.' -ForegroundColor Yellow
    Write-Host 'Para reproducirlas, conserva la semilla local del escenario.' -ForegroundColor Yellow
    Write-Host ''
    foreach ($upn in $passwordsDerivadas.Keys) {
        Write-Host ("  {0} / {1}" -f $upn, $passwordsDerivadas[$upn]) -ForegroundColor Gray
    }
    Write-Host ''
}

# ============================================================
# GUARDADO DEL MANIFIESTO Y LOG
# ============================================================
$manifiestoPath = Get-LabManifiestoPath

if (Save-LabManifiesto -Manifiesto $manifiesto -Path $manifiestoPath) {
    Add-LogEntry -Categoria 'Info' -Mensaje 'Manifiesto guardado correctamente.' -Detalle $manifiestoPath
} else {
    Add-LogEntry -Categoria 'Error' -Mensaje 'No se pudo guardar el manifiesto.' -Detalle $manifiestoPath
}

$logPath = Join-Path $PSScriptRoot "log_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"

try {
    $log | Export-Csv -Path $logPath -NoTypeInformation -Encoding UTF8
} catch {
    Write-LabError "No se pudo guardar el log en $logPath : $($_.Exception.Message)"
}

$errores = ($log | Where-Object Categoria -eq 'Error').Count
$avisos  = ($log | Where-Object Categoria -eq 'Warning').Count
$total   = $log.Count

Write-Host ''
Write-Host '--- Resumen de ejecucion ---' -ForegroundColor Cyan
Write-Host "Eventos totales: $total"
Write-Host "Avisos:          $avisos" -ForegroundColor Yellow
Write-Host "Errores:         $errores" -ForegroundColor Red
Write-Host "Log completo:    $logPath" -ForegroundColor Gray
Write-Host "Manifiesto:      $manifiestoPath" -ForegroundColor Gray
Write-Host ''