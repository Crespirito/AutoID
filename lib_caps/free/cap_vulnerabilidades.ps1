<#
.SYNOPSIS
    Capacidad: Vulnerabilidades aplicadas sobre objetos existentes.
.DESCRIPTION
    Aplica vulnerabilidades declaradas en la sección 'vulnerabilidades'
    del escenario. Cada vulnerabilidad tiene un 'tipo' y unos 'parametros'
    que indican qué modificar.

    TIPOS SOPORTADOS:
      - ServicePrincipalOwner: añade un usuario como owner de un SP.
      - GroupOwner: añade un usuario como owner de un grupo.
      - ApplicationSecret: añade un client secret a una app.
      - PimEligibleRole: asigna un rol elegible PIM a un usuario (requiere P2).

    SEGURIDAD DE PREEXISTENTES:
    Si el objeto objetivo (SP, grupo, app, usuario) es preexistente
    (snapshot pre-lab), no se aplica la vulnerabilidad y se marca
    'preexistente'. Eso evita modificar objetos que no son del laboratorio.

    DEPENDENCIAS: Aplicaciones, Grupos, Usuarios (según el tipo).

    NIVEL: Free para ServicePrincipalOwner, GroupOwner y ApplicationSecret.
    P2 para PimEligibleRole.
#>

$Capacidad = @{
    Nombre      = 'Vulnerabilidades'
    SeccionJson = 'vulnerabilidades'
    Alias       = @('vulnerabilidades','vulnerability')
    Nivel       = 'Free'
    DependeDe   = @('Aplicaciones','Grupos','Usuarios')
    PermisosApp = @('Application.ReadWrite.All','AppRoleAssignment.ReadWrite.All','Group.ReadWrite.All','RoleManagement.ReadWrite.Directory')

    TestDisponible = {
        param($Contexto)
        if (-not (Test-LabGraphSession)) {
            return [pscustomobject]@{ Disponible = $false; Motivo = 'Sin sesión de Graph' }
        }
        return [pscustomobject]@{ Disponible = $true; Motivo = $null }
    }

    ValidarDef = {
        param($Def)
        $errores = @()
        $i = 0
        foreach ($v in @($Def)) {
            $i++
            if ([string]::IsNullOrWhiteSpace($v.nombre)) {
                $errores += "Vulnerabilidad #$i sin 'nombre'."
            }
            if ([string]::IsNullOrWhiteSpace($v.tipo)) {
                $errores += "Vulnerabilidad #$i sin 'tipo'."
                continue
            }
            $tiposValidos = @('ServicePrincipalOwner','GroupOwner','ApplicationSecret','PimEligibleRole')
            if ($v.tipo -notin $tiposValidos) {
                $errores += "Vulnerabilidad #$i con tipo no soportado: '$($v.tipo)'."
                continue
            }
            if ($v.tipo -eq 'ServicePrincipalOwner') {
                if (-not $v.parametros.usuario) { $errores += "Vulnerabilidad #$i (ServicePrincipalOwner) sin 'usuario'." }
                if (-not $v.parametros.aplicacion) { $errores += "Vulnerabilidad #$i (ServicePrincipalOwner) sin 'aplicacion'." }
            }
            if ($v.tipo -eq 'GroupOwner') {
                if (-not $v.parametros.usuario) { $errores += "Vulnerabilidad #$i (GroupOwner) sin 'usuario'." }
                if (-not $v.parametros.grupo) { $errores += "Vulnerabilidad #$i (GroupOwner) sin 'grupo'." }
            }
            if ($v.tipo -eq 'ApplicationSecret') {
                if (-not $v.parametros.aplicacion) { $errores += "Vulnerabilidad #$i (ApplicationSecret) sin 'aplicacion'." }
            }
            if ($v.tipo -eq 'PimEligibleRole') {
                if (-not $v.parametros.usuario) { $errores += "Vulnerabilidad #$i (PimEligibleRole) sin 'usuario'." }
                if (-not $v.parametros.rol) { $errores += "Vulnerabilidad #$i (PimEligibleRole) sin 'rol'." }
            }
        }
        return $errores
    }

    Describir = {
        param($Def)
        $nombres = @($Def) | ForEach-Object { "$($_.nombre) ($($_.tipo))" }
        return "Vulnerabilidades ($($nombres.Count)): $($nombres -join ', ')"
    }

    Crear = {
        param($Def, $Contexto)

        $creados = @()

        foreach ($v in @($Def)) {
            $nombre = $v.nombre
            $tipo = $v.tipo
            $parametros = $v.parametros

            Write-Verbose "   -> Aplicando vulnerabilidad: $nombre ($tipo)"

            try {
                switch ($tipo) {
                    'ServicePrincipalOwner' {
                        $resultado = Invoke-VulnServicePrincipalOwner -Parametros $parametros -Contexto $Contexto
                        if ($resultado) { $creados += $resultado }
                    }
                    'GroupOwner' {
                        $resultado = Invoke-VulnGroupOwner -Parametros $parametros -Contexto $Contexto
                        if ($resultado) { $creados += $resultado }
                    }
                    'ApplicationSecret' {
                        $resultado = Invoke-VulnApplicationSecret -Parametros $parametros -Contexto $Contexto
                        if ($resultado) { $creados += $resultado }
                    }
                    'PimEligibleRole' {
                        $resultado = Invoke-VulnPimEligibleRole -Parametros $parametros -Contexto $Contexto
                        if ($resultado) { $creados += $resultado }
                    }
                    default {
                        Write-LabWarn "Tipo de vulnerabilidad no soportado: $tipo"
                    }
                }
            } catch {
                Write-LabWarn "No se pudo aplicar '$nombre': $($_.Exception.Message)"
            }
        }

        return $creados
    }

    Revertir = {
        param($Objeto, $Contexto)

        $tipo = if ($Objeto.datos) { $Objeto.datos.tipoVulnerabilidad } else { $null }
        if ([string]::IsNullOrWhiteSpace($tipo)) {
            # Intentar inferir por el tipo del objeto del manifiesto
            $tipo = $Objeto.tipo
        }

        try {
            switch ($tipo) {
                'ServicePrincipalOwner' {
                    return (Invoke-RevertirVulnServicePrincipalOwner -Objeto $Objeto)
                }
                'GroupOwner' {
                    return (Invoke-RevertirVulnGroupOwner -Objeto $Objeto)
                }
                'ApplicationSecret' {
                    return (Invoke-RevertirVulnApplicationSecret -Objeto $Objeto)
                }
                'PimEligibleRole' {
                    return (Invoke-RevertirVulnPimEligibleRole -Objeto $Objeto)
                }
                default {
                    Write-LabWarn "Tipo de vulnerabilidad desconocido para revertir: $tipo"
                    return $false
                }
            }
        } catch {
            Write-LabWarn "No se pudo revertir la vulnerabilidad '$($Objeto.id)': $($_.Exception.Message)"
            return $false
        }
    }

    PreguntarUI = {
        param($Contexto)

        Show-LabBanner 'Nueva vulnerabilidad'

        Write-Host '  Tipos disponibles:' -ForegroundColor Cyan
        Write-Host '    [1] ServicePrincipalOwner (usuario owner de SP)'
        Write-Host '    [2] GroupOwner (usuario owner de grupo)'
        Write-Host '    [3] ApplicationSecret (client secret en app)'
        Write-Host '    [4] PimEligibleRole (rol elegible PIM)'
        $op = Read-Host '  Opción [1/2/3/4]'

        $nombre = Read-Host '  Nombre de la vulnerabilidad'
        if ([string]::IsNullOrWhiteSpace($nombre)) { return $null }

        switch ($op) {
            '1' {
                $usuario = Read-Host '  UPN del usuario'
                $app = Read-Host '  DisplayName de la aplicación'
                if (-not $usuario -or -not $app) { return $null }
                return [pscustomobject]@{
                    nombre     = $nombre
                    tipo       = 'ServicePrincipalOwner'
                    parametros = @{ usuario = $usuario; aplicacion = $app }
                }
            }
            '2' {
                $usuario = Read-Host '  UPN del usuario'
                $grupo = Read-Host '  DisplayName del grupo'
                if (-not $usuario -or -not $grupo) { return $null }
                return [pscustomobject]@{
                    nombre     = $nombre
                    tipo       = 'GroupOwner'
                    parametros = @{ usuario = $usuario; grupo = $grupo }
                }
            }
            '3' {
                $app = Read-Host '  DisplayName de la aplicación'
                if (-not $app) { return $null }
                return [pscustomobject]@{
                    nombre     = $nombre
                    tipo       = 'ApplicationSecret'
                    parametros = @{ aplicacion = $app }
                }
            }
            '4' {
                $usuario = Read-Host '  UPN del usuario'
                $rol = Read-Host '  Nombre del rol (ej. Global Administrator)'
                if (-not $usuario -or -not $rol) { return $null }
                return [pscustomobject]@{
                    nombre     = $nombre
                    tipo       = 'PimEligibleRole'
                    parametros = @{ usuario = $usuario; rol = $rol }
                }
            }
            default { return $null }
        }
    }
}

# ============================================================
# APLICADORES (funciones auxiliares de la capacidad)
# ============================================================

function Invoke-VulnServicePrincipalOwner {
    param($Parametros, $Contexto)

    $upn = $Parametros.usuario -replace '\{tenant\}', $Contexto.TenantDomain
    $appNombre = $Parametros.aplicacion

    # Snapshot pre-lab: si la app es preexistente, no se toca
    if ($Contexto.SnapshotPreLab -and
        $Contexto.SnapshotPreLab.ContainsKey('aplicaciones') -and
        $Contexto.SnapshotPreLab.aplicaciones.ContainsKey($appNombre)) {
        Write-LabWarn "Aplicación '$appNombre' es preexistente. No se aplica ServicePrincipalOwner."
        return [pscustomobject]@{
            tipo              = 'VulnerabilidadAplicada'
            tipoVulnerabilidad = 'ServicePrincipalOwner'
            aplicacion        = $appNombre
            usuario           = $upn
            estadoDetalle     = 'preexistente'
        }
    }

    $user = Get-MgUser -UserId $upn -ErrorAction SilentlyContinue
    if (-not $user) { throw "Usuario '$upn' no encontrado." }
    if ($user -is [array]) { $user = $user[0] }

    $app = Get-MgApplication -Filter "displayName eq '$appNombre'" -ErrorAction SilentlyContinue
    if (-not $app) { throw "Aplicación '$appNombre' no encontrada." }
    if ($app -is [array]) { $app = $app[0] }

    $sp = Get-MgServicePrincipal -Filter "appId eq '$($app.AppId)'" -ErrorAction SilentlyContinue
    if (-not $sp) { throw "SP de '$appNombre' no encontrado." }
    if ($sp -is [array]) { $sp = $sp[0] }

    $body = @{ '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$($user.Id)" }
    $null = New-MgServicePrincipalOwnerByRef -ServicePrincipalId $sp.Id -BodyParameter $body -ErrorAction Stop

    return [pscustomobject]@{
        tipo               = 'VulnerabilidadAplicada'
        tipoVulnerabilidad = 'ServicePrincipalOwner'
        servicePrincipalId = $sp.Id
        directoryObjectId  = $user.Id
        aplicacion         = $appNombre
        usuario            = $upn
        estadoDetalle      = 'creado'
    }
}

function Invoke-VulnGroupOwner {
    param($Parametros, $Contexto)

    $upn = $Parametros.usuario -replace '\{tenant\}', $Contexto.TenantDomain
    $nombreGrupo = $Parametros.grupo

    # Snapshot pre-lab: si el grupo es preexistente, no se toca
    if ($Contexto.SnapshotPreLab -and
        $Contexto.SnapshotPreLab.ContainsKey('grupos') -and
        $Contexto.SnapshotPreLab.grupos.ContainsKey($nombreGrupo)) {
        Write-LabWarn "Grupo '$nombreGrupo' es preexistente. No se aplica GroupOwner."
        return [pscustomobject]@{
            tipo               = 'VulnerabilidadAplicada'
            tipoVulnerabilidad = 'GroupOwner'
            grupo              = $nombreGrupo
            usuario            = $upn
            estadoDetalle      = 'preexistente'
        }
    }

    $user = Get-MgUser -UserId $upn -ErrorAction SilentlyContinue
    if (-not $user) { throw "Usuario '$upn' no encontrado." }
    if ($user -is [array]) { $user = $user[0] }

    $grupo = Get-MgGroup -Filter "displayName eq '$nombreGrupo'" -ErrorAction SilentlyContinue
    if (-not $grupo) { throw "Grupo '$nombreGrupo' no encontrado." }
    if ($grupo -is [array]) { $grupo = $grupo[0] }

    $body = @{ '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$($user.Id)" }
    $null = New-MgGroupOwnerByRef -GroupId $grupo.Id -BodyParameter $body -ErrorAction Stop

    return [pscustomobject]@{
        tipo               = 'VulnerabilidadAplicada'
        tipoVulnerabilidad = 'GroupOwner'
        groupId            = $grupo.Id
        directoryObjectId  = $user.Id
        grupo              = $nombreGrupo
        usuario            = $upn
        estadoDetalle      = 'creado'
    }
}

function Invoke-VulnApplicationSecret {
    param($Parametros, $Contexto)

    $appNombre = $Parametros.aplicacion

    # Snapshot pre-lab
    if ($Contexto.SnapshotPreLab -and
        $Contexto.SnapshotPreLab.ContainsKey('aplicaciones') -and
        $Contexto.SnapshotPreLab.aplicaciones.ContainsKey($appNombre)) {
        Write-LabWarn "Aplicación '$appNombre' es preexistente. No se aplica ApplicationSecret."
        return [pscustomobject]@{
            tipo               = 'VulnerabilidadAplicada'
            tipoVulnerabilidad = 'ApplicationSecret'
            aplicacion         = $appNombre
            estadoDetalle      = 'preexistente'
        }
    }

    $app = Get-MgApplication -Filter "displayName eq '$appNombre'" -ErrorAction SilentlyContinue
    if (-not $app) { throw "Aplicación '$appNombre' no encontrada." }
    if ($app -is [array]) { $app = $app[0] }

    $cred = @{
        displayName = 'Lab vulnerability secret'
        endDateTime = (Get-Date).AddYears(1)
    }
    $result = Add-MgApplicationPassword -ApplicationId $app.Id -PasswordCredential $cred -ErrorAction Stop

    Write-Host ''
    Write-Host '  SECRETO DE VULNERABILIDAD CREADO (MOSTRAR UNA SOLA VEZ):' -ForegroundColor Yellow
    Write-Host "    Aplicación : $appNombre"
    Write-Host "    KeyId      : $($result.KeyId)"
    Write-Host "    Secreto    : $($result.SecretText)" -ForegroundColor Green
    Write-Host ''

    return [pscustomobject]@{
        tipo               = 'VulnerabilidadAplicada'
        tipoVulnerabilidad = 'ApplicationSecret'
        applicationId      = $app.Id
        keyId              = $result.KeyId
        aplicacion         = $appNombre
        estadoDetalle      = 'creado'
    }
}

function Invoke-VulnPimEligibleRole {
    param($Parametros, $Contexto)

    $upn = $Parametros.usuario -replace '\{tenant\}', $Contexto.TenantDomain
    $rol = $Parametros.rol

    # Snapshot pre-lab: si el usuario es preexistente, no se toca
    if ($Contexto.SnapshotPreLab -and
        $Contexto.SnapshotPreLab.ContainsKey('usuarios') -and
        $Contexto.SnapshotPreLab.usuarios.ContainsKey($upn.ToLowerInvariant())) {
        Write-LabWarn "Usuario '$upn' es preexistente. No se aplica PimEligibleRole."
        return [pscustomobject]@{
            tipo               = 'VulnerabilidadAplicada'
            tipoVulnerabilidad = 'PimEligibleRole'
            usuario            = $upn
            rol                = $rol
            estadoDetalle      = 'preexistente'
        }
    }

    $user = Get-MgUser -UserId $upn -ErrorAction SilentlyContinue
    if (-not $user) { throw "Usuario '$upn' no encontrado." }
    if ($user -is [array]) { $user = $user[0] }

    $roleDef = Get-MgRoleManagementDirectoryRoleDefinition -Filter "displayName eq '$rol'" -ErrorAction Stop
    if (-not $roleDef) { throw "Rol '$rol' no encontrado." }
    if ($roleDef -is [array]) { $roleDef = $roleDef[0] }

    $body = @{
        action           = 'adminAssign'
        justification    = 'Lab vulnerability'
        roleDefinitionId = $roleDef.Id
        directoryScopeId = '/'
        principalId      = $user.Id
        scheduleInfo     = @{
            startDateTime = (Get-Date).ToString('o')
            expiration    = @{
                type     = 'afterDuration'
                duration = 'PT8H'
            }
        }
    }
    $request = New-MgRoleManagementDirectoryRoleEligibilityScheduleRequest -BodyParameter $body -ErrorAction Stop

    return [pscustomobject]@{
        tipo                     = 'VulnerabilidadAplicada'
        tipoVulnerabilidad       = 'PimEligibleRole'
        principalId              = $user.Id
        roleDefinitionId         = $roleDef.Id
        scheduleRequestId        = $request.Id
        usuario                  = $upn
        rol                      = $rol
        estadoDetalle            = 'creado'
    }
}

# ============================================================
# REVERSORES (funciones auxiliares de la capacidad)
# ============================================================

function Invoke-RevertirVulnServicePrincipalOwner {
    param($Objeto)

    $spId = if ($Objeto.datos) { $Objeto.datos.servicePrincipalId } else { $null }
    $dirId = if ($Objeto.datos) { $Objeto.datos.directoryObjectId } else { $null }
    if (-not $spId -or -not $dirId) { return $true }  # preexistente o sin datos

    try {
        $null = Remove-MgServicePrincipalOwnerByRef -ServicePrincipalId $spId -DirectoryObjectId $dirId -Confirm:$false -ErrorAction Stop
        return $true
    } catch {
        if ($_.Exception.Message -match '404|not found|does not exist') { return $true }
        return $false
    }
}

function Invoke-RevertirVulnGroupOwner {
    param($Objeto)

    $groupId = if ($Objeto.datos) { $Objeto.datos.groupId } else { $null }
    $dirId = if ($Objeto.datos) { $Objeto.datos.directoryObjectId } else { $null }
    if (-not $groupId -or -not $dirId) { return $true }

    try {
        $null = Remove-MgGroupOwnerByRef -GroupId $groupId -DirectoryObjectId $dirId -Confirm:$false -ErrorAction Stop
        return $true
    } catch {
        if ($_.Exception.Message -match '404|not found|does not exist') { return $true }
        return $false
    }
}

function Invoke-RevertirVulnApplicationSecret {
    param($Objeto)

    $appId = if ($Objeto.datos) { $Objeto.datos.applicationId } else { $null }
    $keyId = if ($Objeto.datos) { $Objeto.datos.keyId } else { $null }
    if (-not $appId -or -not $keyId) { return $true }

    try {
        $null = Remove-MgApplicationPassword -ApplicationId $appId -KeyId $keyId -Confirm:$false -ErrorAction Stop
        return $true
    } catch {
        if ($_.Exception.Message -match '404|not found|does not exist') { return $true }
        return $false
    }
}

function Invoke-RevertirVulnPimEligibleRole {
    param($Objeto)

    $requestId = if ($Objeto.datos) { $Objeto.datos.scheduleRequestId } else { $null }
    if (-not $requestId) { return $true }

    try {
        $null = Remove-MgRoleManagementDirectoryRoleEligibilityScheduleRequest -UnifiedRoleEligibilityScheduleRequestId $requestId -Confirm:$false -ErrorAction Stop
        return $true
    } catch {
        if ($_.Exception.Message -match '404|not found|does not exist') { return $true }
        return $false
    }
}

Register-LabCapacidad -Capacidad $Capacidad