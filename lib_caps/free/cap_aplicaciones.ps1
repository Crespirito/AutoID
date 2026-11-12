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
.NOTES
    Requiere PowerShell 7.
#>
#Requires -Version 7.0

# Set-StrictMode -Version Latest

$Capacidad = @{
    Nombre      = 'Aplicaciones'
    Descripcion = 'Aplicaciones y Service Principals'
    SeccionJson = 'aplicaciones'
    Alias       = @('Aplicaciones', 'apps')
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
            $description = if ($a.PSObject.Properties['description'] -and $null -ne $a.description) { $a.description } else { '' }
            $signInAudience = if ($a.PSObject.Properties['signInAudience'] -and -not [string]::IsNullOrWhiteSpace($a.signInAudience)) {
                $a.signInAudience
            } else {
                'AzureADMyOrg'
            }
            $redirectUris = if ($a.PSObject.Properties['redirectUris'] -and $null -ne $a.redirectUris) {
                @($a.redirectUris)
            } else {
                @()
            }

            # N14: escapar comillas simples para filtros OData
            $displayNameEscapado = $displayName -replace "'","''"

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
            # N21: normalizar array vacío antes de acceder a [0]
            $existing = Get-MgApplication -Filter "displayName eq '$displayNameEscapado'" -ErrorAction SilentlyContinue
            $existingArr = @($existing)
            if ($existingArr.Count -gt 0) {
                $app = $existingArr[0]
                if ($null -ne $app) {
                    Write-Verbose "   -> Aplicación existe: $displayName (reutilizada)"
                    $estadoDetalle = 'reutilizado'
                } else {
                    Write-LabWarn "Get-MgApplication devolvió un array con $($existingArr.Count) entradas pero la primera es `$null. Se ignora."
                    $app = $null
                }
            }

            if ($null -eq $app) {
                $params = @{
                    DisplayName    = $displayName
                    SignInAudience = $signInAudience
                }
                if (-not [string]::IsNullOrWhiteSpace($description)) { $params.Description = $description }
                if ($redirectUris.Count -gt 0) { $params.Web = @{ RedirectUris = $redirectUris } }

                $nueva = New-MgApplication @params -ErrorAction Stop
                if ($null -eq $nueva) { throw "New-MgApplication no devolvió objeto para $displayName" }
                $nuevaArr = @($nueva)
                $app = $nuevaArr[0]
                Write-Verbose "   -> Aplicación creada: $displayName"
                $estadoDetalle = 'creado'
            }

            $appId = $app.AppId
            if ($appId -is [array]) { $appId = $appId[0] }
            $appId = [string]$appId

            $creados += [pscustomobject]@{
                tipo          = 'Aplicacion'
                displayName   = $displayName
                objectId      = $app.Id
                appId         = $appId
                estadoDetalle = $estadoDetalle
            }

            # --- 3. Service Principal asociado ---
            # N14: escapar appId (aunque es GUID, mantenemos consistencia)
            $appIdEscapado = $appId -replace "'","''"
            $existingSP = Get-MgServicePrincipal -Filter "appId eq '$appIdEscapado'" -ErrorAction SilentlyContinue
            $existingSPArr = @($existingSP)

            if ($existingSPArr.Count -gt 0 -and $null -ne $existingSPArr[0]) {
                $spExistente = $existingSPArr[0]
                Write-Verbose "   -> Service Principal existe para $displayName"
                $creados += [pscustomobject]@{
                    tipo          = 'ServicePrincipal'
                    displayName   = $displayName
                    appId         = $appId
                    objectId      = $spExistente.Id
                    estadoDetalle = 'reutilizado'
                }
            } else {
                $spParams = @{
                    AppId       = $appId
                    DisplayName = $displayName
                }
                $sp = New-MgServicePrincipal @spParams -ErrorAction Stop
                if ($null -eq $sp) { throw "New-MgServicePrincipal no devolvió objeto para $displayName" }
                $spArr = @($sp)
                $spObj = $spArr[0]
                Write-Verbose "   -> Service Principal creado para $displayName"
                $creados += [pscustomobject]@{
                    tipo          = 'ServicePrincipal'
                    displayName   = $displayName
                    appId         = $appId
                    objectId      = $spObj.Id
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
                    # N14: escapar appId
                    $appIdEscapado = $appId -replace "'","''"
                    $spCandidatos = @(Get-MgServicePrincipal -Filter "appId eq '$appIdEscapado'" -ErrorAction SilentlyContinue)
                    if ($spCandidatos.Count -gt 0 -and $null -ne $spCandidatos[0]) { $sp = $spCandidatos[0] }
                }
                if (-not $sp) { return $true }  # idempotente
                if ($sp -is [array]) { $sp = $sp[0] }

                if ($objectIdEsperado -and $sp.Id -ne $objectIdEsperado) {
                    Write-LabWarn "El SP '$($sp.Id)' tiene un objectId distinto al del manifiesto. No se borra."
                    return $false
                }

                # Quitar asignaciones antes de borrar (PS7 a veces requiere esto)
                try {
                    $asignaciones = Get-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $sp.Id -All -ErrorAction SilentlyContinue
                    foreach ($asig in @($asignaciones)) {
                        $null = Remove-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $sp.Id -AppRoleAssignmentId $asig.Id -Confirm:$false -ErrorAction SilentlyContinue
                    }
                } catch { }

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
                    # N14: escapar displayName
                    $dnEscapado = $displayName -replace "'","''"
                    $appCandidatos = @(Get-MgApplication -Filter "displayName eq '$dnEscapado'" -ErrorAction SilentlyContinue)
                    if ($appCandidatos.Count -gt 0 -and $null -ne $appCandidatos[0]) { $app = $appCandidatos[0] }
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

$null = Register-LabCapacidad -Capacidad $Capacidad