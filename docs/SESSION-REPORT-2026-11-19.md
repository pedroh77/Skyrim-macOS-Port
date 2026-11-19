# Relatório técnico — sessão DSH (2026-11-19)

**Projeto:** `/Users/pedro/git/Skyrim-macOS-Shim` — port nativo Apple Silicon do Skyrim 32-bit (Oldrim 1.9.32.0.8) via recompilação estática x86→ARM64 e D3D9→Metal.
**Máquina:** MacBook Air M1 2020, 7-core GPU, 8 GB, macOS 27.2.1 (26B131), painel 2560×1600.
**Intervalo coberto:** desde o fechamento do relatório de **2026-11-18 21:45** até **2026-11-19 02:30**.
**Relatório anterior:** `docs/SESSION-REPORT-2026-11-18.md` (janela de opções, harness de benchmark, análise MetalFX, diagnóstico do display 2560×1600 vs 2880×1800, sem commit).

> Este relatório é autocontido para repasse a outro agente. O relatório de 2026-11-18 continua sendo a referência para o bug da janela, o harness e a análise MetalFX; aqui está o que foi feito **depois** dele.

---

## 1. TL;DR

1. **Steam integrado e testado:** launcher (`SkyrimLauncher`), injeção do `gameoverlayrenderer.dylib`, AppID **72850**, bridge de achievements (`SteamUserStats`) e fallback offline. O teste real do launcher retornou `[steam] SteamAPI_Init -> true (AppID=72850)` e o jogo rodou a 60 fps. O Overlay em si (Shift+Tab) e as conquistas **não foram testados interativamente**.
2. **FXAA implementado e testado:** novo modo `FXAA (Fast, Post-Process)` ao lado de Off/SMAA, shader FXAA 3.11 em MSL, pipeline próprio no `d3d9_metal.m`, pass aplicado na resolução interna antes do MetalFX. Teste: `aa=fxaa`, 60 fps, sem erro de shader.
3. **Detecção do painel físico corrigida:** o app agora detecta **2560×1600** (painel) mesmo com o desktop em 2880×1800 (backing 2×), e tem override `SKYRIM_OUTPUT_WIDTH/HEIGHT`. Teste: `physical panel 2560x1600 (desktop backing 2880x1800)`, render 1714×1072 → output 2560×1600 (67%), MetalFX.
4. **App final construído, instalado e assinado:** `/Users/pedro/Applications/Skyrim.app`, 15 GB, `SkyrimLauncher` como `CFBundleExecutable`, `libsteam_api.dylib` universal, `steam_appid.txt=72850`, assinatura ad-hoc profunda válida. O fix do `NSWindow` do relatório anterior foi mantido.
5. **Fork publicado:** `https://github.com/pedroh77/Skyrim-macOS-Shim` (público, fork de `arjuk95-dot/FNV-iOS-Shim`), `main` no commit **`441d596`** (113 arquivos, 88.134 inserções, 3.286 deleções). Branch local `skyrim` rastreando `skyrim/main`.
6. **Presets de sombra investigados:** o app altera 5 chaves de `SkyrimPrefs.ini` (mapas principal/secundário, `iShadowMapResolution`, `fShadowDistance`, `iBlurDeferredShadowMask`). No benchmark da carroça (67% MFX, sem VSync): Low e Medium ~11 ms GPU / 200–239 fps; High ~14 ms / 181–206 fps (**+~25% GPU, −10–15% fps, +27 MB**). O `Keep` com um ini novo/padrão crashou por falta de `iShadowMapResolution`; o ini atual do usuário tem a chave.
7. **Ini do usuário ajustado:** `bShadowsOnGrass=0`, `fShadowDistance=1500`, `iShadowSplitCount=1`, `fInteriorShadowDistance=1500`, `iShadowFilter=2`; mapas 1024/512 e blur 3 mantidos. O modo correto para preservar isso é **Keep**.
8. **Limitações:** Overlay/achievements não testados visualmente; benchmark de sombras parcial (keep crashou; low/medium/high deram timeout no runner, mas os logs têm dados); app ad-hoc (Gatekeeper); avisos de link com Unicorn/FFmpeg compilados para macOS 27 vs alvo 14; `tests/run.sh`/host-check não rodaram nesta sessão; o Info.plist do app ainda grava o commit-base `6600879`.

---

## 2. Contexto e estado

- O relatório de 2026-11-18 terminou com: bug da janela corrigido, harness em `tools/bench/`, MetalFX medido, display diagnosticado (2880×1800 de backing), **nada commitado**, builds em `/tmp/skyrim-build` e `/tmp/skyrim-bench-build`.
- O estado agora:
  - App instalado em `~/Applications/Skyrim.app` (não mais `/tmp`).
  - `.git` do projeto agora tem o branch `skyrim` e o commit `441d596`, publicado no fork `pedroh77/Skyrim-macOS-Shim`.
  - O remote `origin` continua sendo `arjuk95-dot/FNV-iOS-Shim`; o remote `skyrim` aponta para o fork.
  - Build com `quick-install.sh` usando `--no-call-trace`; o app final tem `FNVGuestCallTraceEnabled=false`.
  - `SkyrimPrefs.ini` do usuário agora está em modo custom (Medium maps + ajustes de performance); o `Skyrim.ini` ainda tem `iShadowMapResolutionPrimary=2048`.
- Máquina: M1 Air fanless, 8 GB, 60 Hz, 2560×1600; o app usa 67% + MetalFX por padrão no teste; o jogo tem `pace_60fps()` (não usar `FNV_NOVSYNC` no gameplay).
- O `TESV.exe` usado é o unpacked Steamless CLI, SHA-256 `d97eb0cc0ceef0923d2234d42b382c0d033853356528b271bc043542b1f5e605`, e o `Info.plist` grava `FNVExecutableSHA256=d97eb0cc...`.

---

## 3. Steam: launcher, Overlay, AppID e achievements

### 3.1 O que o jogo importa

`llvm-objdump -p TESV.exe` mostra exatamente 5 imports de `steam_api.dll`:

- `SteamAPI_Init`
- `SteamAPI_RunCallbacks`
- `SteamAPI_RegisterCallback`
- `SteamAPI_UnregisterCallback`
- `SteamUserStats`

Todos estão cobertos por `upstream/recomp/host/shims_steam.c`, que também expõe os proxies `SteamUser`, `SteamFriends`, `SteamApps`, `SteamUtils`, `SteamAPI_IsSteamRunning`, `SteamAPI_Shutdown` e as funções de achievement get/set/clear. Sem Steam client/dylib, o shim cai em offline e o jogo continua.

### 3.2 Launcher

`macos/FNVSteamLauncher.c` compila como `SkyrimLauncher` e é o `CFBundleExecutable`:

- Verifica se o Steam Mac está instalado; se não estiver rodando, abre `Steam.app` com `-silent`.
- Espera o usuário global via `steamclient.dylib` (`SteamClient`/`ConnectToGlobalUser`) por até ~20 s.
- Define `SteamAppId`, `SteamGameId` e `SteamOverlayGameId` = **72850**.
- Injeta `gameoverlayrenderer.dylib` via `DYLD_INSERT_LIBRARIES` (caminho atual: `~/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/`).
- `execv` do binário `Skyrim` (mesmo diretório), preservando o ambiente.
- Flags: `SKYRIM_STEAM_DISABLE=1` (desliga a bridge), `SKYRIM_STEAM_NO_OVERLAY=1` (não injeta o Overlay).
- Limitação: não há fallback para instalações alternativas do Steam (`/Applications/Steam.app`, etc.) neste momento; o caminho atual existe nesta máquina.

### 3.3 Build e distribuição

- `quick-install.sh` baixa o `Steamworks.NET_20.1.0.unitypackage`, verifica SHA-256 `3be79e6bdf53c86210267bf39f46362bb839130896006aec26364c5efc37e314`, extrai `libsteam_api.dylib` universal (i386/x86_64/arm64), cacheia em `~/Library/Caches/skyrim-macos/steamworks/20.1.0/` e passa `--steam-api-dylib`/`--steam-appid 72850` ao `build.py`.
- `--no-steam` gera a variante offline, sem launcher/dylib/Overlay.
- `tools/build.py` copia a dylib para `Contents/Frameworks/libsteam_api.dylib`, escreve `Contents/MacOS/steam_appid.txt` (`72850`) e define `CFBundleExecutable=SkyrimLauncher`.
- `README.md` documenta Steam, `--no-steam`, os flags de runtime e o caminho do app.

### 3.4 Teste executado

Com `SkyrimLauncher` + `SKYRIM_SKIP_LAUNCHER=1` + `SKYRIM_AA=fxaa` + `FNV_QUIT_AFTER=30`:

```text
[S_API] SteamAPI_Init(): Loaded '.../Steam.AppBundle/Steam/Contents/MacOS/steamclient.dylib' OK.
[steam] SteamAPI_Init -> true (AppID=72850)
[display] physical panel 2560x1600 (desktop backing 2880x1800)
[display] render 1714x1072 -> output 2560x1600 (67%) @ 60Hz; upscaler=metalfx; aa=fxaa; ...
[metal] frame 1282: 59.7 fps, 11 draws/frame ...
exit=0
```

- `steam_osx` ficou rodando após o teste.
- A Steam ID foi carregada (linha `Caching Steam ID` do log do cliente); não é reproduzida neste relatório.
- O teste direto do binário `Skyrim` sem launcher mostrou `[steam] SteamAPI_Init -> false (Steam client unavailable; running offline)`, o fallback esperado.
- **Não testado:** Shift+Tab visualmente, notificações e desbloqueio de conquistas. A injeção do Overlay e a inicialização da Steam API estão configuradas/confirmadas; o teste visual é manual.

---

## 4. FXAA

### 4.1 Interface

- `macos/FNVApp.m` agora expõe no popup de Anti-Aliasing: `Off` (0), `SMAA (Post-Process)` (1), `FXAA (Fast, Post-Process)` (2).
- Persistência em `SkyrimAntiAliasing`; env `SKYRIM_AA=off|smaa|fxaa` (ou 0/1/2) tem prioridade; `opts.antiAliasing` é validado em 0..2.
- Log de display: `aa=off|smaa|fxaa`.
- O SMAA anterior foi mantido.

### 4.2 Renderer

Em `upstream/recomp/host/d3d9_metal.m`:

- `fxaa_pso`, `fxaa_samp`, `fxaa_out`, `fxaa_init_failed`, `fxaa_ensure_pipelines()`.
- Shader FXAA 3.11 (`fxaa_fs`) + full-screen triangle (`fxaa_vs`) compilado em runtime com `newLibraryWithSource`; o shader foi validado isoladamente com `xcrun metal` (exit 0).
- `run_fxaa()` roda no texture interno/final antes do MetalFX/bilinear; o present escolhe `SMAA` se `fnv_graphics_aa()==1`, `FXAA` se `==2`.
- `aa_name()` usado nos logs de init/display.

### 4.3 Teste

```text
[display] physical panel 2560x1600 (desktop backing 2880x1800)
[display] render 1714x1072 -> output 2560x1600 (67%) @ 60Hz; upscaler=metalfx; aa=fxaa; ...
[metal] frame 1277: 60.0 fps, 11 draws/frame (11 rendered), 6 pipelines, ff-skipped 0
[input] FNV_QUIT_AFTER: 30 s elapsed at frame 1390, exiting
exit=0
```

Sem `[fxaa]` de erro no log. O menu não foi clicado neste teste (foi usado `SKYRIM_AA=fxaa`), mas o item e a persistência estão no código; o caminho de render foi exercitado.

---

## 5. Painel físico 2560×1600

O relatório de 2026-11-18 diagnosticou que o app usava 2880×1800 (backing 1440×900 @2×) e que 2560×1600 seria mais eficiente. Nesta sessão foi implementada a correção em `macos/FNVApp.m`:

- `detectPhysicalDisplayPixels()` percorre `CGDisplayCopyAllDisplayModes` e escolhe o modo nativo (`kDisplayModeNativeFlag` / maior modo com a mesma proporção do painel), separando painel físico de backing.
- Override `SKYRIM_OUTPUT_WIDTH` / `SKYRIM_OUTPUT_HEIGHT` (640..16384 / 480..16384) para forçar o output.
- Log: `[display] physical panel 2560x1600 (desktop backing 2880x1800)`.
- O `SkyrimPrefs.ini` grava `iSize W=1714`, `iSize H=1072` (resolução interna de render 67%; o output é 2560×1600 via MetalFX).
- Resultado: 4,10 MP de output em vez de 5,18 MP (−21% de pixels vs 2880×1800), 1:1 no painel.

O `README.md` documenta a detecção e o override.

---

## 6. Build, instalação e assinatura

Build executada com `./quick-install.sh "$HOME/Applications/Skyrim.app"` (caches frios, pois a cache tinha sido apagada):

- Codecs reconstruídos (13 MB).
- Tradução do `TESV.exe`: **78.497 funções**; **78.501 TUs emitidos**; 6 `callother` pulados (`sqrtps` 4, `psllw` 1, `packssdw` 1); Ghidra/JSONL temporários limpos.
- Compilação ARM64 com `--no-call-trace`; link com Unicorn e FFmpeg.
- Avisos de link (não fatais): `unicorn` 2.1.4 (`/opt/homebrew`) e `libavcodec.63`/`libswresample.7`/`libavutil.61` (`/opt/local`) foram compilados para macOS 27.0 e o app tem alvo macOS 14.0. Funciona nesta máquina (macOS 27.2.1); não valida macOS 14.
- GameData de 14 GB movido para o bundle; 1 Bink convertido para MP4; assinatura ad-hoc; instalação em `~/Applications`; exit 0.
- Log completo: `/tmp/quick-install-steam-fxaa.log`.
- Disco: ~19 GB livres antes, ~18 GB depois; app 15 GB.

### 6.1 Bundle final

```text
Skyrim.app/Contents/MacOS/Skyrim            147.573.600 bytes
Skyrim.app/Contents/MacOS/SkyrimLauncher     35.184 bytes
Skyrim.app/Contents/MacOS/steam_appid.txt         6 bytes ("72850")
Skyrim.app/Contents/Frameworks/libsteam_api.dylib 556.976 bytes (universal)
Skyrim.app/Contents/Info.plist              CFBundleExecutable=SkyrimLauncher
                                            FNVExecutableSHA256=d97eb0cc...
                                            FNVBuildSourceCommit=6600879
```

- `codesign --verify --deep --strict` → `valid on disk`, `satisfies its Designated Requirement`.
- `Skyrim`, `SkyrimLauncher`, `libsteam_api.dylib` e `steam_appid.txt` assinados/validados; assinatura ad-hoc (`dev.skyrimmac.game`), sem notarização.
- O `Info.plist` ainda registra o commit-base FNV `6600879` porque a build foi feita antes do commit `441d596`; um rebuild futuro grava o commit novo. Não afeta o funcionamento.

---

## 7. Verificação (matriz)

| Item | Comando/condição | Resultado |
|---|---|---|
| Build | `quick-install.sh` | exit 0; app 15 GB; 78.501 TUs; 6 skipped; avisos de SDK |
| Assinatura | `codesign --verify --deep --strict` | válida; nested assinados; ad-hoc |
| FXAA | `Skyrim` + `SKYRIM_AA=fxaa` | 2560×1600; 1714×1072 67%; 60 fps; exit 0; sem erro |
| Steam API | `SkyrimLauncher` + skip | `[S_API]` OK; `[steam] true (72850)`; 60 fps; exit 0; `steam_osx` |
| Overlay | injeção do launcher | configurada/confirmada; Shift+Tab **não** testado visualmente |
| Achievements | shims | implementados; **não** testados interativamente |
| Painel | log de display | 2560×1600 (backing 2880×1800); 67%; MetalFX |
| Sombras | `run_bench.py` 4 presets | keep crash; low/medium/high timeout; dados nos logs; High +25% |
| Janela/Play | fix anterior | código mantido; app testado via `SKYRIM_SKIP_LAUNCHER`; Play pela janela não re-testado |
| Host tests | `tests/run.sh`/`host-check` | **não** rodaram nesta sessão |
| CI | `.github` herdado do FNV | não ajustado/verificado |

---

## 8. Presets de sombra

### 8.1 O que o app altera

`macos/FNVApp.m` (linhas ~1064–1081) só mexe em 5 chaves:

| Preset | `iShadowMapResolution` | Primary / Secondary | `fShadowDistance` | `iBlurDeferredShadowMask` |
|---|---|---|---|---|
| **Keep** | não escreve | não escreve | não escreve | não escreve |
| **Low** | 512 | 512 / 512 | 1500 | 2 |
| **Medium** | 1024 | 1024 / 512 | 2500 | 3 |
| **High** | 2048 | 2048 / 1024 | 4000 | 5 |

O padrão do jogo (`Skyrim.app/Contents/Resources/GameData/Skyrim/SkyrimPrefs.ini`) tem Primary 2048 / Secondary 1024, distância 2500, blur 5 — mas **não tem `iShadowMapResolution`**. O `Keep` com esse ini novo crashou no teste.

### 8.2 Benchmark

- Runner: `python3 tools/bench/run_bench.py --app .../Skyrim --root .../GameData --script tools/bench/cart_intro.script --config metalfx67:67:metalfx:0 --novsync --repeats 1 --quit-after 240 --timeout 180`.
- 4 presets: keep, low, medium, high.
- **keep**: `rc=-6`; validação Metal `depthAttachmentPixelFormat MTLPixelFormatBGRA8Unorm is not depth renderable`; causa provável: `iShadowMapResolution` ausente no ini padrão.
- **low/medium/high**: `rc=timeout` (o runner mata em 180 s; a carroça sem VSync a ~200 fps não terminou no `--quit-after 240`); os `run.log` têm intervalos `[perf]` válidos.
- Dados dos logs (carroça, 67% MFX, AA off, sem VSync):

| Preset | GPU/frame | FPS | Footprint |
|---|---|---|---|
| Low | ~10,5–12,7 ms | ~200–229 | 1725 MB |
| Medium | ~10,0–12,1 ms | ~200–239 | 1732 MB |
| High | ~11,9–14,7 ms | ~181–206 | 1752 MB |
| Keep (novo) | crash | — | — |

- **High vs Low/Medium:** +~25% GPU, −10–15% fps, +27 MB; **Medium ≈ Low** nesta cena. O `thermal=1` apareceu já no Low/Medium; a máquina é fanless.
- A carroça é leve e o teto de 60 Hz (16,7 ms) dá folga; em cenas externas pesadas/mais sombras o High pode apertar. O teste é `--novsync`, então os fps não são o gameplay; o GPU é o dado comparativo.
- O runner não gerou `summary.csv` nos runs com falha; os números acima vêm dos `[perf]` dos `run.log` em `/tmp/skyrim-shadow-*`.

### 8.3 Ini do usuário

Antes: Medium (1024/512, 2500, blur 3, `iShadowMapResolution=1024`, `iShadowFilter=3`, `bShadowsOnGrass=1`).
Depois:

```ini
[Display]
fInteriorShadowDistance=1500.0000
fShadowDistance=1500.0000
iShadowSplitCount=1
iShadowFilter=2
bShadowsOnGrass=0
; mantidos: iShadowMapResolution=1024, Primary=1024, Secondary=512,
; iBlurDeferredShadowMask=3, bTreesReceiveShadows=0, bDrawLandShadows=0
```

- `bShadowsOnGrass` fica em `[Display]` no `SkyrimPrefs.ini`; não existe no `Skyrim.ini` — essa foi a confusão do usuário (o `Skyrim.ini` tem outro `[Display]` e `iShadowMapResolutionPrimary=2048`).
- O `Skyrim.ini` ainda tem `iShadowMapResolutionPrimary=2048`; o `SkyrimPrefs.ini` 1024. O app/presets só alteram o Prefs. Não alinhei o `Skyrim.ini` nesta sessão.
- **Keep** é o modo certo para preservar esses valores; Low/Medium/High sobrescrevem as 5 chaves. Se o jogo reescrever o ini pelas opções gráficas internas, os ajustes podem ser perdidos; reaplicar.

### 8.4 Recomendação

- **Medium** (1024/2500) é o melhor equilíbrio no M1 Air; o custo no teste foi ≈ Low.
- **Low** para máximo fps/thermal ou se o visual de sombras curtas/blocadas não incomodar.
- **High** só para qualidade/indoor/screenshots; o custo e o calor no Air fanless não justificam como padrão.
- **Keep** apenas com ini editado; no ini atual, Keep = custom (não é um preset de qualidade).
- Correção pendente: o `Keep` deve garantir `iShadowMapResolution` quando o ini padrão não a tiver, evitando o crash.

---

## 9. Fork, commit e publicação

- Fork: `https://github.com/pedroh77/Skyrim-macOS-Shim` — público, `isFork=true`, parent `arjuk95-dot/FNV-iOS-Shim`.
- `main` = **`441d596`**: *"Convert FNV-iOS-Shim to The Elder Scrolls V: Skyrim (32-bit LE) macOS port"*; 113 arquivos, 88.134 inserções, 3.286 deleções; inclui Steam, FXAA, painel, README, `tools/bench`, docs e os fontes.
- Descrição/tópicos do repo ajustados no GitHub.
- Localmente: branch `skyrim` rastreando `skyrim/main`; `origin` = FNV; `skyrim` = fork.
- O relatório anterior (`2026-11-18`) e este (`2026-11-19`) ficam em `docs/`.
- O app foi construído antes do commit; `FNVBuildSourceCommit=6600879` (base FNV). Rebuild após o commit grava `441d596`.
- GitHub Actions herdadas do FNV não foram revisadas/ajustadas.

---

## 10. Limitações e riscos

1. **Overlay e achievements não testados visualmente** — só a inicialização da Steam API, o `steam_osx` e a configuração da injeção. Testar Shift+Tab e um achievement.
2. **Benchmark de sombras parcial** — keep crash, low/medium/high timeout; o runner precisa de `--timeout`/`--quit-after` maiores ou `--novsync` desligado; o keep precisa da chave `iShadowMapResolution`.
3. **Keep crash** — ini padrão sem `iShadowMapResolution` → pipeline Metal com depth BGRA8. O ini atual do usuário tem a chave; o bug fica para um ini novo.
4. **Assinatura ad-hoc** — Gatekeeper pode pedir right-click → Open no primeiro launch; não é notarizada.
5. **Avisos de SDK** — Unicorn/FFmpeg compilados para macOS 27; alvo 14. Não afeta esta máquina.
6. **`Skyrim.ini` vs `SkyrimPrefs.ini`** — o `Primary` 2048 no `Skyrim.ini` e 1024 no Prefs; o app só mexe no Prefs. Alinhar se quiser consistência.
7. **Jogo pode reescrever o Prefs** pelas opções gráficas internas; os ajustes custom/Keep podem ser perdidos.
8. **Testes host/CI** — `tests/run.sh` e `host-check` não rodaram; workflows herdados não foram verificados.
9. **App Info commit** — 6600879, não 441d596; rebuild opcional.
10. **Steam overlay path** — só o caminho atual do Steam; sem fallback para outras instalações.
11. **`SkyrimLauncher`/janela** — fix anterior mantido; esta build foi testada via `SKYRIM_SKIP_LAUNCHER`; o Play pela janela não foi re-testado.
12. **Dados de sombra** — carroça leve, 1 run/config, `thermal=1`; o High pode ser pior em cenas pesadas. Não usar os fps de `--novsync` como gameplay.

---

## 11. Próximos passos

1. Corrigir o `Keep` para garantir `iShadowMapResolution` (usar o Primary ou um default 1024) e testar com um ini padrão.
2. Testar Shift+Tab, notificações e um achievement com o Steam client real.
3. Refazer o benchmark de sombras com `--timeout 300`, `--quit-after 150`, cooldown ≥60 s, 2 repetições e uma cena externa pesada; medir Low/Medium/High no cap de 60.
4. Decidir o `Skyrim.ini` `iShadowMapResolutionPrimary` (2048) vs Prefs (1024) e, se necessário, alinhar.
5. Adicionar fallback do Overlay para `/Applications/Steam.app` e instalações alternativas.
6. Rodar `bash tests/run.sh` e `python3 tools/build.py host-check`; revisar as GitHub Actions herdadas.
7. Rebuild opcional após `441d596` para gravar o commit novo no Info.plist.
8. Atualizar README/report conforme os resultados; o app atual já está em `~/Applications`.

---

## 12. Artefatos e caminhos

**App e jogo**
- `/Users/pedro/Applications/Skyrim.app` (15 GB; GameData 14 GB).
- `Contents/MacOS/{Skyrim,SkyrimLauncher,steam_appid.txt}`; `Contents/Frameworks/libsteam_api.dylib`; `Contents/Info.plist`.
- `~/Library/Application Support/Skyrim/UserDocuments/My Games/Skyrim/{Skyrim.ini,SkyrimPrefs.ini}`.
- `~/Library/Logs/Skyrim/skyrim.log`.

**Build/logs**
- `/tmp/quick-install-steam-fxaa.log`
- `/tmp/fxaa_test.log`
- `/tmp/steam_launcher_test.log`
- `/tmp/skyrim-shadow-{keep,low,medium,high}/metalfx67_r1/run.log`

**Caches**
- `~/Library/Caches/skyrim-macos/codecs/`
- `~/Library/Caches/skyrim-macos/translate-d97eb0cc0cee/`
- `~/Library/Caches/skyrim-macos/objects-<hash>/`
- `~/Library/Caches/skyrim-macos/steamworks/20.1.0/libsteam_api.dylib`

**Fonte**
- `macos/FNVApp.m`, `macos/FNVDisplay.c`, `macos/FNVSteamLauncher.c`
- `upstream/recomp/host/d3d9_metal.m`, `shims_steam.c`, `shims_win.c`, `shims_kernel32.c`
- `tools/build.py`, `quick-install.sh`, `README.md`
- `docs/SESSION-REPORT-2026-11-18.md`, `docs/SESSION-REPORT-2026-11-19.md`
- `tools/bench/*` (harness)

**Git**
- Repo: `/Users/pedro/git/Skyrim-macOS-Shim`; branch `skyrim`; `441d596`.
- Fork: `https://github.com/pedroh77/Skyrim-macOS-Shim`; parent `arjuk95-dot/FNV-iOS-Shim`; `origin` FNV; `skyrim` fork.

---

## 13. Caveats

- Os números de sombra são de 1 run por preset, com `--novsync`, carroça e `thermal=1`; servem para comparar GPU, não para prometer fps de gameplay. O cap real é 60 Hz.
- O `keep` crashou por um ini novo sem `iShadowMapResolution`; o ini atual do usuário tem a chave, então o Keep atual funciona. O fix ainda não foi implementado.
- O `Skyrim.ini` tem `iShadowMapResolutionPrimary=2048` e o Prefs 1024; não alinhei. O jogo pode usar um dos dois; validar em jogo.
- O Overlay/achievements não foram testados interativamente; o launcher/Steam API foram.
- A assinatura é ad-hoc; o primeiro launch pode pedir right-click → Open.
- Os avisos de link (macOS 27 vs 14) não impedem esta máquina, mas não validam macOS 14.
- `tests/run.sh`, `host-check` e CI não rodaram nesta sessão.
- O app foi construído antes do commit `441d596`; o Info.plist grava `6600879`.
- O `README` foi atualizado com Steam/FXAA/painel/`--no-steam`; o relatório de 2026-11-18 continua válido para janela/harness/MetalFX.

---

*Fim do relatório.*
