<#
.SYNOPSIS
    Capacidad: Grupos con asignación de roles.
.DESCRIPTION
    Crea grupos de seguridad con IsAssignableToRole = $true, que pueden
    recibir roles de directorio de Entra ID.

    LICENCIA:
    Los grupos con asignación de roles requieren Microsoft Entra ID P1
    (o P2). TestDisponible consulta los SKUs del tenant (cacheada vía
    Get-LabSubscribedSku).

    SEGURIDAD DE PREEXISTENTES:
    - Si el displayName está en el snapshot pre-lab, el grupo existía
      antes del laboratorio. Se marca 'preexistente' y no se modifica.

    NIVEL: P1.
.NOTES
    Requiere PowerShell 7.
#>
#Requires -Version 7.0

# Set-StrictMode -Version Latest

$Capacidad = @{
    Nombre      = 'GruposRoleAssignable'
    Descripcion = 'Grupos con asignación de roles'
    SeccionJson = 'gruposRoleAssignable'
    Alias       = @('grupos_role_assignable', 'gruposAsignablesARoles')
    Nivel       = 'P1'
    DependeDe   = @()
    PermisosApp = @('Group.ReadWrite.All','Group.Create','RoleManagement.ReadWrite.Directory')

    TestDisponible = {
        param($Contexto)
        if (-not (Test-LabGraphSession)) {
            return [pscustomobject]@{ Disponible = $false; Motivo = 'Sin sesión de Graph' }
        }
        try {
            # N7: usar caché de SKUs
            $skus = @(Get-LabSubscribedSku)
            $tieneP1 = $false
            foreach ($sku in $skus) {
                if ($sku.PSObject.Properties['ServicePlans'] -and $null -ne $sku.ServicePlans) {
                    foreach ($plan in @($sku.ServicePlans)) {
                        if ($plan.ServicePlanName -in @('AAD_PREMIUM','AAD_PREMIUM_P2') -and $plan.ProvisioningStatus -eq 'Success') {
                            $tieneP1 = $true
                            break
                        }
                    }
                }
                if ($tieneP1) { break }
            }
            if (-not $tieneP1) {
                return [pscustomobject]@{ Disponible = $false; Motivo = 'Requiere licencia Entra ID P1 (AAD_PREMIUM)' }
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
            $description = if ($g.PSObject.Properties['description'] -and $null -ne $g.description) { $g.description } else { '' }

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

            # --- 2. ¿Existe ya? (N14: escapado OData + N21: normalizar array) ---
            $displayNameEscapado = $displayName -replace "'","''"
            $existingRaw = Get-MgGroup -Filter "displayName eq '$displayNameEscapado'" -ErrorAction SilentlyContinue
            $existingArr = @($existingRaw)
            if ($existingArr.Count -gt 0 -and $null -ne $existingArr[0]) {
                Write-Verbose "   -> Grupo existe: $displayName (reutilizado)"
                $grupo = $existingArr[0]
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
                    Write-LabWarn "No se pudo crear el grupo '$displayName': $($_.Exception.Message)"
                    continue
                }

                if ($null -eq $grupo) { throw "New-MgGroup no devolvió objeto para $displayName" }
                $grupoArr = @($grupo)
                $grupoObj = $grupoArr[0]
                Write-Verbose "   -> Grupo con asignación de roles creado: $displayName"
                $grupo = $grupoObj
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
                # N14: escapado OData
                $dnEscapado = $displayName -replace "'","''"
                $grupoCandidatos = @(Get-MgGroup -Filter "displayName eq '$dnEscapado'" -ErrorAction SilentlyContinue)
                if ($grupoCandidatos.Count -gt 0 -and $null -ne $grupoCandidatos[0]) {
                    $grupo = $grupoCandidatos[0]
                }
            }
            if (-not $grupo) { return $true }
            if ($grupo -is [array]) { $grupo = $grupo[0] }

            if (-not [string]::IsNullOrWhiteSpace($objectIdEsperado) -and
                $grupo.Id -ne $objectIdEsperado) {
                Write-LabWarn "El grupo '$displayName' tiene un objectId distinto. No se borra."
                return $false
            }

            # Vaciar miembros y owners antes de borrar
            try {
                $miembros = Get-MgGroupMember -GroupId $grupo.Id -All -ErrorAction SilentlyContinue
                foreach ($m in @($miembros)) {
                    $null = Remove-MgGroupMemberByRef -GroupId $grupo.Id -DirectoryObjectId $m.Id -Confirm:$false -ErrorAction SilentlyContinue
                }
            } catch { }

            try {
                $owners = Get-MgGroupOwner -GroupId $grupo.Id -All -ErrorAction SilentlyContinue
                foreach ($o in @($owners)) {
                    $null = Remove-MgGroupOwnerByRef -GroupId $grupo.Id -DirectoryObjectId $o.Id -Confirm:$false -ErrorAction SilentlyContinue
                }
            } catch { }

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

$null = Register-LabCapacidad -Capacidad $Capacidad