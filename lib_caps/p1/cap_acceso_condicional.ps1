<#
.SYNOPSIS
    Capacidad: Políticas de Acceso Condicional.
.DESCRIPTION
    Crea políticas de Acceso Condicional a partir de la sección
    'accesoCondicional' del escenario.

    Estructura de la sección 'accesoCondicional':
      {
        displayName,
        state: 'disabled' | 'enabled' | 'enabledForReportingButNotEnforced',
        conditions: { ... },       # condiciones de la política
        grantControls: { ... },    # controles de concesión
        sessionControls?: { ... }  # controles de sesión (opcional)
      }

    LICENCIA:
    El Acceso Condicional requiere Microsoft Entra ID P1 (o P2).
    TestDisponible consulta los SKUs del tenant y comprueba si existe
    el plan de servicio 'AAD_PREMIUM' o 'AAD_PREMIUM_P2' con estado
    'Success'. Si no existe, la capacidad no se ofrece.

    SEGURIDAD:
    - Por defecto, las políticas se crean en estado 'disabled' para que
      el operador las revise antes de habilitarlas. Si el escenario
      declara 'enabled', se respeta pero se avisa.
    - No se aplican políticas sobre objetos preexistentes: si la política
      ya existe (mismo displayName), se marca 'reutilizado'.
    - La reversión borra la política. Si la política estaba habilitada
      y bloqueaba el acceso, el operador debe revisarlo manualmente.

    NIVEL: P1.
#>

$Capacidad = @{
    Nombre       = 'AccesoCondicional'
    Descripcion  = 'Políticas de Acceso Condicional'
    SeccionJson  = 'accesoCondicional'
    Alias        = @('accesoCondicional','acceso_condicional','conditionalAccess')
    Nivel        = 'P1'
    DependeDe    = @()
    PermisosApp  = @('Policy.Read.All','Policy.ReadWrite.ConditionalAccess')

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
        foreach ($p in @($Def)) {
            $i++
            if ([string]::IsNullOrWhiteSpace($p.displayName)) {
                $errores += "Política de Acceso Condicional #$i sin 'displayName'."
            }
            if ((Get-LabPropiedadValor -Objeto $p -Nombre 'state') -and $p.state) {
                if ($p.state -notin @('disabled','enabled','enabledForReportingButNotEnforced')) {
                    $errores += "Política #$i con 'state' inválido: '$($p.state)'."
                }
            }
            if (-not ((Get-LabPropiedadValor -Objeto $p -Nombre 'conditions')) -or $null -eq $p.conditions) {
                $errores += "Política #$i sin 'conditions'."
            }
            if (-not ((Get-LabPropiedadValor -Objeto $p -Nombre 'grantControls')) -or $null -eq $p.grantControls) {
                $errores += "Política #$i sin 'grantControls'."
            }
        }
        return $errores
    }

    Describir = {
        param($Def)
        $nombres = @($Def) | ForEach-Object {
<<<<<<< Updated upstream
            $state = if ($_.PSObject.Properties['state']) { $_.state } else { 'disabled' }
=======
            $state = if ((Get-LabPropiedadValor -Objeto $_ -Nombre 'state')) { $_.state } else { 'disabled' }
>>>>>>> Stashed changes
            "$($_.displayName) [$state]"
        }
        return "Políticas de Acceso Condicional ($(@($nombres).Count)): $($nombres -join ', ')"
    }

    Crear = {
        param($Def, $Contexto)

        $creados = @()

        foreach ($p in @($Def)) {
            $displayName = $p.displayName
<<<<<<< Updated upstream
            $state = if ($p.PSObject.Properties['state'] -and $p.state) { $p.state } else { 'disabled' }
=======
            $state = if ((Get-LabPropiedadValor -Objeto $p -Nombre 'state') -and $p.state) { $p.state } else { 'disabled' }
>>>>>>> Stashed changes

            # Aviso si la política se crea habilitada
            if ($state -eq 'enabled') {
                Write-LabWarn "La política '$displayName' se creará HABILITADA. Revisa las condiciones antes de continuar."
            }

            # --- 1. ¿Existe ya? ---
            $existing = Get-MgIdentityConditionalAccessPolicy -Filter "displayName eq '$displayName'" -ErrorAction SilentlyContinue
            if ($existing) {
                if ($existing -is [array]) { $existing = $existing[0] }
                Write-Verbose "   -> Política existe: $displayName (reutilizada)"
                $creados += [pscustomobject]@{
                    tipo          = 'AccesoCondicional'
                    displayName   = $displayName
                    objectId      = $existing.Id
                    state         = $existing.State
                    estadoDetalle = 'reutilizado'
                }
                continue
            }

            # --- 2. Construir BodyParameter ---
            $body = @{
                displayName = $displayName
                state       = $state
                conditions  = $p.conditions
                grantControls = $p.grantControls
            }
<<<<<<< Updated upstream
            if ($p.PSObject.Properties['sessionControls'] -and $null -ne $p.sessionControls) {
=======
            if ((Get-LabPropiedadValor -Objeto $p -Nombre 'sessionControls') -and $null -ne $p.sessionControls) {
>>>>>>> Stashed changes
                $body['sessionControls'] = $p.sessionControls
            }

            # --- 3. Crear política ---
            try {
                $politica = New-MgIdentityConditionalAccessPolicy -BodyParameter $body -ErrorAction Stop
                if ($null -eq $politica) { throw "New-MgIdentityConditionalAccessPolicy no devolvió objeto para $displayName" }
                if ($politica -is [array]) { $politica = $politica[0] }
                Write-Verbose "   -> Política creada: $displayName (state: $state)"
                $creados += [pscustomobject]@{
                    tipo          = 'AccesoCondicional'
                    displayName   = $displayName
                    objectId      = $politica.Id
                    state         = $state
                    estadoDetalle = 'creado'
                }
            } catch {
                Write-LabWarn "No se pudo crear la política '$displayName': $($_.Exception.Message)"
            }
        }

        return $creados
    }

    Revertir = {
        param($Objeto, $Contexto)

        if ($Objeto.tipo -ne 'AccesoCondicional') { return $false }

        $displayName = if ($Objeto.datos) { $Objeto.datos.displayName } else { $null }
        $objectIdEsperado = if ($Objeto.datos) { $Objeto.datos.objectId } else { $null }

        if ([string]::IsNullOrWhiteSpace($displayName) -and [string]::IsNullOrWhiteSpace($objectIdEsperado)) {
            Write-LabWarn "Política sin displayName ni objectId en el manifiesto: $($Objeto.id)"
            return $false
        }

        try {
            $politica = $null
            if ($objectIdEsperado) {
                $politica = Get-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $objectIdEsperado -ErrorAction SilentlyContinue
            }
            if (-not $politica -and $displayName) {
                $politica = Get-MgIdentityConditionalAccessPolicy -Filter "displayName eq '$displayName'" -ErrorAction SilentlyContinue
            }
            if (-not $politica) { return $true }  # idempotente
            if ($politica -is [array]) { $politica = $politica[0] }

            if (-not [string]::IsNullOrWhiteSpace($objectIdEsperado) -and
                $politica.Id -ne $objectIdEsperado) {
                Write-LabWarn "La política '$displayName' tiene un objectId distinto. No se borra."
                return $false
            }

            # Aviso si la política estaba habilitada
            if ($politica.State -eq 'enabled') {
                Write-LabWarn "La política '$displayName' estaba HABILITADA. Se va a borrar. Revisa el impacto."
            }

            $null = Remove-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $politica.Id -Confirm:$false -ErrorAction Stop
            return $true
        } catch {
            if ($_.Exception.Message -match '404|not found|does not exist') { return $true }
            Write-LabWarn "No se pudo borrar la política '$($Objeto.id)': $($_.Exception.Message)"
            return $false
        }
    }

    PreguntarUI = {
        param($Contexto)

        Show-LabBanner 'Nueva política de Acceso Condicional'

        $displayName = Read-Host '  DisplayName de la política'
        if ([string]::IsNullOrWhiteSpace($displayName)) {
            Write-LabWarn 'DisplayName vacío. Cancelando.'
            return $null
        }

        Write-Host ''
        Write-Host '  Estado inicial:' -ForegroundColor Cyan
        Write-Host '    [1] disabled (recomendado, revisar antes de habilitar)'
        Write-Host '    [2] enabledForReportingButNotEnforced (solo reporte)'
        Write-Host '    [3] enabled (aplicar inmediatamente)'
        $opState = Read-Host '  Opción [1/2/3]'
        $state = switch ($opState) {
            '2' { 'enabledForReportingButNotEnforced' }
            '3' { 'enabled' }
            default { 'disabled' }
        }

        # Condiciones básicas: usuarios, aplicaciones, ubicaciones
        Write-Host ''
        Write-Host '  Condiciones (deja vacío para "All"):' -ForegroundColor Cyan
        $incluirUsuarios = Read-Host '  Incluir usuarios (UPN separados por coma, vacío = All)'
        $incluirApps = Read-Host '  Incluir aplicaciones (AppId separados por coma, vacío = All)'

        $conditions = @{
            users = @{
                includeUsers = if ([string]::IsNullOrWhiteSpace($incluirUsuarios)) { @('All') } else { @($incluirUsuarios -split ',' | ForEach-Object { $_.Trim() }) }
            }
            applications = @{
                includeApplications = if ([string]::IsNullOrWhiteSpace($incluirApps)) { @('All') } else { @($incluirApps -split ',' | ForEach-Object { $_.Trim() }) }
            }
        }

        # Controles de concesión
        Write-Host ''
        Write-Host '  Controles de concesión:' -ForegroundColor Cyan
        Write-Host '    [1] Requerir MFA'
        Write-Host '    [2] Bloquear acceso'
        $opGrant = Read-Host '  Opción [1/2]'

        $grantControls = if ($opGrant -eq '2') {
            @{ operator = 'OR'; builtInControls = @('block') }
        } else {
            @{ operator = 'OR'; builtInControls = @('mfa') }
        }

        return [pscustomobject]@{
            displayName   = $displayName
            state         = $state
            conditions    = $conditions
            grantControls = $grantControls
        }
    }
}

Register-LabCapacidad -Capacidad $Capacidad
