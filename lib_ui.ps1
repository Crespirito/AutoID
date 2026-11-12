<#
.SYNOPSIS
    Librería de helpers de consola para el laboratorio.
.DESCRIPTION
    Proporciona:
      - Limpieza de pantalla con fallback.
      - Pausa segura (compatible con PowerShell 7).
      - Cabecera y banner.
      - Wrappers de color para mensajes (Info, Ok, Warn, Error).
      - Confirmación explícita por "SI".

    MITIGACIÓN DEL PARPADEO:
    Show-LabHeader acepta -PausaMs para dormir N milisegundos antes
    del Clear-Host, suavizando el parpadeo en terminales con renderizado
    acelerado (Windows Terminal, VS Code). Por defecto 0 (sin pausa).

    NOTA SOBRE Write-Host:
    Este archivo es el wrapper de UI del laboratorio. El uso de
    Write-Host es INTENCIONAL: es la capa que traduce los mensajes
    del dominio a salida de consola con color.
.NOTES
    Sin dependencias. Se carga por dot-sourcing.
    Requiere PowerShell 7.
#>
#Requires -Version 7.0

# Set-StrictMode -Version Latest

# ============================================================
# CONFIGURACIÓN INTERNA
# ============================================================
$script:LabUIAncho = 60

# ============================================================
# PANTALLA
# ============================================================

function Clear-LabScreen {
    <#
    .SYNOPSIS
        Limpia la consola de forma segura.
    .PARAMETER SinPausa
        Aceptado por compatibilidad. No se usa actualmente; reservado
        para futuras implementaciones que quieran evitar cualquier
        pausa antes del borrado.
    #>
    param(
        [switch]$SinPausa
    )

    try {
        Clear-Host
    } catch {
        # Fallback para terminales que no soportan Clear-Host
        try {
            $host.UI.RawUI.BufferSize = New-Object System.Management.Automation.Host.Size(120, 50)
        } catch { }
    }
}

function Wait-LabKey {
    <#
    .SYNOPSIS
        Pausa hasta que el usuario pulse Enter.
    .DESCRIPTION
        En PowerShell 7, leer teclas crudas con RawUI puede fallar en
        Windows Terminal o VS Code. Usamos Read-Host para máxima compatibilidad.
    .PARAMETER Mensaje
        Texto mostrado antes de la pausa.
    #>
    param(
        [string]$Mensaje = 'Pulsa Enter para continuar...'
    )

    Write-Host ''
    $null = Read-Host $Mensaje
}

# ============================================================
# CABECERAS Y BANNERS
# ============================================================

function Show-LabHeader {
    <#
    .SYNOPSIS
        Limpia la pantalla y dibuja la cabecera del laboratorio.
    .PARAMETER Titulo
        Título a mostrar. Por defecto, el genérico del laboratorio.
    .PARAMETER PausaMs
        Milisegundos a esperar antes del Clear-Host. Útil para mitigar
        el parpadeo en terminales con renderizado acelerado. Por defecto 0
        (sin pausa).
    #>
    param(
        [string]$Titulo = 'GESTOR DE ENTORNOS DE LABORATORIO - ENTRA ID',
        [int]$PausaMs = 0
    )

    if ($PausaMs -gt 0) {
        Start-Sleep -Milliseconds $PausaMs
    }

    Clear-LabScreen

    $linea = '=' * $script:LabUIAncho
    $texto = ('    ' + $Titulo).PadRight($script:LabUIAncho)

    Write-Host $linea -ForegroundColor Cyan
    Write-Host $texto -ForegroundColor Cyan
    Write-Host $linea -ForegroundColor Cyan
    Write-Host ''
}

function Show-LabBanner {
    <#
    .SYNOPSIS
        Dibuja un separador con un texto de sección.
    .PARAMETER Texto
        Texto de la sección.
    #>
    param(
        [string]$Texto
    )

    Write-Host ''
    Write-Host "--- $Texto ---" -ForegroundColor Cyan
    Write-Host ''
}

# ============================================================
# MENSAJES CON COLOR
# ============================================================

function Write-LabInfo {
    param([string]$Msg)
    Write-Host "[INFO]  $Msg" -ForegroundColor Gray
}

function Write-LabOk {
    param([string]$Msg)
    Write-Host "[OK]    $Msg" -ForegroundColor Green
}

function Write-LabWarn {
    param([string]$Msg)
    Write-Host "[WARN]  $Msg" -ForegroundColor Yellow
}

function Write-LabError {
    param([string]$Msg)
    Write-Host "[ERROR] $Msg" -ForegroundColor Red
}

function Write-LabBanner {
    <#
    .SYNOPSIS
        Cabecera destacada para marcar el inicio de una fase (despliegue,
        limpieza, reversión).
    #>
    param([string]$Texto)

    $linea = '=' * 60
    Write-Host ''
    Write-Host $linea -ForegroundColor Magenta
    Write-Host "  $Texto" -ForegroundColor Magenta
    Write-Host $linea -ForegroundColor Magenta
    Write-Host ''
}

function Write-LabSeccion {
    <#
    .SYNOPSIS
        Separador ligero de sección dentro de una pantalla.
    #>
    param([string]$Texto)

    Write-Host ''
    Write-Host "--- $Texto ---" -ForegroundColor Cyan
    Write-Host ''
}

# ============================================================
# CONFIRMACIONES
# ============================================================

function Read-LabConfirm {
    <#
    .SYNOPSIS
        Pide confirmación explícita escribiendo 'SI'.
    .PARAMETER Mensaje
        Texto de la pregunta.
    .OUTPUTS
        $true si el usuario escribió exactamente 'SI', $false en caso contrario.
    #>
    param(
        [string]$Mensaje = '¿Quieres continuar?'
    )

    Write-Host $Mensaje -ForegroundColor Yellow
    $resp = Read-Host "Escribe 'SI' para confirmar"
    return ($resp -eq 'SI')
}