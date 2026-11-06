<#
.SYNOPSIS
    Capacidad: Grupos con asignación de roles.
.DESCRIPTION
    Crea grupos de seguridad con IsAssignableToRole = $true, que pueden
    recibir roles de directorio de Entra ID.

    LICENCIA:
    Los grupos con asignación de roles requieren Microsoft Entra ID P1
    (o P2, que incluye P1). TestDisponible consulta los SKUs del tenant
    y comprueba si existe el plan de servicio 'AAD_PREMIUM' o
    'AAD_PREMIUM_P2' con estado 'Success'. Si no existe, la capacidad
    no se ofrece en el menú manual y se omite en el flujo automático.

    SEGURIDAD DE PREEXISTENTES:
    - Si el displayName está en el snapshot pre-lab, el grupo existía
      antes del laboratorio. Se marca 'preexistente' y no se modifica.

    NIVEL: P1.
#>

$Capacidad = @{
    Nombre       = 'GruposRoleAssignable'
    Descripcion  = 'Grupos con asignación de roles'
    SeccionJson  = 'gruposRoleAssignable'
    Alias        = @('gruposRoleAssignable','grupos_role_assignable','gruposAsignablesARoles')
    Nivel        = 'P1'
    DependeDe    = @()
    PermisosApp  = @('Group.ReadWrite.All','Group.Create','RoleManagement.ReadWrite.Directory')

    TestDisponible = {
        param($Contexto)
        if (-not (Test-LabGraphSession)) {
            return [pscustomobject]@{ Disponible = $false; Motivo = 'Sin sesión de Graph' }
        }
        try {
            $skus = Get-MgSubscribedSku -ErrorAction Stop
            $tieneP1 = $false
            foreach ($sku in @($skus)) {
                foreach ($plan in @($sku.ServicePlans)) {
                    if ($plan.ServicePlanName -in @('AAD_PREMIUM','AAD_PREMIUM_P2') -and
                        $plan.ProvisioningStatus -eq 'Success') {
                        $tieneP1 = $true
                        break
                    }
                }
                if ($tieneP1) { break }
            }
            if (-not $tieneP1) {
                return [pscustomobject]@{
                    Disponible = $false
                    Motivo     = 'Requiere licencia Entra ID P1 (AAD_PREMIUM)'
                }
            }
            return [pscustomobject]@{ Disponible = $true; Motivo = $null }
        } catch {
            Write-LabWarn "No se pudieron consultar los SKUs del tenant: $($_.Exception.Message)"
            return [pscustomobject]@{ Disponible = $true; Motivo = $null }
        }
    }

    ValidarDef = {
        param($Def)
        $errores = @()
        $i = 0
        foreach ($g in @($Def)) {
            $i++
            if ([string]::IsNullOrWhiteSpace($g.displayName)) {
                $errores += "Grupo con asignación de roles #$i sin 'displayName'."
            }
        }
        return $errores
    }

    Describir = {
        param($Def)
        $nombres = @($Def) | ForEach-Object { $_.displayName }
        return "Grupos con asignación de roles ($($nombres.Count)): $($nombres -join ', ')"
    }

    Crear = {
        param($Def, $Contexto)

        $creados = @()

        foreach ($g in @($Def)) {
            $displayName = $g.displayName
            $description = if ($g.PSObject.Properties['description']) { $g.description } else { '' }

            # --- 1. Snapshot pre-lab ---
            if ($Contexto.SnapshotPreLab -and
                $Contexto.SnapshotPreLab.ContainsKey('grupos') -and
                $Contexto.SnapshotPreLab.grupos.ContainsKey($displayName)) {
                Write-LabWarn "El grupo '$displayName' ya existía antes del laboratorio. No se adopta."
                $creados += [pscustomobject]@{
                    tipo          = 'GrupoRoleAssignable'
                    displayName   = $displayName
                    objectId      = $Contexto.SnapshotPreLab.grupos[$displayName]
                    estadoDetalle = 'preexistente'
                }
                continue
            }

            # --- 2. ¿Existe ya? ---
            $existing = Get-MgGroup -Filter "displayName eq '$displayName'" -ErrorAction SilentlyContinue
            if ($existing) {
                if ($existing -is [array]) { $existing = $existing[0] }
                Write-Verbose "   -> Grupo existe: $displayName (reutilizado)"
                $grupo = $existing
                $estadoDetalle = 'reutilizado'
            } else {
                $mailNickname = $displayName -replace '[^a-zA-Z0-9]', ''
                $params = @{
                    DisplayName        = $displayName
                    Description        = $description
                    MailNickname       = $mailNickname
                    MailEnabled        = $false
                    SecurityEnabled    = $true
                    IsAssignableToRole = $true
                }

                try {
                    $grupo = New-MgGroup @params -ErrorAction Stop
                } catch {
                    if ($_.Exception.Message -match 'license|Premium|P1|P2') {
                        Write-LabWarn "No se pudo crear el grupo '$displayName': requiere licencia P1/P2. $($_.Exception.Message)"
                    } else {
                        Write-LabWarn "No se pudo crear el grupo '$displayName': $($_.Exception.Message)"
                    }
                    continue
                }

                if ($null -eq $grupo) { throw "New-MgGroup no devolvió objeto para $displayName" }
                if ($grupo -is [array]) { $grupo = $grupo[0] }
                Write-Verbose "   -> Grupo con asignación de roles creado: $displayName"
                $estadoDetalle = 'creado'
            }

            $creados += [pscustomobject]@{
                tipo          = 'GrupoRoleAssignable'
                displayName   = $displayName
                objectId      = $grupo.Id
                estadoDetalle = $estadoDetalle
            }
        }

        return $creados
    }

    Revertir = {
        param($Objeto, $Contexto)

        if ($Objeto.tipo -ne 'GrupoRoleAssignable') { return $false }

        $displayName = if ($Objeto.datos) { $Objeto.datos.displayName } else { $null }
        $objectIdEsperado = if ($Objeto.datos) { $Objeto.datos.objectId } else { $null }

        if ([string]::IsNullOrWhiteSpace($displayName) -and [string]::IsNullOrWhiteSpace($objectIdEsperado)) {
            Write-LabWarn "Grupo sin displayName ni objectId en el manifiesto: $($Objeto.id)"
            return $false
        }

        try {
            $grupo = $null
            if ($objectIdEsperado) {
                $grupo = Get-MgGroup -GroupId $objectIdEsperado -ErrorAction SilentlyContinue
            }
            if (-not $grupo -and $displayName) {
                $grupo = Get-MgGroup -Filter "displayName eq '$displayName'" -ErrorAction SilentlyContinue
            }
            if (-not $grupo) { return $true }
            if ($grupo -is [array]) { $grupo = $grupo[0] }

            if (-not [string]::IsNullOrWhiteSpace($objectIdEsperado) -and
                $grupo.Id -ne $objectIdEsperado) {
                Write-LabWarn "El grupo '$displayName' tiene un objectId distinto. No se borra."
                return $false
            }

            # Vaciar miembros y owners antes de borrar
            $miembros = Get-MgGroupMember -GroupId $grupo.Id -All -ErrorAction SilentlyContinue
            foreach ($m in $miembros) {
                $null = Remove-MgGroupMemberByRef -GroupId $grupo.Id -DirectoryObjectId $m.Id -Confirm:$false -ErrorAction SilentlyContinue
            }
            $owners = Get-MgGroupOwner -GroupId $grupo.Id -All -ErrorAction SilentlyContinue
            foreach ($o in $owners) {
                $null = Remove-MgGroupOwnerByRef -GroupId $grupo.Id -DirectoryObjectId $o.Id -Confirm:$false -ErrorAction SilentlyContinue
            }

            $null = Remove-MgGroup -GroupId $grupo.Id -Confirm:$false -ErrorAction Stop
            return $true
        } catch {
            if ($_.Exception.Message -match '404|not found|does not exist') { return $true }
            Write-LabWarn "No se pudo borrar el grupo '$($Objeto.id)': $($_.Exception.Message)"
            return $false
        }
    }

    PreguntarUI = {
        param($Contexto)

        Show-LabBanner 'Nuevo grupo con asignación de roles'

        $displayName = Read-Host '  DisplayName'
        if ([string]::IsNullOrWhiteSpace($displayName)) {
            Write-LabWarn 'DisplayName vacío. Cancelando.'
            return $null
        }

        if ($Contexto.SnapshotPreLab -and
            $Contexto.SnapshotPreLab.ContainsKey('grupos') -and
            $Contexto.SnapshotPreLab.grupos.ContainsKey($displayName)) {
            Write-LabWarn "El grupo '$displayName' ya existía antes del laboratorio. No se puede adoptar."
            return $null
        }

        $description = Read-Host '  Description (opcional)'

        return [pscustomobject]@{
            displayName = $displayName
            description = $description
        }
    }
}

Register-LabCapacidad -Capacidad $Capacidad