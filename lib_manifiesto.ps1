<#
.SYNOPSIS
    Librería de gestión del manifiesto del laboratorio.
.DESCRIPTION
    Proporciona:
      - Ruta canónica del manifiesto (manifiesto_lab.json)
      - Existencia del manifiesto
      - Lectura normalizada: arrays garantizados, propiedades por defecto
        y deduplicación de entradas
      - Estado resumido para mostrar en el menú
      - Guardado del manifiesto (para creauto.ps1 y creamanual.ps1)
      - Renombrado del manifiesto a "procesado" (para clean_up.ps1)
.NOTES
    Depende de lib_ui.ps1 (funciones Write-Lab*).
    Se carga por dot-sourcing.
    Guardar este fichero como UTF-8 con BOM para compatibilidad con PS 5.1.
#>
#Requires -Version 5.1

# ============================================================
# RUTA CANÓNICA
# ============================================================
$script:LabManifiestoFileName = "manifiesto_lab.json"
$script:LabManifiestoPath     = Join-Path $PSScriptRoot $script:LabManifiestoFileName

# ============================================================
# FUNCIONES PÚBLICAS
# ============================================================

function Get-LabManifiestoPath {
    <#
    .SYNOPSIS
        Devuelve la ruta absoluta del manifiesto estándar.
    #>
    return $script:LabManifiestoPath
}

function Test-LabManifiestoExists {
    <#
    .SYNOPSIS
        Devuelve $true si existe el manifiesto estándar.
    #>
    return (Test-Path $script:LabManifiestoPath)
}

function Get-LabManifiesto {
    <#
    .SYNOPSIS
        Lee y normaliza el manifiesto. Devuelve $null si no existe.
    .DESCRIPTION
        Garantiza que las propiedades Usuarios, Grupos, Aplicaciones y
        ServicePrincipals son siempre arrays (incluso si el JSON las
        omite o las guarda como valor único) y que no contienen
        duplicados. Esto permite usar .Count con StrictMode activo sin
        errores y evita que clean_up.ps1 intente borrar dos veces el
        mismo objeto.
    .PARAMETER Path
        Ruta alternativa del manifiesto. Si se omite, se usa la estándar.
    .OUTPUTS
        PSCustomObject normalizado o $null si no existe el fichero.
    #>
    param(
        [string]$Path = $null
    )

    if (-not $Path) { $Path = $script:LabManifiestoPath }
    if (-not (Test-Path $Path)) { return $null }

    $m = Get-Content -Path $Path -Raw -Encoding UTF8 | ConvertFrom-Json

    # Helper local para leer una propiedad con fallback y deduplicar.
    $leerColeccion = {
        param($origen, $nombre)
        if ($origen.PSObject.Properties[$nombre]) {
            @($origen.$nombre) | Select-Object -Unique
        } else {
            @()
        }
    }

    return [pscustomobject]@{
        Fecha             = if ($m.PSObject.Properties['Fecha'])             { $m.Fecha }             else { $null }
        TenantId          = if ($m.PSObject.Properties['TenantId'])          { $m.TenantId }          else { $null }
        TenantDomain      = if ($m.PSObject.Properties['TenantDomain'])      { $m.TenantDomain }      else { $null }
        Usuarios          = & $leerColeccion $m 'Usuarios'
        Grupos            = & $leerColeccion $m 'Grupos'
        Aplicaciones      = & $leerColeccion $m 'Aplicaciones'
        ServicePrincipals = & $leerColeccion $m 'ServicePrincipals'
    }
}

function Get-LabManifiestoStatus {
    <#
    .SYNOPSIS
        Devuelve un resumen del manifiesto para mostrar en el menú.
    .OUTPUTS
        $null               si no existe manifiesto
        "ilegible"          si existe pero no se puede leer
        PSCustomObject      con Fecha, Tenant, Usuarios, Grupos, Apps, SPs
    #>
    if (-not (Test-LabManifiestoExists)) { return $null }

    try {
        $m = Get-LabManifiesto -Path $script:LabManifiestoPath
        return [pscustomobject]@{
            Fecha    = $m.Fecha
            Tenant   = $m.TenantDomain
            Usuarios = $m.Usuarios.Count
            Grupos   = $m.Grupos.Count
            Apps     = $m.Aplicaciones.Count
            SPs      = $m.ServicePrincipals.Count
        }
    } catch {
        return "ilegible"
    }
}

function New-LabManifiestoVacio {
    <#
    .SYNOPSIS
        Devuelve la estructura base del manifiesto, lista para rellenar.
    .DESCRIPTION
        Lo usan los scripts de creación para inicializar el manifiesto
        antes de ir añadiendo objetos.
    .OUTPUTS
        OrderedDictionary con Fecha, TenantId, TenantDomain y arrays vacíos.
    #>
    return [ordered]@{
        Fecha             = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss")
        TenantId          = $null
        TenantDomain      = $null
        Usuarios          = @()
        Grupos            = @()
        Aplicaciones      = @()
        ServicePrincipals = @()
    }
}

function Save-LabManifiesto {
    <#
    .SYNOPSIS
        Guarda el manifiesto en disco.
    .PARAMETER Manifiesto
        El objeto (ordered o pscustomobject) a guardar.
    .PARAMETER Path
        Ruta destino. Si se omite, se usa la estándar.
    .OUTPUTS
        $true si se guardó correctamente, $false si falló.
    #>
    param(
        [Parameter(Mandatory=$true)]
        [object]$Manifiesto,

        [string]$Path = $null
    )

    if (-not $Path) { $Path = $script:LabManifiestoPath }

    try {
        $Manifiesto | ConvertTo-Json -Depth 5 | Set-Content -Path $Path -Encoding UTF8 -Force
        return $true
    } catch {
        Write-LabWarn "No se pudo guardar el manifiesto: $($_.Exception.Message)"
        return $false
    }
}

function Rename-LabManifiestoProcesado {
    <#
    .SYNOPSIS
        Renombra el manifiesto actual con sufijo _procesado_<timestamp>.
    .DESCRIPTION
        Lo usa clean_up.ps1 al terminar para evitar reprocesarlo.
        $script:LabManifiestoPath es una ruta absoluta (Join-Path con
        $PSScriptRoot), así que Move-Item funciona independientemente
        del directorio actual.
    .OUTPUTS
        Ruta del nuevo fichero, o $null si no había manifiesto o falló.
    #>
    if (-not (Test-LabManifiestoExists)) { return $null }

    try {
        $nuevoPath = $script:LabManifiestoPath -replace '\.json$', "_procesado_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
        Move-Item -Path $script:LabManifiestoPath -Destination $nuevoPath -Force -ErrorAction Stop
        return $nuevoPath
    } catch {
        Write-LabWarn "No se pudo renombrar el manifiesto: $($_.Exception.Message)"
        return $null
    }
}