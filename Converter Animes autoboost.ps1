<#
.SYNOPSIS
    Pipeline automatizado e inteligente para processamento e otimização de mídias (Anime/Séries).
.DESCRIPTION
    Este script orquestra a conversão de vídeos para AV1 via Auto-Boost-Essential, 
    analisa e transcodifica múltiplas faixas de áudio inteligentemente via FFmpeg,
    empacota os resultados usando MKVToolNix e realiza auditoria de qualidade (SSIMULACRA2)
    e eficiência de compressão (Regra dos 80%) antes de consolidar os arquivos.
.NOTES
    Autor: Ednan Costa
    Data: Março 2026
    Padrões Aplicados: Clean Code, DRY (Don't Repeat Yourself), SRP (Single Responsibility Principle)
#>

# ====================================================================
# 1. CONFIGURAÇÕES GLOBAIS DO AMBIENTE (Application Configuration)
# ====================================================================

# Reduz a prioridade do processo pai e dos filhos para não travar o uso do PC
[System.Diagnostics.Process]::GetCurrentProcess().PriorityClass = [System.Diagnostics.ProcessPriorityClass]::Idle

# Dicionário central de configurações com caminhos dinâmicos
$AppConfig = @{
    Paths = @{
        # Caminho dinâmico para a pasta do Usuário (C:\Users\Nome)
        PythonExe       = "$HOME\PythonEnv\AutoBoost\Scripts\python.exe"
        SvtAv1Exe       = "$HOME\SVT-AV1-Essential\Bin\Release\SvtAv1EncApp.exe"
        
        # Caminho dinâmico para Program Files (C:\Program Files)
        FfvshipExe      = "$($Env:ProgramFiles)\VapourSynth\plugins\FFVship.exe"
        
        # Mantenha este caminho conforme sua necessidade local
        AutoBoostScript = "C:\Path\Auto-Boost-Essential.py"
    }
    Rules = @{
        ValidVideoCodecs    = @("av1", "hevc", "vp9")
        MaxTargetSizeRatio  = 0.80 # O arquivo final não pode ultrapassar 80% do original
    }
    Encoder = @{
        AutoBoostArgs = @("--quality", "high", "--aggressive", "--ssimu2", "gpu")
        FinalParams   = "--scm 0 --auto-tiling 1 --film-grain 4 --color-primaries bt709 --transfer-characteristics bt709 --matrix-coefficients bt709"
    }
}

# ====================================================================
# 2. FUNÇÕES DE SUPORTE E INFRAESTRUTURA (Helpers)
# ====================================================================

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

function Get-SvtAv1Version {
    <#
    .SYNOPSIS
        Recupera a versão real do encoder SVT-AV1 para embutir nos metadados.
    #>
    if (Test-Path -LiteralPath $AppConfig.Paths.SvtAv1Exe) { 
        return (& $AppConfig.Paths.SvtAv1Exe --version 2>&1) | Select-Object -First 1 
    }
    return "SVT-AV1 (Desconhecido)"
}

function Remove-TemporaryAssets {
    <#
    .SYNOPSIS
        Limpa os arquivos temporários gerados durante o processamento de um episódio específico.
    #>
    param ([hashtable]$Context)
    if (Test-Path -LiteralPath $Context.VideoTemp) { Remove-Item -LiteralPath $Context.VideoTemp -Force }
    if (Test-Path -LiteralPath $Context.AudioTemp) { Remove-Item -LiteralPath $Context.AudioTemp -Force }
    if (Test-Path -LiteralPath $Context.TagsXml)   { Remove-Item -LiteralPath $Context.TagsXml -Force }
    if (Test-Path -LiteralPath $Context.WorkDir)   { Remove-Item -LiteralPath $Context.WorkDir -Recurse -Force }
}

# ====================================================================
# 3. FUNÇÕES DE DOMÍNIO (Lógica Central do Negócio)
# ====================================================================

function Get-MediaMetadata {
    <#
    .SYNOPSIS
        Extrai metadados completos do arquivo via FFprobe e converte para um objeto de fácil leitura.
    #>
    param ([string]$FilePath)
    
    $FfprobeCmd = "ffprobe -v quiet -print_format json -show_streams -show_format `"$FilePath`""
    return Invoke-Expression $FfprobeCmd | ConvertFrom-Json
}

function Get-AudioOptimizationPlan {
    <#
    .SYNOPSIS
        Analisa uma faixa de áudio e determina a melhor estratégia de transcodificação
        baseada na quantidade de canais e no bitrate atual.
    #>
    param ($AudioStream)
    
    $Codec = $AudioStream.codec_name
    $Channels = if ($AudioStream.channels) { [int]$AudioStream.channels } else { 2 }
    $CurrentBitrate = if ($AudioStream.bit_rate) { [math]::Round([int]$AudioStream.bit_rate / 1000) } else { 0 }

    # Configuração padrão de segurança
    $Plan = @{ Action = "Encode"; TargetBitrate = "96k" }

    if ($Codec -eq "opus") {
        $Plan.Action = "Copy"
    } elseif ($Channels -gt 2) {
        # Surround (5.1+)
        if ($CurrentBitrate -gt 0 -and $CurrentBitrate -le 256) { $Plan.Action = "Copy" } else { $Plan.TargetBitrate = "256k" }
    } elseif ($Channels -eq 1) {
        # Mono
        if ($CurrentBitrate -gt 0 -and $CurrentBitrate -le 64) { $Plan.Action = "Copy" } else { $Plan.TargetBitrate = "64k" }
    } else {
        # Estéreo
        if ($CurrentBitrate -gt 0 -and $CurrentBitrate -le 96) { $Plan.Action = "Copy" } else { $Plan.TargetBitrate = "96k" }
    }

    return $Plan
}

# ====================================================================
# 4. FUNÇÕES DE EXECUÇÃO (Wrappers de Ferramentas Externas)
# ====================================================================

function Invoke-VideoEncoding {
    <#
    .SYNOPSIS
        Executa o script Python do Auto-Boost para processar a faixa de vídeo.
    #>
    param ([hashtable]$Context)
    
    Write-AppLog "Iniciando codificação de vídeo (Auto-Boost)..." "WARN"
    $PythonArgs = @("-i", $Context.OriginalFile) + $AppConfig.Encoder.AutoBoostArgs + @("--final-params", $AppConfig.Encoder.FinalParams)
    
    & $AppConfig.Paths.PythonExe $AppConfig.Paths.AutoBoostScript @PythonArgs
    
    if (-not (Test-Path -LiteralPath $Context.VideoTemp)) { 
        throw "O arquivo final de vídeo (.ivf) não foi gerado. O processo falhou ou foi abortado." 
    }
}

function Invoke-AudioProcessing {
    <#
    .SYNOPSIS
        Aplica a lógica de otimização para cada trilha de áudio usando FFmpeg.
    #>
    param ([hashtable]$Context, $AudioStreams)
    
    Write-AppLog "Processando trilhas de áudio dinamicamente..." "INFO"
    $FfmpegArgs = @("-v", "error", "-y", "-i", $Context.OriginalFile)
    
    $Index = 0
    foreach ($Stream in $AudioStreams) {
        $Plan = Get-AudioOptimizationPlan -AudioStream $Stream
        
        $FfmpegArgs += "-map"
        $FfmpegArgs += "0:a:$Index"

        if ($Plan.Action -eq "Copy") {
            Write-AppLog "-> Trilha $Index [$($Stream.codec_name)]: Cópia direta." "SUCCESS"
            $FfmpegArgs += "-c:a:$Index", "copy"
        } else {
            Write-AppLog "-> Trilha $Index [$($Stream.codec_name) / $($Stream.channels)ch]: Convertendo para Opus $($Plan.TargetBitrate)." "WARN"
            $FfmpegArgs += "-c:a:$Index", "libopus", "-b:a:$Index", $Plan.TargetBitrate
        }
        $Index++
    }
    
    $FfmpegArgs += "-vbr", "on", $Context.AudioTemp
    & ffmpeg @FfmpegArgs
}

function Invoke-MediaMuxing {
    <#
    .SYNOPSIS
        Gera o arquivo XML de metadados e usa o MKVMerge para empacotar Vídeo, Áudio e Legendas.
    #>
    param ([hashtable]$Context, [string]$EncoderVersion)
    
    Write-AppLog "Gerando metadados XML seguros..." "INFO"
    $EncoderSettings = "Auto-Boost: $($AppConfig.Encoder.AutoBoostArgs -join ' ') | SVT-AV1: $($AppConfig.Encoder.FinalParams)"
    
    $XmlContent = @"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE Tags SYSTEM "matroskatags.dtd">
<Tags><Tag><Targets><TargetTypeValue>50</TargetTypeValue></Targets>
<Simple><Name>ENCODER</Name><String>$EncoderVersion</String></Simple>
<Simple><Name>ENCODER_SETTINGS</Name><String>$EncoderSettings</String></Simple>
</Tag></Tags>
"@
    $XmlContent | Out-File -LiteralPath $Context.TagsXml -Encoding utf8

    Write-AppLog "Empacotando vídeo e áudio via mkvmerge..." "WARN"
    $MkvArgs = @("-o", $Context.MkvTemp, "--tags", "0:$($Context.TagsXml)", $Context.VideoTemp, $Context.AudioTemp, "--no-video", "--no-audio", $Context.OriginalFile)
    
    & mkvmerge @MkvArgs
    
    if ($LASTEXITCODE -ne 0) { throw "Erro fatal durante a multiplexação (mkvmerge)." }
}

function Measure-QualityAndSize {
    <#
    .SYNOPSIS
        Calcula a métrica SSIMULACRA2, extrai os valores chave e avalia se o 
        arquivo comprimido atende à regra de tamanho e qualidade visual.
    #>
    param ([hashtable]$Context)

    Write-AppLog "Calculando métrica SSIMULACRA2 final (Comparando com o Original)..." "WARN"

    # Executa o FFVship e guarda a saída de texto
    $ProcessOutput = & $AppConfig.Paths.FfvshipExe --source $Context.OriginalFile --encoded $Context.MkvTemp -m SSIMULACRA2
    $OutputText = $ProcessOutput -join "`n"

    # Imprime a janela de métricas na tela para você acompanhar
    if ($OutputText -match '(?s)(-----------SSIMULACRA2-----------.*)') {
        Write-Host "`n$($Matches[1])`n" -ForegroundColor Cyan
    } else {
        $ProcessOutput | ForEach-Object { Write-Host $_ -ForegroundColor Cyan }
    }

    # === EXTRAÇÃO MATEMÁTICA DO SSIMULACRA2 ===
    # AQUI ESTÃO AS VARIÁVEIS SENDO DEFINIDAS!
    $SsimuAverage = 0
    $Ssimu5th = 0
    $SsimuMin = 0

    if ($OutputText -match 'Average\s*:\s*([\d.]+)') {
        $SsimuAverage = [double]::Parse($Matches[1], [cultureinfo]::InvariantCulture)
    }
    if ($OutputText -match '5th percentile\s*:\s*([\d.]+)') {
        $Ssimu5th = [double]::Parse($Matches[1], [cultureinfo]::InvariantCulture)
    }
    if ($OutputText -match 'Minimum\s*:\s*([\d.]+)') {
        $SsimuMin = [double]::Parse($Matches[1], [cultureinfo]::InvariantCulture)
    }

    # Trava de segurança caso o regex falhe ao ler o texto do FFVship
    if ($SsimuAverage -eq 0 -or $Ssimu5th -eq 0 -or $SsimuMin -eq 0) {
        throw "Erro: Não foi possível extrair todas as notas SSIMULACRA2 (Average, 5th, Minimum) do console."
    }

    # === CÁLCULO DE TAMANHO (Regra dos 80%) ===
    $OriginalFileInfo = Get-Item -LiteralPath $Context.OriginalFile
    $NewFileInfo = Get-Item -LiteralPath $Context.MkvTemp

    if ($OriginalFileInfo.Length -eq 0) { 
        throw "Arquivo original está com 0 bytes! Impossível calcular a compressão." 
    }

    $Ratio = $NewFileInfo.Length / $OriginalFileInfo.Length
    $PercentOriginal = [math]::Round($Ratio * 100, 2)
    $Savings = 100 - $PercentOriginal

    Write-AppLog "Tamanho Original: $([math]::Round($OriginalFileInfo.Length / 1MB, 2)) MB" "INFO"
    Write-AppLog "Tamanho Novo: $([math]::Round($NewFileInfo.Length / 1MB, 2)) MB ($PercentOriginal% do original)" "INFO"

    # === CÁLCULO FINAL DE APROVAÇÃO (Tamanho + Qualidade) ===
    # Metas: Média >= 80.0 | 5th Percentile >= 75.0 | Minimum >= 55.0
    
    $QualityApproved = ($SsimuAverage -ge 80.0) -and ($Ssimu5th -ge 75.0) -and ($SsimuMin -ge 55.0)
    $SizeApproved = ($Ratio -le $AppConfig.Rules.MaxTargetSizeRatio)

    if ($QualityApproved -and $SizeApproved) {
        Write-AppLog "O arquivo reduziu $Savings% e passou na Malha Fina Visual. Aprovado!" "SUCCESS"
        Write-AppLog "-> [Métricas] Média: $SsimuAverage | 5th: $Ssimu5th | Min: $SsimuMin" "SUCCESS"
        return $true
    } else {
        Write-AppLog "O arquivo falhou nos critérios de arquivamento. Rejeitado!" "ERROR"
        
        if (-not $SizeApproved) {
            Write-AppLog "-> Motivo: Ficou muito grande ($PercentOriginal% do original. Limite: $($AppConfig.Rules.MaxTargetSizeRatio * 100)%)." "WARN"
        }
        if (-not $QualityApproved) {
            Write-AppLog "-> Motivo: Qualidade visual abaixo do padrão exigido." "WARN"
            Write-AppLog "-> [Métricas Obtidas] Média: $SsimuAverage | 5th: $Ssimu5th | Min: $SsimuMin" "WARN"
        }
        return $false
    }
}

# ====================================================================
# 5. ORQUESTRAÇÃO PRINCIPAL (Main Pipeline)
# ====================================================================

& {
    Write-AppLog "Iniciando Pipeline de Transcodificação Profissional..." "SUCCESS"
    $SvtVersion = Get-SvtAv1Version

    # Busca apenas arquivos originais (ignora temporários e rejeitados)
    $TargetFiles = Get-ChildItem -Filter "*.mkv" | Where-Object { $_.Name -notmatch "_temp" -and $_.Name -notmatch "_Encoded" }

    foreach ($File in $TargetFiles) {
        Write-AppLog "============================================================" "INFO"
        Write-AppLog "Analisando ativo: $($File.Name)" "INFO"

        # Dicionário de Contexto (Guarda todos os caminhos para não poluir o código com variáveis)
        $Ctx = @{
            OriginalFile = $File.FullName
            BaseName     = $File.BaseName
            Directory    = $File.DirectoryName
            VideoTemp    = Join-Path $File.DirectoryName "$($File.BaseName).ivf"
            AudioTemp    = Join-Path $File.DirectoryName "$($File.BaseName)_audio.mka"
            MkvTemp      = Join-Path $File.DirectoryName "$($File.BaseName)_temp.mkv"
            TagsXml      = Join-Path $File.DirectoryName "tags_temp.xml"
            WorkDir      = Join-Path $File.DirectoryName $File.BaseName
        }

        # ETAPA A: Validação do Codec Atual
        $MediaData = Get-MediaMetadata -FilePath $Ctx.OriginalFile
        $VideoStream = $MediaData.streams | Where-Object { $_.codec_type -eq "video" -and $_.attached_pic -ne 1 } | Select-Object -First 1
        $AudioStreams = $MediaData.streams | Where-Object { $_.codec_type -eq "audio" }

        if ($VideoStream.codec_name -in $AppConfig.Rules.ValidVideoCodecs) {
            Write-AppLog "Vídeo já está otimizado ($($VideoStream.codec_name)). Arquivo ignorado." "SUCCESS"
            continue 
        }

        try {
            # ETAPA B: Otimização de Vídeo e Áudio
            Write-AppLog "Encoder alvo: $SvtVersion" "INFO"
            Invoke-VideoEncoding -Context $Ctx
            Invoke-AudioProcessing -Context $Ctx -AudioStreams $AudioStreams
            
            # ETAPA C: Empacotamento Final
            Invoke-MediaMuxing -Context $Ctx -EncoderVersion $SvtVersion

            # ETAPA D: Limpeza de Cache de Renderização (Limpa antes de avaliar para poupar disco)
            Remove-TemporaryAssets -Context $Ctx

            # ETAPA E: Auditoria Final (Qualidade e Regra dos 80%)
            $IsApproved = Measure-QualityAndSize -Context $Ctx

            if ($IsApproved) {
                Write-AppLog "Aprovado! Substituindo arquivo original pelo novo encode..." "SUCCESS"
                Remove-Item -LiteralPath $Ctx.OriginalFile -Force
                Rename-Item -LiteralPath $Ctx.MkvTemp -NewName "$($Ctx.BaseName).mkv"
            } else {
                # Se não for aprovado, renomeia para _Encoded e não apaga o original
                Rename-Item -LiteralPath $Ctx.MkvTemp -NewName "$($Ctx.BaseName)_Encoded.mkv"
                Write-AppLog "Arquivos originais e encodados mantidos para sua avaliação manual." "WARN"
            }

        } catch {
            Write-AppLog "Falha crítica no processamento de $($Ctx.BaseName): $_" "ERROR"
            # O bloco Catch garante que o erro num episódio não trave a temporada inteira
        }
    }
    
    Write-AppLog "Pipeline finalizado para todos os ativos na pasta." "SUCCESS"
}