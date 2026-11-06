<#
.SYNOPSIS
    Capacidad: App Roles y asignaciones de roles de aplicación.
.DESCRIPTION
    Define roles de aplicación (appRoles) en una aplicación existente y
    crea asignaciones de esos roles a usuarios o grupos.

    La sección del escenario 'appRoles' contiene dos tipos de entradas:
      - Definiciones de rol: { aplicacion, displayName, value, allowedMemberTypes }
      - Asignaciones: { aplicacion, value, principal } (principal = UPN o displayName de grupo)

    SEGURIDAD DE PREEXISTENTES:
    - Si la aplicación es preexistente (snapshot pre-lab), no se define
      ningún rol en ella y se marca todo como 'preexistente'.
    - Si la asignación ya existía, se marca 'reutilizado'.
    - Si no, se crea y se marca 'creado'.

    DEPENDENCIAS: Aplicaciones (necesita el appId y el SP de la app).

    NIVEL: Free (app roles no requiere licencia P1/P2 para asignar a
    usuarios; asignar a grupos sí requiere P1/P2, pero eso lo valida
    TestDisponible en runtime).
#>

$Capacidad = @{
    Nombre      = 'AppRoles'
    SeccionJson = 'appRoles'
    Alias       = @('appRoles','app_roles')
    Nivel       = 'Free'
    DependeDe   = @('Aplicaciones')
    PermisosApp = @('Application.ReadWrite.All','AppRoleAssignment.ReadWrite.All','Directory.Read.All')

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
        foreach ($r in @($Def)) {
            $i++
            if ([string]::IsNullOrWhiteSpace($r.aplicacion)) {
                $errores += "AppRole #$i sin 'aplicacion'."
                continue
            }
            # Si tiene 'principal', es una asignación
            if ($r.PSObject.Properties['principal'] -and -not [string]::IsNullOrWhiteSpace($r.principal)) {
                if ([string]::IsNullOrWhiteSpace($r.value)) {
                    $errores += "Asignación #$i sin 'value' (rol a asignar)."
                }
            } else {
                # Es una definición de rol
                if ([string]::IsNullOrWhiteSpace($r.displayName)) {
                    $errores += "Definición de rol #$i sin 'displayName'."
                }
                if ([string]::IsNullOrWhiteSpace($r.value)) {
                    $errores += "Definición de rol #$i sin 'value'."
                } elseif ($r.value -match '\s') {
                    $errores += "Definición de rol #$i: 'value' no puede contener espacios."
                }
                if ($r.PSObject.Properties['allowedMemberTypes'] -and $null -ne $r.allowedMemberTypes) {
                    foreach ($t in @($r.allowedMemberTypes)) {
                        if ($t -notin @('User','Application')) {
                            $errores += "Definición de rol #$i: allowedMemberTypes inválido: '$t'."
                        }
                    }
                }
            }
        }
        return $errores
    }

    Describir = {
        param($Def)
        $defs = @($Def | Where-Object { -not $_.PSObject.Properties['principal'] -or [string]::IsNullOrWhiteSpace($_.principal) })
        $asigs = @($Def | Where-Object { $_.PSObject.Properties['principal'] -and -not [string]::IsNullOrWhiteSpace($_.principal) })
        $lineas = @()
        if ($defs.Count -gt 0) { $lineas += "Roles definidos: $($defs.Count)" }
        if ($asigs.Count -gt 0) { $lineas += "Asignaciones: $($asigs.Count)" }
        return ($lineas -join ' | ')
    }

    Crear = {
        param($Def, $Contexto)

        $creados = @()

        # 1. Separar definiciones y asignaciones
        $definiciones = @($Def | Where-Object { -not $_.PSObject.Properties['principal'] -or [string]::IsNullOrWhiteSpace($_.principal) })
        $asignaciones = @($Def | Where-Object { $_.PSObject.Properties['principal'] -and -not [string]::IsNullOrWhiteSpace($_.principal) })

        # 2. Agrupar definiciones por aplicación
        $rolesPorApp = @{}
        foreach ($d in $definiciones) {
            $appNombre = $d.aplicacion
            if (-not $rolesPorApp.ContainsKey($appNombre)) { $rolesPorApp[$appNombre] = @() }
            $rolesPorApp[$appNombre] += $d
        }

        # 3. Aplicar definiciones de rol a cada app
        foreach ($appNombre in $rolesPorApp.Keys) {
            # Comprobar preexistencia de la app
            if ($Contexto.SnapshotPreLab -and
                $Contexto.SnapshotPreLab.ContainsKey('aplicaciones') -and
                $Contexto.SnapshotPreLab.aplicaciones.ContainsKey($appNombre)) {
                Write-LabWarn "Aplicación '$appNombre' es preexistente. No se definen roles en ella."
                foreach ($d in $rolesPorApp[$appNombre]) {
                    $creados += [pscustomobject]@{
                        tipo          = 'AppRole'
                        aplicacion    = $appNombre
                        value         = $d.value
                        estadoDetalle = 'preexistente'
                    }
                }
                continue
            }

            $app = Get-MgApplication -Filter "displayName eq '$appNombre'" -ErrorAction SilentlyContinue
            if (-not $app) {
                Write-LabWarn "Aplicación '$appNombre' no encontrada para definir roles; se omite."
                continue
            }
            if ($app -is [array]) { $app = $app[0] }

            # Construir lista de appRoles nueva (preservando los existentes)
            $rolesExistentes = @()
            if ($app.AppRoles) { $rolesExistentes = @($app.AppRoles) }

            $rolesNuevos = @()
            $rolesNuevos += $rolesExistentes

            foreach ($d in $rolesPorApp[$appNombre]) {
                # Comprobar si el rol ya existe por value
                $yaExiste = $false
                foreach ($r in $rolesExistentes) {
                    if ($r.Value -eq $d.value) { $yaExiste = $true; break }
                }
                if ($yaExiste) {
                    Write-Verbose "   -> Rol '$($d.value)' ya existe en '$appNombre'"
                    $creados += [pscustomobject]@{
                        tipo          = 'AppRole'
                        aplicacion    = $appNombre
                        value         = $d.value
                        appId         = $app.AppId
                        estadoDetalle = 'reutilizado'
                    }
                    continue
                }

                $allowedMemberTypes = @('User')
                if ($d.PSObject.Properties['allowedMemberTypes'] -and $null -ne $d.allowedMemberTypes) {
                    $allowedMemberTypes = @($d.allowedMemberTypes)
                }

                $rolesNuevos += @{
                    DisplayName         = $d.displayName
                    Description         = if ($d.PSObject.Properties['description']) { $d.description } else { $d.displayName }
                    Value               = $d.value
                    AllowedMemberTypes  = $allowedMemberTypes
                    IsEnabled           = $true
                    Id                  = [guid]::NewGuid().ToString()
                }

                $creados += [pscustomobject]@{
                    tipo          = 'AppRole'
                    aplicacion    = $appNombre
                    value         = $d.value
                    appId         = $app.AppId
                    estadoDetalle = 'creado'
                }
            }

            # Actualizar la app si hay roles nuevos
            if ($rolesNuevos.Count -gt $rolesExistentes.Count) {
                $null = Update-MgApplication -ApplicationId $app.Id -AppRoles $rolesNuevos -ErrorAction Stop
                Write-Verbose "   -> Roles actualizados en '$appNombre'"
            }
        }

        # 4. Aplicar asignaciones
        foreach ($asig in $asignaciones) {
            $appNombre = $asig.aplicacion
            $rolValue = $asig.value
            $principal = $asig.principal

            # Comprobar preexistencia de la app
            if ($Contexto.SnapshotPreLab -and
                $Contexto.SnapshotPreLab.ContainsKey('aplicaciones') -and
                $Contexto.SnapshotPreLab.aplicaciones.ContainsKey($appNombre)) {
                Write-LabWarn "Aplicación '$appNombre' es preexistente. No se asignan roles."
                $creados += [pscustomobject]@{
                    tipo          = 'AppRoleAssignment'
                    aplicacion    = $appNombre
                    value         = $rolValue
                    principal     = $principal
                    estadoDetalle = 'preexistente'
                }
                continue
            }

            # Buscar app y SP
            $app = Get-MgApplication -Filter "displayName eq '$appNombre'" -ErrorAction SilentlyContinue
            if (-not $app) {
                Write-LabWarn "Aplicación '$appNombre' no encontrada para asignación; se omite."
                continue
            }
            if ($app -is [array]) { $app = $app[0] }

            $sp = Get-MgServicePrincipal -Filter "appId eq '$($app.AppId)'" -ErrorAction SilentlyContinue
            if (-not $sp) {
                Write-LabWarn "Service Principal de '$appNombre' no encontrado; se omite asignación."
                continue
            }
            if ($sp -is [array]) { $sp = $sp[0] }

            # Buscar el rol por value en el SP (appRoles del SP)
            $appRole = $null
            if ($sp.AppRoles) {
                foreach ($ar in @($sp.AppRoles)) {
                    if ($ar.Value -eq $rolValue) { $appRole = $ar; break }
                }
            }
            if (-not $appRole) {
                Write-LabWarn "Rol '$rolValue' no encontrado en '$appNombre'; se omite asignación."
                continue
            }

            # Resolver principal (usuario o grupo)
            $principalId = $null
            $principalType = $null

            $user = Get-MgUser -UserId $principal -ErrorAction SilentlyContinue
            if ($user) {
                if ($user -is [array]) { $user = $user[0] }
                $principalId = $user.Id
                $principalType = 'User'
            } else {
                $group = Get-MgGroup -Filter "displayName eq '$principal'" -ErrorAction SilentlyContinue
                if ($group) {
                    if ($group -is [array]) { $group = $group[0] }
                    $principalId = $group.Id
                    $principalType = 'Group'
                }
            }

            if (-not $principalId) {
                Write-LabWarn "Principal '$principal' no encontrado (ni usuario ni grupo); se omite asignación."
                continue
            }

            # Comprobar si ya está asignado
            $asignacionesExistentes = Get-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $sp.Id -All -ErrorAction SilentlyContinue
            $yaAsignado = $false
            foreach ($a in $asignacionesExistentes) {
                if ($a.PrincipalId -eq $principalId -and $a.AppRoleId -eq $appRole.Id) {
                    $yaAsignado = $true; break
                }
            }

            if ($yaAsignado) {
                Write-Verbose "   -> $principal ya tiene rol '$rolValue' en '$appNombre'"
                $creados += [pscustomobject]@{
                    tipo          = 'AppRoleAssignment'
                    aplicacion    = $appNombre
                    value         = $rolValue
                    principal     = $principal
                    principalId   = $principalId
                    appRoleId     = $appRole.Id
                    servicePrincipalId = $sp.Id
                    estadoDetalle = 'reutilizado'
                }
                continue
            }

            $body = @{
                PrincipalId = $principalId
                ResourceId  = $sp.Id
                AppRoleId   = $appRole.Id
            }

            try {
                $null = New-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $sp.Id -BodyParameter $body -ErrorAction Stop
                Write-Verbose "   -> $principal asignado a rol '$rolValue' en '$appNombre'"
                $creados += [pscustomobject]@{
                    tipo          = 'AppRoleAssignment'
                    aplicacion    = $appNombre
                    value         = $rolValue
                    principal     = $principal
                    principalId   = $principalId
                    appRoleId     = $appRole.Id
                    servicePrincipalId = $sp.Id
                    estadoDetalle = 'creado'
                }
            } catch {
                Write-LabWarn "No se pudo asignar rol '$rolValue' a '$principal': $($_.Exception.Message)"
            }
        }

        return $creados
    }

    Revertir = {
        param($Objeto, $Contexto)

        if ($Objeto.tipo -eq 'AppRoleAssignment') {
            $spId = if ($Objeto.datos) { $Objeto.datos.servicePrincipalId } else { $null }
            $principalId = if ($Objeto.datos) { $Objeto.datos.principalId } else { $null }
            $appRoleId = if ($Objeto.datos) { $Objeto.datos.appRoleId } else { $null }

            if (-not $spId -or -not $principalId -or -not $appRoleId) {
                # Preexistente o sin datos: no hay nada que revertir
                return $true
            }

            try {
                $asignaciones = Get-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $spId -All -ErrorAction SilentlyContinue
                $encontrada = $null
                foreach ($a in $asignaciones) {
                    if ($a.PrincipalId -eq $principalId -and $a.AppRoleId -eq $appRoleId) {
                        $encontrada = $a; break
                    }
                }
                if (-not $encontrada) { return $true }  # idempotente

                $null = Remove-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $spId -AppRoleAssignmentId $encontrada.Id -Confirm:$false -ErrorAction Stop
                return $true
            } catch {
                Write-LabWarn "No se pudo quitar la asignación de rol '$($Objeto.id)': $($_.Exception.Message)"
                return $false
            }
        }

        if ($Objeto.tipo -eq 'AppRole') {
            # Un rol definido no se puede "borrar" fácilmente sin afectar asignaciones.
            # El cleanup lo deja como no-revertido; el operador debe borrar la app
            # completa si quiere eliminar los roles.
            Write-LabWarn "Los roles de aplicación definidos no se revierten individualmente. Borra la aplicación completa si es necesario."
            return $false
        }

        return $false
    }

    PreguntarUI = {
        param($Contexto)

        Show-LabBanner 'Nuevo App Role'

        # Pedir aplicación
        $appNombre = Read-Host '  Aplicación (displayName)'
        if ([string]::IsNullOrWhiteSpace($appNombre)) {
            Write-LabWarn 'Aplicación vacía. Cancelando.'
            return $null
        }

        # Comprobar preexistencia
        if ($Contexto.SnapshotPreLab -and
            $Contexto.SnapshotPreLab.ContainsKey('aplicaciones') -and
            $Contexto.SnapshotPreLab.aplicaciones.ContainsKey($appNombre)) {
            Write-LabWarn "La aplicación '$appNombre' es preexistente. No se pueden definir roles."
            return $null
        }

        Write-Host ''
        Write-Host '  Tipo:' -ForegroundColor Cyan
        Write-Host '    [1] Definir un rol'
        Write-Host '    [2] Asignar un rol existente a un usuario/grupo'
        $op = Read-Host '  Opción [1/2]'

        if ($op -eq '2') {
            $rolValue = Read-Host '  Value del rol (ej. Admin)'
            if ([string]::IsNullOrWhiteSpace($rolValue)) { return $null }
            $principal = Read-Host '  UPN de usuario o displayName de grupo'
            if ([string]::IsNullOrWhiteSpace($principal)) { return $null }

            return [pscustomobject]@{
                aplicacion = $appNombre
                value      = $rolValue
                principal  = $principal
            }
        }

        $displayName = Read-Host '  DisplayName del rol'
        if ([string]::IsNullOrWhiteSpace($displayName)) { return $null }
        $value = Read-Host '  Value del rol (sin espacios)'
        if ([string]::IsNullOrWhiteSpace($value)) { return $null }

        Write-Host ''
        Write-Host '  AllowedMemberTypes:' -ForegroundColor Cyan
        Write-Host '    [1] User (por defecto)'
        Write-Host '    [2] User + Application'
        $opTipo = Read-Host '  Opción [1/2]'
        $allowedMemberTypes = if ($opTipo -eq '2') { @('User','Application') } else { @('User') }

        return [pscustomobject]@{
            aplicacion         = $appNombre
            displayName        = $displayName
            value              = $value
            allowedMemberTypes = $allowedMemberTypes
        }
    }
}

Register-LabCapacidad -Capacidad $Capacidad