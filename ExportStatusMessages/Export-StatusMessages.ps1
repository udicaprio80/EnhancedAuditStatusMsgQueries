



<#
    Script: Import-CMStatusMessageQueries (Fixed v2 U. Di Caprio)
    Optimized: Gemini AI for Windows Server 2022 / MEMCM
    
    Description: Exports SCCM Status Messages from DLL resources.
#>

param( 
    [Parameter(Mandatory=$True)] 
    [string]$stringPathToDLL, 
    [Parameter(Mandatory=$True)] 
    [string]$stringOutputCSV 
) 

# Definisce la classe C# per le chiamate API di Windows (P/Invoke) una sola volta
$TypeDefinition = @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public class Win32MsgUtils {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern uint FormatMessage(uint flags, IntPtr source, uint messageId, uint langId, StringBuilder buffer, uint size, string[] arguments);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern IntPtr LoadLibrary(string lpFileName);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool FreeLibrary(IntPtr hModule);
}
'@

# Compila il tipo solo se non gia caricato nella sessione
if (-not ([System.Management.Automation.PSTypeName]'Win32MsgUtils').Type) {
    Add-Type -TypeDefinition $TypeDefinition
}

# Configurazione costanti
$sizeOfBuffer = 16384 
$stringArrayInput = $null # Non servono argomenti per l'estrazione pura
# Flags: FORMAT_MESSAGE_IGNORE_INSERTS (0x200) | FORMAT_MESSAGE_FROM_HMODULE (0x800)
$flags = 0x00000A00 
$stringOutput = New-Object System.Text.StringBuilder $sizeOfBuffer 
$colMessages = [System.Collections.Generic.List[PSObject]]::new()

Write-Host "Caricamento libreria: $stringPathToDLL" -ForegroundColor Cyan

# Carica la DLL in memoria
$hModule = [Win32MsgUtils]::LoadLibrary($stringPathToDLL)

if ($hModule -eq [IntPtr]::Zero) {
    Write-Error "Impossibile caricare la DLL. Verifica il percorso e che l'architettura (x64/x86) corrisponda alla shell PowerShell."
    return
}

try {
    Write-Host "Libreria caricata. Inizio estrazione messaggi..." -ForegroundColor Green
    
    # Definizione delle severity bitmasks
    # 0x40000000 = Informational (1073741824)
    # 0x80000000 = Warning (2147483648)
    # 0xC0000000 = Error (3221225472)
    
    $severities = @{
        "Informational" = 1073741824
        "Warning"       = 2147483648
        "Error"         = 3221225472
    }

    foreach ($sevName in $severities.Keys) {
        $bitMask = $severities[$sevName]
        Write-Progress -Activity "Estrazione messaggi ($sevName)" -Status "Elaborazione..."
        
        # Loop ottimizzato
        for ($i = 1; $i -le 65535; $i++) { # Ridotto a 65535 (range tipico WORD), aumentare se necessario
            
            # Combina la maschera di gravita con l'ID messaggio
            # Nota: PowerShell gestisce i numeri grandi come Int64/UInt32 automaticamente qui
            $msgIdToCheck = $bitMask -bor $i
            
            # Pulisce il buffer
            $stringOutput.Clear() | Out-Null
            
            $result = [Win32MsgUtils]::FormatMessage($flags, $hModule, $msgIdToCheck, 0, $stringOutput, $sizeOfBuffer, $stringArrayInput)
            
            if ($result -gt 0) {
                # Pulizia stringa originale
                $cleanMsg = $stringOutput.ToString().Replace("%11","").Replace("%12","").Replace("%3%4%5%6%7%8%9%10","").Trim()
                
                # Creazione oggetto veloce
                $obj = [PSCustomObject]@{
                    MessageID     = $i
                    Severity      = $sevName
                    MessageString = $cleanMsg
                }
                $colMessages.Add($obj)
            }
        }
    }

    Write-Host "Trovati $($colMessages.Count) messaggi totali." -ForegroundColor Green
    
    # Esportazione
    Write-Host "Esportazione in corso su: $stringOutputCSV"
    $colMessages | Export-Csv -Path $stringOutputCSV -NoTypeInformation -Encoding UTF8

}
finally {
    # Rilascia la DLL dalla memoria per evitare lock
    if ($hModule -ne [IntPtr]::Zero) {
        [Win32MsgUtils]::FreeLibrary($hModule) | Out-Null
        Write-Host "Libreria rilasciata." -ForegroundColor Cyan
    }
}
