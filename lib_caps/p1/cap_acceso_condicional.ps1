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
        conditions: { ... },
        grantControls: { ... },
        sessionControls?: { ... }
      }

    LICENCIA:
    El Acceso Condicional requiere Microsoft Entra ID P1 (o P2).
    TestDisponible consulta los SKUs del tenant (cacheada vía
    Get-LabSubscribedSku).

    SEGURIDAD:
    - Por defecto, las políticas se crean en estado 'disabled' para que
      el operador las revise antes de habilitarlas. Si el escenario
      declara 'enabled', se respeta pero se avisa.
    - Si la política ya existe (mismo displayName), se marca 'reutilizado'.
    - La reversión borra la política.

    NIVEL: P1.
.NOTES
    Requiere PowerShell 7.
#>
#Requires -Version 7.0

# Set-StrictMode -Version Latest

$Capacidad = @{
    Nombre      = 'AccesoCondicional'
    Descripcion = 'Políticas de Acceso Condicional'
    SeccionJson = 'accesoCondicional'
    Alias       = @('acceso_condicional', 'conditionalAccess')
    Nivel       = 'P1'
    DependeDe   = @()
    PermisosApp = @('Policy.Read.All','Policy.ReadWrite.ConditionalAccess')

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
        foreach ($p in @($Def)) {
            $i++
            if ([string]::IsNullOrWhiteSpace($p.displayName)) {
                $errores += "Política de Acceso Condicional #$i sin 'displayName'."
            }
            if ($p.PSObject.Properties['state'] -and $p.state) {
                if ($p.state -notin @('disabled','enabled','enabledForReportingButNotEnforced')) {
                    $errores += "Política #$i con 'state' inválido: '$($p.state)'."
                }
            }
            if (-not $p.PSObject.Properties['conditions'] -or $null -eq $p.conditions) {
                $errores += "Política #$i sin 'conditions'."
            }
            if (-not $p.PSObject.Properties['grantControls'] -or $null -eq $p.grantControls) {
                $errores += "Política #$i sin 'grantControls'."
            }
        }
        return $errores
    }

    Describir = {
        param($Def)
        $nombres = @($Def) | ForEach-Object {
            $state = if ($_.PSObject.Properties['state'] -and $_.state) { $_.state } else { 'disabled' }
            "$($_.displayName) [$state]"
        }
        return "Políticas de Acceso Condicional ($($nombres.Count)): $($nombres -join ', ')"
    }

    Crear = {
        param($Def, $Contexto)

        $creados = @()

        foreach ($p in @($Def)) {
            $displayName = $p.displayName
            $state = if ($p.PSObject.Properties['state'] -and -not [string]::IsNullOrWhiteSpace($p.state)) { $p.state } else { 'disabled' }

            if ($state -eq 'enabled') {
                Write-LabWarn "La política '$displayName' se creará HABILITADA. Revisa las condiciones antes de continuar."
            }

            # --- 1. ¿Existe ya? (N14: escapado OData + N21: normalizar array) ---
            $displayNameEscapado = $displayName -replace "'","''"
            $existingRaw = Get-MgIdentityConditionalAccessPolicy -Filter "displayName eq '$displayNameEscapado'" -ErrorAction SilentlyContinue
            $existingArr = @($existingRaw)
            if ($existingArr.Count -gt 0) {
                $existing = $existingArr[0]
                if ($null -ne $existing) {
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
            }

            # --- 2. Construir BodyParameter ---
            $conditionsHash = @{}
            if ($p.conditions) {
                foreach ($prop in $p.conditions.PSObject.Properties) {
                    $conditionsHash[$prop.Name] = $prop.Value
                }
            }

            $grantControlsHash = @{}
            if ($p.grantControls) {
                foreach ($prop in $p.grantControls.PSObject.Properties) {
                    $grantControlsHash[$prop.Name] = $prop.Value
                }
            }

            $body = @{
                displayName = $displayName
                state       = $state
                conditions  = $conditionsHash
                grantControls = $grantControlsHash
            }
            
            if ($p.PSObject.Properties['sessionControls'] -and $null -ne $p.sessionControls) {
                $sessionControlsHash = @{}
                foreach ($prop in $p.sessionControls.PSObject.Properties) {
                    $sessionControlsHash[$prop.Name] = $prop.Value
                }
                $body['sessionControls'] = $sessionControlsHash
            }

            # --- 3. Crear política ---
            try {
                $politica = New-MgIdentityConditionalAccessPolicy -BodyParameter $body -ErrorAction Stop
                if ($null -eq $politica) { throw "New-MgIdentityConditionalAccessPolicy no devolvió objeto para $displayName" }
                $politicaArr = @($politica)
                $politicaObj = $politicaArr[0]
                Write-Verbose "   -> Política creada: $displayName (state: $state)"
                $creados += [pscustomobject]@{
                    tipo          = 'AccesoCondicional'
                    displayName   = $displayName
                    objectId      = $politicaObj.Id
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
                # N14: escapado OData
                $dnEscapado = $displayName -replace "'","''"
                $politicaCandidatos = @(Get-MgIdentityConditionalAccessPolicy -Filter "displayName eq '$dnEscapado'" -ErrorAction SilentlyContinue)
                if ($politicaCandidatos.Count -gt 0 -and $null -ne $politicaCandidatos[0]) {
                    $politica = $politicaCandidatos[0]
                }
            }
            if (-not $politica) { return $true }
            if ($politica -is [array]) { $politica = $politica[0] }

            if (-not [string]::IsNullOrWhiteSpace($objectIdEsperado) -and
                $politica.Id -ne $objectIdEsperado) {
                Write-LabWarn "La política '$displayName' tiene un objectId distinto. No se borra."
                return $false
            }

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

$null = Register-LabCapacidad -Capacidad $Capacidad