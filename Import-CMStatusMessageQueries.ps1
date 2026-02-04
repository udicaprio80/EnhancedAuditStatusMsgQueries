
    <#
    Script: Import-CMStatusMessageQueries (Fixed v2 U. Di Caprio)
    Optimized: Gemini AI for Windows Server 2022 / MEMCM
    
    Fix v2:
    - Gestione Multi-Site 
    - Debugging XML migliorato
#>

param(
    [Parameter(Mandatory=$True)]
    [string]$XMLPath
)

# 1. Configurazione Percorso Modulo SCCM
$SccmUiPath = $env:SMS_ADMIN_UI_PATH
if ([string]::IsNullOrEmpty($SccmUiPath)) {
    Write-Error "Errore: La console di Configuration Manager non sembra essere installata (Variabile d'ambiente SMS_ADMIN_UI_PATH mancante)."
    exit
}

$ModulePath = "$SccmUiPath\..\ConfigurationManager.psd1"

# 2. Importazione Modulo
if (!(Get-Module "ConfigurationManager")) {
    if (Test-Path $ModulePath) {
        Write-Host "Importazione modulo SCCM da: $ModulePath" -ForegroundColor Cyan
        Import-Module $ModulePath -ErrorAction Stop
    }
    else {
        Write-Error "Impossibile trovare il modulo ConfigurationManager.psd1"
        exit
    }
}

# 3. Gestione Site Code e Drive 
try {
    # Se ci sono pi  drive, ne prendiamo solo il primo (Select-Object -First 1)
    $SiteCodeObj = Get-PSDrive -PSProvider CMSITE -ErrorAction SilentlyContinue | Select-Object -First 1
    
    if ($SiteCodeObj) {
        $SiteCode = $SiteCodeObj.Name
    }
    else {
        # Se il drive non   montato, cerca il sito e crealo
        $Site = Get-CMSite -ErrorAction Stop | Select-Object -First 1
        $SiteCode = $Site.SiteCode
        New-PSDrive -Name $SiteCode -PSProvider CMSITE -Root $Site.ServerName -Description "SCCM Drive" | Out-Null
    }

    # Pulizia ulteriore nel caso la stringa contenga spazi indesiderati
    $SiteCode = $SiteCode.Trim()

    Write-Host "Site Code utilizzato: $SiteCode" -ForegroundColor Cyan
    Set-Location "$($SiteCode):"
}
catch {
    Write-Error "Impossibile connettersi al Site Drive di SCCM. Errore: $($_.Exception.Message)"
    exit
}

# 4. Importazione XML e Controllo Integrita
if (-not (Test-Path $XMLPath)) {
    Write-Error "Il file specificato non esiste: $XMLPath"
    exit
}

try {
    Write-Host "Lettura file XML: $XMLPath" -ForegroundColor Cyan
    
    # Controllo preliminare del contenuto (spesso scaricando da GitHub si scarica l'HTML invece del RAW)
    $FirstLine = Get-Content $XMLPath -TotalCount 1
    if ($FirstLine -like "<!DOCTYPE html*") {
        Write-Error "ERRORE CRITICO: Il file XML sembra essere una pagina HTML di GitHub e non il file dati RAW."
        Write-Warning "Scarica il file correttamente cliccando su 'Raw' in GitHub o copiando solo il contenuto del codice."
        exit
    }

    $CMStatusMsgs = Import-Clixml $XMLPath
}
catch {
    Write-Error "Errore durante l'importazione del file XML."
    Write-Error "Dettaglio tecnico: $($_.Exception.Message)"
    exit
}

# 5. Creazione Query
if ($null -eq $CMStatusMsgs) {
    Write-Error "L'importazione non ha restituito dati. Il file XML potrebbe essere vuoto o corrotto."
    exit
}

foreach ($Query in $CMStatusMsgs) {
    $QueryName = $Query.Name
    
    if ([string]::IsNullOrWhiteSpace($QueryName)) {
        continue
    }

    # Controllo preventivo se esiste gia
    if (Get-CMStatusMessageQuery -Name $QueryName -ErrorAction SilentlyContinue) {
        Write-Host -ForegroundColor Yellow "SKIP: La query '$QueryName' esiste gi ."
    }
    else {
        try {
            $StatusQuery = @{
                Name       = $QueryName
                Expression = $Query.Expression
                Comments   = $Query.Comments
            }
            
            New-CMStatusMessageQuery @StatusQuery -ErrorAction Stop | Out-Null
            Write-Host -ForegroundColor Green "OK: Query '$QueryName' creata con successo."
        }
        catch {
            Write-Host -ForegroundColor Red "ERRORE: Impossibile creare '$QueryName'. Dettagli: $($_.Exception.Message)"
        }
    }
}
