# Relatório técnico — sessão DSH (2026-11-18)

> **Nota (2026-11-20):** o projeto foi renomeado de `Skyrim-macOS-Shim` para `Skyrim-macOS-Port`. O diretório local já usa o nome novo; o repositório no GitHub acompanha o rename.

**Projeto:** `/Users/pedro/git/Skyrim-macOS-Port` — port nativo Apple Silicon do Skyrim 32-bit (Oldrim) via recompilação estática e D3D9→Metal.
**Máquina:** MacBook Air M1 2020, 7-core GPU, 8 GB, macOS 27.2.1 (26B131), painel 2560×1600.
**Objetivo desta sessão:** (1) diagnosticar/corrigir o crash introduzido pela janela de opções; (2) criar uma forma objetiva de medir e comparar escala de render × MetalFX.

> Este relatório é autocontido para repasse a outro agente. Números medidos nesta máquina; onde há estimativa ou confound, está marcado.

---

## 1. TL;DR

1. **O crash da janela de opções não era MetalFX/SMAA.** Era um over-release de `NSWindow` sob ARC: `close` com `releasedWhenClosed=YES` + `self.optionsWindow = nil` liberavam a janela duas vezes; o autorelease pool depois tentava liberar memória já liberada → `SIGSEGV` em `objc_release`. Corrigido em `macos/FNVApp.m` e verificado: Play abre o jogo.
2. **Montei um harness de benchmark reproduzível** em `tools/bench/`: cenário fixo (intro/carroça + diálogo estático), scripts de input, sincronização, métricas `[perf]`, dumps de qualidade e análise por draw count.
3. **Resultado principal:** MetalFX **não é um ganho de performance na mesma escala**. Ele custa ~2–4 ms de GPU a 2880×1800. O ganho que se percebe vem de **baixar a escala de render** (100% → 75% → 50%), não do upscaler. Na carroça, o MetalFX 50% (~51 fps) é competitivo com bilinear 75% (~49 fps) e tem texto mais nítido, mas a 50% o aliasing aparece.
4. **67% é um bom sweet spot** no modo 2880×1800: escala 1,49×, GPU ~12,7 ms, bem menos aliasing que 50% (2×). 85% não vale (GPU 16,2 ms / ~34 fps, quase nativo); 75% é o limite de qualidade com ~40 fps na carroça.
5. **O painel é 2560×1600, mas o app sai 2880×1800** por causa do modo 1440×900 @2x. O 2880×1800 é supersampling/HiDPI (o WindowServer reduz para 2560×1600), não detalhe real além do painel; custa 26% mais pixels. Para jogar, 2560×1600 1:1 é mais eficiente; o 75% em 2560 tem interno 1920×1200 e equivale aproximadamente ao 67% em 2880, com menos GPU e sem downsample.
6. **MetalFX usado no projeto = API Metal 3-era (`MTLFXSpatialScaler`, `MTLCommandBuffer`)**, não Metal 4. O M1/macOS 27 suporta a API Metal 4 (`supportsMetal4FX=1`), que tem `MTL4FXSpatialScaler`, temporal denoised e frame interpolator. O algoritmo spatial é o mesmo; Metal 4 é integração/modelo de comando/novos recursos, exige port do renderer.
7. **Temporal/TAA não compensa no Oldrim D3D9** — a avaliação do Gemini está essencialmente correta: faltam motion vectors por objeto, jitter limpo, depth/history; camera-only gera ghosting em NPCs/folhagem/água/partículas. O spatial é a escolha pragmática.
8. **A API permite <50% nesta máquina** (encode spatial completou em 2×, 3×, 4×, 6× e 8×), mas o projeto clampa em 50% em dois lugares. Acima de 2× a qualidade/performance não são garantidas; para a carroça, 50% já está no piso prático por causa da CPU.
9. **CPU é o teto na carroça**: `main_cpu_ms` 17–24 ms; a 50% a GPU (~10 ms) já está abaixo da CPU. O 60 fps não é realista na carroça neste M1 Air; indoor/leve deve encostar em 60.
10. **Estado:** correções e harness estão no working tree, **sem commit**. O `.git` do projeto ainda é um clone do FNV-iOS-Shim; os arquivos do Skyrim estão untracked. Não commitei nada. A build corrigida do jogo está em `/tmp/skyrim-build/Skyrim.app`; a build de benchmark em `/tmp/skyrim-bench-build/Skyrim.app`.

---

## 2. Contexto e estado do repositório

- Diretório ativo: `/Users/pedro/git/Skyrim-macOS-Port`.
- O projeto nasceu de uma cópia do FNV-iOS-Shim; o usuário criou depois o fork `pedroh77/FalloutNewVegas-macOS-Shim` para o port macOS do FNV. O Skyrim é um segundo fork local nunca publicado.
- O `.git` em `Skyrim-macOS-Port` aponta para `git@github.com:arjuk95-dot/FNV-iOS-Shim.git`, HEAD `6600879` (branch `macos`), e **não** tem histórico do Skyrim. Os arquivos do Skyrim aparecem como untracked; o `git status` mostra deleções/modificações do FNV (ios/, testes etc.). O Info.plist grava `FNVBuildSourceCommit=6600879` (commit do FNV). Não alterei isso.
- Builds:
  - `/tmp/skyrim-build/Skyrim.app` — jogo com a correção da janela; a build antiga que crashava foi renomeada para `/tmp/skyrim-build/Skyrim.app.crashy-20261118`.
  - `/tmp/skyrim-bench-build/Skyrim.app` — build de benchmark, com `waitsteady` no input e paridade bilinear headless.
  - `/tmp/skyrim-rebuild/Skyrim.app` — build intermediária da correção (igual à instalada).
- Não há save em `~/Library/Application Support/Skyrim/UserDocuments/.../Saves` (vazio). O harness usa o intro e o diálogo, não um save.

---

## 3. Bug da janela de opções (diagnóstico e correção)

### 3.1 Sintoma

- A janela de opções abria; ao clicar **Play**, o app morria com `SIGSEGV`.
- Cinco relatórios em `~/Library/Logs/DiagnosticReports/Skyrim-2026-11-18-*.ips` (18:39–18:41) com o mesmo stack, na main thread:

```
objc_release
AutoreleasePoolPage::releaseUntil
objc_autoreleasePoolPop
_CFAutoreleasePoolPop
-[NSAutoreleasePool drain]
-[NSApplication run]
main
```

- `vmRegionInfo`: endereço da falha fora de qualquer região mapeada → `isa` de objeto já liberado.

### 3.2 Prova

Rodando com `NSZombieEnabled=YES`:

```
*** -[NSKVONotifying_NSWindow release]: message sent to deallocated instance 0x...
```

Era a janela de opções (`NSWindow`) sendo liberada de novo no drain do pool.

### 3.3 Causa raiz

`NSWindow.releasedWhenClosed` é `YES` por padrão. O código fazia:

```objc
[self.optionsWindow close];   // -close libera/autorelease a janela
self.optionsWindow = nil;     // ARC libera de novo
```

Sob ARC, isso desaloca a janela enquanto uma referência ainda está pendente no autorelease pool; no próximo drain, `objc_release` lê a `isa` já sobrescrita e segfaulta.

Reprodução mínima fora do projeto (ARC, AppKit):

```objc
NSWindow *w = [[NSWindow alloc] initWithContentRect:...];
[w close];
w = nil;
// @autoreleasepool drain -> SIGSEGV
```

Com `w.releasedWhenClosed = NO;` antes do `close`, o mesmo programa termina com status 0.

### 3.4 Correção aplicada em `macos/FNVApp.m`

1. Na criação da janela de opções:

```objc
self.optionsWindow.releasedWhenClosed = NO;
```

2. Em `launchWithOptions:`:
   - a janela do jogo é mostrada **antes** de fechar a de opções;
   - a janela de opções é mantida viva por uma referência forte local e fechada de forma assíncrona na main queue, **depois** que a ação do botão Play retorna:

```objc
self.gameLaunched = YES;

[self.window center];
[self.window makeKeyAndOrderFront:nil];
[self.window makeFirstResponder:self.metalView];
[NSApp activateIgnoringOtherApps:YES];

if (self.optionsWindow) {
    NSWindow *optionsWindow = self.optionsWindow;
    self.optionsWindow = nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        [optionsWindow close];
    });
}
```

3. Também foi verificado o caminho de fechar a janela pelo botão vermelho (`windowWillClose` → terminate) — encerra com status 0, sem crash.

### 3.5 Verificação

- Build corrigida instalada em `/tmp/skyrim-build/Skyrim.app`.
- Teste com clique real no botão Play via `performClick:` (não só chamada direta): o jogo abriu e rodou:
  - `[display] render 2160x1350 -> output 2880x1800 (75%) @ 60Hz; upscaler=metalfx; aa=off; ...`
  - `[metal] frame 2458: 56.4 fps, ...`
- A janela de opções sozinha fica aberta sem crash; fechar no vermelho encerra limpo.

**Observação:** o bug era independente das opções escolhidas (MetalFX/SMAA); acontecia no fechamento da janela, antes de o jogo iniciar.

---

## 4. Harness de benchmark

### 4.1 Arquivos criados em `tools/bench/`

| Arquivo | Função |
|---|---|
| `cart_intro.script` | Sincroniza no menu, abre New Game, confirma, espera o cinematográfico e mede a carroça; dumps no fim. |
| `dialog.script` | Sincroniza no diálogo “Start a new game?” (câmera/UI estáticas) e mede uma janela curta; isola o upscaler. |
| `menu_quality.script` | Para no diálogo e faz um dump estático para qualidade. |
| `run_bench.py` | Executa configs, captura logs, parseia `[metal]`/`[perf]`, agrega, escreve `results.json`, `summary.csv`. |
| `capture_quality.py` | Captura frames estáticos alinhados por config. |
| `compare_frames.py` | PSNR/SSIM contra o nativo; suporta crop/índice de dump. |
| `analyze_windows.py` | Analisa janelas por faixa de draw count (comparação “mesmo trabalho”). |
| `make_chart.py` | Gera gráfico GPU/CPU/fps a partir do `summary.csv`. |
| `README.md` | Protocolo, comandos, métricas, resultados do piloto e limitações. |

### 4.2 Comando de input novo (`upstream/recomp/host/input.c`)

Adicionado `waitsteady <frames> [<min_draws>]`:

- espera o draw count ficar **inalterado** por N frames e ser ≥ `min_draws`;
- ao satisfazer, desloca os frames seguintes do script (mesma semântica do `waitdraws`);
- usado para sincronizar no menu (que pode ter 10 ou 13 draws) e no diálogo (40 draws) sem depender de um valor fixo.

Implementação resumida:

```c
if (!strcmp(s->cmd, "waitsteady")) {
    uint64_t need = s->a ? (uint64_t)s->a : 30;
    uint64_t min = s->b > 0 ? (uint64_t)s->b : 0;
    if (last_draws < min) steady_run = 0;
    else if (last_draws == steady_draws) steady_run++;
    else { steady_draws = last_draws; steady_run = 1; }
    if (steady_run < need) return;
    shift = (int64_t)frame - (int64_t)s->frame;
    steady_run = 0; cursor++;
    continue;
}
```

### 4.3 Paridade bilinear no headless (`upstream/recomp/host/d3d9_metal.m`)

No modo headless (benchmark/dumps) o caminho **bilinear** não fazia o upscale até a resolução de saída; o MetalFX fazia. Isso subestimava o custo do bilinear e gerava dumps de tamanhos diferentes (2160×1350 vs 2880×1800).

Correção (só headless; o jogo em janela não muda):

```objc
if (!drawable && final_tex && fnv_graphics_upscaler() != 1 &&
    (final_tex.width != outW || final_tex.height != outH)) {
    // cria/reutiliza linear_out em 2880×1800
    blit(final_tex, linear_out, 0, 0, 1);   // sampler linear
    final_tex = linear_out;
}
```

Com isso, bilinear e MetalFX pagam o passe final na resolução de saída; os dumps ficam 2880×1800 e a comparação de GPU/qualidade fica justa.

### 4.4 Cenários e janelas

**Carroça (gameplay real):**

- Script: `waitsteady 120 9` (menu), `tap 28` (Enter/New), `waitsteady 90 20` (diálogo), `tap 28` (Yes), dumps em 4300/4400/4500, quit em 4800.
- Janela medida: frames de script **2400–4200** após o segundo sync (1800 frames; 30 s a 60 fps, mais tempo quando o fps é menor).
- O jogo usa o pace de 60 Hz (`pace_60fps`) para Havok; não usar `FNV_NOVSYNC` em gameplay.

**Diálogo (GPU isolado):**

- Script: `waitsteady 120 9`, `tap 28`, `waitsteady 90 20`, quit em 600.
- Janela: `--window-start 150 --window-end 550`; câmera/UI estáticas, 37–40 draws; fps travado em 60. Ler `gpu_ms`, não fps.

**Qualidade:**

- `menu_quality.script`: para no diálogo, `dump` em 50, quit em 120.
- Frames de 2880×1800; comparação por índice 0.
- Métricas: PSNR e SSIM (janela local 8×8 em luma reduzida 2×) contra o nativo 100%; também crop do texto do diálogo (estático e alinhado).

### 4.5 Métricas e controles

- `gpu_ms`: duração média de GPU dos command buffers concluídos (timestamps Metal).
- `main_cpu_ms`: CPU da thread do jogo/present; teto de CPU.
- `fps = 1000 / interval_ms` (média de ~2 s).
- `present_ms`, `drawable_wait_ms`, `inflight_wait_ms`.
- `max_interval_ms` (pior frame da janela), `draws`, `compile_ms_total`.
- `thermal`, `low_power`, `footprint_mib`, `upload_peak_kib`.
- Excluídas janelas com `compile_ms_total > 0`; dumps fora da janela de medição.
- `SKYRIM_MOUSE_ACCEL=0` em todos os runs (a aceleração do touchpad não afeta GPU/CPU; só o feel de input).
- Headless, mesmo user dir, mesmos flags de build (sem `--no-call-trace`).
- Intercalação/cooldown/repetições no protocolo; o piloto foi 1 run por config.

### 4.6 Comandos

Build de benchmark (uma vez; cache):

```sh
python3 tools/build.py game \
  --generated ~/Library/Caches/skyrim-macos/translate-124306c7ea4a/generated \
  --exe "$HOME/Library/Application Support/Steam/steamapps/common/Skyrim/TESV.exe" \
  --codec-prefix ~/Library/Caches/skyrim-macos/codecs/prefix \
  --unicorn-prefix /opt/homebrew/opt/unicorn \
  --cache ~/Library/Caches/skyrim-macos/objects-124306c7ea4a \
  --out /tmp/skyrim-bench-build --app-name Skyrim
```

Piloto da carroça:

```sh
python3 tools/bench/run_bench.py \
  --config native:100:bilinear:0 \
  --config bilinear75:75:bilinear:0 \
  --config metalfx75:75:metalfx:0 \
  --config metalfx50:50:metalfx:0 \
  --repeats 1 --cooldown 75 --out /tmp/skyrim-bench-pilot
```

67/85:

```sh
python3 tools/bench/run_bench.py \
  --config metalfx67:67:metalfx:0 --config metalfx85:85:metalfx:0 \
  --repeats 1 --cooldown 60 --out /tmp/skyrim-bench-6785
```

Microbench do diálogo:

```sh
python3 tools/bench/run_bench.py \
  --script "$PWD/tools/bench/dialog.script" \
  --window-start 150 --window-end 550 --cooldown 10 \
  --config native:100:bilinear:0 \
  --config bilinear75:75:bilinear:0 --config metalfx75:75:metalfx:0 \
  --config bilinear50:50:bilinear:0 --config metalfx50:50:metalfx:0 \
  --out /tmp/skyrim-bench-dialog3
```

Qualidade:

```sh
python3 tools/bench/capture_quality.py --out /tmp/skyrim-bench-quality2 --cooldown 10
python3 tools/bench/compare_frames.py \
  --results /tmp/skyrim-bench-quality2/results.json \
  --reference native --dump-index 0
```

Sweep completo recomendado:

```sh
python3 tools/bench/run_bench.py --repeats 2 --cooldown 90 \
  --config metalfx50:50:metalfx:0 --config bilinear50:50:bilinear:0 \
  --config metalfx67:67:metalfx:0 --config metalfx75:75:metalfx:0 \
  --config metalfx85:85:metalfx:0 --config native:100:bilinear:0 \
  --out /tmp/skyrim-bench-full
```

---

## 5. Resultados medidos

### 5.1 Carroça — piloto (1 run/config; janelas medidas com thermal=0)

| config | escala | upscaler | GPU ms | CPU ms | fps |
|---|---:|---|---:|---:|---:|
| native | 100% | bilinear | 18,00 | 24,27 | 34,3 |
| bilinear75 | 75% | bilinear | 11,25 | 17,46 | 48,9 |
| metalfx75 | 75% | MetalFX | 13,83 | 21,20 | 40,3 |
| metalfx50 | 50% | MetalFX | 9,95 | 16,81 | 50,9 |

Mesma faixa de draws (1200–1600; reduz a diferença de trecho da carroça):

| config | GPU ms | CPU ms | fps |
|---|---:|---:|---:|
| bilinear75 | 11,06 | 17,08 | 49,8 |
| metalfx75 | 13,62 | 19,80 | 42,4 |
| metalfx50 | 9,97 | 16,82 | 51,4 |
| native | 17,98 | 24,49 | 33,5 |

67% e 85% (runs adicionais):

| config | GPU ms | CPU ms | fps | observação |
|---|---:|---:|---:|---|
| metalfx67 | 12,72 | 22,69 | 29,7 | **thermal=1** e trecho mais pesado; fps não comparável; GPU confiável |
| metalfx85 | 16,23 | 21,69 | 34,2 | thermal=0 |

O 85% é quase o nativo em fps (34,2 vs 34,3) com GPU 16,2 vs 18,0: pouco ganho de qualidade sobre 75% por muito custo. O 67% deve ficar ~43–45 fps em condição fria/mesmo trecho (GPU entre 50% e 75%); o 29,7 medido foi contaminado por thermal=1.

### 5.2 Diálogo estático — build com paridade bilinear (GPU-bound; fps 60 cap)

| config | GPU ms |
|---|---:|
| native 100% | 8,25 |
| bilinear75 | 5,84 |
| metalfx75 | 8,79 |
| bilinear50 | 3,34 |
| metalfx50 | 7,06 |

CPU 1,3–3,3 ms; GPU é o limite. O MetalFX spatial custa ~3 ms sobre o bilinear na mesma escala; a 75% chega a ser mais caro que o nativo 100% nesta cena leve.

### 5.3 Qualidade — diálogo estático vs nativo 100%

Frame completo (2880×1800):

| config | PSNR dB | SSIM |
|---|---:|---:|
| bilinear75 | 23,24 | 0,7821 |
| metalfx75 | 23,31 | 0,8004 |
| metalfx50 | 23,67 | 0,8870 |

Crop do texto do diálogo (região estática; mais representativo para AA de UI):

| config | PSNR dB | SSIM |
|---|---:|---:|
| bilinear75 | 19,36 | 0,5847 |
| metalfx75 | 19,18 | 0,7232 |
| metalfx50 | 19,00 | 0,7401 |

Leitura: o MetalFX entrega bordas/texto bem mais nítidos que o bilinear na mesma escala (SSIM 0,72 vs 0,58); o PSNR ligeiramente favorece o bilinear por suavizar. O 50% tem SSIM de texto até maior (0,74) por conta do edge enhancement do scaler, mas PSNR menor e possível over-sharpening; visualmente o texto do 50% fica mais “bold”. Em movimento, o 50% mostra aliasing/shimmer; o 67% reduz muito.

### 5.4 O que os números mostram

- **MetalFX não é speed-up na mesma escala.** Custo de GPU: ~+2,6 ms na carroça a 75%; ~+2,95 ms no diálogo a 75%; ~+3,7 ms a 50%.
- **O ganho vem da escala**: 100→75 economiza ~4–7 ms de GPU; 75→50 mais ~4 ms. Na carroça, 34 → 40 → 51 fps.
- **CPU é o teto na carroça**: 17–24 ms. A 50%, GPU ~10 ms < CPU; o fps ~51 e não 60. Abaixo de 50% o ganho seria pequeno (cpu/60 cap) e a qualidade pior.
- **85% não vale**; **67% é o sweet spot** no modo 2880×1800; **75%** para qualidade/indoor; **50%** só para cenas pesadas (aliasing).
- **A aceleração do touchpad não entra no fps**: ela muda o mapeamento/suavização do mouse; a sensação de resposta melhora, mas `gpu_ms`/`main_cpu_ms` não mudam.

---

## 6. MetalFX: spatial × temporal, Metal 3 × Metal 4, limites de escala

### 6.1 O que o projeto usa

Em `upstream/recomp/host/d3d9_metal.m`, `run_metalfx_spatial()`:

- `MTLFXSpatialScalerDescriptor`
- `newSpatialScalerWithDevice:`
- `[scaler encodeToCommandBuffer:cmd]` em um `MTLCommandBuffer`
- `colorProcessingMode = Perceptual`
- output BGRA8 na resolução de saída; input na resolução interna.

Isso é a **API Metal 3-era** do MetalFX (introduzida no macOS 13 / iOS 16), não a API Metal 4.

### 6.2 Metal 4 nesta máquina

- `system_profiler` reporta “Metal Support: Metal 4”.
- Probe direto: `[MTLFXSpatialScalerDescriptor supportsMetal4FX:device] = 1` no M1.
- O SDK macOS 27.2 traz:
  - `MTL4FXSpatialScaler` (macOS 26+), criado com `newSpatialScalerWithDevice:compiler:` e `MTL4Compiler`, encodado em `MTL4CommandBuffer`;
  - `MTL4FXTemporalScaler`, `MTL4FXTemporalDenoisedScaler`, `MTL4FXFrameInterpolator`.
- Para o **spatial**, o algoritmo/qualidade é o mesmo; muda a integração (modelo de comando/compilador), com potencial de menor overhead de CPU e novos recursos. Portar exigiria usar `MTL4CommandBuffer`/`MTL4Compiler` no renderer — mudança grande, não um switch. O gargalo da carroça é o guest/draw submission, não só a API.

### 6.3 Limite de escala

Teste empírico no M1/macOS 27.2:

- `MTLFXSpatialScaler` criado com input/output de 1,00× a 4,00× (2880×1800 de saída): todos OK.
- Encode real (textura de entrada preenchida, comando commit/wait, leitura da saída) em **2×, 3×, 4×, 6× e 8×**: todos `status=4` (completed), sem erro, saída não vazia.
- Ou seja: **a API não impõe 2× nesta máquina**. O **projeto** clampa em 50% em:
  - `macos/FNVApp.m` — `clampScale` (50–100) e o seletor da janela;
  - `macos/FNVDisplay.c` — `if (scale_pct < 50u) scale_pct = 50u;`.
- O Spatial é otimizado/documentado para até 2× (50%); acima disso a qualidade/performance não são garantidas. Para 33%/25% seria preciso remover o clamp e aceitar imagem mais macia/aliased; na carroça o ganho seria limitado pela CPU/60 cap.
- O temporal scaler (MetalFX) e o frame interpolator também existem, mas não são usados.

### 6.4 Temporal/TAA no Oldrim D3D9

A avaliação do Gemini está essencialmente correta:

- TAA/MetalFX Temporal exigem **motion vectors por pixel**, **jitter de projeção**, **depth** e **histórico**.
- O stream D3D9 do Oldrim não fornece motion vectors por objeto; o layer D3D9→Metal vê draws/constantes, mas não tem o movimento anterior de NPCs, árvores, água, partículas ou malhas skinned de forma limpa.
- Um **camera-only** com reprojeção por depth funciona para geometria estática, mas **fantasma** objetos em movimento (NPCs, folhagem, água, partículas); o Oldrim tem muita folhagem.
- Injetar jitter na matriz de projeção afeta culling, sombras, reflexos e UI; sem coordenar todos os passes, treme.
- Gerar motion vectors de verdade exigiria instrumentar transforms/skinning do engine — projeto grande e arriscado, não um toggle.
- `MTL4FXTemporalScaler`/`MTL4FXFrameInterpolator` também precisam desses dados; a API disponível no M1 não resolve o problema do engine. Frame interpolation ainda adiciona latência.
- **Conclusão:** spatial é a escolha pragmática; o preço é aliasing em escalas baixas. O 67% ameniza; o SMAA é a alavanca espacial disponível (custa GPU).

---

## 7. Display 2560×1600 vs output 2880×1800

- Painel físico: **2560×1600** (MacBook Air M1 13").
- O app usa `NSScreen.frame × backingScaleFactor`. No modo “looks like 1440×900” com 2×, o output é **2880×1800**.
- O WindowServer reduz 2880×1800 → 2560×1600. Isso é:
  - **HiDPI** para UI/texto (renderizado em 2×, mais nítido);
  - **supersampling leve** para o 3D (1,125× de downsample), que pode reduzir aliasing;
  - **não** é detalhe real além do painel.
- Custo: 5,18 MP vs 4,10 MP = **+26,4%** de pixels no GPU e no scaler.
- Para o jogo, 2560×1600 (1280×800 HiDPI ou modo 2560×1600 no SwitchResX) é mais eficiente: 1:1 no painel, ~21% menos trabalho, possivelmente mais nítido (sem downsample).
- Relação de detalhe efetivo no painel:
  - 67% em 2880 → interno 1928×1206; após downsample 1,125× → ~1715×1072 efetivos no painel.
  - 75% em 2560 → interno 1920×1200; 1:1 → ~1920×1200 efetivos, com menos GPU e sem downsample.
  - 67% em 2560 → interno 1715×1072; 1:1; mais performance, menos detalhe.
- O “100% (Native)” do launcher é a resolução de backing, não a do painel. O app não tem override de output; a troca de modo de display é a alavanca atual. Um override `SKYRIM_OUTPUT_WIDTH/HEIGHT` (ou uma janela 1280×800 pts em fullscreen 2560×1600) exigiria mudança de código; o fullscreen 1:1 de verdade pede o modo de display.

---

## 8. CPU, 8 GB e limites de hardware

- Na carroça, `main_cpu_ms` 17–24 ms; a GPU a 50% é ~10 ms. O jogo é CPU-bound nessa cena.
- A build atual tem `FNVGuestCallTraceEnabled=true` (call trace ligado). O `--no-call-trace` é uma alavanca de CPU, mas muda os flags de todos os TUs → recompilação completa do cache. O `quick-install.sh` usa `--no-call-trace`; a build manual atual não.
- 8 GB **não é o limitador do MetalFX**: o footprint do jogo é ~3,4 GB; o scaler adiciona dezenas de MB. O limite é o GPU de 7 núcleos, fanless/thermal e o output 2880×1800. Fechar apps ajuda; o 60 Hz cap é o teto.
- 60 Hz: `pace_60fps()` mantém Havok estável; não usar `FNV_NOVSYNC` em gameplay. Em cenas leves, o fps encosta em 60 e o MetalFX só reduz consumo/calor.

---

## 9. Recomendações

1. **Default global no modo 2880×1800: 67% MFX** (o “Balanced” do launcher). É o melhor equilíbrio visual/performance no spatial; 50% só para as cenas mais pesadas (aliasing); 75% para indoor/qualidade; 85% não vale.
2. **Se trocar o display para 2560×1600: 75% MFX** (1920×1200, 1:1) é o equivalente ao 67% em 2880, com menos GPU e sem downsample. Para mais fps, 67%; para máximo, 50%.
3. **SMAA** se o aliasing incomodar no 50% ou em movimento no 67%; custo modesto.
4. **CPU**: `--no-call-trace` e redução de draw distance/grass/shadows rendem mais que descer de 50% para 33%.
5. **Não** investir em temporal/TAA/frame interpolation sem motion vectors; o spatial é o caminho; o Gemini está certo.
6. **Próximos passos de medição**: sweep completo com 2 repetições/90 s; incluir 67/85 e bilinear em cada escala; SMAA 0/1 em 50/67; criar um save indoor/leve e medir o “limiar” real por cena; testar 2560×1600; opcionalmente 33/25% com clamp removido para quantificar o tradeoff.
7. **Git**: o projeto não tem histórico do Skyrim. Antes de continuar, criar um repositório/commit próprio (ou um branch) para não perder a correção e o harness; o `.git` atual é do FNV. Não fiz commit.

---

## 10. Artefatos e caminhos

- Fonte corrigido: `macos/FNVApp.m` (janela), `upstream/recomp/host/input.c` (`waitsteady`), `upstream/recomp/host/d3d9_metal.m` (paridade bilinear headless + MetalFX).
- Harness: `tools/bench/*` (README com protocolo e resultados).
- Build do jogo corrigida: `/tmp/skyrim-build/Skyrim.app`; build antiga crashando: `/tmp/skyrim-build/Skyrim.app.crashy-20261118`.
- Build de benchmark: `/tmp/skyrim-bench-build/Skyrim.app`.
- Dados:
  - `/tmp/skyrim-bench-pilot/` — `summary.csv`, `results.json`, `windows.csv`, `bench.png`, logs/dumps.
  - `/tmp/skyrim-bench-6785/` — 67/85.
  - `/tmp/skyrim-bench-dialog3/` — microbench do diálogo pós-paridade.
  - `/tmp/skyrim-bench-quality2/` — dumps de qualidade, `quality.csv`, `text_compare.png`.
- Backups/README: `tools/bench/README.md`; `/tmp/FNVApp.m.before-launcher-fix` (backup do fonte antes da correção da janela).
- Probes de API (temporários): `/tmp/mfxprobe/probe.m`, `/tmp/mfxencode/enc.m`.

---

## 11. Caveats importantes

- O piloto é **1 run por config**; a carroça se move e o fps muda o trecho coberto. Os números de fps/CPU são indicativos; os deltas de GPU e a conclusão “MetalFX custa ~2–4 ms e não é speed-up na mesma escala” são consistentes entre carroça e diálogo.
- O run de 67% pegou `thermal=1` e trecho pesado; o fps 29,7 **não** deve ser usado; o GPU 12,72 é o dado útil. Reexecutar com cooldown ≥90 s.
- O frame completo do diálogo tem ruído da animação do fundo; o crop de texto é a comparação estática mais confiável. SSIM e PSNR discordam em parte; o olho humano/uso em movimento decide.
- A paridade bilinear headless é uma correção de benchmark; o jogo em janela não mudou.
- O teste de escala <50% foi direto na API, não no jogo; o projeto clampa. Qualidade em 33/25% não foi medida em gameplay.
- O modo 2560×1600 não foi testado (não alterei o display do usuário); o ganho é estimado por contagem de pixels.
- A build de benchmark tem call trace ligado; comparar com `--no-call-trace` exige rebuild completo.
- O `.git` do projeto é do FNV; os arquivos do Skyrim e o harness estão untracked. Nada foi commitado.

---

*Fim do relatório.*
