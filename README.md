# 🎬 Anime Auto-Encoder Pipeline (AV1)

Este é um pipeline automatizado construído em **PowerShell** para otimização e compressão de animes. O script orquestra a conversão de vídeos para o formato AV1 de altíssima eficiência, aplicando transcodificação de áudio inteligente e auditoria de qualidade rigorosa (SSIMULACRA2) a cada episódio.

## 🚀 Principais Funcionalidades
* **Auto-Boost Integrado:** Variação dinâmica de CRF baseada na complexidade de cada cena, garantindo bits extras onde importa e economia em cenas estáticas.
* **Áudio Adaptativo:** Transcodifica canais Mono (64k), Estéreo (96k) e Surround (256k) usando o codec Opus de forma inteligente via FFmpeg.
* **Auditoria de Qualidade:** Compara o arquivo codificado com o original e calcula a pontuação matemática de distorção usando métricas de percepção visual.
* **Controle de Eficiência (Regra dos 80%):** Apenas substitui o vídeo original se o encode gerar pelo menos 20% de economia de espaço em disco.
* **Zero Gargalo (Idle Priority):** Execução em background (`Idle`), permitindo o uso normal do PC (ou até jogos leves) durante as horas de codificação.

---

## ⚙️ A Mágica por trás do Auto-Boost
Integrado ao script, o processamento de vídeo funciona em duas etapas principais para garantir uma consistência visual excepcional sem quebrar o pipeline:
1.  **Fast-Pass:** Executa um passe rápido no encoder, encontra mudanças de cena baseadas em keyframes e calcula as métricas de qualidade prévias (SSIMULACRA2).
2.  **Final-Pass:** Ajusta automaticamente o CRF das zonas específicas, combinando a alocação dinâmica com a injeção segura de grão (`--film-grain 4`), evitando *Broken Pipes* e falhas de memória.

---

## 🛠️ Pré-requisitos e Dependências
Para que o pipeline funcione, você precisará das seguintes ferramentas instaladas e acessíveis no seu sistema:

1.  **Python 3.12+** (Para rodar o núcleo do Auto-Boost)
2.  **SVT-AV1-Essential:** [Build personalizada](https://github.com/nekotrix/SVT-AV1-Essential/discussions/12)
3.  **FFmpeg:** [Última versão (GPL)](https://github.com/BtbN/FFmpeg-Builds/releases/latest/download/ffmpeg-master-latest-win64-gpl.zip) *(Deve estar no PATH do Windows)*
4.  **Auto-Boost-Essential:** [Script Python Base](https://github.com/nekotrix/auto-boost-algorithm/blob/main/Auto-Boost-Essential/Auto-Boost-Essential.py)
5.  **VapourSynth & FFVship (CUDA/CPU):** [FFVship_nvidia v5.0.0](https://codeberg.org/Line-fr/Vship/releases) (Para a auditoria de qualidade das zonas)
6.  **MKVToolNix:** *(O executável `mkvmerge` deve estar no PATH do Windows)*

---

## 📂 Configuração dos Caminhos (Paths)
O arquivo `Converter Animes autoboost.ps1` foi construído para ser altamente customizável. Abra o script e verifique o dicionário `$AppConfig`:

* O script localizará o Python automaticamente na pasta especificada: `$HOME\PythonEnv\AutoBoost\Scripts\python.exe`
* O executável do SVT-AV1 será localizado em: `$HOME\SVT-AV1-Essential\Bin\Release\SvtAv1EncApp.exe`
* **Importante:** Ajuste as variáveis de caminho dentro do bloco `$AppConfig` para refletirem a estrutura exata de pastas do seu computador antes de iniciar o primeiro encode.

---

> **Nota:** Este pipeline foi desenhado para ser resiliente. Se a conversão de um episódio falhar no meio do caminho (ou não atingir os critérios de qualidade), o script preservará o arquivo original e passará para o próximo da fila de forma automática.