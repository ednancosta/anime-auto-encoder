<#
.SYNOPSIS
    Pipeline automatizado e inteligente para processamento e otimização de mídias (Anime/Séries).
.DESCRIPTION
    Este script orquestra a conversão de vídeos para AV1 via Auto-Boost-Essential,
    analisa e transcodifica múltiplas faixas de áudio inteligentemente via FFmpeg,
    organiza e padroniza legendas ASS/SRT, placas (Signs) e fontes no padrão CRD,
    isola caminhos com caracteres especiais Unicode (como '：') ou longos via Hardlink ASCII-Safe,
    empacota os resultados usando MKVToolNix e realiza auditoria rápida de eficiência
    de compressão (Regra dos 80%) antes da auditoria visual (SSIMULACRA2).
.NOTES
    Autor: Ednan Costa
    Data: Novembro 2026
    Padrões Aplicados: Clean Code, DRY (Don't Repeat Yourself), SRP (Single Responsibility Principle)
#>
[CmdletBinding()]
param (
    # 1 = Anime (Desenhos, cores sólidas, linhas afiadas)
    # 2 = Filme (Live-Action, pessoas reais, grão de câmera)
    [ValidateSet(1, 2)]
    [int]$MediaType = 1,

    # Pasta raiz para busca recursiva dos vídeos (padrão: pasta atual do terminal)
    [string]$TargetDir = (Get-Location).Path,

    # Se ativado, corrige via Remux Rápido áudios/legendas/Signs/fontes em vídeos que já estão em AV1/HEVC/VP9
    [switch]$FixTracksOnOptimizedVideos
)

# --- FIX DE CODIFICAÇÃO (ACENTOS, CARACTERES JAPONESES E UNICODE '：') ---
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding  = [System.Text.Encoding]::UTF8
$OutputEncoding           = [System.Text.Encoding]::UTF8
$env:PYTHONIOENCODING     = "utf-8"
$env:PYTHONUTF8           = "1"
$Utf8NoBom                = [System.Text.UTF8Encoding]::new($false)
# -----------------------------------------------------------

# --- MODO SEGUNDO PLANO (IDLE) ---
# Reduz a prioridade deste script. Todos os sub-processos (Python, FFmpeg, FFVship) herdarão isso.
$OriginalProcessPriority = (Get-Process -Id $PID).PriorityClass
(Get-Process -Id $PID).PriorityClass = 'Idle'
# -----------------------------------------------------------

try {

# ====================================================================
# 1. CONFIGURAÇÕES GLOBAIS DO AMBIENTE
# ====================================================================

# Dicionário base (Caminhos e Regras Gerais independentes de mídia)
$AppConfig = @{
    Paths = @{
        FfvshipExe      = "C:\Path\FFVship_nvidia\FFVship.exe" # Substitua pelo seu caminho real
        PythonExe       = "C:\PythonEnv\AutoBoost\Scripts\python.exe" # Substitua pelo seu caminho real
        AutoBoostScript = "C:\Path\Auto-Boost-Essential.py" # Substitua pelo seu caminho real
        MkvMergeExe     = "C:\Program Files\MKVToolNix\mkvmerge.exe"
        FontDirs        = @(
            "C:\Crunchyroll-Downloader\fonts",
            "C:\multi-downloader-nx-windows-x64-gui\fonts",
            "C:\Windows\Fonts"
        )
        SkipCacheFile   = ".autoboost_skip.json"
        MetricsLogFile  = "G:\Meu Drive\Drivers e Firmwares\autoboost_metrics.csv"
    }
    Rules = @{
        ValidVideoCodecs           = @("av1", "hevc", "vp9")
        MinFileSizeToEncode        = 800MB # Ignora o re-encode de vídeo em arquivos menores que este tamanho (ex: 800MB)
        MaxTargetSizeRatio         = 0.80  # O arquivo final não pode ultrapassar 80% do original
        EarlyVideoSizeAbort        = $true # Aborta imediatamente após o encode de vídeo (.ivf) se só o vídeo já ultrapassar 80% do arquivo original
        RememberRejectedBySize     = $true # Salva em .autoboost_skip.json os arquivos reprovados na regra dos 80% para não reprocessá-los à toa
        VerifyFinalSsimu2          = $true # Executa o FFVship (SSIMULACRA2) final apenas nos arquivos que já passaram na regra de tamanho (<= 80%)
        FixTracksOnOptimizedVideos = $false
    }
    MediaPreferences = @{
        # Prioridade de idiomas de áudio (Português principal primeiro, Japonês em seguida, [AD] por último)
        AudioLanguagePriority       = @("por", "pt-br", "pt", "jpn", "ja-jp", "ja", "eng")
        DefaultAudioLanguage        = "por"
        # Prioridade de idiomas de legenda (Português no topo; demais idiomas mantidos como backup)
        SubtitleLanguagePriority    = @("por", "pt-br", "pt")
        DefaultSubtitleLanguage     = "por"
        # Equivalente às opções do CRD:
        DefaultSubtitleSigns        = $true   # Quando houver áudio PT-BR, define a legenda Signs PT-BR como Default (e desmarca Default da legenda completa)
        MarkSignsAsForced           = $true   # Marca a legenda Signs com flag Forced no MKV
        AutoExtractSignsFromFullAss = $true   # Se não houver trilha Signs separada no MKV, extrai automaticamente as linhas de placas (Sign) da legenda PT-BR completa
        AddScaledBorderAndShadow    = "yes"   # Injeta "ScaledBorderAndShadow: yes" nas legendas .ass
        FixCccSubtitles             = $true   # Corrige estilos de legendas geradas com ClosedCaptionConverter
        MuxFonts                    = $true   # Anexa automaticamente fontes .ttf/.otf usadas nas legendas .ass
        PreserveDescriptionAndCover = $true   # Preserva tags globais (DESCRIPTION) e anexos (cover.png) no MKV final
    }
}

if ($FixTracksOnOptimizedVideos.IsPresent) {
    $AppConfig.Rules.FixTracksOnOptimizedVideos = $true
}

# Mapa de Fontes Padrão do CRD (Família Tipográfica -> Arquivo de Fonte)
$FontFileLookup = @{
    "adobe arabic"                       = @("AdobeArabic-Bold.otf", "adobe-arabic-regular.otf")
    "andale mono"                        = @("andalemo.ttf")
    "arial"                              = @("arial.ttf")
    "arial black"                        = @("ariblk.ttf")
    "arial bold"                         = @("arialbd.ttf")
    "arial bold italic"                  = @("arialbi.ttf")
    "arial italic"                       = @("ariali.ttf")
    "arial unicode ms"                   = @("arialuni.ttf", "arial unicode ms.otf")
    "arial unicode ms bold"              = @("arial unicode ms bold.otf")
    "comic sans ms"                      = @("comic.ttf")
    "comic sans ms bold"                 = @("comicbd.ttf")
    "courier new"                        = @("cour.ttf")
    "courier new bold"                   = @("courbd.ttf")
    "courier new bold italic"            = @("courbi.ttf")
    "courier new italic"                 = @("couri.ttf")
    "dejavu lgc sans mono"               = @("DejaVuLGCSansMono.ttf")
    "dejavu lgc sans mono bold"          = @("DejaVuLGCSansMono-Bold.ttf")
    "dejavu lgc sans mono bold oblique"  = @("DejaVuLGCSansMono-BoldOblique.ttf")
    "dejavu lgc sans mono oblique"       = @("DejaVuLGCSansMono-Oblique.ttf")
    "dejavu sans"                        = @("DejaVuSans.ttf")
    "dejavu sans bold"                   = @("DejaVuSans-Bold.ttf")
    "dejavu sans bold oblique"           = @("DejaVuSans-BoldOblique.ttf")
    "dejavu sans condensed"              = @("DejaVuSansCondensed.ttf")
    "dejavu sans condensed bold"         = @("DejaVuSansCondensed-Bold.ttf")
    "dejavu sans condensed bold oblique" = @("DejaVuSansCondensed-BoldOblique.ttf")
    "dejavu sans condensed oblique"      = @("DejaVuSansCondensed-Oblique.ttf")
    "dejavu sans extralight"             = @("DejaVuSans-ExtraLight.ttf")
    "dejavu sans mono"                   = @("DejaVuSansMono.ttf")
    "dejavu sans mono bold"              = @("DejaVuSansMono-Bold.ttf")
    "dejavu sans mono bold oblique"      = @("DejaVuSansMono-BoldOblique.ttf")
    "dejavu sans mono oblique"           = @("DejaVuSansMono-Oblique.ttf")
    "dejavu sans oblique"                = @("DejaVuSans-Oblique.ttf")
    "garamond"                           = @("garamond.ttf", "GARA.TTF")
    "gautami"                            = @("gautami.ttf")
    "georgia"                            = @("georgia.ttf")
    "georgia bold"                       = @("georgiab.ttf")
    "georgia bold italic"                = @("georgiaz.ttf")
    "georgia italic"                     = @("georgiai.ttf")
    "impact"                             = @("impact.ttf")
    "meera inimai"                       = @("MeeraInimai-Regular.ttf")
    "noto sans tamil"                    = @("NotoSansTamilVariable.ttf")
    "noto sans telugu"                   = @("NotoSansTeluguVariable.ttf")
    "noto sans thai"                     = @("NotoSansThai.ttf", "NotoSansThai-VariableFont_wdth,wght.ttf")
    "rubik"                              = @("Rubik-Regular.ttf")
    "rubik black"                        = @("Rubik-Black.ttf")
    "rubik black italic"                 = @("Rubik-BlackItalic.ttf")
    "rubik bold"                         = @("Rubik-Bold.ttf")
    "rubik bold italic"                  = @("Rubik-BoldItalic.ttf")
    "rubik italic"                       = @("Rubik-Italic.ttf")
    "rubik light"                        = @("Rubik-Light.ttf")
    "rubik light italic"                 = @("Rubik-LightItalic.ttf")
    "rubik medium"                       = @("Rubik-Medium.ttf")
    "rubik medium italic"                = @("Rubik-MediumItalic.ttf")
    "tahoma"                             = @("tahoma.ttf")
    "tahoma bold"                        = @("tahomabd.ttf")
    "times new roman"                    = @("times.ttf")
    "times new roman bold"               = @("timesbd.ttf")
    "times new roman bold italic"        = @("timesbi.ttf")
    "times new roman italic"             = @("timesi.ttf")
    "trebuchet ms"                       = @("trebuc.ttf")
    "trebuchet ms bold"                  = @("trebucbd.ttf")
    "trebuchet ms bold italic"           = @("trebucbi.ttf")
    "trebuchet ms italic"                = @("trebucit.ttf")
    "verdana"                            = @("verdana.ttf")
    "verdana bold"                       = @("verdanab.ttf")
    "verdana bold italic"                = @("verdanaz.ttf")
    "verdana italic"                     = @("verdanai.ttf")
    "vrinda"                             = @("vrinda.ttf")
    "vrinda bold"                        = @("vrindab.ttf")
    "webdings"                           = @("webdings.ttf")
}

# Injeção Dinâmica dos Parâmetros baseada na Flag ($MediaType)
if ($MediaType -eq 1) {
    Write-Host ">>> MODO ANIME ATIVADO <<<" -ForegroundColor Cyan

    # Define o SVT-AV1 Neko para Animes
    $AppConfig.Paths.Add("SvtAv1Exe", "C:\Path\SvtAv1EncAppNeko\SvtAv1EncApp.exe")

    $AppConfig.Add("Encoder", @{
        AnimeCrf1080p = 25
        AnimeCrf4K    = 28
        TargetSsimu2  = 81.5
        AutoBoostArgs = @("--target-ssimu2", "81.5", "--ssimu2", "gpu")
        FinalParams   = "--scm 0 --auto-tiling 1 --film-grain 4 --tune 0 --fast-decode 1 --qp-scale-compress-strength 3"
    })
    $AppConfig.Rules.Add("MinAverage", 80.0)
    $AppConfig.Rules.Add("Min5th", 68.0)
    $AppConfig.Rules.Add("FfvshipEvery", 1)

} elseif ($MediaType -eq 2) {
    Write-Host ">>> MODO FILME (LIVE-ACTION) ATIVADO <<<" -ForegroundColor Yellow

    # Define o SVT-AV1-Essential (com Auto-Boost por cena e curva PQ HDR10) para Filmes
    $AppConfig.Paths.Add("SvtAv1Exe", "C:\Path\SvtAv1EncAppNeko\SvtAv1EncApp.exe")
    $AppConfig.MediaPreferences.AudioLanguagePriority       = @("por", "pt-br", "pt", "eng", "jpn", "ja-jp", "ja")
    $AppConfig.MediaPreferences.AutoExtractSignsFromFullAss = $false

    $AppConfig.Add("Encoder", @{
        MovieCrf1080p = 24
        MovieCrf4K    = 28
        TargetSsimu2  = 81.5
        AutoBoostArgs = @("--target-ssimu2", "81.5", "--ssimu2", "gpu")
        FinalParams   = "--preset 4 --tune 0 --scm 0 --auto-tiling 1 --film-grain 8 --luminance-qp-bias 15 --qp-scale-compress-strength 2 --fast-decode 1"
    })
    $AppConfig.Rules.Add("MinAverage", 80.0)
    $AppConfig.Rules.Add("Min5th", 65.0) # Relaxado para lidar com Motion Blur real
    $AppConfig.Rules.Add("FfvshipEvery", 3)
}

# === CORREÇÃO CRÍTICA: SEQUESTRO DE PATH DINÂMICO ===
# Garante que o Python (Auto-Boost) encontre o SVT-AV1 correto selecionado acima
$SvtDirectory = Split-Path -Parent $AppConfig.Paths.SvtAv1Exe
if (-not [string]::IsNullOrWhiteSpace($SvtDirectory) -and [System.IO.Directory]::Exists($SvtDirectory)) {
    $env:PATH = "$SvtDirectory;$env:PATH"
}
# ====================================================

# ====================================================================
# 2. FUNÇÕES DE SUPORTE, CACHE E ISOLAMENTO UNICODE (Helpers)
# ====================================================================

# P/Invoke Win32 CreateHardLinkW para criar Hardlinks diretamente em caminhos com '：' (U+FF1A) ou colchetes
if (-not ([System.Management.Automation.PSTypeName]'Win32HardLink').Type) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class Win32HardLink {
    [DllImport("Kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool CreateHardLinkW(string lpFileName, string lpExistingFileName, IntPtr lpSecurityAttributes);
}
"@
}

function Write-AppLog {
    <#
    .SYNOPSIS
        Registra mensagens no console com formatação padronizada e timestamp.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)][string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR", "SUCCESS")][string]$Level = "INFO"
    )
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $Colors = @{ "INFO" = "Cyan"; "WARN" = "Yellow"; "ERROR" = "Red"; "SUCCESS" = "Green" }

    Write-Host "[$Timestamp] [$Level] $Message" -ForegroundColor $Colors[$Level]
}

function ConvertTo-LongPath {
    <#
    .SYNOPSIS
        Converte um caminho local Windows (ex: D:\...) para o prefixo estendido \\?\ sem alterar caminhos UNC ou já prefixados.
    #>
    param ([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    if ($Path.StartsWith("\\?\")) { return $Path }
    if ($Path -match "^[A-Za-z]:\\") { return "\\?\$Path" }
    return $Path
}

function Move-FileSafely {
    <#
    .SYNOPSIS
        Move e substitui arquivos de forma atômica/segura: nunca apaga o arquivo original antes de o novo estar garantido no destino.
        Em caso de falha durante a substituição no mesmo caminho, restaura o backup .autoboost.bak automaticamente.
    #>
    param (
        [Parameter(Mandatory=$true)][string]$SourcePath,
        [Parameter(Mandatory=$true)][string]$DestinationPath,
        [string]$OriginalToReplace = ""
    )

    $LongSrc  = ConvertTo-LongPath $SourcePath
    $LongDst  = ConvertTo-LongPath $DestinationPath
    $LongOrig = ConvertTo-LongPath $OriginalToReplace

    if (-not [string]::IsNullOrWhiteSpace($OriginalToReplace) -and [System.IO.File]::Exists($LongOrig)) {
        if ([string]::Equals($OriginalToReplace, $DestinationPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            $BackupPath = "$OriginalToReplace.autoboost.bak"
            $LongBak    = ConvertTo-LongPath $BackupPath

            if ([System.IO.File]::Exists($LongBak)) {
                [System.IO.File]::Delete($LongBak)
            }

            [System.IO.File]::Move($LongOrig, $LongBak)
            try {
                [System.IO.File]::Move($LongSrc, $LongDst, $true)
                if ([System.IO.File]::Exists($LongBak)) {
                    [System.IO.File]::Delete($LongBak)
                }
            } catch {
                if ([System.IO.File]::Exists($LongBak) -and -not [System.IO.File]::Exists($LongOrig)) {
                    [System.IO.File]::Move($LongBak, $LongOrig)
                }
                throw
            }
        } else {
            [System.IO.File]::Move($LongSrc, $LongDst, $true)
            if ([System.IO.File]::Exists($LongOrig)) {
                [System.IO.File]::Delete($LongOrig)
            }
        }
    } else {
        [System.IO.File]::Move($LongSrc, $LongDst, $true)
    }
}

function Test-Prerequisites {
    <#
    .SYNOPSIS
        Valida no início da execução se os binários obrigatórios existem (Fail-Fast).
    #>
    foreach ($Cmd in @("ffmpeg", "ffprobe")) {
        if ($null -eq (Get-Command $Cmd -ErrorAction SilentlyContinue)) {
            throw "Ferramenta obrigatória '$Cmd' não encontrada no PATH do sistema."
        }
    }

    if (-not [System.IO.File]::Exists($AppConfig.Paths.MkvMergeExe)) {
        throw "MKVMerge não encontrado em '$($AppConfig.Paths.MkvMergeExe)'. Ajuste `$AppConfig.Paths.MkvMergeExe."
    }

    $MissingEncodeTools = [System.Collections.Generic.List[string]]::new()
    if (-not [System.IO.File]::Exists($AppConfig.Paths.PythonExe))       { $MissingEncodeTools.Add("PythonExe ($($AppConfig.Paths.PythonExe))") }
    if (-not [System.IO.File]::Exists($AppConfig.Paths.AutoBoostScript)) { $MissingEncodeTools.Add("AutoBoostScript ($($AppConfig.Paths.AutoBoostScript))") }
    if (-not [System.IO.File]::Exists($AppConfig.Paths.SvtAv1Exe))       { $MissingEncodeTools.Add("SvtAv1Exe ($($AppConfig.Paths.SvtAv1Exe))") }
    if ($AppConfig.Rules.VerifyFinalSsimu2 -and -not [System.IO.File]::Exists($AppConfig.Paths.FfvshipExe)) {
        $MissingEncodeTools.Add("FfvshipExe ($($AppConfig.Paths.FfvshipExe))")
    }

    if ($MissingEncodeTools.Count -gt 0) {
        Write-AppLog "Aviso: Ferramentas de re-encode de vídeo ausentes: $($MissingEncodeTools -join '; '). Apenas o modo Remux (FixTracksOnOptimizedVideos) funcionará." "WARN"
    }

    return @{
        CanEncodeVideo     = ($MissingEncodeTools.Count -eq 0)
        MissingEncodeTools = $MissingEncodeTools.ToArray()
    }
}

function Get-SvtAv1Version {
    <#
    .SYNOPSIS
        Recupera a versão real do encoder SVT-AV1 para embutir nos metadados.
    #>
    if ([System.IO.File]::Exists($AppConfig.Paths.SvtAv1Exe)) {
        return (& $AppConfig.Paths.SvtAv1Exe --version 2>&1) | Select-Object -First 1
    }
    return "SVT-AV1 (Desconhecido)"
}

function Initialize-FontFileCache {
    <#
    .SYNOPSIS
        Indexa uma única vez na inicialização todos os arquivos de fonte (.ttf/.otf) disponíveis
        nas pastas configuradas, tornando a busca de fontes O(1) em memória para todos os episódios.
    #>
    $Cache = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if (-not $AppConfig.MediaPreferences.MuxFonts) { return $Cache }

    foreach ($Dir in $AppConfig.Paths.FontDirs) {
        if (-not [System.IO.Directory]::Exists($Dir)) { continue }
        try {
            foreach ($FilePath in [System.IO.Directory]::EnumerateFiles($Dir)) {
                $FileName = [System.IO.Path]::GetFileName($FilePath)
                if (-not $Cache.ContainsKey($FileName)) {
                    $Cache[$FileName] = $FilePath
                }
            }
        } catch {}
    }
    return $Cache
}

function Import-SkipSizeHistory {
    <#
    .SYNOPSIS
        Carrega o histórico de arquivos já avaliados/rejeitados (por tamanho ou remux concluído) para evitar reprocessamento.
    #>
    param ([string]$CacheFilePath)
    $Map = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ([System.IO.File]::Exists($CacheFilePath)) {
        try {
            $Json = [System.IO.File]::ReadAllText($CacheFilePath, [System.Text.Encoding]::UTF8)
            $Data = $Json | ConvertFrom-Json -AsHashTable
            if ($null -ne $Data) {
                foreach ($K in $Data.Keys) { $Map[$K] = [string]$Data[$K] }
            }
        } catch {}
    }
    return $Map
}

function Save-SkipSizeHistory {
    <#
    .SYNOPSIS
        Salva no disco o histórico atualizado de arquivos em cache.
    #>
    param (
        [string]$CacheFilePath,
        $HistoryMap
    )
    try {
        $PlainHash = @{}
        foreach ($K in $HistoryMap.Keys) { $PlainHash[$K] = $HistoryMap[$K] }
        $Json = $PlainHash | ConvertTo-Json -Depth 3
        [System.IO.File]::WriteAllText($CacheFilePath, $Json, $Utf8NoBom)
    } catch {}
}

function Write-EncodeMetricsLog {
    <#
    .SYNOPSIS
        Registra em CSV consolidado as métricas de tamanho, SSIMULACRA2 e parâmetros de cada conversão para calibração futura do CRF.
    #>
    param (
        [string]$LogPath,
        [string]$FileName,
        [string]$Folder,
        [string]$MediaMode,
        [string]$Resolution,
        [string]$SourceCodec,
        [string]$ColorProfile,
        [string]$BaseTarget,
        [string]$EncoderParams,
        [string]$Status,
        [long]$OriginalBytes,
        [long]$NewBytes,
        [double]$Ratio,
        [double]$ElapsedMin,
        $SsimuAvg = $null,
        $SsimuMedian = $null,
        $Ssimu5th = $null,
        $Ssimu95th = $null,
        $SsimuMin = $null,
        $SsimuStdDev = $null,
        $FastSsimuAvg = $null,
        $FastSsimuP15 = $null,
        $FastSsimuMin = $null
    )

    if ([string]::IsNullOrWhiteSpace($LogPath)) { return }

    $Inv = [cultureinfo]::InvariantCulture
    $Fmt = { param($Val) if ($null -eq $Val) { "" } else { ([double]$Val).ToString("0.00", $Inv) } }

    $SizePct    = $Ratio * 100.0
    $SavingsPct = 100.0 - $SizePct

    $Row = [PSCustomObject][ordered]@{
        Timestamp     = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        MediaType     = $MediaMode
        Status        = $Status
        Folder        = $Folder
        FileName      = $FileName
        Resolution    = $Resolution
        SourceCodec   = $SourceCodec
        ColorProfile  = $ColorProfile
        BaseTarget    = $BaseTarget
        OriginalMB    = & $Fmt ($OriginalBytes / 1MB)
        NewMB         = & $Fmt ($NewBytes / 1MB)
        SizePct       = & $Fmt $SizePct
        SavingsPct    = & $Fmt $SavingsPct
        FastSsimuAvg  = & $Fmt $FastSsimuAvg
        FastSsimuP15  = & $Fmt $FastSsimuP15
        FastSsimuMin  = & $Fmt $FastSsimuMin
        SsimuAvg      = & $Fmt $SsimuAvg
        SsimuMedian   = & $Fmt $SsimuMedian
        Ssimu5th      = & $Fmt $Ssimu5th
        Ssimu95th     = & $Fmt $Ssimu95th
        SsimuMin      = & $Fmt $SsimuMin
        SsimuStdDev   = & $Fmt $SsimuStdDev
        ElapsedMin    = & $Fmt $ElapsedMin
        EncoderParams = $EncoderParams
    }

    try {
        $ParentDir = [System.IO.Path]::GetDirectoryName($LogPath)
        if (-not [string]::IsNullOrWhiteSpace($ParentDir)) {
            [void][System.IO.Directory]::CreateDirectory($ParentDir)
        }
        $Row | Export-Csv -Path $LogPath -Append -NoTypeInformation -Encoding utf8
    } catch {
        Write-AppLog "Aviso: Falha ao gravar log de métricas em '$LogPath': $_" "WARN"
    }
}

function Get-FileSkipSignature {
    <#
    .SYNOPSIS
        Gera uma assinatura determinística baseada no tamanho, data de modificação, versão do encoder e parâmetros.
    #>
    param (
        [System.IO.FileInfo]$FileInfo,
        [string]$SvtVersion = ""
    )
    $EncKey = "$MediaType|$SvtVersion|$($AppConfig.Encoder.AutoBoostArgs -join ' ')|$($AppConfig.Encoder.FinalParams)|$($AppConfig.Encoder.AnimeCrf1080p)|$($AppConfig.Encoder.AnimeCrf4K)|$($AppConfig.Encoder.MovieCrf1080p)|$($AppConfig.Encoder.MovieCrf4K)|$($AppConfig.Encoder.TargetSsimu2)|$($AppConfig.Rules.MaxTargetSizeRatio)"
    return "$($FileInfo.Length)|$($FileInfo.LastWriteTimeUtc.Ticks)|$EncKey"
}

function New-SafeExecutionContext {
    <#
    .SYNOPSIS
        Cria o contexto de trabalho para um episódio.
        Se o caminho ou nome do arquivo contiver caracteres especiais Unicode (ex: '：' U+FF1A, '？', '～'),
        caracteres sensíveis ao shell/Python ([ ] & % ! ') ou for muito longo (> 190 chars),
        cria automaticamente um ambiente de staging 100% ASCII via Hardlink instantâneo (0 bytes extras).
    #>
    param ([System.IO.FileInfo]$File)

    $RealFullPath = $File.FullName -replace "^\\\\\?\\(?=[A-Za-z]:\\)", ""
    $RealDir      = $File.DirectoryName -replace "^\\\\\?\\(?=[A-Za-z]:\\)", ""
    $RealBaseName = [System.IO.Path]::GetFileNameWithoutExtension($File.Name)
    $Ext          = $File.Extension

    $HasSpecialChars = (
        $RealFullPath.Length -gt 190 -or
        $RealFullPath -match "[^\x20-\x7E]" -or
        $RealFullPath -match "[\[\]&%!']"
    )

    if ($HasSpecialChars) {
        $DriveRoot   = [System.IO.Path]::GetPathRoot($RealFullPath)
        $SafeBaseDir = if ($DriveRoot -match "^[A-Za-z]:\\$") { $DriveRoot } else { $env:TEMP }
        $SafeRootDir = [System.IO.Path]::Combine($SafeBaseDir, "_autoboost_work")
        $JobId       = [Guid]::NewGuid().ToString("N").Substring(0, 12)
        $SafeJobDir  = [System.IO.Path]::Combine($SafeRootDir, "job_$JobId")
        [void][System.IO.Directory]::CreateDirectory($SafeJobDir)

        $SafeSourceFile = [System.IO.Path]::Combine($SafeJobDir, "source$Ext")
        $LongRealPath   = ConvertTo-LongPath $RealFullPath

        $Linked = [Win32HardLink]::CreateHardLinkW($SafeSourceFile, $LongRealPath, [IntPtr]::Zero)
        if (-not $Linked -or -not [System.IO.File]::Exists($SafeSourceFile)) {
            [System.IO.File]::Copy($LongRealPath, $SafeSourceFile, $true)
        }

        return @{
            RealOriginalFile = $RealFullPath
            OriginalFile     = $SafeSourceFile
            BaseName         = $RealBaseName
            Directory        = $RealDir
            WorkingDir       = $SafeJobDir
            UsingSafeStaging = $true
            SafeJobDir       = $SafeJobDir
            SafeRootDir      = $SafeRootDir
            VideoTemp        = [System.IO.Path]::Combine($SafeJobDir, "source.ivf")
            AudioTemp        = [System.IO.Path]::Combine($SafeJobDir, "source_audio.mka")
            MkvTemp          = [System.IO.Path]::Combine($SafeJobDir, "source_temp.mkv")
            TagsXml          = [System.IO.Path]::Combine($SafeJobDir, "tags_temp.xml")
            SubsDir          = [System.IO.Path]::Combine($SafeJobDir, "subs_temp")
            WorkDir          = [System.IO.Path]::Combine($SafeJobDir, "source")
        }
    }

    return @{
        RealOriginalFile = $RealFullPath
        OriginalFile     = $RealFullPath
        BaseName         = $RealBaseName
        Directory        = $RealDir
        WorkingDir       = $RealDir
        UsingSafeStaging = $false
        SafeJobDir       = $null
        SafeRootDir      = $null
        VideoTemp        = [System.IO.Path]::Combine($RealDir, "${RealBaseName}.ivf")
        AudioTemp        = [System.IO.Path]::Combine($RealDir, "${RealBaseName}_audio.mka")
        MkvTemp          = [System.IO.Path]::Combine($RealDir, "${RealBaseName}_temp.mkv")
        TagsXml          = [System.IO.Path]::Combine($RealDir, "tags_temp.xml")
        SubsDir          = [System.IO.Path]::Combine($RealDir, "${RealBaseName}_subs_temp")
        WorkDir          = [System.IO.Path]::Combine($RealDir, $RealBaseName)
    }
}

function Remove-TemporaryAssets {
    <#
    .SYNOPSIS
        Limpa os arquivos temporários gerados durante o processamento de um episódio específico.
        Usa as APIs nativas [System.IO.File] e [System.IO.Directory] para suportar qualquer caractere especial.
    #>
    param (
        [hashtable]$Context,
        [bool]$KeepMkvTemp = $false
    )
    try { if ([System.IO.File]::Exists($Context.VideoTemp))     { [System.IO.File]::Delete($Context.VideoTemp) } } catch {}
    try { if ([System.IO.File]::Exists($Context.AudioTemp))     { [System.IO.File]::Delete($Context.AudioTemp) } } catch {}
    try { if ([System.IO.File]::Exists($Context.TagsXml))       { [System.IO.File]::Delete($Context.TagsXml) } } catch {}
    try { if ([System.IO.Directory]::Exists($Context.SubsDir))  { [System.IO.Directory]::Delete($Context.SubsDir, $true) } } catch {}
    try { if ([System.IO.Directory]::Exists($Context.WorkDir))  { [System.IO.Directory]::Delete($Context.WorkDir, $true) } } catch {}

    if (-not $KeepMkvTemp) {
        try { if ([System.IO.File]::Exists($Context.MkvTemp)) { [System.IO.File]::Delete($Context.MkvTemp) } } catch {}
        if ($Context.UsingSafeStaging) {
            try { if ([System.IO.File]::Exists($Context.OriginalFile))    { [System.IO.File]::Delete($Context.OriginalFile) } } catch {}
            try { if ([System.IO.Directory]::Exists($Context.SafeJobDir)) { [System.IO.Directory]::Delete($Context.SafeJobDir, $true) } } catch {}
            try {
                if ([System.IO.Directory]::Exists($Context.SafeRootDir) -and ([System.IO.Directory]::GetFileSystemEntries($Context.SafeRootDir)).Count -eq 0) {
                    [System.IO.Directory]::Delete($Context.SafeRootDir)
                }
            } catch {}
        }
    }
}

function Get-NormalizedLanguageCode {
    <#
    .SYNOPSIS
        Normaliza códigos de idioma (ISO 639-1/639-2/BCP-47) para comparação uniforme.
    #>
    param ([string]$Lang, [string]$Title = "")
    $Raw = ""
    if (-not [string]::IsNullOrWhiteSpace($Lang)) { $Raw = $Lang.Trim().ToLowerInvariant() }

    switch -Regex ($Raw) {
        "^(por|pt|pt-br|pt_br|pob)$" { return "por" }
        "^(jpn|ja|ja-jp|ja_jp)$"     { return "jpn" }
        "^(eng|en|en-us|en_us)$"     { return "eng" }
    }

    if (-not [string]::IsNullOrWhiteSpace($Title)) {
        switch -Regex ($Title) {
            "(?i)(portugu|brazil|pt-br)" { return "por" }
            "(?i)(japan|japon)"          { return "jpn" }
            "(?i)(english|ingl)"         { return "eng" }
        }
    }

    if ([string]::IsNullOrWhiteSpace($Raw)) { return "und" }
    return $Raw
}

# ====================================================================
# 3. FUNÇÕES DE DOMÍNIO (Lógica Central do Negócio)
# ====================================================================

function Get-MediaMetadata {
    <#
    .SYNOPSIS
        Extrai metadados completos do arquivo via FFprobe e converte para hashtable com validação de erros.
    #>
    param ([string]$FilePath)

    $JsonText = (& ffprobe -v quiet -print_format json -show_streams -show_format $FilePath) -join "`n"
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($JsonText)) {
        throw "Falha ao extrair metadados via ffprobe (ExitCode=$LASTEXITCODE) em: $FilePath"
    }

    return $JsonText | ConvertFrom-Json -AsHashTable
}

function ConvertFrom-FfprobeRational {
    <#
    .SYNOPSIS
        Converte uma string racional (ex.: "34000/50000") ou numérica do ffprobe em [double] InvariantCulture.
    #>
    param ($Value)
    if ($null -eq $Value) { return $null }
    $Str = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($Str)) { return $null }
    if ($Str -match "^(-?\d+(?:\.\d+)?)/(-?\d+(?:\.\d+)?)$") {
        $Num = [double]::Parse($Matches[1], [cultureinfo]::InvariantCulture)
        $Den = [double]::Parse($Matches[2], [cultureinfo]::InvariantCulture)
        if ($Den -eq 0) { return $null }
        return ($Num / $Den)
    }
    [double]$Parsed = 0
    if ([double]::TryParse($Str, [System.Globalization.NumberStyles]::Float, [cultureinfo]::InvariantCulture, [ref]$Parsed)) {
        return $Parsed
    }
    return $null
}

function Get-VideoColorParams {
    <#
    .SYNOPSIS
        Detecta espaço de cor CICP, range, chroma position e metadados HDR10 (Mastering Display + MaxCLL/MaxFALL)
        gerando as flags exatas do SvtAv1EncApp sem alterar a tabela de cores original via pipe Y4M.
    #>
    param (
        [Parameter(Mandatory=$true)][string]$FilePath,
        [Parameter(Mandatory=$true)]$VideoStream
    )

    $PrimMap = @{
        "bt709" = "bt709"; "bt470m" = "bt470m"; "bt470bg" = "bt470bg"
        "smpte170m" = "bt601"; "bt601" = "bt601"; "smpte240m" = "smpte240"
        "smpte240" = "smpte240"; "film" = "film"; "bt2020" = "bt2020"
        "smpte428" = "xyz"; "xyz" = "xyz"; "smpte431" = "smpte431"
        "smpte432" = "smpte432"; "ebu3213" = "ebu3213"
    }
    $TransMap = @{
        "bt709" = "bt709"; "gamma22" = "bt470m"; "bt470m" = "bt470m"
        "gamma28" = "bt470bg"; "bt470bg" = "bt470bg"; "smpte170m" = "bt601"
        "bt601" = "bt601"; "smpte240m" = "smpte240"; "smpte240" = "smpte240"
        "linear" = "linear"; "log100" = "log100"; "log316" = "log100-sqrt10"
        "log100-sqrt10" = "log100-sqrt10"; "iec61966-2-4" = "iec61966"
        "iec61966_2_4" = "iec61966"; "iec61966" = "iec61966"
        "bt1361e" = "bt1361"; "bt1361" = "bt1361"; "iec61966-2-1" = "srgb"
        "iec61966_2_1" = "srgb"; "srgb" = "srgb"; "bt2020-10" = "bt2020-10"
        "bt2020_10bit" = "bt2020-10"; "bt2020-12" = "bt2020-12"
        "bt2020_12bit" = "bt2020-12"; "smpte2084" = "smpte2084"
        "smpte428" = "smpte428"; "arib-std-b67" = "hlg"; "hlg" = "hlg"
    }
    $MatMap = @{
        "rgb" = "identity"; "identity" = "identity"; "bt709" = "bt709"
        "fcc" = "fcc"; "bt470bg" = "bt470bg"; "smpte170m" = "bt601"
        "bt601" = "bt601"; "smpte240m" = "smpte240"; "smpte240" = "smpte240"
        "ycgco" = "ycgco"; "bt2020nc" = "bt2020-ncl"; "bt2020-ncl" = "bt2020-ncl"
        "bt2020_ncl" = "bt2020-ncl"; "bt2020c" = "bt2020-cl"
        "bt2020-cl" = "bt2020-cl"; "bt2020_cl" = "bt2020-cl"
        "smpte2085" = "smpte2085"; "chroma-derived-nc" = "chroma-ncl"
        "chroma-ncl" = "chroma-ncl"; "chroma-derived-c" = "chroma-cl"
        "chroma-cl" = "chroma-cl"; "ictcp" = "ictcp"
    }

    $RawPrim   = ([string]$VideoStream.color_primaries).Trim().ToLowerInvariant()
    $RawTrans  = ([string]$VideoStream.color_transfer).Trim().ToLowerInvariant()
    $RawMat    = ([string]$VideoStream.color_space).Trim().ToLowerInvariant()
    $RawRange  = ([string]$VideoStream.color_range).Trim().ToLowerInvariant()
    $RawChroma = ([string]$VideoStream.chroma_location).Trim().ToLowerInvariant()

    $Prim   = if ($PrimMap.ContainsKey($RawPrim))  { $PrimMap[$RawPrim] }   else { $null }
    $Trans  = if ($TransMap.ContainsKey($RawTrans)) { $TransMap[$RawTrans] } else { $null }
    $Matrix = if ($MatMap.ContainsKey($RawMat))    { $MatMap[$RawMat] }     else { $null }

    if ($null -eq $Prim -and $null -eq $Trans -and $null -eq $Matrix -and ([int]$VideoStream.width -ge 1280 -or [int]$VideoStream.height -ge 720)) {
        $Prim = "bt709"; $Trans = "bt709"; $Matrix = "bt709"
    }

    $Flags = [System.Collections.Generic.List[string]]::new()
    if ($Prim)   { $Flags.Add("--color-primaries $Prim") }
    if ($Trans)  { $Flags.Add("--transfer-characteristics $Trans") }
    if ($Matrix) { $Flags.Add("--matrix-coefficients $Matrix") }
    if ($RawRange -eq "pc" -or $RawRange -eq "jpeg") { $Flags.Add("--color-range 1") }
    elseif ($RawRange -eq "tv" -or $RawRange -eq "mpeg") { $Flags.Add("--color-range 0") }

    if ($RawChroma -eq "left" -or $RawChroma -eq "vertical") { $Flags.Add("--chroma-sample-position vertical") }
    elseif ($RawChroma -eq "topleft" -or $RawChroma -eq "colocated") { $Flags.Add("--chroma-sample-position colocated") }

    $AllSideData = [System.Collections.Generic.List[object]]::new()
    if ($null -ne $VideoStream.side_data_list) {
        foreach ($Sd in $VideoStream.side_data_list) { $AllSideData.Add($Sd) }
    }

    $IsHdrPq = ($Trans -eq "smpte2084")
    if ($IsHdrPq -or $Trans -eq "hlg" -or $Prim -eq "bt2020") {
        $FrameJson = (& ffprobe -v quiet -print_format json -select_streams v:0 -read_intervals "%+#1" -show_frames $FilePath) -join "`n"
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($FrameJson)) {
            try {
                $FrameData = $FrameJson | ConvertFrom-Json -AsHashTable
                if ($FrameData -and $FrameData.frames -and $FrameData.frames.Count -gt 0 -and $FrameData.frames[0].side_data_list) {
                    foreach ($Sd in $FrameData.frames[0].side_data_list) { $AllSideData.Add($Sd) }
                }
            } catch {}
        }
    }

    $HasMastering = $false; $HasCll = $false; $HasDoVi = $false; $HasHdr10P = $false
    foreach ($Sd in $AllSideData) {
        $SdType = [string]$Sd["side_data_type"]
        if ($SdType -match "(?i)(DOVI|Dolby Vision)") { $HasDoVi = $true }
        elseif ($SdType -match "(?i)(SMPTE2094-40|HDR10\+)") { $HasHdr10P = $true }
        elseif (-not $HasMastering -and $SdType -eq "Mastering display metadata") {
            $Gx = ConvertFrom-FfprobeRational $Sd["green_x"]; $Gy = ConvertFrom-FfprobeRational $Sd["green_y"]
            $Bx = ConvertFrom-FfprobeRational $Sd["blue_x"];  $By = ConvertFrom-FfprobeRational $Sd["blue_y"]
            $Rx = ConvertFrom-FfprobeRational $Sd["red_x"];   $Ry = ConvertFrom-FfprobeRational $Sd["red_y"]
            $Wx = ConvertFrom-FfprobeRational $Sd["white_point_x"]; $Wy = ConvertFrom-FfprobeRational $Sd["white_point_y"]
            $LMax = ConvertFrom-FfprobeRational $Sd["max_luminance"]; $LMin = ConvertFrom-FfprobeRational $Sd["min_luminance"]
            if ($null -ne $Gx -and $null -ne $Gy -and $null -ne $Bx -and $null -ne $By -and $null -ne $Rx -and $null -ne $Ry -and $null -ne $Wx -and $null -ne $Wy -and $null -ne $LMax -and $null -ne $LMin -and $LMax -gt 0) {
                $Inv = [cultureinfo]::InvariantCulture
                $MdStr = "G({0},{1})B({2},{3})R({4},{5})WP({6},{7})L({8},{9})" -f `
                    $Gx.ToString("0.0000", $Inv), $Gy.ToString("0.0000", $Inv), `
                    $Bx.ToString("0.0000", $Inv), $By.ToString("0.0000", $Inv), `
                    $Rx.ToString("0.0000", $Inv), $Ry.ToString("0.0000", $Inv), `
                    $Wx.ToString("0.0000", $Inv), $Wy.ToString("0.0000", $Inv), `
                    $LMax.ToString("0.0000", $Inv), $LMin.ToString("0.0000", $Inv)
                $Flags.Add("--mastering-display $MdStr")
                $HasMastering = $true
            }
        } elseif (-not $HasCll -and $SdType -eq "Content light level metadata") {
            $MaxCll  = if ($null -ne $Sd["max_content"]) { [int]$Sd["max_content"] } else { $null }
            $MaxFall = if ($null -ne $Sd["max_average"]) { [int]$Sd["max_average"] } else { $null }
            if ($null -ne $MaxCll -and $null -ne $MaxFall -and ($MaxCll -gt 0 -or $MaxFall -gt 0)) {
                $Flags.Add("--content-light $MaxCll,$MaxFall")
                $HasCll = $true
            }
        }
    }

    if ($IsHdrPq) { $Flags.Add("--variance-boost-curve 3") }
    if ($HasDoVi -or $HasHdr10P) {
        Write-AppLog "Metadados dinâmicos detectados (Dolby Vision=$HasDoVi | HDR10+=$HasHdr10P): o encode manterá a camada base HDR10." "WARN"
    }

    $Summary = "$(if ($IsHdrPq) { 'HDR10 PQ' } else { 'SDR' }) ($Prim/$Trans/$Matrix$(if ($HasMastering) { ' + MDCV' })$(if ($HasCll) { ' + CLL' }))"
    return @{ CliFlags = ($Flags -join " "); IsHdrPq = $IsHdrPq; Summary = $Summary }
}

function Get-RuntimeEncoderParams {
    <#
    .SYNOPSIS
        Monta AutoBoostArgs e FinalParams finais para cada vídeo (ajustando CRF por resolução em Filmes e injetando flags de cor/HDR10).
    #>
    param (
        [Parameter(Mandatory=$true)]$VideoStream,
        [Parameter(Mandatory=$true)][hashtable]$ColorProfile
    )

    $ColorFlags = $ColorProfile.CliFlags.Trim()
    $Is4K = (([int]$VideoStream.width * [int]$VideoStream.height) -gt (1920 * 1080))
    if ($MediaType -eq 1) {
        $BaseCrf = if ($Is4K) { $AppConfig.Encoder.AnimeCrf4K } else { $AppConfig.Encoder.AnimeCrf1080p }
        $FastStr = ("--crf $BaseCrf $ColorFlags").Trim()
        $AbArgs = @("--fast-params", $FastStr) + @($AppConfig.Encoder.AutoBoostArgs)
        $FinParams = ("--crf $BaseCrf " + $AppConfig.Encoder.FinalParams + " " + $ColorFlags).Trim()
        $BaseTarget = "crf=$BaseCrf"
    } else {
        $BaseCrf = if ($Is4K) { $AppConfig.Encoder.MovieCrf4K } else { $AppConfig.Encoder.MovieCrf1080p }
        $FastStr = ("--preset 6 --crf $BaseCrf $ColorFlags").Trim()
        $AbArgs = @("--fast-params", $FastStr) + @($AppConfig.Encoder.AutoBoostArgs)
        $FinParams = ("--crf $BaseCrf " + $AppConfig.Encoder.FinalParams + " " + $ColorFlags).Trim()
        $BaseTarget = "crf=$BaseCrf"
    }

    return @{
        AutoBoostArgs = $AbArgs
        FinalParams   = $FinParams
        BaseTarget    = $BaseTarget
    }
}

function Get-AudioOptimizationPlan {
    <#
    .SYNOPSIS
        Define se a trilha de áudio deve ser copiada diretamente ou transcodificada para Opus,
        com fallback automático para tags Matroska 'BPS' quando stream.bit_rate vier nulo.
    #>
    param ($AudioStream)

    $Codec = $AudioStream.codec_name

    $Channels = 2
    if ($null -ne $AudioStream.channels) { $Channels = [int]$AudioStream.channels }

    $CurrentBitrate = 0
    [long]$ParsedBitrate = 0
    if ($null -ne $AudioStream.bit_rate -and [long]::TryParse([string]$AudioStream.bit_rate, [ref]$ParsedBitrate) -and $ParsedBitrate -gt 0) {
        $CurrentBitrate = [math]::Round($ParsedBitrate / 1000)
    }

    if ($CurrentBitrate -eq 0 -and $AudioStream.tags) {
        foreach ($TagKey in $AudioStream.tags.Keys) {
            if ($TagKey -match "^(?i)BPS(-[A-Za-z]{2,3})?$") {
                [long]$BpsVal = 0
                if ([long]::TryParse([string]$AudioStream.tags[$TagKey], [ref]$BpsVal) -and $BpsVal -gt 0) {
                    $CurrentBitrate = [math]::Round($BpsVal / 1000)
                    break
                }
            }
        }
    }

    $StereoTargetNum = if ($MediaType -eq 2) { 128 } else { 96 }
    $Plan = @{ Action = "Encode"; TargetBitrate = "${StereoTargetNum}k" }

    if ($Codec -eq "opus") {
        $Plan.Action = "Copy"
    } elseif ($Channels -ge 8) {
        if ($CurrentBitrate -gt 0 -and $CurrentBitrate -le 384) { $Plan.Action = "Copy" } else { $Plan.TargetBitrate = "384k" }
    } elseif ($Channels -gt 2) {
        if ($CurrentBitrate -gt 0 -and $CurrentBitrate -le 256) { $Plan.Action = "Copy" } else { $Plan.TargetBitrate = "256k" }
    } elseif ($Channels -eq 1) {
        if ($CurrentBitrate -gt 0 -and $CurrentBitrate -le 64) { $Plan.Action = "Copy" } else { $Plan.TargetBitrate = "64k" }
    } else {
        if ($CurrentBitrate -gt 0 -and $CurrentBitrate -le $StereoTargetNum) { $Plan.Action = "Copy" } else { $Plan.TargetBitrate = "${StereoTargetNum}k" }
    }

    return $Plan
}

function Get-AudioTrackLayoutPlan {
    <#
    .SYNOPSIS
        Classifica, ordena e define as flags Default/Forced para as trilhas de áudio no padrão CRD:
        - Prioriza Português (por / pt-BR) principal em 1º lugar e Japonês (jpn) em 2º lugar.
        - Empurra faixas de Audiodescrição ([AD]) para depois das trilhas principais e garante que [AD] nunca seja Default.
    #>
    param ($AudioStreams)

    $Items = @()
    $RelIdx = 0
    foreach ($Stream in $AudioStreams) {
        $RawLang  = if ($Stream.tags -and $Stream.tags.ContainsKey("language")) { [string]$Stream.tags["language"] } else { "" }
        $RawTitle = if ($Stream.tags -and $Stream.tags.ContainsKey("title"))    { [string]$Stream.tags["title"] }    else { "" }
        $NormLang = Get-NormalizedLanguageCode -Lang $RawLang -Title $RawTitle

        $VisImpaired = ($Stream.disposition -and $Stream.disposition["visual_impaired"] -eq 1)
        $IsAD = $VisImpaired -or ($RawTitle -match "(?i)(\[ad\]|\bad\b|audio\s*description|audiodescri|descriptive)")

        $LangRank = $AppConfig.MediaPreferences.AudioLanguagePriority.IndexOf($NormLang)
        if ($LangRank -lt 0) { $LangRank = 99 }

        $SortWeight = if ($IsAD) { 100 + $LangRank } else { $LangRank }

        $CleanTitle = $RawTitle
        if ([string]::IsNullOrWhiteSpace($CleanTitle)) {
            switch ($NormLang) {
                "por"   { $CleanTitle = if ($IsAD) { "Portuguese [AD]" } else { "Portuguese" } }
                "jpn"   { $CleanTitle = "Japanese" }
                "eng"   { $CleanTitle = "English" }
                default { $CleanTitle = $NormLang }
            }
        }

        $Items += @{
            Stream       = $Stream
            SourceRelIdx = $RelIdx
            NormLang     = $NormLang
            Title        = $CleanTitle
            IsAD         = $IsAD
            SortWeight   = $SortWeight
            IsDefault    = $false
        }
        $RelIdx++
    }

    $Ordered = @($Items | Sort-Object -Property @{Expression={$_.SortWeight}}, @{Expression={$_.SourceRelIdx}})

    $TargetDefaultLang = Get-NormalizedLanguageCode -Lang $AppConfig.MediaPreferences.DefaultAudioLanguage
    $DefaultAssigned = $false

    foreach ($Item in $Ordered) {
        if (-not $DefaultAssigned -and -not $Item.IsAD -and $Item.NormLang -eq $TargetDefaultLang) {
            $Item.IsDefault = $true
            $DefaultAssigned = $true
        }
    }
    if (-not $DefaultAssigned -and $Ordered.Count -gt 0) {
        $FirstNonAD = $Ordered | Where-Object { -not $_.IsAD } | Select-Object -First 1
        if ($null -ne $FirstNonAD) { $FirstNonAD.IsDefault = $true }
        else { $Ordered[0].IsDefault = $true }
    }

    $HasPortugueseAudio = ($null -ne ($Ordered | Where-Object { $_.NormLang -eq "por" -and -not $_.IsAD } | Select-Object -First 1))

    return @{
        Tracks             = $Ordered
        HasPortugueseAudio = $HasPortugueseAudio
    }
}

function Invoke-AssSinglePassAnalysis {
    <#
    .SYNOPSIS
        Analisa e transforma um arquivo .ass em UMA ÚNICA PASSADA em memória RAM (Single-Pass):
        1. Injeta/atualiza ScaledBorderAndShadow: yes
        2. Aplica FixCccSubtitles (se gerado pelo ClosedCaptionConverter)
        3. Coleta famílias e variantes Bold/Italic de fontes em Style: e tags inline \fn
        4. Conta diálogos e separa em memória os eventos de Placas (Signs)
    #>
    param (
        [string]$AssFilePath,
        [string]$NormLang,
        [System.Collections.Generic.HashSet[string]]$UsedFontFamilies,
        [bool]$ExtractSigns
    )

    $Lines        = [System.IO.File]::ReadAllLines($AssFilePath, [System.Text.Encoding]::UTF8)
    $Updated      = [System.Collections.Generic.List[string]]::new($Lines.Length + 4)
    $SignHeader   = [System.Collections.Generic.List[string]]::new()
    $SignEvents   = [System.Collections.Generic.List[string]]::new()

    $TargetSbs    = $AppConfig.MediaPreferences.AddScaledBorderAndShadow
    $HasSbs       = $false
    $InEvents     = $false
    $DialogueCnt  = 0

    $IsCcc = $false
    if ($AppConfig.MediaPreferences.FixCccSubtitles) {
        for ($i = 0; $i -lt [Math]::Min($Lines.Length, 60); $i++) {
            if ($Lines[$i] -match "(?i)(ClosedCaptionConverter|Style:\s*Default_\d+)") {
                $IsCcc = $true
                break
            }
        }
    }

    $SpokenDialogueStyleRegex = "^(?i)(main|main\s*top|top|default|italics|italics[-_\s]*top|flashback|flashback[-_\s]*top|narration|narrator|overlap|internal|thoughts|song|lyrics|spoken|dialogue|dialog|bottom|subtitle)s?$"
    $ExplicitSignStyleRegex   = "(?i)(^|[\s_-])(sign|signs|placa|placas|title|episode|episodenumber|note|notes|text|caption|board|screen|book|paper|letter|place|location|date|label|banner|logo|eyecatch|next|prev|credit)s?($|[\s_-]|\d)"

    foreach ($Line in $Lines) {
        $CurrentLine = $Line

        if (-not $InEvents) {
            if ($CurrentLine -match "^\s*\[Events\]") {
                $InEvents = $true
            } elseif ($CurrentLine -match "^\s*ScaledBorderAndShadow\s*:") {
                if (-not [string]::IsNullOrWhiteSpace($TargetSbs)) {
                    $CurrentLine = "ScaledBorderAndShadow: $TargetSbs"
                }
                $HasSbs = $true
            } elseif ($IsCcc) {
                if ($CurrentLine -match "^\s*PlayResX\s*:") { $CurrentLine = "PlayResX: 640" }
                elseif ($CurrentLine -match "^\s*PlayResY\s*:") { $CurrentLine = "PlayResY: 360" }
                elseif ($CurrentLine -match "^\s*Style:\s*([^,]+),") {
                    $StyleName = $Matches[1].Trim()
                    $Align = "2"
                    if ($CurrentLine -match ",([1-9]),\d+,\d+,\d+,\d+\s*$") { $Align = $Matches[1] }

                    $CurrentLine = "Style: $StyleName,Trebuchet MS,22,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,-1,0,0,0,100,100,0,0,1,2,1,$Align,0020,0020,0015,0"
                }
            }

            # Coleta família tipográfica + variantes Bold/Italic declaradas em Style:
            if ($CurrentLine -match "^\s*Style\s*:\s*(.+)$") {
                $StyleFields = $Matches[1] -split ','
                if ($StyleFields.Count -ge 2) {
                    $Fam = $StyleFields[1].Trim().TrimStart('@')
                    if (-not [string]::IsNullOrWhiteSpace($Fam)) {
                        [void]$UsedFontFamilies.Add($Fam)
                        $IsBold   = ($StyleFields.Count -ge 8 -and ($StyleFields[7].Trim() -eq "-1" -or $StyleFields[7].Trim() -eq "1"))
                        $IsItalic = ($StyleFields.Count -ge 9 -and ($StyleFields[8].Trim() -eq "-1" -or $StyleFields[8].Trim() -eq "1"))

                        if ($IsBold -and $IsItalic) { [void]$UsedFontFamilies.Add("$Fam Bold Italic") }
                        elseif ($IsBold)            { [void]$UsedFontFamilies.Add("$Fam Bold") }
                        elseif ($IsItalic)          { [void]$UsedFontFamilies.Add("$Fam Italic") }
                    }
                }
            }

            if (-not $HasSbs -and -not [string]::IsNullOrWhiteSpace($TargetSbs) -and $CurrentLine -match "^\s*\[V4\+?\s*Styles\]") {
                $Updated.Add("ScaledBorderAndShadow: $TargetSbs")
                $Updated.Add("")
                if ($ExtractSigns) {
                    $SignHeader.Add("ScaledBorderAndShadow: $TargetSbs")
                    $SignHeader.Add("")
                }
                $HasSbs = $true
            }

            $Updated.Add($CurrentLine)
            if ($ExtractSigns) { $SignHeader.Add($CurrentLine) }
            continue
        }

        # Dentro da seção [Events]
        $Updated.Add($CurrentLine)

        if ($CurrentLine -match "^\s*Format\s*:") {
            if ($ExtractSigns) { $SignHeader.Add($CurrentLine) }
            continue
        }

        if ($CurrentLine -match "^\s*Dialogue\s*:") {
            $DialogueCnt++

            # Coleta fontes inline (\fnFonte)
            if ($CurrentLine -match "\\fn") {
                foreach ($M in [regex]::Matches($CurrentLine, "\\fn([^\\\}]+)")) {
                    $Fam = $M.Groups[1].Value.Trim().TrimStart('@')
                    if (-not [string]::IsNullOrWhiteSpace($Fam)) { [void]$UsedFontFamilies.Add($Fam) }
                }
            }

            # Se solicitado, verifica na mesma passada se a linha pertence às Placas (Signs)
            if ($ExtractSigns -and $CurrentLine -match "^\s*Dialogue\s*:\s*[^,]*,[^,]*,[^,]*,([^,]*),([^,]*),[^,]*,[^,]*,[^,]*,[^,]*,(.*)$") {
                $StyleName = $Matches[1].Trim()
                $ActorName = $Matches[2].Trim()
                $TextBody  = $Matches[3]

                $IsExplicitSignStyle   = ($StyleName -match $ExplicitSignStyleRegex)
                $IsExplicitSignActor   = ($ActorName -match "(?i)^(sign|signs|placa|placas|text|title|note|caption|screen|board)$")
                $IsNonSpokenPositioned = ($StyleName -notmatch $SpokenDialogueStyleRegex) -and ($TextBody -match "\\(pos|move|org|clip|iclip|fad|an[7891346])\b")

                if ($IsExplicitSignStyle -or $IsExplicitSignActor -or $IsNonSpokenPositioned) {
                    $SignEvents.Add($CurrentLine)
                }
            }
        }
    }

    if (-not $HasSbs -and -not [string]::IsNullOrWhiteSpace($TargetSbs)) {
        $Updated.Insert(0, "ScaledBorderAndShadow: $TargetSbs")
        if ($ExtractSigns) { $SignHeader.Insert(0, "ScaledBorderAndShadow: $TargetSbs") }
    }

    [System.IO.File]::WriteAllLines($AssFilePath, $Updated, $Utf8NoBom)

    $CombinedSignLines = @()
    if ($ExtractSigns -and $SignEvents.Count -gt 0) {
        $CombinedSignLines = @($SignHeader) + @($SignEvents)
    }

    return @{
        DialogueLines = $DialogueCnt
        SignCount     = $SignEvents.Count
        SignLines     = $CombinedSignLines
    }
}

function Resolve-RequiredFontsFromCache {
    <#
    .SYNOPSIS
        Resolve instantaneamente em memória (O(1)) os caminhos das fontes usadas nas legendas .ass
        que ainda não estão anexadas no arquivo MKV original.
    #>
    param (
        [System.Collections.Generic.HashSet[string]]$UsedFontFamilies,
        [string[]]$AlreadyAttachedFontNames,
        $FontCache
    )

    if (-not $AppConfig.MediaPreferences.MuxFonts -or $UsedFontFamilies.Count -eq 0 -or $null -eq $FontCache) {
        return @()
    }

    $AttachedSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($Name in $AlreadyAttachedFontNames) {
        if (-not [string]::IsNullOrWhiteSpace($Name)) { [void]$AttachedSet.Add($Name) }
    }

    $FilesToAttach = [System.Collections.Generic.List[string]]::new()

    foreach ($Family in $UsedFontFamilies) {
        $Key = $Family.ToLowerInvariant()
        $CandidateFileNames = @()
        if ($FontFileLookup.ContainsKey($Key)) {
            $CandidateFileNames += $FontFileLookup[$Key]
        }
        $SafeName = $Family -replace "\s+", ""
        $CandidateFileNames += @("$Family.ttf", "$Family.otf", "$SafeName.ttf", "$SafeName.otf")

        $AlreadyPresent = $false
        foreach ($Cand in $CandidateFileNames) {
            if ($AttachedSet.Contains($Cand)) {
                $AlreadyPresent = $true
                break
            }
        }
        if ($AlreadyPresent) { continue }

        foreach ($Cand in $CandidateFileNames) {
            if ($FontCache.ContainsKey($Cand)) {
                $ResolvedPath = $FontCache[$Cand]
                $FileNameOnly = [System.IO.Path]::GetFileName($ResolvedPath)
                if (-not $AttachedSet.Contains($FileNameOnly)) {
                    [void]$AttachedSet.Add($FileNameOnly)
                    $FilesToAttach.Add($ResolvedPath)
                }
                break
            }
        }
    }

    return $FilesToAttach.ToArray()
}

function Invoke-SubtitleAndFontProcessing {
    <#
    .SYNOPSIS
        Extrai, corrige, classifica e ordena todas as legendas do MKV no padrão CRD em uma única passada:
        - Coloca Português (pt-BR) sempre como principal no topo.
        - Identifica (ou gera automaticamente) a faixa de Placas (Brazilian Portuguese Signs).
        - Quando o áudio é PT-BR, define Signs como Default=yes e Forced=yes (e desmarca Default da legenda completa).
        - Quando o áudio é apenas Japonês (ou não há Signs), define a legenda completa PT-BR como Default=yes.
        - Aplica ScaledBorderAndShadow: yes, FixCccSubtitles e localiza fontes via cache O(1).
    #>
    param (
        [hashtable]$Context,
        $SubtitleStreams,
        $AttachmentStreams,
        [bool]$HasPortugueseAudio,
        $FontCache
    )

    if ($null -eq $SubtitleStreams -or @($SubtitleStreams).Count -eq 0) {
        return @{ Tracks = @(); FontsToAttach = @(); HasPorSigns = $false; UseFallbackCopy = $false }
    }

    [void][System.IO.Directory]::CreateDirectory($Context.SubsDir)

    Write-AppLog "Extraindo e padronizando faixas de legenda (Padrão CRD Single-Pass)..." "INFO"
    $ExtractArgs = @("-v", "error", "-y", "-i", $Context.OriginalFile)
    $RawMetaList = @()

    $SubRelIdx = 0
    foreach ($Stream in $SubtitleStreams) {
        $Codec = [string]$Stream.codec_name
        $OutCodec = "copy"
        $ExtraFmtArgs = @()
        $Ext = switch -Regex ($Codec) {
            "^(ass|ssa)$"       { "ass" }
            "^(subrip|srt)$"    { "srt" }
            "^(webvtt|vtt)$"    { "vtt" }
            "^(mov_text|tx3g)$" { $OutCodec = "srt"; "srt" }
            default             { $ExtraFmtArgs = @("-f", "matroska"); "mks" }
        }
        $OutFile = [System.IO.Path]::Combine($Context.SubsDir, ("sub_{0:D2}.{1}" -f $SubRelIdx, $Ext))
        $ExtractArgs += @("-map", "0:s:$SubRelIdx", "-c:s", $OutCodec) + $ExtraFmtArgs + @($OutFile)

        $RawLang  = if ($Stream.tags -and $Stream.tags.ContainsKey("language")) { [string]$Stream.tags["language"] } else { "" }
        $RawTitle = if ($Stream.tags -and $Stream.tags.ContainsKey("title"))    { [string]$Stream.tags["title"] }    else { "" }
        $NormLang = Get-NormalizedLanguageCode -Lang $RawLang -Title $RawTitle

        $IsForcedDisp = ($Stream.disposition -and $Stream.disposition["forced"] -eq 1)
        $IsSDHDisp    = ($Stream.disposition -and $Stream.disposition["hearing_impaired"] -eq 1)

        $IsSigns = $IsForcedDisp -or ($RawTitle -match "(?i)\b(signs|forced|placas)\b")
        $IsCC    = $IsSDHDisp -or ($RawTitle -match "(?i)(\[cc\]|\bcc\b|sdh|closed\s*caption)")

        $RawMetaList += @{
            Stream        = $Stream
            SourceRelIdx  = $SubRelIdx
            Codec         = $Codec
            Ext           = $Ext
            FilePath      = $OutFile
            RawLang       = if ([string]::IsNullOrWhiteSpace($RawLang)) { $NormLang } else { $RawLang }
            NormLang      = $NormLang
            Title         = $RawTitle
            IsSigns       = $IsSigns
            IsCC          = $IsCC
            DialogueLines = 0
            SignCount     = 0
            SignLines     = @()
        }
        $SubRelIdx++
    }

    & ffmpeg @ExtractArgs
    if ($LASTEXITCODE -ne 0) {
        Write-AppLog "Aviso: Falha ao extrair legendas isoladamente; mantendo cópia direta do MKV." "WARN"
        return @{ Tracks = @(); FontsToAttach = @(); HasPorSigns = $false; UseFallbackCopy = $true }
    }

    $UsedFontFamilies = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($Track in $RawMetaList) {
        if ($Track.Ext -eq "ass" -and $Track.NormLang -eq "por" -and [System.IO.File]::Exists($Track.FilePath)) {
            $NeedSignScan = ($Track.NormLang -eq "por" -and -not $Track.IsCC -and $AppConfig.MediaPreferences.AutoExtractSignsFromFullAss)
            $Analysis = Invoke-AssSinglePassAnalysis -AssFilePath $Track.FilePath -NormLang $Track.NormLang -UsedFontFamilies $UsedFontFamilies -ExtractSigns $NeedSignScan
            $Track.DialogueLines = $Analysis.DialogueLines
            $Track.SignCount     = $Analysis.SignCount
            $Track.SignLines     = $Analysis.SignLines
        } elseif ($Track.Ext -eq "srt" -and [System.IO.File]::Exists($Track.FilePath)) {
            $SrtLines = [System.IO.File]::ReadAllLines($Track.FilePath, [System.Text.Encoding]::UTF8)
            $Track.DialogueLines = @($SrtLines | Where-Object { $_ -match "^\s*\d{2}:\d{2}:\d{2}[,.]\d{3}\s*-->" }).Count
        }
    }

    $ForcedLabel = if ($MediaType -eq 2) { "Brazilian Portuguese (Forced)" } else { "Brazilian Portuguese Signs" }
    $PorCandidates = @($RawMetaList | Where-Object { $_.NormLang -eq "por" -and -not $_.IsCC })
    $HasPorSigns = ($null -ne ($PorCandidates | Where-Object { $_.IsSigns } | Select-Object -First 1))

    if (-not $HasPorSigns -and $PorCandidates.Count -ge 2) {
        $SortedByLines = @($PorCandidates | Sort-Object -Property @{Expression={$_.DialogueLines}} -Descending)
        $MainPor = $SortedByLines[0]
        $SmallestPor = $SortedByLines[-1]
        if ($MainPor.DialogueLines -gt 0 -and $SmallestPor.DialogueLines -gt 0 -and ($SmallestPor.DialogueLines / $MainPor.DialogueLines) -le 0.40) {
            $SmallestPor.IsSigns = $true
            if ([string]::IsNullOrWhiteSpace($SmallestPor.Title) -or $SmallestPor.Title -eq "Brazilian Portuguese") {
                $SmallestPor.Title = $ForcedLabel
            }
            $HasPorSigns = $true
            Write-AppLog "-> Faixa de legenda PT-BR menor ($($SmallestPor.DialogueLines) linhas) identificada como Forçada/Signs." "SUCCESS"
        }
    }

    $FinalTrackList = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($Track in $RawMetaList) {
        $FinalTrackList.Add($Track)

        if (-not $HasPorSigns -and $AppConfig.MediaPreferences.AutoExtractSignsFromFullAss -and $Track.NormLang -eq "por" -and -not $Track.IsCC -and $Track.Ext -eq "ass") {
            if ($Track.SignCount -gt 0 -and $Track.SignCount -lt $Track.DialogueLines) {
                $SignsPath = [System.IO.Path]::Combine($Context.SubsDir, "sub_por_signs_auto.ass")
                [System.IO.File]::WriteAllLines($SignsPath, [string[]]$Track.SignLines, $Utf8NoBom)

                $AutoSignsTrack = @{
                    Stream        = $Track.Stream
                    SourceRelIdx  = $Track.SourceRelIdx
                    Codec         = "ass"
                    Ext           = "ass"
                    FilePath      = $SignsPath
                    RawLang       = "por"
                    NormLang      = "por"
                    Title         = "Brazilian Portuguese Signs"
                    IsSigns       = $true
                    IsCC          = $false
                    DialogueLines = $Track.SignCount
                }
                $FinalTrackList.Add($AutoSignsTrack)
                $HasPorSigns = $true
                Write-AppLog "-> Gerada automaticamente trilha 'Brazilian Portuguese Signs' ($($Track.SignCount) placas extraídas do ASS)." "SUCCESS"
            }
        }
        $Track.SignLines = $null
    }

    foreach ($T in $FinalTrackList) {
        $LangRank = $AppConfig.MediaPreferences.SubtitleLanguagePriority.IndexOf($T.NormLang)
        if ($LangRank -lt 0) { $LangRank = 99 }

        $SubTypeRank = if ($T.IsCC) { 2 } elseif ($T.IsSigns) { 1 } else { 0 }
        $T["SortWeight"] = ($LangRank * 10) + $SubTypeRank

        if ($T.NormLang -eq "por") {
            if ($T.IsSigns -and $T.Title -notmatch "(?i)(signs|forced|for[çc]ad|placas)") {
                $T.Title = $ForcedLabel
            } elseif (-not $T.IsSigns -and -not $T.IsCC -and [string]::IsNullOrWhiteSpace($T.Title)) {
                $T.Title = "Brazilian Portuguese"
            }
        }
    }

    $OrderedSubs = @($FinalTrackList | Sort-Object -Property @{Expression={$_.SortWeight}}, @{Expression={$_.SourceRelIdx}})

    $TargetSubLang = Get-NormalizedLanguageCode -Lang $AppConfig.MediaPreferences.DefaultSubtitleLanguage
    $UseSignsAsDefault = $HasPortugueseAudio -and $AppConfig.MediaPreferences.DefaultSubtitleSigns -and $HasPorSigns
    $DefaultSubAssigned = $false

    foreach ($T in $OrderedSubs) {
        $T["IsForced"]  = ($T.IsSigns -and $AppConfig.MediaPreferences.MarkSignsAsForced)
        $T["IsDefault"] = $false

        if (-not $DefaultSubAssigned -and $T.NormLang -eq $TargetSubLang -and -not $T.IsCC) {
            if ($UseSignsAsDefault -and $T.IsSigns) {
                $T["IsDefault"] = $true
                $DefaultSubAssigned = $true
            } elseif (-not $UseSignsAsDefault -and -not $T.IsSigns) {
                $T["IsDefault"] = $true
                $DefaultSubAssigned = $true
            }
        }
    }

    $ExistingFontNames = @()
    if ($null -ne $AttachmentStreams) {
        foreach ($Att in $AttachmentStreams) {
            if ($Att.tags -and $Att.tags.ContainsKey("filename")) {
                $ExistingFontNames += [string]$Att.tags["filename"]
            }
        }
    }
    $FontsToAttach = Resolve-RequiredFontsFromCache -UsedFontFamilies $UsedFontFamilies -AlreadyAttachedFontNames $ExistingFontNames -FontCache $FontCache
    if ($FontsToAttach.Count -gt 0) {
        Write-AppLog "-> Fontes adicionais localizadas no cache para anexo no MKV: $($FontsToAttach.Count) arquivo(s)." "SUCCESS"
    }

    return @{
        Tracks          = $OrderedSubs
        FontsToAttach   = $FontsToAttach
        HasPorSigns     = $HasPorSigns
        UseFallbackCopy = $false
    }
}

function Test-NeedsTrackNormalization {
    <#
    .SYNOPSIS
        Verifica se um arquivo MKV (já codificado em AV1/HEVC) precisa de Remux Rápido CRD:
        - Mais de 1 áudio default ou [AD] marcado como default;
        - Ordem de áudio incorreta (ex.: 'por' não está em 1º ou [AD] antes de faixas normais);
        - Disposição incorreta das legendas PT-BR (Full vs Signs);
        - Apenas 1 legenda PT-BR e ainda não registrada no cache de remux para esta assinatura de arquivo.
    #>
    param (
        $MediaData,
        $SkipHistory = $null,
        [string]$RemuxKey = "",
        [string]$FileSignature = ""
    )

    $AudioStreams = @($MediaData.streams | Where-Object { $_.codec_type -eq "audio" })
    $SubStreams   = @($MediaData.streams | Where-Object { $_.codec_type -eq "subtitle" })

    if ($AudioStreams.Count -gt 0) {
        $DefaultAudios = @($AudioStreams | Where-Object { $_.disposition -and $_.disposition["default"] -eq 1 })
        if ($DefaultAudios.Count -ne 1) { return $true }

        $DefAudioTitle = if ($DefaultAudios[0].tags -and $DefaultAudios[0].tags.ContainsKey("title")) { [string]$DefaultAudios[0].tags["title"] } else { "" }
        if ($DefAudioTitle -match "(?i)(\[ad\]|\bad\b|audio\s*description|audiodescri)") { return $true }

        $AudioPlan = Get-AudioTrackLayoutPlan -AudioStreams $AudioStreams
        for ($i = 0; $i -lt $AudioStreams.Count; $i++) {
            if ($AudioPlan.Tracks[$i].SourceRelIdx -ne $i) { return $true }
            if ($AudioPlan.Tracks[$i].IsDefault -and ($AudioStreams[$i].disposition["default"] -ne 1)) { return $true }
        }
    }

    $HasPorAudio = ($null -ne ($AudioStreams | Where-Object {
        $L = if ($_.tags -and $_.tags.ContainsKey("language")) { [string]$_.tags["language"] } else { "" }
        $T = if ($_.tags -and $_.tags.ContainsKey("title"))    { [string]$_.tags["title"] }    else { "" }
        $IsAD = ($_.disposition -and $_.disposition["visual_impaired"] -eq 1) -or ($T -match "(?i)(\[ad\]|\bad\b|audio\s*description)")
        (-not $IsAD) -and ((Get-NormalizedLanguageCode -Lang $L -Title $T) -eq "por")
    } | Select-Object -First 1))

    if ($SubStreams.Count -gt 0) {
        $NonCcPorSubs = @($SubStreams | Where-Object {
            $L = if ($_.tags -and $_.tags.ContainsKey("language")) { [string]$_.tags["language"] } else { "" }
            $T = if ($_.tags -and $_.tags.ContainsKey("title"))    { [string]$_.tags["title"] }    else { "" }
            $IsCC = ($_.disposition -and $_.disposition["hearing_impaired"] -eq 1) -or ($T -match "(?i)(\[cc\]|\bcc\b|sdh|closed\s*caption)")
            (-not $IsCC) -and ((Get-NormalizedLanguageCode -Lang $L -Title $T) -eq "por")
        })

        if ($NonCcPorSubs.Count -ge 2 -and $HasPorAudio) {
            $SignsSub = $NonCcPorSubs | Where-Object {
                $T = if ($_.tags -and $_.tags.ContainsKey("title")) { [string]$_.tags["title"] } else { "" }
                ($_.disposition -and $_.disposition["forced"] -eq 1) -or ($T -match "(?i)\b(signs|forced|placas)\b")
            } | Select-Object -First 1

            if ($null -ne $SignsSub -and $AppConfig.MediaPreferences.DefaultSubtitleSigns) {
                $IsSignsDef = ($SignsSub.disposition -and $SignsSub.disposition["default"] -eq 1)
                $IsSignsFrc = ($SignsSub.disposition -and $SignsSub.disposition["forced"] -eq 1)
                if (-not $IsSignsDef -or ($AppConfig.MediaPreferences.MarkSignsAsForced -and -not $IsSignsFrc)) {
                    return $true
                }
            }
        } elseif ($HasPorAudio -and $NonCcPorSubs.Count -eq 1 -and $AppConfig.MediaPreferences.AutoExtractSignsFromFullAss) {
            if ($null -ne $SkipHistory -and -not [string]::IsNullOrWhiteSpace($RemuxKey) -and $SkipHistory.ContainsKey($RemuxKey) -and $SkipHistory[$RemuxKey] -eq $FileSignature) {
                return $false
            }
            return $true
        }
    }

    return $false
}

# ====================================================================
# 4. FUNÇÕES DE EXECUÇÃO (Wrappers de Ferramentas Externas)
# ====================================================================

function Invoke-VideoEncoding {
    <#
    .SYNOPSIS
        Executa o script Python do Auto-Boost para processar a faixa de vídeo dentro do diretório seguro (WorkingDir).
    #>
    param (
        [hashtable]$Context,
        [hashtable]$RuntimeEncoder = $null
    )

    if ($null -eq $RuntimeEncoder) { $RuntimeEncoder = $AppConfig.Encoder }
    Write-AppLog "Iniciando codificação de vídeo (Auto-Boost)..." "WARN"
    $PythonArgs = @("-i", $Context.OriginalFile) + @($RuntimeEncoder.AutoBoostArgs) + @("--final-params", $RuntimeEncoder.FinalParams)

    Push-Location -LiteralPath $Context.WorkingDir
    try {
        & $AppConfig.Paths.PythonExe $AppConfig.Paths.AutoBoostScript @PythonArgs
        $PythonExitCode = $LASTEXITCODE
    } finally {
        Pop-Location
    }

    if ($PythonExitCode -ne 0 -or -not [System.IO.File]::Exists($Context.VideoTemp)) {
        throw "O arquivo final de vídeo (.ivf) não foi gerado ou Auto-Boost retornou erro ($PythonExitCode)."
    }
}

function Invoke-AudioProcessing {
    <#
    .SYNOPSIS
        Aplica a lógica de otimização para cada trilha de áudio usando FFmpeg,
        já reordenando as faixas (PT-BR principal -> JA-JP -> [AD]) e preservando idioma e título.
        Retorna $true se gerou o AudioTemp ou $false se não houver trilhas de áudio.
    #>
    param ([hashtable]$Context, $AudioLayoutPlan)

    if ($null -eq $AudioLayoutPlan -or $null -eq $AudioLayoutPlan.Tracks -or $AudioLayoutPlan.Tracks.Count -eq 0) {
        Write-AppLog "Nenhuma trilha de áudio encontrada. Pulando etapa de áudio." "INFO"
        return $false
    }

    Write-AppLog "Processando e ordenando trilhas de áudio dinamicamente..." "INFO"
    $FfmpegArgs = @("-v", "error", "-y", "-i", $Context.OriginalFile)

    $OutIndex = 0
    foreach ($TrackInfo in $AudioLayoutPlan.Tracks) {
        $Stream = $TrackInfo.Stream
        $SrcIdx = $TrackInfo.SourceRelIdx
        $Plan   = Get-AudioOptimizationPlan -AudioStream $Stream

        $FfmpegArgs += "-map", "0:a:$SrcIdx"
        $FfmpegArgs += "-metadata:s:a:$OutIndex", "language=$($TrackInfo.NormLang)"
        $FfmpegArgs += "-metadata:s:a:$OutIndex", "title=$($TrackInfo.Title)"

        $DispValue = if ($TrackInfo.IsDefault) { "default" } else { "0" }
        $FfmpegArgs += "-disposition:a:$OutIndex", $DispValue

        if ($Plan.Action -eq "Copy") {
            Write-AppLog "-> Trilha $OutIndex (orig #$SrcIdx) [$($TrackInfo.NormLang) - $($TrackInfo.Title) | $($Stream.codec_name) | Default=$($TrackInfo.IsDefault)]: Cópia direta." "SUCCESS"
            $FfmpegArgs += "-c:a:$OutIndex", "copy"
        } else {
            Write-AppLog "-> Trilha $OutIndex (orig #$SrcIdx) [$($TrackInfo.NormLang) - $($TrackInfo.Title) | $($Stream.codec_name) / $($Stream.channels)ch | Default=$($TrackInfo.IsDefault)]: Convertendo para Opus $($Plan.TargetBitrate)." "WARN"
            $FfmpegArgs += "-c:a:$OutIndex", "libopus", "-b:a:$OutIndex", $Plan.TargetBitrate, "-vbr:a:$OutIndex", "on"

            # === CORREÇÃO DE ERRO PARA OPUS (5.1 e 7.1) ===
            if ($Stream.channels -eq 6) {
                $FfmpegArgs += "-filter:a:$OutIndex", "channelmap=channel_layout=5.1"
            } elseif ($Stream.channels -eq 8) {
                $FfmpegArgs += "-filter:a:$OutIndex", "channelmap=channel_layout=7.1"
            }
        }
        $OutIndex++
    }

    $FfmpegArgs += $Context.AudioTemp
    & ffmpeg @FfmpegArgs

    if ($LASTEXITCODE -ne 0) {
        throw "Erro fatal durante a conversão de áudio (FFmpeg). O arquivo pode conter canais incompatíveis."
    }

    return $true
}

function Invoke-MediaMuxing {
    <#
    .SYNOPSIS
        Gera o XML de tags do vídeo apenas quando há re-encode (evitando duplicar DESCRIPTION ou sobrescrever tags no Remux)
        e usa o MKVMerge para empacotar Vídeo, Áudio, Legendas (ordenadas com flags Signs/Default/Forced),
        Capas (cover.png) e Fontes (.ttf/.otf).
    #>
    param (
        [hashtable]$Context,
        [string]$EncoderVersion,
        $MediaData,
        $AudioLayoutPlan,
        $SubtitlePlan,
        [hashtable]$RuntimeEncoder = $null,
        [bool]$UseOriginalVideo = $false,
        [bool]$HasAudioTemp = $true
    )

    if ($null -eq $RuntimeEncoder) { $RuntimeEncoder = $AppConfig.Encoder }

    $MkvArgs = @("-o", $Context.MkvTemp)
    $NoPreserveFlags = @()
    if (-not $AppConfig.MediaPreferences.PreserveDescriptionAndCover) {
        $NoPreserveFlags = @("--no-global-tags", "--no-attachments")
    }

    # 1. Entrada de Vídeo
    if ($UseOriginalVideo) {
        $VideoTrackId = 0
        if ($null -ne $MediaData -and $null -ne $MediaData.streams) {
            $VideoStream = $MediaData.streams | Where-Object { $_.codec_type -eq "video" -and (-not $_.disposition -or $_.disposition["attached_pic"] -ne 1) } | Select-Object -First 1
            $MkvTrackIdx = 0
            foreach ($S in ($MediaData.streams | Sort-Object -Property index)) {
                $IsAttach = ($S.codec_type -eq "attachment") -or ($S.disposition -and $S.disposition["attached_pic"] -eq 1)
                if ($IsAttach) { continue }
                if ($null -ne $VideoStream -and $S.index -eq $VideoStream.index) {
                    $VideoTrackId = $MkvTrackIdx
                    break
                }
                $MkvTrackIdx++
            }
        }

        Write-AppLog "Empacotando vídeo original + trilhas padronizadas via mkvmerge (preservando tags e capa)..." "WARN"
        $MkvArgs += $NoPreserveFlags
        if ($null -eq $SubtitlePlan -or -not $SubtitlePlan.UseFallbackCopy) { $MkvArgs += "--no-subtitles" }
        $MkvArgs += "--no-audio", "--default-track-flag", "${VideoTrackId}:yes", $Context.OriginalFile
    } else {
        Write-AppLog "Gerando tags de vídeo XML (ENCODER / ENCODER_SETTINGS)..." "INFO"
        $EncoderSettings = "Auto-Boost: $($RuntimeEncoder.AutoBoostArgs -join ' ') | SVT-AV1: $($RuntimeEncoder.FinalParams)"
        $EscapedEncoder  = [System.Security.SecurityElement]::Escape([string]$EncoderVersion)
        $EscapedSettings = [System.Security.SecurityElement]::Escape([string]$EncoderSettings)

        $XmlContent = @"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE Tags SYSTEM "matroskatags.dtd">
<Tags>
  <Tag>
    <Targets><TargetTypeValue>50</TargetTypeValue></Targets>
    <Simple><Name>ENCODER</Name><String>$EscapedEncoder</String></Simple>
    <Simple><Name>ENCODER_SETTINGS</Name><String>$EscapedSettings</String></Simple>
  </Tag>
</Tags>
"@
        [System.IO.File]::WriteAllText($Context.TagsXml, $XmlContent, $Utf8NoBom)

        Write-AppLog "Empacotando vídeo, áudio, legendas e fontes via mkvmerge..." "WARN"
        $AspectArgs = @()
        if ($null -ne $MediaData -and $null -ne $MediaData.streams) {
            $VideoStream = $MediaData.streams | Where-Object { $_.codec_type -eq "video" -and (-not $_.disposition -or $_.disposition["attached_pic"] -ne 1) } | Select-Object -First 1
            if ($null -ne $VideoStream -and -not [string]::IsNullOrWhiteSpace($VideoStream.sample_aspect_ratio) -and $VideoStream.sample_aspect_ratio -notin @("1:1", "0:1", "N/A") -and $VideoStream.display_aspect_ratio -match "^\d+:\d+$") {
                $AspectArgs = @("--aspect-ratio", "0:$($VideoStream.display_aspect_ratio)")
            }
        }
        $MkvArgs += @("--tags", "0:$($Context.TagsXml)", "--default-track-flag", "0:yes") + $AspectArgs + @($Context.VideoTemp)
    }

    # 2. Entrada de Áudio
    if ($HasAudioTemp -and $null -ne $AudioLayoutPlan -and $AudioLayoutPlan.Tracks.Count -gt 0 -and [System.IO.File]::Exists($Context.AudioTemp)) {
        $AudioTrackIdx = 0
        foreach ($AudioTrack in $AudioLayoutPlan.Tracks) {
            $DefFlag = if ($AudioTrack.IsDefault) { "yes" } else { "no" }
            $MkvArgs += "--language", "${AudioTrackIdx}:$($AudioTrack.NormLang)"
            $MkvArgs += "--track-name", "${AudioTrackIdx}:$($AudioTrack.Title)"
            $MkvArgs += "--default-track-flag", "${AudioTrackIdx}:$DefFlag"
            $MkvArgs += "--forced-display-flag", "${AudioTrackIdx}:no"
            $AudioTrackIdx++
        }
        $MkvArgs += $Context.AudioTemp
    }

    # 3. Entradas de Legendas (Ordenadas no padrão CRD com Default/Forced/Signs)
    if ($null -ne $SubtitlePlan -and -not $SubtitlePlan.UseFallbackCopy -and $SubtitlePlan.Tracks.Count -gt 0) {
        foreach ($SubTrack in $SubtitlePlan.Tracks) {
            $DefFlag    = if ($SubTrack.IsDefault) { "yes" } else { "no" }
            $ForcedFlag = if ($SubTrack.IsForced)  { "yes" } else { "no" }

            $MkvArgs += "--language", "0:$($SubTrack.NormLang)"
            if (-not [string]::IsNullOrWhiteSpace($SubTrack.Title)) {
                $MkvArgs += "--track-name", "0:$($SubTrack.Title)"
            }
            $MkvArgs += "--default-track-flag", "0:$DefFlag"
            $MkvArgs += "--forced-display-flag", "0:$ForcedFlag"
            $MkvArgs += $SubTrack.FilePath

            Write-AppLog "-> Legenda [$($SubTrack.NormLang) | $($SubTrack.Title)]: Default=$DefFlag | Forced=$ForcedFlag" "INFO"
        }

        if (-not $UseOriginalVideo) {
            $MkvArgs += $NoPreserveFlags
            $MkvArgs += "--no-video", "--no-audio", "--no-subtitles", $Context.OriginalFile
        }
    } else {
        if (-not $UseOriginalVideo) {
            $MkvArgs += $NoPreserveFlags
            $MkvArgs += "--no-video", "--no-audio", $Context.OriginalFile
        }
    }

    # 4. Anexa fontes adicionais (.ttf/.otf) detectadas nas legendas .ass
    if ($null -ne $SubtitlePlan -and $null -ne $SubtitlePlan.FontsToAttach) {
        foreach ($FontPath in $SubtitlePlan.FontsToAttach) {
            $MkvArgs += "--attach-file", $FontPath
        }
    }

    & $AppConfig.Paths.MkvMergeExe @MkvArgs

    if ($LASTEXITCODE -ge 2) {
        throw "Erro fatal durante a multiplexação (mkvmerge retornou código $LASTEXITCODE)."
    }
}

function Measure-QualityAndSize {
    <#
    .SYNOPSIS
        Avalia PRIMEIRO a Regra dos 80% de tamanho instantaneamente (0,001s).
        Se reprovar por tamanho, rejeita imediatamente SEM rodar o FFVship (SSIMULACRA2).
    #>
    param ([hashtable]$Context)

    # === 1. CÁLCULO INSTANTÂNEO DE TAMANHO (Regra dos 80% ANTES do FFVship) ===
    $OriginalLength = ([System.IO.FileInfo]::new((ConvertTo-LongPath $Context.OriginalFile))).Length
    $NewLength      = ([System.IO.FileInfo]::new((ConvertTo-LongPath $Context.MkvTemp))).Length

    if ($OriginalLength -eq 0) {
        throw "Arquivo original está com 0 bytes! Impossível calcular a compressão."
    }

    $Ratio           = $NewLength / $OriginalLength
    $PercentOriginal = [math]::Round($Ratio * 100, 2)
    $Savings         = [math]::Round(100 - $PercentOriginal, 2)
    $SizeApproved    = ($Ratio -le $AppConfig.Rules.MaxTargetSizeRatio)

    Write-AppLog "Tamanho Original: $([math]::Round($OriginalLength / 1MB, 2)) MB" "INFO"
    Write-AppLog "Tamanho Novo: $([math]::Round($NewLength / 1MB, 2)) MB ($PercentOriginal% do original)" "INFO"

    if (-not $SizeApproved) {
        Write-AppLog "O arquivo falhou na Regra dos 80% ($PercentOriginal% > $($AppConfig.Rules.MaxTargetSizeRatio * 100)%). Rejeitado imediatamente (FFVship poupado)!" "ERROR"
        return @{
            Approved       = $false
            RejectedBySize = $true
            Ratio          = $Ratio
            OriginalBytes  = $OriginalLength
            NewBytes       = $NewLength
        }
    }

    if (-not $AppConfig.Rules.VerifyFinalSsimu2) {
        Write-AppLog "O arquivo reduziu $Savings% (<= $($AppConfig.Rules.MaxTargetSizeRatio * 100)%) e a auditoria extra SSIMULACRA2 está desativada. Aprovado!" "SUCCESS"
        return @{
            Approved       = $true
            RejectedBySize = $false
            Ratio          = $Ratio
            OriginalBytes  = $OriginalLength
            NewBytes       = $NewLength
        }
    }

    # === 2. AUDITORIA VISUAL SSIMULACRA2 (Apenas para arquivos que já passaram no tamanho!) ===
    Write-AppLog "Tamanho aprovado ($PercentOriginal%). Calculando métrica SSIMULACRA2 final (Comparando com o Original)..." "WARN"

    $OutputText   = ""
    $SsimuAverage = $null
    $SsimuMedian  = $null
    $Ssimu5th     = $null
    $Ssimu95th    = $null
    $SsimuMin     = $null
    $SsimuStdDev  = $null

    $GpuMutex = [System.Threading.Mutex]::new($false, "Local\RTX5060Ti_GPU_Lock")
    $MutexAcquired = $false
    try {
        try {
            $MutexAcquired = $GpuMutex.WaitOne(600000)
        } catch [System.Threading.AbandonedMutexException] {
            $MutexAcquired = $true
        }
        if (-not $MutexAcquired) {
            Write-AppLog "Aviso: Timeout aguardando trava de GPU; preservando encode como '_Encoded.mkv'." "WARN"
            return @{
                Approved       = $false
                RejectedBySize = $false
                AuditFailed    = $true
                Ratio          = $Ratio
                OriginalBytes  = $OriginalLength
                NewBytes       = $NewLength
            }
        }

        (Get-Process -Id $PID).PriorityClass = 'BelowNormal'
        foreach ($GpuThreads in @(2, 1)) {
            $FfvshipArgs = @("--source", $Context.OriginalFile, "--encoded", $Context.MkvTemp, "-m", "SSIMULACRA2", "--threads", "2", "--gpu-threads", [string]$GpuThreads)
            if ($AppConfig.Rules.FfvshipEvery -gt 1) {
                $FfvshipArgs += @("--every", [string]$AppConfig.Rules.FfvshipEvery)
            }
            $ProcessOutput = & $AppConfig.Paths.FfvshipExe @FfvshipArgs
            $OutputText = $ProcessOutput -join "`n"

            $SsimuAverage = $null; $SsimuMedian = $null; $Ssimu5th = $null; $Ssimu95th = $null; $SsimuMin = $null; $SsimuStdDev = $null
            if ($LASTEXITCODE -eq 0) {
                if ($OutputText -match 'Average\s*:\s*(-?[\d.]+)')            { $SsimuAverage = [double]::Parse($Matches[1], [cultureinfo]::InvariantCulture) }
                if ($OutputText -match 'Standard Deviation\s*:\s*(-?[\d.]+)') { $SsimuStdDev  = [double]::Parse($Matches[1], [cultureinfo]::InvariantCulture) }
                if ($OutputText -match 'Median\s*:\s*(-?[\d.]+)')             { $SsimuMedian  = [double]::Parse($Matches[1], [cultureinfo]::InvariantCulture) }
                if ($OutputText -match '5th percentile\s*:\s*(-?[\d.]+)')     { $Ssimu5th     = [double]::Parse($Matches[1], [cultureinfo]::InvariantCulture) }
                if ($OutputText -match '95th percentile\s*:\s*(-?[\d.]+)')    { $Ssimu95th    = [double]::Parse($Matches[1], [cultureinfo]::InvariantCulture) }
                if ($OutputText -match 'Minimum\s*:\s*(-?[\d.]+)')            { $SsimuMin     = [double]::Parse($Matches[1], [cultureinfo]::InvariantCulture) }
            }

            if ($LASTEXITCODE -eq 0 -and $null -ne $SsimuAverage -and $null -ne $Ssimu5th -and $null -ne $SsimuMin) {
                break
            }

            if ($GpuThreads -eq 2) {
                Write-AppLog "FFVship falhou ou não retornou métricas (Exit=$LASTEXITCODE); liberando VRAM do OCR e tentando com --gpu-threads 1..." "WARN"
                try { Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:8765/api/control/unload-vram" -TimeoutSec 2 | Out-Null } catch {}
                Start-Sleep -Seconds 3
            }
        }
    } finally {
        try { (Get-Process -Id $PID).PriorityClass = 'Idle' } catch {}
        if ($MutexAcquired) { try { $GpuMutex.ReleaseMutex() } catch {} }
        $GpuMutex.Dispose()
    }

    if ($OutputText -match '(?s)(-----------SSIMULACRA2-----------.*)') {
        Write-Host "`n$($Matches[1])`n" -ForegroundColor Cyan
    } elseif (-not [string]::IsNullOrWhiteSpace($OutputText)) {
        $OutputText -split "`n" | ForEach-Object { Write-Host $_ -ForegroundColor Cyan }
    }

    if ($null -eq $SsimuAverage -or $null -eq $Ssimu5th -or $null -eq $SsimuMin) {
        Write-AppLog "FFVship falhou após retentativa ao auditar '$($Context.BaseName)'. Encode será preservado como '_Encoded.mkv' (não descartado)." "ERROR"
        return @{
            Approved       = $false
            RejectedBySize = $false
            AuditFailed    = $true
            Ratio          = $Ratio
            OriginalBytes  = $OriginalLength
            NewBytes       = $NewLength
        }
    }

    $QualityApproved = ($SsimuAverage -ge $AppConfig.Rules.MinAverage) -and ($Ssimu5th -ge $AppConfig.Rules.Min5th)

    if ($QualityApproved) {
        Write-AppLog "O arquivo reduziu $Savings% e passou no Padrão Premium. Aprovado!" "SUCCESS"
        Write-AppLog "-> [Métricas] Média: $SsimuAverage | 5th: $Ssimu5th | Min: $SsimuMin" "SUCCESS"
        return @{
            Approved       = $true
            RejectedBySize = $false
            Ratio          = $Ratio
            OriginalBytes  = $OriginalLength
            NewBytes       = $NewLength
            SsimuAvg       = $SsimuAverage
            SsimuMedian    = $SsimuMedian
            Ssimu5th       = $Ssimu5th
            Ssimu95th      = $Ssimu95th
            SsimuMin       = $SsimuMin
            SsimuStdDev    = $SsimuStdDev
        }
    } else {
        Write-AppLog "O arquivo falhou nos critérios de Qualidade Visual. Rejeitado!" "ERROR"
        Write-AppLog "-> [Métricas Obtidas] Média: $SsimuAverage | 5th: $Ssimu5th | Min: $SsimuMin" "WARN"
        return @{
            Approved       = $false
            RejectedBySize = $false
            Ratio          = $Ratio
            OriginalBytes  = $OriginalLength
            NewBytes       = $NewLength
            SsimuAvg       = $SsimuAverage
            SsimuMedian    = $SsimuMedian
            Ssimu5th       = $Ssimu5th
            Ssimu95th      = $Ssimu95th
            SsimuMin       = $SsimuMin
            SsimuStdDev    = $SsimuStdDev
        }
    }
}

# ====================================================================
# 5. ORQUESTRAÇÃO PRINCIPAL (Main Pipeline)
# ====================================================================

Write-AppLog "Iniciando Pipeline de Transcodificação Profissional..." "SUCCESS"
$Prereq        = Test-Prerequisites
$SvtVersion    = Get-SvtAv1Version
$FontCache     = Initialize-FontFileCache
$RootDirPath   = [System.IO.Path]::GetFullPath($TargetDir)
$SkipCachePath = [System.IO.Path]::Combine($RootDirPath, $AppConfig.Paths.SkipCacheFile)
$SkipHistory   = Import-SkipSizeHistory -CacheFilePath $SkipCachePath

# Limpa jobs órfãos de _autoboost_work caso nenhum encode esteja ativo
$ActiveSvt = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'SvtAv1EncApp' -or $_.CommandLine -match 'Auto-Boost-Essential\.py' }
if (-not $ActiveSvt) {
    $DriveRootForClean = [System.IO.Path]::GetPathRoot($RootDirPath)
    $WorkRoots = @([System.IO.Path]::Combine($DriveRootForClean, "_autoboost_work"), [System.IO.Path]::Combine($env:TEMP, "_autoboost_work")) | Select-Object -Unique
    foreach ($Wr in $WorkRoots) {
        if ([System.IO.Directory]::Exists($Wr)) {
            $StaleJobs = @([System.IO.Directory]::EnumerateDirectories($Wr, "job_*"))
            if ($StaleJobs.Count -gt 0) {
                foreach ($JobDir in $StaleJobs) {
                    try { [System.IO.Directory]::Delete($JobDir, $true) } catch {}
                }
                Write-AppLog "Limpeza preventiva: $($StaleJobs.Count) pasta(s) órfã(s) removida(s) de '$Wr'." "INFO"
            }
            try {
                if (([System.IO.Directory]::GetFileSystemEntries($Wr)).Count -eq 0) {
                    [System.IO.Directory]::Delete($Wr)
                }
            } catch {}
        }
    }
}

# Enumeração segura com IgnoreInaccessible para evitar falhas em System Volume Information / pastas protegidas e suportar '：'
$EnumOpts = [System.IO.EnumerationOptions]::new()
$EnumOpts.RecurseSubdirectories = $true
$EnumOpts.IgnoreInaccessible    = $true

$RootDirInfo = [System.IO.DirectoryInfo]::new((ConvertTo-LongPath $RootDirPath))
$TargetFiles = @($RootDirInfo.EnumerateFiles("*", $EnumOpts) |
               Where-Object {
                   $_.FullName -notmatch "\\_autoboost_work\\" -and
                   $_.Extension -match "^\.(mkv|mp4|avi|ts|mov|m4v)$" -and
                   $_.Name -notmatch "_temp|_Encoded|\.autoboost\.bak$" -and
                   ($_.Length -ge $AppConfig.Rules.MinFileSizeToEncode -or $AppConfig.Rules.FixTracksOnOptimizedVideos)
               } |
               Sort-Object -Property DirectoryName, Name)

Write-AppLog "Foram encontrados $($TargetFiles.Count) arquivos candidatos nas pastas e subpastas de '$RootDirPath'." "INFO"

foreach ($File in $TargetFiles) {
    Write-AppLog "============================================================" "INFO"
    Write-AppLog "Analisando ativo: $($File.Name)" "INFO"
    Write-AppLog "Tamanho Original: $([math]::Round($File.Length / 1MB, 2)) MB | Diretório: $($File.Directory.Name)" "INFO"

    $FileKey       = $File.FullName -replace "^\\\\\?\\(?=[A-Za-z]:\\)", ""
    $FileSignature = Get-FileSkipSignature -FileInfo $File -SvtVersion $SvtVersion
    if ($AppConfig.Rules.RememberRejectedBySize -and $SkipHistory.ContainsKey($FileKey) -and $SkipHistory[$FileKey] -eq $FileSignature) {
        Write-AppLog "Arquivo já testado anteriormente e reprovado na Regra dos 80%. Ignorado instantaneamente!" "WARN"
        continue
    }

    $Ctx = New-SafeExecutionContext -File $File
    if ($Ctx.UsingSafeStaging) {
        Write-AppLog "Caminho especial/longo detectado ('：' / Unicode / símbolos). Usando Hardlink ASCII-Safe: $($Ctx.OriginalFile)" "INFO"
    }

    try {
        # ETAPA A: Validação do Codec Atual e Metadados
        $MediaData         = Get-MediaMetadata -FilePath $Ctx.OriginalFile
        $VideoStream       = $MediaData.streams | Where-Object { $_.codec_type -eq "video" -and (-not $_.disposition -or $_.disposition["attached_pic"] -ne 1) } | Select-Object -First 1
        $AudioStreams      = @($MediaData.streams | Where-Object { $_.codec_type -eq "audio" })
        $SubtitleStreams   = @($MediaData.streams | Where-Object { $_.codec_type -eq "subtitle" })
        $AttachmentStreams = @($MediaData.streams | Where-Object { $_.codec_type -eq "attachment" })

        if ($null -eq $VideoStream) {
            Write-AppLog "Nenhuma trilha de vídeo encontrada (apenas anexo/áudio). Arquivo ignorado." "WARN"
            Remove-TemporaryAssets -Context $Ctx
            continue
        }

        $IsAlreadyOptimized = ($VideoStream.codec_name -in $AppConfig.Rules.ValidVideoCodecs)
        $RemuxKey = "remux|$FileKey"

        if ($IsAlreadyOptimized) {
            if ($AppConfig.Rules.FixTracksOnOptimizedVideos -and (Test-NeedsTrackNormalization -MediaData $MediaData -SkipHistory $SkipHistory -RemuxKey $RemuxKey -FileSignature $FileSignature)) {
                Write-AppLog "Vídeo já está em $($VideoStream.codec_name), mas faixas de áudio/legenda serão normalizadas (Modo Remux Rápido CRD)..." "WARN"
                $AudioLayoutPlan = Get-AudioTrackLayoutPlan -AudioStreams $AudioStreams
                $HasAudioTemp    = Invoke-AudioProcessing -Context $Ctx -AudioLayoutPlan $AudioLayoutPlan
                $SubtitlePlan    = Invoke-SubtitleAndFontProcessing -Context $Ctx -SubtitleStreams $SubtitleStreams -AttachmentStreams $AttachmentStreams -HasPortugueseAudio $AudioLayoutPlan.HasPortugueseAudio -FontCache $FontCache
                Invoke-MediaMuxing -Context $Ctx -EncoderVersion $SvtVersion -MediaData $MediaData -AudioLayoutPlan $AudioLayoutPlan -SubtitlePlan $SubtitlePlan -UseOriginalVideo $true -HasAudioTemp $HasAudioTemp

                $FinalDestPath = [System.IO.Path]::Combine($Ctx.Directory, "$($Ctx.BaseName).mkv")
                Move-FileSafely -SourcePath $Ctx.MkvTemp -DestinationPath $FinalDestPath -OriginalToReplace $Ctx.RealOriginalFile
                Remove-TemporaryAssets -Context $Ctx

                $NewInfo = [System.IO.FileInfo]::new((ConvertTo-LongPath $FinalDestPath))
                $SkipHistory["remux|$FinalDestPath"] = Get-FileSkipSignature -FileInfo $NewInfo -SvtVersion $SvtVersion
                Save-SkipSizeHistory -CacheFilePath $SkipCachePath -HistoryMap $SkipHistory
                Write-AppLog "Faixas de áudio, legendas (Signs) e fontes normalizadas com sucesso!" "SUCCESS"
                continue
            } else {
                Write-AppLog "Vídeo já está otimizado ($($VideoStream.codec_name)). Arquivo ignorado." "SUCCESS"
                Remove-TemporaryAssets -Context $Ctx
                continue
            }
        }

        if ($File.Length -lt $AppConfig.Rules.MinFileSizeToEncode) {
            Write-AppLog "Arquivo menor que o limite mínimo ($([math]::Round($AppConfig.Rules.MinFileSizeToEncode / 1MB, 0)) MB). Re-encode ignorado." "INFO"
            Remove-TemporaryAssets -Context $Ctx
            continue
        }

        $ExistingEncodedPath = ConvertTo-LongPath ([System.IO.Path]::Combine($Ctx.Directory, "$($Ctx.BaseName)_Encoded.mkv"))
        if ([System.IO.File]::Exists($ExistingEncodedPath)) {
            Write-AppLog "Já existe '_Encoded.mkv' aguardando inspeção manual para este episódio. Pulando!" "WARN"
            Remove-TemporaryAssets -Context $Ctx
            continue
        }

        if (-not $Prereq.CanEncodeVideo) {
            throw "Re-encode abortado (Fail-Fast): ferramentas ausentes em `$AppConfig.Paths: $($Prereq.MissingEncodeTools -join '; ')"
        }

        $ColorProfile   = Get-VideoColorParams -FilePath $Ctx.OriginalFile -VideoStream $VideoStream
        $RuntimeEncoder = Get-RuntimeEncoderParams -VideoStream $VideoStream -ColorProfile $ColorProfile
        Write-AppLog "Perfil de Cor detectado: $($ColorProfile.Summary)" "INFO"

        $MediaMode        = if ($MediaType -eq 2) { "Filme" } else { "Anime" }
        $Resolution       = "$($VideoStream.width)x$($VideoStream.height)"
        $EncoderParamsStr = "$($RuntimeEncoder.AutoBoostArgs -join ' ') | $($RuntimeEncoder.FinalParams)"
        $EncodeStopwatch  = [System.Diagnostics.Stopwatch]::StartNew()

        # ETAPA B1: Codificação de Vídeo (.ivf)
        Write-AppLog "Encoder alvo: $SvtVersion" "INFO"
        Invoke-VideoEncoding -Context $Ctx -RuntimeEncoder $RuntimeEncoder

        $FastSsimuAvg = $null; $FastSsimuP15 = $null; $FastSsimuMin = $null; $EffectiveCrf = $null
        $FastMetricsPath = ConvertTo-LongPath ([System.IO.Path]::Combine($Ctx.WorkDir, "fast_metrics.txt"))
        if ([System.IO.File]::Exists($FastMetricsPath)) {
            $FastParts = ([System.IO.File]::ReadAllText($FastMetricsPath, [System.Text.Encoding]::UTF8)).Trim().Split(',')
            if ($FastParts.Count -ge 3) {
                $Inv = [cultureinfo]::InvariantCulture
                [double]$FastVal = 0
                if ([double]::TryParse($FastParts[0], [System.Globalization.NumberStyles]::Float, $Inv, [ref]$FastVal)) { $FastSsimuAvg = $FastVal }
                if ([double]::TryParse($FastParts[1], [System.Globalization.NumberStyles]::Float, $Inv, [ref]$FastVal)) { $FastSsimuP15 = $FastVal }
                if ([double]::TryParse($FastParts[2], [System.Globalization.NumberStyles]::Float, $Inv, [ref]$FastVal)) { $FastSsimuMin = $FastVal }
                if ($FastParts.Count -ge 4 -and -not [string]::IsNullOrWhiteSpace($FastParts[3])) {
                    $EffectiveCrf = $FastParts[3].Trim()
                }
            }
        }
        $LogBaseTarget = if ($EffectiveCrf) { "$($RuntimeEncoder.BaseTarget) -> crf=$EffectiveCrf" } else { $RuntimeEncoder.BaseTarget }

        # DISJUNTOR ESTÁGIO 1 (Early Video Size Bailout)
        if ($AppConfig.Rules.EarlyVideoSizeAbort) {
            $IvfLength = ([System.IO.FileInfo]::new((ConvertTo-LongPath $Ctx.VideoTemp))).Length
            $VideoOnlyRatio = $IvfLength / $File.Length
            if ($VideoOnlyRatio -gt $AppConfig.Rules.MaxTargetSizeRatio) {
                $VideoPct = [math]::Round($VideoOnlyRatio * 100, 2)
                Write-AppLog "Disjuntor Rápido: Só o vídeo .ivf já atingiu $VideoPct% do arquivo original (Limite: $($AppConfig.Rules.MaxTargetSizeRatio * 100)%). Abortando áudio, mux e FFVship!" "WARN"
                $EncodeStopwatch.Stop()
                Write-EncodeMetricsLog -LogPath $AppConfig.Paths.MetricsLogFile -FileName $File.Name -Folder $File.Directory.Name `
                    -MediaMode $MediaMode -Resolution $Resolution -SourceCodec $VideoStream.codec_name `
                    -ColorProfile $ColorProfile.Summary -BaseTarget $LogBaseTarget -EncoderParams $EncoderParamsStr `
                    -Status "Rejected_EarlyVideoSize" -OriginalBytes $File.Length -NewBytes $IvfLength `
                    -Ratio $VideoOnlyRatio -ElapsedMin $EncodeStopwatch.Elapsed.TotalMinutes `
                    -FastSsimuAvg $FastSsimuAvg -FastSsimuP15 $FastSsimuP15 -FastSsimuMin $FastSsimuMin
                Remove-TemporaryAssets -Context $Ctx
                $SkipHistory[$FileKey] = $FileSignature
                Save-SkipSizeHistory -CacheFilePath $SkipCachePath -HistoryMap $SkipHistory
                continue
            }
        }

        # ETAPA B2: Otimização de Áudio, Legendas (Single-Pass) e Fontes (Cache O(1))
        $AudioLayoutPlan = Get-AudioTrackLayoutPlan -AudioStreams $AudioStreams
        $HasAudioTemp    = Invoke-AudioProcessing -Context $Ctx -AudioLayoutPlan $AudioLayoutPlan

        $SubtitlePlan = Invoke-SubtitleAndFontProcessing -Context $Ctx -SubtitleStreams $SubtitleStreams -AttachmentStreams $AttachmentStreams -HasPortugueseAudio $AudioLayoutPlan.HasPortugueseAudio -FontCache $FontCache

        # ETAPA C: Empacotamento Final (Padrão CRD)
        Invoke-MediaMuxing -Context $Ctx -EncoderVersion $SvtVersion -MediaData $MediaData -AudioLayoutPlan $AudioLayoutPlan -SubtitlePlan $SubtitlePlan -RuntimeEncoder $RuntimeEncoder -HasAudioTemp $HasAudioTemp

        # ETAPA D: Limpeza prévia de intermediários antes da auditoria visual (poupa disco)
        Remove-TemporaryAssets -Context $Ctx -KeepMkvTemp $true

        # ETAPA E: Auditoria Final (Checa Tamanho em 0,001s ANTES de rodar o FFVship!)
        $AuditResult = Measure-QualityAndSize -Context $Ctx

        if ($AuditResult.Approved) {
            $FinalDestPath   = [System.IO.Path]::Combine($Ctx.Directory, "$($Ctx.BaseName).mkv")
            $EncodedDestPath = [System.IO.Path]::Combine($Ctx.Directory, "$($Ctx.BaseName)_Encoded.mkv")
            try {
                Write-AppLog "Aprovado! Substituindo arquivo original pelo novo encode..." "SUCCESS"
                Move-FileSafely -SourcePath $Ctx.MkvTemp -DestinationPath $FinalDestPath -OriginalToReplace $Ctx.RealOriginalFile
                $AuditStatus = "Approved"
            } catch [System.IO.IOException] {
                Write-AppLog "Original bloqueado por outro app (Jellyfin/qBittorrent): $_ — salvando novo encode em '_Encoded.mkv'." "WARN"
                Move-FileSafely -SourcePath $Ctx.MkvTemp -DestinationPath $EncodedDestPath
                $AuditStatus = "Approved_LockedOriginal"
            }
            Remove-TemporaryAssets -Context $Ctx
        } elseif ($AuditResult.RejectedBySize) {
            Write-AppLog "Arquivo rejeitado por TAMANHO ($([math]::Round($AuditResult.Ratio * 100, 2))%). Apagando encode e registrando no cache de ignorados..." "WARN"
            Remove-TemporaryAssets -Context $Ctx
            $SkipHistory[$FileKey] = $FileSignature
            Save-SkipSizeHistory -CacheFilePath $SkipCachePath -HistoryMap $SkipHistory
            $AuditStatus = "Rejected_Size"
        } else {
            $FailReason = if ($AuditResult.AuditFailed) { "FALHA NA AUDITORIA GPU" } else { "QUALIDADE" }
            Write-AppLog "Arquivo preservado como '_Encoded.mkv' para inspeção manual ($FailReason)." "WARN"
            $EncodedDestPath = [System.IO.Path]::Combine($Ctx.Directory, "$($Ctx.BaseName)_Encoded.mkv")
            Move-FileSafely -SourcePath $Ctx.MkvTemp -DestinationPath $EncodedDestPath
            Remove-TemporaryAssets -Context $Ctx
            $AuditStatus = if ($AuditResult.AuditFailed) { "Audit_Failed_Saved" } else { "Rejected_Quality" }
        }

        $EncodeStopwatch.Stop()
        Write-EncodeMetricsLog -LogPath $AppConfig.Paths.MetricsLogFile -FileName $File.Name -Folder $File.Directory.Name `
            -MediaMode $MediaMode -Resolution $Resolution -SourceCodec $VideoStream.codec_name `
            -ColorProfile $ColorProfile.Summary -BaseTarget $LogBaseTarget -EncoderParams $EncoderParamsStr `
            -Status $AuditStatus -OriginalBytes $AuditResult.OriginalBytes -NewBytes $AuditResult.NewBytes `
            -Ratio $AuditResult.Ratio -ElapsedMin $EncodeStopwatch.Elapsed.TotalMinutes `
            -FastSsimuAvg $FastSsimuAvg -FastSsimuP15 $FastSsimuP15 -FastSsimuMin $FastSsimuMin `
            -SsimuAvg $AuditResult.SsimuAvg -SsimuMedian $AuditResult.SsimuMedian -Ssimu5th $AuditResult.Ssimu5th `
            -Ssimu95th $AuditResult.Ssimu95th -SsimuMin $AuditResult.SsimuMin -SsimuStdDev $AuditResult.SsimuStdDev

    } catch {
        Write-AppLog "Falha crítica no processamento de $($Ctx.BaseName): $_" "ERROR"
        # O bloco Catch garante que o erro num episódio não trave a temporada inteira
    } finally {
        Remove-TemporaryAssets -Context $Ctx
    }
}

Write-AppLog "Pipeline finalizado para todos os ativos na árvore de pastas." "SUCCESS"
} finally {
    try { (Get-Process -Id $PID).PriorityClass = $OriginalProcessPriority } catch {}
}