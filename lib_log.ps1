<#
.SYNOPSIS
    Librería de logging común para los scripts del laboratorio.
.DESCRIPTION
    Proporciona:
      - Un log en memoria (List[object]) compartido por referencia.
      - Add-LabLogEntry: añade una entrada y la escribe en consola con color.
      - Save-LabLog: vuelca el log a CSV.
      - Get-LabLogSummary: totales por categoría.
      - Reset-LabLog: vacía el log (llamar al inicio de cada script hijo).

    Sustituye a las funciones Add-LogEntry duplicadas en
    clean_up.ps1, creauto.ps1 y creamanual.ps1.
.NOTES
    Depende de lib_ui.ps1 (Write-LabInfo/Ok/Warn/Error).
    Se carga por dot-sourcing.
    Guardar este fichero como UTF-8 con BOM para compatibilidad con PS 5.1.
#>
#Requires -Version 5.1

# ============================================================
# LOG EN MEMORIA
# ============================================================
$script:LabLog = [System.Collections.Generic.List[object]]::new()

# ============================================================
# FUNCIONES PÚBLICAS
# ============================================================

function Reset-LabLog {
    <#
    .SYNOPSIS
        Vacía el log en memoria.
    .DESCRIPTION
        Llamar al inicio de cada script hijo para que no se acumulen
        entradas entre ejecuciones dentro de la misma sesión del menú.
    #>
    $script:LabLog.Clear()
}

function Add-LabLogEntry {
    <#
    .SYNOPSIS
        Añade una entrada al log y la escribe en consola con el color
        adecuado a su categoría.
    .PARAMETER Categoria
        "Info" | "Warning" | "Error"
    .PARAMETER Mensaje
        Texto corto descriptivo.
    .PARAMETER Detalle
        Objeto libre (string, hashtable, pscustomobject) con contexto
        adicional para el CSV.
    #>
    param(
        [Parameter(Mandatory=$true)]
        [ValidateSet("Info","Warning","Error")]
        [string]$Categoria,

        [Parameter(Mandatory=$true)]
        [string]$Mensaje,

        [object]$Detalle = $null
    )

    $script:LabLog.Add([pscustomobject]@{
        Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Categoria = $Categoria
        Mensaje   = $Mensaje
        Detalle   = $Detalle
    })

    switch ($Categoria) {
        "Error"   { Write-LabError $Mensaje }
        "Warning" { Write-LabWarn  $Mensaje }
        default   { Write-LabInfo  $Mensaje }
    }
}

function Save-LabLog {
    <#
    .SYNOPSIS
        Vuelca el log en memoria a un fichero CSV.
    .PARAMETER Prefijo
        Prefijo del nombre del fichero. El timestamp se añade solo.
        Ejemplo: "log_cleanup" -> "log_cleanup_20250101_120000.csv"
    .PARAMETER Directorio
        Directorio destino. Por defecto, $PSScriptRoot del llamador.
    .OUTPUTS
        Ruta absoluta del CSV guardado, o $null si no había entradas
        o si falló la escritura.
    #>
    param(
        [string]$Prefijo = "log_lab",
        [string]$Directorio = $PSScriptRoot
    )

    if ($script:LabLog.Count -eq 0) {
        return $null
    }

    if (-not $Directorio) { $Directorio = "." }

    $logPath = Join-Path $Directorio "$($Prefijo)_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"

    try {
        $script:LabLog | Export-Csv -Path $logPath -NoTypeInformation -Encoding UTF8
        return $logPath
    } catch {
        Write-LabError "No se pudo guardar el log en $logPath : $($_.Exception.Message)"
        return $null
    }
}

function Get-LabLogSummary {
    <#
    .SYNOPSIS
        Devuelve un resumen del log en memoria.
    .OUTPUTS
        PSCustomObject con Total, Avisos, Errores.
    #>
    $errores = @($script:LabLog | Where-Object Categoria -eq "Error").Count
    $avisos  = @($script:LabLog | Where-Object Categoria -eq "Warning").Count

    return [pscustomobject]@{
        Total   = $script:LabLog.Count
        Avisos  = $avisos
        Errores = $errores
    }
}