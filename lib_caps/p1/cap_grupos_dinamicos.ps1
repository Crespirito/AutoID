<#
.SYNOPSIS
    Capacidad: Grupos dinámicos.
.DESCRIPTION
    Crea grupos de seguridad con membresía dinámica (DynamicMembership)
    a partir de la sección 'gruposDinamicos' del escenario.

    LICENCIA:
    Los grupos dinámicos requieren Microsoft Entra ID P1 (o P2).
    TestDisponible consulta los SKUs del tenant (cacheada vía
    Get-LabSubscribedSku).

    SEGURIDAD DE PREEXISTENTES:
    - Si el displayName está en el snapshot pre-lab, el grupo existía antes
      del laboratorio. Se marca 'preexistente' y no se modifica.

    NIVEL: P1.
.NOTES
    Requiere PowerShell 7.
#>
#Requires -Version 7.0

# Set-StrictMode -Version Latest

$Capacidad = @{
    Nombre      = 'GruposDinamicos'
    Descripcion = 'Grupos dinámicos'
    SeccionJson = 'gruposDinamicos'
    Alias       = @('dynamicGroups', 'dynamic_groups')
    Nivel       = 'P1'
    DependeDe   = @()
    PermisosApp = @('Group.ReadWrite.All','Group.Create')

    TestDisponible = {
        param($Contexto)
        if (-not (Test-LabGraphSession)) {
            return [pscustomobject]@{ Disponible = $false; Motivo = 'Sin sesión de Graph' }
        }
        try {
            # N7: usar caché
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
                $errores += "Grupo dinámico #$i sin 'displayName'."
            }
            if ([string]::IsNullOrWhiteSpace($g.membershipRule)) {
                $errores += "Grupo dinámico #$i sin 'membershipRule'."
            } else {
                if (-not ($g.membershipRule -match '^\s*\(')) {
                    # CORREGIDO: sintaxis de variables
                    $errores += "Grupo dinámico #${i}: 'membershipRule' debe empezar por '('."
                }
            }
            if ($g.PSObject.Properties['processingState'] -and $g.processingState) {
                if ($g.processingState -notin @('On','Paused')) {
                    # CORREGIDO: sintaxis de variables
                    $errores += "Grupo dinámico #${i}: 'processingState' inválido ('$($g.processingState)'). Debe ser 'On' o 'Paused'."
                }
            }
        }
        return $errores
    }

    Describir = {
        param($Def)
        $nombres = @($Def) | ForEach-Object { $_.displayName }
        return "Grupos dinámicos ($($nombres.Count)): $($nombres -join ', ')"
    }

    Crear = {
        param($Def, $Contexto)

        $creados = @()

        foreach ($g in @($Def)) {
            $displayName = $g.displayName
            $description = if ($g.PSObject.Properties['description'] -and $null -ne $g.description) { $g.description } else { '' }
            $membershipRule = $g.membershipRule
            $processingState = if ($g.PSObject.Properties['processingState'] -and -not [string]::IsNullOrWhiteSpace($g.processingState)) {
                $g.processingState
            } else {
                'On'
            }

            # --- 1. Snapshot pre-lab ---
            if ($Contexto.SnapshotPreLab -and
                $Contexto.SnapshotPreLab.ContainsKey('grupos') -and
                $Contexto.SnapshotPreLab.grupos.ContainsKey($displayName)) {
                Write-LabWarn "Grupo dinámico '$displayName' ya existía antes del laboratorio. No se adopta."
                $creados += [pscustomobject]@{
                    tipo          = 'GrupoDinamico'
                    displayName   = $displayName
                    objectId      = $Contexto.SnapshotPreLab.grupos[$displayName]
                    estadoDetalle = 'preexistente'
                }
                continue
            }

            # --- 2. ¿Existe ya? ---
            # N14: escapado OData
            $displayNameEscapado = $displayName -replace "'","''"
            $existing = Get-MgGroup -Filter "displayName eq '$displayNameEscapado'" -ErrorAction SilentlyContinue
            if ($existing) {
                if ($existing -is [array]) { $existing = $existing[0] }
                Write-Verbose "   -> Grupo dinámico existe: $displayName (reutilizado)"
                $grupo = $existing
                $estadoDetalle = 'reutilizado'
            } else {
                $mailNickname = $displayName -replace '[^a-zA-Z0-9]', ''
                $params = @{
                    DisplayName                   = $displayName
                    Description                   = $description
                    MailNickname                  = $mailNickname
                    MailEnabled                   = $false
                    SecurityEnabled               = $true
                    GroupTypes                    = @('DynamicMembership')
                    MembershipRule                = $membershipRule
                    MembershipRuleProcessingState = $processingState
                }

                try {
                    $grupo = New-MgGroup @params -ErrorAction Stop
                } catch {
                    Write-LabWarn "No se pudo crear el grupo dinámico '$displayName': $($_.Exception.Message)"
                    continue
                }

                if ($null -eq $grupo) { throw "New-MgGroup no devolvió objeto para $displayName" }
                if ($grupo -is [array]) { $grupo = $grupo[0] }
                Write-Verbose "   -> Grupo dinámico creado: $displayName"
                $estadoDetalle = 'creado'
            }

            $creados += [pscustomobject]@{
                tipo           = 'GrupoDinamico'
                displayName    = $displayName
                objectId       = $grupo.Id
                membershipRule = $membershipRule
                estadoDetalle  = $estadoDetalle
            }
        }

        return $creados
    }

    Revertir = {
        param($Objeto, $Contexto)

        if ($Objeto.tipo -ne 'GrupoDinamico') { return $false }

        $displayName = if ($Objeto.datos) { $Objeto.datos.displayName } else { $null }
        $objectIdEsperado = if ($Objeto.datos) { $Objeto.datos.objectId } else { $null }

        if ([string]::IsNullOrWhiteSpace($displayName) -and [string]::IsNullOrWhiteSpace($objectIdEsperado)) {
            Write-LabWarn "Grupo dinámico sin displayName ni objectId en el manifiesto: $($Objeto.id)"
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
                $grupo = Get-MgGroup -Filter "displayName eq '$dnEscapado'" -ErrorAction SilentlyContinue
            }
            if (-not $grupo) { return $true }
            if ($grupo -is [array]) { $grupo = $grupo[0] }

            if (-not [string]::IsNullOrWhiteSpace($objectIdEsperado) -and
                $grupo.Id -ne $objectIdEsperado) {
                Write-LabWarn "El grupo dinámico '$displayName' tiene un objectId distinto. No se borra."
                return $false
            }

            $null = Remove-MgGroup -GroupId $grupo.Id -Confirm:$false -ErrorAction Stop
            return $true
        } catch {
            if ($_.Exception.Message -match '404|not found|does not exist') { return $true }
            Write-LabWarn "No se pudo borrar el grupo dinámico '$($Objeto.id)': $($_.Exception.Message)"
            return $false
        }
    }

    PreguntarUI = {
        param($Contexto)

        Show-LabBanner 'Nuevo grupo dinámico'

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

        Write-Host ''
        Write-Host '  Regla de membresía (sintaxis de Entra ID):' -ForegroundColor Cyan
        Write-Host '    Ejemplos:' -ForegroundColor Gray
        Write-Host '      (user.userType -eq "Guest")' -ForegroundColor Gray
        Write-Host '      (user.department -eq "Ventas")' -ForegroundColor Gray
        Write-Host '      (user.accountEnabled -eq true)' -ForegroundColor Gray
        $membershipRule = Read-Host '  Regla'
        if ([string]::IsNullOrWhiteSpace($membershipRule)) {
            Write-LabWarn 'Regla vacía. Cancelando.'
            return $null
        }

        $state = Read-Host '  ProcessingState [On/Paused] (Enter = On)'
        $processingState = if ($state -eq 'Paused') { 'Paused' } else { 'On' }

        return [pscustomobject]@{
            displayName     = $displayName
            description     = $description
            membershipRule  = $membershipRule
            processingState = $processingState
        }
    }
}

$null = Register-LabCapacidad -Capacidad $Capacidad