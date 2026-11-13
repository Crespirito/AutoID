<#
.SYNOPSIS
    Capacidad: Grupos de seguridad.
.DESCRIPTION
    Crea grupos de seguridad en Entra ID a partir de la sección 'grupos'
    del escenario.

    Las relaciones de membresía (usuario -> grupo) se gestionan en
    cap_relaciones.ps1, que depende de esta capacidad y de Usuarios.

    SEGURIDAD DE PREEXISTENTES:
    - Si el displayName está en $Contexto.SnapshotPreLab.grupos, el grupo
      existía antes del lab. Se marca 'preexistente' y no se modifica.
    - Si no está en el snapshot pero existe en el tenant, se reutiliza.
    - Si no existe, se crea.

    NIVEL: Free.
#>

$Capacidad = @{
    Nombre      = 'Grupos'
    Descripcion = 'Grupos de seguridad'
    SeccionJson = 'grupos'
    Alias       = @('Grupos','grupos')
    Nivel       = 'Free'
    DependeDe   = @()
    PermisosApp = @('Group.ReadWrite.All')

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
        foreach ($g in @($Def)) {
            $i++
            if ([string]::IsNullOrWhiteSpace($g.displayName)) {
                $errores += "Grupo #$i sin 'displayName'."
            }
        }
        return $errores
    }

    Describir = {
        param($Def)
        $nombres = @($Def) | ForEach-Object { $_.displayName }
        return "Grupos ($(@($nombres).Count)): $($nombres -join ', ')"
    }

    Crear = {
        param($Def, $Contexto)

        $creados = @()

        foreach ($g in @($Def)) {
            $displayName = $g.displayName
<<<<<<< Updated upstream
            $description = if ($g.PSObject.Properties['description']) { $g.description } else { '' }
            $mailNickname = if ($g.PSObject.Properties['mailNickname'] -and $g.mailNickname) {
=======
            $description = if ((Get-LabPropiedadValor -Objeto $g -Nombre 'description')) { $g.description } else { '' }
            $mailNickname = if ((Get-LabPropiedadValor -Objeto $g -Nombre 'mailNickname') -and $g.mailNickname) {
>>>>>>> Stashed changes
                $g.mailNickname
            } else {
                $displayName -replace '[^a-zA-Z0-9]', ''
            }

            # --- 1. Snapshot pre-lab ---
            if ($Contexto.SnapshotPreLab -and
                $Contexto.SnapshotPreLab.ContainsKey('grupos') -and
                $Contexto.SnapshotPreLab.grupos.ContainsKey($displayName)) {
                Write-LabWarn "Grupo '$displayName' ya existía antes del laboratorio. No se adopta ni modifica."
                $creados += [pscustomobject]@{
                    tipo          = 'Grupo'
                    displayName   = $displayName
                    objectId      = $Contexto.SnapshotPreLab.grupos[$displayName]
                    estadoDetalle = 'preexistente'
                }
                continue
            }

            # --- 2. ¿Existe ya en el tenant? ---
            $existing = Get-MgGroup -Filter "displayName eq '$displayName'" -ErrorAction SilentlyContinue
            if ($existing) {
                if ($existing -is [array]) { $existing = $existing[0] }
                Write-Verbose "   -> Grupo existe: $displayName (reutilizado)"
                $grupo = $existing
                $estadoDetalle = 'reutilizado'
            } else {
                $params = @{
                    DisplayName     = $displayName
                    Description     = $description
                    MailNickname    = $mailNickname
                    MailEnabled     = $false
                    SecurityEnabled = $true
                }
                $grupo = New-MgGroup @params -ErrorAction Stop
                if ($null -eq $grupo) { throw "New-MgGroup no devolvió objeto para $displayName" }
                if ($grupo -is [array]) { $grupo = $grupo[0] }
                Write-Verbose "   -> Grupo creado: $displayName"
                $estadoDetalle = 'creado'
            }

            $creados += [pscustomobject]@{
                tipo          = 'Grupo'
                displayName   = $displayName
                objectId      = $grupo.Id
                estadoDetalle = $estadoDetalle
            }
        }

        return $creados
    }

    Revertir = {
        param($Objeto, $Contexto)

        if ($Objeto.tipo -ne 'Grupo') { return $false }

        $displayName = $null
        $objectIdEsperado = $null
        if ($Objeto.datos) {
            if ((Get-LabPropiedadValor -Objeto $Objeto.datos -Nombre 'displayName')) { $displayName = $Objeto.datos.displayName }
            if ((Get-LabPropiedadValor -Objeto $Objeto.datos -Nombre 'objectId'))    { $objectIdEsperado = $Objeto.datos.objectId }
        }
        if ([string]::IsNullOrWhiteSpace($displayName)) {
            Write-LabWarn "Grupo sin displayName en el manifiesto: $($Objeto.id)"
            return $false
        }

        try {
            $grupo = Get-MgGroup -Filter "displayName eq '$displayName'" -ErrorAction SilentlyContinue
            if (-not $grupo) { return $true }
            if ($grupo -is [array]) { $grupo = $grupo[0] }

            if (-not [string]::IsNullOrWhiteSpace($objectIdEsperado) -and
                $grupo.Id -ne $objectIdEsperado) {
                Write-LabWarn "El grupo '$displayName' tiene un objectId distinto al del manifiesto. No se borra."
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
            Write-LabWarn "No se pudo borrar el grupo '$displayName': $($_.Exception.Message)"
            return $false
        }
    }

    PreguntarUI = {
        param($Contexto)

        Show-LabBanner 'Nuevo grupo'

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
            displayName  = $displayName
            description  = $description
            mailNickname = ($displayName -replace '[^a-zA-Z0-9]', '')
        }
    }
}

Register-LabCapacidad -Capacidad $Capacidad
