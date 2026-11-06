<#
.SYNOPSIS
    Librería de helpers de consola para el laboratorio.
.DESCRIPTION
    Proporciona:
      - Limpieza de pantalla con fallback (ISE, hosts sin RawUI).
      - Pausa con fallback.
      - Cabecera y banner.
      - Wrappers de color para mensajes (Info, Ok, Warn, Error).
      - Confirmación explícita por "SI".
      - Entrada de contraseña segura (SecureString).
.NOTES
    Sin dependencias. Se carga por dot-sourcing.
    El resto de librerías y scripts asumen que estas funciones existen.

    SOBRE PSAvoidUsingWriteHost:
    Este archivo es el wrapper de UI del laboratorio. El uso de
    Write-Host es INTENCIONAL: es la capa que traduce los mensajes
    del dominio (info, ok, warn, error) a salida de consola con color.
    Las reglas de PSScriptAnalyzer sobre Write-Host se pueden suprimir
    para este archivo sin afectar al resto del proyecto.
#>

# ============================================================
# PANTALLA
# ============================================================

function Clear-LabScreen {
    <#
    .SYNOPSIS
        Limpia la consola de forma segura.
    .DESCRIPTION
        Clear-Host falla en algunos hosts (ISE sin RawUI, redirecciones).
        Se captura y se ignora.
    #>
    try { Clear-Host } catch { }
}

function Wait-LabKey {
    <#
    .SYNOPSIS
        Pausa hasta que el usuario pulse una tecla o Enter.
    .PARAMETER Mensaje
        Texto mostrado antes de la pausa.
    #>
    param(
        [string]$Mensaje = 'Pulsa cualquier tecla para continuar...'
    )

    Write-Host ''
    Write-Host $Mensaje -ForegroundColor Gray

    try {
        $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    } catch {
        $null = Read-Host '(Enter para continuar)'
    }
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
    #>
    param(
        [string]$Titulo = 'GESTOR DE ENTORNOS DE LABORATORIO - ENTRA ID'
    )

    Clear-LabScreen
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host ('    ' + $Titulo).PadRight(60) -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor Cyan
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
    <#
    .SYNOPSIS
        Mensaje informativo (gris).
    .PARAMETER Msg
        Texto del mensaje.
    #>
    param([string]$Msg)
    Write-Host "[INFO]  $Msg" -ForegroundColor Gray
}

function Write-LabOk {
    <#
    .SYNOPSIS
        Mensaje de éxito (verde).
    .PARAMETER Msg
        Texto del mensaje.
    #>
    param([string]$Msg)
    Write-Host "[OK]    $Msg" -ForegroundColor Green
}

function Write-LabWarn {
    <#
    .SYNOPSIS
        Mensaje de aviso (amarillo).
    .PARAMETER Msg
        Texto del mensaje.
    #>
    param([string]$Msg)
    Write-Host "[WARN]  $Msg" -ForegroundColor Yellow
}

function Write-LabError {
    <#
    .SYNOPSIS
        Mensaje de error (rojo).
    .PARAMETER Msg
        Texto del mensaje.
    #>
    param([string]$Msg)
    Write-Host "[ERROR] $Msg" -ForegroundColor Red
}

# ============================================================
# CONFIRMACIONES Y ENTRADA SEGURA
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

function Read-LabSecureString {
    <#
    .SYNOPSIS
        Pide una contraseña sin mostrarla en pantalla.
    .DESCRIPTION
        Wrapper de Read-Host -AsSecureString. Devuelve $null si el
        operador deja la entrada vacía.
    .PARAMETER Prompt
        Texto del prompt.
    .OUTPUTS
        SecureString, o $null si está vacía.
    #>
    param(
        [string]$Prompt = '  Password'
    )

    $secure = Read-Host $Prompt -AsSecureString
    if ($null -eq $secure -or $secure.Length -eq 0) {
        return $null
    }
    return $secure
}

function ConvertFrom-LabSecureString {
    <#
    .SYNOPSIS
        Convierte una SecureString a texto plano solo en memoria.
    .DESCRIPTION
        Necesario para pasarla a cmdlets de Graph que esperan string
        (PasswordProfile). El texto plano no se persiste en disco.
    .PARAMETER SecureString
        SecureString a convertir.
    .OUTPUTS
        String con el texto plano.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [System.Security.SecureString]$SecureString
    )

    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

# ============================================================
# UTILIDADES DE LISTA
# ============================================================

function Show-LabListaNumerada {
    <#
    .SYNOPSIS
        Muestra una lista numerada y devuelve el índice seleccionado.
    .PARAMETER Items
        Array de elementos a mostrar.
    .PARAMETER Selector
        Scriptblock que recibe un elemento y devuelve el texto a mostrar.
    .PARAMETER Prompt
        Texto del prompt de selección.
    .PARAMETER PermitirCancelar
        Si se especifica, el índice -1 cancela.
    .OUTPUTS
        Índice seleccionado (0..N-1), o -1 si se cancela.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [array]$Items,

        [Parameter(Mandatory = $true)]
        [scriptblock]$Selector,

        [string]$Prompt = 'Selecciona un número',

        [switch]$PermitirCancelar
    )

    for ($i = 0; $i -lt $Items.Count; $i++) {
        $texto = & $Selector $Items[$i]
        Write-Host ('  [{0}] {1}' -f $i, $texto)
    }
    if ($PermitirCancelar) {
        Write-Host '  [0] Cancelar'
    }
    Write-Host ''

    $sel = Read-Host $Prompt

    if ($PermitirCancelar -and $sel -eq '0') { return -1 }
    if ($sel -match '^\d+$' -and [int]$sel -lt $Items.Count) {
        return [int]$sel
    }
    return -1
}