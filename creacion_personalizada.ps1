<#
.SYNOPSIS
    Creación personalizada de entorno de laboratorio en Entra ID (Free).
.DESCRIPTION
    Permite al usuario elegir qué objetos crear (usuarios, grupos,
    aplicaciones y service principals) y los va construyendo
    interactivamente. Al final guarda el manifiesto para que
    clean_up.ps1 pueda eliminarlos después.

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
. (Join-Path $PSScriptRoot "lib_ui.ps1")
. (Join-Path $PSScriptRoot "lib_manifiesto.ps1")

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
Write-LabBanner "Obteniendo informacion del tenant"

try {
    $Organization = Get-MgOrganization -ErrorAction Stop
    $TenantDomain = ($Organization.VerifiedDomains | Where-Object IsDefault).Name

    $context = Get-MgContext
    $manifiesto.TenantId     = $context.TenantId
    $manifiesto.TenantDomain = $TenantDomain

    Add-LogEntry -Categoria "Info" -Mensaje "Informacion del tenant obtenida." -Detalle @{
        Tenant = $TenantDomain
        Id     = $context.TenantId
    }
} catch {
    Add-LogEntry -Categoria "Error" -Mensaje "No se pudo obtener informacion del tenant." -Detalle $_.Exception.Message
    exit 1
}

# ============================================================
# ESTADO LOCAL DEL ESCENARIO
# ============================================================
# Lo que el usuario va definiendo durante la sesión.
$Escenario = [ordered]@{
    Usuarios          = [System.Collections.Generic.List[object]]::new()
    Grupos            = [System.Collections.Generic.List[object]]::new()
    Aplicaciones      = [System.Collections.Generic.List[object]]::new()
    Relaciones        = [System.Collections.Generic.List[object]]::new()  # p.ej. membresías, owners
}

# ============================================================
# FUNCIONES AUXILIARES DE CREACIÓN
# ============================================================

function New-UsuarioInteractivo {
    <#
    .SYNOPSIS
        Pide los datos de un usuario y lo crea. Lo añade al escenario y al manifiesto.
    #>
    param([string]$TenantDomain)

    Show-LabBanner "Nuevo usuario"

    $displayName = Read-Host "  DisplayName"
    if ([string]::IsNullOrWhiteSpace($displayName)) {
        Write-LabWarn "DisplayName vacio. Cancelando."
        return $null
    }

    $nick = $displayName.ToLower() -replace '[^a-z0-9]', '.'
    $upnDefault = "$nick@$TenantDomain"
    $upn = Read-Host "  UPN [$upnDefault]"
    if ([string]::IsNullOrWhiteSpace($upn)) { $upn = $upnDefault }

    $password = Read-Host "  Password (visible)"
    if ([string]::IsNullOrWhiteSpace($password)) {
        Write-LabWarn "Password vacia. Cancelando."
        return $null
    }

    $department = Read-Host "  Department (opcional)"
    $jobTitle   = Read-Host "  JobTitle (opcional)"

    # ¿Existe ya?
    $existing = Get-MgUser -Filter "userPrincipalName eq '$upn'" -ErrorAction SilentlyContinue
    if ($existing) {
        if ($existing -is [array]) { $existing = $existing[0] }
        Write-LabWarn "El usuario $upn ya existe. Se reutiliza."
        $user = $existing
        if ($manifiesto.Usuarios -notcontains $upn) { $manifiesto.Usuarios += $upn }
    } else {
        $params = @{
            DisplayName       = $displayName
            UserPrincipalName = $upn
            MailNickname      = ($displayName -replace '[^a-zA-Z0-9]', '')
            AccountEnabled    = $true
            PasswordProfile   = @{
                ForceChangePasswordNextSignIn = $false
                Password = $password
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
        Add-LogEntry -Categoria "Info" -Mensaje "Usuario creado." -Detalle $upn
        $manifiesto.Usuarios += $upn
    }

    $Escenario.Usuarios.Add([pscustomobject]@{
        Id            = $user.Id
        DisplayName   = $displayName
        UserPrincipalName = $upn
        Password      = $password
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

    Show-LabBanner "Nuevo grupo"

    $displayName = Read-Host "  DisplayName"
    if ([string]::IsNullOrWhiteSpace($displayName)) {
        Write-LabWarn "DisplayName vacio. Cancelando."
        return $null
    }

    $description = Read-Host "  Description (opcional)"
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
        Add-LogEntry -Categoria "Info" -Mensaje "Grupo creado." -Detalle $displayName
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

    Show-LabBanner "Nueva aplicacion"

    $displayName = Read-Host "  DisplayName"
    if ([string]::IsNullOrWhiteSpace($displayName)) {
        Write-LabWarn "DisplayName vacio. Cancelando."
        return $null
    }

    $description = Read-Host "  Description (opcional)"

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
        Add-LogEntry -Categoria "Info" -Mensaje "Aplicacion creada." -Detalle $displayName
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
        Add-LogEntry -Categoria "Info" -Mensaje "Service Principal creado." -Detalle $sp.Id
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
        Write-LabWarn "No hay usuarios en el escenario. Crea alguno primero."
        return
    }
    if ($Escenario.Grupos.Count -eq 0) {
        Write-LabWarn "No hay grupos en el escenario. Crea alguno primero."
        return
    }

    Show-LabBanner "Añadir miembro a grupo"

    Write-Host "  Usuarios disponibles:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $Escenario.Usuarios.Count; $i++) {
        $u = $Escenario.Usuarios[$i]
        Write-Host ("    [{0}] {1} ({2})" -f $i, $u.DisplayName, $u.UserPrincipalName)
    }
    $selU = Read-Host "  Numero de usuario"
    if (-not ($selU -match '^\d+$') -or [int]$selU -ge $Escenario.Usuarios.Count) {
        Write-LabWarn "Seleccion invalida."
        return
    }
    $user = $Escenario.Usuarios[[int]$selU]

    Write-Host "  Grupos disponibles:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $Escenario.Grupos.Count; $i++) {
        $g = $Escenario.Grupos[$i]
        Write-Host ("    [{0}] {1}" -f $i, $g.DisplayName)
    }
    $selG = Read-Host "  Numero de grupo"
    if (-not ($selG -match '^\d+$') -or [int]$selG -ge $Escenario.Grupos.Count) {
        Write-LabWarn "Seleccion invalida."
        return
    }
    $group = $Escenario.Grupos[[int]$selG]

    $body = @{ "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$($user.Id)" }
    try {
        New-MgGroupMemberByRef -GroupId $group.Id -BodyParameter $body -ErrorAction Stop
        $Escenario.Relaciones.Add([pscustomobject]@{
            Tipo        = "MembresiaGrupo"
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
        Write-LabWarn "Necesitas al menos un usuario y una aplicacion en el escenario."
        return
    }

    Show-LabBanner "Asignar propietario a un Service Principal"

    Write-Host "  Usuarios disponibles:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $Escenario.Usuarios.Count; $i++) {
        $u = $Escenario.Usuarios[$i]
        Write-Host ("    [{0}] {1} ({2})" -f $i, $u.DisplayName, $u.UserPrincipalName)
    }
    $selU = Read-Host "  Numero de usuario"
    if (-not ($selU -match '^\d+$') -or [int]$selU -ge $Escenario.Usuarios.Count) {
        Write-LabWarn "Seleccion invalida."
        return
    }
    $user = $Escenario.Usuarios[[int]$selU]

    Write-Host "  Aplicaciones disponibles:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $Escenario.Aplicaciones.Count; $i++) {
        $a = $Escenario.Aplicaciones[$i]
        Write-Host ("    [{0}] {1}" -f $i, $a.DisplayName)
    }
    $selA = Read-Host "  Numero de aplicacion"
    if (-not ($selA -match '^\d+$') -or [int]$selA -ge $Escenario.Aplicaciones.Count) {
        Write-LabWarn "Seleccion invalida."
        return
    }
    $app = $Escenario.Aplicaciones[[int]$selA]

    $body = @{ "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$($user.Id)" }
    try {
        New-MgServicePrincipalOwnerByRef -ServicePrincipalId $app.ServicePrincipal -BodyParameter $body -ErrorAction Stop
        $Escenario.Relaciones.Add([pscustomobject]@{
            Tipo        = "PropietarioSP"
            SPId        = $app.ServicePrincipal
            AppNombre   = $app.DisplayName
            UsuarioId   = $user.Id
            UsuarioUpn  = $user.UserPrincipalName
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
    Show-LabHeader -Titulo "CREACION PERSONALIZADA - CONSTRUCCION DEL ESCENARIO"

    Write-Host "--- Estado actual del escenario ---" -ForegroundColor Yellow
    Write-Host "  Usuarios     : $($Escenario.Usuarios.Count)"
    Write-Host "  Grupos       : $($Escenario.Grupos.Count)"
    Write-Host "  Aplicaciones : $($Escenario.Aplicaciones.Count)"
    Write-Host "  Relaciones   : $($Escenario.Relaciones.Count)"
    Write-Host ""

    Write-Host "--- Añadir elementos ---" -ForegroundColor Cyan
    Write-Host "  [1] Nuevo usuario"
    Write-Host "  [2] Nuevo grupo"
    Write-Host "  [3] Nueva aplicacion (con SP)"
    Write-Host ""
    Write-Host "--- Añadir relaciones ---" -ForegroundColor Cyan
    Write-Host "  [4] Añadir miembro a grupo"
    Write-Host "  [5] Asignar propietario a un SP"
    Write-Host ""
    Write-Host "--- Listar ---" -ForegroundColor Cyan
    Write-Host "  [L] Listar elementos del escenario"
    Write-Host ""
    Write-Host "  [S] Salir SIN guardar manifiesto"
    Write-Host "  [G] Guardar manifiesto y finalizar"
    Write-Host ""

    $op = Read-Host "Selecciona una opcion"
    # Normalizar: Read-Host puede devolver $null en algunos hosts y
    # .ToUpper() lanzaría NullReferenceException con StrictMode.
    $op = if ($null -eq $op) { "" } else { $op.Trim() }

    switch ($op.ToUpper()) {
        "1" { $null = New-UsuarioInteractivo -TenantDomain $TenantDomain }
        "2" { $null = New-GrupoInteractivo }
        "3" { $null = New-AppInteractiva }
        "4" { Add-MiembroInteractivo }
        "5" { Add-OwnerSPInteractivo }
        "L" {
            Show-LabBanner "Elementos del escenario"
            Write-Host "Usuarios:" -ForegroundColor Cyan
            if ($Escenario.Usuarios.Count) { $Escenario.Usuarios | ForEach-Object { Write-Host "  - $($_.DisplayName) <$($_.UserPrincipalName)>" } } else { Write-Host "  (ninguno)" -ForegroundColor DarkGray }
            Write-Host ""
            Write-Host "Grupos:" -ForegroundColor Cyan
            if ($Escenario.Grupos.Count) { $Escenario.Grupos | ForEach-Object { Write-Host "  - $($_.DisplayName)" } } else { Write-Host "  (ninguno)" -ForegroundColor DarkGray }
            Write-Host ""
            Write-Host "Aplicaciones:" -ForegroundColor Cyan
            if ($Escenario.Aplicaciones.Count) { $Escenario.Aplicaciones | ForEach-Object { Write-Host "  - $($_.DisplayName) (SP: $($_.ServicePrincipal))" } } else { Write-Host "  (ninguna)" -ForegroundColor DarkGray }
            Write-Host ""
            Write-Host "Relaciones:" -ForegroundColor Cyan
            if ($Escenario.Relaciones.Count) { $Escenario.Relaciones | ForEach-Object { Write-Host "  - $($_.Tipo): $($_.UsuarioUpn) -> $($_.GrupoNombre)$($_.AppNombre)" } } else { Write-Host "  (ninguna)" -ForegroundColor DarkGray }
            Wait-LabKey
        }
        "S" {
            if (Read-LabConfirm "¿Salir sin guardar el manifiesto? Los objetos creados quedaran sin registrar para cleanup.") {
                $salirConstruccion = $true
                Write-LabWarn "Saliendo sin guardar manifiesto."
            }
        }
        "G" {
            if ($Escenario.Usuarios.Count -eq 0 -and $Escenario.Grupos.Count -eq 0 -and $Escenario.Aplicaciones.Count -eq 0) {
                Write-LabWarn "No hay nada que guardar. Sal del menu con [S] si quieres salir."
            } else {
                if (Read-LabConfirm "¿Guardar manifiesto y finalizar la creacion personalizada?") {
                    $salirConstruccion = $true
                }
            }
        }
        default {
            Write-LabWarn "Opcion no valida."
            Start-Sleep -Seconds 1
        }
    }
}

# ============================================================
# GUARDADO DEL MANIFIESTO Y LOG
# ============================================================
Write-LabBanner "Finalizando creacion personalizada"

$manifiestoPath = Get-LabManifiestoPath

if ($Escenario.Usuarios.Count -gt 0 -or $Escenario.Grupos.Count -gt 0 -or $Escenario.Aplicaciones.Count -gt 0) {
    if (Save-LabManifiesto -Manifiesto $manifiesto -Path $manifiestoPath) {
        Add-LogEntry -Categoria "Info" -Mensaje "Manifiesto guardado correctamente." -Detalle $manifiestoPath
        Write-LabOk "Manifiesto guardado: $manifiestoPath"
    } else {
        Add-LogEntry -Categoria "Error" -Mensaje "No se pudo guardar el manifiesto." -Detalle $manifiestoPath
    }

    # Resumen final
    Write-Host ""
    Write-Host "--- Resumen del escenario creado ---" -ForegroundColor Cyan
    Write-Host "  Usuarios     : $($Escenario.Usuarios.Count)"
    Write-Host "  Grupos       : $($Escenario.Grupos.Count)"
    Write-Host "  Aplicaciones : $($Escenario.Aplicaciones.Count)"
    Write-Host "  Relaciones   : $($Escenario.Relaciones.Count)"
    Write-Host ""

    if ($Escenario.Usuarios.Count -gt 0) {
        Write-Host "Credenciales:" -ForegroundColor Yellow
        foreach ($u in $Escenario.Usuarios) {
            Write-Host "  $($u.UserPrincipalName) / $($u.Password)" -ForegroundColor Gray
        }
        Write-Host ""
    }
} else {
    Write-LabWarn "No se creo ningun objeto. No se guarda manifiesto."
}

# Log
$logPath = Join-Path $PSScriptRoot "log_personalizada_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
try {
    $log | Export-Csv -Path $logPath -NoTypeInformation -Encoding UTF8
    Write-Host "Log completo: $logPath" -ForegroundColor Gray
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
Write-Host ""
Write-LabOk "Creacion personalizada finalizada."