<#
.SYNOPSIS
    Capacidad: Licencias de Microsoft 365.
.DESCRIPTION
    Asigna licencias de Microsoft 365 a usuarios a partir de la sección
    'licencias' del escenario.

    Estructura de la sección 'licencias':
      { usuario, skuPartNumber, disabledPlans?: [servicePlanName] }

    El SkuId se resuelve desde Get-MgSubscribedSku usando el SkuPartNumber
    (por ejemplo 'SPE_E5', 'AAD_PREMIUM', 'ENTERPRISEPACK'). Si el tenant
    no tiene ese SKU suscrito, se avisa y se omite.

    SEGURIDAD DE PREEXISTENTES:
    - Si el usuario es preexistente (snapshot pre-lab), no se le asigna
      licencia y se marca 'preexistente'.
    - Si el usuario ya tenía la licencia, se marca 'reutilizado'.
    - Si no, se asigna y se marca 'creado'.

    DEPENDENCIAS: Usuarios (necesita el objectId del usuario).

    NIVEL: Free (asignar licencias no requiere P1/P2 para el operador;
    el tenant debe tener los SKUs suscritos).
#>

$Capacidad = @{
    Nombre       = 'Licencias'
    Descripcion  = 'Licencias de Microsoft 365'
    SeccionJson  = 'licencias'
    Alias        = @('licencias','licenses')
    Nivel        = 'Free'
    DependeDe    = @('Usuarios')
    PermisosApp  = @('LicenseAssignment.ReadWrite.All','User.Read.All','Organization.Read.All')

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
        foreach ($l in @($Def)) {
            $i++
            if ([string]::IsNullOrWhiteSpace($l.usuario)) {
                $errores += "Licencia #$i sin 'usuario'."
            }
            if ([string]::IsNullOrWhiteSpace($l.skuPartNumber)) {
                $errores += "Licencia #$i sin 'skuPartNumber'."
            }
            if ((Get-LabPropiedadValor -Objeto $l -Nombre 'disabledPlans') -and $null -ne $l.disabledPlans) {
                foreach ($dp in @($l.disabledPlans)) {
                    if ([string]::IsNullOrWhiteSpace($dp)) {
                        $errores += "Licencia #$i con disabledPlan vacío."
                    }
                }
            }
        }
        return $errores
    }

    Describir = {
        param($Def)
        $nombres = @($Def) | ForEach-Object { "$($_.usuario) -> $($_.skuPartNumber)" }
        return "Licencias ($(@($nombres).Count)): $($nombres -join ', ')"
    }

    Crear = {
        param($Def, $Contexto)

        $creados = @()

        # Cache de SKUs del tenant
        $skusTenant = @{}
        try {
            $skus = Get-MgSubscribedSku -All -ErrorAction Stop
            foreach ($sku in @($skus)) {
                $skusTenant[$sku.SkuPartNumber] = $sku
            }
        } catch {
            Write-LabWarn "No se pudieron consultar los SKUs del tenant: $($_.Exception.Message)"
        }

        foreach ($l in @($Def)) {
            $upn = $l.usuario -replace '\{tenant\}', $Contexto.TenantDomain
            $skuPartNumber = $l.skuPartNumber

            # --- 1. Snapshot pre-lab ---
            if ($Contexto.SnapshotPreLab -and
                $Contexto.SnapshotPreLab.ContainsKey('usuarios') -and
                $Contexto.SnapshotPreLab.usuarios.ContainsKey($upn.ToLowerInvariant())) {
                Write-LabWarn "El usuario '$upn' ya existía antes del laboratorio. No se le asigna licencia."
                $creados += [pscustomobject]@{
                    tipo          = 'Licencia'
                    upn           = $upn
                    skuPartNumber = $skuPartNumber
                    estadoDetalle = 'preexistente'
                }
                continue
            }

            # --- 2. Resolver SKU ---
            if (-not $skusTenant.ContainsKey($skuPartNumber)) {
                Write-LabWarn "El SKU '$skuPartNumber' no está suscrito en el tenant. Se omite licencia para '$upn'."
                continue
            }
            $sku = $skusTenant[$skuPartNumber]
            $skuId = $sku.SkuId

            # --- 3. Buscar usuario ---
            $user = Get-MgUser -UserId $upn -ErrorAction SilentlyContinue
            if (-not $user) {
                Write-LabWarn "Usuario '$upn' no encontrado para asignar licencia; se omite."
                continue
            }
            if ($user -is [array]) { $user = $user[0] }

            # --- 4. Comprobar si ya tiene la licencia ---
            $yaTiene = $false
            if ($user.AssignedLicenses) {
                foreach ($al in @($user.AssignedLicenses)) {
                    if ($al.SkuId -eq $skuId) { $yaTiene = $true; break }
                }
            }

            if ($yaTiene) {
                Write-Verbose "   -> $upn ya tiene la licencia '$skuPartNumber' (reutilizado)"
                $creados += [pscustomobject]@{
                    tipo          = 'Licencia'
                    upn           = $upn
                    skuPartNumber = $skuPartNumber
                    skuId         = $skuId
                    userId        = $user.Id
                    estadoDetalle = 'reutilizado'
                }
                continue
            }

            # --- 5. Construir AddLicenses ---
            $addLicense = @{ SkuId = $skuId }

<<<<<<< Updated upstream
            if ($l.PSObject.Properties['disabledPlans'] -and $null -ne $l.disabledPlans) {
=======
            if ((Get-LabPropiedadValor -Objeto $l -Nombre 'disabledPlans') -and $null -ne $l.disabledPlans) {
>>>>>>> Stashed changes
                $disabledIds = @()
                foreach ($dpName in @($l.disabledPlans)) {
                    $plan = $null
                    foreach ($sp in @($sku.ServicePlans)) {
                        if ($sp.ServicePlanName -eq $dpName) { $plan = $sp; break }
                    }
                    if ($plan) {
                        $disabledIds += $plan.ServicePlanId
                    } else {
                        Write-LabWarn "El plan '$dpName' no existe en el SKU '$skuPartNumber'; se ignora."
                    }
                }
                if ($disabledIds.Count -gt 0) {
                    $addLicense['DisabledPlans'] = $disabledIds
                }
            }

            # --- 6. Asignar ---
            try {
                $null = Set-MgUserLicense -UserId $user.Id -AddLicenses @($addLicense) -RemoveLicenses @() -ErrorAction Stop
                Write-Verbose "   -> Licencia '$skuPartNumber' asignada a '$upn'"
                $creados += [pscustomobject]@{
                    tipo          = 'Licencia'
                    upn           = $upn
                    skuPartNumber = $skuPartNumber
                    skuId         = $skuId
                    userId        = $user.Id
                    estadoDetalle = 'creado'
                }
            } catch {
                Write-LabWarn "No se pudo asignar la licencia '$skuPartNumber' a '$upn': $($_.Exception.Message)"
            }
        }

        return $creados
    }

    Revertir = {
        param($Objeto, $Contexto)

        if ($Objeto.tipo -ne 'Licencia') { return $false }

        $userId = if ($Objeto.datos) { $Objeto.datos.userId } else { $null }
        $skuId = if ($Objeto.datos) { $Objeto.datos.skuId } else { $null }

        if (-not $userId -or -not $skuId) {
            # Preexistente o sin datos: no hay nada que revertir
            return $true
        }

        try {
            # Comprobar si el usuario todavía tiene la licencia
            $user = Get-MgUser -UserId $userId -Property 'id,assignedLicenses' -ErrorAction SilentlyContinue
            if (-not $user) { return $true }  # idempotente
            if ($user -is [array]) { $user = $user[0] }

            $tieneLicencia = $false
            if ($user.AssignedLicenses) {
                foreach ($al in @($user.AssignedLicenses)) {
                    if ($al.SkuId -eq $skuId) { $tieneLicencia = $true; break }
                }
            }
            if (-not $tieneLicencia) { return $true }  # idempotente

            $null = Set-MgUserLicense -UserId $userId -AddLicenses @() -RemoveLicenses @($skuId) -ErrorAction Stop
            return $true
        } catch {
            Write-LabWarn "No se pudo quitar la licencia '$($Objeto.id)': $($_.Exception.Message)"
            return $false
        }
    }

    PreguntarUI = {
        param($Contexto)

        Show-LabBanner 'Nueva asignación de licencia'

        $upn = Read-Host '  UPN del usuario'
        if ([string]::IsNullOrWhiteSpace($upn)) {
            Write-LabWarn 'UPN vacío. Cancelando.'
            return $null
        }

        # Snapshot pre-lab
        if ($Contexto.SnapshotPreLab -and
            $Contexto.SnapshotPreLab.ContainsKey('usuarios') -and
            $Contexto.SnapshotPreLab.usuarios.ContainsKey($upn.ToLowerInvariant())) {
            Write-LabWarn "El usuario '$upn' ya existía antes del laboratorio. No se le puede asignar licencia."
            return $null
        }

        # Mostrar SKUs disponibles
        try {
            $skus = Get-MgSubscribedSku -All -ErrorAction SilentlyContinue
            if ($skus) {
                Write-Host ''
                Write-Host '  SKUs disponibles en el tenant:' -ForegroundColor Cyan
                foreach ($s in @($skus)) {
                    Write-Host "    - $($s.SkuPartNumber) (SkuId: $($s.SkuId))"
                }
                Write-Host ''
            }
        } catch { }

        $skuPartNumber = Read-Host '  SkuPartNumber (ej. SPE_E5, AAD_PREMIUM)'
        if ([string]::IsNullOrWhiteSpace($skuPartNumber)) {
            Write-LabWarn 'SkuPartNumber vacío. Cancelando.'
            return $null
        }

        $disabled = Read-Host '  DisabledPlans (separados por coma, Enter para omitir)'
        $disabledPlans = @()
        if (-not [string]::IsNullOrWhiteSpace($disabled)) {
            $disabledPlans = @($disabled -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        }

        return [pscustomobject]@{
            usuario       = $upn
            skuPartNumber = $skuPartNumber
            disabledPlans = $disabledPlans
        }
    }
}

Register-LabCapacidad -Capacidad $Capacidad
