# Harle Optimizer

Otimizador de Windows para jogos, em um único `Harle.exe`. · *Windows gaming optimizer in a single `Harle.exe`.* [English below](#english)

Comunidade: https://discord.gg/rDb9raznQ7

## O que ele faz
- **Otimizar**: 77 ajustes em 10 categorias (desempenho, placa de vídeo, registro, debloat, privacidade, rede, conforto, limpeza, manutenção, avançados), com perfis Competitivo, Equilibrado e Notebook. Cada PC vê só os da sua versão do Windows. Tudo tem backup e **Reverter tudo**.
- **Debloat do Windows 10 e 11 do seu jeito**: cada item com a própria chave, você escolhe o que sai. Detecta a versão e mostra só o que existe nela (Widgets, Copilot, Recall e botão do Chat no 11; Cortana, Reunir Agora e barra de Pessoas no 10), mais telemetria, anúncios e apps patrocinados. Store, Xbox e Game Bar ficam.
- **Apps**: escolha um por um quais apps pré-instalados remover (Skype, Cortana, Bing, Candy Crush...). Store e Xbox nunca entram na lista.
- **Medição** de FPS (média e 1% low) antes/depois, com **gráfico do histórico** e **cartão de resultado** para postar.
- **Monitor** com **overlay no jogo** e **alerta de temperatura** da placa de vídeo.
- **Modo partida**: fecha o que pesa e reabre depois.
- **Drivers**: drivers do Windows Update escolhendo um por um, dispositivos com problema e links oficiais de vídeo e chipset. Feito para depois de formatar.
- **Memória**: limpeza de RAM (cache, lista modificada e working set) na hora ou automática, no estilo do Mem Reduct.
- **Jogos**: modo partida automático, prioridade alta fixa e placa de vídeo dedicada, jogo por jogo.
- **Scanner**, **Upgrade** (o que vale trocar no seu PC) e **BIOS** (XMP, Resizable BAR, CSM, Secure Boot/TPM, PBO).
- **Saúde do PC**: erros de hardware (WHEA), telas azuis com a causa provável, desligamentos, TDR do driver, discos e bateria.
- **Discos**: saúde, temperatura, horas ligado, total escrito e a tabela S.M.A.R.T. completa de cada disco (NVMe e SATA), no estilo do CrystalDiskInfo.
- **Copiar relatório** para pedir ajuda no Discord.
- **Online**: ping, jitter e perda de pacotes até os data centers de São Paulo, DNS mais rápido com troca em um clique e detector de overlays.
- **Salvar e carregar configuração** em arquivo, para compartilhar com a comunidade.
- **Atualização com um clique**, conferindo o SHA-256 antes de trocar o exe.
- Português e inglês (botão EN/PT).

## Como usar
1. Baixe o `Harle.exe` na página **Releases** (só de lá ou do Discord oficial).
2. Abra como administrador. O Harle cria um ponto de restauração antes de mudar qualquer coisa.
3. Se o Windows mostrar **"O Windows protegeu o computador"** (SmartScreen): clique em **Mais informações → Executar assim mesmo**. Isso aparece porque o arquivo ainda não tem assinatura digital paga, não porque tem vírus.

## Kit de formatação (sem internet)
Em cada versão, além do `Harle.exe`, a Release traz o **`Harle-Kit-<versão>.zip`**: o Harle e os instaladores oficiais da Microsoft que os jogos precisam (Visual C++ 2005 a 2022, DirectX de junho de 2010 e .NET 8), com a assinatura digital conferida. Dá para baixar no celular, passar para o PC recém-formatado e instalar tudo sem internet: extraia a pasta, abra o `Harle.exe` de dentro dela e use a aba **Drivers → Runtimes para jogos**.

Sem driver de rede depois de formatar? Ligue um celular **Android** no PC pelo cabo e ative a **Ancoragem USB**: o Windows já tem o driver para isso. Com internet, a aba Drivers encontra o driver da placa de rede. Antes de formatar, a mesma aba salva num pendrive os drivers do seu PC e o **3DP Net** (driver de rede para quase todas as placas, baixado do site oficial). Já formatou? Baixe o 3DP Net em [3dpchip.com](https://www.3dpchip.com/3dpchip/index_eng.html) pelo celular e coloque na pasta `Rede` do kit: o Harle mostra o botão **Abrir o 3DP Net**.

## Conferir se o arquivo é o original
Compare o SHA-256 do arquivo baixado com o publicado na Release. No PowerShell:
```powershell
Get-FileHash .\Harle.exe -Algorithm SHA256
```
O mesmo código aparece dentro do Harle, em **Créditos → Conferir o arquivo (SHA-256)**. Se for diferente, não abra.

O SHA-256 de cada versão está na descrição da Release correspondente.

## Antivírus
Otimizadores mexem em registro, serviços e tarefas agendadas, então alguns antivírus dão alerta genérico ("heurístico"). Você pode enviar o arquivo ao [VirusTotal](https://www.virustotal.com) e ver o resultado de dezenas de antivírus.

## Desfazer
**Reverter tudo** devolve cada ajuste ao valor original (guardado em `C:\ProgramData\Harle\backup.json`). Apps removidos e arquivos apagados pela limpeza não voltam. Registro de atividades: `C:\ProgramData\Harle\harle.log`.

## Código aberto
O Harle é código aberto, sob a licença **GPL-3.0** (veja `LICENSE`): qualquer pessoa pode ler, compilar e conferir o que ele faz. Quem distribuir uma versão modificada precisa manter o código aberto e os créditos.

Cada Release é compilada pelo GitHub Actions a partir deste repositório, e a descrição da Release traz o link da compilação. Para compilar você mesmo (Windows, Linux ou macOS, com PowerShell 7):
```
pwsh build/build.ps1
```
O exe sai em `out/Harle.exe`. A assinatura digital está descrita em `SIGNING.md`.

## Terceiros
PresentMon (Intel, licença MIT), NVAPI/NVML (NVIDIA), AMD Display Library, PowerShell e WPF (Microsoft). Assemblies de referência do .NET Framework para compilar (.NET Foundation, licença MIT).

---

## English
Windows gaming optimizer: 77 tweaks with profiles and full revert (each PC only sees the ones for its Windows version), Windows 10/11 debloat where you pick each item, per-app debloat, FPS benchmark with result card, in-game overlay and GPU temperature alert, play mode, hardware scanner, upgrade advice, BIOS checklist, PC Health (WHEA errors, blue screens, drives, battery) and a CrystalDiskInfo-style Drives tab with full S.M.A.R.T. Switch language with the EN/PT button.

- Download `Harle.exe` only from **Releases** or the official Discord, and run it as administrator. A restore point is created before any change.
- If Windows SmartScreen says **"Windows protected your PC"**, click **More info → Run anyway**. It shows because the file is not code-signed yet.
- Verify the file: `Get-FileHash .\Harle.exe -Algorithm SHA256` must match the hash in the release (also shown in **Credits → Verify the file (SHA-256)**).
- **Revert all** restores every original value. Removed apps and cleaned files don't come back.
- Open source under GPL-3.0, built by GitHub Actions. Build it yourself with `pwsh build/build.ps1`.
