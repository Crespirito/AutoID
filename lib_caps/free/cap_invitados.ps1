<#
.SYNOPSIS
    Capacidad: Usuarios invitados (B2B guests).
.DESCRIPTION
    Invita usuarios externos como guests a Entra ID a partir de la sección
    'invitados' del escenario.

    Un guest es un objeto User con userType = 'Guest'. La invitación se
    crea con New-MgInvitation, que devuelve un InvitationId. El cleanup
    borra el usuario guest resultante, no la invitación (que es efímera).

    SEGURIDAD DE PREEXISTENTES:
    - Si el email del invitado ya corresponde a un usuario en el tenant,
      se marca 'reutilizado' y no se invita de nuevo.
    - Si el snapshot pre-lab contiene el email, se marca 'preexistente'.
    - Si no existe, se invita y se marca 'creado'.

    DEPENDENCIAS: ninguna.
    NIVEL: Free.
.NOTES
    Requiere PowerShell 7.
#>
#Requires -Version 7.0

# Set-StrictMode -Version Latest

$Capacidad = @{
    Nombre      = 'Invitados'
    Descripcion = 'Usuarios invitados B2B (guests)'
    SeccionJson = 'invitados'
    Alias       = @('guests')
    Nivel       = 'Free'
    DependeDe   = @()
    PermisosApp = @('User.Invite.All','User.ReadWrite.All')

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
        foreach ($inv in @($Def)) {
            $i++
            if ([string]::IsNullOrWhiteSpace($inv.email)) {
                $errores += "Invitado #$i sin 'email'."
            } elseif ($inv.email -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
                $errores += "Invitado #$i con email inválido: '$($inv.email)'."
            }
            if ([string]::IsNullOrWhiteSpace($inv.displayName)) {
                $errores += "Invitado #$i sin 'displayName'."
            }
            if ($inv.PSObject.Properties['redirectUrl'] -and $null -ne $inv.redirectUrl) {
                if ($inv.redirectUrl -notmatch '^https?://') {
                    $errores += "Invitado #$i con redirectUrl inválido: '$($inv.redirectUrl)'."
                }
            }
        }
        return $errores
    }

    Describir = {
        param($Def)
        $nombres = @($Def) | ForEach-Object { "$($_.displayName) <$($_.email)>" }
        return "Invitados ($($nombres.Count)): $($nombres -join ', ')"
    }

    Crear = {
        param($Def, $Contexto)

        $creados = @()

        foreach ($inv in @($Def)) {
            $email = $inv.email
            $displayName = $inv.displayName
            
            $redirectUrl = if ($inv.PSObject.Properties['redirectUrl'] -and -not [string]::IsNullOrWhiteSpace($inv.redirectUrl)) {
                $inv.redirectUrl
            } else {
                'https://myapplications.microsoft.com'
            }
            
            $sendMessage = $true
            if ($inv.PSObject.Properties['sendMessage'] -and $null -ne $inv.sendMessage) {
                $sendMessage = [bool]$inv.sendMessage
            }

            $emailKey = $email.ToLowerInvariant()

            # --- 1. Snapshot pre-lab ---
            if ($Contexto.SnapshotPreLab -and
                $Contexto.SnapshotPreLab.ContainsKey('usuarios') -and
                $Contexto.SnapshotPreLab.usuarios.ContainsKey($emailKey)) {
                Write-LabWarn "El invitado '$email' ya existía antes del laboratorio. No se adopta."
                $creados += [pscustomobject]@{
                    tipo          = 'Invitado'
                    email         = $email
                    displayName   = $displayName
                    objectId      = $Contexto.SnapshotPreLab.usuarios[$emailKey]
                    estadoDetalle = 'preexistente'
                }
                continue
            }

            # --- 2. ¿Existe ya como usuario en el tenant? ---
            # N14: escapado OData
            $emailEscapado = $email -replace "'","''"
            $existing = Get-MgUser -Filter "mail eq '$emailEscapado'" -ErrorAction SilentlyContinue
            if ($existing) {
                if ($existing -is [array]) { $existing = $existing[0] }
                Write-Verbose "   -> Invitado ya existe: $email (reutilizado)"
                $creados += [pscustomobject]@{
                    tipo          = 'Invitado'
                    email         = $email
                    displayName   = $displayName
                    objectId      = $existing.Id
                    upn           = $existing.UserPrincipalName
                    estadoDetalle = 'reutilizado'
                }
                continue
            }

            # --- 3. Invitar ---
            $params = @{
                InvitedUserEmailAddress = $email
                InvitedUserDisplayName  = $displayName
                InviteRedirectUrl       = $redirectUrl
                SendInvitationMessage   = $sendMessage
            }

            try {
                $invitacion = New-MgInvitation @params -ErrorAction Stop
            } catch {
                Write-LabWarn "No se pudo invitar a '$email': $($_.Exception.Message)"
                continue
            }

            if ($null -eq $invitacion) {
                Write-LabWarn "New-MgInvitation no devolvió objeto para '$email'."
                continue
            }

            # El usuario guest tarda un momento en crearse en el tenant
            Start-Sleep -Seconds 2
            # N14: escapado OData
            $guestUser = Get-MgUser -Filter "mail eq '$emailEscapado'" -ErrorAction SilentlyContinue
            $objectId = $null
            $upn = $null
            if ($guestUser) {
                if ($guestUser -is [array]) { $guestUser = $guestUser[0] }
                $objectId = $guestUser.Id
                $upn = $guestUser.UserPrincipalName
            }

            Write-Verbose "   -> Invitación creada para '$email'"
            $creados += [pscustomobject]@{
                tipo           = 'Invitado'
                email          = $email
                displayName    = $displayName
                objectId       = $objectId
                upn            = $upn
                invitationId   = $invitacion.Id
                estadoDetalle  = 'creado'
            }
        }

        return $creados
    }

    Revertir = {
        param($Objeto, $Contexto)

        if ($Objeto.tipo -ne 'Invitado') { return $false }

        $objectIdEsperado = if ($Objeto.datos) { $Objeto.datos.objectId } else { $null }
        $email = if ($Objeto.datos) { $Objeto.datos.email } else { $null }
        $upn = if ($Objeto.datos) { $Objeto.datos.upn } else { $null }

        if ([string]::IsNullOrWhiteSpace($objectIdEsperado) -and
            [string]::IsNullOrWhiteSpace($upn) -and
            [string]::IsNullOrWhiteSpace($email)) {
            Write-LabWarn "Invitado sin identificadores en el manifiesto: $($Objeto.id)"
            return $false
        }

        try {
            # Buscar el usuario guest
            $guestUser = $null
            if ($objectIdEsperado) {
                $guestUser = Get-MgUser -UserId $objectIdEsperado -ErrorAction SilentlyContinue
            }
            if (-not $guestUser -and $upn) {
                $guestUser = Get-MgUser -UserId $upn -ErrorAction SilentlyContinue
            }
            if (-not $guestUser -and $email) {
                # N14: escapado OData
                $emailEscapado = $email -replace "'","''"
                $guestUser = Get-MgUser -Filter "mail eq '$emailEscapado'" -ErrorAction SilentlyContinue
            }

            if (-not $guestUser) { return $true }
            if ($guestUser -is [array]) { $guestUser = $guestUser[0] }

            if (-not [string]::IsNullOrWhiteSpace($objectIdEsperado) -and
                $guestUser.Id -ne $objectIdEsperado) {
                Write-LabWarn "El invitado '$email' tiene un objectId distinto al del manifiesto. No se borra."
                return $false
            }

            $null = Remove-MgUser -UserId $guestUser.Id -Confirm:$false -ErrorAction Stop
            return $true
        } catch {
            Write-LabWarn "No se pudo borrar el invitado '$($Objeto.id)': $($_.Exception.Message)"
            return $false
        }
    }

    PreguntarUI = {
        param($Contexto)

        Show-LabBanner 'Nuevo usuario invitado (guest)'

        $email = Read-Host '  Email del invitado'
        if ([string]::IsNullOrWhiteSpace($email)) {
            Write-LabWarn 'Email vacío. Cancelando.'
            return $null
        }
        if ($email -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
            Write-LabWarn 'Email inválido. Cancelando.'
            return $null
        }

        if ($Contexto.SnapshotPreLab -and
            $Contexto.SnapshotPreLab.ContainsKey('usuarios') -and
            $Contexto.SnapshotPreLab.usuarios.ContainsKey($email.ToLowerInvariant())) {
            Write-LabWarn "El invitado '$email' ya existía antes del laboratorio. No se puede adoptar."
            return $null
        }

        $displayName = Read-Host '  DisplayName'
        if ([string]::IsNullOrWhiteSpace($displayName)) { $displayName = $email }

        $redirectUrl = Read-Host '  Redirect URL [https://myapplications.microsoft.com]'
        if ([string]::IsNullOrWhiteSpace($redirectUrl)) { $redirectUrl = 'https://myapplications.microsoft.com' }

        $enviar = Read-Host '  ¿Enviar email de invitación? (SI/N) [SI]'
        $sendMessage = ($enviar -ne 'N')

        return [pscustomobject]@{
            email        = $email
            displayName  = $displayName
            redirectUrl  = $redirectUrl
            sendMessage  = $sendMessage
        }
    }
}

$null = Register-LabCapacidad -Capacidad $Capacidad