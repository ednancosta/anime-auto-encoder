# 🎬 Anime & Movie Auto-Encoder Pipeline (AV1)

Pipeline automatizado em **PowerShell** para otimização e compressão de **Animes/Séries** e **Filmes (Live-Action)** em **AV1**, combinando descoberta automática de CRF por alvo visual (`--target-ssimu2`), cálculo de *zones* por cena via **Auto-Boost-Essential**, transcodificação inteligente de áudio para **Opus**, padronização de legendas PT-BR (Placas/Forçadas) e auditoria final acelerada por GPU (**SSIMULACRA2** via `FFVship`).

---

## ✨ Principais Funcionalidades (v2.3.0)

* **Alvo de Qualidade Automático (`--target-ssimu2 81.5`):** Funciona no espírito do `ab-av1`, mas avaliando **100% do vídeo** no `fast_pass` sem sorteio de trechos e **sem passes extras** — ajusta o CRF base automaticamente (protegendo média e 15º percentil) antes de distribuir as *zones* cena a cena.
* **Modos Dedicados (`-MediaType 1` e `-MediaType 2`):**
  * `-MediaType 1` (**Anime — Padrão**): base `CRF 29` (1080p) / `CRF 31` (4K) com alvo `SSIMULACRA2 81.5` (corte final `Média >= 80.0` e `5th >= 72.0`), `--film-grain 4`, extração automática de placas `.ass` (`Signs`) e áudio `por -> jpn -> eng` (Estéreo 96k).
  * `-MediaType 2` (**Filmes / Live-Action**): base `CRF 24` (1080p) / `CRF 28` (4K) com alvo `SSIMULACRA2 81.5`, re-encode habilitado também para **HEVC** (`ValidVideoCodecs = av1, vp9`), `--film-grain 8`, `--luminance-qp-bias 15`, detecção automática de **HDR10** (CICP, Mastering Display, MaxCLL/MaxFALL + `--variance-boost-curve 3`), guarda contra Dolby Vision Perfil 5 sem base HDR10, áudio `por -> eng` (Estéreo 128k / 5.1 256k / 7.1 384k), auditoria SSIMULACRA2 em **todos os frames** e auditoria **CVVDP (`standard_hdr_pq`, JOD ≥ 9.5)** para aprovar vídeos HDR PQ.
* **Regra Enxuta de Legendas PT-BR:**
  * Se houver áudio em **Português**, a faixa de **Placas/Forçada (`Signs`/`Forced`)** vira `Default=yes` + `Forced=yes` (extraindo placas automaticamente do `.ass` completo em animes se necessário).
  * Se o áudio for estrangeiro (ex.: Japonês/Inglês), a **legenda completa em Português** vira `Default=yes`.
  * Todos os outros idiomas de legenda são mantidos intactos no `.mkv` apenas como backup.
* **Isolamento Unicode & Caminhos Longos:** Cria *hardlink* instantâneo em pasta ASCII temporária (`_autoboost_work`) quando o arquivo tem caracteres como `：`, colchetes ou caminho longo (> 190 chars).
* **Controle de Eficiência & Segurança:**
  * **Regra dos 80% (com Disjuntor Rápido no `.ivf`):** Aborta e registra no cache `.autoboost_skip.json` se o arquivo não economizar pelo menos 20% de espaço.
  * **Substituição Atômica (`Move-FileSafely`):** Nunca apaga o original antes de garantir o novo arquivo no destino (restaura `.autoboost.bak` em caso de falha).
  * **Log de Calibração (`autoboost_metrics.csv`):** Salva tamanho antes/depois, SSIMULACRA2 do `fast_pass`, distribuição final (`Avg`, `Median`, `5th`, `95th`, `Min`, `StdDev`), CRF efetivo e tempo gasto.

---

## 🛠️ Pré-requisitos e Forks Utilizados

1. **Auto-Boost-Essential (Fork ≥ `v2.1-stage-resume` com `--target-ssimu2` e retomada por etapa):** [ednancosta/auto-boost-algorithm](https://github.com/ednancosta/auto-boost-algorithm)
2. **SVT-AV1-Essential (Motor com suporte a `--zones`):** [ednancosta/SVT-AV1-Essential](https://github.com/ednancosta/SVT-AV1-Essential)
3. **Python 3.12+** (com `vsjetpack`, `rich`, `vapoursynth` e `ffms2`)
4. **FFVship (GPU CUDA / CPU):** [Vship](https://codeberg.org/Line-fr/Vship/releases)
5. **FFmpeg & FFprobe** (no `PATH` do Windows)
6. **MKVToolNix (`mkvmerge.exe`)**

---

## 🚀 Como Usar

Abra o PowerShell na pasta desejada e execute:

```powershell
# Anime / Séries de Animação (Padrão: -MediaType 1)
& "C:\Caminho\Do\Autoboost script.ps1" -MediaType 1 -TargetDir "D:\Animes"

# Filmes / Séries Live-Action (HDR10 e Surround automáticos)
& "C:\Caminho\Do\Autoboost script.ps1" -MediaType 2 -TargetDir "D:\Filmes"

# Opcional: corrigir apenas faixas de áudio/legendas/fontes em vídeos já em AV1/HEVC/VP9
& "C:\Caminho\Do\Autoboost script.ps1" -FixTracksOnOptimizedVideos -TargetDir "D:\Animes"
```

Antes de rodar pela primeira vez, ajuste o bloco `$AppConfig.Paths` no topo do [`Autoboost script.ps1`](./Autoboost%20script.ps1) para apontar para os executáveis da sua máquina (`FFVship.exe`, `python.exe`, `Auto-Boost-Essential.py`, `SvtAv1EncApp.exe` e `mkvmerge.exe`).

---

## 📋 Changelog

### v2.3.0
* **CRF inicial calibrado em Animes (`29` 1080p / `31` 4K):** Reduz a distância do *fast pass* até o CRF final (calibrado a partir dos 51 encodes de `autoboost_metrics.csv`), em conjunto com o fork `Auto-Boost-Essential` corrigido (`projected_avg - 0.3`, piso `p15 >= target - 4.5` e `--crf` efetivo repassado ao `final_pass`).
* **Metadados & `FFVship` otimizados:** A tag `ENCODER_SETTINGS` do MKV agora registra o `--crf` efetivo calculado pelo Auto-Boost, e o índice `source.ffindex` é reaproveitado via `--source-index` pelo `FFVship` para evitar dupla indexação do MKV original.
* **Limpeza e estabilidade:** Classificação unificada de trilhas `[AD]`/`CC`/`Signs` (`Get-TrackFlags`), correção da contagem na limpeza preventiva de `_autoboost_work` e migração completa de colunas antigas em `autoboost_metrics.csv`.

### v2.2.0
* **Retomada segura entre etapas (`--resume`):** Interrupções (`Ctrl+C` ou desligamento) preservam estágios concluídos (`fast_pass`, métricas e cálculo de `zones`), usando pasta `job_<hash>` estável por arquivo (`caminho|tamanho`) e chave `resume_key.txt` (invalida automaticamente se o encoder ou parâmetros mudarem). Qualquer passe interrompido no meio recomeça do frame 0 sem emenda de `.ivf`, evitando vídeo picotado e áudio dessincronizado; trabalhos retomáveis expiram após 14 dias.
* **Filmes (`FfvshipEvery 1`):** Auditoria SSIMULACRA2 em `-MediaType 2` passa a medir todos os frames (em vez de `--every 3`), tornando o 5º percentil (`Min5th`) mais confiável com custo marginal na RTX 5060 Ti.

### v2.1.0
* **Anime (`Min5th 72.0`):** Elevado o corte de aprovação do 5º percentil de `68.0` para `72.0` (limiar visual de transparência; reprovados são preservados em `_Encoded.mkv` sem sobrescrever o original).
* **Auditoria HDR PQ por CVVDP:** Filmes HDR (`smpte2084`) agora são aprovados por **CVVDP JOD ≥ 9.5** via `FFVship` com `--displayModel standard_hdr_pq` e `--gpu-threads 1` (SSIMULACRA2 segue registrado como referência e ainda guia o Auto-Boost).
* **Filmes HEVC liberados:** No modo `-MediaType 2`, `ValidVideoCodecs` passa a `@("av1", "vp9")`, permitindo re-encodar filmes 4K HDR em HEVC com proteção da regra dos 80%.
* **Proteção Dolby Vision Perfil 5:** Arquivos DOVI sem camada base HDR10 (`dv_bl_signal_compatibility_id == 0`) são ignorados automaticamente para evitar inversão/distorção de cores.
* **Métricas CSV (`CvvdpJod`):** Adicionada a coluna `CvvdpJod` em `autoboost_metrics.csv`, com migração automática do cabeçalho em logs antigos antes do `Export-Csv -Append`.
* **Calibração `--luminance-qp-bias` (Animes):** Teste A/B nas cenas mais escuras de `S01E12` mostrou que `CRF 33 + lqb 20` (`4.75 MB`, média escura `88.26`, 5th `75.07`) não superou `CRF 32 + lqb 10` (`4.86 MB`, média escura `88.43`, 5th `75.33`), mantendo o padrão `10` do encoder Neko.

### v2.0.1
* Corrigido o binding de parâmetros no topo de [`Autoboost script.ps1`](./Autoboost%20script.ps1) (removido wrapper `&{...}`), fazendo `-TargetDir`, `-MediaType` e `-FixTracksOnOptimizedVideos` funcionarem via linha de comando.
* Calibrado o CRF inicial de Anime (`-MediaType 1`) para **`CRF 25` (1080p)** / **`CRF 28` (4K)** em conjunto com a inclinação assimétrica do `--target-ssimu2 81.5` (`1.5` p/ baixar, `1.25` p/ subir, trava `[-6.0, +8.0]`).

### v2.0.0
* Renomeado `Converter Animes autoboost.ps1` para `Autoboost script.ps1`.
* Adicionado suporte nativo a **Filmes / Live-Action (`-MediaType 2`)**, incluindo extração automática de metadados HDR10 (MDCV, MaxCLL/FALL), curva PQ e áudio Opus 5.1/7.1.
* Integrado `--target-ssimu2 81.5` ao fork `Auto-Boost-Essential` para descoberta dinâmica de CRF sem passes extras.
* Simplificadas as regras de idiomas e legendas: foco em Português (Placas/Forçada com áudio PT-BR; completa com áudio estrangeiro), preservando demais legendas como backup.
* Adicionado log consolidado `autoboost_metrics.csv` com notas do `fast_pass`, métricas finais de SSIMULACRA2 e CRF efetivo.
* Adicionados staging Unicode via Hardlink Win32, cache O(1) de fontes, correção de legendas PGS/VobSub (`.mks`) e preservação de DAR anamórfico.

### v1.0.0
* Release inicial com pipeline AV1 para animes usando Auto-Boost-Essential e regra dos 80%.
