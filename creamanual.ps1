<#
.SYNOPSIS
    Creación personalizada de entorno de laboratorio en Entra ID (Free).
.DESCRIPTION
    Permite al usuario elegir qué objetos crear (usuarios, grupos,
    aplicaciones y service principals) y los va construyendo
    interactivamente. Al final guarda el manifiesto para que
    clean_up.ps1 pueda eliminarlos después.

    GESTIÓN DE CONTRASEÑAS:
    Para cada usuario, el operador puede:
      - Introducir la contraseña manualmente (Read-Host -AsSecureString),
      - o dejar que se derive automáticamente de la semilla local del
        escenario manual (HMAC-SHA256(semilla, UPN)).
    En ningún caso se guarda la contraseña en el manifiesto ni se imprime
    en el resumen final. Si se elige generación automática, la contraseña
    se muestra UNA SOLA VEZ en el momento de crearla.

    La sesión de Microsoft Graph la gestiona menu.ps1. Este script NO
    conecta ni desconecta; solo verifica que hay sesión activa y falla
    con código 1 si no la hay.

    NOTA: es un esqueleto. La creación de objetos está implementada,
    pero las decisiones de escenario (qué usuarios, qué grupos, qué
    vulnerabilidad inyectar) son tuyas. Aquí solo se demuestra el flujo.
.NOTES
    Depende de lib_ui.ps1 y lib_manifiesto.ps1.
#>
#Requires -Version 5.1
#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.Applications, Microsoft.Graph.Users, Microsoft.Graph.Groups, Microsoft.Graph.Identity.DirectoryManagement

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================
# CARGA DE LIBRERÍAS
# ============================================================
. (Join-Path $PSScriptRoot 'lib_ui.ps1')
. (Join-Path $PSScriptRoot 'lib_manifiesto.ps1')
. (Join-Path $PSScriptRoot 'lib_escenarios.ps1')

# ============================================================
# VERIFICACIÓN DE SESIÓN (gestionada por el menú)
# ============================================================
if (-not (Get-MgContext -ErrorAction SilentlyContinue)) {
    Write-LabError 'No hay sesión de Graph activa. Ejecuta este script desde menu.ps1.'
    exit 1
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
# La semilla vive en escenarios/.secrets/<nombre>.seed, fuera de Git.
# En creamanual se usa una semilla por sesión de creación manual.

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
        Devuelve la ruta del fichero de semilla para un nombre dado.
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

    $bytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($bytes)
    } finally {
        $rng.Dispose()
    }

    $b64 = [Convert]::ToBase64String($bytes)
    Set-Content -Path $seedPath -Value $b64 -Encoding UTF8 -Force

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

    Write-LabInfo "Semilla generada para '$NombreEscenario' en $seedPath"
    return $bytes
}

function New-LabPasswordFromSeed {
    <#
    .SYNOPSIS
        Deriva una contraseña determinista a partir de la semilla y el UPN.
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

    $b64 = [Convert]::ToBase64String($hash)
    $core = ($b64 -replace '[^A-Za-z0-9]', '').Substring(0, 16)
    return "$core!Aa1"
}

function ConvertTo-LabPlainText {
    <#
    .SYNOPSIS
        Convierte una SecureString a texto plano solo en memoria, para pasarla a Graph.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [System.Security.SecureString]$SecureString
    )

    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

# ============================================================
# INFORMACIÓN DEL TENANT
# ============================================================
Write-LabBanner 'Obteniendo informacion del tenant'

try {
    $Organization = Get-MgOrganization -ErrorAction Stop
    $TenantDomain = ($Organization.VerifiedDomains | Where-Object IsDefault).Name

    $context = Get-MgContext
    $manifiesto.TenantId     = $context.TenantId
    $manifiesto.TenantDomain = $TenantDomain

    Add-LogEntry -Categoria 'Info' -Mensaje 'Informacion del tenant obtenida.' -Detalle @{
        Tenant = $TenantDomain
        Id     = $context.TenantId
    }
} catch {
    Add-LogEntry -Categoria 'Error' -Mensaje 'No se pudo obtener informacion del tenant.' -Detalle $_.Exception.Message
    exit 1
}

# ============================================================
# SEMILLA DE LA SESIÓN MANUAL
# ============================================================
# Cada sesión de creación manual tiene su propia semilla, para que las
# contraseñas derivadas sean reproducibles conservando el fichero.
$nombreSemillaManual = 'manual_' + (Get-Date -Format 'yyyyMMdd_HHmmss')
$semillaManual = Get-LabSeed -NombreEscenario $nombreSemillaManual

Write-LabInfo "Semilla de esta sesion manual: $nombreSemillaManual"
Write-LabInfo 'Conserva esta semilla para reproducir las contrasenas generadas automaticamente.'
Write-Host ''

# ============================================================
# ESTADO LOCAL DEL ESCENARIO
# ============================================================
$Escenario = [ordered]@{
    Usuarios     = [System.Collections.Generic.List[object]]::new()
    Grupos       = [System.Collections.Generic.List[object]]::new()
    Aplicaciones = [System.Collections.Generic.List[object]]::new()
    Relaciones   = [System.Collections.Generic.List[object]]::new()
}

# ============================================================
# FUNCIONES AUXILIARES DE CREACIÓN
# ============================================================

function New-UsuarioInteractivo {
    <#
    .SYNOPSIS
        Pide los datos de un usuario y lo crea. Permite introducir la
        contraseña manualmente o generarla automáticamente desde la semilla.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$TenantDomain
    )

    Show-LabBanner 'Nuevo usuario'

    $displayName = Read-Host '  DisplayName'
    if ([string]::IsNullOrWhiteSpace($displayName)) {
        Write-LabWarn 'DisplayName vacio. Cancelando.'
        return $null
    }

    $nick = $displayName.ToLower() -replace '[^a-z0-9]', '.'
    $upnDefault = "$nick@$TenantDomain"
    $upn = Read-Host "  UPN [$upnDefault]"
    if ([string]::IsNullOrWhiteSpace($upn)) { $upn = $upnDefault }

    # --- Contraseña: manual o automática desde semilla ---
    $passwordPlain = $null
    $passwordGeneradaAuto = $false

    Write-Host ''
    Write-Host '  Contrasena:' -ForegroundColor Cyan
    Write-Host '    [1] Introducir manualmente (no se muestra en pantalla)'
    Write-Host '    [2] Generar automaticamente desde la semilla'
    $opPwd = Read-Host '  Opcion [1/2]'

    switch ($opPwd) {
        '2' {
            $passwordPlain = New-LabPasswordFromSeed -Semilla $semillaManual -Upn $upn
            $passwordGeneradaAuto = $true
            Write-Host ''
            Write-Host '  Contrasena generada (MOSTRAR UNA SOLA VEZ):' -ForegroundColor Yellow
            Write-Host "    $passwordPlain" -ForegroundColor Gray
            Write-Host '  Anotala. Se puede reproducir conservando la semilla.' -ForegroundColor Yellow
            Write-Host ''
        }
        default {
            $secure = Read-Host '  Password' -AsSecureString
            if ($null -eq $secure -or $secure.Length -eq 0) {
                Write-LabWarn 'Password vacia. Cancelando.'
                return $null
            }
            $passwordPlain = ConvertTo-LabPlainText -SecureString $secure
        }
    }

    $department = Read-Host '  Department (opcional)'
    $jobTitle   = Read-Host '  JobTitle (opcional)'

    # ¿Existe ya?
    $existing = Get-MgUser -Filter "userPrincipalName eq '$upn'" -ErrorAction SilentlyContinue
    if ($existing) {
        if ($existing -is [array]) { $existing = $existing[0] }
        Write-LabWarn "El usuario $upn ya existe. Se reutiliza y se actualiza su contrasena."
        $user = $existing
        if ($manifiesto.Usuarios -notcontains $upn) { $manifiesto.Usuarios += $upn }

        $passwordProfile = @{
            Password                      = $passwordPlain
            ForceChangePasswordNextSignIn = $false
        }
        Update-MgUser -UserId $user.Id -PasswordProfile $passwordProfile -ErrorAction Stop
    } else {
        $params = @{
            DisplayName       = $displayName
            UserPrincipalName = $upn
            MailNickname      = ($displayName -replace '[^a-zA-Z0-9]', '')
            AccountEnabled    = $true
            PasswordProfile   = @{
                ForceChangePasswordNextSignIn = $false
                Password                      = $passwordPlain
            }
        }
        if ($department) { $params.Department = $department }
        if ($jobTitle)   { $params.JobTitle   = $jobTitle }

        $user = New-MgUser @params -ErrorAction Stop
        if ($null -eq $user) {
            Write-LabError "New-MgUser no devolvio objeto para $upn."
            return $null
        }
        if ($user -is [array]) { $user = $user[0] }
        Add-LogEntry -Categoria 'Info' -Mensaje 'Usuario creado.' -Detalle $upn
        $manifiesto.Usuarios += $upn
    }

    $Escenario.Usuarios.Add([pscustomobject]@{
        Id                = $user.Id
        DisplayName       = $displayName
        UserPrincipalName = $upn
        PasswordGenerada  = $passwordGeneradaAuto
    })

    Write-LabOk "Usuario listo: $upn"
    return $user
}

function New-GrupoInteractivo {
    <#
    .SYNOPSIS
        Pide los datos de un grupo de seguridad y lo crea.
    #>
    param()

    Show-LabBanner 'Nuevo grupo'

    $displayName = Read-Host '  DisplayName'
    if ([string]::IsNullOrWhiteSpace($displayName)) {
        Write-LabWarn 'DisplayName vacio. Cancelando.'
        return $null
    }

    $description = Read-Host '  Description (opcional)'
    $mailNick = $displayName -replace '[^a-zA-Z0-9]', ''

    $existing = Get-MgGroup -Filter "displayName eq '$displayName'" -ErrorAction SilentlyContinue
    if ($existing) {
        if ($existing -is [array]) { $existing = $existing[0] }
        Write-LabWarn "El grupo $displayName ya existe. Se reutiliza."
        $group = $existing
        if ($manifiesto.Grupos -notcontains $displayName) { $manifiesto.Grupos += $displayName }
    } else {
        # NOTA: IsAssignableToRole omitido (requiere P1/P2)
        $group = New-MgGroup -DisplayName $displayName -Description $description -MailNickname $mailNick -MailEnabled:$false -SecurityEnabled:$true -ErrorAction Stop
        if ($null -eq $group) {
            Write-LabError "New-MgGroup no devolvio objeto para $displayName."
            return $null
        }
        if ($group -is [array]) { $group = $group[0] }
        Add-LogEntry -Categoria 'Info' -Mensaje 'Grupo creado.' -Detalle $displayName
        $manifiesto.Grupos += $displayName
    }

    $Escenario.Grupos.Add([pscustomobject]@{
        Id          = $group.Id
        DisplayName = $displayName
    })

    Write-LabOk "Grupo listo: $displayName"
    return $group
}

function New-AppInteractiva {
    <#
    .SYNOPSIS
        Pide los datos de una aplicación y crea también su service principal.
    #>
    param()

    Show-LabBanner 'Nueva aplicacion'

    $displayName = Read-Host '  DisplayName'
    if ([string]::IsNullOrWhiteSpace($displayName)) {
        Write-LabWarn 'DisplayName vacio. Cancelando.'
        return $null
    }

    $description = Read-Host '  Description (opcional)'

    $existing = Get-MgApplication -Filter "displayName eq '$displayName'" -ErrorAction SilentlyContinue
    if ($existing) {
        if ($existing -is [array]) { $existing = $existing[0] }
        Write-LabWarn "La aplicacion $displayName ya existe. Se reutiliza."
        $app = $existing
        if ($manifiesto.Aplicaciones -notcontains $displayName) { $manifiesto.Aplicaciones += $displayName }
    } else {
        $app = New-MgApplication -DisplayName $displayName -Description $description -ErrorAction Stop
        if ($null -eq $app) {
            Write-LabError "New-MgApplication no devolvio objeto para $displayName."
            return $null
        }
        if ($app -is [array]) { $app = $app[0] }
        Add-LogEntry -Categoria 'Info' -Mensaje 'Aplicacion creada.' -Detalle $displayName
        $manifiesto.Aplicaciones += $displayName
    }

    $appId = $app.AppId
    if ($appId -is [array]) { $appId = $appId[0] }
    $appId = $appId.ToString()

    $existingSP = Get-MgServicePrincipal -Filter "appId eq '$appId'" -ErrorAction SilentlyContinue
    if ($existingSP) {
        if ($existingSP -is [array]) { $existingSP = $existingSP[0] }
        $sp = $existingSP
        if ($manifiesto.ServicePrincipals -notcontains $sp.Id) { $manifiesto.ServicePrincipals += $sp.Id }
    } else {
        $sp = New-MgServicePrincipal -AppId $appId -DisplayName $displayName -ErrorAction Stop
        if ($null -eq $sp) {
            Write-LabError "New-MgServicePrincipal no devolvio objeto para $displayName."
            return $null
        }
        if ($sp -is [array]) { $sp = $sp[0] }
        Add-LogEntry -Categoria 'Info' -Mensaje 'Service Principal creado.' -Detalle $sp.Id
        $manifiesto.ServicePrincipals += $sp.Id
    }

    $Escenario.Aplicaciones.Add([pscustomobject]@{
        Id               = $app.Id
        AppId            = $appId
        DisplayName      = $displayName
        ServicePrincipal = $sp.Id
    })

    Write-LabOk "Aplicacion y SP listos: $displayName"
    return $app
}

function Add-MiembroInteractivo {
    <#
    .SYNOPSIS
        Añade uno de los usuarios del escenario a uno de los grupos del escenario.
    #>
    param()

    if ($Escenario.Usuarios.Count -eq 0) {
        Write-LabWarn 'No hay usuarios en el escenario. Crea alguno primero.'
        return
    }
    if ($Escenario.Grupos.Count -eq 0) {
        Write-LabWarn 'No hay grupos en el escenario. Crea alguno primero.'
        return
    }

    Show-LabBanner 'Añadir miembro a grupo'

    Write-Host '  Usuarios disponibles:' -ForegroundColor Cyan
    for ($i = 0; $i -lt $Escenario.Usuarios.Count; $i++) {
        $u = $Escenario.Usuarios[$i]
        Write-Host ('    [{0}] {1} ({2})' -f $i, $u.DisplayName, $u.UserPrincipalName)
    }
    $selU = Read-Host '  Numero de usuario'
    if (-not ($selU -match '^\d+$') -or [int]$selU -ge $Escenario.Usuarios.Count) {
        Write-LabWarn 'Seleccion invalida.'
        return
    }
    $user = $Escenario.Usuarios[[int]$selU]

    Write-Host '  Grupos disponibles:' -ForegroundColor Cyan
    for ($i = 0; $i -lt $Escenario.Grupos.Count; $i++) {
        $g = $Escenario.Grupos[$i]
        Write-Host ('    [{0}] {1}' -f $i, $g.DisplayName)
    }
    $selG = Read-Host '  Numero de grupo'
    if (-not ($selG -match '^\d+$') -or [int]$selG -ge $Escenario.Grupos.Count) {
        Write-LabWarn 'Seleccion invalida.'
        return
    }
    $group = $Escenario.Grupos[[int]$selG]

    $body = @{ '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$($user.Id)" }
    try {
        New-MgGroupMemberByRef -GroupId $group.Id -BodyParameter $body -ErrorAction Stop
        $Escenario.Relaciones.Add([pscustomobject]@{
            Tipo        = 'MembresiaGrupo'
            GrupoId     = $group.Id
            GrupoNombre = $group.DisplayName
            UsuarioId   = $user.Id
            UsuarioUpn  = $user.UserPrincipalName
        })
        Write-LabOk "Añadido $($user.DisplayName) a $($group.DisplayName)"
    } catch {
        Write-LabError "No se pudo añadir el miembro: $($_.Exception.Message)"
    }
}

function Add-OwnerSPInteractivo {
    <#
    .SYNOPSIS
        Asigna un usuario del escenario como propietario de un SP del escenario.
    #>
    param()

    if ($Escenario.Usuarios.Count -eq 0 -or $Escenario.Aplicaciones.Count -eq 0) {
        Write-LabWarn 'Necesitas al menos un usuario y una aplicacion en el escenario.'
        return
    }

    Show-LabBanner 'Asignar propietario a un Service Principal'

    Write-Host '  Usuarios disponibles:' -ForegroundColor Cyan
    for ($i = 0; $i -lt $Escenario.Usuarios.Count; $i++) {
        $u = $Escenario.Usuarios[$i]
        Write-Host ('    [{0}] {1} ({2})' -f $i, $u.DisplayName, $u.UserPrincipalName)
    }
    $selU = Read-Host '  Numero de usuario'
    if (-not ($selU -match '^\d+$') -or [int]$selU -ge $Escenario.Usuarios.Count) {
        Write-LabWarn 'Seleccion invalida.'
        return
    }
    $user = $Escenario.Usuarios[[int]$selU]

    Write-Host '  Aplicaciones disponibles:' -ForegroundColor Cyan
    for ($i = 0; $i -lt $Escenario.Aplicaciones.Count; $i++) {
        $a = $Escenario.Aplicaciones[$i]
        Write-Host ('    [{0}] {1}' -f $i, $a.DisplayName)
    }
    $selA = Read-Host '  Numero de aplicacion'
    if (-not ($selA -match '^\d+$') -or [int]$selA -ge $Escenario.Aplicaciones.Count) {
        Write-LabWarn 'Seleccion invalida.'
        return
    }
    $app = $Escenario.Aplicaciones[[int]$selA]

    $body = @{ '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$($user.Id)" }
    try {
        New-MgServicePrincipalOwnerByRef -ServicePrincipalId $app.ServicePrincipal -BodyParameter $body -ErrorAction Stop
        $Escenario.Relaciones.Add([pscustomobject]@{
            Tipo       = 'PropietarioSP'
            SPId       = $app.ServicePrincipal
            AppNombre  = $app.DisplayName
            UsuarioId  = $user.Id
            UsuarioUpn = $user.UserPrincipalName
        })
        Write-LabOk "Propietario asignado: $($user.DisplayName) -> $($app.DisplayName)"
    } catch {
        Write-LabError "No se pudo asignar propietario: $($_.Exception.Message)"
    }
}

# ============================================================
# MENÚ DE CONSTRUCCIÓN DEL ESCENARIO
# ============================================================

$salirConstruccion = $false
while (-not $salirConstruccion) {
    Show-LabHeader -Titulo 'CREACION PERSONALIZADA - CONSTRUCCION DEL ESCENARIO'

    Write-Host '--- Estado actual del escenario ---' -ForegroundColor Yellow
    Write-Host "  Usuarios     : $($Escenario.Usuarios.Count)"
    Write-Host "  Grupos       : $($Escenario.Grupos.Count)"
    Write-Host "  Aplicaciones : $($Escenario.Aplicaciones.Count)"
    Write-Host "  Relaciones   : $($Escenario.Relaciones.Count)"
    Write-Host ''

    Write-Host '--- Añadir elementos ---' -ForegroundColor Cyan
    Write-Host '  [1] Nuevo usuario'
    Write-Host '  [2] Nuevo grupo'
    Write-Host '  [3] Nueva aplicacion (con SP)'
    Write-Host ''
    Write-Host '--- Añadir relaciones ---' -ForegroundColor Cyan
    Write-Host '  [4] Añadir miembro a grupo'
    Write-Host '  [5] Asignar propietario a un SP'
    Write-Host ''
    Write-Host '--- Listar ---' -ForegroundColor Cyan
    Write-Host '  [L] Listar elementos del escenario'
    Write-Host ''
    Write-Host '  [S] Salir SIN guardar manifiesto'
    Write-Host '  [G] Guardar manifiesto y finalizar'
    Write-Host ''

    $op = Read-Host 'Selecciona una opcion'

    switch ($op.ToUpper()) {
        '1' { $null = New-UsuarioInteractivo -TenantDomain $TenantDomain }
        '2' { $null = New-GrupoInteractivo }
        '3' { $null = New-AppInteractiva }
        '4' { Add-MiembroInteractivo }
        '5' { Add-OwnerSPInteractivo }
        'L' {
            Show-LabBanner 'Elementos del escenario'
            Write-Host 'Usuarios:' -ForegroundColor Cyan
            if ($Escenario.Usuarios.Count) {
                $Escenario.Usuarios | ForEach-Object { Write-Host "  - $($_.DisplayName) <$($_.UserPrincipalName)>" }
            } else {
                Write-Host '  (ninguno)' -ForegroundColor DarkGray
            }
            Write-Host ''
            Write-Host 'Grupos:' -ForegroundColor Cyan
            if ($Escenario.Grupos.Count) {
                $Escenario.Grupos | ForEach-Object { Write-Host "  - $($_.DisplayName)" }
            } else {
                Write-Host '  (ninguno)' -ForegroundColor DarkGray
            }
            Write-Host ''
            Write-Host 'Aplicaciones:' -ForegroundColor Cyan
            if ($Escenario.Aplicaciones.Count) {
                $Escenario.Aplicaciones | ForEach-Object { Write-Host "  - $($_.DisplayName) (SP: $($_.ServicePrincipal))" }
            } else {
                Write-Host '  (ninguna)' -ForegroundColor DarkGray
            }
            Write-Host ''
            Write-Host 'Relaciones:' -ForegroundColor Cyan
            if ($Escenario.Relaciones.Count) {
                $Escenario.Relaciones | ForEach-Object { Write-Host "  - $($_.Tipo): $($_.UsuarioUpn) -> $($_.GrupoNombre)$($_.AppNombre)" }
            } else {
                Write-Host '  (ninguna)' -ForegroundColor DarkGray
            }
            Wait-LabKey
        }
        'S' {
            if (Read-LabConfirm '¿Salir sin guardar el manifiesto? Los objetos creados quedaran sin registrar para cleanup.') {
                $salirConstruccion = $true
                Write-LabWarn 'Saliendo sin guardar manifiesto.'
            }
        }
        'G' {
            if ($Escenario.Usuarios.Count -eq 0 -and $Escenario.Grupos.Count -eq 0 -and $Escenario.Aplicaciones.Count -eq 0) {
                Write-LabWarn 'No hay nada que guardar. Sal del menu con [S] si quieres salir.'
            } else {
                if (Read-LabConfirm '¿Guardar manifiesto y finalizar la creacion personalizada?') {
                    $salirConstruccion = $true
                }
            }
        }
        default {
            Write-LabWarn 'Opcion no valida.'
            Start-Sleep -Seconds 1
        }
    }
}

# ============================================================
# GUARDADO DEL MANIFIESTO Y LOG
# ============================================================
Write-LabBanner 'Finalizando creacion personalizada'

$manifiestoPath = Get-LabManifiestoPath

if ($Escenario.Usuarios.Count -gt 0 -or $Escenario.Grupos.Count -gt 0 -or $Escenario.Aplicaciones.Count -gt 0) {
    if (Save-LabManifiesto -Manifiesto $manifiesto -Path $manifiestoPath) {
        Add-LogEntry -Categoria 'Info' -Mensaje 'Manifiesto guardado correctamente.' -Detalle $manifiestoPath
        Write-LabOk "Manifiesto guardado: $manifiestoPath"
    } else {
        Add-LogEntry -Categoria 'Error' -Mensaje 'No se pudo guardar el manifiesto.' -Detalle $manifiestoPath
    }

    # Resumen final SIN contraseñas
    Write-Host ''
    Write-Host '--- Resumen del escenario creado ---' -ForegroundColor Cyan
    Write-Host "  Usuarios     : $($Escenario.Usuarios.Count)"
    Write-Host "  Grupos       : $($Escenario.Grupos.Count)"
    Write-Host "  Aplicaciones : $($Escenario.Aplicaciones.Count)"
    Write-Host "  Relaciones   : $($Escenario.Relaciones.Count)"
    Write-Host ''

    if ($Escenario.Usuarios.Count -gt 0) {
        Write-Host 'Usuarios creados (sin contrasenas):' -ForegroundColor Yellow
        foreach ($u in $Escenario.Usuarios) {
            $nota = if ($u.PasswordGenerada) { ' [contrasena derivada de semilla]' } else { '' }
            Write-Host "  $($u.UserPrincipalName)$nota" -ForegroundColor Gray
        }
        Write-Host ''
        Write-Host 'Recuerda: las contrasenas no se guardan en disco ni en el manifiesto.' -ForegroundColor Yellow
        Write-Host "Semilla de esta sesion: $nombreSemillaManual" -ForegroundColor Yellow
        Write-Host 'Conservala para reproducir las contrasenas generadas automaticamente.' -ForegroundColor Yellow
        Write-Host ''
    }
} else {
    Write-LabWarn 'No se creo ningun objeto. No se guarda manifiesto.'
}

# Log
$logPath = Join-Path $PSScriptRoot "log_personalizada_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
try {
    $log | Export-Csv -Path $logPath -NoTypeInformation -Encoding UTF8
    Write-Host "Log completo: $logPath" -ForegroundColor Gray
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
Write-Host ''
Write-LabOk 'Creacion personalizada finalizada.'