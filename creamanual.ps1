<#
.SYNOPSIS
    Creación manual (personalizada) de entorno de laboratorio en Entra ID (Free).
.DESCRIPTION
    Permite al usuario elegir qué objetos crear (usuarios, grupos,
    aplicaciones y service principals) y los va construyendo
    interactivamente. Al final guarda el manifiesto para que
    clean_up.ps1 pueda eliminarlos después.

    La sesión de Microsoft Graph la gestiona menu.ps1. Este script NO
    conecta ni desconecta; solo verifica que hay sesión activa y falla
    con código 1 si no la hay.
.NOTES
    Depende de lib_ui.ps1, lib_log.ps1 y lib_manifiesto.ps1.
    Guardar este fichero como UTF-8 con BOM para compatibilidad con PS 5.1.
#>
#Requires -Version 5.1

[CmdletBinding()]
param()

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
# MANIFIESTO
# ============================================================
$manifiesto = New-LabManifiestoVacio

# ============================================================
# INFORMACIÓN DEL TENANT
# ============================================================
Show-LabBanner "Obteniendo informacion del tenant"

try {
    $Organization = Get-MgOrganization -ErrorAction Stop
    $TenantDomain = ($Organization.VerifiedDomains | Where-Object { $_.IsDefault -eq $true }).Name
    if (-not $TenantDomain) { $TenantDomain = $Organization.VerifiedDomains[0].Name }

    $context = Get-MgContext
    $manifiesto.TenantId     = $context.TenantId
    $manifiesto.TenantDomain = $TenantDomain

    Add-LabLogEntry -Categoria "Info" -Mensaje "Informacion del tenant obtenida." -Detalle @{
        Tenant = $TenantDomain
        Id     = $context.TenantId
    }
} catch {
    Add-LabLogEntry -Categoria "Error" -Mensaje "No se pudo obtener informacion del tenant." -Detalle $_.Exception.Message
    exit 1
}

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
        Pide los datos de un usuario, los previsualiza y, si el usuario
        confirma, lo crea. Lo añade al escenario y al manifiesto.
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
    $rol        = Read-Host "  Rol (opcional, ej: Comercial, Administrador)"
    if ([string]::IsNullOrWhiteSpace($rol)) { $rol = "" }

    $existing = Get-MgUser -Filter "userPrincipalName eq '$upn'" -ErrorAction SilentlyContinue
    if ($existing) {
        if ($existing -is [array]) { $existing = $existing[0] }
    }

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

    Write-Host ""
    Write-Host "--- Simulacion de creacion de usuario ---" -ForegroundColor Yellow
    Write-Host "  Accion        : $(if ($existing) { 'REUTILIZAR (ya existe)' } else { 'CREAR' })"
    Write-Host "  DisplayName   : $displayName"
    Write-Host "  UPN           : $upn"
    Write-Host "  MailNickname  : $($params.MailNickname)"
    Write-Host "  Department    : $(if ($department) { $department } else { '(vacio)' })"
    Write-Host "  JobTitle      : $(if ($jobTitle) { $jobTitle } else { '(vacio)' })"
    Write-Host "  Rol           : $(if ($rol) { $rol } else { '(vacio)' })"
    Write-Host "  Password      : ********"
    Write-Host ""

    if (-not (Read-LabConfirm "¿Aplicar estos datos?")) {
        Write-LabWarn "Creacion cancelada."
        return $null
    }

    if ($existing) {
        Write-LabWarn "El usuario $upn ya existe. Se reutiliza."
        $user = $existing
        if ($manifiesto.Usuarios -notcontains $upn) { $manifiesto.Usuarios += $upn }

        $passwordProfile = @{
            Password = $password
            ForceChangePasswordNextSignIn = $false
        }
        Update-MgUser -UserId $user.Id -PasswordProfile $passwordProfile -ErrorAction Stop
    } else {
        $user = New-MgUser @params -ErrorAction Stop
        Add-LabLogEntry -Categoria "Info" -Mensaje "Usuario creado." -Detalle $upn
        $manifiesto.Usuarios += $upn
    }

    $Escenario.Usuarios.Add([pscustomobject]@{
        Id                = $user.Id
        DisplayName       = $displayName
        UserPrincipalName = $upn
        Password          = $password
        Rol               = $rol
    })

    Write-LabOk "Usuario listo: $upn"
    return $user
}

function New-GrupoInteractivo {
    <#
    .SYNOPSIS
        Pide los datos de un grupo de seguridad, los previsualiza y lo crea.
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

    $existing = Get-MgGroup -Filter "displayName eq '$($displayName -replace "'", "''")'" -ErrorAction SilentlyContinue
    if ($existing) {
        if ($existing -is [array]) { $existing = $existing[0] }
    }

    Write-Host ""
    Write-Host "--- Simulacion de creacion de grupo ---" -ForegroundColor Yellow
    Write-Host "  Accion        : $(if ($existing) { 'REUTILIZAR (ya existe)' } else { 'CREAR' })"
    Write-Host "  DisplayName   : $displayName"
    Write-Host "  Description   : $(if ($description) { $description } else { '(vacio)' })"
    Write-Host "  MailNickname  : $mailNick"
    Write-Host ""

    if (-not (Read-LabConfirm "¿Aplicar estos datos?")) {
        Write-LabWarn "Creacion cancelada."
        return $null
    }

    if ($existing) {
        Write-LabWarn "El grupo $displayName ya existe. Se reutiliza."
        $group = $existing
        if ($manifiesto.Grupos -notcontains $displayName) { $manifiesto.Grupos += $displayName }
    } else {
        $group = New-MgGroup -DisplayName $displayName -Description $description -MailNickname $mailNick -MailEnabled:$false -SecurityEnabled:$true -ErrorAction Stop
        Add-LabLogEntry -Categoria "Info" -Mensaje "Grupo creado." -Detalle $displayName
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
        Pide los datos de una aplicación, la previsualiza y crea su SP.
    #>
    param()

    Show-LabBanner "Nueva aplicacion"

    $displayName = Read-Host "  DisplayName"
    if ([string]::IsNullOrWhiteSpace($displayName)) {
        Write-LabWarn "DisplayName vacio. Cancelando."
        return $null
    }

    $description = Read-Host "  Description (opcional)"

    $existing = Get-MgApplication -Filter "displayName eq '$($displayName -replace "'", "''")'" -ErrorAction SilentlyContinue
    if ($existing) {
        if ($existing -is [array]) { $existing = $existing[0] }
    }

    Write-Host ""
    Write-Host "--- Simulacion de creacion de aplicacion ---" -ForegroundColor Yellow
    Write-Host "  Accion        : $(if ($existing) { 'REUTILIZAR (ya existe)' } else { 'CREAR' })"
    Write-Host "  DisplayName   : $displayName"
    Write-Host "  Description   : $(if ($description) { $description } else { '(vacio)' })"
    Write-Host "  (Se creara tambien su Service Principal asociado)" -ForegroundColor DarkGray
    Write-Host ""

    if (-not (Read-LabConfirm "¿Aplicar estos datos?")) {
        Write-LabWarn "Creacion cancelada."
        return $null
    }

    if ($existing) {
        Write-LabWarn "La aplicacion $displayName ya existe. Se reutiliza."
        $app = $existing
        if ($manifiesto.Aplicaciones -notcontains $displayName) { $manifiesto.Aplicaciones += $displayName }
    } else {
        $app = New-MgApplication -DisplayName $displayName -Description $description -ErrorAction Stop
        Add-LabLogEntry -Categoria "Info" -Mensaje "Aplicacion creada." -Detalle $displayName
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
        Add-LabLogEntry -Categoria "Info" -Mensaje "Service Principal creado." -Detalle $sp.Id
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
            Tipo       = "PropietarioSP"
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

function Show-EstadoEscenario {
    Write-Host "--- Estado actual del escenario ---" -ForegroundColor Yellow
    Write-Host "  Usuarios     : $($Escenario.Usuarios.Count)"
    Write-Host "  Grupos       : $($Escenario.Grupos.Count)"
    Write-Host "  Aplicaciones : $($Escenario.Aplicaciones.Count)"
    Write-Host "  Relaciones   : $($Escenario.Relaciones.Count)"
    Write-Host ""
}

function Show-ListadoEscenario {
    Show-LabBanner "Elementos del escenario"

    Write-Host "Usuarios:" -ForegroundColor Cyan
    if ($Escenario.Usuarios.Count) {
        $Escenario.Usuarios | ForEach-Object { Write-Host "  - $($_.DisplayName) <$($_.UserPrincipalName)> [Rol: $($_.Rol)]" }
    } else {
        Write-Host "  (ninguno)" -ForegroundColor DarkGray
    }
    Write-Host ""

    Write-Host "Grupos:" -ForegroundColor Cyan
    if ($Escenario.Grupos.Count) {
        $Escenario.Grupos | ForEach-Object { Write-Host "  - $($_.DisplayName)" }
    } else {
        Write-Host "  (ninguno)" -ForegroundColor DarkGray
    }
    Write-Host ""

    Write-Host "Aplicaciones:" -ForegroundColor Cyan
    if ($Escenario.Aplicaciones.Count) {
        $Escenario.Aplicaciones | ForEach-Object { Write-Host "  - $($_.DisplayName) (SP: $($_.ServicePrincipal))" }
    } else {
        Write-Host "  (ninguna)" -ForegroundColor DarkGray
    }
    Write-Host ""

    Write-Host "Relaciones:" -ForegroundColor Cyan
    if ($Escenario.Relaciones.Count) {
        $Escenario.Relaciones | ForEach-Object { Write-Host "  - $($_.Tipo): $($_.UsuarioUpn) -> $($_.GrupoNombre)$($_.AppNombre)" }
    } else {
        Write-Host "  (ninguna)" -ForegroundColor DarkGray
    }
}

# ============================================================
# BUCLE PRINCIPAL
# ============================================================
try {
    $salirConstruccion = $false

    while (-not $salirConstruccion) {
        Show-LabHeader -Titulo "CREACION MANUAL - CONSTRUCCION DEL ESCENARIO"

        Show-EstadoEscenario

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

        switch ($op.ToUpper()) {
            "1" { $null = New-UsuarioInteractivo -TenantDomain $TenantDomain }
            "2" { $null = New-GrupoInteractivo }
            "3" { $null = New-AppInteractiva }
            "4" { Add-MiembroInteractivo }
            "5" { Add-OwnerSPInteractivo }
            "L" {
                Show-ListadoEscenario
                Wait-LabKey
            }
            "S" {
                $hayObjetos = ($Escenario.Usuarios.Count -gt 0 -or
                               $Escenario.Grupos.Count -gt 0 -or
                               $Escenario.Aplicaciones.Count -gt 0)

                if (-not $hayObjetos) {
                    $salirConstruccion = $true
                    Write-LabInfo "Saliendo sin objetos creados."
                    break
                }

                Write-LabWarn "Hay objetos creados sin registrar en el manifiesto."
                Write-Host "Si sales sin guardar, clean_up.ps1 no podra eliminarlos." -ForegroundColor Yellow
                $resp = Read-Host "¿Quieres guardar el manifiesto antes de salir? (SI/N)"

                if ($resp -eq "SI") {
                    $manifiestoPath = Get-LabManifiestoPath
                    if (Save-LabManifiesto -Manifiesto $manifiesto -Path $manifiestoPath) {
                        Add-LabLogEntry -Categoria "Info" -Mensaje "Manifiesto guardado (salida parcial)." -Detalle $manifiestoPath
                        Write-LabOk "Manifiesto guardado: $manifiestoPath"
                    } else {
                        Add-LabLogEntry -Categoria "Error" -Mensaje "No se pudo guardar el manifiesto." -Detalle $manifiestoPath
                    }
                } else {
                    Write-LabWarn "Saliendo sin guardar manifiesto."
                }

                $salirConstruccion = $true
            }
            "G" {
                if ($Escenario.Usuarios.Count -eq 0 -and $Escenario.Grupos.Count -eq 0 -and $Escenario.Aplicaciones.Count -eq 0) {
                    Write-LabWarn "No hay nada que guardar. Sal del menu con [S] si quieres salir."
                } else {
                    if (Read-LabConfirm "¿Guardar manifiesto y finalizar la creacion manual?") {
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
} catch {
    Add-LabLogEntry -Categoria "Error" -Mensaje "Error fatal en la creacion manual." -Detalle @{
        Mensaje = $_.Exception.Message
        Linea   = $_.InvocationInfo.ScriptLineNumber
    }
    Write-Host ""
    Write-Host "Pulsa Enter para volver al menu..." -ForegroundColor Gray
    $null = Read-Host
    exit 1
}

# ============================================================
# GUARDADO DEL MANIFIESTO Y LOG
# ============================================================
Show-LabBanner "Finalizando creacion manual"

$manifiestoPath = Get-LabManifiestoPath

if ($Escenario.Usuarios.Count -gt 0 -or $Escenario.Grupos.Count -gt 0 -or $Escenario.Aplicaciones.Count -gt 0) {
    if (Save-LabManifiesto -Manifiesto $manifiesto -Path $manifiestoPath) {
        Add-LabLogEntry -Categoria "Info" -Mensaje "Manifiesto guardado correctamente." -Detalle $manifiestoPath
        Write-LabOk "Manifiesto guardado: $manifiestoPath"
    } else {
        Add-LabLogEntry -Categoria "Error" -Mensaje "No se pudo guardar el manifiesto." -Detalle $manifiestoPath
    }

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
            Write-Host "  $($u.UserPrincipalName) / $($u.Password) [Rol: $($u.Rol)]" -ForegroundColor Gray
        }
        Write-Host ""
    }
} else {
    Write-LabWarn "No se creo ningun objeto. No se guarda manifiesto."
}

$logPath = Save-LabLog -Prefijo "log_creamanual"
$resumen = Get-LabLogSummary

if ($logPath) {
    Write-Host "Log completo: $logPath" -ForegroundColor Gray
}

Write-Host ""
Write-Host "--- Resumen de ejecucion ---" -ForegroundColor Cyan
Write-Host "Eventos totales: $($resumen.Total)"
Write-Host "Avisos:          $($resumen.Avisos)" -ForegroundColor Yellow
Write-Host "Errores:         $($resumen.Errores)" -ForegroundColor Red
Write-Host ""
Write-LabOk "Creacion manual finalizada."