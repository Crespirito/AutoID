<#
.SYNOPSIS
    Capacidad: Permisos de API concedidos a una aplicación.
.DESCRIPTION
    Concede permisos de API (application o delegated) a una aplicación
    existente a partir de la sección 'permisosApi' del escenario.

    TIPOS DE PERMISO:
      - 'application': se concede con New-MgServicePrincipalAppRoleAssignment.
        El permiso se busca en AppRoles del SP del recurso (Microsoft Graph).
      - 'delegated': se concede con New-MgOauth2PermissionGrant.
        El permiso se busca en Oauth2PermissionScopes del SP del recurso.

    SEGURIDAD DE PREEXISTENTES:
    - Si la aplicación es preexistente (snapshot pre-lab), no se conceden
      permisos y se marca 'preexistente'.
    - Si el permiso ya estaba concedido, se marca 'reutilizado'.
    - Si no, se concede y se marca 'creado'.

    DEPENDENCIAS: Aplicaciones (necesita el objectId de la app y su SP).

    NIVEL: Free (conceder permisos a Microsoft Graph no requiere P1/P2;
    el consentimiento de administrador es lo que se necesita).
#>

$Capacidad = @{
    Nombre      = 'PermisosApi'
    SeccionJson = 'permisosApi'
    Alias       = @('permisosApi','permisos_api','apiPermissions')
    Nivel       = 'Free'
    DependeDe   = @('Aplicaciones')
    PermisosApp = @('Application.ReadWrite.All','AppRoleAssignment.ReadWrite.All','DelegatedPermissionGrant.ReadWrite.All')

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
        foreach ($p in @($Def)) {
            $i++
            if ([string]::IsNullOrWhiteSpace($p.aplicacion)) {
                $errores += "Permiso #$i sin 'aplicacion'."
            }
            if ([string]::IsNullOrWhiteSpace($p.recurso)) {
                $errores += "Permiso #$i sin 'recurso' (ej. Microsoft Graph)."
            }
            if ([string]::IsNullOrWhiteSpace($p.permiso)) {
                $errores += "Permiso #$i sin 'permiso' (ej. User.ReadWrite.All)."
            }
            if ($p.PSObject.Properties['tipo'] -and $p.tipo) {
                if ($p.tipo -notin @('application','delegated')) {
                    $errores += "Permiso #$i con 'tipo' inválido: '$($p.tipo)'. Debe ser 'application' o 'delegated'."
                }
            }
        }
        return $errores
    }

    Describir = {
        param($Def)
        $nombres = @($Def) | ForEach-Object { "$($_.aplicacion) -> $($_.permiso)" }
        return "Permisos de API ($($nombres.Count)): $($nombres -join ', ')"
    }

    Crear = {
        param($Def, $Contexto)

        $creados = @()

        # SP de Microsoft Graph (recurso por defecto)
        $graphSp = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'" -ErrorAction SilentlyContinue
        if (-not $graphSp) {
            throw "No se encontró el Service Principal de Microsoft Graph. ¿La sesión tiene permisos?"
        }
        if ($graphSp -is [array]) { $graphSp = $graphSp[0] }

        foreach ($p in @($Def)) {
            $appNombre = $p.aplicacion
            $recursoNombre = $p.recurso
            $permisoValor = $p.permiso
            $tipo = if ($p.PSObject.Properties['tipo'] -and $p.tipo) { $p.tipo } else { 'application' }

            # --- 1. Snapshot pre-lab ---
            if ($Contexto.SnapshotPreLab -and
                $Contexto.SnapshotPreLab.ContainsKey('aplicaciones') -and
                $Contexto.SnapshotPreLab.aplicaciones.ContainsKey($appNombre)) {
                Write-LabWarn "Aplicación '$appNombre' es preexistente. No se conceden permisos."
                $creados += [pscustomobject]@{
                    tipo          = 'PermisoApi'
                    aplicacion    = $appNombre
                    permiso       = $permisoValor
                    estadoDetalle = 'preexistente'
                }
                continue
            }

            # --- 2. Buscar la app y su SP ---
            $app = Get-MgApplication -Filter "displayName eq '$appNombre'" -ErrorAction SilentlyContinue
            if (-not $app) {
                Write-LabWarn "Aplicación '$appNombre' no encontrada; se omite permiso."
                continue
            }
            if ($app -is [array]) { $app = $app[0] }

            $clientSp = Get-MgServicePrincipal -Filter "appId eq '$($app.AppId)'" -ErrorAction SilentlyContinue
            if (-not $clientSp) {
                Write-LabWarn "Service Principal de '$appNombre' no encontrado; se omite permiso."
                continue
            }
            if ($clientSp -is [array]) { $clientSp = $clientSp[0] }

            # --- 3. Resolver el recurso (SP del recurso) ---
            $resourceSp = $null
            if ($recursoNombre -eq 'Microsoft Graph') {
                $resourceSp = $graphSp
            } else {
                $resourceSp = Get-MgServicePrincipal -Filter "displayName eq '$recursoNombre'" -ErrorAction SilentlyContinue
                if ($resourceSp -is [array]) { $resourceSp = $resourceSp[0] }
            }
            if (-not $resourceSp) {
                Write-LabWarn "Recurso '$recursoNombre' no encontrado; se omite permiso."
                continue
            }

            # --- 4. Buscar el permiso en el recurso ---
            if ($tipo -eq 'application') {
                # Application permission: buscar en AppRoles
                $appRole = $null
                foreach ($ar in @($resourceSp.AppRoles)) {
                    if ($ar.Value -eq $permisoValor -and $ar.AllowedMemberTypes -contains 'Application') {
                        $appRole = $ar; break
                    }
                }
                if (-not $appRole) {
                    Write-LabWarn "Permiso de aplicación '$permisoValor' no encontrado en '$recursoNombre'."
                    continue
                }

                # Comprobar si ya está concedido
                $asignaciones = Get-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $clientSp.Id -All -ErrorAction SilentlyContinue
                $yaConcedido = $false
                foreach ($a in $asignaciones) {
                    if ($a.AppRoleId -eq $appRole.Id -and $a.ResourceId -eq $resourceSp.Id) {
                        $yaConcedido = $true; break
                    }
                }

                if ($yaConcedido) {
                    Write-Verbose "   -> Permiso '$permisoValor' ya concedido a '$appNombre' (reutilizado)"
                    $creados += [pscustomobject]@{
                        tipo          = 'PermisoApi'
                        aplicacion    = $appNombre
                        permiso       = $permisoValor
                        tipoPermiso   = 'application'
                        appRoleId     = $appRole.Id
                        resourceId    = $resourceSp.Id
                        clientSpId    = $clientSp.Id
                        estadoDetalle = 'reutilizado'
                    }
                    continue
                }

                # Conceder
                $body = @{
                    PrincipalId = $clientSp.Id
                    ResourceId  = $resourceSp.Id
                    AppRoleId   = $appRole.Id
                }
                try {
                    $null = New-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $clientSp.Id -BodyParameter $body -ErrorAction Stop
                    Write-Verbose "   -> Permiso '$permisoValor' concedido a '$appNombre'"
                    $creados += [pscustomobject]@{
                        tipo          = 'PermisoApi'
                        aplicacion    = $appNombre
                        permiso       = $permisoValor
                        tipoPermiso   = 'application'
                        appRoleId     = $appRole.Id
                        resourceId    = $resourceSp.Id
                        clientSpId    = $clientSp.Id
                        estadoDetalle = 'creado'
                    }
                } catch {
                    Write-LabWarn "No se pudo conceder '$permisoValor' a '$appNombre': $($_.Exception.Message)"
                }

            } else {
                # Delegated permission: buscar en Oauth2PermissionScopes
                $scope = $null
                foreach ($s in @($resourceSp.Oauth2PermissionScopes)) {
                    if ($s.Value -eq $permisoValor) {
                        $scope = $s; break
                    }
                }
                if (-not $scope) {
                    Write-LabWarn "Permiso delegado '$permisoValor' no encontrado en '$recursoNombre'."
                    continue
                }

                # Comprobar si ya está concedido
                $grants = Get-MgOauth2PermissionGrant -Filter "clientId eq '$($clientSp.Id)' and resourceId eq '$($resourceSp.Id)'" -ErrorAction SilentlyContinue
                $yaConcedido = $false
                $grantExistente = $null
                foreach ($g in @($grants)) {
                    if ($g.Scope -match "\b$([regex]::Escape($permisoValor))\b") {
                        $yaConcedido = $true
                        $grantExistente = $g
                        break
                    }
                }

                if ($yaConcedido) {
                    Write-Verbose "   -> Permiso delegado '$permisoValor' ya concedido a '$appNombre' (reutilizado)"
                    $creados += [pscustomobject]@{
                        tipo          = 'PermisoApi'
                        aplicacion    = $appNombre
                        permiso       = $permisoValor
                        tipoPermiso   = 'delegated'
                        scopeId       = $scope.Id
                        resourceId    = $resourceSp.Id
                        clientSpId    = $clientSp.Id
                        grantId       = $grantExistente.Id
                        estadoDetalle = 'reutilizado'
                    }
                    continue
                }

                # Conceder (AllPrincipals)
                try {
                    $grant = New-MgOauth2PermissionGrant -ClientId $clientSp.Id -ConsentType 'AllPrincipals' -ResourceId $resourceSp.Id -Scope $permisoValor -ErrorAction Stop
                    Write-Verbose "   -> Permiso delegado '$permisoValor' concedido a '$appNombre'"
                    $creados += [pscustomobject]@{
                        tipo          = 'PermisoApi'
                        aplicacion    = $appNombre
                        permiso       = $permisoValor
                        tipoPermiso   = 'delegated'
                        scopeId       = $scope.Id
                        resourceId    = $resourceSp.Id
                        clientSpId    = $clientSp.Id
                        grantId       = $grant.Id
                        estadoDetalle = 'creado'
                    }
                } catch {
                    Write-LabWarn "No se pudo conceder permiso delegado '$permisoValor' a '$appNombre': $($_.Exception.Message)"
                }
            }
        }

        return $creados
    }

    Revertir = {
        param($Objeto, $Contexto)

        if ($Objeto.tipo -ne 'PermisoApi') { return $false }

        $tipoPermiso = if ($Objeto.datos) { $Objeto.datos.tipoPermiso } else { $null }
        $clientSpId = if ($Objeto.datos) { $Objeto.datos.clientSpId } else { $null }

        if ([string]::IsNullOrWhiteSpace($clientSpId)) {
            # Preexistente o sin datos: no hay nada que revertir
            return $true
        }

        try {
            if ($tipoPermiso -eq 'application') {
                $appRoleId = if ($Objeto.datos) { $Objeto.datos.appRoleId } else { $null }
                if (-not $appRoleId) { return $true }

                $asignaciones = Get-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $clientSpId -All -ErrorAction SilentlyContinue
                $encontrada = $null
                foreach ($a in $asignaciones) {
                    if ($a.AppRoleId -eq $appRoleId) {
                        $encontrada = $a; break
                    }
                }
                if (-not $encontrada) { return $true }  # idempotente

                $null = Remove-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $clientSpId -AppRoleAssignmentId $encontrada.Id -Confirm:$false -ErrorAction Stop
                return $true

            } elseif ($tipoPermiso -eq 'delegated') {
                $grantId = if ($Objeto.datos) { $Objeto.datos.grantId } else { $null }
                if (-not $grantId) { return $true }

                $grant = Get-MgOauth2PermissionGrant -OAuth2PermissionGrantId $grantId -ErrorAction SilentlyContinue
                if (-not $grant) { return $true }  # idempotente

                $null = Remove-MgOauth2PermissionGrant -OAuth2PermissionGrantId $grantId -Confirm:$false -ErrorAction Stop
                return $true
            }
        } catch {
            Write-LabWarn "No se pudo revocar el permiso '$($Objeto.id)': $($_.Exception.Message)"
            return $false
        }

        return $false
    }

    PreguntarUI = {
        param($Contexto)

        Show-LabBanner 'Nuevo permiso de API'

        $appNombre = Read-Host '  Aplicación (displayName)'
        if ([string]::IsNullOrWhiteSpace($appNombre)) {
            Write-LabWarn 'Aplicación vacía. Cancelando.'
            return $null
        }

        # Snapshot pre-lab
        if ($Contexto.SnapshotPreLab -and
            $Contexto.SnapshotPreLab.ContainsKey('aplicaciones') -and
            $Contexto.SnapshotPreLab.aplicaciones.ContainsKey($appNombre)) {
            Write-LabWarn "La aplicación '$appNombre' es preexistente. No se pueden conceder permisos."
            return $null
        }

        $recurso = Read-Host '  Recurso [Microsoft Graph]'
        if ([string]::IsNullOrWhiteSpace($recurso)) { $recurso = 'Microsoft Graph' }

        Write-Host ''
        Write-Host '  Tipo de permiso:' -ForegroundColor Cyan
        Write-Host '    [1] Application (por defecto)'
        Write-Host '    [2] Delegated'
        $opTipo = Read-Host '  Opción [1/2]'
        $tipo = if ($opTipo -eq '2') { 'delegated' } else { 'application' }

        $permiso = Read-Host '  Permiso (ej. User.ReadWrite.All)'
        if ([string]::IsNullOrWhiteSpace($permiso)) {
            Write-LabWarn 'Permiso vacío. Cancelando.'
            return $null
        }

        return [pscustomobject]@{
            aplicacion = $appNombre
            recurso    = $recurso
            permiso    = $permiso
            tipo       = $tipo
        }
    }
}

Register-LabCapacidad -Capacidad $Capacidad