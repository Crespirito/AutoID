<#
.SYNOPSIS
    Capacidad: Aplicaciones y Service Principals.
.DESCRIPTION
    Crea aplicaciones en Entra ID a partir de la sección 'aplicaciones'
    del escenario, y su service principal asociado.

    Respeta el snapshot pre-lab: si el displayName de la aplicación ya
    existía antes del laboratorio, no la adopta ni la modifica. Si el SP
    asociado también existía antes, no lo toca.

    SEGURIDAD DE PREEXISTENTES:
    - Si la app está en $Contexto.SnapshotPreLab.aplicaciones, se marca
      'preexistente' y no se modifica.
    - Si la app no está en el snapshot pero existe en el tenant, se
      reutiliza y se marca 'reutilizado'.
    - Si no existe, se crea y se marca 'creado'.
    - El SP sigue la misma lógica, comprobando por appId.

    NIVEL: Free.
#>

$Capacidad = @{
    Nombre      = 'Aplicaciones'
    SeccionJson = 'aplicaciones'
    Alias       = @('Aplicaciones','aplicaciones','apps')
    Nivel       = 'Free'
    DependeDe   = @()
    PermisosApp = @('Application.ReadWrite.All','Directory.Read.All')

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
        foreach ($a in @($Def)) {
            $i++
            if ([string]::IsNullOrWhiteSpace($a.displayName)) {
                $errores += "Aplicación #$i sin 'displayName'."
            }
            if ($a.PSObject.Properties['redirectUris'] -and $null -ne $a.redirectUris) {
                foreach ($uri in @($a.redirectUris)) {
                    if ($uri -notmatch '^https?://') {
                        $errores += "Aplicación #$i con redirectUri inválido: '$uri'."
                    }
                }
            }
            if ($a.PSObject.Properties['signInAudience']) {
                $audiencias = @('AzureADMyOrg','AzureADMultipleOrgs','AzureADandPersonalMicrosoftAccount','PersonalMicrosoftAccount')
                if ($a.signInAudience -notin $audiencias) {
                    $errores += "Aplicación #$i con signInAudience inválido: '$($a.signInAudience)'."
                }
            }
        }
        return $errores
    }

    Describir = {
        param($Def)
        $nombres = @($Def) | ForEach-Object { $_.displayName }
        return "Aplicaciones ($($nombres.Count)): $($nombres -join ', ')"
    }

    Crear = {
        param($Def, $Contexto)

        $creados = @()

        foreach ($a in @($Def)) {
            $displayName = $a.displayName
            $description = if ($a.PSObject.Properties['description']) { $a.description } else { '' }
            $signInAudience = if ($a.PSObject.Properties['signInAudience'] -and $a.signInAudience) {
                $a.signInAudience
            } else {
                'AzureADMyOrg'
            }
            $redirectUris = if ($a.PSObject.Properties['redirectUris'] -and $null -ne $a.redirectUris) {
                @($a.redirectUris)
            } else {
                @()
            }

            # --- 1. Snapshot pre-lab ---
            if ($Contexto.SnapshotPreLab -and
                $Contexto.SnapshotPreLab.ContainsKey('aplicaciones') -and
                $Contexto.SnapshotPreLab.aplicaciones.ContainsKey($displayName)) {
                Write-LabWarn "Aplicación '$displayName' ya existía antes del laboratorio. No se adopta ni modifica."
                $creados += [pscustomobject]@{
                    tipo          = 'Aplicacion'
                    displayName   = $displayName
                    objectId      = $Contexto.SnapshotPreLab.aplicaciones[$displayName]
                    appId         = $null
                    estadoDetalle = 'preexistente'
                }
                continue
            }

            # --- 2. ¿Existe ya en el tenant? ---
            $existing = Get-MgApplication -Filter "displayName eq '$displayName'" -ErrorAction SilentlyContinue
            if ($existing) {
                if ($existing -is [array]) { $existing = $existing[0] }
                Write-Verbose "   -> Aplicación existe: $displayName (reutilizada)"
                $app = $existing
                $estadoDetalle = 'reutilizado'
            } else {
                $params = @{
                    DisplayName    = $displayName
                    SignInAudience = $signInAudience
                    Description    = $description
                }
                if ($redirectUris.Count -gt 0) {
                    $params.Web = @{ RedirectUris = $redirectUris }
                }

                $app = New-MgApplication @params -ErrorAction Stop
                if ($null -eq $app) { throw "New-MgApplication no devolvió objeto para $displayName" }
                if ($app -is [array]) { $app = $app[0] }
                Write-Verbose "   -> Aplicación creada: $displayName"
                $estadoDetalle = 'creado'
            }

            $appId = $app.AppId
            if ($appId -is [array]) { $appId = $appId[0] }
            $appId = $appId.ToString()

            $creados += [pscustomobject]@{
                tipo          = 'Aplicacion'
                displayName   = $displayName
                objectId      = $app.Id
                appId         = $appId
                estadoDetalle = $estadoDetalle
            }

            # --- 3. Service Principal asociado ---
            $existingSP = Get-MgServicePrincipal -Filter "appId eq '$appId'" -ErrorAction SilentlyContinue
            if ($existingSP) {
                if ($existingSP -is [array]) { $existingSP = $existingSP[0] }
                Write-Verbose "   -> Service Principal existe para $displayName"
                $creados += [pscustomobject]@{
                    tipo          = 'ServicePrincipal'
                    displayName   = $displayName
                    appId         = $appId
                    objectId      = $existingSP.Id
                    estadoDetalle = 'reutilizado'
                }
            } else {
                $spParams = @{
                    AppId       = $appId
                    DisplayName = $displayName
                }
                $sp = New-MgServicePrincipal @spParams -ErrorAction Stop
                if ($null -eq $sp) { throw "New-MgServicePrincipal no devolvió objeto para $displayName" }
                if ($sp -is [array]) { $sp = $sp[0] }
                Write-Verbose "   -> Service Principal creado para $displayName"
                $creados += [pscustomobject]@{
                    tipo          = 'ServicePrincipal'
                    displayName   = $displayName
                    appId         = $appId
                    objectId      = $sp.Id
                    estadoDetalle = 'creado'
                }
            }
        }

        return $creados
    }

    Revertir = {
        param($Objeto, $Contexto)

        if ($Objeto.tipo -eq 'ServicePrincipal') {
            $objectIdEsperado = if ($Objeto.datos) { $Objeto.datos.objectId } else { $null }
            $appId = if ($Objeto.datos) { $Objeto.datos.appId } else { $null }

            if ([string]::IsNullOrWhiteSpace($objectIdEsperado) -and [string]::IsNullOrWhiteSpace($appId)) {
                Write-LabWarn "ServicePrincipal sin objectId ni appId en el manifiesto: $($Objeto.id)"
                return $false
            }

            try {
                $sp = $null
                if ($objectIdEsperado) {
                    $sp = Get-MgServicePrincipal -ServicePrincipalId $objectIdEsperado -ErrorAction SilentlyContinue
                }
                if (-not $sp -and $appId) {
                    $sp = Get-MgServicePrincipal -Filter "appId eq '$appId'" -ErrorAction SilentlyContinue
                }
                if (-not $sp) { return $true }  # idempotente
                if ($sp -is [array]) { $sp = $sp[0] }

                if ($objectIdEsperado -and $sp.Id -ne $objectIdEsperado) {
                    Write-LabWarn "El SP '$($sp.Id)' tiene un objectId distinto al del manifiesto. No se borra."
                    return $false
                }

                # Quitar asignaciones antes de borrar
                $asignaciones = Get-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $sp.Id -All -ErrorAction SilentlyContinue
                foreach ($asig in $asignaciones) {
                    $null = Remove-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $sp.Id -AppRoleAssignmentId $asig.Id -Confirm:$false -ErrorAction SilentlyContinue
                }

                $null = Remove-MgServicePrincipal -ServicePrincipalId $sp.Id -Confirm:$false -ErrorAction Stop
                return $true
            } catch {
                Write-LabWarn "No se pudo borrar el SP '$($Objeto.id)': $($_.Exception.Message)"
                return $false
            }
        }

        if ($Objeto.tipo -eq 'Aplicacion') {
            $displayName = if ($Objeto.datos) { $Objeto.datos.displayName } else { $null }
            $objectIdEsperado = if ($Objeto.datos) { $Objeto.datos.objectId } else { $null }

            if ([string]::IsNullOrWhiteSpace($objectIdEsperado) -and [string]::IsNullOrWhiteSpace($displayName)) {
                Write-LabWarn "Aplicación sin objectId ni displayName en el manifiesto: $($Objeto.id)"
                return $false
            }

            try {
                $app = $null
                if ($objectIdEsperado) {
                    $app = Get-MgApplication -ApplicationId $objectIdEsperado -ErrorAction SilentlyContinue
                }
                if (-not $app -and $displayName) {
                    $app = Get-MgApplication -Filter "displayName eq '$displayName'" -ErrorAction SilentlyContinue
                }
                if (-not $app) { return $true }  # idempotente
                if ($app -is [array]) { $app = $app[0] }

                if ($objectIdEsperado -and $app.Id -ne $objectIdEsperado) {
                    Write-LabWarn "La aplicación '$displayName' tiene un objectId distinto al del manifiesto. No se borra."
                    return $false
                }

                $null = Remove-MgApplication -ApplicationId $app.Id -Confirm:$false -ErrorAction Stop
                return $true
            } catch {
                Write-LabWarn "No se pudo borrar la aplicación '$($Objeto.id)': $($_.Exception.Message)"
                return $false
            }
        }

        return $false
    }

    PreguntarUI = {
        param($Contexto)

        Show-LabBanner 'Nueva aplicación'

        $displayName = Read-Host '  DisplayName'
        if ([string]::IsNullOrWhiteSpace($displayName)) {
            Write-LabWarn 'DisplayName vacío. Cancelando.'
            return $null
        }

        # Snapshot pre-lab
        if ($Contexto.SnapshotPreLab -and
            $Contexto.SnapshotPreLab.ContainsKey('aplicaciones') -and
            $Contexto.SnapshotPreLab.aplicaciones.ContainsKey($displayName)) {
            Write-LabWarn "La aplicación '$displayName' ya existía antes del laboratorio. No se puede adoptar."
            return $null
        }

        $description = Read-Host '  Description (opcional)'

        Write-Host ''
        Write-Host '  SignInAudience:' -ForegroundColor Cyan
        Write-Host '    [1] AzureADMyOrg (por defecto)'
        Write-Host '    [2] AzureADMultipleOrgs'
        Write-Host '    [3] AzureADandPersonalMicrosoftAccount'
        $opAud = Read-Host '  Opción [1/2/3]'
        $signInAudience = switch ($opAud) {
            '2' { 'AzureADMultipleOrgs' }
            '3' { 'AzureADandPersonalMicrosoftAccount' }
            default { 'AzureADMyOrg' }
        }

        $uri = Read-Host '  Redirect URI (opcional, Enter para omitir)'
        $redirectUris = @()
        if (-not [string]::IsNullOrWhiteSpace($uri)) {
            $redirectUris = @($uri)
        }

        $def = [pscustomobject]@{
            displayName    = $displayName
            description    = $description
            signInAudience = $signInAudience
            redirectUris   = $redirectUris
        }
        return $def
    }
}

Register-LabCapacidad -Capacidad $Capacidad