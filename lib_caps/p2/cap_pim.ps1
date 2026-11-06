<#
.SYNOPSIS
    Capacidad: Roles elegibles de PIM.
.DESCRIPTION
    Asigna roles de directorio como elegibles (no activos) mediante
    Privileged Identity Management (PIM), a partir de la sección
    'pim' del escenario.

    Estructura de la sección 'pim':
      { usuario, rol, duracion?: 'PT8H', justificacion?: '...' }

    LICENCIA:
    PIM requiere Microsoft Entra ID P2 (o Entra ID Governance).
    TestDisponible consulta los SKUs del tenant y comprueba si existe
    el plan de servicio 'AAD_PREMIUM_P2' con estado 'Success'.
    Si no existe, la capacidad no se ofrece.

    SEGURIDAD DE PREEXISTENTES:
    - Si el usuario es preexistente (snapshot pre-lab), no se le asigna
      rol elegible y se marca 'preexistente'.

    DEPENDENCIAS: Usuarios.

    NIVEL: P2.
#>

$Capacidad = @{
    Nombre       = 'Pim'
    Descripcion  = 'Roles elegibles PIM'
    SeccionJson  = 'pim'
    Alias        = @('pim','PIM','rolesElegibles')
    Nivel        = 'P2'
    DependeDe    = @('Usuarios')
    PermisosApp  = @('RoleManagement.ReadWrite.Directory','User.Read.All')

    TestDisponible = {
        param($Contexto)
        if (-not (Test-LabGraphSession)) {
            return [pscustomobject]@{ Disponible = $false; Motivo = 'Sin sesión de Graph' }
        }
        try {
            $skus = Get-MgSubscribedSku -ErrorAction Stop
            $tieneP2 = $false
            foreach ($sku in @($skus)) {
                foreach ($plan in @($sku.ServicePlans)) {
                    if ($plan.ServicePlanName -eq 'AAD_PREMIUM_P2' -and
                        $plan.ProvisioningStatus -eq 'Success') {
                        $tieneP2 = $true
                        break
                    }
                }
                if ($tieneP2) { break }
            }
            if (-not $tieneP2) {
                return [pscustomobject]@{
                    Disponible = $false
                    Motivo     = 'Requiere licencia Entra ID P2 (AAD_PREMIUM_P2)'
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
        foreach ($p in @($Def)) {
            $i++
            if ([string]::IsNullOrWhiteSpace($p.usuario)) {
                $errores += "Rol PIM #$i sin 'usuario'."
            }
            if ([string]::IsNullOrWhiteSpace($p.rol)) {
                $errores += "Rol PIM #$i sin 'rol'."
            }
            if ($p.PSObject.Properties['duracion'] -and $p.duracion) {
                if ($p.duracion -notmatch '^PT\d+[HM]$') {
                    $errores += "Rol PIM #$i: 'duracion' inválida ('$($p.duracion)'). Formato esperado: PT8H, PT30M, etc."
                }
            }
        }
        return $errores
    }

    Describir = {
        param($Def)
        $nombres = @($Def) | ForEach-Object { "$($_.usuario) -> $($_.rol)" }
        return "Roles elegibles PIM ($($nombres.Count)): $($nombres -join ', ')"
    }

    Crear = {
        param($Def, $Contexto)

        $creados = @()

        foreach ($p in @($Def)) {
            $upn = $p.usuario -replace '\{tenant\}', $Contexto.TenantDomain
            $rolNombre = $p.rol
            $duracion = if ($p.PSObject.Properties['duracion'] -and $p.duracion) { $p.duracion } else { 'PT8H' }
            $justificacion = if ($p.PSObject.Properties['justificacion'] -and $p.justificacion) {
                $p.justificacion
            } else {
                'Asignación de laboratorio'
            }

            # --- 1. Snapshot pre-lab ---
            if ($Contexto.SnapshotPreLab -and
                $Contexto.SnapshotPreLab.ContainsKey('usuarios') -and
                $Contexto.SnapshotPreLab.usuarios.ContainsKey($upn.ToLowerInvariant())) {
                Write-LabWarn "El usuario '$upn' ya existía antes del laboratorio. No se le asigna rol PIM."
                $creados += [pscustomobject]@{
                    tipo          = 'PimEligibleRole'
                    upn           = $upn
                    rol           = $rolNombre
                    estadoDetalle = 'preexistente'
                }
                continue
            }

            # --- 2. Buscar usuario ---
            $user = Get-MgUser -UserId $upn -ErrorAction SilentlyContinue
            if (-not $user) {
                Write-LabWarn "Usuario '$upn' no encontrado para rol PIM; se omite."
                continue
            }
            if ($user -is [array]) { $user = $user[0] }

            # --- 3. Buscar rol ---
            $roleDef = Get-MgRoleManagementDirectoryRoleDefinition -Filter "displayName eq '$rolNombre'" -ErrorAction SilentlyContinue
            if (-not $roleDef) {
                Write-LabWarn "Rol '$rolNombre' no encontrado; se omite."
                continue
            }
            if ($roleDef -is [array]) { $roleDef = $roleDef[0] }

            # --- 4. Comprobar si ya tiene el rol elegible ---
            $requests = Get-MgRoleManagementDirectoryRoleEligibilityScheduleRequest `
                -Filter "principalId eq '$($user.Id)' and roleDefinitionId eq '$($roleDef.Id)'" `
                -All -ErrorAction SilentlyContinue
            $yaElegible = $false
            foreach ($r in @($requests)) {
                if ($r.Status -eq 'Provisioned' -and $r.DirectoryScopeId -eq '/') {
                    $yaElegible = $true; break
                }
            }

            if ($yaElegible) {
                Write-Verbose "   -> $upn ya tiene rol elegible '$rolNombre' (reutilizado)"
                $creados += [pscustomobject]@{
                    tipo          = 'PimEligibleRole'
                    upn           = $upn
                    rol           = $rolNombre
                    userId        = $user.Id
                    roleDefinitionId = $roleDef.Id
                    estadoDetalle = 'reutilizado'
                }
                continue
            }

            # --- 5. Crear la asignación elegible ---
            $body = @{
                action           = 'adminAssign'
                justification    = $justificacion
                roleDefinitionId = $roleDef.Id
                directoryScopeId = '/'
                principalId      = $user.Id
                scheduleInfo     = @{
                    startDateTime = (Get-Date).ToString('o')
                    expiration    = @{
                        type     = 'afterDuration'
                        duration = $duracion
                    }
                }
            }

            try {
                $resultado = New-MgRoleManagementDirectoryRoleEligibilityScheduleRequest -BodyParameter $body -ErrorAction Stop
                Write-Verbose "   -> Rol elegible '$rolNombre' asignado a '$upn'"
                $creados += [pscustomobject]@{
                    tipo               = 'PimEligibleRole'
                    upn                = $upn
                    rol                = $rolNombre
                    userId             = $user.Id
                    roleDefinitionId   = $roleDef.Id
                    scheduleRequestId  = $resultado.Id
                    estadoDetalle      = 'creado'
                }
            } catch {
                Write-LabWarn "No se pudo asignar rol elegible '$rolNombre' a '$upn': $($_.Exception.Message)"
            }
        }

        return $creados
    }

    Revertir = {
        param($Objeto, $Contexto)

        if ($Objeto.tipo -ne 'PimEligibleRole') { return $false }

        $userId = if ($Objeto.datos) { $Objeto.datos.userId } else { $null }
        $roleDefinitionId = if ($Objeto.datos) { $Objeto.datos.roleDefinitionId } else { $null }
        $scheduleRequestId = if ($Objeto.datos) { $Objeto.datos.scheduleRequestId } else { $null }

        # Si no hay datos suficientes, no hay nada que revertir
        if (-not $userId -or -not $roleDefinitionId) {
            return $true
        }

        try {
            # Buscar la request elegible activa
            $requests = Get-MgRoleManagementDirectoryRoleEligibilityScheduleRequest `
                -Filter "principalId eq '$userId' and roleDefinitionId eq '$roleDefinitionId'" `
                -All -ErrorAction SilentlyContinue

            $encontrada = $null
            foreach ($r in @($requests)) {
                if ($r.Status -eq 'Provisioned' -and $r.DirectoryScopeId -eq '/') {
                    $encontrada = $r; break
                }
            }

            if (-not $encontrada) { return $true }  # idempotente

            $null = Remove-MgRoleManagementDirectoryRoleEligibilityScheduleRequest `
                -UnifiedRoleEligibilityScheduleRequestId $encontrada.Id `
                -Confirm:$false -ErrorAction Stop
            return $true
        } catch {
            if ($_.Exception.Message -match '404|not found|does not exist') { return $true }
            Write-LabWarn "No se pudo revocar el rol elegible '$($Objeto.id)': $($_.Exception.Message)"
            return $false
        }
    }

    PreguntarUI = {
        param($Contexto)

        Show-LabBanner 'Nuevo rol elegible PIM'

        $upn = Read-Host '  UPN del usuario'
        if ([string]::IsNullOrWhiteSpace($upn)) {
            Write-LabWarn 'UPN vacío. Cancelando.'
            return $null
        }

        if ($Contexto.SnapshotPreLab -and
            $Contexto.SnapshotPreLab.ContainsKey('usuarios') -and
            $Contexto.SnapshotPreLab.usuarios.ContainsKey($upn.ToLowerInvariant())) {
            Write-LabWarn "El usuario '$upn' ya existía antes del laboratorio. No se le puede asignar rol PIM."
            return $null
        }

        $rol = Read-Host '  Nombre del rol (ej. Global Administrator, User Administrator)'
        if ([string]::IsNullOrWhiteSpace($rol)) {
            Write-LabWarn 'Rol vacío. Cancelando.'
            return $null
        }

        $duracion = Read-Host '  Duración [PT8H] (formato ISO 8601)'
        if ([string]::IsNullOrWhiteSpace($duracion)) { $duracion = 'PT8H' }

        return [pscustomobject]@{
            usuario    = $upn
            rol        = $rol
            duracion   = $duracion
        }
    }
}

Register-LabCapacidad -Capacidad $Capacidad