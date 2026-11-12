<#
.SYNOPSIS
    Capacidad: Unidades administrativas (Administrative Units).
.DESCRIPTION
    Crea unidades administrativas (AU) en Entra ID, añade miembros
    (usuarios y grupos) y asigna roles con ámbito de AU.

    LICENCIAS:
    - Crear la AU y añadir miembros: disponible en Free.
    - Asignar un rol con ámbito de AU: requiere P1/P2.

    SEGURIDAD DE PREEXISTENTES:
    - Si el snapshot pre-lab contiene la AU, se marca 'preexistente'
      y no se modifica.
    - Si el snapshot NO contiene la clave 'administrativeUnits' (esto
      ocurre hoy porque lib_creadores.ps1 no la rellena), la capacidad
      hace una consulta puntual a Graph y, si la AU existe y no está
      en $Contexto.ObjetosCreados['AdministrativeUnits'], la marca como
      'preexistente' y no la toca.
    - Los miembros y roles de una AU preexistente no se tocan.

    DEPENDENCIAS: Usuarios, Grupos.
    NIVEL: P1.
.NOTES
    Requiere PowerShell 7.
#>
#Requires -Version 7.0

# Set-StrictMode -Version Latest

$Capacidad = @{
    Nombre      = 'AdministrativeUnits'
    Descripcion = 'Unidades administrativas (AUs)'
    SeccionJson = 'administrativeUnits'
    Alias       = @('unidadesAdministrativas','unidades_administrativas','adminUnits')
    Nivel       = 'P1'
    DependeDe   = @('Usuarios','Grupos')
    PermisosApp = @('AdministrativeUnit.ReadWrite.All','RoleManagement.ReadWrite.Directory','User.Read.All','Group.Read.All')

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
        foreach ($au in @($Def)) {
            $i++
            if ([string]::IsNullOrWhiteSpace($au.displayName)) {
                $errores += "AU #$i sin 'displayName'."
            }
            if ($au.PSObject.Properties['members'] -and $null -ne $au.members) {
                foreach ($m in @($au.members)) {
                    if ([string]::IsNullOrWhiteSpace($m)) {
                        $errores += "AU #$i con miembro vacío."
                    }
                }
            }
            if ($au.PSObject.Properties['roles'] -and $null -ne $au.roles) {
                foreach ($r in @($au.roles)) {
                    if ([string]::IsNullOrWhiteSpace($r.rol)) {
                        $errores += "AU #$i con rol sin 'rol'."
                    }
                    if ([string]::IsNullOrWhiteSpace($r.usuario)) {
                        $errores += "AU #$i con rol sin 'usuario'."
                    }
                }
            }
        }
        return $errores
    }

    Describir = {
        param($Def)
        $nombres = @($Def) | ForEach-Object {
            $extra = @()
            if ($_.PSObject.Properties['members'] -and $null -ne $_.members) { $extra += "miembros: $(@($_.members).Count)" }
            if ($_.PSObject.Properties['roles'] -and $null -ne $_.roles) { $extra += "roles: $(@($_.roles).Count)" }
            $sufijo = if ($extra.Count) { " ($($extra -join ', '))" } else { '' }
            "$($_.displayName)$sufijo"
        }
        return "Unidades administrativas ($($nombres.Count)): $($nombres -join ', ')"
    }

    Crear = {
        param($Def, $Contexto)

        $creados = @()

        # N3: helper local de preexistencia
        $esPreexistente = {
            param($displayName, $objectIdExistente)
            # 1. Snapshot global (si existe la clave)
            if ($Contexto.SnapshotPreLab -and
                $Contexto.SnapshotPreLab.ContainsKey('administrativeUnits') -and
                $Contexto.SnapshotPreLab.administrativeUnits.ContainsKey($displayName)) {
                return $true
            }
            # 2. ¿Está en ObjetosCreados de esta sesión? -> reutilización legítima
            if ($Contexto.ContainsKey('ObjetosCreados') -and
                $Contexto.ObjetosCreados.ContainsKey('AdministrativeUnits')) {
                foreach ($o in @($Contexto.ObjetosCreados['AdministrativeUnits'])) {
                    if ($o.datos -and $o.datos.objectId -and $o.datos.objectId -eq $objectIdExistente) {
                        return $false
                    }
                }
            }
            # 3. Existe en el tenant pero no lo creamos nosotros -> preexistente
            return $true
        }

        foreach ($auDef in @($Def)) {
            $displayName = $auDef.displayName
            $description = if ($auDef.PSObject.Properties['description'] -and $null -ne $auDef.description) { $auDef.description } else { '' }

            # --- 1. ¿Existe ya en el tenant? (consulta puntual) ---
            # N14: escapar comillas simples en el filtro OData
            $displayNameEscapado = $displayName -replace "'","''"
            $existing = Get-MgDirectoryAdministrativeUnit -Filter "displayName eq '$displayNameEscapado'" -ErrorAction SilentlyContinue
            if ($existing -is [array]) { $existing = $existing[0] }
            $existeEnTenant = ($null -ne $existing)

            # --- 2. N3: decidir si es preexistente ---
            if ($existeEnTenant) {
                $idExistente = $existing.Id
                if (& $esPreexistente $displayName $idExistente) {
                    Write-LabWarn "AU '$displayName' ya existía antes del laboratorio. No se adopta ni modifica."
                    $creados += [pscustomobject]@{
                        tipo          = 'AdministrativeUnit'
                        displayName   = $displayName
                        objectId      = $idExistente
                        estadoDetalle = 'preexistente'
                    }
                    continue
                }
                # Reutilización legítima (creada en esta misma sesión)
                Write-Verbose "   -> AU existe: $displayName (reutilizada en esta sesión)"
                $au = $existing
                $estadoDetalle = 'reutilizado'
            } else {
                $params = @{
                    DisplayName = $displayName
                    Description = $description
                }
                $au = New-MgDirectoryAdministrativeUnit -BodyParameter $params -ErrorAction Stop
                if ($null -eq $au) { throw "New-MgDirectoryAdministrativeUnit no devolvió objeto para $displayName" }
                if ($au -is [array]) { $au = $au[0] }
                Write-Verbose "   -> AU creada: $displayName"
                $estadoDetalle = 'creado'
            }

            $creados += [pscustomobject]@{
                tipo          = 'AdministrativeUnit'
                displayName   = $displayName
                objectId      = $au.Id
                estadoDetalle = $estadoDetalle
            }

            # --- 3. Añadir miembros ---
            if ($auDef.PSObject.Properties['members'] -and $null -ne $auDef.members) {
                foreach ($m in @($auDef.members)) {
                    $miembroId = $null
                    $miembroTipo = $null
                    $upn = $m -replace '\{tenant\}', $Contexto.TenantDomain

                    $user = Get-MgUser -UserId $upn -ErrorAction SilentlyContinue
                    if ($user) {
                        if ($user -is [array]) { $user = $user[0] }
                        $miembroId = $user.Id
                        $miembroTipo = 'Usuario'
                    } else {
                        # N14: escapar comillas simples
                        $mEscapado = $m -replace "'","''"
                        $group = Get-MgGroup -Filter "displayName eq '$mEscapado'" -ErrorAction SilentlyContinue
                        if ($group) {
                            if ($group -is [array]) { $group = $group[0] }
                            $miembroId = $group.Id
                            $miembroTipo = 'Grupo'
                        }
                    }

                    if (-not $miembroId) {
                        Write-LabWarn "Miembro '$m' no encontrado para AU '$displayName'; se omite."
                        continue
                    }

                    $miembrosActuales = Get-MgDirectoryAdministrativeUnitMember -AdministrativeUnitId $au.Id -All -ErrorAction SilentlyContinue
                    $yaEsMiembro = $false
                    foreach ($ma in @($miembrosActuales)) {
                        if ($ma.Id -eq $miembroId) { $yaEsMiembro = $true; break }
                    }

                    if ($yaEsMiembro) {
                        $estadoMiembro = 'reutilizado'
                    } else {
                        $body = @{ '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$miembroId" }
                        $null = New-MgDirectoryAdministrativeUnitMemberByRef -AdministrativeUnitId $au.Id -BodyParameter $body -ErrorAction Stop
                        $estadoMiembro = 'creado'
                    }

                    $creados += [pscustomobject]@{
                        tipo          = 'AdministrativeUnitMember'
                        administrativeUnitId = $au.Id
                        memberId      = $miembroId
                        memberType    = $miembroTipo
                        memberName    = $m
                        estadoDetalle = $estadoMiembro
                    }
                }
            }

            # --- 4. Asignar roles con ámbito de AU ---
            if ($auDef.PSObject.Properties['roles'] -and $null -ne $auDef.roles) {
                foreach ($r in @($auDef.roles)) {
                    $rolNombre = $r.rol
                    $upn = $r.usuario -replace '\{tenant\}', $Contexto.TenantDomain

                    $user = Get-MgUser -UserId $upn -ErrorAction SilentlyContinue
                    if (-not $user) {
                        Write-LabWarn "Usuario '$upn' no encontrado para rol '$rolNombre' en AU '$displayName'; se omite."
                        continue
                    }
                    if ($user -is [array]) { $user = $user[0] }

                    # N14: escapar comillas simples
                    $rolEscapado = $rolNombre -replace "'","''"
                    $roleDef = Get-MgRoleManagementDirectoryRoleDefinition -Filter "displayName eq '$rolEscapado'" -ErrorAction SilentlyContinue
                    if (-not $roleDef) {
                        Write-LabWarn "Rol '$rolNombre' no encontrado; se omite."
                        continue
                    }
                    if ($roleDef -is [array]) { $roleDef = $roleDef[0] }

                    $asignaciones = Get-MgRoleManagementDirectoryRoleAssignment -Filter "principalId eq '$($user.Id)' and roleDefinitionId eq '$($roleDef.Id)'" -ErrorAction SilentlyContinue
                    $yaAsignado = $false
                    foreach ($a in @($asignaciones)) {
                        if ($a.DirectoryScopeId -eq "/administrativeUnits/$($au.Id)") {
                            $yaAsignado = $true; break
                        }
                    }

                    if ($yaAsignado) {
                        $estadoRol = 'reutilizado'
                    } else {
                        $body = @{
                            DirectoryScopeId = "/administrativeUnits/$($au.Id)"
                            PrincipalId      = $user.Id
                            RoleDefinitionId = $roleDef.Id
                        }
                        try {
                            $null = New-MgRoleManagementDirectoryRoleAssignment -BodyParameter $body -ErrorAction Stop
                            $estadoRol = 'creado'
                        } catch {
                            Write-LabWarn "No se pudo asignar rol '$rolNombre' a '$upn' en AU '$displayName': $($_.Exception.Message)"
                            $estadoRol = 'fallido'
                        }
                    }

                    $creados += [pscustomobject]@{
                        tipo          = 'AdministrativeUnitRole'
                        administrativeUnitId = $au.Id
                        roleDefinitionId = $roleDef.Id
                        roleName      = $rolNombre
                        principalId   = $user.Id
                        principalUpn  = $upn
                        estadoDetalle = $estadoRol
                    }
                }
            }
        }

        return $creados
    }

    Revertir = {
        param($Objeto, $Contexto)

        if ($Objeto.tipo -eq 'AdministrativeUnitMember') {
            $auId = if ($Objeto.datos) { $Objeto.datos.administrativeUnitId } else { $null }
            $memberId = if ($Objeto.datos) { $Objeto.datos.memberId } else { $null }
            if (-not $auId -or -not $memberId) { return $true }

            try {
                $null = Remove-MgDirectoryAdministrativeUnitMemberByRef -AdministrativeUnitId $auId -DirectoryObjectId $memberId -Confirm:$false -ErrorAction Stop
                return $true
            } catch {
                if ($_.Exception.Message -match '404|not found|does not exist') { return $true }
                Write-LabWarn "No se pudo quitar el miembro '$memberId' de la AU '$auId': $($_.Exception.Message)"
                return $false
            }
        }

        if ($Objeto.tipo -eq 'AdministrativeUnitRole') {
            $auId = if ($Objeto.datos) { $Objeto.datos.administrativeUnitId } else { $null }
            $principalId = if ($Objeto.datos) { $Objeto.datos.principalId } else { $null }
            $roleDefinitionId = if ($Objeto.datos) { $Objeto.datos.roleDefinitionId } else { $null }
            if (-not $auId -or -not $principalId -or -not $roleDefinitionId) { return $true }

            try {
                $asignaciones = Get-MgRoleManagementDirectoryRoleAssignment -Filter "principalId eq '$principalId' and roleDefinitionId eq '$roleDefinitionId'" -ErrorAction SilentlyContinue
                $encontrada = $null
                foreach ($a in @($asignaciones)) {
                    if ($a.DirectoryScopeId -eq "/administrativeUnits/$auId") {
                        $encontrada = $a; break
                    }
                }
                if (-not $encontrada) { return $true }

                $null = Remove-MgRoleManagementDirectoryRoleAssignment -UnifiedRoleAssignmentId $encontrada.Id -Confirm:$false -ErrorAction Stop
                return $true
            } catch {
                if ($_.Exception.Message -match '404|not found|does not exist') { return $true }
                Write-LabWarn "No se pudo quitar el rol de la AU '$auId': $($_.Exception.Message)"
                return $false
            }
        }

        if ($Objeto.tipo -eq 'AdministrativeUnit') {
            $displayName = if ($Objeto.datos) { $Objeto.datos.displayName } else { $null }
            $objectIdEsperado = if ($Objeto.datos) { $Objeto.datos.objectId } else { $null }
            if ([string]::IsNullOrWhiteSpace($displayName) -and [string]::IsNullOrWhiteSpace($objectIdEsperado)) { return $false }

            try {
                $au = $null
                if ($objectIdEsperado) {
                    $au = Get-MgDirectoryAdministrativeUnit -AdministrativeUnitId $objectIdEsperado -ErrorAction SilentlyContinue
                }
                if (-not $au -and $displayName) {
                    # N14: escapar comillas simples
                    $dnEscapado = $displayName -replace "'","''"
                    $au = Get-MgDirectoryAdministrativeUnit -Filter "displayName eq '$dnEscapado'" -ErrorAction SilentlyContinue
                }
                if (-not $au) { return $true }
                if ($au -is [array]) { $au = $au[0] }

                if ($objectIdEsperado -and $au.Id -ne $objectIdEsperado) {
                    Write-LabWarn "La AU '$displayName' tiene un objectId distinto. No se borra."
                    return $false
                }

                $null = Remove-MgDirectoryAdministrativeUnit -AdministrativeUnitId $au.Id -Confirm:$false -ErrorAction Stop
                return $true
            } catch {
                if ($_.Exception.Message -match '404|not found|does not exist') { return $true }
                Write-LabWarn "No se pudo borrar la AU '$($Objeto.id)': $($_.Exception.Message)"
                return $false
            }
        }

        return $false
    }

    PreguntarUI = {
        param($Contexto)

        Show-LabBanner 'Nueva unidad administrativa'

        $displayName = Read-Host '  DisplayName de la AU'
        if ([string]::IsNullOrWhiteSpace($displayName)) { return $null }

        if ($Contexto.SnapshotPreLab -and
            $Contexto.SnapshotPreLab.ContainsKey('administrativeUnits') -and
            $Contexto.SnapshotPreLab.administrativeUnits.ContainsKey($displayName)) {
            Write-LabWarn "La AU '$displayName' ya existía antes del laboratorio. No se puede adoptar."
            return $null
        }

        $description = Read-Host '  Description (opcional)'

        $members = @()
        while ($true) {
            $m = Read-Host '  Miembro (UPN o displayName de grupo, Enter para terminar)'
            if ([string]::IsNullOrWhiteSpace($m)) { break }
            $members += $m
        }

        $roles = @()
        while ($true) {
            $rol = Read-Host '  Rol a asignar (ej. User Administrator, Enter para terminar)'
            if ([string]::IsNullOrWhiteSpace($rol)) { break }
            $usuario = Read-Host '    UPN del usuario para el rol'
            if ([string]::IsNullOrWhiteSpace($usuario)) { continue }
            $roles += [pscustomobject]@{ rol = $rol; usuario = $usuario }
        }

        return [pscustomobject]@{
            displayName = $displayName
            description = $description
            members     = $members
            roles       = $roles
        }
    }
}

$null = Register-LabCapacidad -Capacidad $Capacidad