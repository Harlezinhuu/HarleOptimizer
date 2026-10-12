#requires -Version 5.1
<#
    Harle Optimizer 3.6
    Otimizador de Windows para jogos: scanner de hardware, ajustes de desempenho,
    registro, debloat, rede e limpeza. Tudo o que o Harle muda fica salvo em
    C:\ProgramData\Harle\backup.json e pode ser revertido pelo proprio app.

    Este script vai embutido no Harle.exe. Tambem roda direto:
    powershell -ExecutionPolicy Bypass -File Harle.ps1

    Copyright (C) 2026 Harle. Licenca GPL-3.0: veja LICENSE em github.com/Harlezinhuu/HarleOptimizer.
#>
param([switch]$SelfTest, [switch]$Elevated)

$ProgressPreference = 'SilentlyContinue'
$script:AppVersion  = '3.6'
# Repositorio do GitHub onde ficam as versoes novas, no formato usuario/repositorio. Vazio = nao confere.
$script:UpdateRepo  = 'Harlezinhuu/HarleOptimizer'
$script:DiscordUrl  = 'https://discord.gg/rDb9raznQ7'
$script:DataDir     = Join-Path $env:ProgramData 'Harle'
$script:BackupFile  = Join-Path $script:DataDir 'backup.json'
$script:LogFile     = Join-Path $script:DataDir 'harle.log'
$script:Backup      = @{ reg = @{}; state = @{} }
$script:Build       = [Environment]::OSVersion.Version.Build
try {
    $cb = [int](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop).CurrentBuildNumber
    if ($cb -gt 0) { $script:Build = $cb }
} catch { }
$script:Hosted      = [bool]$env:HARLE_HOSTED
$script:Busy        = $false
$script:RunResult   = @{}
$script:HasNvidia   = $null
$script:HasAmd      = $null
$script:GpuChoice   = 'nvidia'
$script:GuardTask   = 'Harle Optimizer - conferir ajustes'
$script:TimerTask   = 'Harle Optimizer - timer'
$script:GuardExe    = Join-Path $env:ProgramFiles 'Harle\Harle.exe'
$script:HarlePlan  = '7c0f2a51-6b3e-4d8a-9c1f-5a2e8d4b6c90'
$script:RestoreDone = $false

# ---------------------------------------------------------------------------
#  Idioma. Em portugues nada e traduzido. Em ingles, os textos fixos sao trocados quando aparecem na tela
#  (Register-Tr) e os textos com valores usam um modelo traduzivel: Tx 'Memoria a {0} MHz' $velocidade.
#  O dicionario fica em en.tsv (embutido no Harle.exe): uma linha por texto, "portugues<TAB>ingles".
# ---------------------------------------------------------------------------
$script:Lang   = 'pt'
$script:TrDict = $null

function Import-TrDict {
    $script:TrDict = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
    $text = $null
    try {
        if ($script:Hosted) {
            $st = [Harle.Native].Assembly.GetManifestResourceStream('en.tsv')
            if ($st) { $rd = New-Object System.IO.StreamReader($st, [Text.Encoding]::UTF8); $text = $rd.ReadToEnd(); $rd.Dispose() }
        }
        if (-not $text -and $PSScriptRoot -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'en.tsv'))) {
            $text = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'en.tsv'), [Text.Encoding]::UTF8)
        }
    } catch { }
    if (-not $text) { return }
    foreach ($line in $text.Split("`n")) {
        $l = $line.TrimEnd("`r")
        if (-not $l -or $l.StartsWith('#')) { continue }
        $i = $l.IndexOf("`t")
        if ($i -le 0) { continue }
        # \n no arquivo vira quebra de linha de verdade
        $k = $l.Substring(0, $i).Replace('\n', "`n"); $v = $l.Substring($i + 1).Replace('\n', "`n")
        $script:TrDict[$k] = $v
    }
}

function Set-Lang([string]$Lang) {
    $script:Lang = if ($Lang -eq 'en') { 'en' } else { 'pt' }
    if ($script:Lang -eq 'en' -and $null -eq $script:TrDict) { Import-TrDict }
}

# Texto com valores: traduz o modelo e so depois coloca os valores.
function Tx([string]$Template) {
    $t = $Template
    if ($script:Lang -eq 'en' -and $script:TrDict) {
        $x = $null
        if ($script:TrDict.TryGetValue($Template, [ref]$x)) { $t = $x }
    }
    if ($args.Count -gt 0) { return ($t -f $args) }
    return $t
}

# Texto pronto: inteiro no dicionario; senao, linha por linha e frase por frase.
function Tr([string]$Text) {
    if ($script:Lang -ne 'en' -or [string]::IsNullOrEmpty($Text) -or -not $script:TrDict) { return $Text }
    $x = $null
    if ($script:TrDict.TryGetValue($Text, [ref]$x)) { return $x }
    if ($Text.Contains("`n")) { return ((@($Text.Split("`n")) | ForEach-Object { Tr $_ }) -join "`n") }
    $lead = $Text.Length - $Text.TrimStart().Length
    if ($lead -gt 0 -or $Text.TrimEnd().Length -lt $Text.Length) {
        $core = $Text.Trim()
        if ($script:TrDict.TryGetValue($core, [ref]$x)) { return $Text.Substring(0, $lead) + $x + $Text.Substring($lead + $core.Length) }
    }
    # "Rede  ·  3", "1  ·  PRIORIDADE": traduz cada lado
    if ($Text.Contains('  ·  ')) { return ((@($Text -split '  ·  ') | ForEach-Object { Tr $_ }) -join '  ·  ') }
    $parts = [regex]::Split($Text, '(?<=[.!?:;])\s+(?=[A-ZÀ-Ý0-9"(])')
    if ($parts.Count -gt 1) {
        $changed = $false
        $out = foreach ($p in $parts) { if ($script:TrDict.TryGetValue($p, [ref]$x)) { $changed = $true; $x } else { $p } }
        if ($changed) { return ($out -join ' ') }
    }
    return $Text
}

# ---------------------------------------------------------------------------
#  Log e backup
# ---------------------------------------------------------------------------
function Write-Log([string]$Message) {
    try {
        if (-not (Test-Path -LiteralPath $script:DataDir)) { New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null }
        Add-Content -LiteralPath $script:LogFile -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message) -Encoding UTF8
    } catch { }
}

function Import-Backup {
    if (-not (Test-Path -LiteralPath $script:BackupFile)) { return }
    try {
        $o = Get-Content -LiteralPath $script:BackupFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($o.reg)   { foreach ($p in $o.reg.PSObject.Properties)   { $script:Backup.reg[$p.Name]   = $p.Value } }
        if ($o.state) { foreach ($p in $o.state.PSObject.Properties) { $script:Backup.state[$p.Name] = $p.Value } }
    } catch { Write-Log "Backup ilegivel: $($_.Exception.Message)" }
}

function Save-Backup {
    try {
        if (-not (Test-Path -LiteralPath $script:DataDir)) { New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null }
        ($script:Backup | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $script:BackupFile -Encoding UTF8
    } catch { Write-Log "Falha ao salvar backup: $($_.Exception.Message)" }
}

# Quem usou o app com o nome antigo (Vortex): traz o backup, tira a tarefa e a pasta antigas.
function Invoke-Migration {
    $oldData = Join-Path $env:ProgramData 'Vortex'
    $oldProg = Join-Path $env:ProgramFiles 'Vortex'
    if (-not (Test-Path -LiteralPath $oldData) -and -not (Test-Path -LiteralPath $oldProg)) { return $false }
    try {
        $oldBackup = Join-Path $oldData 'backup.json'
        if ((Test-Path -LiteralPath $oldBackup) -and -not (Test-Path -LiteralPath $script:BackupFile)) {
            if (-not (Test-Path -LiteralPath $script:DataDir)) { New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null }
            Copy-Item -LiteralPath $oldBackup -Destination $script:BackupFile -Force
        }
    } catch { Write-Log "Migracao do backup: $($_.Exception.Message)" }
    try { Unregister-ScheduledTask -TaskName 'Vortex Optimizer - conferir ajustes' -Confirm:$false -ErrorAction SilentlyContinue } catch { }
    try { Remove-Item -LiteralPath $oldProg -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    # A pasta antiga so sai depois que o backup esta a salvo no lugar novo.
    if (-not (Test-Path -LiteralPath (Join-Path $oldData 'backup.json')) -or (Test-Path -LiteralPath $script:BackupFile)) {
        try { Remove-Item -LiteralPath $oldData -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
    try {
        if ((Invoke-Native 'powercfg.exe' '/list').Out -match $script:HarlePlan) {
            [void](Invoke-Native 'powercfg.exe' "/changename $($script:HarlePlan) `"Harle - Desempenho maximo`" `"Criado pelo Harle Optimizer`"")
        }
    } catch { }
    Write-Log 'Dados do nome antigo (Vortex) migrados'
    return $true
}

# Ate a 3.4 o ajuste de gravacao em segundo plano tambem desligava a captura da Game Bar. Devolve o valor original.
function Restore-GameBarCapture {
    try {
        $old = @(
            @{ P = 'HKCU\System\GameConfigStore'; N = 'GameDVR_Enabled'; T = 'DWord'; V = 0; D = 1 },
            @{ P = 'HKCU\Software\Microsoft\Windows\CurrentVersion\GameDVR'; N = 'AppCaptureEnabled'; T = 'DWord'; V = 0; D = 1 }
        )
        $done = $false
        foreach ($e in $old) {
            if ($script:Backup.reg.ContainsKey("$($e.P)|$($e.N)")) { Restore-RegEntry $e; $done = $true }
        }
        if ($done) { Save-Backup; Write-Log 'Captura da Game Bar devolvida (ajuste antigo de gravacao)' }
    } catch { Write-Log "Falhou ao devolver a captura da Game Bar: $($_.Exception.Message)" }
}

# Ate a 3.5.1 havia "Pausar o Windows Update ate 2099". Ela foi trocada pelo controle igual ao gpedit, que deixa a
# Store, o Xbox e o Defender funcionando. Quem tinha a pausa ligada: a pausa sai e o controle novo entra no lugar.
function Convert-WuPause {
    try {
        $wux = 'HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
        $old = @(
            @{ P = $wux; N = 'PauseUpdatesExpiryTime';     T = 'String'; V = '2099-12-31T00:00:00Z' },
            @{ P = $wux; N = 'PauseFeatureUpdatesEndTime'; T = 'String'; V = '2099-12-31T00:00:00Z' },
            @{ P = $wux; N = 'PauseQualityUpdatesEndTime'; T = 'String'; V = '2099-12-31T00:00:00Z' }
        )
        $had = @($script:Backup.state['applied']) -contains 'wupause'
        foreach ($e in $old) { if ($script:Backup.reg.ContainsKey("$($e.P)|$($e.N)")) { $had = $true; Restore-RegEntry $e } }
        if (-not $had) { return }
        foreach ($n in 'PauseUpdatesStartTime', 'PauseFeatureUpdatesStartTime', 'PauseQualityUpdatesStartTime') { Remove-RegValue $wux $n }
        Set-Applied 'wupause' $false
        $t = $script:TweakById['wucontrol']
        if ($t) { Enable-Tweak $t }
        Save-Backup
        Write-Log 'Pausa do Windows Update ate 2099 trocada pelo controle igual ao gpedit'
    } catch { Write-Log "Troca da pausa do Windows Update: $($_.Exception.Message)" }
}

# Carrega o backup e deixa tudo pronto para ler ou aplicar ajustes.
function Initialize-State {
    $migrated = Invoke-Migration
    Import-Backup
    Restore-GameBarCapture
    Convert-WuPause
    $saved = [string]$script:Backup.state['gpu']
    if ($saved -eq 'nvidia' -or $saved -eq 'amd') { $script:GpuChoice = $saved }
    elseif (Test-Nvidia) { $script:GpuChoice = 'nvidia' }
    elseif (Test-Amd)    { $script:GpuChoice = 'amd' }
    $savedProfile = [string]$script:Backup.state['profile']
    if (@($script:Profiles | ForEach-Object { $_.Id }) -contains $savedProfile) { $script:ProfileId = $savedProfile }
    else {
        try { if (@(Get-CimInstance Win32_Battery -ErrorAction Stop).Count -gt 0) { $script:ProfileId = 'notebook' } } catch { }
    }
    if ($migrated -and $script:Hosted -and (@($script:Backup.state['applied']) -contains 'guard')) {
        try { Enable-Tweak $script:TweakById['guard'] } catch { Write-Log "Migracao da checagem do login: $($_.Exception.Message)" }
    }
}

# ---------------------------------------------------------------------------
#  Registro (API .NET direta: sem curingas, sem apagar chaves existentes)
# ---------------------------------------------------------------------------
function Open-RegKey([string]$Path, [switch]$Write, [switch]$Create) {
    $i    = $Path.IndexOf('\')
    $root = $Path.Substring(0, $i)
    $sub  = $Path.Substring($i + 1)
    $hive = if ($root -eq 'HKLM') { [Microsoft.Win32.RegistryHive]::LocalMachine } else { [Microsoft.Win32.RegistryHive]::CurrentUser }
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive, [Microsoft.Win32.RegistryView]::Default)
    if ($Create) { return $base.CreateSubKey($sub) }
    return $base.OpenSubKey($sub, [bool]$Write)
}

function Get-RegState([string]$Path, [string]$Name) {
    $k = $null
    try {
        $k = Open-RegKey $Path
        if ($null -eq $k) { return @{ Exists = $false; KeyExists = $false } }
        if (@($k.GetValueNames()) -notcontains $Name) { return @{ Exists = $false; KeyExists = $true } }
        $kind = $k.GetValueKind($Name)
        $val  = $k.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        return @{ Exists = $true; KeyExists = $true; Kind = $kind.ToString(); Value = $val }
    } catch {
        return @{ Exists = $false; KeyExists = $false }
    } finally {
        if ($k) { $k.Close() }
    }
}

function ConvertTo-UInt32($Value) {
    return [uint32]([int64]$Value -band 4294967295)
}

function Set-RegValue([string]$Path, [string]$Name, $Value, [string]$Kind) {
    $k = Open-RegKey $Path -Create
    try {
        switch ($Kind) {
            'DWord' {
                $u = ConvertTo-UInt32 $Value
                $k.SetValue($Name, [BitConverter]::ToInt32([BitConverter]::GetBytes([uint32]$u), 0), [Microsoft.Win32.RegistryValueKind]::DWord)
            }
            'QWord'        { $k.SetValue($Name, [int64]$Value,    [Microsoft.Win32.RegistryValueKind]::QWord) }
            'Binary'       { $k.SetValue($Name, [byte[]]$Value,   [Microsoft.Win32.RegistryValueKind]::Binary) }
            'MultiString'  { $k.SetValue($Name, [string[]]$Value, [Microsoft.Win32.RegistryValueKind]::MultiString) }
            'ExpandString' { $k.SetValue($Name, [string]$Value,   [Microsoft.Win32.RegistryValueKind]::ExpandString) }
            default        { $k.SetValue($Name, [string]$Value,   [Microsoft.Win32.RegistryValueKind]::String) }
        }
    } finally { $k.Close() }
}

function Remove-RegValue([string]$Path, [string]$Name) {
    $k = $null
    try {
        $k = Open-RegKey $Path -Write
        if ($k) { $k.DeleteValue($Name, $false) }
    } catch { } finally { if ($k) { $k.Close() } }
}

function Test-ValueEqual($A, $B, [string]$Kind) {
    try {
        if ($Kind -eq 'DWord') { return ((ConvertTo-UInt32 $A) -eq (ConvertTo-UInt32 $B)) }
        return ([string]$A -eq [string]$B)
    } catch { return $false }
}

function Backup-RegValue([string]$Path, [string]$Name) {
    $key = "$Path|$Name"
    if ($script:Backup.reg.ContainsKey($key)) { return }
    $s = Get-RegState $Path $Name
    if ($s.Exists) { $script:Backup.reg[$key] = @{ Exists = $true; Kind = $s.Kind; Value = $s.Value } }
    else           { $script:Backup.reg[$key] = @{ Exists = $false } }
}

# Entrada de registro: @{ P=caminho; N=nome; T=tipo; V=valor; D=padrao do Windows (opcional); Del=$true para apagar }
function Test-RegEntry($e) {
    $s = Get-RegState $e.P $e.N
    if ($e.Del) { return (-not $s.Exists) }
    if (-not $s.Exists) { return $false }
    return (Test-ValueEqual $s.Value $e.V $e.T)
}

function Set-RegEntry($e) {
    Backup-RegValue $e.P $e.N
    if ($e.Del) { Remove-RegValue $e.P $e.N } else { Set-RegValue $e.P $e.N $e.V $e.T }
}

function Restore-RegEntry($e) {
    $key = "$($e.P)|$($e.N)"
    $b = $null
    if ($script:Backup.reg.ContainsKey($key)) { $b = $script:Backup.reg[$key] }
    $useBackup = $false
    if ($null -ne $b) {
        if ($e.Del)             { $useBackup = [bool]$b.Exists }
        elseif (-not $b.Exists) { $useBackup = $true }
        else                    { $useBackup = -not (Test-ValueEqual $b.Value $e.V $e.T) }
    }
    if ($useBackup) {
        if ($b.Exists) { Set-RegValue $e.P $e.N $b.Value ([string]$b.Kind) } else { Remove-RegValue $e.P $e.N }
    } elseif (-not $e.Del) {
        if ($e.ContainsKey('D')) { Set-RegValue $e.P $e.N $e.D $e.T } else { Remove-RegValue $e.P $e.N }
    }
    $script:Backup.reg.Remove($key)
}

# ---------------------------------------------------------------------------
#  Ajudantes dos ajustes que nao sao so registro
# ---------------------------------------------------------------------------
# Roda um programa de console sem abrir janela e devolve a saida e o codigo.
function Invoke-Native([string]$File, [string]$Arguments) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $File
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    try { $psi.StandardOutputEncoding = [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage) } catch { }
    $p = [System.Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEnd()
    $p.WaitForExit()
    $code = $p.ExitCode
    $p.Dispose()
    return @{ Out = $out; Code = $code }
}

function Get-ActivePlan {
    try {
        $o = (Invoke-Native 'powercfg.exe' '/getactivescheme').Out
        $m = [regex]::Match($o, '([0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12})\s*(?:\((.+)\))?')
        if ($m.Success) { return @{ Guid = $m.Groups[1].Value.ToLower(); Name = $m.Groups[2].Value.Trim() } }
    } catch { }
    return @{ Guid = ''; Name = '' }
}

function Get-ServiceStart([string]$Name) {
    $s = Get-RegState "HKLM\SYSTEM\CurrentControlSet\Services\$Name" 'Start'
    if ($s.Exists) { return [int]$s.Value }
    return $null
}

function Test-ServicesDisabled([string[]]$Names) {
    $found = 0
    foreach ($n in $Names) {
        if (-not (Get-Service -Name $n -ErrorAction SilentlyContinue)) { continue }
        $found++
        if ((Get-ServiceStart $n) -ne 4) { return $false }
    }
    return ($found -gt 0)
}

function Disable-Services([string]$StateKey, [string[]]$Names) {
    $saved = @{}
    $old = $script:Backup.state[$StateKey]
    foreach ($n in $Names) {
        if (-not (Get-Service -Name $n -ErrorAction SilentlyContinue)) { continue }
        $start = Get-ServiceStart $n
        if ($null -ne $old -and $null -ne $old.$n) { $saved[$n] = [int]$old.$n }
        elseif ($null -ne $start -and $start -ne 4) { $saved[$n] = [int]$start }
        Stop-Service -Name $n -Force -ErrorAction SilentlyContinue
        Set-Service  -Name $n -StartupType Disabled -ErrorAction SilentlyContinue
    }
    $script:Backup.state[$StateKey] = $saved
}

function Restore-Services([string]$StateKey, [hashtable]$Defaults) {
    $saved = $script:Backup.state[$StateKey]
    foreach ($n in $Defaults.Keys) {
        if (-not (Get-Service -Name $n -ErrorAction SilentlyContinue)) { continue }
        $v = $null
        if ($null -ne $saved) { $v = $saved.$n }
        if ($null -eq $v) { $v = $Defaults[$n] }
        $mode = 'Manual'
        if ([int]$v -eq 2) { $mode = 'Automatic' }
        Set-Service -Name $n -StartupType $mode -ErrorAction SilentlyContinue
    }
    $script:Backup.state.Remove($StateKey)
}

$script:TelemetryTasks = @(
    @('\Microsoft\Windows\Application Experience\', 'Microsoft Compatibility Appraiser'),
    @('\Microsoft\Windows\Application Experience\', 'ProgramDataUpdater'),
    @('\Microsoft\Windows\Customer Experience Improvement Program\', 'Consolidator'),
    @('\Microsoft\Windows\Customer Experience Improvement Program\', 'UsbCeip'),
    @('\Microsoft\Windows\DiskDiagnostic\', 'Microsoft-Windows-DiskDiagnosticDataCollector'),
    @('\Microsoft\Windows\Feedback\Siuf\', 'DmClient'),
    @('\Microsoft\Windows\Feedback\Siuf\', 'DmClientOnScenarioDownload')
)

function Get-TelemetryTasks {
    foreach ($t in $script:TelemetryTasks) {
        Get-ScheduledTask -TaskPath $t[0] -TaskName $t[1] -ErrorAction SilentlyContinue
    }
}

function Format-Bytes([int64]$Bytes) {
    if ($Bytes -ge 1GB) { return ('{0:N1} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -lt 1MB) { return 'menos de 1 MB' }
    return ('{0:N0} MB' -f ($Bytes / 1MB))
}

# Trabalho demorado roda em segundo plano para a janela nao congelar.
function Invoke-Background([string]$Code, [hashtable]$Arguments) {
    $ps = [powershell]::Create()
    $out = @()
    try {
        [void]$ps.AddScript($Code)
        if ($Arguments) { [void]$ps.AddParameters($Arguments) }
        $async = $ps.BeginInvoke()
        while (-not $async.IsCompleted) { Update-Ui 'Background'; Start-Sleep -Milliseconds 40 }
        $out = @($ps.EndInvoke($async))
    } catch {
        Write-Log "Segundo plano falhou: $($_.Exception.Message)"
    } finally { $ps.Dispose() }
    return $out
}

$script:BloatCode = @'
param([string[]]$Names)
$ProgressPreference = 'SilentlyContinue'
$errors = @{}
$families = @{}
function Get-Listed([string[]]$Types) {
    @(Get-AppxPackage -AllUsers -PackageTypeFilter $Types -ErrorAction SilentlyContinue | Where-Object { $Names -contains $_.Name })
}
# So conta como instalado o que algum usuario realmente tem; pacote apenas guardado no disco ("Staged") nao aparece no menu Iniciar.
function Get-InstalledUsers($p) {
    @($p.PackageUserInformation | Where-Object { $_ -and ([string]$_.InstallState) -eq 'Installed' })
}
function Get-Present {
    $set = @{}
    foreach ($p in (Get-Listed @('Main'))) { if ((Get-InstalledUsers $p).Count -gt 0) { $set[[string]$p.Name] = $true } }
    $set
}
function Note-Error([string]$Name, $Err) {
    $m = ([string]$Err.Exception.Message -split "`r?`n")[0]
    if ($m.Length -gt 220) { $m = $m.Substring(0, 220) }
    $errors[$Name] = $m
}

$before = Get-Present
foreach ($p in (Get-Listed @('Main', 'Bundle'))) { if ($p.PackageFamilyName) { $families[[string]$p.PackageFamilyName] = $true } }

# 1) Para todos os usuarios, pelo pacote "pai". Quase todo app da Loja vem em um pacote do tipo Bundle,
#    e o Windows so aceita a remocao para todos quando ela e pedida pelo Bundle.
foreach ($p in (Get-Listed @('Bundle'))) {
    try { Remove-AppxPackage -Package $p.PackageFullName -AllUsers -ErrorAction Stop } catch { Note-Error ([string]$p.Name) $_ }
}
# 2) Apps que nao vem em Bundle: o pacote principal e o proprio "pai".
foreach ($p in (Get-Listed @('Main'))) {
    if ((Get-InstalledUsers $p).Count -eq 0) { continue }
    try { Remove-AppxPackage -Package $p.PackageFullName -AllUsers -ErrorAction Stop } catch { Note-Error ([string]$p.Name) $_ }
}
# 3) O que sobrou sai usuario por usuario.
foreach ($p in (Get-Listed @('Main'))) {
    foreach ($u in (Get-InstalledUsers $p)) {
        $sid = [string]$u.UserSecurityId.Sid
        if (-not $sid) { continue }
        try { Remove-AppxPackage -Package $p.PackageFullName -User $sid -ErrorAction Stop } catch { Note-Error ([string]$p.Name) $_ }
    }
}
# 4) Tira tambem o instalador que fica guardado no Windows, para o app nao ser recolocado em contas novas.
try {
    $prov = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop | Where-Object { $Names -contains $_.DisplayName })
    foreach ($p in $prov) {
        $parts = ([string]$p.PackageName).Split('_')
        if ($parts.Count -ge 2) { $families[$parts[0] + '_' + $parts[$parts.Count - 1]] = $true }
        if (-not $before.ContainsKey([string]$p.DisplayName)) { $before[[string]$p.DisplayName] = $true }
        try { Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName -ErrorAction Stop | Out-Null } catch { Note-Error ([string]$p.DisplayName) $_ }
    }
} catch { }
# 5) Marca cada app como "desprovisionado": e o aviso oficial para o Windows nao reinstalar nas atualizacoes de versao.
$key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned'
foreach ($f in $families.Keys) {
    try { if (-not (Test-Path -LiteralPath "$key\$f")) { New-Item -Path "$key\$f" -Force | Out-Null } } catch { }
}
# 6) Confere de verdade: so conta como removido o que nenhum usuario tem mais.
$after = Get-Present
foreach ($n in $before.Keys) {
    if ($after.ContainsKey($n)) { "FAIL|$n|$($errors[$n])" } else { "OK|$n" }
}
'@

# Store, Xbox e Game Bar ficam sempre: tem gente que usa, e muitos jogos dependem deles.
$script:AppsKeep = @('Microsoft.WindowsStore', 'Microsoft.StorePurchaseApp', 'Microsoft.DesktopAppInstaller', 'Microsoft.GamingApp', 'Microsoft.XboxApp',
    'Microsoft.XboxGamingOverlay', 'Microsoft.XboxGameOverlay', 'Microsoft.XboxIdentityProvider', 'Microsoft.XboxSpeechToTextOverlay',
    'Microsoft.Xbox.TCUI', 'Microsoft.GamingServices', 'Microsoft.XboxGameCallableUI')

function Remove-Bloat([string[]]$Names) {
    $Names = @($Names | Where-Object { $script:AppsKeep -notcontains $_ })
    $lines = @(Invoke-Background $script:BloatCode @{ Names = $Names })
    $removed = @(); $failed = @()
    foreach ($l in $lines) {
        $f = ([string]$l).Split('|', 3)
        if ($f[0] -eq 'OK') { $removed += $f[1]; Write-Log "App removido: $($f[1])" }
        elseif ($f[0] -eq 'FAIL') { $failed += $f[1]; Write-Log "App NAO removido: $($f[1]) -> $($f[2])" }
    }
    # Sem isto o Windows reinstala sozinho os apps patrocinados: liga o ajuste que bloqueia.
    $ads = $script:TweakById['ads']
    if ($ads -and -not (Test-Tweak $ads)) {
        try { Enable-Tweak $ads; Write-Log 'Reinstalacao automatica de apps bloqueada' } catch { Write-Log "Bloqueio de reinstalacao: $($_.Exception.Message)" }
    }
    $ok = if ($removed.Count -eq 1) { '1 app removido' } else { (Tx '{0} apps removidos' $removed.Count) }
    if ($failed.Count -gt 0) {
        $bad = if ($failed.Count -eq 1) { '1 não saiu' } else { (Tx '{0} não saíram' $failed.Count) }
        if ($removed.Count -eq 0) { return (Tx '{0} (o motivo está no log)' (Tr $bad)) }
        return (Tx '{0}, {1} (o motivo está no log)' (Tr $ok) (Tr $bad))
    }
    if ($removed.Count -eq 0) { return 'Nada para remover' }
    return $ok
}

# ---------------------------------------------------------------------------
#  Apps pre-instalados que a pessoa pode escolher remover (tela Apps)
#  Rec = ja vem marcado. A Microsoft Store, o app Xbox e as pecas do Xbox que os jogos usam (login, Game Bar, servicos)
#  nao entram na lista de proposito: sem elas, jogos e a propria reinstalacao de apps param de funcionar.
# ---------------------------------------------------------------------------
$script:AppCatalog = @(
    @{ Id = 'bing';       Rec = $true;  Label = 'Notícias, Finanças e Esportes do Bing'; Note = 'Apps de conteúdo da Microsoft que vêm no Windows.'
       Names = @('Microsoft.BingNews', 'Microsoft.News', 'Microsoft.BingFinance', 'Microsoft.BingSports', 'Microsoft.BingSearch') }
    @{ Id = 'solitaire';  Rec = $true;  Label = 'Paciência (Solitaire Collection)'; Note = 'Jogo de cartas com anúncios.'; Names = @('Microsoft.MicrosoftSolitaireCollection') }
    @{ Id = 'clipchamp';  Rec = $true;  Label = 'Clipchamp'; Note = 'Editor de vídeo da Microsoft.'; Names = @('Clipchamp.Clipchamp') }
    @{ Id = 'officehub';  Rec = $true;  Label = 'Microsoft 365 (hub do Office)'; Note = 'É só a vitrine. Word, Excel e os outros programas do Office instalados não são tocados.'; Names = @('Microsoft.MicrosoftOfficeHub') }
    @{ Id = 'tips';       Rec = $true;  Label = 'Dicas'; Note = 'Tutoriais do Windows.'; Names = @('Microsoft.Getstarted') }
    @{ Id = 'feedback';   Rec = $true;  Label = 'Hub de Comentários'; Note = 'Envio de sugestões para a Microsoft.'; Names = @('Microsoft.WindowsFeedbackHub') }
    @{ Id = 'skype';      Rec = $true;  Label = 'Skype'; Note = 'A Microsoft encerrou o Skype em 2025.'; Names = @('Microsoft.SkypeApp') }
    @{ Id = 'cortana';    Rec = $true;  Label = 'Cortana'; Note = 'Assistente que a Microsoft descontinuou.'; Names = @('Microsoft.549981C3F5F10') }
    @{ Id = 'copilotapp'; Rec = $true;  Label = 'App do Copilot'; Note = 'O assistente de IA da Microsoft. Dá para usar pelo navegador se precisar.'; Names = @('Microsoft.Copilot', 'Microsoft.Windows.Ai.Copilot.Provider') }
    @{ Id = 'people';     Rec = $true;  Label = 'Pessoas e Mensagens'; Note = 'Apps antigos de contatos e SMS.'; Names = @('Microsoft.People', 'Microsoft.Messaging') }
    @{ Id = 'maps';       Rec = $true;  Label = 'Mapas'; Note = 'A Microsoft descontinuou o app.'; Names = @('Microsoft.WindowsMaps') }
    @{ Id = 'mobile';     Rec = $true;  Label = 'Planos Móveis e Carteira'; Note = 'Venda de planos de dados e a carteira antiga da Microsoft.'; Names = @('Microsoft.OneConnect', 'Microsoft.Wallet') }
    @{ Id = 'threed';     Rec = $true;  Label = 'Visualizador 3D, 3D Builder e Print 3D'; Note = 'Apps de modelos 3D.'; Names = @('Microsoft.Microsoft3DViewer', 'Microsoft.3DBuilder', 'Microsoft.Print3D') }
    @{ Id = 'mixed';      Rec = $true;  Label = 'Portal de Realidade Misturada'; Note = 'Só serve para os óculos Windows Mixed Reality.'; Names = @('Microsoft.MixedReality.Portal') }
    @{ Id = 'automate';   Rec = $true;  Label = 'Power Automate'; Note = 'Automação de tarefas de escritório.'; Names = @('Microsoft.PowerAutomateDesktop') }
    @{ Id = 'devhome';    Rec = $true;  Label = 'Dev Home'; Note = 'Painel para programadores.'; Names = @('Microsoft.Windows.DevHome') }
    @{ Id = 'journal';    Rec = $true;  Label = 'Microsoft Journal'; Note = 'Caderno para caneta digital.'; Names = @('Microsoft.MicrosoftJournal') }
    @{ Id = 'candy';      Rec = $true;  Label = 'Candy Crush'; Note = 'Jogo patrocinado.'; Names = @('king.com.CandyCrushSaga', 'king.com.CandyCrushSodaSaga') }
    @{ Id = 'tiktok';     Rec = $true;  Label = 'TikTok'; Note = 'App patrocinado.'; Names = @('BytedancePte.Ltd.TikTok') }
    @{ Id = 'disney';     Rec = $true;  Label = 'Disney+'; Note = 'App patrocinado.'; Names = @('Disney.37853FC22B2CE') }
    @{ Id = 'linkedin';   Rec = $true;  Label = 'LinkedIn'; Note = 'App patrocinado.'; Names = @('7EE7776C.LinkedInforWindows') }

    @{ Id = 'weather';    Rec = $false; Label = 'Clima'; Note = 'Previsão do tempo.'; Names = @('Microsoft.BingWeather') }
    @{ Id = 'mail';       Rec = $false; Label = 'Email e Calendário'; Note = 'Os apps antigos de email e agenda do Windows.'; Names = @('microsoft.windowscommunicationsapps') }
    @{ Id = 'outlook';    Rec = $false; Label = 'Outlook (novo)'; Note = 'O app de email que substituiu o Email e Calendário.'; Names = @('Microsoft.OutlookForWindows') }
    @{ Id = 'teams';      Rec = $false; Label = 'Microsoft Teams'; Note = 'Se você usa o Teams no trabalho ou na escola, deixe.'; Names = @('MicrosoftTeams', 'MSTeams') }
    @{ Id = 'onenote';    Rec = $false; Label = 'OneNote'; Note = 'Bloco de anotações da Microsoft.'; Names = @('Microsoft.Office.OneNote') }
    @{ Id = 'phone';      Rec = $false; Label = 'Vincular ao Celular'; Note = 'Mostra notificações e fotos do celular no PC.'; Names = @('Microsoft.YourPhone') }
    @{ Id = 'todo';       Rec = $false; Label = 'Microsoft To Do'; Note = 'Lista de tarefas.'; Names = @('Microsoft.Todos') }
    @{ Id = 'sticky';     Rec = $false; Label = 'Notas Autoadesivas'; Note = 'As notas que você já escreveu somem do PC junto com o app.'; Names = @('Microsoft.MicrosoftStickyNotes') }
    @{ Id = 'paint3d';    Rec = $false; Label = 'Paint 3D'; Note = 'Não é o Paint comum, que continua.'; Names = @('Microsoft.MSPaint') }
    @{ Id = 'movies';     Rec = $false; Label = 'Filmes e TV'; Note = 'No Windows 10 é o player de vídeo padrão.'; Names = @('Microsoft.ZuneVideo') }
    @{ Id = 'music';      Rec = $false; Label = 'Media Player (Groove Música)'; Note = 'No Windows 11 é o player de música e vídeo padrão.'; Names = @('Microsoft.ZuneMusic') }
    @{ Id = 'photos';     Rec = $false; Label = 'Fotos'; Note = 'É o visualizador de imagens padrão. Sem ele, as imagens abrem em outro programa.'; Names = @('Microsoft.Windows.Photos') }
    @{ Id = 'calc';       Rec = $false; Label = 'Calculadora'; Note = 'A calculadora do Windows.'; Names = @('Microsoft.WindowsCalculator') }
    @{ Id = 'camera';     Rec = $false; Label = 'Câmera'; Note = 'App da webcam.'; Names = @('Microsoft.WindowsCamera') }
    @{ Id = 'alarms';     Rec = $false; Label = 'Relógio e Alarmes'; Note = 'Alarmes, cronômetro e sessões de foco.'; Names = @('Microsoft.WindowsAlarms') }
    @{ Id = 'recorder';   Rec = $false; Label = 'Gravador de Som'; Note = 'Gravação de áudio pelo microfone.'; Names = @('Microsoft.WindowsSoundRecorder') }
    @{ Id = 'gethelp';    Rec = $false; Label = 'Obter Ajuda'; Note = 'No Windows 11 as soluções de problemas das Configurações abrem por ele.'; Names = @('Microsoft.GetHelp') }
    @{ Id = 'quick';      Rec = $false; Label = 'Assistência Rápida'; Note = 'Suporte remoto entre dois PCs.'; Names = @('MicrosoftCorporationII.QuickAssist') }
    @{ Id = 'family';     Rec = $false; Label = 'Microsoft Family'; Note = 'Controle dos pais.'; Names = @('MicrosoftCorporationII.MicrosoftFamily') }
)

# O que esta marcado para sair: a escolha salva da pessoa ou, sem escolha, o padrao do catalogo.
function Get-AppPicks {
    $ov = ConvertTo-Hashtable $script:Backup.state['appsPick']
    $out = @{}
    foreach ($a in $script:AppCatalog) { $out[$a.Id] = if ($ov.ContainsKey($a.Id)) { [bool]$ov[$a.Id] } else { [bool]$a.Rec } }
    return $out
}

function Set-AppPick([string]$Id, [bool]$On) {
    $ov = ConvertTo-Hashtable $script:Backup.state['appsPick']
    $ov[$Id] = $On
    $script:Backup.state['appsPick'] = $ov
    Save-Backup
}

# Nomes de pacote dos apps marcados. Com $Only, so os que tambem estao naquela lista de ids.
function Get-AppNamesToRemove([string[]]$Only) {
    $picks = Get-AppPicks
    $names = @()
    foreach ($a in $script:AppCatalog) {
        if (-not $picks[$a.Id]) { continue }
        if ($Only -and $Only -notcontains $a.Id) { continue }
        $names += $a.Names
    }
    return @($names)
}

# Itens do catalogo que tem algum pacote na lista de instalados.
function Get-CatalogInstalled([string[]]$Installed) {
    return @($script:AppCatalog | Where-Object { $a = $_; @($a.Names | Where-Object { $Installed -contains $_ }).Count -gt 0 })
}

# Lista os apps instalados para algum usuario do PC.
$script:AppScanCode = @'
$ProgressPreference = 'SilentlyContinue'
Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | ForEach-Object {
    if (@($_.PackageUserInformation | Where-Object { $_ -and ([string]$_.InstallState) -eq 'Installed' }).Count -gt 0) { [string]$_.Name }
}
'@

# Limpeza de componentes do Windows. Devolve "codigo de saida|bytes liberados no disco do sistema".
$script:DismCode = @'
$drive = ([string]$env:SystemDrive).TrimEnd(':')
$before = [int64]0; $after = [int64]0
try { $before = [int64](Get-PSDrive -Name $drive -ErrorAction Stop).Free } catch { }
$code = -1
try {
    $p = Start-Process -FilePath (Join-Path $env:WINDIR 'System32\Dism.exe') -ArgumentList '/Online /Cleanup-Image /StartComponentCleanup' -WindowStyle Hidden -Wait -PassThru
    $code = $p.ExitCode
} catch { }
try { $after = [int64](Get-PSDrive -Name $drive -ErrorAction Stop).Free } catch { }
"$code|$($after - $before)"
'@

# Apaga o conteudo das pastas sem seguir atalhos de pasta (junctions) e devolve os bytes liberados.
$script:CleanCode = @'
param([string[]]$Paths)
$script:Freed = [int64]0
function Remove-Tree([string]$Path) {
    try {
        $attr = [IO.File]::GetAttributes($Path)
        if ($attr -band [IO.FileAttributes]::Directory) {
            if (-not ($attr -band [IO.FileAttributes]::ReparsePoint)) {
                foreach ($c in [IO.Directory]::GetFileSystemEntries($Path)) { Remove-Tree $c }
            }
            [IO.Directory]::Delete($Path, $false)
        } else {
            $len = ([IO.FileInfo]$Path).Length
            if ($attr -band [IO.FileAttributes]::ReadOnly) { [IO.File]::SetAttributes($Path, [IO.FileAttributes]::Normal) }
            [IO.File]::Delete($Path)
            $script:Freed += $len
        }
    } catch { }
}
foreach ($p in $Paths) {
    if ([string]::IsNullOrWhiteSpace($p) -or $p.Length -lt 8) { continue }
    if (-not (Test-Path -LiteralPath $p -PathType Container)) { continue }
    try { $items = [IO.Directory]::GetFileSystemEntries($p) } catch { continue }
    foreach ($c in $items) { Remove-Tree $c }
}
$script:Freed
'@

function Invoke-Cleanup([string[]]$Paths) {
    $r = @(Invoke-Background $script:CleanCode @{ Paths = $Paths })
    $freed = [int64]0
    if ($r.Count -gt 0) { $freed = [int64]$r[$r.Count - 1] }
    Write-Log "Limpeza: $freed bytes"
    if ($freed -lt 1MB) { return 'Já estava limpo' }
    return (Tx '{0} liberados' (Format-Bytes $freed))
}

$script:RestoreCode = @'
$ProgressPreference = 'SilentlyContinue'
$key  = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
$name = 'SystemRestorePointCreationFrequency'
$old  = $null
try { $old = (Get-ItemProperty -LiteralPath $key -Name $name -ErrorAction Stop).$name } catch { }
try {
    Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
    Set-ItemProperty -LiteralPath $key -Name $name -Value 0 -Type DWord -ErrorAction SilentlyContinue
    Checkpoint-Computer -Description 'Harle Optimizer' -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop -WarningAction SilentlyContinue
    'ok'
} catch {
    'erro: ' + $_.Exception.Message
} finally {
    if ($null -ne $old) { Set-ItemProperty -LiteralPath $key -Name $name -Value $old -Type DWord -ErrorAction SilentlyContinue }
    else { Remove-ItemProperty -LiteralPath $key -Name $name -ErrorAction SilentlyContinue }
}
'@

function New-RestorePoint {
    $r = @(Invoke-Background $script:RestoreCode $null)
    $last = if ($r.Count -gt 0) { [string]$r[$r.Count - 1] } else { 'sem resposta' }
    Write-Log "Ponto de restauracao: $last"
    return ($last -eq 'ok')
}

function ConvertTo-Hashtable($Object) {
    if ($Object -is [hashtable]) { return $Object }
    $h = @{}
    if ($null -ne $Object) { foreach ($p in $Object.PSObject.Properties) { $h[$p.Name] = $p.Value } }
    return $h
}

# ---------------------------------------------------------------------------
#  Perfis globais do driver de video (so no Harle.exe): NVIDIA pela NVAPI, AMD pela ADL
#  IDs conferidos em NvApiDriverSettings.h e na referencia do NVIDIA Profile Inspector.
# ---------------------------------------------------------------------------
$script:NvSettings = @(
    @{ Id = 0x1057EB71; V = 1 },                # energia: preferir desempenho maximo
    @{ Id = 0x007BA09E; V = 1 },                # latencia baixa: no maximo 1 quadro na fila
    @{ Id = 0x0005F543; V = 1; Soft = $true },  # estado que o Painel mostra: "Ativado"
    @{ Id = 0x00CE2691; V = 20 }                # filtro de textura: alto desempenho
)

function Test-Nvidia {
    if ($null -eq $script:HasNvidia) {
        $script:HasNvidia = $false
        if ($script:Hosted) { try { $script:HasNvidia = [bool][Harle.Nvidia]::Available() } catch { } }
    }
    return $script:HasNvidia
}

function Test-Amd {
    if ($null -eq $script:HasAmd) {
        $script:HasAmd = $false
        if ($script:Hosted) { try { $script:HasAmd = [bool][Harle.Amd]::Available() } catch { } }
    }
    return $script:HasAmd
}

function Test-AmdProfile {
    $r = [Harle.Amd]::Read()
    return ($r[0] -eq 0 -and $r[1] -eq 1 -and $r[2] -eq 0)
}

function Set-AmdProfile {
    if (-not $script:Backup.state['amd']) {
        $r = [Harle.Amd]::Read()
        if ($r[0] -eq 0) { $script:Backup.state['amd'] = @{ AntiLag = [int]$r[1]; Chill = [int]$r[2] } }
    }
    $st = [Harle.Amd]::Apply(1, 0)
    if ($st -ne 0) { Write-Log "AMD nao gravou: codigo $st $([Harle.Amd]::LastError)" }
}

function Restore-AmdProfile {
    $b = $script:Backup.state['amd']
    if ($b) { [void][Harle.Amd]::Apply([int]$b.AntiLag, [int]$b.Chill) } else { [void][Harle.Amd]::Apply(0, 0) }
    $script:Backup.state.Remove('amd')
}

function Test-NvProfile {
    foreach ($n in $script:NvSettings) {
        $r = [Harle.Nvidia]::Read($n.Id)
        if ($r[0] -ne 0) { if ($n.Soft) { continue } else { return $false } }
        if ([int64]$r[1] -ne [int64]$n.V) { return $false }
    }
    return $true
}

function Set-NvProfile {
    $saved = ConvertTo-Hashtable $script:Backup.state['nv']
    foreach ($n in $script:NvSettings) {
        $key = [string]$n.Id
        if (-not $saved.ContainsKey($key)) {
            $r = [Harle.Nvidia]::Read($n.Id)
            $saved[$key] = @{ Custom = ($r[0] -eq 0 -and $r[2] -eq 0); Value = [int64]$r[1] }
        }
        $st = [Harle.Nvidia]::Write($n.Id, $n.V)
        if ($st -ne 0) { Write-Log "NVIDIA $key nao gravou: codigo $st $([Harle.Nvidia]::LastError)" }
    }
    $script:Backup.state['nv'] = $saved
}

function Restore-NvProfile {
    $saved = ConvertTo-Hashtable $script:Backup.state['nv']
    foreach ($n in $script:NvSettings) {
        $b = $saved[[string]$n.Id]
        if ($b -and $b.Custom) { [void][Harle.Nvidia]::Write($n.Id, [uint32]$b.Value) }
        else                   { [void][Harle.Nvidia]::Reset($n.Id) }
    }
    $script:Backup.state.Remove('nv')
}

# ---------------------------------------------------------------------------
#  Medicao
# ---------------------------------------------------------------------------
function Get-Load {
    $os = Get-CimInstance Win32_OperatingSystem
    return @{
        RamMB = [int](($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1024)
        Procs = @(Get-Process).Count
        When  = (Get-Date).ToString('dd/MM/yyyy HH:mm')
    }
}

function Format-Load($l) {
    if (-not $l) { return '' }
    return ((Tx '{0:N1} GB em uso, {1} processos') -f ([double]$l.RamMB / 1024), [int]$l.Procs)
}

# Extrai um arquivo embutido no Harle.exe para Program Files\Harle e devolve o caminho.
function Get-AssetPath([string]$Name) {
    $dir = Split-Path -Parent $script:GuardExe
    $dst = Join-Path $dir $Name
    $stream = [Harle.Native].Assembly.GetManifestResourceStream($Name)
    if (-not $stream) { throw "Arquivo embutido ausente: $Name" }
    try {
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        if (-not (Test-Path -LiteralPath $dst) -or (Get-Item -LiteralPath $dst).Length -ne $stream.Length) {
            $fs = [IO.File]::Create($dst)
            try { $stream.CopyTo($fs) } finally { $fs.Dispose() }
        }
    } finally { $stream.Dispose() }
    return $dst
}

# Le o CSV do PresentMon e devolve FPS medio e 1% low do programa que mais apresentou quadros.
$script:FpsIgnore = @('dwm.exe', 'explorer.exe', 'Harle.exe', 'ApplicationFrameHost.exe', 'SearchHost.exe', 'StartMenuExperienceHost.exe',
                      'ShellExperienceHost.exe', 'TextInputHost.exe', 'chrome.exe', 'msedge.exe', 'firefox.exe', 'opera.exe', 'brave.exe',
                      'msedgewebview2.exe', 'Discord.exe', 'steamwebhelper.exe', 'NVIDIA Overlay.exe', 'NVIDIA app.exe', 'WidgetBoard.exe')

function Get-FrameStats([string]$CsvPath) {
    if (-not (Test-Path -LiteralPath $CsvPath)) { return $null }
    $rows = @(Import-Csv -LiteralPath $CsvPath)
    if ($rows.Count -eq 0) { return $null }
    $col = @($rows[0].PSObject.Properties.Name | Where-Object { $_ -match '^(MsBetweenPresents|FrameTime)$' })[0]
    if (-not $col) { return $null }
    $best = $rows | Where-Object { $script:FpsIgnore -notcontains $_.Application } | Group-Object Application | Sort-Object Count -Descending | Select-Object -First 1
    if (-not $best -or $best.Count -lt 120) { return $null }
    $ci = [Globalization.CultureInfo]::InvariantCulture
    $ms = New-Object 'System.Collections.Generic.List[double]'
    $sum = 0.0
    foreach ($r in $best.Group) {
        $v = 0.0
        if ([double]::TryParse([string]$r.$col, [Globalization.NumberStyles]::Float, $ci, [ref]$v) -and $v -gt 0) { $ms.Add($v); $sum += $v }
    }
    if ($ms.Count -lt 120 -or $sum -le 0) { return $null }
    $ms.Sort()
    $p99 = $ms[[Math]::Min($ms.Count - 1, [int][Math]::Floor($ms.Count * 0.99))]
    return @{
        App    = [string]$best.Name
        Frames = $ms.Count
        Avg    = [Math]::Round(1000.0 * $ms.Count / $sum, 1)
        Low    = [Math]::Round(1000.0 / $p99, 1)
    }
}

# ---------------------------------------------------------------------------
#  Programas de inicializacao (o mesmo liga/desliga do Gerenciador de Tarefas)
# ---------------------------------------------------------------------------
function Get-RegValues([string]$Path) {
    $h = @{}
    $k = $null
    try {
        $k = Open-RegKey $Path
        if ($k) { foreach ($n in $k.GetValueNames()) { $h[$n] = $k.GetValue($n, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) } }
    } catch { } finally { if ($k) { $k.Close() } }
    return $h
}

function Get-CommandExe([string]$Command) {
    $c = [Environment]::ExpandEnvironmentVariables($Command).Trim()
    if ($c -match '^"([^"]+)"') { return $Matches[1] }
    if ($c -match '^(.+?\.exe)(\s|$)') { return $Matches[1] }
    return ($c -split '\s+')[0]
}

function Test-StartupEnabled([string]$Approved, [string]$Key) {
    $s = Get-RegState $Approved $Key
    if (-not $s.Exists) { return $true }
    $b = @($s.Value)
    if ($b.Count -eq 0) { return $true }
    return (([int]$b[0] -band 1) -eq 0)
}

function Set-StartupEnabled([string]$Approved, [string]$Key, [bool]$On) {
    $bytes = New-Object byte[] 12
    if ($On) { $bytes[0] = 2 }
    else {
        $bytes[0] = 3
        [Array]::Copy([BitConverter]::GetBytes([DateTime]::UtcNow.ToFileTimeUtc()), 0, $bytes, 4, 8)
    }
    Set-RegValue $Approved $Key $bytes 'Binary'
}

function Get-StartupItems {
    $cv = 'SOFTWARE\Microsoft\Windows\CurrentVersion'
    $items = @()
    $sources = @(
        @{ Run = "HKCU\$cv\Run"; Appr = "HKCU\$cv\Explorer\StartupApproved\Run" },
        @{ Run = "HKLM\$cv\Run"; Appr = "HKLM\$cv\Explorer\StartupApproved\Run" },
        @{ Run = "HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run"; Appr = "HKLM\$cv\Explorer\StartupApproved\Run32" }
    )
    foreach ($s in $sources) {
        $vals = Get-RegValues $s.Run
        foreach ($n in $vals.Keys) {
            if (-not $n) { continue }
            $items += @{ Name = [string]$n; Key = [string]$n; Appr = $s.Appr; Exe = (Get-CommandExe ([string]$vals[$n])) }
        }
    }
    $folders = @(
        @{ Dir = [Environment]::GetFolderPath('Startup');       Appr = "HKCU\$cv\Explorer\StartupApproved\StartupFolder" },
        @{ Dir = [Environment]::GetFolderPath('CommonStartup'); Appr = "HKLM\$cv\Explorer\StartupApproved\StartupFolder" }
    )
    foreach ($f in $folders) {
        if (-not $f.Dir -or -not (Test-Path -LiteralPath $f.Dir)) { continue }
        foreach ($file in @(Get-ChildItem -LiteralPath $f.Dir -File -ErrorAction SilentlyContinue)) {
            if ($file.Name -eq 'desktop.ini') { continue }
            $exe = $file.FullName
            if ($file.Extension -eq '.lnk') {
                try { $t = (New-Object -ComObject WScript.Shell).CreateShortcut($file.FullName).TargetPath; if ($t) { $exe = $t } } catch { }
            }
            $items += @{ Name = $file.BaseName; Key = $file.Name; Appr = $f.Appr; Exe = $exe }
        }
    }
    foreach ($i in $items) {
        $i.Enabled = Test-StartupEnabled $i.Appr $i.Key
        $i.Title = $i.Name
        $i.RamMB = 0
        try {
            if ($i.Exe -and (Test-Path -LiteralPath $i.Exe)) {
                $d = [Diagnostics.FileVersionInfo]::GetVersionInfo($i.Exe).FileDescription
                if ($d -and $d.Trim()) { $i.Title = $d.Trim() }
                $pn = [IO.Path]::GetFileNameWithoutExtension($i.Exe)
                if ('rundll32', 'cmd', 'powershell', 'wscript', 'cscript', 'explorer', 'msiexec' -notcontains $pn) {
                    $sum = (Get-Process -Name $pn -ErrorAction SilentlyContinue | Measure-Object WorkingSet64 -Sum).Sum
                    if ($sum) { $i.RamMB = [int]($sum / 1MB) }
                }
            }
        } catch { }
    }
    return @($items | Sort-Object { $_.Title })
}

# ---------------------------------------------------------------------------
#  Modo partida: o que pode ser fechado
# ---------------------------------------------------------------------------
# nome do processo = rotulo, fecha por padrao?
$script:PlayKnown = @{
    'chrome'  = @('Google Chrome', $true);   'msedge'  = @('Microsoft Edge', $true); 'firefox' = @('Firefox', $true)
    'opera'   = @('Opera', $true);           'brave'   = @('Brave', $true);          'vivaldi' = @('Vivaldi', $true)
    'ms-teams' = @('Microsoft Teams', $true); 'Teams'  = @('Microsoft Teams', $true)
    'OneDrive' = @('OneDrive', $true);       'PhoneExperienceHost' = @('Vincular ao Celular', $true)
    'Creative Cloud' = @('Adobe Creative Cloud', $true)
    'Discord' = @('Discord', $false);        'Spotify' = @('Spotify', $false)
    'steam'   = @('Steam', $false);          'EpicGamesLauncher' = @('Epic Games Launcher', $false)
    'Battle.net' = @('Battle.net', $false);  'EADesktop' = @('EA app', $false)
    'upc'     = @('Ubisoft Connect', $false); 'GalaxyClient' = @('GOG Galaxy', $false)
    'RiotClientServices' = @('Riot Client', $false)
}
$script:PlayIgnore = @('explorer', 'dwm', 'Harle', 'ApplicationFrameHost', 'SearchHost', 'StartMenuExperienceHost', 'ShellExperienceHost',
                       'LockApp', 'TextInputHost', 'SystemSettings', 'Taskmgr', 'powershell', 'WindowsTerminal', 'vlc', 'mpc-hc64',
                       'mpc-be64', 'PotPlayerMini64', 'Video.UI', 'NVIDIA app', 'NVIDIA Overlay')

# Recebe a lista de processos (ja filtrada para a sessao do usuario) e devolve os candidatos a fechar.
function Get-PlayCandidates($Processes, $Overrides) {
    $ov = ConvertTo-Hashtable $Overrides
    $out = @()
    foreach ($g in @($Processes | Group-Object ProcessName)) {
        $ram = [int64]0
        $window = $false
        foreach ($p in $g.Group) { $ram += [int64]$p.WorkingSet64; if ($p.MainWindowHandle -and $p.MainWindowHandle -ne [IntPtr]::Zero) { $window = $true } }
        $known = $script:PlayKnown[$g.Name]
        $label = $null; $default = $false
        if ($known) { $label = $known[0]; $default = [bool]$known[1] }
        elseif ($window -and $ram -ge 300MB -and ($script:PlayIgnore -notcontains $g.Name)) { $label = $g.Name }
        if (-not $label) { continue }
        $close = $default
        if ($ov.ContainsKey($g.Name)) { $close = [bool]$ov[$g.Name] }
        $out += @{ Name = [string]$g.Name; Label = $label; RamMB = [int]($ram / 1MB); Close = $close; Window = $window }
    }
    return @($out | Sort-Object { -$_.RamMB })
}

# ---------------------------------------------------------------------------
#  Copia do Harle.exe em Program Files (usada pelas tarefas do login) e ajudante do timer
# ---------------------------------------------------------------------------
function Test-HarleTask([string]$Name) { return [bool](Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue) }

function Test-HarleExe {
    if (-not (Test-Path -LiteralPath $script:GuardExe)) { return $false }
    $src = $env:HARLE_EXE
    if ($src -and $src -ne $script:GuardExe -and (Test-Path -LiteralPath $src)) {
        if ((Get-Item -LiteralPath $src).Length -ne (Get-Item -LiteralPath $script:GuardExe).Length) { return $false }
        return ((Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $script:GuardExe -Algorithm SHA256).Hash)
    }
    return $true
}

function Stop-TimerHelper {
    Get-CimInstance Win32_Process -Filter "Name='Harle.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match '/timer' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

function Start-TimerHelper {
    $running = @(Get-CimInstance Win32_Process -Filter "Name='Harle.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match '/timer' })
    if ($running.Count -eq 0 -and (Test-Path -LiteralPath $script:GuardExe)) { Start-Process -FilePath $script:GuardExe -ArgumentList '/timer' }
}

function Install-HarleExe {
    $dir = Split-Path -Parent $script:GuardExe
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $src = $env:HARLE_EXE
    if ($src -and $src -ne $script:GuardExe -and -not (Test-HarleExe)) {
        # O ajudante do timer roda a partir da copia; ele sai da frente para ela ser trocada.
        Stop-TimerHelper
        Start-Sleep -Milliseconds 400
        Copy-Item -LiteralPath $src -Destination $script:GuardExe -Force -ErrorAction SilentlyContinue
    }
    if (Test-HarleTask $script:TimerTask) { Start-TimerHelper }
}

function Remove-HarleExeIfUnused {
    if ((Test-HarleTask $script:GuardTask) -or (Test-HarleTask $script:TimerTask)) { return }
    if ($env:HARLE_EXE -eq $script:GuardExe) { return }
    $dir = Split-Path -Parent $script:GuardExe
    foreach ($f in 'Harle.exe', 'PresentMon.exe', 'PresentMon-LICENSE.txt') { Remove-Item -LiteralPath (Join-Path $dir $f) -Force -ErrorAction SilentlyContinue }
    if ((Test-Path -LiteralPath $dir) -and @(Get-ChildItem -LiteralPath $dir -Force).Count -eq 0) { Remove-Item -LiteralPath $dir -Force -ErrorAction SilentlyContinue }
}

function Register-HarleTask([string]$Name, [string]$Argument, [string]$Delay) {
    $user      = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $action    = New-ScheduledTaskAction -Execute $script:GuardExe -Argument $Argument
    $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $user
    if ($Delay) { $trigger.Delay = $Delay }
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
    # Limite zero = sem limite de tempo (o ajudante do timer fica ligado a sessao toda).
    $limit     = if ($Delay) { New-TimeSpan -Minutes 10 } else { [TimeSpan]::Zero }
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit $limit
    Register-ScheduledTask -TaskName $Name -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
}

# ---------------------------------------------------------------------------
#  Aviso de versao nova (GitHub Releases)
# ---------------------------------------------------------------------------
$script:UpdateCode = @'
param([string]$Repo)
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $r = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -Headers @{ 'User-Agent' = 'HarleOptimizer' } -TimeoutSec 8 -ErrorAction Stop
    $exe = @($r.assets | Where-Object { $_.name -eq 'Harle.exe' }) | Select-Object -First 1
    $sha = @($r.assets | Where-Object { $_.name -eq 'Harle.exe.sha256' }) | Select-Object -First 1
    "$($r.tag_name)|$($r.html_url)|$(if ($exe) { $exe.browser_download_url })|$(if ($sha) { $sha.browser_download_url })"
} catch { '' }
'@

# Atualizacao com um clique: baixa o Harle.exe e o .sha256 da Release, confere o SHA-256 e a versao gravada no exe.
# So devolve "ok" se as duas conferencias passarem; o arquivo baixado fica numa pasta temporaria.
$script:SelfUpdateCode = @'
param([string]$ExeUrl, [string]$ShaUrl, [string]$Version)
$ProgressPreference = 'SilentlyContinue'
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $dir = Join-Path ([IO.Path]::GetTempPath()) 'Harle-update'
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $h = @{ 'User-Agent' = 'HarleOptimizer' }
    $shaFile = Join-Path $dir 'Harle.exe.sha256'
    Invoke-WebRequest -Uri $ShaUrl -OutFile $shaFile -Headers $h -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
    $m = [regex]::Match([IO.File]::ReadAllText($shaFile), '[0-9a-fA-F]{64}')
    if (-not $m.Success) { 'erro|sha'; return }
    $exe = Join-Path $dir 'Harle.exe'
    Invoke-WebRequest -Uri $ExeUrl -OutFile $exe -Headers $h -UseBasicParsing -TimeoutSec 300 -ErrorAction Stop
    $got = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
    if ($got -ne $m.Value.ToUpperInvariant()) { "erro|hash|$got"; return }
    $fv = [string][Diagnostics.FileVersionInfo]::GetVersionInfo($exe).FileVersion
    if (-not $fv.StartsWith($Version)) { "erro|versao|$fv"; return }
    "ok|$exe|$got"
} catch { "erro|rede|$($_.Exception.Message)" }
'@

# Devolve o numero da versao nova (ex.: "3.1") se a etiqueta do GitHub for maior que a deste app; senao ''.
function Get-NewerVersion([string]$Tag) {
    $t = ([string]$Tag).Trim() -replace '^[vV]', ''
    if ($t -notmatch '^\d+(\.\d+){1,3}$') { return '' }
    try { if ([version]$t -gt [version]$script:AppVersion) { return $t } } catch { }
    return ''
}

# ---------------------------------------------------------------------------
#  Catalogo de ajustes
#  Impact: Alto / Medio / Baixo = quanto costuma pesar no desempenho em jogos.
#  Cada ajuste tem botao proprio na tela. Os perfis (Competitivo, Equilibrado, Notebook) ligam e desligam
#  conjuntos deles; Optional = fora do Equilibrado; Manual = nenhum perfil mexe. Entradas com Run sao acoes.
# ---------------------------------------------------------------------------
$CDM   = 'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
$MMCSS = 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
$WUX   = 'HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'

$script:Tweaks = @(
    # ---------------- Desempenho ----------------
    @{ Id = 'powerplan'; Cat = 'fps'; Impact = 'Médio'
       Name = 'Plano de energia de desempenho máximo'
       Desc = 'Cria e ativa um plano que mantém o processador em frequência alta e desliga a suspensão de USB e PCIe. Reduz quedas bruscas de FPS; gasta um pouco mais de energia com o PC parado.'
       Test = { (Get-ActivePlan).Guid -eq $script:HarlePlan }
       Apply = {
           $plan = $script:HarlePlan
           $cur = Get-ActivePlan
           if ($cur.Guid -and $cur.Guid -ne $plan -and -not $script:Backup.state['powerplan']) { $script:Backup.state['powerplan'] = $cur.Guid }
           if ((Invoke-Native 'powercfg.exe' '/list').Out -notmatch $plan) {
               $r = Invoke-Native 'powercfg.exe' "/duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 $plan"
               if ($r.Code -ne 0) { [void](Invoke-Native 'powercfg.exe' "/duplicatescheme 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c $plan") }
               [void](Invoke-Native 'powercfg.exe' "/changename $plan `"Harle - Desempenho maximo`" `"Criado pelo Harle Optimizer`"")
           }
           [void](Invoke-Native 'powercfg.exe' "/setacvalueindex $plan 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0")
           [void](Invoke-Native 'powercfg.exe' "/setacvalueindex $plan 501a4d13-42af-4429-9fd1-a8218c268e20 ee12f906-d277-404b-b6da-e5fa1a576df5 0")
           [void](Invoke-Native 'powercfg.exe' "/setactive $plan")
       }
       Revert = {
           $plan = $script:HarlePlan
           $balanced = '381b4222-f694-41f0-9685-ff5bb260df2e'
           $prev = $script:Backup.state['powerplan']
           if (-not $prev) { $prev = $balanced }
           [void](Invoke-Native 'powercfg.exe' "/setactive $prev")
           if ((Get-ActivePlan).Guid -eq $plan) { [void](Invoke-Native 'powercfg.exe' "/setactive $balanced") }
           [void](Invoke-Native 'powercfg.exe' "/delete $plan")
           $script:Backup.state.Remove('powerplan')
       } }

    @{ Id = 'gamemode'; Cat = 'fps'; Impact = 'Médio'
       Name = 'Modo de Jogo do Windows'
       Desc = 'Dá prioridade ao jogo em primeiro plano e impede o Windows Update de instalar drivers e pedir reinício enquanto você joga.'
       Reg = @(
           @{ P = 'HKCU\Software\Microsoft\GameBar'; N = 'AutoGameModeEnabled'; T = 'DWord'; V = 1 },
           @{ P = 'HKCU\Software\Microsoft\GameBar'; N = 'AllowAutoGameMode';   T = 'DWord'; V = 1 }
       ) }

    @{ Id = 'gamedvr'; Cat = 'fps'; Impact = 'Médio'
       Name = 'Desligar a gravação em segundo plano'
       Desc = 'Desliga só o "Gravar o que aconteceu" da Xbox Game Bar, que fica gravando os últimos minutos o tempo todo e ocupa GPU e disco. A Game Bar continua inteira: Win + G, capturas de tela e gravações quando você pedir.'
       Reg = @(
           @{ P = 'HKCU\Software\Microsoft\Windows\CurrentVersion\GameDVR'; N = 'HistoricalCaptureEnabled'; T = 'DWord'; V = 0; D = 0 }
       ) }

    @{ Id = 'hags'; Cat = 'fps'; Impact = 'Médio'; Reboot = $true
       Name = 'Agendamento de GPU acelerado por hardware'
       Desc = 'Passa o gerenciamento da fila de quadros do processador para a placa de vídeo. Pode reduzir a latência em placas de vídeo recentes.'
       Reg = @( @{ P = 'HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'; N = 'HwSchMode'; T = 'DWord'; V = 2; D = 1 } ) }

    @{ Id = 'winopt'; Cat = 'fps'; Impact = 'Médio'; MinBuild = 22000
       Name = 'Otimizações para jogos em janela'
       Desc = 'Faz jogos DirectX 10 e 11 em janela ou tela cheia sem bordas usarem o modo de apresentação moderno, com menos latência e suporte a taxa de atualização variável.'
       Test = {
           $s = Get-RegState 'HKCU\Software\Microsoft\DirectX\UserGpuPreferences' 'DirectXUserGlobalSettings'
           $s.Exists -and ([string]$s.Value -match 'SwapEffectUpgradeEnable=1')
       }
       Apply = {
           $p = 'HKCU\Software\Microsoft\DirectX\UserGpuPreferences'; $n = 'DirectXUserGlobalSettings'
           Backup-RegValue $p $n
           $s = Get-RegState $p $n
           $cur = ''
           if ($s.Exists) { $cur = [string]$s.Value }
           $cur = [regex]::Replace($cur, 'SwapEffectUpgradeEnable=\d;?', '')
           Set-RegValue $p $n ($cur + 'SwapEffectUpgradeEnable=1;') 'String'
       }
       Revert = {
           $p = 'HKCU\Software\Microsoft\DirectX\UserGpuPreferences'; $n = 'DirectXUserGlobalSettings'
           $s = Get-RegState $p $n
           if ($s.Exists) {
               $cur = [regex]::Replace([string]$s.Value, 'SwapEffectUpgradeEnable=\d;?', '')
               Set-RegValue $p $n ($cur + 'SwapEffectUpgradeEnable=0;') 'String'
           }
           $script:Backup.reg.Remove("$p|$n")
       } }

    # ---------------- Placa de video (vale o perfil da marca escolhida na tela) ----------------
    @{ Id = 'nvprofile'; Cat = 'gpu'; Impact = 'Médio'; Gpu = 'nvidia'
       Name = 'Perfil global da NVIDIA para desempenho'
       Desc = 'Ajusta o driver GeForce sem você abrir o painel: energia em desempenho máximo, modo de latência baixa ativado e filtro de textura em alto desempenho.'
       Test   = { Test-NvProfile }
       Apply  = { Set-NvProfile }
       Revert = { Restore-NvProfile } }

    @{ Id = 'amdprofile'; Cat = 'gpu'; Impact = 'Médio'; Gpu = 'amd'
       Name = 'Perfil global da AMD para desempenho'
       Desc = 'Ajusta o driver Radeon sem você abrir o Adrenalin: liga o Radeon Anti-Lag, que encurta o atraso entre o comando e a imagem, e desliga o Radeon Chill, que segura o FPS para economizar energia.'
       Test   = { Test-AmdProfile }
       Apply  = { Set-AmdProfile }
       Revert = { Restore-AmdProfile } }

    # ---------------- Registro ----------------
    @{ Id = 'mmcss'; Cat = 'reg'; Impact = 'Baixo'
       Name = 'Menos processador reservado para o sistema'
       Desc = 'O Windows guarda 20% do processador para tarefas de fundo enquanto há áudio ou vídeo tocando. Este ajuste baixa a reserva para 10% (SystemResponsiveness).'
       Reg = @( @{ P = $MMCSS; N = 'SystemResponsiveness'; T = 'DWord'; V = 10; D = 20 } ) }

    @{ Id = 'mmcssgames'; Cat = 'reg'; Impact = 'Baixo'
       Name = 'Prioridade alta para o perfil de jogos'
       Desc = 'Sobe a prioridade de processador, GPU e disco do perfil "Games" do agendador multimídia. Só vale para jogos que usam esse perfil.'
       Reg = @(
           @{ P = "$MMCSS\Tasks\Games"; N = 'GPU Priority';        T = 'DWord';  V = 8;      D = 8 },
           @{ P = "$MMCSS\Tasks\Games"; N = 'Priority';            T = 'DWord';  V = 6;      D = 2 },
           @{ P = "$MMCSS\Tasks\Games"; N = 'Scheduling Category'; T = 'String'; V = 'High'; D = 'Medium' },
           @{ P = "$MMCSS\Tasks\Games"; N = 'SFIO Priority';       T = 'String'; V = 'High'; D = 'Normal' }
       ) }

    @{ Id = 'throttle'; Cat = 'reg'; Impact = 'Baixo'
       Name = 'Desligar o freio de energia em processos'
       Desc = 'Impede o Windows de reduzir a frequência de programas que ele considera de fundo, como launchers e chat de voz abertos junto com o jogo.'
       Reg = @( @{ P = 'HKLM\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling'; N = 'PowerThrottlingOff'; T = 'DWord'; V = 1 } ) }

    @{ Id = 'mouseaccel'; Cat = 'reg'; Impact = 'Médio'; Reboot = $true
       Name = 'Desligar a aceleração do mouse'
       Desc = 'Não muda o FPS, muda a mira: o cursor passa a andar sempre a mesma distância para o mesmo movimento da mão. Vale a partir do próximo login.'
       Reg = @(
           @{ P = 'HKCU\Control Panel\Mouse'; N = 'MouseSpeed';      T = 'String'; V = '0'; D = '1' },
           @{ P = 'HKCU\Control Panel\Mouse'; N = 'MouseThreshold1'; T = 'String'; V = '0'; D = '6' },
           @{ P = 'HKCU\Control Panel\Mouse'; N = 'MouseThreshold2'; T = 'String'; V = '0'; D = '10' }
       ) }

    @{ Id = 'stickykeys'; Cat = 'reg'; Impact = 'Baixo'; Reboot = $true
       Name = 'Desligar os atalhos de Teclas de Aderência'
       Desc = 'Evita que apertar Shift cinco vezes, ou segurar uma tecla, abra um aviso do Windows e tire você do jogo.'
       Reg = @(
           @{ P = 'HKCU\Control Panel\Accessibility\StickyKeys';        N = 'Flags'; T = 'String'; V = '506'; D = '510' },
           @{ P = 'HKCU\Control Panel\Accessibility\Keyboard Response'; N = 'Flags'; T = 'String'; V = '122'; D = '126' },
           @{ P = 'HKCU\Control Panel\Accessibility\ToggleKeys';        N = 'Flags'; T = 'String'; V = '58';  D = '62' }
       ) }

    @{ Id = 'menudelay'; Cat = 'reg'; Impact = 'Baixo'; Reboot = $true
       Name = 'Menus sem atraso'
       Desc = 'Baixa de 400 ms para 50 ms a espera do Windows antes de abrir submenus. Deixa a navegação mais rápida, sem efeito em jogo.'
       Reg = @( @{ P = 'HKCU\Control Panel\Desktop'; N = 'MenuShowDelay'; T = 'String'; V = '50'; D = '400' } ) }

    @{ Id = 'startupdelay'; Cat = 'reg'; Impact = 'Baixo'
       Name = 'Programas de inicialização sem espera'
       Desc = 'Remove os segundos de atraso que o Windows coloca antes de abrir os programas configurados para iniciar junto com o sistema.'
       Reg = @( @{ P = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize'; N = 'StartupDelayInMSec'; T = 'DWord'; V = 0 } ) }

    @{ Id = 'faststartup'; Cat = 'reg'; Impact = 'Baixo'
       Name = 'Desligar a Inicialização Rápida'
       Desc = 'Faz o Windows iniciar do zero a cada vez que liga, em vez de reaproveitar o estado anterior. Evita lentidão e bugs de driver acumulados; o boot leva alguns segundos a mais.'
       Reg = @( @{ P = 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power'; N = 'HiberbootEnabled'; T = 'DWord'; V = 0; D = 1 } ) }

    # ---------------- Debloat ----------------
    @{ Id = 'telemetry'; Cat = 'debloat'; Impact = 'Baixo'
       Name = 'Reduzir a telemetria do Windows'
       Desc = 'Coloca a coleta de dados de diagnóstico no mínimo permitido e desliga os serviços que enviam esses dados em segundo plano.'
       Reg = @(
           @{ P = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; N = 'AllowTelemetry'; T = 'DWord'; V = 0 },
           @{ P = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection'; N = 'AllowTelemetry'; T = 'DWord'; V = 0 },
           @{ P = 'HKCU\Software\Microsoft\Siuf\Rules'; N = 'NumberOfSIUFInPeriod'; T = 'DWord'; V = 0 }
       )
       Test   = { Test-ServicesDisabled @('DiagTrack', 'dmwappushservice') }
       Apply  = { Disable-Services 'svc-telemetry' @('DiagTrack', 'dmwappushservice') }
       Revert = { Restore-Services 'svc-telemetry' @{ DiagTrack = 2; dmwappushservice = 3 } } }

    @{ Id = 'teletasks'; Cat = 'debloat'; Impact = 'Médio'
       Name = 'Desligar as tarefas agendadas de telemetria'
       Desc = 'O avaliador de compatibilidade e outras tarefas de coleta rodam em horários aleatórios e usam processador e disco, às vezes no meio da partida.'
       Test = {
           $ts = @(Get-TelemetryTasks)
           if ($ts.Count -eq 0) { return $false }
           return (@($ts | Where-Object { $_.State -ne 'Disabled' }).Count -eq 0)
       }
       Apply  = { foreach ($x in @(Get-TelemetryTasks)) { $x | Disable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null } }
       Revert = { foreach ($x in @(Get-TelemetryTasks)) { $x | Enable-ScheduledTask  -ErrorAction SilentlyContinue | Out-Null } } }

    @{ Id = 'ads'; Cat = 'debloat'; Impact = 'Baixo'
       Name = 'Desligar sugestões, anúncios e apps patrocinados'
       Desc = 'Para as dicas e propagandas do menu Iniciar e da tela de bloqueio, e impede o Windows de instalar sozinho jogos e apps promovidos.'
       Reg = @(
           @{ P = $CDM; N = 'SilentInstalledAppsEnabled';      T = 'DWord'; V = 0; D = 1 },
           @{ P = $CDM; N = 'PreInstalledAppsEnabled';         T = 'DWord'; V = 0; D = 1 },
           @{ P = $CDM; N = 'OemPreInstalledAppsEnabled';      T = 'DWord'; V = 0; D = 1 },
           @{ P = $CDM; N = 'SystemPaneSuggestionsEnabled';    T = 'DWord'; V = 0; D = 1 },
           @{ P = $CDM; N = 'SoftLandingEnabled';              T = 'DWord'; V = 0; D = 1 },
           @{ P = $CDM; N = 'SubscribedContent-310093Enabled'; T = 'DWord'; V = 0; D = 1 },
           @{ P = $CDM; N = 'SubscribedContent-338388Enabled'; T = 'DWord'; V = 0; D = 1 },
           @{ P = $CDM; N = 'SubscribedContent-338389Enabled'; T = 'DWord'; V = 0; D = 1 },
           @{ P = $CDM; N = 'SubscribedContent-353694Enabled'; T = 'DWord'; V = 0; D = 1 },
           @{ P = $CDM; N = 'SubscribedContent-353696Enabled'; T = 'DWord'; V = 0; D = 1 },
           @{ P = 'HKCU\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'; N = 'Enabled'; T = 'DWord'; V = 0; D = 1 },
           @{ P = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; N = 'ShowSyncProviderNotifications'; T = 'DWord'; V = 0; D = 1 },
           @{ P = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; N = 'Start_IrisRecommendations';     T = 'DWord'; V = 0; D = 1 }
       ) }

    @{ Id = 'bing'; Cat = 'debloat'; Impact = 'Baixo'
       Name = 'Tirar a pesquisa da web do menu Iniciar'
       Desc = 'A busca do Iniciar passa a procurar só no seu PC, sem consultar o Bing a cada letra digitada. Fica mais rápida e para de mostrar resultados da internet.'
       Reg = @(
           @{ P = 'HKCU\Software\Policies\Microsoft\Windows\Explorer'; N = 'DisableSearchBoxSuggestions'; T = 'DWord'; V = 1 },
           @{ P = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Search'; N = 'BingSearchEnabled'; T = 'DWord'; V = 0; D = 1 }
       ) }

    @{ Id = 'widgets'; Cat = 'debloat'; Impact = 'Médio'; Reboot = $true
       Name = 'Desligar Widgets e notícias'
       Desc = 'O painel de widgets mantém processos de navegador abertos o tempo todo, ocupando centenas de MB de RAM. Desligar tira o botão da barra de tarefas.'
       Reg = @(
           @{ P = 'HKLM\SOFTWARE\Policies\Microsoft\Dsh'; N = 'AllowNewsAndInterests'; T = 'DWord'; V = 0 },
           @{ P = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds'; N = 'EnableFeeds'; T = 'DWord'; V = 0 }
       ) }

    @{ Id = 'copilot'; Cat = 'debloat'; Impact = 'Baixo'
       Name = 'Desligar o Copilot e o Recall'
       Desc = 'Desativa o assistente do Windows e a captura de tela contínua do Recall por política do sistema.'
       Reg = @(
           @{ P = 'HKCU\Software\Policies\Microsoft\Windows\WindowsCopilot'; N = 'TurnOffWindowsCopilot'; T = 'DWord'; V = 1 },
           @{ P = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot'; N = 'TurnOffWindowsCopilot'; T = 'DWord'; V = 1 },
           @{ P = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'; N = 'DisableAIDataAnalysis'; T = 'DWord'; V = 1 }
       ) }

    @{ Id = 'activity'; Cat = 'debloat'; Impact = 'Baixo'
       Name = 'Desligar o histórico de atividades'
       Desc = 'O Windows deixa de registrar e enviar à Microsoft a lista de apps e arquivos que você abriu.'
       Reg = @(
           @{ P = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\System'; N = 'EnableActivityFeed';    T = 'DWord'; V = 0 },
           @{ P = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\System'; N = 'PublishUserActivities'; T = 'DWord'; V = 0 },
           @{ P = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\System'; N = 'UploadUserActivities';  T = 'DWord'; V = 0 }
       ) }

    @{ Id = 'edgebg'; Cat = 'debloat'; Impact = 'Médio'
       Name = 'Impedir o Edge de rodar em segundo plano'
       Desc = 'Desliga o pré-carregamento do Edge junto com o Windows e os processos que continuam abertos depois de fechar o navegador. O Edge vai mostrar "gerenciado pela organização".'
       Reg = @(
           @{ P = 'HKLM\SOFTWARE\Policies\Microsoft\Edge'; N = 'StartupBoostEnabled';   T = 'DWord'; V = 0 },
           @{ P = 'HKLM\SOFTWARE\Policies\Microsoft\Edge'; N = 'BackgroundModeEnabled'; T = 'DWord'; V = 0 }
       ) }

    @{ Id = 'onedrive'; Cat = 'debloat'; Impact = 'Médio'
       Name = 'Tirar o OneDrive da inicialização'
       Desc = 'O OneDrive deixa de abrir sozinho e de sincronizar enquanto você joga. Seus arquivos ficam intactos; para sincronizar, abra o OneDrive pelo menu Iniciar.'
       Reg = @( @{ P = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Run'; N = 'OneDrive'; Del = $true } ) }

    @{ Id = 'services'; Cat = 'debloat'; Impact = 'Baixo'
       Name = 'Desligar serviços que quase ninguém usa'
       Desc = 'Mapas offline, fax, modo de demonstração de loja e compartilhamento de rede do Windows Media Player.'
       Test   = { Test-ServicesDisabled @('MapsBroker', 'Fax', 'RetailDemo', 'WMPNetworkSvc') }
       Apply  = { Disable-Services 'svc-extra' @('MapsBroker', 'Fax', 'RetailDemo', 'WMPNetworkSvc') }
       Revert = { Restore-Services 'svc-extra' @{ MapsBroker = 2; Fax = 3; RetailDemo = 3; WMPNetworkSvc = 3 } } }

    @{ Id = 'appx'; Cat = 'debloat'; Impact = 'Baixo'
       Name = 'Remover os apps marcados na tela Apps'
       Desc = 'Na tela Apps cada app tem o próprio botão. Sem mexer lá, saem só os recomendados: notícias e apps do Bing, Paciência, Clipchamp, Skype, Cortana, o app do Copilot, Candy Crush, TikTok e outros promocionais. Depois de removidos, o Windows não os reinstala sozinho, e o Harle confere no fim se cada um saiu mesmo.'
       Apps = $true
       Run  = { param($t) Remove-Bloat (Get-AppNamesToRemove) } }

    @{ Id = 'bgapps'; Cat = 'debloat'; Impact = 'Médio'; Optional = $true
       Name = 'Impedir apps da Loja de rodar em segundo plano'
       Desc = 'Apps instalados pela Microsoft Store deixam de trabalhar com a janela fechada, o que libera memória e processador. Em troca, eles param de avisar quando fechados: quem usa WhatsApp ou Email da Loja só recebe notificação com o app aberto.'
       Reg = @( @{ P = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy'; N = 'LetAppsRunInBackground'; T = 'DWord'; V = 2 } ) }

    @{ Id = 'chromebg'; Cat = 'debloat'; Impact = 'Médio'; Optional = $true
       Name = 'Impedir o Chrome de rodar em segundo plano'
       Desc = 'O Chrome deixa de ficar aberto escondido depois que você fecha a janela. Como é feito por política, o Chrome passa a mostrar o aviso "gerenciado pela sua organização" nas configurações; é só o Harle.'
       Reg = @( @{ P = 'HKLM\SOFTWARE\Policies\Google\Chrome'; N = 'BackgroundModeEnabled'; T = 'DWord'; V = 0 } ) }

    @{ Id = 'wsearch'; Cat = 'debloat'; Impact = 'Baixo'; Optional = $true
       Name = 'Desligar a indexação de arquivos'
       Desc = 'Para o serviço que fica lendo o disco para montar o índice da pesquisa. Ajuda principalmente em PCs com HD. Em troca, a pesquisa de arquivos do menu Iniciar e do Explorador fica bem mais lenta; a pesquisa de programas continua.'
       Test   = { Test-ServicesDisabled @('WSearch') }
       Apply  = { Disable-Services 'svc-search' @('WSearch') }
       Revert = { Restore-Services 'svc-search' @{ WSearch = 2 } } }

    @{ Id = 'lockads'; Cat = 'debloat'; Impact = 'Baixo'
       Name = 'Tirar dicas e curiosidades da tela de bloqueio'
       Desc = 'A tela de bloqueio fica só com a imagem e o relógio, sem os textos de curiosidades, dicas e propagandas por cima.'
       Reg = @(
           @{ P = $CDM; N = 'RotatingLockScreenOverlayEnabled'; T = 'DWord'; V = 0; D = 1 },
           @{ P = $CDM; N = 'SubscribedContent-338387Enabled';  T = 'DWord'; V = 0; D = 1 }
       ) }

    @{ Id = 'scoobe'; Cat = 'debloat'; Impact = 'Baixo'
       Name = 'Tirar o "Vamos terminar de configurar" depois das atualizações'
       Desc = 'Para a tela cheia que aparece depois de algumas atualizações oferecendo conta Microsoft, OneDrive, Microsoft 365 e Game Pass.'
       Reg = @( @{ P = 'HKCU\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement'; N = 'ScoobeSystemSettingEnabled'; T = 'DWord'; V = 0; D = 1 } ) }

    # Só no Windows 10
    @{ Id = 'cortana10'; Cat = 'debloat'; Impact = 'Baixo'; MaxBuild = 21999
       Name = 'Desligar a Cortana'
       Desc = 'Desliga a Cortana por política e tira o botão dela da barra de tarefas. A pesquisa do menu Iniciar continua funcionando.'
       Reg = @(
           @{ P = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; N = 'AllowCortana'; T = 'DWord'; V = 0 },
           @{ P = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; N = 'ShowCortanaButton'; T = 'DWord'; V = 0; D = 1 }
       ) }

    @{ Id = 'meetnow'; Cat = 'debloat'; Impact = 'Baixo'; MaxBuild = 21999
       Name = 'Tirar o Reunir Agora e a barra de Pessoas'
       Desc = 'Some o ícone de câmera do Skype (Reunir Agora) do canto da barra de tarefas e o botão de Pessoas.'
       Reg = @(
           @{ P = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'; N = 'HideSCAMeetNow'; T = 'DWord'; V = 1 },
           @{ P = 'HKCU\Software\Policies\Microsoft\Windows\Explorer'; N = 'HidePeopleBar'; T = 'DWord'; V = 1 }
       ) }

    # Só no Windows 11
    @{ Id = 'chaticon'; Cat = 'debloat'; Impact = 'Baixo'; MinBuild = 22000
       Name = 'Tirar o botão do Chat (Teams) da barra de tarefas'
       Desc = 'O botão do Chat do Teams gratuito some da barra de tarefas. O Teams do trabalho ou da escola não é afetado.'
       Reg = @( @{ P = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Chat'; N = 'ChatIcon'; T = 'DWord'; V = 3 } ) }

    @{ Id = 'startacct'; Cat = 'debloat'; Impact = 'Baixo'; MinBuild = 22621
       Name = 'Tirar os avisos de conta do menu Iniciar'
       Desc = 'Some o lembrete do menu Iniciar para entrar com conta Microsoft, fazer backup no OneDrive ou assinar o Microsoft 365.'
       Reg = @( @{ P = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; N = 'Start_AccountNotifications'; T = 'DWord'; V = 0; D = 1 } ) }

    @{ Id = 'recall'; Cat = 'debloat'; Impact = 'Baixo'; MinBuild = 26100; Reboot = $true
       Name = 'Remover o Recall e o Click to Do'
       Desc = 'Tira o Recall (que fotografa a tela o tempo todo para busca) e o Click to Do por política do Windows. Só existem nos PCs Copilot+; nos outros não muda nada.'
       Reg = @(
           @{ P = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'; N = 'AllowRecallEnablement'; T = 'DWord'; V = 0 },
           @{ P = 'HKCU\Software\Policies\Microsoft\Windows\WindowsAI'; N = 'DisableAIDataAnalysis'; T = 'DWord'; V = 1 },
           @{ P = 'HKCU\Software\Policies\Microsoft\Windows\WindowsAI'; N = 'DisableClickToDo'; T = 'DWord'; V = 1 }
       ) }

    # ---------------- Privacidade ----------------
    @{ Id = 'tailored'; Cat = 'priv'; Impact = 'Baixo'
       Name = 'Desligar as experiências personalizadas'
       Desc = 'A Microsoft deixa de usar os dados de diagnóstico deste PC para montar dicas, anúncios e recomendações sob medida.'
       Reg = @( @{ P = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Privacy'; N = 'TailoredExperiencesWithDiagnosticDataEnabled'; T = 'DWord'; V = 0 } ) }

    @{ Id = 'typing'; Cat = 'priv'; Impact = 'Baixo'
       Name = 'Parar de coletar o que você digita e escreve'
       Desc = 'Desliga a coleta de digitação e escrita à mão que o Windows usa para personalizar o dicionário e as sugestões. O corretor e as sugestões básicas continuam.'
       Reg = @(
           @{ P = 'HKCU\Software\Microsoft\InputPersonalization'; N = 'RestrictImplicitInkCollection';  T = 'DWord'; V = 1 }
           @{ P = 'HKCU\Software\Microsoft\InputPersonalization'; N = 'RestrictImplicitTextCollection'; T = 'DWord'; V = 1 }
           @{ P = 'HKCU\Software\Microsoft\InputPersonalization\TrainedDataStore'; N = 'HarvestContacts'; T = 'DWord'; V = 0 }
           @{ P = 'HKCU\Software\Microsoft\Personalization\Settings'; N = 'AcceptedPrivacyPolicy'; T = 'DWord'; V = 0 }
       ) }

    @{ Id = 'speech'; Cat = 'priv'; Impact = 'Baixo'; Optional = $true
       Name = 'Desligar o reconhecimento de fala online'
       Desc = 'Sua voz deixa de ser enviada à Microsoft pelo ditado do Windows. O ditado online (Win + H) para de funcionar; o reconhecimento de fala local continua.'
       Reg = @( @{ P = 'HKCU\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy'; N = 'HasAccepted'; T = 'DWord'; V = 0 } ) }

    @{ Id = 'launchtrack'; Cat = 'priv'; Impact = 'Baixo'; Optional = $true
       Name = 'Parar de registrar os programas que você abre'
       Desc = 'O Windows deixa de anotar o que você abre para montar a lista de mais usados do menu Iniciar e os resultados da pesquisa. Essa lista para de se atualizar.'
       Reg = @( @{ P = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; N = 'Start_TrackProgs'; T = 'DWord'; V = 0 } ) }

    @{ Id = 'langlist'; Cat = 'priv'; Impact = 'Baixo'
       Name = 'Não informar sua lista de idiomas aos sites'
       Desc = 'Os navegadores da Microsoft deixam de entregar aos sites a lista de idiomas instalados no Windows, que serve para identificar o PC.'
       Reg = @( @{ P = 'HKCU\Control Panel\International\User Profile'; N = 'HttpAcceptLanguageOptOut'; T = 'DWord'; V = 1 } ) }

    @{ Id = 'searchhist'; Cat = 'priv'; Impact = 'Baixo'
       Name = 'Desligar o histórico e a nuvem na pesquisa do Windows'
       Desc = 'A pesquisa do menu Iniciar deixa de guardar o que você procurou neste PC e de buscar no conteúdo das suas contas Microsoft, de trabalho ou de escola.'
       Reg = @(
           @{ P = 'HKCU\Software\Microsoft\Windows\CurrentVersion\SearchSettings'; N = 'IsDeviceSearchHistoryEnabled'; T = 'DWord'; V = 0 }
           @{ P = 'HKCU\Software\Microsoft\Windows\CurrentVersion\SearchSettings'; N = 'IsMSACloudSearchEnabled';      T = 'DWord'; V = 0 }
           @{ P = 'HKCU\Software\Microsoft\Windows\CurrentVersion\SearchSettings'; N = 'IsAADCloudSearchEnabled';      T = 'DWord'; V = 0 }
       ) }

    @{ Id = 'feedback'; Cat = 'priv'; Impact = 'Baixo'
       Name = 'Parar os pedidos de avaliação do Windows'
       Desc = 'O Windows deixa de abrir notificações pedindo nota e comentários sobre ele.'
       Reg = @( @{ P = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; N = 'DoNotShowFeedbackNotifications'; T = 'DWord'; V = 1 } ) }

    @{ Id = 'wer'; Cat = 'priv'; Impact = 'Baixo'
       Name = 'Desligar o envio de relatórios de erro'
       Desc = 'Quando um programa trava, o Windows deixa de montar e enviar o relatório para a Microsoft. Poupa disco e processador logo depois de um travamento.'
       Reg = @( @{ P = 'HKLM\SOFTWARE\Microsoft\Windows\Windows Error Reporting'; N = 'Disabled'; T = 'DWord'; V = 1 } ) }

    @{ Id = 'ceip'; Cat = 'priv'; Impact = 'Baixo'
       Name = 'Sair do programa de aperfeiçoamento do Windows'
       Desc = 'Desliga o Programa de Aperfeiçoamento da Experiência do Usuário, que coleta estatísticas de uso do sistema.'
       Reg = @( @{ P = 'HKLM\SOFTWARE\Policies\Microsoft\SQMClient\Windows'; N = 'CEIPEnable'; T = 'DWord'; V = 0 } ) }

    @{ Id = 'remoteassist'; Cat = 'priv'; Impact = 'Baixo'
       Name = 'Desligar a Assistência Remota'
       Desc = 'Ninguém mais consegue pedir para controlar este PC pela Assistência Remota do Windows. Programas como AnyDesk e TeamViewer não são afetados.'
       Reg = @( @{ P = 'HKLM\SYSTEM\CurrentControlSet\Control\Remote Assistance'; N = 'fAllowToGetHelp'; T = 'DWord'; V = 0 } ) }

    @{ Id = 'location'; Cat = 'priv'; Impact = 'Baixo'; Optional = $true
       Name = 'Desligar a localização'
       Desc = 'Nenhum app descobre onde o PC está. Clima, Mapas e o fuso horário automático deixam de saber a sua cidade sozinhos.'
       Reg = @( @{ P = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location'; N = 'Value'; T = 'String'; V = 'Deny' } ) }

    # ---------------- Rede ----------------
    @{ Id = 'nagle'; Cat = 'net'; Impact = 'Médio'
       Name = 'Desligar o algoritmo de Nagle'
       Desc = 'Envia cada pacote na hora em vez de esperar para agrupar. Baixa a latência em jogos que usam TCP, como muitos MMOs; em jogos que usam UDP não muda nada.'
       RegDyn = {
           $base = 'SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces'
           $k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($base)
           if (-not $k) { return }
           foreach ($sub in $k.GetSubKeyNames()) {
               $ik = $k.OpenSubKey($sub)
               if (-not $ik) { continue }
               $ip = $ik.GetValue('DhcpIPAddress')
               if (-not $ip) { $ip = $ik.GetValue('IPAddress') }
               $ik.Close()
               $ipText = (@($ip) -join '').Trim()
               if ($ipText -and $ipText -ne '0.0.0.0') {
                   @{ P = "HKLM\$base\$sub"; N = 'TcpAckFrequency'; T = 'DWord'; V = 1 }
                   @{ P = "HKLM\$base\$sub"; N = 'TCPNoDelay';      T = 'DWord'; V = 1 }
               }
           }
           $k.Close()
       } }

    @{ Id = 'netthrottle'; Cat = 'net'; Impact = 'Baixo'
       Name = 'Desligar o limite de rede multimídia'
       Desc = 'O Windows limita o processamento de pacotes de rede enquanto há áudio ou vídeo tocando. Este ajuste remove o limite (NetworkThrottlingIndex).'
       Reg = @( @{ P = $MMCSS; N = 'NetworkThrottlingIndex'; T = 'DWord'; V = 4294967295; D = 10 } ) }

    @{ Id = 'delivery'; Cat = 'net'; Impact = 'Médio'
       Name = 'Parar de enviar atualizações para outros PCs'
       Desc = 'Por padrão o Windows usa a sua internet para distribuir atualizações a outros computadores. Desligar libera o upload e evita picos de ping.'
       Reg = @( @{ P = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'; N = 'DODownloadMode'; T = 'DWord'; V = 0 } ) }

    @{ Id = 'nicpower'; Cat = 'net'; Impact = 'Baixo'; Reboot = $true
       Name = 'Impedir o Windows de desligar a placa de rede'
       Desc = 'Desmarca, em cada adaptador físico de rede, a opção que deixa o Windows desligar o dispositivo para economizar energia. Evita quedas de conexão e picos de ping depois de um tempo parado. Em notebook gasta um pouco mais de bateria.'
       RegDyn = {
           $base = 'SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}'
           $k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($base)
           if (-not $k) { return }
           foreach ($sub in $k.GetSubKeyNames()) {
               if ($sub -notmatch '^\d{4}$') { continue }
               $ik = $null
               try { $ik = $k.OpenSubKey($sub) } catch { }
               if (-not $ik) { continue }
               $ch = $ik.GetValue('Characteristics')
               $inst = $ik.GetValue('NetCfgInstanceId')
               $ik.Close()
               # 0x4 = adaptador fisico (cabo ou Wi-Fi); os virtuais de VPN e maquina virtual ficam de fora.
               if ($null -ne $ch -and $inst -and (([int64]$ch) -band 4)) {
                   @{ P = "HKLM\$base\$sub"; N = 'PnPCapabilities'; T = 'DWord'; V = 24 }
               }
           }
           $k.Close()
       } }

    @{ Id = 'flushdns'; Cat = 'net'; Impact = 'Baixo'
       Name = 'Limpar o cache de DNS'
       Desc = 'Apaga os endereços guardados, o que resolve launchers e jogos que não conectam depois de trocar de rede.'
       Run  = { param($t) [void](Invoke-Native 'ipconfig.exe' '/flushdns'); 'Cache limpo' } }

    # ---------------- Conforto ----------------
    @{ Id = 'audioduck'; Cat = 'qol'; Impact = 'Baixo'
       Name = 'Não abaixar o som do jogo durante chamadas'
       Desc = 'O Windows deixa de reduzir sozinho o volume dos outros programas quando detecta uma chamada de voz, como acontece ao entrar em uma call no meio da partida.'
       Reg = @( @{ P = 'HKCU\Software\Microsoft\Multimedia\Audio'; N = 'UserDuckingPreference'; T = 'DWord'; V = 3 } ) }

    @{ Id = 'endtask'; Cat = 'qol'; Impact = 'Baixo'; MinBuild = 22631; Optional = $true
       Name = 'Finalizar tarefa no botão direito da barra de tarefas'
       Desc = 'Adiciona "Finalizar tarefa" ao menu do botão direito de cada programa na barra de tarefas. Fecha um jogo travado sem abrir o Gerenciador de Tarefas. Existe a partir do Windows 11 23H2.'
       Reg = @( @{ P = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings'; N = 'TaskbarEndTask'; T = 'DWord'; V = 1 } ) }

    @{ Id = 'classicmenu'; Cat = 'qol'; Impact = 'Baixo'; MinBuild = 22000; Optional = $true; Reboot = $true
       Name = 'Menu de botão direito completo no Windows 11'
       Desc = 'O botão direito volta a abrir direto o menu completo, sem precisar clicar em "Mostrar mais opções". Vale depois de reiniciar o PC ou sair e entrar na conta.'
       Test = {
           $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32')
           if (-not $k) { return $false }
           $v = $k.GetValue([string]::Empty, $null)
           $k.Close()
           return ($null -ne $v -and ([string]$v).Length -eq 0)
       }
       Apply = {
           $k = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32')
           $k.SetValue([string]::Empty, [string]::Empty)
           $k.Close()
       }
       # Aqui a chave inteira foi criada pelo Harle e precisa sair: vazia, ela ainda manteria o menu antigo.
       Revert = { [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree('Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}', $false) } }

    @{ Id = 'fileext'; Cat = 'qol'; Impact = 'Baixo'; Optional = $true
       Name = 'Mostrar as extensões dos arquivos'
       Desc = 'O Explorador passa a mostrar .exe, .png, .zip e as outras extensões. Ajuda a não abrir um programa disfarçado de imagem ou documento.'
       Reg = @( @{ P = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; N = 'HideFileExt'; T = 'DWord'; V = 0 } ) }

    @{ Id = 'thispc'; Cat = 'qol'; Impact = 'Baixo'; Optional = $true
       Name = 'Abrir o Explorador em "Este Computador"'
       Desc = 'O Explorador de Arquivos abre mostrando os discos, em vez da tela Início com arquivos recentes.'
       Reg = @( @{ P = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; N = 'LaunchTo'; T = 'DWord'; V = 1 } ) }

    @{ Id = 'foldertype'; Cat = 'qol'; Impact = 'Baixo'; Optional = $true
       Name = 'Abrir pastas grandes mais rápido'
       Desc = 'O Explorador deixa de examinar o conteúdo de cada pasta para decidir se ela é de fotos, músicas ou vídeos. Pastas com milhares de arquivos abrem mais rápido; em troca, todas usam a mesma visualização geral.'
       Reg = @( @{ P = 'HKCU\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags\AllFolders\Shell'; N = 'FolderType'; T = 'String'; V = 'NotSpecified' } ) }

    @{ Id = 'aeroshake'; Cat = 'qol'; Impact = 'Baixo'; Optional = $true
       Name = 'Desligar o "sacudir para minimizar"'
       Desc = 'Sacudir uma janela com o mouse deixa de minimizar todas as outras.'
       Reg = @( @{ P = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; N = 'DisallowShaking'; T = 'DWord'; V = 1 } ) }

    @{ Id = 'taskview'; Cat = 'qol'; Impact = 'Baixo'; Optional = $true
       Name = 'Tirar o botão Visão de Tarefas'
       Desc = 'Remove o botão de áreas de trabalho da barra de tarefas. O atalho Win + Tab continua funcionando.'
       Reg = @( @{ P = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; N = 'ShowTaskViewButton'; T = 'DWord'; V = 0 } ) }

    @{ Id = 'searchbox'; Cat = 'qol'; Impact = 'Baixo'; Optional = $true
       Name = 'Tirar a caixa de pesquisa da barra de tarefas'
       Desc = 'Libera o espaço da barra. Para pesquisar, é só apertar a tecla Windows e começar a digitar.'
       Reg = @( @{ P = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Search'; N = 'SearchboxTaskbarMode'; T = 'DWord'; V = 0 } ) }

    @{ Id = 'autoplay'; Cat = 'qol'; Impact = 'Baixo'; Optional = $true
       Name = 'Desligar a Reprodução Automática'
       Desc = 'Pendrives, HDs externos e discos deixam de abrir janelas ou executar algo sozinhos ao serem conectados.'
       Reg = @( @{ P = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\AutoplayHandlers'; N = 'DisableAutoplay'; T = 'DWord'; V = 1 } ) }

    @{ Id = 'maintwake'; Cat = 'qol'; Impact = 'Baixo'; Optional = $true
       Name = 'Não acordar o PC para manutenção'
       Desc = 'A manutenção automática do Windows deixa de tirar o PC da suspensão de madrugada. Ela continua rodando quando o PC estiver ligado e parado.'
       Reg = @( @{ P = 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\Maintenance'; N = 'WakeUp'; T = 'DWord'; V = 0 } ) }

    @{ Id = 'longpaths'; Cat = 'qol'; Impact = 'Baixo'; Optional = $true
       Name = 'Aceitar caminhos de arquivo longos'
       Desc = 'Libera caminhos com mais de 260 caracteres para os programas que suportam. Resolve erros ao extrair ou instalar mods e projetos com muitas pastas, uma dentro da outra.'
       Reg = @( @{ P = 'HKLM\SYSTEM\CurrentControlSet\Control\FileSystem'; N = 'LongPathsEnabled'; T = 'DWord'; V = 1 } ) }

    # ---------------- Limpeza ----------------
    @{ Id = 'cleantemp'; Cat = 'clean'; Impact = 'Baixo'
       Name = 'Limpar arquivos temporários'
       Desc = 'Apaga as pastas de temporários do usuário e do Windows e os despejos de erro de aplicativos. Arquivos em uso são pulados.'
       Run  = { param($t) Invoke-Cleanup @($env:TEMP, (Join-Path $env:WINDIR 'Temp'), (Join-Path $env:LOCALAPPDATA 'CrashDumps')) } }

    @{ Id = 'cleanwu'; Cat = 'clean'; Impact = 'Baixo'
       Name = 'Limpar downloads antigos do Windows Update'
       Desc = 'Apaga os instaladores de atualizações já aplicadas, que costumam ocupar alguns GB. O Windows baixa de novo o que ainda precisar.'
       Run  = { param($t)
           $was = (Get-Service wuauserv -ErrorAction SilentlyContinue).Status -eq 'Running'
           Stop-Service wuauserv, bits -Force -ErrorAction SilentlyContinue
           $msg = Invoke-Cleanup @((Join-Path $env:WINDIR 'SoftwareDistribution\Download'))
           if ($was) { Start-Service wuauserv -ErrorAction SilentlyContinue }
           $msg } }

    @{ Id = 'shadercache'; Cat = 'clean'; Impact = 'Baixo'; Manual = $true
       Name = 'Limpar o cache de shaders'
       Desc = 'Apaga os shaders guardados pelo DirectX e pelos drivers NVIDIA e AMD. Use depois de atualizar o driver de vídeo ou se um jogo passou a travar ou mostrar defeitos na imagem. Na primeira vez que abrir cada jogo depois disso, ele trava um pouco enquanto monta os shaders de novo.'
       Run  = { param($t)
           $l = $env:LOCALAPPDATA
           Invoke-Cleanup @((Join-Path $l 'D3DSCache'), (Join-Path $l 'NVIDIA\DXCache'), (Join-Path $l 'NVIDIA\GLCache'),
                            (Join-Path $env:ProgramData 'NVIDIA Corporation\NV_Cache'),
                            (Join-Path $l 'AMD\DxCache'), (Join-Path $l 'AMD\DxcCache'), (Join-Path $l 'AMD\VkCache'), (Join-Path $l 'AMD\GLCache'))
       } }

    @{ Id = 'recycle'; Cat = 'clean'; Impact = 'Baixo'; Manual = $true; Button = 'Esvaziar'
       Name = 'Esvaziar a Lixeira'
       Desc = 'Apaga de vez o que está na Lixeira de todos os discos. Não tem volta.'
       Run  = { param($t)
           $n = -1
           try { $n = @((New-Object -ComObject Shell.Application).NameSpace(10).Items()).Count } catch { }
           if ($n -eq 0) { return 'Já estava vazia' }
           Clear-RecycleBin -Force -ErrorAction SilentlyContinue
           if ($n -gt 0) { return (Tx '{0} itens apagados' $n) }
           return 'Lixeira esvaziada'
       } }

    @{ Id = 'dismclean'; Cat = 'clean'; Impact = 'Baixo'; Manual = $true
       Name = 'Limpar componentes antigos do Windows'
       Desc = 'Roda a limpeza oficial do Windows (DISM) que remove versões antigas de componentes deixadas pelas atualizações. Costuma liberar alguns GB e pode levar de 2 a 15 minutos.'
       Run  = { param($t)
           $r = @(Invoke-Background $script:DismCode $null)
           $line = if ($r.Count -gt 0) { [string]$r[$r.Count - 1] } else { [string]::Empty }
           $f = $line.Split('|')
           $code = -1; $freed = [int64]0
           if ($f.Count -ge 2) { [void][int]::TryParse($f[0], [ref]$code); [void][int64]::TryParse($f[1], [ref]$freed) }
           Write-Log "DISM: codigo $code, $freed bytes"
           if ($code -ne 0 -and $code -ne 3010) { return (Tx 'O DISM devolveu o código {0}' ($code)) }
           if ($freed -lt 1MB) { return 'Nada para limpar' }
           return (Tx '{0} liberados' (Format-Bytes $freed))
       } }

    @{ Id = 'hibernate'; Cat = 'clean'; Impact = 'Baixo'; Optional = $true
       Name = 'Desligar a hibernação'
       Desc = 'Apaga o arquivo hiberfil.sys, que ocupa no disco perto de 40% do tamanho da RAM (uns 6 GB com 16 GB de RAM). A opção Hibernar some do menu de desligar e a Inicialização Rápida deixa de existir. Em notebook, só use se você nunca hiberna.'
       Test  = { $s = Get-RegState 'HKLM\SYSTEM\CurrentControlSet\Control\Power' 'HibernateEnabled'; return ($s.Exists -and [int]$s.Value -eq 0) }
       Apply = {
           $s = Get-RegState 'HKLM\SYSTEM\CurrentControlSet\Control\Power' 'HibernateEnabled'
           if ($null -eq $script:Backup.state['hibernate']) { $script:Backup.state['hibernate'] = $(if ($s.Exists) { [int]$s.Value } else { 1 }) }
           [void](Invoke-Native 'powercfg.exe' '/hibernate off')
       }
       Revert = {
           $prev = $script:Backup.state['hibernate']
           if ($null -eq $prev -or [int]$prev -ne 0) { [void](Invoke-Native 'powercfg.exe' '/hibernate on') }
           $script:Backup.state.Remove('hibernate')
       } }

    # ---------------- Manutencao ----------------
    @{ Id = 'wudrivers'; Cat = 'keep'; Impact = 'Baixo'; Optional = $true
       Name = 'Não deixar o Windows Update trocar drivers'
       Desc = 'O Windows Update deixa de instalar drivers junto com as atualizações, o que evita ele trocar o driver de vídeo que você instalou por um mais antigo. Em troca, drivers de outros dispositivos passam a ser por sua conta.'
       Reg = @( @{ P = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'; N = 'ExcludeWUDriversInQualityUpdate'; T = 'DWord'; V = 1 } ) }

    # Igual a politica do gpedit "Configurar Atualizacoes Automaticas" em "2 - Notificar para download e instalacao".
    @{ Id = 'wucontrol'; Cat = 'keep'; Impact = 'Médio'; Optional = $true
       Name = 'Windows Update sob controle (igual ao gpedit)'
       Desc = 'Faz o mesmo que a política do gpedit "Configurar Atualizações Automáticas" em "Notificar para download e instalação": o Windows não baixa nem instala nada sozinho e não reinicia com você usando o PC. A Microsoft Store, o Xbox e o Defender continuam se atualizando normalmente, e as atualizações do Windows você instala quando quiser em Configurações, Windows Update. Também adia por um ano as atualizações de versão grandes. No Windows Home a Microsoft não garante que essas políticas sejam respeitadas; no Pro funciona igual ao gpedit.'
       Reg = @(
           @{ P = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'; N = 'NoAutoUpdate'; T = 'DWord'; V = 0 },
           @{ P = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'; N = 'AUOptions'; T = 'DWord'; V = 2 },
           @{ P = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'; N = 'NoAutoRebootWithLoggedOnUsers'; T = 'DWord'; V = 1 },
           @{ P = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'; N = 'DeferFeatureUpdates'; T = 'DWord'; V = 1 },
           @{ P = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'; N = 'DeferFeatureUpdatesPeriodInDays'; T = 'DWord'; V = 365 }
       ) }

    @{ Id = 'storeauto'; Cat = 'keep'; Impact = 'Baixo'; Optional = $true
       Name = 'Desligar a atualização automática dos apps da Loja'
       Desc = 'A Microsoft Store deixa de baixar atualizações de apps sozinha, o que evita downloads no meio da partida. Você passa a atualizar pela própria Store; quem usa Game Pass precisa lembrar de atualizar o app Xbox e os Serviços de Jogos.'
       Reg = @( @{ P = 'HKLM\SOFTWARE\Policies\Microsoft\WindowsStore'; N = 'AutoDownload'; T = 'DWord'; V = 2 } ) }

    @{ Id = 'guard'; Cat = 'keep'; Impact = 'Médio'; ExeOnly = $true
       Name = 'Conferir os ajustes a cada login'
       Desc = 'Atualizações do Windows desfazem alguns ajustes sem avisar. Um minuto depois do login, o Harle confere em silêncio e reaplica só o que foi revertido. Não abre janela, não roda o Windows Update e termina em segundos.'
       Test   = { (Test-HarleTask $script:GuardTask) -and (Test-HarleExe) }
       Apply  = { Install-HarleExe; Register-HarleTask $script:GuardTask '/reaplicar' 'PT1M' }
       Revert = {
           Unregister-ScheduledTask -TaskName $script:GuardTask -Confirm:$false -ErrorAction SilentlyContinue
           Remove-HarleExeIfUnused
       } }

    # ---------------- Avancados (fora do perfil Equilibrado) ----------------
    @{ Id = 'visualfx'; Cat = 'opt'; Impact = 'Baixo'; Optional = $true
       Name = 'Reduzir transparência e animações'
       Desc = 'Tira a transparência das janelas e as animações de minimizar e da barra de tarefas. O ganho em jogo é pequeno; o Windows fica com resposta mais seca.'
       Reg = @(
           @{ P = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'; N = 'EnableTransparency'; T = 'DWord'; V = 0; D = 1 },
           @{ P = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';  N = 'TaskbarAnimations';  T = 'DWord'; V = 0; D = 1 },
           @{ P = 'HKCU\Control Panel\Desktop\WindowMetrics'; N = 'MinAnimate'; T = 'String'; V = '0'; D = '1' }
       ) }

    @{ Id = 'timer'; Cat = 'opt'; Impact = 'Médio'; Optional = $true; ExeOnly = $true
       Name = 'Timer do Windows em 0,5 ms'
       Desc = 'Faz o que os apps de Timer Resolution fazem: um ajudante invisível abre no login e mantém o relógio interno do Windows em 0,5 ms. No Windows 11 vale para todos os programas, depois de reiniciar; no Windows 10 vale na hora para os jogos que pedem timer preciso, que são quase todos. Não aumenta o FPS médio; deixa as esperas do jogo mais precisas, o que pode firmar o ritmo dos quadros e baixar um pouco a latência. Em troca, o processador gasta mais energia. Meça antes e depois na tela Medição.'
       # A chave que torna o pedido global so existe no Windows 11; no Windows 10 o ajudante basta.
       RegDyn = {
           if ($script:Build -ge 22000) {
               @{ P = 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\kernel'; N = 'GlobalTimerResolutionRequests'; T = 'DWord'; V = 1 }
           }
       }
       Test   = { (Test-HarleTask $script:TimerTask) -and (Test-HarleExe) }
       Apply  = { Install-HarleExe; Register-HarleTask $script:TimerTask '/timer' ''; Start-TimerHelper }
       Revert = {
           Unregister-ScheduledTask -TaskName $script:TimerTask -Confirm:$false -ErrorAction SilentlyContinue
           Stop-TimerHelper
           Remove-HarleExeIfUnused
       } }

    @{ Id = 'hvci'; Cat = 'opt'; Impact = 'Alto'; Reboot = $true; Optional = $true; Manual = $true
       Name = 'Desligar a Integridade de Memória'
       Desc = 'A proteção por virtualização do Windows 11 custa desempenho em jogos limitados pelo processador, e a própria Microsoft lista desligá-la como opção para quem prioriza FPS. Em troca, o Windows perde uma defesa contra drivers maliciosos, e o Vanguard (Valorant e League of Legends) pode exigir que ela fique ligada. Não desligue se você joga esses jogos. Vale depois de reiniciar o PC.'
       Reg = @( @{ P = 'HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity'; N = 'Enabled'; T = 'DWord'; V = 0; D = 1 } ) }
)

# ---------------------------------------------------------------------------
#  Perfis prontos
# ---------------------------------------------------------------------------
$script:Profiles = @(
    @{ Id = 'competitive'; Label = 'Competitivo'; Add = @('timer', 'visualfx'); Skip = @()
       Hint = 'Latência e FPS acima de tudo: liga também o timer de 0,5 ms e tira transparência e animações.' },
    @{ Id = 'balanced'; Label = 'Equilibrado'; Add = @(); Skip = @()
       Hint = 'Os ajustes recomendados, sem mexer na aparência nem no consumo de energia.' },
    @{ Id = 'notebook'; Label = 'Notebook'; Add = @(); Skip = @('powerplan', 'throttle', 'nvprofile', 'amdprofile', 'nicpower')
       Hint = 'Como o Equilibrado, sem o que esquenta e gasta bateria: plano de energia máximo e driver de vídeo em desempenho máximo.' }
)
$script:ProfileId = 'balanced'

function Get-Profile { return ($script:Profiles | Where-Object { $_.Id -eq $script:ProfileId } | Select-Object -First 1) }

# Ajustes que os perfis controlam: todos os liga/desliga que este PC aceita, menos os manuais.
function Get-ManagedToggles { return @($script:Tweaks | Where-Object { -not $_.Run -and -not $_.Manual -and (Test-Supported $_) }) }

# Deve ficar ligado no perfil atual?
function Test-InProfile($t) {
    $p = Get-Profile
    if ($t.Run -or $t.Manual) { return $false }
    if ($p.Skip -contains $t.Id) { return $false }
    if ($t.Optional) { return ($p.Add -contains $t.Id) }
    return $true
}

$script:TweakById = @{}
foreach ($t in $script:Tweaks) { $script:TweakById[$t.Id] = $t }

function Test-Supported($t) {
    if ($t.MinBuild -and $script:Build -lt $t.MinBuild) { return $false }
    if ($t.MaxBuild -and $script:Build -gt $t.MaxBuild) { return $false }
    if ($t.ExeOnly -and -not $script:Hosted) { return $false }
    if ($t.Gpu) {
        if ($script:GpuChoice -ne $t.Gpu) { return $false }
        if ($t.Gpu -eq 'nvidia') { return (Test-Nvidia) } else { return (Test-Amd) }
    }
    return $true
}

function Get-TweakReg($t) {
    if ($t.RegDyn) { return @(& $t.RegDyn) }
    if ($t.Reg)    { return @($t.Reg) }
    return @()
}

function Test-Tweak($t) {
    try {
        $entries = @(Get-TweakReg $t)
        if ($entries.Count -eq 0 -and -not $t.Test) { return $false }
        foreach ($e in $entries) { if (-not (Test-RegEntry $e)) { return $false } }
        if ($t.Test) { return [bool](& $t.Test) }
        return $true
    } catch { return $false }
}

$script:StateCache = @{}
function Get-TweakState($t, [switch]$Fresh) {
    if ($Fresh -or -not $script:StateCache.ContainsKey($t.Id)) { $script:StateCache[$t.Id] = [bool](Test-Tweak $t) }
    return $script:StateCache[$t.Id]
}

# Lista do que o Harle ativou: e o que a checagem do login mantem.
function Set-Applied([string]$Id, [bool]$On) {
    $list = @($script:Backup.state['applied'] | Where-Object { $_ -and $_ -ne $Id })
    if ($On) { $list += $Id }
    $script:Backup.state['applied'] = $list
}

function Enable-Tweak($t) {
    foreach ($e in @(Get-TweakReg $t)) { Set-RegEntry $e }
    if ($t.Apply) { & $t.Apply }
    Set-Applied $t.Id $true
    Save-Backup
    Write-Log "Ativado: $($t.Id)"
}

function Disable-Tweak($t) {
    foreach ($e in @(Get-TweakReg $t)) { Restore-RegEntry $e }
    if ($t.Revert) { & $t.Revert }
    Set-Applied $t.Id $false
    Save-Backup
    Write-Log "Revertido: $($t.Id)"
}

# Checagem silenciosa do login: reaplica so o que o Harle tinha ativado e o Windows desfez.
function Invoke-Reapply {
    $n = 0
    foreach ($id in @($script:Backup.state['applied'])) {
        $t = $script:TweakById[[string]$id]
        if (-not $t -or $t.Run -or -not (Test-Supported $t)) { continue }
        if (Test-Tweak $t) { continue }
        try { Enable-Tweak $t; $n++; Write-Log "Reaplicado no login: $id" }
        catch { Write-Log "Nao reaplicou $($id): $($_.Exception.Message)" }
    }
    Write-Log "Checagem do login: $n reaplicado(s)"
    return $n
}

# ---------------------------------------------------------------------------
#  Tela Otimizar: categorias, filtros, busca e o detalhe "o que este ajuste muda"
# ---------------------------------------------------------------------------
$script:TweakCats = @( @('fps', 'Desempenho'), @('gpu', 'Placa de vídeo'), @('reg', 'Registro'), @('debloat', 'Debloat'), @('priv', 'Privacidade'),
                       @('net', 'Rede'), @('qol', 'Conforto'), @('clean', 'Limpeza'), @('keep', 'Manutenção'), @('opt', 'Avançados') )

function Get-CatLabel([string]$Cat) {
    foreach ($c in $script:TweakCats) { if ($c[0] -eq $Cat) { return $c[1] } }
    return $Cat
}

# Minusculas e sem acento, para a busca achar "memoria" em "Memória".
function ConvertTo-Plain([string]$Text) {
    if (-not $Text) { return '' }
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $Text.ToLowerInvariant().Normalize([Text.NormalizationForm]::FormD).ToCharArray()) {
        if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch) -ne [Globalization.UnicodeCategory]::NonSpacingMark) { [void]$sb.Append($ch) }
    }
    return $sb.ToString()
}

# Recomendado = faz parte do perfil Equilibrado (as acoes de limpeza e remocao tambem rodam nele).
function Test-TweakRecommended($t) { return (-not $t.Optional -and -not $t.Manual) }

function Get-TweakKind($t) {
    if ($t.Run) { return 'AÇÃO' }
    if ($t.Gpu) { return 'DRIVER' }
    if ($t.Apply) { return 'SISTEMA' }
    return 'REGISTRO'
}

# Filtros: all, rec, on ou o codigo de uma categoria. A busca olha nome, descricao e categoria.
# Ajuste feito para a outra geracao do Windows (so 10 ou so 11) nem aparece na lista.
function Test-IsWin11 { return ($script:Build -ge 22000) }
function Test-ThisWindows($t) {
    if ($t.MaxBuild -and (Test-IsWin11)) { return $false }
    if ($t.MinBuild -ge 22000 -and -not (Test-IsWin11)) { return $false }
    return $true
}

function Select-Tweaks([string]$Filter, [string]$Search) {
    $needle = (ConvertTo-Plain $Search).Trim()
    $out = @()
    foreach ($t in $script:Tweaks) {
        $ok = switch ($Filter) {
            'rec'   { Test-TweakRecommended $t }
            'on'    { (-not $t.Run) -and (Test-Supported $t) -and (Get-TweakState $t) }
            ''      { $true }
            'all'   { $true }
            default { $t.Cat -eq $Filter }
        }
        if (-not $ok) { continue }
        if (-not (Test-ThisWindows $t)) { continue }
        if ($needle) {
            $hay = ConvertTo-Plain "$($t.Name) $($t.Desc) $(Get-CatLabel $t.Cat)"
            if ($hay.IndexOf($needle, [StringComparison]::Ordinal) -lt 0) { continue }
        }
        $out += $t
    }
    return @($out)
}

# Texto do (i): as chaves e valores exatos, na forma em que vao para o registro.
function Get-TweakDetail($t) {
    $L = New-Object 'System.Collections.Generic.List[string]'
    if ($t.Run -and $t.Manual) { $L.Add('Ação de uma vez: roda só quando você clica. Aplicar perfil não mexe nela.') }
    elseif ($t.Run) { $L.Add('Ação de uma vez: roda quando você clica, ou junto com Aplicar perfil. Não fica ligada.') }
    $reg = @()
    try { $reg = @(Get-TweakReg $t | Where-Object { $_ }) } catch { }
    $last = ''
    $shown = 0
    foreach ($e in $reg) {
        if ($shown -ge 24) { $L.Add((Tx '... e mais {0} valores.' ($($reg.Count - $shown)))); break }
        if ([string]$e.P -ne $last) { $L.Add([string]$e.P); $last = [string]$e.P }
        if ($e.Del) { $L.Add((Tx '    {0}: valor apagado' ($($e.N)))) } else { $L.Add((Tx '    {0} = {1}' ($($e.N)) ($($e.V)))) }
        $shown++
    }
    if ($t.Apply) { $L.Add('Aplicado por comandos do próprio Windows (energia, serviços, tarefas agendadas ou driver), como diz a descrição.') }
    if (-not $t.Run) {
        if ($reg.Count -eq 0 -and -not $t.Apply) { $L.Add('Neste PC não há nada para este ajuste mudar agora.') }
        $L.Add('O valor original fica guardado e volta quando você desliga.')
    }
    return ($L -join "`n")
}

# Quantos ajustes de liga/desliga de cada categoria existem neste PC e quantos estao ligados.
function Get-CatSummary {
    $out = @()
    foreach ($c in $script:TweakCats) {
        $all = @($script:Tweaks | Where-Object { $_.Cat -eq $c[0] })
        $tog = @($all | Where-Object { -not $_.Run -and (Test-Supported $_) })
        $on  = @($tog | Where-Object { Get-TweakState $_ }).Count
        $out += @{ Cat = $c[0]; Label = $c[1]; On = $on; Total = $tog.Count; Actions = @($all | Where-Object { $_.Run }).Count }
    }
    return $out
}

# ---------------------------------------------------------------------------
#  Exportar .reg
# ---------------------------------------------------------------------------
function ConvertTo-RegLine($e, [bool]$Undo) {
    $name = '"' + $e.N.Replace('\', '\\').Replace('"', '\"') + '"'
    if ($Undo) {
        if ($e.Del) { return $null }
        if (-not $e.ContainsKey('D')) { return "$name=-" }
        $v = $e.D
    } else {
        if ($e.Del) { return "$name=-" }
        $v = $e.V
    }
    if ($e.T -eq 'DWord') { return ('{0}=dword:{1:x8}' -f $name, (ConvertTo-UInt32 $v)) }
    return ('{0}="{1}"' -f $name, ([string]$v).Replace('\', '\\').Replace('"', '\"'))
}

function Get-RegFileText($TweakList, [bool]$Undo) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('Windows Registry Editor Version 5.00')
    foreach ($t in $TweakList) {
        if (-not $t.Reg) { continue }
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine("; $($t.Name)")
        $lastKey = ''
        foreach ($e in $t.Reg) {
            $line = ConvertTo-RegLine $e $Undo
            if ($null -eq $line) { continue }
            $full = $e.P -replace '^HKLM\\', 'HKEY_LOCAL_MACHINE\' -replace '^HKCU\\', 'HKEY_CURRENT_USER\'
            if ($full -ne $lastKey) { [void]$sb.AppendLine("[$full]"); $lastKey = $full }
            [void]$sb.AppendLine($line)
        }
    }
    return $sb.ToString()
}

# ---------------------------------------------------------------------------
#  Scanner de hardware
# ---------------------------------------------------------------------------
function Format-Capacity([double]$Bytes) {
    $gb = $Bytes / 1e9
    if ($gb -ge 1000) { return ('{0:N1} TB' -f ($gb / 1000)) }
    return ('{0:N0} GB' -f $gb)
}

function Get-Specs {
    $s = @{ Cpu = $null; Gpus = @(); Ram = $null; Disks = @(); Vols = @(); Board = $null; Os = $null; Display = $null; Sys = @{} }

    try {
        $c = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
        $short = ($c.Name -replace '\(R\)|\(TM\)', '' -replace '\s+\d+-Core Processor', '' -replace 'CPU\s*@.*', '' -replace 'with Radeon.*', '' -replace '^\s*(AMD|Intel)\s+', '').Trim()
        $s.Cpu = @{ Name = $c.Name.Trim(); Short = $short; Cores = [int]$c.NumberOfCores; Threads = [int]$c.NumberOfLogicalProcessors; MHz = [int]$c.MaxClockSpeed }
    } catch { }

    try {
        $vram = @{}
        $class = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
        foreach ($k in @(Get-ChildItem -Path $class -ErrorAction SilentlyContinue)) {
            $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
            if (-not $p -or -not $p.DriverDesc) { continue }
            $q = $p.'HardwareInformation.qwMemorySize'
            if ($null -eq $q) { continue }
            if ($q -is [byte[]]) { $q = [BitConverter]::ToInt64($q, 0) }
            $vram[[string]$p.DriverDesc] = [int64]$q
        }
        foreach ($g in @(Get-CimInstance Win32_VideoController -ErrorAction Stop)) {
            if ($g.Name -match 'Virtual|Remote|Basic|Parsec|Mirror|IddCx|DisplayLink') { continue }
            $bytes = [int64]0
            if ($vram.ContainsKey([string]$g.Name)) { $bytes = $vram[[string]$g.Name] }
            elseif ($g.AdapterRAM) { $bytes = [int64]$g.AdapterRAM }
            $drv = [string]$g.DriverVersion
            if ($g.Name -match 'NVIDIA' -and $drv -match '^\d+\.\d+\.(\d+)\.(\d+)$') {
                $digits = ($Matches[1] + $Matches[2])
                if ($digits.Length -ge 5) { $d5 = $digits.Substring($digits.Length - 5); $drv = $d5.Substring(0, 3) + '.' + $d5.Substring(3) }
            }
            $s.Gpus += @{
                Name = [string]$g.Name
                Short = ($g.Name -replace '^NVIDIA GeForce\s+', '' -replace '^AMD\s+', '' -replace '\(R\)|\(TM\)', '').Trim()
                VramGB = [Math]::Round($bytes / 1GB, 0)
                Driver = $drv; DriverDate = $g.DriverDate
                W = [int]$g.CurrentHorizontalResolution; H = [int]$g.CurrentVerticalResolution; Hz = [int]$g.CurrentRefreshRate
            }
        }
    } catch { }

    try {
        $sticks = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction Stop)
        $total  = ($sticks | Measure-Object Capacity -Sum).Sum
        $slots  = 0
        try { $slots = [int](@(Get-CimInstance Win32_PhysicalMemoryArray -ErrorAction Stop) | Measure-Object MemoryDevices -Sum).Sum } catch { }
        $first  = $sticks | Select-Object -First 1
        $speed  = [int]$first.ConfiguredClockSpeed
        if ($speed -le 0) { $speed = [int]$first.Speed }
        $type = switch ([int]$first.SMBIOSMemoryType) { 24 { 'DDR3' } 26 { 'DDR4' } 34 { 'DDR5' } default { '' } }
        $s.Ram = @{ TotalGB = [Math]::Round($total / 1GB, 0); Sticks = $sticks.Count; Slots = $slots; Speed = $speed; Rated = [int]$first.Speed; Type = $type
                    Part = ("$($first.Manufacturer) $($first.PartNumber)").Trim() }
    } catch { }

    try {
        foreach ($d in @(Get-PhysicalDisk -ErrorAction Stop)) {
            $kind = [string]$d.MediaType
            if ($kind -eq 'Unspecified' -or -not $kind) { $kind = 'Disco' }
            if ([string]$d.BusType -eq 'NVMe') { $kind = 'SSD NVMe' }
            $s.Disks += @{ Name = [string]$d.FriendlyName; Kind = $kind; Bytes = [double]$d.Size }
        }
    } catch {
        try { foreach ($d in @(Get-CimInstance Win32_DiskDrive)) { $s.Disks += @{ Name = [string]$d.Model; Kind = 'Disco'; Bytes = [double]$d.Size } } } catch { }
    }

    try {
        foreach ($v in @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop)) {
            $s.Vols += @{ Letter = [string]$v.DeviceID; Size = [double]$v.Size; Free = [double]$v.FreeSpace }
        }
    } catch { }

    try {
        $b    = Get-CimInstance Win32_BaseBoard -ErrorAction Stop | Select-Object -First 1
        $bios = Get-CimInstance Win32_BIOS -ErrorAction Stop | Select-Object -First 1
        $s.Board = @{ Maker = [string]$b.Manufacturer; Model = [string]$b.Product; Bios = [string]$bios.SMBIOSBIOSVersion; BiosDate = $bios.ReleaseDate }
    } catch { }

    try {
        $o   = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $ver = (Get-RegState 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'DisplayVersion').Value
        $s.Os = @{ Name = ([string]$o.Caption -replace '^Microsoft\s+', '').Trim(); Version = [string]$ver; Build = [string]$o.BuildNumber; Arch = [string]$o.OSArchitecture; Boot = $o.LastBootUpTime }
    } catch { }

    try {
        $main = $s.Gpus | Where-Object { $_.W -gt 0 } | Select-Object -First 1
        if ($main) {
            $max = 0
            try {
                $modes = @(Get-CimInstance CIM_VideoControllerResolution -ErrorAction Stop | Where-Object { $_.HorizontalResolution -eq $main.W -and $_.VerticalResolution -eq $main.H })
                $max = [int]($modes | Measure-Object RefreshRate -Maximum).Maximum
            } catch { }
            $s.Display = @{ W = $main.W; H = $main.H; Hz = $main.Hz; MaxHz = $max }
        }
    } catch { }

    $s.IsLaptop = $false
    try { $s.IsLaptop = @(Get-CimInstance Win32_Battery -ErrorAction Stop).Count -gt 0 } catch { }
    # Em que tipo de disco o Windows esta instalado.
    $s.SysDisk = ''
    try {
        $letter = ([string]$env:SystemDrive).TrimEnd(':')
        $num = (Get-Partition -DriveLetter $letter -ErrorAction Stop | Select-Object -First 1).DiskNumber
        $pd = Get-PhysicalDisk -ErrorAction Stop | Where-Object { [string]$_.DeviceId -eq [string]$num } | Select-Object -First 1
        if ($pd) { $s.SysDisk = if ([string]$pd.BusType -eq 'NVMe') { 'SSD NVMe' } else { [string]$pd.MediaType } }
    } catch { }

    # O que da para saber da BIOS pelo Windows: modo de inicializacao, Secure Boot, TPM e Resizable BAR.
    $s.Fw = @{ Mode = ''; SecureBoot = $null; Tpm = ''; Rebar = '' }
    try {
        $t = Get-RegState 'HKLM\SYSTEM\CurrentControlSet\Control' 'PEFirmwareType'
        if ($t.Exists) { $s.Fw.Mode = switch ([int]$t.Value) { 2 { 'UEFI' } 1 { 'Legacy' } default { '' } } }
    } catch { }
    try {
        $sb = Get-RegState 'HKLM\SYSTEM\CurrentControlSet\Control\SecureBoot\State' 'UEFISecureBootEnabled'
        if ($sb.Exists) { $s.Fw.SecureBoot = ([int]$sb.Value -eq 1) } elseif ($s.Fw.Mode -eq 'Legacy') { $s.Fw.SecureBoot = $false }
    } catch { }
    try {
        $tpm = @(Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftTpm' -ClassName Win32_Tpm -ErrorAction Stop) | Select-Object -First 1
        if ($tpm) {
            $v = (([string]$tpm.SpecVersion) -split ',')[0].Trim()
            $s.Fw.Tpm = if ($v -match '^2') { '2.0' } elseif ($v) { $v } else { 'none' }
        } else { $s.Fw.Tpm = 'none' }
    } catch { }
    # Resizable BAR: com ele ligado a placa de video aparece com uma faixa de memoria do tamanho da VRAM (GBs);
    # sem ele a faixa e de 256 MB. So afirma "ligado"; quando nao acha a faixa grande, fica sem resposta.
    try {
        foreach ($vc in @(Get-CimInstance Win32_VideoController -ErrorAction Stop)) {
            if (-not $vc.PNPDeviceID -or [string]$vc.Name -match 'Virtual|Remote|Basic|Parsec|Mirror|IddCx|DisplayLink') { continue }
            $id = ([string]$vc.PNPDeviceID).Replace('\', '\\').Replace("'", "''")
            $pnp = Get-CimInstance Win32_PnPEntity -Filter "DeviceID='$id'" -ErrorAction Stop | Select-Object -First 1
            if (-not $pnp) { continue }
            foreach ($m in @(Get-CimAssociatedInstance -InputObject $pnp -ResultClassName Win32_DeviceMemoryAddress -ErrorAction Stop)) {
                $size = [double]$m.EndingAddress - [double]$m.StartingAddress + 1
                if ($size -ge 1GB) { $s.Fw.Rebar = 'on' }
            }
        }
    } catch { }

    $s.Sys.Plan = (Get-ActivePlan).Name
    $gm = Get-RegState 'HKCU\Software\Microsoft\GameBar' 'AutoGameModeEnabled'
    $s.Sys.GameMode = (-not $gm.Exists) -or ([int]$gm.Value -ne 0)
    $hs = Get-RegState 'HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode'
    $s.Sys.Hags = $hs.Exists -and ([int]$hs.Value -eq 2)
    $s.Sys.Hvci = $false
    try {
        $dg = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard -ErrorAction Stop
        $s.Sys.Hvci = @($dg.SecurityServicesRunning) -contains 2
    } catch { }
    return $s
}

function Get-Diagnostics($s) {
    $out = @()
    if ($s.Ram) {
        $r = $s.Ram
        if ($r.Type -eq 'DDR4' -and $r.Speed -gt 0 -and $r.Speed -le 2666) {
            $out += @{ Level = 'warn'; Title = (Tx 'Memória rodando a {0} MHz' ($($r.Speed)))
                       Text = 'Isso costuma indicar XMP/DOCP desligado na BIOS. Com um kit de 3200 ou 3600 MHz, ligar o perfil é o maior ganho gratuito que existe: de 10 a 20% em jogos limitados pelo processador, principalmente em Ryzen.' }
        } elseif ($r.Speed -gt 0) {
            $out += @{ Level = 'ok'; Title = (Tx 'Memória a {0} MHz' ($($r.Speed))); Text = 'A velocidade está em um bom nível para o seu processador.' }
        }
        if ($r.Sticks -eq 1) {
            $out += @{ Level = 'warn'; Title = 'Um único pente de memória'
                       Text = 'Em single channel o processador perde bastante desempenho em jogos. Dois pentes iguais em dual channel resolvem.' }
        } elseif ($r.Sticks -ge 2) {
            $out += @{ Level = 'ok'; Title = (Tx '{0} pentes de memória' $r.Sticks); Text = 'Com os pentes nos slots certos da placa-mãe (em geral o 2º e o 4º), você está em dual channel.' }
        }
        if ($r.TotalGB -gt 0 -and $r.TotalGB -le 16) {
            $out += @{ Level = 'info'; Title = (Tx '{0} GB de RAM' $r.TotalGB)
                       Text = 'Dá conta dos jogos atuais, mas sem folga. Feche o navegador antes de jogar títulos pesados.' }
        }
    }
    if ($s.Display -and $s.Display.MaxHz -ge ($s.Display.Hz + 10)) {
        $out += @{ Level = 'warn'; Title = (Tx 'Monitor em {0} Hz' ($($s.Display.Hz)))
                   Text = (Tx 'O modo atual parece aceitar até {0} Hz. Mude em Configurações > Sistema > Tela > Tela avançada.' ($($s.Display.MaxHz))) }
    }
    foreach ($g in $s.Gpus) {
        if ($g.DriverDate) {
            $age = [int]((Get-Date) - $g.DriverDate).TotalDays
            if ($age -gt 150) {
                $out += @{ Level = 'warn'; Title = (Tx 'Driver de vídeo com {0} meses' ($([int]($age / 30))))
                           Text = (Tx 'O driver da {0} é antigo. Drivers novos trazem otimizações para jogos recentes; baixe pelo app da fabricante.' ($($g.Short))) }
            } else {
                $out += @{ Level = 'ok'; Title = 'Driver de vídeo recente'; Text = (Tx 'Versão {0}, de {1}.' ($($g.Driver)) ($($g.DriverDate.ToString('dd/MM/yyyy')))) }
            }
        }
        if ($g.VramGB -gt 0 -and $g.VramGB -le 6) {
            $out += @{ Level = 'info'; Title = (Tx '{0} GB de memória de vídeo' $g.VramGB)
                       Text = 'É o limite desta placa em jogos novos. Mantenha texturas em Médio ou Alto e use DLSS em Qualidade; estourar a VRAM causa travadas fortes.' }
        }
    }
    $sys = $s.Vols | Where-Object { $_.Letter -eq $env:SystemDrive } | Select-Object -First 1
    if ($sys -and $sys.Size -gt 0) {
        $pct = [int](100 * $sys.Free / $sys.Size)
        if ($pct -lt 15) {
            $out += @{ Level = 'warn'; Title = (Tx 'Disco {0} com {1}% livre' ($($sys.Letter)) ($pct))
                       Text = 'SSDs ficam mais lentos quando quase cheios. A limpeza do Harle apaga os temporários; tente manter pelo menos 15% livre.' }
        }
    }
    if (@($s.Disks | Where-Object { $_.Kind -eq 'HDD' }).Count -gt 0) {
        $out += @{ Level = 'info'; Title = 'Há um HD mecânico no PC'; Text = 'Deixe os jogos no SSD. No HD o carregamento é bem mais lento e mundos abertos travam ao carregar o cenário.' }
    }
    if ($s.Sys.Hvci) {
        $out += @{ Level = 'info'; Title = 'Integridade de Memória ligada'; Text = 'É uma proteção do Windows que custa um pouco de desempenho, mas o Vanguard (Valorant e League of Legends) pode exigir que fique ligada. Desligar é opcional, no filtro Avançados da tela Otimizar.' }
    }
    return $out
}

# ---------------------------------------------------------------------------
#  Relatorio para pedir ajuda, cartao de resultado e alerta de temperatura (a parte sem tela)
# ---------------------------------------------------------------------------
function Limit-Text([string]$Text, [int]$Max) {
    if ($Text.Length -le $Max) { return $Text }
    return $Text.Substring(0, [Math]::Max(0, $Max - 3)).TrimEnd() + '...'
}

# Texto pronto para colar no Discord, que aceita ate 2000 caracteres por mensagem.
# $State: @{ Profile; Gpu; Hosted; On = nomes ligados; Off = nomes desligados; Fps = ultima medicao ou $null }
function Get-ReportText($Specs, $State, [string[]]$LogLines, [int]$MaxLength = 1950) {
    $s = $Specs
    $L = New-Object 'System.Collections.Generic.List[string]'
    $onOff = { param($b) if ($b) { 'ligado' } else { 'desligado' } }
    if ($s -and $s.Os)  { $L.Add("Windows: $($s.Os.Name) $($s.Os.Version), build $($s.Os.Build), $($s.Os.Arch)") }
    if ($s -and $s.Cpu) { $L.Add((Tx 'Processador: {0} ({1} núcleos, {2} threads)' ($($s.Cpu.Name)) ($($s.Cpu.Cores)) ($($s.Cpu.Threads)))) }
    if ($s) {
        foreach ($g in @($s.Gpus)) {
            $vram = if ($g.VramGB -gt 0) { ", $($g.VramGB) GB" } else { '' }
            $date = if ($g.DriverDate) { (Tx ' de {0}' ($($g.DriverDate.ToString('dd/MM/yyyy')))) } else { '' }
            $L.Add((Tx 'Placa de vídeo: {0}{1}, driver {2}{3}' ($($g.Name)) ($vram) ($($g.Driver)) ($date)))
        }
    }
    if ($s -and $s.Ram) {
        $speed = if ($s.Ram.Speed -gt 0) { (Tx ' a {0} MHz' ($($s.Ram.Speed))) } else { '' }
        $L.Add(((Tx 'Memória: {0} GB {1}' ($($s.Ram.TotalGB)) ($($s.Ram.Type)))).Trim() + "$speed, $($s.Ram.Sticks) pentes")
    }
    if ($s -and $s.Board)   { $L.Add((Tx 'Placa-mãe: {0} {1}, BIOS {2}' ($($s.Board.Maker)) ($($s.Board.Model)) ($($s.Board.Bios)))) }
    if ($s -and $s.Display) { $L.Add((Tx 'Tela: {0} x {1} a {2} Hz' ($($s.Display.W)) ($($s.Display.H)) ($($s.Display.Hz)))) }
    if ($s -and @($s.Disks).Count -gt 0) {
        $disks = @($s.Disks | ForEach-Object { "$($_.Kind) $(Format-Capacity $_.Bytes)" }) -join ', '
        $sys = @($s.Vols | Where-Object { $_.Letter -eq $env:SystemDrive }) | Select-Object -First 1
        $free = if ($sys) { ((Tx '; {0} com {1:N0} GB livres') -f $sys.Letter, ($sys.Free / 1GB)) } else { '' }
        $L.Add("Discos: $disks$free")
    }
    if ($s -and $s.Sys) {
        $hvci = if ($s.Sys.Hvci) { 'ligada' } else { 'desligada' }
        $L.Add((Tx 'Plano de energia: {0} | Modo de Jogo {1} | Agendamento de GPU {2} | Integridade de Memória {3}' ($($s.Sys.Plan)) ($(& $onOff $s.Sys.GameMode)) ($(& $onOff $s.Sys.Hags)) ($hvci)))
    }
    $exe = if ($State.Hosted) { 'Harle.exe' } else { 'script' }
    $L.Add("Perfil: $($State.Profile) | Placa escolhida: $($State.Gpu) | Aberto pelo $exe")
    $on = @($State.On); $off = @($State.Off)
    $count = (Tx 'Ajustes ligados: {0} de {1}' ($($on.Count)) ($($on.Count + $off.Count)))
    # Lista o lado menor: com quase tudo ligado, o que interessa e o que ficou de fora.
    if ($on.Count -eq 0 -or $off.Count -eq 0) { $L.Add($count) }
    elseif ($on.Count -le $off.Count) { $L.Add((Limit-Text "$count. Ligados: $($on -join '; ')" 620)) }
    else { $L.Add((Limit-Text "$count. Desligados: $($off -join '; ')" 620)) }
    if ($State.Fps) {
        $f = $State.Fps
        $L.Add(((Tx 'Última medição: {0}, {1:N1} FPS de média e {2:N1} de 1% low ({3}, {4} ajustes ativos)') -f $f.App, [double]$f.Avg, [double]$f.Low, $f.When, $f.Active))
    }
    $head = "**Relatório do Harle Optimizer $($script:AppVersion)** ($((Get-Date).ToString('dd/MM/yyyy HH:mm')))`n" + '```' + "`n"
    $tail = "`n" + '```'
    $body = ($L -join "`n")
    # O nome da conta do Windows nao precisa ir para um servidor publico.
    $clean = { param($t) ([string]$t -replace '(?i)\\Users\\[^\\"'']+', '\Users\(conta)' -replace '`', "'") }
    $body = & $clean $body
    $room = $MaxLength - $head.Length - $tail.Length
    $body = Limit-Text $body $room
    # O fim do log entra do mais novo para o mais velho, ate onde couber.
    $keep = New-Object 'System.Collections.Generic.List[string]'
    $left = $room - $body.Length - "`nFim do log:".Length
    $all = @($LogLines | Where-Object { $_ })
    for ($i = $all.Count - 1; $i -ge 0 -and $keep.Count -lt 12; $i--) {
        $line = Limit-Text (& $clean $all[$i]) 160
        if ($line.Length + 1 -gt $left) { break }
        $keep.Insert(0, $line)
        $left -= ($line.Length + 1)
    }
    if ($keep.Count -gt 0) { $body = $body + "`nFim do log:`n" + ($keep -join "`n") }
    return $head + $body + $tail
}

# Par de medicoes para o cartao: "depois" e a mais recente; "antes" e a do mesmo jogo com menos ajustes ativos
# (no empate, a mais antiga). Sem duas medicoes do mesmo jogo nao ha cartao.
function Get-CardPair($List) {
    $all = @($List | Where-Object { $_ })
    if ($all.Count -lt 2) { return $null }
    $after = $all[$all.Count - 1]
    $before = $null
    for ($i = 0; $i -lt $all.Count - 1; $i++) {
        $m = $all[$i]
        if ([string]$m.App -ne [string]$after.App -or [double]$m.Avg -le 0) { continue }
        if ($null -eq $before -or [int]$m.Active -lt [int]$before.Active) { $before = $m }
    }
    if (-not $before) { return $null }
    return @{ Before = $before; After = $after }
}

function Format-Gain([double]$Before, [double]$After) {
    if ($Before -le 0) { return '' }
    return ('{0:+0.0;-0.0;0.0}%' -f (100.0 * ($After - $Before) / $Before))
}

# Alerta de temperatura. Devolve 'raise' (passou do limite por 3 leituras seguidas), 'repeat' (continua quente,
# um novo aviso por minuto), 'clear' (voltou a ficar 3 graus abaixo do limite) ou 'none'.
function Step-TempAlert($A, [double]$Temp, [datetime]$Now) {
    if (-not $A.On -or $Temp -lt 0) { return 'none' }
    if ($Temp -ge $A.Limit) {
        $A.Hot = [int]$A.Hot + 1
        if (-not $A.Active) {
            if ($A.Hot -lt 3) { return 'none' }
            $A.Active = $true; $A.Last = $Now
            return 'raise'
        }
        if (($Now - [datetime]$A.Last).TotalSeconds -ge 60) { $A.Last = $Now; return 'repeat' }
        return 'none'
    }
    $A.Hot = 0
    if ($A.Active -and $Temp -le ($A.Limit - 3)) { $A.Active = $false; return 'clear' }
    return 'none'
}

# ---------------------------------------------------------------------------
#  Aba Upgrade: o que vale trocar neste PC.
#  As notas sao estimativas por modelo (GeForce RTX 3060 = 100 nas placas, Ryzen 5 5600 = 100 nos processadores)
#  e servem so para decidir qual peca limita o conjunto. Nao sao medicao.
#  Os modelos sugeridos sao exemplos da data abaixo; a lista precisa ser revista a cada versao.
# ---------------------------------------------------------------------------
$script:UpgradeDate = 'outubro de 2026'

# Do mais especifico para o mais generico: "RTX 4070 Ti" precisa vir antes de "RTX 4070".
$script:GpuTable = @(
    @('RTX\s*5090', 450), @('RTX\s*5080', 325), @('RTX\s*5070\s*Ti', 280), @('RTX\s*5070', 222), @('RTX\s*5060\s*Ti', 165), @('RTX\s*5060', 140), @('RTX\s*5050', 105),
    @('RTX\s*4090', 355), @('RTX\s*4080', 286), @('RTX\s*4070\s*Ti\s*SUPER', 248), @('RTX\s*4070\s*Ti', 228), @('RTX\s*4070\s*SUPER', 213), @('RTX\s*4070', 185),
    @('RTX\s*4060\s*Ti', 144), @('RTX\s*4060', 118), @('RTX\s*4050', 95),
    @('RTX\s*3090\s*Ti', 240), @('RTX\s*3090', 218), @('RTX\s*3080\s*Ti', 212), @('RTX\s*3080', 190), @('RTX\s*3070\s*Ti', 157), @('RTX\s*3070', 148),
    @('RTX\s*3060\s*Ti', 130), @('RTX\s*3060', 100), @('RTX\s*3050', 70),
    @('RTX\s*2080\s*Ti', 126), @('RTX\s*2080\s*SUPER', 109), @('RTX\s*2080', 104), @('RTX\s*2070\s*SUPER', 98), @('RTX\s*2070', 87), @('RTX\s*2060\s*SUPER', 84), @('RTX\s*2060', 74),
    @('GTX\s*1660\s*Ti', 62), @('GTX\s*1660\s*SUPER', 61), @('GTX\s*1660', 54), @('GTX\s*1650\s*SUPER', 46), @('GTX\s*1650', 35), @('GTX\s*1630', 17),
    @('GTX\s*1080\s*Ti', 91), @('GTX\s*1080', 71), @('GTX\s*1070\s*Ti', 66), @('GTX\s*1070', 59), @('GTX\s*1060', 45), @('GTX\s*1050\s*Ti', 27), @('GTX\s*1050', 22), @('GT\s*1030', 13),
    @('GTX\s*980\s*Ti', 51), @('GTX\s*980', 41), @('GTX\s*970', 35), @('GTX\s*960', 23), @('GTX\s*950', 19), @('GTX\s*750\s*Ti', 15), @('GT\s*7[1-4]0', 6),
    @('RX\s*9070\s*XT', 270), @('RX\s*9070', 240), @('RX\s*9060\s*XT', 160), @('RX\s*9060', 135),
    @('RX\s*7900\s*XTX', 290), @('RX\s*7900\s*XT', 252), @('RX\s*7900\s*GRE', 215), @('RX\s*7800\s*XT', 198), @('RX\s*7700\s*XT', 165), @('RX\s*7600\s*XT', 118), @('RX\s*7600', 112),
    @('RX\s*6950\s*XT', 220), @('RX\s*6900\s*XT', 208), @('RX\s*6800\s*XT', 192), @('RX\s*6800', 168), @('RX\s*6750\s*XT', 138), @('RX\s*6700\s*XT', 132), @('RX\s*6700', 118),
    @('RX\s*6650\s*XT', 106), @('RX\s*6600\s*XT', 103), @('RX\s*6600', 86), @('RX\s*6500\s*XT', 45), @('RX\s*6400', 38),
    @('RX\s*5700\s*XT', 95), @('RX\s*5700', 83), @('RX\s*5600\s*XT', 73), @('RX\s*5500\s*XT', 50),
    @('RX\s*590', 45), @('RX\s*580', 41), @('RX\s*570', 34), @('RX\s*560', 19), @('RX\s*550', 12),
    @('Arc.*B580', 125), @('Arc.*B570', 110), @('Arc.*A770', 102), @('Arc.*A750', 95), @('Arc.*A580', 85), @('Arc.*A380', 30),
    @('Radeon.*(890M|880M)', 38), @('Radeon.*(780M|760M|680M)', 30), @('Vega|Radeon\(TM\)\s+Graphics|Radeon\s+Graphics', 14), @('Iris', 12), @('UHD|HD\s+Graphics', 5)
)

# Faixas de placa nova, com exemplos a venda na data acima.
$script:GpuPicks = @(
    @{ Score = 135; Label = 'Entrada';       Models = 'Intel Arc B580 12 GB, Radeon RX 9060 XT 8 GB ou GeForce RTX 5060 8 GB'; Use = 'Para 1080p em qualidade alta' }
    @{ Score = 162; Label = 'Intermediária'; Models = 'Radeon RX 9060 XT 16 GB ou GeForce RTX 5060 Ti 16 GB'; Use = 'Para 1080p no máximo e 1440p em alto, com folga de memória de vídeo' }
    @{ Score = 230; Label = 'Alta';          Models = 'GeForce RTX 5070 12 GB ou Radeon RX 9070 16 GB'; Use = 'Para 1440p em qualidade alta com FPS alto' }
    @{ Score = 275; Label = 'Muito alta';    Models = 'Radeon RX 9070 XT 16 GB ou GeForce RTX 5070 Ti 16 GB'; Use = 'Para 1440p no máximo e 4K com DLSS ou FSR' }
)

# Placas que funcionam so com a energia do slot: quem tem uma delas costuma ter fonte fraca ou sem cabo PCIe.
$script:GpuSlotPowered = 'GTX\s*1050|GTX\s*1630|GTX\s*1650(?!\s*SUPER)|GT\s*\d|RX\s*6400|RX\s*550|RX\s*560|Arc.*A380'

function Get-GpuInfo($Gpu, [bool]$Laptop) {
    $r = @{ Known = $false; Score = 0; Integrated = $false; SlotPowered = $false; Mobile = $false }
    if (-not $Gpu) { return $r }
    $n = [string]$Gpu.Name
    foreach ($row in $script:GpuTable) {
        if ($n -match ('(?i)' + $row[0] + '(?![0-9])')) { $r.Known = $true; $r.Score = [double]$row[1]; break }
    }
    if (-not $r.Known) { return $r }
    $vram = [double]$Gpu.VramGB
    # Mesmo nome, placas diferentes: a quantidade de memoria desempata.
    if ($n -match '(?i)RTX\s*3050' -and $vram -gt 0 -and $vram -le 6) { $r.Score = $(if ($vram -le 4) { 45 } else { 56 }); $r.SlotPowered = ($vram -gt 4) }
    if ($n -match '(?i)GTX\s*1060' -and $vram -gt 0 -and $vram -le 3) { $r.Score = 40 }
    $r.Integrated = ($n -match '(?i)Vega|Radeon\(TM\)\s+Graphics|Radeon\s+Graphics|Iris|UHD|HD\s+Graphics|\b\d{3}M\b')
    if ($n -match ('(?i)' + $script:GpuSlotPowered)) { $r.SlotPowered = $true }
    $r.Mobile = $Laptop -or ($n -match '(?i)Laptop|Mobile|Max-Q')
    if ($r.Mobile -and -not $r.Integrated) { $r.Score = [Math]::Round($r.Score * 0.82) }
    return $r
}

function Get-CpuInfo($Cpu, [bool]$Laptop) {
    $r = @{ Known = $false; Score = 0; Platform = 'unknown'; Mobile = $false; X3D = $false }
    if (-not $Cpu) { return $r }
    $n = [string]$Cpu.Name
    if ($n -match 'Ryzen\s+(\d)\s+(?:PRO\s+)?(\d)(\d{3})([A-Za-z0-9]*)') {
        $tier = [int]$Matches[1]; $gen = [int]$Matches[2]; $num = [string]$Matches[3]; $suf = ([string]$Matches[4]).ToUpper()
        $r.Mobile = $Laptop -or ($suf -match '^(U|H|HS|HX|C)$') -or ($gen -eq 6)
        $r.X3D = $suf -match 'X3D'
        $base = switch ($gen) { 1 { 55 } 2 { 62 } 3 { 78 } 4 { 75 } 5 { 100 } 6 { 100 } 7 { 128 } 8 { 115 } 9 { 138 } default { 0 } }
        if ($gen -eq 3 -and $suf -match '^G') { $base = 62 }
        # 5500, 5600G, 5700G e o 5700 sem X tem menos cache que os outros Zen 3.
        if ($gen -eq 5 -and ($suf -match '^G' -or $num -eq '500' -or ($num -eq '700' -and $suf -eq ''))) { $base = 88 }
        if ($r.X3D) { $base = switch ($gen) { 5 { 120 } 7 { 155 } 9 { 170 } default { $base } } }
        if ($tier -eq 3) { $base = $base * 0.85 }
        if ($base -le 0) { return $r }
        $r.Known = $true
        $r.Platform = if ($r.Mobile) { 'laptop' } elseif ($gen -le 5) { 'AM4' } else { 'AM5' }
        $r.Score = [Math]::Round($(if ($r.Mobile) { $base * 0.85 } else { $base }))
        return $r
    }
    if ($n -match 'Core(?:\(TM\))?\s+Ultra\s+(\d)\s+(\d)(\d{2})([A-Za-z]*)') {
        $tier = [int]$Matches[1]; $series = [int]$Matches[2]; $suf = ([string]$Matches[4]).ToUpper()
        $r.Mobile = $Laptop -or ($series -ne 2) -or ($suf -match '^(U|H|HX|V)$')
        $base = switch ($tier) { 5 { 118 } 7 { 125 } 9 { 128 } default { 110 } }
        $r.Known = $true
        $r.Platform = if ($r.Mobile) { 'laptop' } else { 'LGA1851' }
        $r.Score = [Math]::Round($(if ($r.Mobile) { $base * 0.8 } else { $base }))
        return $r
    }
    if ($n -match 'i([3579])[- ](\d{4,5})([A-Za-z0-9]*)') {
        $tier = [int]$Matches[1]; $num = [string]$Matches[2]; $suf = ([string]$Matches[3]).ToUpper()
        $gen = if ($num.Length -eq 5) { [int]$num.Substring(0, 2) } else { [int]$num.Substring(0, 1) }
        # Notebooks da 10a a 13a geracao usam 4 digitos comecando em 1: i5-1035G1, i7-1165G7, i5-1235U.
        $lowPower = ($num.Length -eq 4 -and $gen -eq 1)
        if ($lowPower) { $gen = [int]$num.Substring(0, 2) }
        $r.Mobile = $Laptop -or $lowPower -or ($suf -match '^(U|H|HK|HS|HX|HQ|MQ|M|Y|P|G\d)$')
        $base = switch ($gen) { 2 { 33 } 3 { 36 } 4 { 45 } 5 { 47 } 6 { 55 } 7 { 57 } 8 { 68 } 9 { 72 } 10 { 76 } 11 { 86 } 12 { 110 } 13 { 125 } 14 { 127 } default { 0 } }
        if ($base -le 0) { return $r }
        # i3 ate a 7a geracao tem 2 nucleos; i5 ate a 7a tem 4 nucleos sem threads extras.
        if ($tier -eq 3) { $base = $base * $(if ($gen -le 7) { 0.7 } else { 0.86 }) }
        elseif ($tier -eq 5 -and $gen -le 7) { $base = $base * 0.85 }
        $r.Known = $true
        $r.Platform = if ($r.Mobile) { 'laptop' } elseif ($gen -ge 12) { 'LGA1700' } elseif ($gen -ge 10) { 'LGA1200' } elseif ($gen -ge 6) { 'LGA1151' } else { 'old' }
        $r.Score = [Math]::Round($(if ($r.Mobile) { $base * 0.8 } else { $base }))
        return $r
    }
    if ($n -match 'FX\(tm\)|FX-\d|Athlon|Pentium|Celeron|Phenom|Core\(TM\)2|Atom|A\d{1,2}-\d{4}') {
        $r.Known = $true; $r.Score = 35; $r.Mobile = $Laptop
        $r.Platform = if ($Laptop) { 'laptop' } else { 'old' }
    }
    return $r
}

function Format-Times([double]$Ratio) {
    if ($Ratio -ge 1.95) { return ((Tx 'cerca de {0:0.#} vezes o desempenho da sua') -f $Ratio) }
    return ((Tx 'cerca de {0:0}% a mais de desempenho que a sua') -f (($Ratio - 1) * 100))
}

# Devolve @{ Headline; Limiter; Items }. Cada item: Level (free, now, later, ok, info), Part, Title, Why, Rows.
function Get-UpgradePlan($s) {
    $items = New-Object System.Collections.ArrayList
    if (-not $s) { return @{ Headline = 'Sem leitura do hardware. Clique em Escanear de novo.'; Limiter = ''; Items = @() } }
    $laptop = [bool]$s.IsLaptop
    $gpu = if (@($s.Gpus).Count -gt 0) { $s.Gpus[0] } else { $null }
    # Com placa dedicada e integrada juntas, vale a mais forte.
    $gi = Get-GpuInfo $gpu $laptop
    foreach ($other in @($s.Gpus)) {
        $oi = Get-GpuInfo $other $laptop
        if ($oi.Known -and $oi.Score -gt $gi.Score) { $gi = $oi; $gpu = $other }
    }
    $ci = Get-CpuInfo $s.Cpu $laptop
    if ($ci.Mobile -or $gi.Mobile) { $laptop = $true }
    $g = [double]$gi.Score; $c = [double]$ci.Score
    $both = $gi.Known -and $ci.Known
    $gpuLimits = $both -and ($g -lt $c * 0.9)
    $cpuLimits = $both -and ($g -gt $c * 2.4)
    $limiter = if ($gpuLimits) { 'gpu' } elseif ($cpuLimits) { 'cpu' } else { '' }
    $when = $script:UpgradeDate

    # ----- Gratis primeiro -----
    if ($s.Ram -and $s.Ram.Type -eq 'DDR4' -and $s.Ram.Speed -gt 0 -and $s.Ram.Speed -le 2666) {
        [void]$items.Add(@{ Level = 'free'; Part = 'Memória'; Title = 'Antes de gastar: ligue o XMP na BIOS'
            Why = (Tx 'A memória está rodando a {0} MHz, o que costuma indicar o perfil XMP (ou DOCP) desligado. Ligar é de graça e rende de 10 a 20% em jogos limitados pelo processador.' ($($s.Ram.Speed)))
            Rows = @( , @('Como', 'O passo a passo para a sua placa-mãe está na aba BIOS. Se o kit for mesmo de 2666 MHz ou menos, nada muda.')) })
    }
    if ($s.Display -and $s.Display.MaxHz -ge ($s.Display.Hz + 10)) {
        [void]$items.Add(@{ Level = 'free'; Part = 'Monitor'; Title = (Tx 'O monitor está em {0} Hz e aceita {1} Hz' ($($s.Display.Hz)) ($($s.Display.MaxHz)))
            Why = 'A tela está mostrando menos quadros do que consegue. É só mudar a taxa nas configurações do Windows.'
            Rows = @( , @('Como', 'Configurações, Sistema, Tela, Tela avançada, e escolha a taxa de atualização mais alta.')) })
    }
    if ($s.Os -and [int]$s.Os.Build -gt 0 -and [int]$s.Os.Build -lt 22000) {
        [void]$items.Add(@{ Level = 'free'; Part = 'Sistema'; Title = 'O Windows 10 saiu de suporte'
            Why = 'Desde outubro de 2025 o Windows 10 não recebe correções de segurança (fora do programa pago de extensão), e drivers e jogos novos vão deixando de testar nele.'
            Rows = @( , @('Como', 'Se o PC for compatível, a atualização para o Windows 11 é gratuita pelo Windows Update. O app Verificação de Integridade do PC, da Microsoft, diz se é.')) })
    }

    # ----- Placa de video -----
    if ($gpu -and $laptop) {
        [void]$items.Add(@{ Level = 'info'; Part = 'Placa de vídeo'; Title = 'Em notebook a placa de vídeo não troca'
            Why = (Tx 'A {0} é soldada na placa-mãe, e o processador também. O que dá para melhorar em notebook é memória, SSD e a limpeza da refrigeração.' ($($gpu.Short)))
            Rows = @( , @('Refrigeração', 'Limpar as ventoinhas e trocar a pasta térmica a cada dois ou três anos devolve o desempenho que o calor tira.')) })
    } elseif ($gpu -and $gi.Known) {
        $vram = [double]$gpu.VramGB
        $level = if ($gpuLimits -or $g -lt 60) { 'now' } elseif ($g -lt 125 -or ($vram -gt 0 -and $vram -le 6)) { 'later' } else { 'ok' }
        $rows = @()
        $hoje = "$($gpu.Short)" + $(if ($vram -gt 0) { ", $vram GB" } else { '' }) + (Tx '. Pela estimativa do Harle, rende perto de {0}% de uma GeForce RTX 3060.' ($([int]$g)))
        $rows += , @('Hoje', $hoje)
        if ($level -ne 'ok') {
            # Sem processador reconhecido nao ha teto; com ele, placa forte demais sobra em 1080p.
            $cap = if ($ci.Known) { $c * 2.4 } else { 100000 }
            $picks = @($script:GpuPicks | Where-Object { $_.Score -ge $g * 1.4 -and $_.Score -le $cap } | Select-Object -First 3)
            foreach ($p in $picks) { $rows += , @($p.Label, (Tx '{0}. {1}: {2}.' (Tr $p.Models) (Tr $p.Use) (Format-Times ($p.Score / $g)))) }
            if ($g -lt 70) { $rows += , @('Usada, mais barata', (Tx 'GeForce RTX 3060 12 GB, RTX 3060 Ti ou Radeon RX 6700 XT, de loja com garantia: {0}.' ($(Format-Times (110 / $g))))) }
            if ($picks.Count -eq 0 -and $ci.Known) { $rows += , @('Atenção', 'Com este processador, uma placa nova renderia bem menos do que pode. Veja o item do processador antes de comprar.') }
            $rows += , @('Memória de vídeo', 'Prefira 12 GB ou mais. Hoje 8 GB é o mínimo e já aperta em jogos novos com texturas no alto.')
            $fonte = if ($gi.SlotPowered -or $gi.Integrated) { 'A sua placa atual funciona só com a energia do slot, então a fonte pode ser fraca ou não ter o cabo certo. A nova vai pedir cabo PCIe de 8 pinos e fonte de marca confiável: 550 W para as de entrada, 650 a 750 W para as mais fortes.' }
                     else { 'Confira se a fonte tem a potência e os cabos PCIe que a placa nova pede: 550 W para as de entrada, 650 a 750 W para as mais fortes.' }
            $rows += , @('Fonte e gabinete', (Tx '{0} O Harle não consegue ler a fonte: olhe a etiqueta dela e meça o espaço do gabinete.' (Tr $fonte)))
        }
        $title = switch ($level) { 'now' { 'Placa de vídeo: é o que mais segura o FPS' } 'later' { 'Placa de vídeo: vale trocar quando der' } default { 'Placa de vídeo: está boa' } }
        $why = if ($gpuLimits) { (Tx 'O {0} dá conta de placas bem mais fortes que a {1}. Nos jogos, é ela que chega a 100% de uso primeiro.' ($($s.Cpu.Short)) ($($gpu.Short))) }
               elseif ($level -eq 'now') { (Tx 'A {0} é uma placa de entrada antiga para os jogos atuais.' ($($gpu.Short))) }
               elseif ($level -eq 'later') { (Tx 'A {0} ainda roda os jogos atuais, mas com qualidade reduzida ou pouca memória de vídeo.' ($($gpu.Short))) }
               else { (Tx 'A {0} dá conta dos jogos atuais em qualidade alta. Não é prioridade.' ($($gpu.Short))) }
        if ($gi.Integrated) { $title = 'Placa de vídeo: o PC usa o vídeo integrado'; $why = 'Não há placa de vídeo dedicada. É o upgrade que mais muda o desempenho em jogos.' }
        [void]$items.Add(@{ Level = $level; Part = 'Placa de vídeo'; Title = $title; Why = $why; Rows = $rows })
    }

    # ----- Processador -----
    if ($s.Cpu -and $ci.Known -and -not $laptop) {
        $level = if ($cpuLimits -or $c -lt 70) { 'now' } elseif ($c -lt 95) { 'later' } else { 'ok' }
        $rows = @()
        $ddr4 = ($s.Ram -and $s.Ram.Type -eq 'DDR4')
        $novo = (Tx 'Ryzen 5 7600X com placa-mãe B650 e memória DDR5. Em {0} a DDR5 está cara, e isso pesa na conta.' (Tr $when))
        switch ($ci.Platform) {
            'AM4' {
                if ($level -ne 'ok') {
                    $rows += , @('Troca direta', 'Ryzen 5 5600 (o mais barato que resolve) ou Ryzen 7 5800X3D (o melhor de AM4 para jogos). Encaixam na sua placa-mãe: atualize a BIOS antes de trocar o processador.')
                    $rows += , @('Trocando tudo', $novo)
                } elseif (-not $ci.X3D) {
                    $rows += , @('Se um dia quiser mais', 'O Ryzen 7 5800X3D encaixa na mesma placa-mãe e rende uns 20% a mais em jogos limitados pelo processador. Só compensa com uma placa de vídeo forte e monitor de 144 Hz ou mais.')
                }
            }
            'AM5' {
                if ($level -ne 'ok' -or (-not $ci.X3D -and $cpuLimits)) { $rows += , @('Troca direta', 'Ryzen 7 9800X3D (o melhor para jogos hoje) ou Ryzen 5 7600X3D. Encaixam na sua placa-mãe com a BIOS atualizada.') }
                else { $rows += , @('Plataforma', 'A placa-mãe AM5 aceita os processadores Ryzen atuais, então a troca futura é só do processador.') }
            }
            'LGA1700' {
                if ($level -ne 'ok') { $rows += , @('Troca direta', 'Core i5-14600K ou Core i7-14700K, com a BIOS atualizada. São os últimos dessa plataforma.') }
                else { $rows += , @('Plataforma', 'A 14ª geração é o fim desse soquete: a próxima troca de processador pede placa-mãe nova.') }
            }
            'LGA1851' { $rows += , @('Plataforma', 'É a plataforma atual da Intel. Não há o que trocar agora.') }
            default {
                $rows += , @('Troca direta', 'Não há uma que valha: esse soquete parou de receber processadores. Trocar o processador pede placa-mãe nova junto.')
                if ($ddr4) { $rows += , @('Mais barato', 'Ryzen 5 5600 com placa-mãe B550, aproveitando a memória DDR4 que você já tem.') }
                $rows += , @('Mais duradouro', $novo)
            }
        }
        $title = switch ($level) { 'now' { 'Processador: está limitando o PC' } 'later' { 'Processador: vale trocar quando der' } default { 'Processador: está bom' } }
        $why = if ($cpuLimits) { (Tx 'A {0} é forte demais para o {1}: em 1080p o processador chega ao limite antes dela.' ($($gpu.Short)) ($($s.Cpu.Short))) }
               elseif ($level -eq 'now') { (Tx 'O {0} é antigo para os jogos atuais, que pedem pelo menos 6 núcleos rápidos. Ele causa travadas mesmo com uma boa placa de vídeo.' ($($s.Cpu.Short))) }
               elseif ($level -eq 'later') { (Tx 'O {0} ainda dá conta, mas segura o FPS mínimo em jogos pesados de processador.' ($($s.Cpu.Short))) }
               elseif ($gi.Known) { (Tx 'O {0} não é o que limita este PC e aguenta uma placa de vídeo mais forte que a atual.' $s.Cpu.Short) } else { (Tx 'O {0} não é o que limita este PC.' $s.Cpu.Short) }
        [void]$items.Add(@{ Level = $level; Part = 'Processador'; Title = $title; Why = $why; Rows = $rows })
    }

    # ----- Memoria -----
    if ($s.Ram -and $s.Ram.TotalGB -gt 0) {
        $r = $s.Ram
        $type = if ($r.Type) { $r.Type } else { 'do mesmo tipo da atual' }
        $kit = switch ($r.Type) { 'DDR5' { 'DDR5 de 6000 MHz CL30' } 'DDR4' { 'DDR4 de 3200 MHz CL16' } 'DDR3' { 'DDR3 de 1600 MHz' } default { 'da mesma velocidade da atual' } }
        $free = if ($r.Slots -gt 0) { [int]$r.Slots - [int]$r.Sticks } else { -1 }
        $slots = if ($free -eq 1) { 'Há 1 slot livre: dá para somar um pente igual ao atual.' } elseif ($free -gt 1) { (Tx 'Há {0} slots livres: dá para somar pentes iguais aos atuais.' ($free)) } elseif ($free -eq 0) { 'Não há slot livre: é preciso trocar os pentes atuais por um kit maior.' } else { 'Abra o gabinete para ver se há slot livre.' }
        if ($laptop) { $kit = (Tx '{0}, no formato de notebook (SO-DIMM)' (Tr $kit)); $slots = (Tx '{0} Em alguns notebooks a memória é soldada: confira o modelo antes de comprar.' (Tr $slots)) }
        $rows = @()
        if ($r.TotalGB -lt 16) {
            if ($r.Sticks -eq 1 -and $free -gt 0) { $rows += , @('O mais barato', (Tx 'Um segundo pente de {0} GB igual ao atual, no slot livre: chega a {1} GB e liga o dual channel.' ($($r.TotalGB)) ($([int]$r.TotalGB * 2)))) }
            $rows += , @('O que comprar', (Tx 'Kit de 2 x 8 GB {0} (16 GB). Se o orçamento der, 2 x 16 GB.' (Tr $kit)))
            $rows += , @('Slots', $slots)
            [void]$items.Add(@{ Level = 'now'; Part = 'Memória'; Title = (Tx 'Memória: {0} GB é pouco' ($($r.TotalGB)))
                Why = 'Jogos atuais pedem 16 GB. Com menos, o Windows usa o disco como memória e o jogo trava ao carregar cenário.'; Rows = $rows })
        } elseif ($r.Sticks -eq 1) {
            $rows += , @('O que comprar', (Tx 'Um segundo pente igual ao atual ({0}, mesma capacidade e velocidade), para ligar o dual channel.' (Tr $type)))
            $rows += , @('Slots', $slots)
            [void]$items.Add(@{ Level = 'now'; Part = 'Memória'; Title = 'Memória: um pente só'
                Why = 'Com um único pente a memória trabalha em single channel, e o processador perde bastante desempenho em jogos. É um dos upgrades mais baratos que existem.'; Rows = $rows })
        } elseif ($r.TotalGB -lt 32) {
            $rows += , @('Quando vale', (Tx '32 GB ({0}) só fazem diferença para quem joga com navegador e Discord abertos, usa mods pesados ou simuladores. Em {1} a memória está cara: não é prioridade.' (Tr $kit) (Tr $when)))
            $rows += , @('Slots', $slots)
            [void]$items.Add(@{ Level = 'ok'; Part = 'Memória'; Title = (Tx 'Memória: {0} GB dão conta' ($($r.TotalGB)))
                Why = 'É a quantidade que os jogos atuais pedem. Feche o navegador antes de títulos pesados e ela não limita.'; Rows = $rows })
        } else {
            [void]$items.Add(@{ Level = 'ok'; Part = 'Memória'; Title = (Tx 'Memória: {0} GB sobram' ($($r.TotalGB))); Why = 'Não há jogo que peça mais do que isso hoje.'; Rows = @() })
        }
    }

    # ----- Armazenamento -----
    if (@($s.Disks).Count -gt 0) {
        $hasSsd = @($s.Disks | Where-Object { $_.Kind -match 'SSD' }).Count -gt 0
        $hasHdd = @($s.Disks | Where-Object { $_.Kind -eq 'HDD' }).Count -gt 0
        $sysOnHdd = ([string]$s.SysDisk -eq 'HDD') -or (-not $hasSsd -and $hasHdd)
        $sys = @($s.Vols | Where-Object { $_.Letter -eq $env:SystemDrive }) | Select-Object -First 1
        $pct = if ($sys -and $sys.Size -gt 0) { [int](100 * $sys.Free / $sys.Size) } else { 100 }
        $buy = (Tx 'SSD NVMe M.2 de 1 TB se a placa-mãe tiver o slot M.2 (quase todas de 2018 para cá têm); senão, SSD SATA de 2,5 polegadas. Em {0} os SSDs estão mais caros que no ano passado.' (Tr $when))
        if ($sysOnHdd) {
            [void]$items.Add(@{ Level = 'now'; Part = 'Armazenamento'; Title = 'SSD: o Windows está em um HD'
                Why = 'É a troca que mais se sente no dia a dia: o PC liga em segundos, os jogos carregam várias vezes mais rápido e mundos abertos param de travar ao carregar cenário.'
                Rows = @( @('O que comprar', $buy), @('Depois', 'Instale o Windows e os jogos no SSD e deixe o HD para arquivos.') ) })
        } elseif ($pct -lt 15) {
            [void]$items.Add(@{ Level = 'later'; Part = 'Armazenamento'; Title = (Tx 'Armazenamento: o disco do sistema tem {0}% livre' ($pct))
                Why = 'SSD quase cheio fica mais lento, e as atualizações de jogos precisam de espaço para instalar.'
                Rows = @( @('Primeiro, de graça', 'Rode as limpezas da tela Otimizar e desinstale jogos parados.'), @('O que comprar', $buy) ) })
        } else {
            $rows = @()
            if ($hasHdd) { $rows += , @('Dica', 'Deixe os jogos no SSD. No HD o carregamento é bem mais lento.') }
            [void]$items.Add(@{ Level = 'ok'; Part = 'Armazenamento'; Title = 'Armazenamento: está bom'; Why = 'O Windows já está em SSD e há espaço livre.'; Rows = $rows })
        }
    }

    # ----- Monitor -----
    if ($s.Display -and $s.Display.Hz -gt 0 -and -not $laptop) {
        $d = $s.Display
        $fast = if ($d.MaxHz -gt $d.Hz) { $d.MaxHz } else { $d.Hz }
        if ($fast -le 75 -and (-not $gi.Known -or $g -ge 45)) {
            [void]$items.Add(@{ Level = 'later'; Part = 'Monitor'; Title = (Tx 'Monitor: {0} Hz escondem o FPS que o PC faz' ($fast))
                Why = (Tx 'A tela mostra no máximo {0} quadros por segundo. Tudo o que o PC gera acima disso não aparece, só reduz o atraso dos comandos.' ($fast))
                Rows = @( @('O que comprar', 'Monitor de 144 Hz ou mais, com FreeSync ou G-Sync. Em 1080p, 24 polegadas; em 1440p, 27 polegadas, se a placa de vídeo for da faixa intermediária para cima.'),
                          @('Ordem', 'Se a placa de vídeo não passa de 60 FPS nos seus jogos, troque a placa antes do monitor.') ) })
        } elseif ($fast -le 75) {
            [void]$items.Add(@{ Level = 'ok'; Part = 'Monitor'; Title = (Tx 'Monitor: {0} Hz, por enquanto tudo bem' ($fast))
                Why = (Tx 'A placa de vídeo atual não passa muito de {0} FPS nos jogos novos, então a tela não está escondendo nada. Um monitor de 144 Hz entra na lista depois da placa.' ($fast)); Rows = @() })
        } else {
            [void]$items.Add(@{ Level = 'ok'; Part = 'Monitor'; Title = (Tx 'Monitor: {0} Hz está bom' ($fast)); Why = 'A tela já mostra FPS alto.'; Rows = @() })
        }
    }

    # Dentro do mesmo nivel: primeiro o barato que destrava o resto (SSD, memoria), depois a peca que limita.
    $order = @{ free = 0; now = 1; later = 2; ok = 3; info = 4 }
    $weight = @{ 'Armazenamento' = 10; 'Memória' = 20; 'Placa de vídeo' = 30; 'Processador' = 40; 'Monitor' = 50; 'Sistema' = 60 }
    if ($limiter -eq 'cpu') { $weight['Processador'] = 25 }
    $idx = 0
    foreach ($it in $items) { $idx++; $w = $weight[[string]$it.Part]; if ($null -eq $w) { $w = 90 }; $it.Rank = [int]$order[$it.Level] * 10000 + $(if ($it.Level -eq 'free') { 0 } else { $w * 100 }) + $idx }
    $sorted = @($items | Sort-Object { $_.Rank })
    $first = @($sorted | Where-Object { $_.Level -eq 'now' }) | Select-Object -First 1
    $headline = if ($laptop) { 'Notebook: dá para melhorar memória e SSD; processador e placa de vídeo são fixos.' }
                elseif ($limiter -eq 'gpu') { 'Neste PC, o que mais segura o FPS é a placa de vídeo.' }
                elseif ($limiter -eq 'cpu') { 'Neste PC, o que mais segura o FPS é o processador.' }
                elseif ($first) { (Tx 'O primeiro upgrade deste PC: {0}.' (Tr $first.Part).ToLower()) }
                elseif (-not $both) { 'O Harle não reconheceu o modelo do processador ou da placa de vídeo, então compara só o resto.' }
                else { 'Este PC está equilibrado: nenhuma peça segura as outras.' }
    return @{ Headline = $headline; Limiter = $limiter; Items = $sorted; Gpu = $gi; Cpu = $ci }
}

# ---------------------------------------------------------------------------
#  Aba BIOS: o que vale mudar na BIOS deste PC e o que o Windows consegue confirmar.
#  O Harle nao mexe na BIOS. Ele so le o estado pelo Windows e mostra onde fica cada opcao.
#  Os caminhos de menu sao os usuais de cada fabricante e mudam um pouco de modelo para modelo.
# ---------------------------------------------------------------------------
$script:BiosPaths = @{
    asus = @{ Key = 'Del ou F2'
        Xmp = 'Aperte F7 para o modo avançado. Ai Tweaker, Ai Overclock Tuner: escolha XMP, D.O.C.P. ou EXPO.'
        Rebar = 'Advanced, PCI Subsystem Settings: ligue Above 4G Decoding e Re-Size BAR Support.'
        Csm = 'Boot, CSM (Compatibility Support Module): Launch CSM em Disabled.'
        Secure = 'Boot, Secure Boot: OS Type em Windows UEFI mode.'
        TpmAmd = 'Advanced, AMD fTPM configuration: Firmware TPM.'; TpmIntel = 'Advanced, PCH-FW Configuration: PTT em Enabled.'
        Pbo = 'Advanced, AMD Overclocking, Precision Boost Overdrive: Enabled.' }
    msi = @{ Key = 'Del'
        Xmp = 'Aperte F7 para o modo avançado. Menu OC: A-XMP, XMP ou EXPO, perfil 1. No modo simples há um botão XMP no topo da tela.'
        Rebar = 'Settings, Advanced, PCIe/PCI Sub-system Settings: ligue Above 4G memory e Re-Size BAR Support.'
        Csm = 'Settings, Advanced, Windows OS Configuration: BIOS Mode em UEFI.'
        Secure = 'Settings, Advanced, Windows OS Configuration, Secure Boot: Enabled.'
        TpmAmd = 'Settings, Security, Trusted Computing: Security Device Support em Enable, com AMD fTPM.'; TpmIntel = 'Settings, Security, Trusted Computing: Security Device Support em Enable, com PTT.'
        Pbo = 'OC, Advanced CPU Configuration, AMD Overclocking, Precision Boost Overdrive: Enabled.' }
    gigabyte = @{ Key = 'Del'
        Xmp = 'Menu Tweaker (M.I.T. nas placas antigas): Extreme Memory Profile (X.M.P.) ou EXPO, perfil 1.'
        Rebar = 'Settings, IO Ports: ligue Above 4G Decoding e Re-Size BAR Support.'
        Csm = 'Boot: CSM Support em Disabled.'
        Secure = 'Boot, Secure Boot: Enabled.'
        TpmAmd = 'Settings, Miscellaneous: AMD CPU fTPM em Enabled.'; TpmIntel = 'Settings, Miscellaneous: Intel Platform Trust Technology (PTT) em Enabled.'
        Pbo = 'Tweaker, Advanced CPU Settings, Precision Boost Overdrive: Enabled.' }
    asrock = @{ Key = 'F2 ou Del'
        Xmp = 'OC Tweaker, DRAM Configuration: Load XMP Setting, perfil 1.'
        Rebar = 'Advanced, PCI Configuration: ligue Above 4G Decoding e Re-Size BAR Support (em placas antigas aparece como C.A.M.).'
        Csm = 'Boot, CSM: Disabled.'
        Secure = 'Security, Secure Boot: Enabled.'
        TpmAmd = 'Advanced, CPU Configuration: AMD fTPM switch.'; TpmIntel = 'Security: Intel Platform Trust Technology.'
        Pbo = 'Advanced, AMD Overclocking, Precision Boost Overdrive: Enabled.' }
    other = @{ Key = 'Del ou F2 (em PCs de marca: F2 na Dell, F10 na HP, F1 ou F2 na Lenovo)'
        Xmp = 'Procure por XMP, DOCP ou EXPO no menu de overclock ou de memória.'
        Rebar = 'Procure por Above 4G Decoding e por Resizable BAR (ou Re-Size BAR) no menu avançado ou de PCI.'
        Csm = 'Procure por CSM no menu Boot e deixe em Disabled.'
        Secure = 'Procure por Secure Boot no menu Boot ou Security.'
        TpmAmd = 'Procure por fTPM no menu avançado ou de segurança.'; TpmIntel = 'Procure por PTT (Platform Trust Technology) no menu avançado ou de segurança.'
        Pbo = 'Procure por Precision Boost Overdrive, dentro de AMD Overclocking.' }
}

function Get-BoardVendor([string]$Maker) {
    if ($Maker -match '(?i)asus') { return 'asus' }
    if ($Maker -match '(?i)micro-star|msi') { return 'msi' }
    if ($Maker -match '(?i)gigabyte') { return 'gigabyte' }
    if ($Maker -match '(?i)asrock') { return 'asrock' }
    return 'other'
}

# PCs montados por estas marcas costumam vir com a BIOS travada, sem XMP nem overclock.
function Test-OemBoard([string]$Maker) { return [bool]($Maker -match '(?i)dell|hewlett|^hp$|hp inc|lenovo|acer|positivo|samsung|alienware|vaio|multilaser|daten') }

# 'pending' = quase certo que esta desligado; 'check' = nao da para saber pelo Windows; 'ok' = ligado.
function Get-XmpState($Ram) {
    if (-not $Ram -or [int]$Ram.Speed -le 0) { return '' }
    $sp = [int]$Ram.Speed
    switch ([string]$Ram.Type) {
        'DDR4' { if ($sp -le 2666) { return 'pending' } elseif ($sp -lt 3000) { return 'check' } else { return 'ok' } }
        'DDR5' { if ($sp -le 4800) { return 'pending' } elseif ($sp -lt 5600) { return 'check' } else { return 'ok' } }
    }
    return ''
}

# Devolve @{ Headline; Pending; Key; Vendor; Items }. Level: do (pendente, confirmado), check (importante, sem como confirmar),
# opt (opcional), ok (ja esta), info.
function Get-BiosPlan($s) {
    if (-not $s) { return @{ Headline = 'Sem leitura do hardware. Clique em Escanear de novo.'; Pending = 0; Key = 'Del ou F2'; Vendor = 'other'; Items = @() } }
    $items = New-Object System.Collections.ArrayList
    $maker = if ($s.Board) { [string]$s.Board.Maker } else { '' }
    $vendor = Get-BoardVendor $maker
    $p = $script:BiosPaths[$vendor]
    $oem = Test-OemBoard $maker
    $laptop = [bool]$s.IsLaptop
    $cpuName = if ($s.Cpu) { [string]$s.Cpu.Name } else { '' }
    $amd = $cpuName -match '(?i)AMD|Ryzen'
    $ci = Get-CpuInfo $s.Cpu $laptop
    $fw = if ($s.Fw) { $s.Fw } else { @{ Mode = ''; SecureBoot = $null; Tpm = ''; Rebar = '' } }
    $legacy = ([string]$fw.Mode -eq 'Legacy')
    $locked = 'Em notebooks e em PCs de marca (Dell, HP, Lenovo, Acer) esta opção costuma não existir. Se não achar, não há o que fazer.'
    $undo = 'Salve com F10. Se o PC não ligar, espere: depois de algumas tentativas a BIOS volta sozinha ao padrão.'

    # ----- 1) XMP: o maior ganho gratuito -----
    $xmp = Get-XmpState $s.Ram
    if ($xmp) {
        $sp = [int]$s.Ram.Speed
        $rows = @()
        $rows += , @('Onde fica', $p.Xmp)
        $rows += , @('Depois', (Tx '{0} Se travar em jogo, tente o perfil 2 ou uma velocidade um degrau abaixo.' (Tr $undo)))
        if ($oem -or $laptop) { $rows += , @('Atenção', $locked) }
        if ($xmp -eq 'pending') {
            [void]$items.Add(@{ Level = 'do'; Part = 'Memória'; Title = (Tx 'Ligar o XMP: a memória está a {0} MHz' ($sp))
                Why = 'Nessa velocidade o perfil de memória (XMP, DOCP ou EXPO) quase com certeza está desligado, e a memória roda abaixo do que o kit entrega. Ligar rende de 10 a 20% em jogos limitados pelo processador, principalmente em Ryzen. É o maior ganho gratuito que existe. Se o seu kit for mesmo dessa velocidade, nada muda.'
                Rows = $rows })
        } elseif ($xmp -eq 'check') {
            [void]$items.Add(@{ Level = 'check'; Part = 'Memória'; Title = (Tx 'Conferir o XMP: a memória está a {0} MHz' ($sp))
                Why = 'Essa velocidade tanto pode ser a do kit quanto um perfil desligado. Veja na etiqueta dos pentes qual é a velocidade de fábrica; se for maior, ligue o perfil.'
                Rows = $rows })
        } else {
            [void]$items.Add(@{ Level = 'ok'; Part = 'Memória'; Title = (Tx 'XMP: ligado, memória a {0} MHz' ($sp)); Why = 'A memória já roda na velocidade de um perfil XMP, DOCP ou EXPO.'; Rows = @() })
        }
    }

    # ----- 2) Windows em modo Legacy trava Resizable BAR e Secure Boot -----
    if ($legacy) {
        [void]$items.Add(@{ Level = 'check'; Part = 'Modo de inicialização'; Title = 'O Windows está instalado em modo Legacy (CSM)'
            Why = 'Nesse modo o Resizable BAR e o Secure Boot não funcionam. Para usá-los, o disco precisa ser convertido para GPT e o CSM desligado na BIOS.'
            Rows = @( @('Como converter', 'Faça backup. No Prompt de Comando como administrador: mbr2gpt /validate /allowFullOS e, se passar, mbr2gpt /convert /allowFullOS. Só depois desligue o CSM.'),
                      @('Onde fica', $p.Csm),
                      @('Cuidado', 'Desligar o CSM sem converter o disco faz o Windows não iniciar. Não se perde nada: basta voltar à BIOS e religar o CSM.') ) })
    }

    # ----- 3) Resizable BAR -----
    $gpu = @($s.Gpus | Where-Object { [string]$_.Name -match '(?i)RTX\s*(30|40|50)\d\d|RX\s*[679]\d{3}|\bArc\b' }) | Select-Object -First 1
    if ($gpu -and -not $laptop) {
        $arc = [string]$gpu.Name -match '(?i)\bArc\b'
        $how = if ([string]$gpu.Name -match '(?i)NVIDIA|RTX') { 'Painel de Controle da NVIDIA, Informações do sistema (canto de baixo, à esquerda): a linha "Barra redimensionável" deve dizer Sim.' }
               elseif ($arc) { 'No app da Intel para a placa (Arc Control ou Intel Graphics Software), a tela de informações do sistema mostra se o Resizable BAR está ativo.' }
               else { 'No AMD Software: Adrenalin, a opção aparece como Smart Access Memory, na parte de desempenho. Se estiver disponível e ligada, está funcionando.' }
        $rows = @()
        $rows += , @('Onde fica', $p.Rebar)
        $rows += , @('Como conferir', $how)
        $rows += , @('Precisa de', 'Windows em modo UEFI, com o CSM desligado, e Above 4G Decoding ligado. Em placas-mãe antigas a opção só aparece depois de atualizar a BIOS.')
        if ([string]$fw.Rebar -eq 'on') {
            [void]$items.Add(@{ Level = 'ok'; Part = 'Placa de vídeo'; Title = 'Resizable BAR: ligado'; Why = (Tx 'O Windows mostra a {0} com a memória de vídeo inteira mapeada, que é o sinal de que o Resizable BAR está funcionando.' ($($gpu.Short))); Rows = @() })
        } else {
            $title = if ($arc) { 'Conferir o Resizable BAR: nas placas Intel Arc ele é essencial' } else { 'Conferir o Resizable BAR' }
            $why = if ($arc) { 'Sem o Resizable BAR as placas Intel Arc perdem uma parte grande do desempenho e travam mais. O Harle não conseguiu confirmar pelo Windows se ele está ligado.' }
                   else { (Tx 'Deixa o processador acessar a memória de vídeo inteira de uma vez. Rende alguns por cento em vários jogos, mais na AMD e em jogos novos, e não custa nada. O Harle não conseguiu confirmar pelo Windows se ele está ligado na {0}.' ($($gpu.Short))) }
            [void]$items.Add(@{ Level = 'check'; Part = 'Placa de vídeo'; Title = $title; Why = $why; Rows = $rows })
        }
    }

    # ----- 4) Versao da BIOS -----
    if ($s.Board -and $s.Board.BiosDate -and -not $laptop) {
        $age = [int]((Get-Date) - $s.Board.BiosDate).TotalDays
        $years = [Math]::Round($age / 365.0, 1)
        $raptor = (-not $amd) -and ($cpuName -match 'i[579]-1[34]\d{3}')
        $rows = @()
        $rows += , @('Como', (Tx 'No site do fabricante da placa-mãe, procure o modelo {0}, baixe a BIOS mais nova para um pendrive em FAT32 e use a ferramenta de atualização da própria BIOS (EZ Flash, M-Flash, Q-Flash ou Instant Flash).' ($($s.Board.Model))))
        $rows += , @('Cuidado', 'Não desligue o PC durante a atualização. Depois dela a BIOS volta ao padrão: ligue de novo o XMP e as outras opções.')
        if ($raptor) {
            [void]$items.Add(@{ Level = 'check'; Part = 'BIOS'; Title = 'Atualizar a BIOS: importante nos Core de 13ª e 14ª geração'
                Why = (Tx 'Esses processadores tiveram um defeito de tensão que causa instabilidade e desgaste, corrigido por microcódigo em 2024. A BIOS deste PC é de {0}. Confira se a versão instalada já traz a correção e use o perfil Intel Default Settings.' ($($s.Board.BiosDate.ToString('dd/MM/yyyy'))))
                Rows = $rows })
        } elseif ($age -gt 730) {
            [void]$items.Add(@{ Level = 'check'; Part = 'BIOS'; Title = (Tx 'Atualizar a BIOS: a deste PC tem {0} anos' ($years))
                Why = (Tx 'A versão instalada é de {0}. Versões novas melhoram a compatibilidade de memória (o XMP fica mais estável), corrigem falhas e, em placas antigas, liberam o Resizable BAR e processadores mais novos.' ($($s.Board.BiosDate.ToString('dd/MM/yyyy'))))
                Rows = $rows })
        } else {
            [void]$items.Add(@{ Level = 'ok'; Part = 'BIOS'; Title = 'Versão da BIOS: recente'; Why = (Tx 'A versão instalada é de {0}.' ($($s.Board.BiosDate.ToString('dd/MM/yyyy')))); Rows = @() })
        }
    }

    # ----- 5) PBO, so em Ryzen de mesa -----
    if ($ci.Known -and -not $laptop -and ($ci.Platform -eq 'AM4' -or $ci.Platform -eq 'AM5') -and $cpuName -notmatch 'Ryzen\s+\d\s+(?:PRO\s+)?[12]\d{3}') {
        [void]$items.Add(@{ Level = 'opt'; Part = 'Processador'; Title = 'Precision Boost Overdrive (PBO)'
            Why = 'Deixa o Ryzen usar mais energia quando a refrigeração permite. Em jogos o ganho é pequeno, de 1 a 5%; em tarefas pesadas é maior, principalmente nos modelos de 65 W. O processador esquenta mais, então só vale com um bom cooler.'
            Rows = @( @('Onde fica', $p.Pbo),
                      @('Um passo além', 'Com o PBO ligado, o Curve Optimizer em valor negativo (comece em -10 em todos os núcleos) baixa a temperatura e sobe um pouco o desempenho. Teste a estabilidade por alguns dias; se o PC reiniciar sozinho, use um valor menor.') ) })
    }

    # ----- 6) Secure Boot e TPM: nao rendem FPS, mas ha jogo que nao abre sem eles -----
    if ($fw.Mode -or $null -ne $fw.SecureBoot -or $fw.Tpm) {
        $sbOn = ($fw.SecureBoot -eq $true)
        $tpmOk = ([string]$fw.Tpm -eq '2.0')
        $tpmPath = if ($amd) { $p.TpmAmd } else { $p.TpmIntel }
        if ($sbOn -and $tpmOk) {
            [void]$items.Add(@{ Level = 'ok'; Part = 'Exigido por jogos'; Title = 'Secure Boot e TPM 2.0: ligados'
                Why = 'Não mudam o FPS, mas o anti-cheat de Valorant (no Windows 11), Battlefield 6 e dos Call of Duty novos só deixa o jogo abrir com os dois ligados. Este PC está pronto.'; Rows = @() })
        } else {
            $falta = @()
            if (-not $sbOn) { $falta += 'Secure Boot' }
            if (-not $tpmOk) { $falta += $(if ([string]$fw.Tpm -eq 'none' -or -not $fw.Tpm) { 'TPM 2.0' } else { (Tx 'TPM 2.0 (o deste PC é {0})' ($($fw.Tpm))) }) }
            $rows = @()
            if (-not $sbOn)  { $rows += , @('Secure Boot', ($p.Secure + $(if ($legacy) { ' Só funciona depois de sair do modo Legacy (item acima).' } else { ' Se aparecer a opção de chaves, escolha instalar as chaves de fábrica.' }))) }
            if (-not $tpmOk) { $rows += , @('TPM', $tpmPath) }
            $rows += , @('Como conferir', 'No Windows, aperte Win + R e rode msinfo32: a linha "Estado da Inicialização Segura" deve dizer Ativado. Para o TPM, rode tpm.msc.')
            [void]$items.Add(@{ Level = 'check'; Part = 'Exigido por jogos'; Title = (Tx 'Desligado neste PC: {0}' ($falta -join (Tr ' e ')))
                Why = 'Não mudam o FPS, mas o anti-cheat de Valorant (no Windows 11), Battlefield 6 e dos Call of Duty novos só deixa o jogo abrir com Secure Boot e TPM 2.0 ligados. Se você joga algum deles, ou pretende, ligue.'
                Rows = $rows })
        }
    }

    $order = @{ do = 0; check = 1; opt = 2; ok = 3; info = 4 }
    $idx = 0
    foreach ($it in $items) { $idx++; $it.Rank = [int]$order[$it.Level] * 100 + $idx }
    $sorted = @($items | Sort-Object { $_.Rank })
    $pending = @($sorted | Where-Object { $_.Level -eq 'do' }).Count
    $check = @($sorted | Where-Object { $_.Level -eq 'check' }).Count
    $headline = if ($pending -eq 1) { '1 ajuste de BIOS pendente neste PC' } elseif ($pending -gt 1) { (Tx '{0} ajustes de BIOS pendentes neste PC' $pending) }
                elseif ($check -gt 0) { 'Nada pendente que o Windows consiga ver. Confira os itens marcados como importantes.' }
                elseif ($sorted.Count -eq 0) { 'O Windows não entregou informação suficiente sobre a BIOS deste PC.' }
                else { 'A BIOS deste PC está em ordem.' }
    return @{ Headline = $headline; Pending = $pending; Key = $p.Key; Vendor = $vendor; Legacy = $legacy; Items = $sorted }
}

# ---------------------------------------------------------------------------
#  Saude do PC: erros de hardware, desligamentos, telas azuis, driver de video, discos e bateria
#  (o que o proprio Windows registrou nos ultimos 30 dias). A coleta roda em segundo plano.
# ---------------------------------------------------------------------------
$script:HealthCode = @'
$ProgressPreference = 'SilentlyContinue'
$days = 30
$since = (Get-Date).AddDays(-$days)
$h = @{ Days = $days; EventsOk = $true; Whea = @(); Kp41 = @(); Bsod = @(); Tdr = @(); MemTest = $null; Disks = @(); Battery = $null; BootTime = $null }
function Read-Events($Filter) {
    try { return @(Get-WinEvent -FilterHashtable $Filter -ErrorAction Stop) }
    catch {
        # "Nenhum evento encontrado" tambem chega como erro; so o resto indica que o log nao pode ser lido.
        if ([string]$_.FullyQualifiedErrorId -notmatch 'NoMatchingEventsFound') { $script:readFailed = $true }
        return @()
    }
}
$script:readFailed = $false
$h.Whea = @(Read-Events @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; StartTime = $since } | ForEach-Object { @{ Id = [int]$_.Id; When = $_.TimeCreated } })
$h.Kp41 = @(Read-Events @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41; StartTime = $since } | ForEach-Object { @{ When = $_.TimeCreated } })
$h.Bsod = @(Read-Events @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; Id = 1001; StartTime = $since } | ForEach-Object {
    $code = ''
    if ([string]$_.Message -match '0x[0-9a-fA-F]{8}') { $code = $Matches[0].ToLower() }
    elseif ($_.Properties.Count -gt 0 -and [string]$_.Properties[0].Value -match '0x[0-9a-fA-F]+') { $code = [string]$_.Properties[0].Value }
    @{ When = $_.TimeCreated; Code = $code } })
$h.Tdr = @(Read-Events @{ LogName = 'System'; ProviderName = 'Display'; Id = 4101; StartTime = $since } | ForEach-Object { @{ When = $_.TimeCreated } })
$mem = @(Read-Events @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-MemoryDiagnostics-Results' } | Sort-Object TimeCreated -Descending | Select-Object -First 1)
if ($mem.Count -gt 0) { $h.MemTest = @{ Id = [int]$mem[0].Id; When = $mem[0].TimeCreated } }
$h.EventsOk = -not $script:readFailed
try {
    foreach ($d in @(Get-PhysicalDisk -ErrorAction Stop)) {
        $r = $null
        try { $r = $d | Get-StorageReliabilityCounter -ErrorAction Stop } catch { }
        $kind = [string]$d.MediaType
        if ([string]$d.BusType -eq 'NVMe') { $kind = 'SSD NVMe' } elseif ($kind -eq 'Unspecified' -or -not $kind) { $kind = 'Disco' }
        $h.Disks += @{ Name = [string]$d.FriendlyName; Kind = $kind; Health = [string]$d.HealthStatus; Bytes = [double]$d.Size
            Temp = $(if ($r -and $r.Temperature) { [int]$r.Temperature } else { -1 })
            Wear = $(if ($r -and $null -ne $r.Wear) { [int]$r.Wear } else { -1 })
            ReadErr = $(if ($r -and $null -ne $r.ReadErrorsUncorrected) { [int64]$r.ReadErrorsUncorrected } else { -1 })
            Hours = $(if ($r -and $null -ne $r.PowerOnHours) { [int64]$r.PowerOnHours } else { -1 }) }
    }
} catch { }
try {
    $st = @(Get-CimInstance -Namespace 'root\wmi' -ClassName BatteryStaticData -ErrorAction Stop) | Select-Object -First 1
    $fc = @(Get-CimInstance -Namespace 'root\wmi' -ClassName BatteryFullChargedCapacity -ErrorAction Stop) | Select-Object -First 1
    $cy = $null
    try { $cy = @(Get-CimInstance -Namespace 'root\wmi' -ClassName BatteryCycleCount -ErrorAction Stop) | Select-Object -First 1 } catch { }
    if ($st -and $fc -and [double]$st.DesignedCapacity -gt 0) {
        $h.Battery = @{ Design = [double]$st.DesignedCapacity; Full = [double]$fc.FullChargedCapacity; Cycles = $(if ($cy) { [int]$cy.CycleCount } else { -1 }) }
    }
} catch { }
try { $h.BootTime = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime } catch { }
$h
'@

# Codigos de tela azul que mais aparecem em PCs de jogo, com a causa mais comum de cada um.
$script:BsodHints = @{
    '0x00000124' = 'WHEA_UNCORRECTABLE_ERROR: erro de hardware. Quase sempre overclock, PBO, Curve Optimizer ou XMP instável, ou superaquecimento.'
    '0x0000001a' = 'MEMORY_MANAGEMENT: costuma ser memória instável (XMP) ou com defeito. Rode o teste de memória.'
    '0x00000050' = 'PAGE_FAULT_IN_NONPAGED_AREA: memória instável ou driver com defeito.'
    '0x0000003b' = 'SYSTEM_SERVICE_EXCEPTION: geralmente um driver. Atualize o driver de vídeo e o de chipset.'
    '0x0000007e' = 'SYSTEM_THREAD_EXCEPTION_NOT_HANDLED: geralmente um driver.'
    '0x000000d1' = 'DRIVER_IRQL_NOT_LESS_OR_EQUAL: um driver, muitas vezes de rede ou de vídeo.'
    '0x0000000a' = 'IRQL_NOT_LESS_OR_EQUAL: driver ou memória instável.'
    '0x00000116' = 'VIDEO_TDR_FAILURE: a placa de vídeo parou de responder. Overclock da placa ou driver.'
    '0x00000117' = 'VIDEO_TDR_TIMEOUT_DETECTED: a placa de vídeo parou de responder. Overclock da placa ou driver.'
    '0x00000133' = 'DPC_WATCHDOG_VIOLATION: driver travado, às vezes o firmware do SSD. Atualize chipset e SSD.'
    '0x000000ef' = 'CRITICAL_PROCESS_DIED: um processo do Windows morreu. Verifique os arquivos do Windows e o disco.'
    '0x00000139' = 'KERNEL_SECURITY_CHECK_FAILURE: driver ou memória instável.'
    '0x00000101' = 'CLOCK_WATCHDOG_TIMEOUT: processador instável, quase sempre overclock ou Curve Optimizer agressivo.'
}

function Get-Plural([int]$N, [string]$One, [string]$Many) { if ($N -eq 1) { return '1 ' + (Tr $One) } return "$N " + (Tr $Many) }

# Devolve @{ Headline; Items }. Level: bad (problema), warn (atencao), ok, info.
function Get-HealthPlan($h, $Specs) {
    if (-not $h) { return @{ Headline = 'Ainda sem leitura. Clique em Verificar de novo.'; Items = @(); Bad = 0; Warn = 0 } }
    $items = New-Object System.Collections.ArrayList
    $days = [int]$h.Days
    $fmt = { param($d) if ($d) { ([datetime]$d).ToString('dd/MM HH:mm') } else { '' } }
    $last = { param($list) $w = @($list | Sort-Object { $_.When } -Descending | Select-Object -First 1); if ($w.Count -gt 0) { & $fmt $w[0].When } else { '' } }

    # ----- Erros de hardware (WHEA) -----
    if ($h.EventsOk) {
        $whea = @($h.Whea)
        $fatal = @($whea | Where-Object { $_.Id -eq 18 -or $_.Id -eq 1 })
        $cpu = @($whea | Where-Object { $_.Id -eq 19 })
        $memE = @($whea | Where-Object { $_.Id -eq 47 })
        $pcie = @($whea | Where-Object { $_.Id -eq 17 })
        if ($whea.Count -eq 0) {
            [void]$items.Add(@{ Level = 'ok'; Part = 'Erros de hardware'; Title = (Tx 'Nenhum erro de hardware nos últimos {0} dias' ($days)); Why = 'O processador, a memória e o PCI Express não registraram nenhuma falha. Se você mexeu em XMP, PBO ou overclock, é um bom sinal de estabilidade.'; Rows = @() })
        } else {
            $rows = @()
            if ($fatal.Count) { $rows += , @('Fatais', (Tx '{0}, o último em {1}. Cada um travou ou reiniciou o PC.' $fatal.Count (& $last $fatal))) }
            if ($cpu.Count)   { $rows += , @('Processador', (Tx '{0}. É o sinal clássico de PBO, Curve Optimizer ou overclock no limite.' (Get-Plural $cpu.Count 'corrigido' 'corrigidos'))) }
            if ($memE.Count)  { $rows += , @('Memória', (Tx '{0}. Costuma ser XMP instável: tente uma velocidade um degrau abaixo ou mais tensão na memória.' (Get-Plural $memE.Count 'corrigido' 'corrigidos'))) }
            if ($pcie.Count)  { $rows += , @('PCI Express', (Tx '{0}. Costumam vir de cabo riser, placa mal encaixada ou da economia de energia do PCIe; em geral não travam nada.' (Get-Plural $pcie.Count 'corrigido' 'corrigidos'))) }
            $rows += , @('O que fazer', 'Desfaça o último ajuste de BIOS ou de overclock e veja se os erros param. Se nada foi mexido, confira as temperaturas na tela Monitor.')
            $level = if ($fatal.Count -gt 0) { 'bad' } elseif (($cpu.Count + $memE.Count) -gt 0) { 'warn' } else { 'info' }
            $title = if ($fatal.Count -gt 0) { (Tx '{0} de hardware nos últimos {1} dias' (Get-Plural $fatal.Count 'erro fatal' 'erros fatais') $days) } else { (Tx '{0} nos últimos {1} dias' (Get-Plural $whea.Count 'erro de hardware corrigido' 'erros de hardware corrigidos') $days) }
            [void]$items.Add(@{ Level = $level; Part = 'Erros de hardware'; Title = $title
                Why = 'O Windows registra quando o processador, a memória ou o PCI Express detectam um erro. Os corrigidos não derrubam o PC, mas mostram que algo está no limite.'; Rows = $rows })
        }

        # ----- Telas azuis e desligamentos -----
        $bsod = @($h.Bsod)
        $kp = @($h.Kp41)
        if ($bsod.Count -gt 0) {
            $rows = @()
            foreach ($g in @($bsod | Group-Object { $_.Code } | Sort-Object Count -Descending)) {
                $code = [string]$g.Name
                $hint = $script:BsodHints[$code]
                if (-not $hint) { $hint = 'Procure o código na internet junto com o nome da sua placa-mãe ou de vídeo.' }
                $label = if ($code) { $code } else { 'Sem código' }
                $rows += , @($label, (Tx '{0}. {1}' (Get-Plural $g.Count 'vez' 'vezes') (Tr $hint)))
            }
            [void]$items.Add(@{ Level = 'bad'; Part = 'Telas azuis'; Title = (Tx '{0} nos últimos {1} dias' (Get-Plural $bsod.Count 'tela azul' 'telas azuis') $days)
                Why = (Tx 'A última foi em {0}. O código de cada uma aponta a causa mais provável.' ($(& $last $bsod))); Rows = $rows })
        } elseif ($kp.Count -gt 0) {
            [void]$items.Add(@{ Level = 'warn'; Part = 'Desligamentos'; Title = (Tx 'O PC desligou sem avisar {0} nos últimos {1} dias' ($(Get-Plural $kp.Count 'vez' 'vezes')) ($days))
                Why = (Tx 'O último foi em {0}. Pode ter sido queda de energia ou o botão segurado. Se aconteceu no meio do jogo, as causas comuns são fonte fraca ou velha, superaquecimento e overclock ou XMP instável.' ($(& $last $kp)))
                Rows = @( , @('O que fazer', 'Se foi em jogo: confira as temperaturas na tela Monitor, desfaça overclocks e, se continuar, desconfie da fonte.')) })
        } else {
            [void]$items.Add(@{ Level = 'ok'; Part = 'Travamentos'; Title = (Tx 'Nenhuma tela azul ou desligamento inesperado em {0} dias' ($days)); Why = 'O Windows não registrou nenhum travamento total.'; Rows = @() })
        }

        # ----- Driver de video -----
        $tdr = @($h.Tdr)
        if ($tdr.Count -gt 0) {
            [void]$items.Add(@{ Level = 'warn'; Part = 'Placa de vídeo'; Title = (Tx 'O driver de vídeo parou de responder {0}' ($(Get-Plural $tdr.Count 'vez' 'vezes')))
                Why = (Tx 'O último foi em {0}. A tela fica preta por alguns segundos e o jogo fecha. As causas comuns são overclock da placa, driver com defeito e placa superaquecendo.' ($(& $last $tdr)))
                Rows = @( @('Overclock', 'Se usou a aba AVANÇADO, clique em Voltar ao padrão.'), @('Driver', 'Reinstale o driver de vídeo pela opção de instalação limpa do instalador da NVIDIA ou da AMD.') ) })
        } else {
            [void]$items.Add(@{ Level = 'ok'; Part = 'Placa de vídeo'; Title = 'O driver de vídeo não travou'; Why = (Tx 'Nenhuma vez em {0} dias.' ($days)); Rows = @() })
        }

        # ----- Teste de memoria -----
        if ($h.MemTest) {
            $when = & $fmt $h.MemTest.When
            if ([int]$h.MemTest.Id -eq 1102) {
                [void]$items.Add(@{ Level = 'bad'; Part = 'Memória'; Title = 'O último teste de memória encontrou erros'
                    Why = (Tx 'Teste de {0}. Com XMP ligado, tente desligar e testar de novo; se os erros continuarem, um dos pentes provavelmente tem defeito.' ($when))
                    Rows = @( , @('Como achar o pente', 'Teste com um pente de cada vez.')) })
            } else {
                [void]$items.Add(@{ Level = 'ok'; Part = 'Memória'; Title = 'O último teste de memória passou'; Why = (Tx 'Teste de {0}, sem erros.' ($when)); Rows = @() })
            }
        }
    } else {
        [void]$items.Add(@{ Level = 'info'; Part = 'Registros do Windows'; Title = 'Não deu para ler os registros do Windows'; Why = 'Sem eles o Harle não consegue contar erros, telas azuis e desligamentos. Feche e abra o Harle de novo.'; Rows = @() })
    }

    # ----- Discos -----
    foreach ($d in @($h.Disks)) {
        $size = if ($d.Bytes -gt 0) { (Tx ' de {0}' ($(Format-Capacity $d.Bytes))) } else { '' }
        $name = (Tr $d.Kind) + $size + " ($($d.Name))"
        $rows = @()
        $bits = @()
        if ($d.Wear -ge 0) { $bits += (Tx '{0}% da vida útil usada' $d.Wear) }
        if ($d.Temp -gt 0) { $bits += (Tx '{0} °C agora' $d.Temp) }
        if ($d.Hours -ge 0) { $bits += ((Tx '{0:N0} horas ligado') -f $d.Hours) }
        if ($bits.Count) { $rows += , @('Leitura', ($bits -join ', ') + '.') }
        $level = 'ok'; $title = (Tx '{0}: saudável' $name); $why = 'O próprio disco diz que está bem.'
        if ($d.Health -eq 'Unhealthy' -or $d.ReadErr -gt 0) {
            $level = 'bad'; $title = (Tx '{0}: com defeito' $name)
            $why = 'O disco relata falha ou erros de leitura que não conseguiu corrigir. Faça backup do que importa agora e planeje a troca.'
        } elseif ($d.Health -eq 'Warning' -or $d.Wear -ge 80) {
            $level = 'warn'; $title = (Tx '{0}: perto do fim da vida útil' $name)
            $why = 'O disco ainda funciona, mas já gastou boa parte das gravações que aguenta. Mantenha backup do que importa.'
        } elseif ($d.Temp -ge 70) {
            $level = 'warn'; $title = (Tx '{0}: quente ({1} °C)' $name $d.Temp)
            $why = 'SSDs acima de 70 °C reduzem a velocidade para se proteger. Um dissipador no M.2 ou mais ventilação no gabinete resolve.'
        }
        [void]$items.Add(@{ Level = $level; Part = 'Disco'; Title = $title; Why = $why; Rows = $rows })
    }

    # ----- Bateria -----
    if ($h.Battery -and $h.Battery.Design -gt 0 -and $h.Battery.Full -gt 0) {
        $pct = [int][Math]::Min(100, [Math]::Round(100.0 * $h.Battery.Full / $h.Battery.Design))
        $cyc = if ($h.Battery.Cycles -gt 0) { (Tx ' depois de {0} ciclos de carga' ($($h.Battery.Cycles))) } else { '' }
        $level = if ($pct -lt 60) { 'warn' } else { 'ok' }
        $why = if ($pct -lt 60) { 'A bateria já perdeu boa parte da capacidade. Se a autonomia incomoda, a troca resolve; não afeta o desempenho na tomada.' } else { 'A bateria está em bom estado.' }
        [void]$items.Add(@{ Level = $level; Part = 'Bateria'; Title = (Tx 'Bateria: guarda {0}% da carga original{1}' ($pct) ($cyc)); Why = $why; Rows = @() })
    }

    # ----- Tempo ligado -----
    if ($h.BootTime) {
        $up = ((Get-Date) - [datetime]$h.BootTime).TotalDays
        if ($up -ge 7) {
            [void]$items.Add(@{ Level = 'info'; Part = 'Sistema'; Title = ((Tx 'Ligado há {0:N0} dias sem reiniciar') -f [Math]::Floor($up)); Why = 'Desligar pelo menu Iniciar não zera isso quando a Inicialização Rápida está ligada. Reiniciar de vez em quando libera memória e aplica atualizações de driver.'; Rows = @() })
        }
    }

    $order = @{ bad = 0; warn = 1; info = 2; ok = 3 }
    $idx = 0
    foreach ($it in $items) { $idx++; $it.Rank = [int]$order[$it.Level] * 100 + $idx }
    $sorted = @($items | Sort-Object { $_.Rank })
    $bad = @($sorted | Where-Object { $_.Level -eq 'bad' }).Count
    $warn = @($sorted | Where-Object { $_.Level -eq 'warn' }).Count
    $headline = if ($bad -gt 0) { 'Há problemas que merecem atenção agora' } elseif ($warn -gt 0) { 'O PC está funcionando, com pontos de atenção' } else { 'Tudo em ordem com a saúde deste PC' }
    return @{ Headline = $headline; Items = $sorted; Bad = $bad; Warn = $warn }
}

# Verificacao da imagem do Windows (DISM). Devolve "estado" ou "erro|mensagem".
$script:ImageScanCode = @'
param([bool]$Repair)
$ProgressPreference = 'SilentlyContinue'
try {
    if ($Repair) {
        $r = Repair-WindowsImage -Online -RestoreHealth -NoRestart -ErrorAction Stop
        $s = Start-Process -FilePath (Join-Path $env:WINDIR 'System32\sfc.exe') -ArgumentList '/scannow' -WindowStyle Hidden -Wait -PassThru
        "repaired|$([string]$r.ImageHealthState)|$($s.ExitCode)"
    } else {
        $r = Repair-WindowsImage -Online -ScanHealth -NoRestart -ErrorAction Stop
        "scan|$([string]$r.ImageHealthState)"
    }
} catch { "erro|$($_.Exception.Message)" }
'@

# ---------------------------------------------------------------------------
#  Aba Discos: o S.M.A.R.T. de cada disco, no estilo do CrystalDiskInfo.
#  NVMe pela pagina de saude do proprio SSD, SATA pelos atributos SMART (Harle.Disk, so no Harle.exe).
#  Sem o Harle.exe, ou quando o controlador nao deixa ler, fica o que o Windows informa.
# ---------------------------------------------------------------------------
$script:DiskCode = @'
$ProgressPreference = 'SilentlyContinue'
$smart = 'Harle.Disk' -as [type]
$out = @()
foreach ($d in @(Get-PhysicalDisk -ErrorAction SilentlyContinue | Sort-Object { [int]$_.DeviceId })) {
    $n = [int]$d.DeviceId
    $r = $null
    try { $r = $d | Get-StorageReliabilityCounter -ErrorAction Stop } catch { }
    $letters = @()
    try { $letters = @(Get-Partition -DiskNumber $n -ErrorAction Stop | Where-Object { $_.DriveLetter } | ForEach-Object { "$($_.DriveLetter):" }) } catch { }
    $x = @{ Number = $n; Name = ([string]$d.FriendlyName).Trim(); Serial = ([string]$d.SerialNumber).Trim(); Firmware = ([string]$d.FirmwareVersion).Trim()
            Bus = [string]$d.BusType; Media = [string]$d.MediaType; Bytes = [double]$d.Size; Rpm = $(if ($null -ne $d.SpindleSpeed) { [int64]$d.SpindleSpeed } else { -1 })
            Health = [string]$d.HealthStatus; Letters = $letters; Rel = $null; Nvme = $null; Ata = $null; SmartError = '' }
    if ($r) {
        $x.Rel = @{ Temp = $(if ($r.Temperature) { [int]$r.Temperature } else { -1 }); TempMax = $(if ($r.TemperatureMax) { [int]$r.TemperatureMax } else { -1 })
                    Wear = $(if ($null -ne $r.Wear) { [int]$r.Wear } else { -1 }); Hours = $(if ($null -ne $r.PowerOnHours) { [int64]$r.PowerOnHours } else { -1 })
                    ReadErr = $(if ($null -ne $r.ReadErrorsUncorrected) { [int64]$r.ReadErrorsUncorrected } else { -1 })
                    WriteErr = $(if ($null -ne $r.WriteErrorsUncorrected) { [int64]$r.WriteErrorsUncorrected } else { -1 })
                    StartStop = $(if ($null -ne $r.StartStopCycleCount) { [int64]$r.StartStopCycleCount } else { -1 }) }
    }
    if ($smart) {
        try {
            if ($x.Bus -eq 'NVMe') { $v = $smart::Nvme($n); if ($v[0] -eq 0) { $x.Nvme = [long[]]$v } else { $x.SmartError = [string]$smart::LastError } }
            elseif ('SATA', 'ATA', 'RAID', 'SAS' -contains $x.Bus) { $v = $smart::Ata($n); if ($v[0] -eq 0 -and $v[1] -gt 0) { $x.Ata = [long[]]$v } else { $x.SmartError = [string]$smart::LastError } }
        } catch { $x.SmartError = $_.Exception.Message }
    }
    $out += $x
}
,$out
'@

# Nomes dos atributos SMART mais comuns (cada fabricante usa alguns de jeito proprio, como no CrystalDiskInfo).
$script:SmartNames = @{
    0x01 = 'Taxa de erros de leitura'; 0x02 = 'Desempenho de leitura'; 0x03 = 'Tempo para girar'; 0x04 = 'Partidas e paradas'
    0x05 = 'Setores realocados'; 0x07 = 'Erros de posicionamento'; 0x08 = 'Desempenho de posicionamento'; 0x09 = 'Horas ligado'
    0x0A = 'Novas tentativas de girar'; 0x0B = 'Novas tentativas de calibração'; 0x0C = 'Vezes ligado'; 0x0D = 'Erros de leitura (software)'
    0x64 = 'Apagamentos de blocos'; 0xA0 = 'Setores irrecuperáveis'; 0xA1 = 'Blocos reserva válidos'; 0xA3 = 'Blocos com defeito de fábrica'
    0xA4 = 'Apagamentos totais'; 0xA5 = 'Apagamentos máximos'; 0xA6 = 'Apagamentos mínimos'; 0xA7 = 'Apagamentos médios'
    0xA8 = 'Erros da interface SATA'; 0xA9 = 'Vida restante'; 0xAA = 'Blocos reserva'; 0xAB = 'Falhas de programação'
    0xAC = 'Falhas de apagamento'; 0xAD = 'Desgaste médio'; 0xAE = 'Desligamentos inesperados'; 0xAF = 'Falhas de programação (pior bloco)'
    0xB0 = 'Falhas de apagamento (pior bloco)'; 0xB1 = 'Contagem de desgaste'; 0xB3 = 'Blocos reserva usados'; 0xB4 = 'Blocos reserva livres'
    0xB5 = 'Falhas de programação'; 0xB6 = 'Falhas de apagamento'; 0xB7 = 'Quedas de velocidade SATA'; 0xB8 = 'Erros de ponta a ponta'
    0xBB = 'Erros não corrigidos informados'; 0xBC = 'Comandos expirados'; 0xBD = 'Gravações em altura alta'; 0xBE = 'Temperatura do fluxo de ar'
    0xBF = 'Impactos (sensor de queda)'; 0xC0 = 'Desligamentos de emergência'; 0xC1 = 'Ciclos de carga das cabeças'; 0xC2 = 'Temperatura'
    0xC3 = 'ECC recuperado por hardware'; 0xC4 = 'Eventos de realocação'; 0xC5 = 'Setores pendentes'; 0xC6 = 'Setores irrecuperáveis'
    0xC7 = 'Erros de CRC (cabo SATA)'; 0xC8 = 'Taxa de erros de gravação'; 0xC9 = 'Erros de leitura (software)'; 0xCA = 'Vida usada'
    0xCC = 'ECC corrigido por software'; 0xCE = 'Altura de voo das cabeças'; 0xD2 = 'Erros RAIN'; 0xDC = 'Deslocamento do disco'
    0xDF = 'Tentativas de carga'; 0xE0 = 'Atrito de carga'; 0xE1 = 'Gravações do computador'; 0xE2 = 'Tempo de carga'
    0xE6 = 'Saúde do meio'; 0xE7 = 'Vida restante'; 0xE8 = 'Reserva disponível'; 0xE9 = 'Desgaste do meio'
    0xEA = 'Médias de apagamento'; 0xEB = 'Bons blocos e reserva'; 0xF0 = 'Horas de voo das cabeças'; 0xF1 = 'Total escrito'
    0xF2 = 'Total lido'; 0xF3 = 'Total escrito (alto)'; 0xF4 = 'Total lido (alto)'; 0xF5 = 'Vida restante'
    0xF7 = 'Páginas escritas pelo computador'; 0xF8 = 'Páginas escritas pela FTL'; 0xF9 = 'Gravações na NAND (GB)'; 0xFA = 'Novas tentativas de leitura'
    0xFE = 'Proteção contra queda livre'
}

# Os mesmos 15 itens que o CrystalDiskInfo mostra em SSDs NVMe.
$script:NvmeNames = @('Aviso crítico', 'Temperatura', 'Reserva disponível', 'Limite da reserva', 'Vida usada', 'Dados lidos', 'Dados escritos',
    'Comandos de leitura', 'Comandos de escrita', 'Tempo ocupado (minutos)', 'Vezes ligado', 'Horas ligado', 'Desligamentos inseguros',
    'Erros de mídia e integridade', 'Entradas no log de erros')

function Format-DiskBytes([double]$Bytes) {
    if ($Bytes -lt 0) { return '' }
    if ($Bytes -ge 1e12) { return (Tx '{0:N2} TB' ($Bytes / 1e12)) }
    return (Tx '{0:N0} GB' ($Bytes / 1e9))
}

# Total escrito/lido dos SSDs SATA: cada fabricante conta de um jeito. So os conhecidos, o resto fica em branco.
function Get-AtaTotal($Name, $Raw) {
    if ($Raw -le 0) { return -1 }
    if ($Name -match 'Kingston|SA400|A400') { return [double]$Raw * 1e9 }
    if ($Name -match 'Samsung|Crucial|Micron|WD|WDC|Western|SanDisk|Seagate|ST\d|Toshiba|KIOXIA|Hitachi|HGST') { return [double]$Raw * 512 }
    return -1
}

# Devolve @{ Status (good/caution/bad/unknown); Pct; Temp; Hours; Cycles; Read; Written; Notes; Attrs; Kind }
function Get-DiskReport($d) {
    $rep = @{ Status = 'unknown'; Pct = -1; Temp = -1; Hours = -1; Cycles = -1; Read = -1; Written = -1; Notes = @(); Attrs = @(); Kind = 'none'; Ssd = $false }
    if (-not $d) { return $rep }
    $rep.Ssd = ($d.Bus -eq 'NVMe' -or $d.Media -eq 'SSD')
    $level = 0   # 0 bom, 1 atencao, 2 ruim
    $rel = $d.Rel
    if ($d.Nvme) {
        $v = $d.Nvme
        $rep.Kind = 'nvme'
        $rep.Temp = $v[2]; $rep.Hours = $v[12]; $rep.Cycles = $v[11]
        $rep.Read = [double]$v[6] * 512000; $rep.Written = [double]$v[7] * 512000
        $rep.Pct = [Math]::Max(0, 100 - [int]$v[5])
        $cw = [int]$v[1]
        $vals = @(('0x{0:X2}' -f $cw), ('{0} °C' -f $v[2]), ('{0}%' -f $v[3]), ('{0}%' -f $v[4]), ('{0}%' -f $v[5]),
            (Format-DiskBytes $rep.Read), (Format-DiskBytes $rep.Written), ('{0:N0}' -f $v[8]), ('{0:N0}' -f $v[9]), ('{0:N0}' -f $v[10]),
            ('{0:N0}' -f $v[11]), ('{0:N0}' -f $v[12]), ('{0:N0}' -f $v[13]), ('{0:N0}' -f $v[14]), ('{0:N0}' -f $v[15]))
        for ($i = 0; $i -lt 15; $i++) {
            $lv = 'ok'
            if ($i -eq 0 -and $cw -ne 0) { $lv = 'bad' }
            if ($i -eq 2 -and $v[3] -lt $v[4]) { $lv = 'bad' }
            if ($i -eq 4 -and $v[5] -ge 90) { $lv = 'warn' }
            if ($i -eq 13 -and $v[14] -gt 0) { $lv = 'warn' }
            $rep.Attrs += @{ Id = ('{0:X2}' -f ($i + 1)); Name = $script:NvmeNames[$i]; Raw = $vals[$i]; Level = $lv }
        }
        if ($cw -band 0x0D) { $level = 2; $rep.Notes += , @('bad', 'O próprio SSD está avisando que algo está errado (reserva acabando, confiabilidade reduzida ou modo só leitura). Faça backup agora e planeje a troca.') }
        elseif ($cw -band 0x12) { $level = [Math]::Max($level, 1); $rep.Notes += , @('warn', 'O SSD avisou que passou do limite de temperatura. Um dissipador no M.2 ou mais ventilação no gabinete resolve.') }
        if ($v[3] -lt $v[4]) { $level = 2 }
        if ($v[14] -gt 0) { $level = [Math]::Max($level, 1); $rep.Notes += , @('warn', (Tx 'O SSD registrou {0} erros de mídia (dados que ele não conseguiu ler ou gravar direito). Faça backup do que é importante.' ($v[14]))) }
    } elseif ($d.Ata) {
        $a = $d.Ata
        $rep.Kind = 'ata'
        $attr = @{}
        for ($i = 0; $i -lt $a[1]; $i++) {
            $b = 2 + 6 * $i
            $id = [int]$a[$b]; $cur = [int]$a[$b + 2]; $wst = [int]$a[$b + 3]; $thr = [int]$a[$b + 4]; $raw = [int64]$a[$b + 5]
            $attr[$id] = @{ Cur = $cur; Raw = $raw }
            $lv = 'ok'
            if ($thr -gt 0 -and $thr -lt 255 -and $cur -le $thr) { $lv = 'bad'; $level = 2 }
            elseif ((0x05, 0xC5, 0xC6) -contains $id -and $raw -gt 0) { $lv = 'warn'; $level = [Math]::Max($level, 1) }
            elseif ($id -eq 0xC7 -and $raw -gt 0) { $lv = 'warn' }
            $name = $script:SmartNames[$id]
            if (-not $name) { $name = 'Específico do fabricante' }
            $shown = if ((0xC2, 0xBE) -contains $id) { '{0} °C' -f ($raw -band 0xFF) } else { '{0:N0}' -f $raw }
            $rep.Attrs += @{ Id = ('{0:X2}' -f $id); Name = $name; Cur = $cur; Worst = $wst; Thr = $(if ($thr -ge 0) { $thr } else { '' }); Raw = $shown; Level = $lv }
        }
        if ($attr[0xC2]) { $rep.Temp = [int]($attr[0xC2].Raw -band 0xFF) } elseif ($attr[0xBE]) { $rep.Temp = [int]($attr[0xBE].Raw -band 0xFF) }
        if ($attr[0x09]) { $rep.Hours = [int64]($attr[0x09].Raw -band 0xFFFFFFFF) }
        if ($attr[0x0C]) { $rep.Cycles = [int64]($attr[0x0C].Raw -band 0xFFFFFFFF) }
        if ($attr[0xF1]) { $rep.Written = Get-AtaTotal $d.Name $attr[0xF1].Raw }
        if ($attr[0xF2]) { $rep.Read = Get-AtaTotal $d.Name $attr[0xF2].Raw }
        if ($rep.Ssd) {
            foreach ($id in 0xE7, 0xA9, 0xCA, 0xE9, 0xB1) { if ($attr[$id] -and $attr[$id].Cur -gt 0 -and $attr[$id].Cur -le 100) { $rep.Pct = $attr[$id].Cur; break } }
        }
        $re = 0; foreach ($id in 0x05, 0xC5, 0xC6) { if ($attr[$id]) { $re += [int64]$attr[$id].Raw } }
        if ($level -eq 2) { $rep.Notes += , @('bad', 'Pelo menos um atributo passou do limite de falha que o próprio fabricante definiu. O disco pode parar a qualquer momento: faça backup agora.') }
        elseif ($re -gt 0) { $rep.Notes += , @('warn', (Tx 'Há {0} setores realocados, pendentes ou irrecuperáveis. Um número que para de subir costuma ser tolerável; se aumentar de uma semana para outra, o disco está se degradando. Faça backup.' ($re))) }
        if ($attr[0xC7] -and $attr[0xC7].Raw -gt 0) { $rep.Notes += , @('info', (Tx 'Erros de CRC ({0}) vêm do cabo SATA ou da porta, não do disco. Se o número subir, troque o cabo ou a porta.' ($attr[0xC7].Raw))) }
    }
    if ($rel) {
        if ($rep.Temp -lt 0 -and $rel.Temp -gt 0) { $rep.Temp = $rel.Temp }
        if ($rep.Hours -lt 0 -and $rel.Hours -ge 0) { $rep.Hours = $rel.Hours }
        if ($rep.Pct -lt 0 -and $rel.Wear -ge 0 -and $rep.Ssd) { $rep.Pct = [Math]::Max(0, 100 - $rel.Wear) }
        if ($rep.Cycles -lt 0 -and $rel.StartStop -ge 0) { $rep.Cycles = $rel.StartStop }
        if ($rel.ReadErr -gt 0 -or $rel.WriteErr -gt 0) { $level = [Math]::Max($level, 1) }
    }
    if ($d.Health -eq 'Unhealthy') { $level = 2 } elseif ($d.Health -eq 'Warning') { $level = [Math]::Max($level, 1) }
    if ($rep.Pct -ge 0 -and $rep.Pct -le 10) { $level = [Math]::Max($level, 1); $rep.Notes += , @('warn', (Tx 'Resta {0}% da vida útil de gravação prevista pelo fabricante. O SSD não para nesse ponto, mas é hora de planejar a troca e manter backup.' ($rep.Pct))) }
    $hot = if ($rep.Ssd) { 70 } else { 55 }
    if ($rep.Temp -ge $hot) { $rep.Notes += , @('warn', (Tx 'Está a {0} °C. Acima de {1} °C o disco começa a reduzir a velocidade para se proteger e se desgasta mais.' ($rep.Temp) ($hot))) }
    if ($rep.Kind -eq 'none') {
        if ($d.Bus -eq 'USB') { $rep.Notes += , @('info', 'Discos USB normalmente não deixam ler o SMART pelo adaptador. Fica só o que o Windows informa.') }
        elseif (-not $script:Hosted) { $rep.Notes += , @('info', 'A leitura completa do SMART só funciona no Harle.exe. Fica só o que o Windows informa.') }
        else { $rep.Notes += , @('info', 'O controlador deste disco não deixou ler o SMART (comum em RAID e em alguns drivers de fabricante). Fica só o que o Windows informa.') }
        if (-not $d.Health -and -not $rel) { $level = -1 }
    }
    $rep.Status = switch ($level) { 2 { 'bad' } 1 { 'caution' } 0 { 'good' } default { 'unknown' } }
    if ($rep.Status -eq 'good' -and $rep.Notes.Count -eq 0) {
        $rep.Notes += , @('ok', $(if ($rep.Pct -ge 0) { (Tx 'Tudo normal. O SSD já gastou {0}% da vida útil de gravação prevista; no uso de jogos isso costuma durar muitos anos.' (100 - $rep.Pct)) } else { 'Tudo normal: nenhum setor com defeito e nenhum atributo perto do limite.' }))
    }
    return $rep
}

function Get-DiskStatusLabel([string]$Status) {
    switch ($Status) { 'good' { 'Bom' } 'caution' { 'Atenção' } 'bad' { 'Ruim' } default { 'Desconhecido' } }
}

# ---------------------------------------------------------------------------
#  Salvar e carregar configuracao (arquivo .json para compartilhar com a comunidade)
#  Vai junto: perfil, ajustes ligados, apps marcados, reinicio automatico, alerta, canto do overlay e o que o
#  modo partida fecha. Nao vai: overclock e marca da placa (dependem do hardware) nem o idioma.
# ---------------------------------------------------------------------------
$script:ConfigApp = 'Harle Optimizer'

function Get-WinName {
    $name = if (Test-IsWin11) { 'Windows 11' } else { 'Windows 10' }
    try {
        $v = (Get-RegState 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'DisplayVersion').Value
        if ($v) { $name += " $v" }
    } catch { }
    return $name
}

function Get-ConfigData {
    $tweaks = @($script:Tweaks | Where-Object { -not $_.Run -and (Test-Supported $_) -and (Get-TweakState $_) } | ForEach-Object { $_.Id })
    return [ordered]@{
        app = $script:ConfigApp; format = 1; version = $script:AppVersion
        exported = (Get-Date).ToString('yyyy-MM-dd HH:mm'); windows = (Get-WinName)
        profile = $script:ProfileId; tweaks = $tweaks; appsPick = (Get-AppPicks)
        autoRestart = [bool]$script:AutoRestart
        alertLimit = $script:Backup.state['alertLimit']; ovCorner = $script:Backup.state['ovCorner']
        playClose = $script:Backup.state['playClose']
    }
}

# Le e confere o arquivo. Devolve @{ Ok; Why; Data; On; Off; Missing } sem mudar nada no PC.
function Read-ConfigFile([string]$Path) {
    $res = @{ Ok = $false; Why = ''; Data = $null; On = @(); Off = @(); Missing = @() }
    try {
        $fi = Get-Item -LiteralPath $Path -ErrorAction Stop
        if ($fi.Length -gt 512KB) { $res.Why = 'O arquivo é grande demais para ser uma configuração do Harle.'; return $res }
        $d = [IO.File]::ReadAllText($Path) | ConvertFrom-Json -ErrorAction Stop
    } catch { $res.Why = 'Não deu para ler o arquivo: ele não é um JSON válido.'; return $res }
    if ([string]$d.app -ne $script:ConfigApp -or [int]$d.format -ne 1) { $res.Why = 'Este arquivo não é uma configuração do Harle.'; return $res }
    $want = @($d.tweaks | ForEach-Object { [string]$_ })
    foreach ($id in $want) {
        $t = $script:TweakById[$id]
        if (-not $t -or $t.Run -or -not (Test-Supported $t)) { $res.Missing += $id }
    }
    foreach ($t in @($script:Tweaks | Where-Object { -not $_.Run -and (Test-Supported $_) })) {
        $is = Get-TweakState $t
        $should = $want -contains $t.Id
        if ($should -and -not $is) { $res.On += $t }
        elseif (-not $should -and $is) { $res.Off += $t }
    }
    $res.Data = $d
    $res.Ok = $true
    return $res
}

# ---------------------------------------------------------------------------
#  Aba Online: ping ate os data centers dos jogos, DNS mais rapido e overlays abertos.
#  Os jogos nao publicam o IP dos servidores; o teste mede ate os data centers de Sao Paulo onde eles rodam,
#  que e o que mais pesa no ping. ICMP primeiro; se o destino nao responde ICMP, mede o tempo de conexao TCP.
# ---------------------------------------------------------------------------
$script:PingCode = @'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$targets = @(
    @{ Id = 'cf';    Name = 'Internet (Cloudflare)';  Host = '1.1.1.1';  Port = 443 }
    @{ Id = 'aws';   Name = 'AWS São Paulo';          Host = 'dynamodb.sa-east-1.amazonaws.com'; Port = 443; TcpOnly = $true }
)
# Retransmissores da Valve em Sao Paulo (CS2, Dota 2, Deadlock): a lista vem da propria Steam.
try {
    $sdr = Invoke-RestMethod -Uri 'https://api.steampowered.com/ISteamApps/GetSDRConfig/v1/?appid=730' -TimeoutSec 6 -ErrorAction Stop
    $gru = $sdr.pops.gru
    if ($gru -and $gru.relays) { $targets += @{ Id = 'valve'; Name = 'Valve São Paulo'; Host = [string]@($gru.relays)[0].ipv4; Port = 0 } }
} catch { }
$out = @()
foreach ($t in $targets) {
    $ms = New-Object 'System.Collections.Generic.List[double]'
    $sent = 10; $mode = 'icmp'
    if (-not $t.TcpOnly) {
        $p = New-Object System.Net.NetworkInformation.Ping
        for ($i = 0; $i -lt $sent; $i++) {
            try { $r = $p.Send($t.Host, 1000); if ($r.Status -eq 'Success') { $ms.Add([double]$r.RoundtripTime) } } catch { }
            Start-Sleep -Milliseconds 120
        }
        $p.Dispose()
    }
    if ($ms.Count -eq 0 -and $t.Port -gt 0) {
        $mode = 'tcp'
        for ($i = 0; $i -lt $sent; $i++) {
            $c = New-Object System.Net.Sockets.TcpClient
            $sw = [Diagnostics.Stopwatch]::StartNew()
            try { $a = $c.BeginConnect($t.Host, $t.Port, $null, $null); if ($a.AsyncWaitHandle.WaitOne(1500) -and $c.Connected) { $sw.Stop(); $ms.Add($sw.Elapsed.TotalMilliseconds) } } catch { }
            $c.Close()
            Start-Sleep -Milliseconds 120
        }
    }
    $out += @{ Id = $t.Id; Name = $t.Name; Host = $t.Host; Mode = $mode; Sent = $sent; Samples = @($ms) }
}
,$out
'@

# Tempo de resposta de cada DNS para nomes que os jogos e apps usam. O atual e o que a placa de rede usa hoje.
$script:DnsCode = @'
$ProgressPreference = 'SilentlyContinue'
$names = @('riotgames.com', 'steampowered.com', 'epicgames.com', 'discord.com', 'youtube.com', 'twitch.tv', 'ea.com', 'xbox.com')
$servers = @(
    @{ Id = 'cloudflare'; Name = 'Cloudflare'; Ip = '1.1.1.1'; Ip2 = '1.0.0.1' }
    @{ Id = 'google';     Name = 'Google';     Ip = '8.8.8.8'; Ip2 = '8.8.4.4' }
    @{ Id = 'quad9';      Name = 'Quad9';      Ip = '9.9.9.9'; Ip2 = '149.112.112.112' }
)
$cur = @()
try {
    $cfg = @(Get-NetIPConfiguration -ErrorAction Stop | Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' })
    foreach ($c in $cfg) { $cur += @(Get-DnsClientServerAddress -InterfaceIndex $c.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object { $_.ServerAddresses }) }
} catch { }
$cur = @($cur | Where-Object { $_ } | Select-Object -Unique)
if ($cur.Count -gt 0 -and -not (@($servers | ForEach-Object { $_.Ip }) -contains $cur[0])) { $servers = @(@{ Id = 'current'; Name = 'Atual'; Ip = $cur[0]; Ip2 = '' }) + $servers }
$out = @()
foreach ($s in $servers) {
    $ms = New-Object 'System.Collections.Generic.List[double]'; $fail = 0
    foreach ($round in 1, 2) {
        foreach ($n in $names) {
            $sw = [Diagnostics.Stopwatch]::StartNew()
            try { [void](Resolve-DnsName -Name $n -Server $s.Ip -Type A -DnsOnly -NoHostsFile -QuickTimeout -ErrorAction Stop); $sw.Stop(); $ms.Add($sw.Elapsed.TotalMilliseconds) } catch { $fail++ }
        }
    }
    $out += @{ Id = $s.Id; Name = $s.Name; Ip = $s.Ip; Ip2 = $s.Ip2; Samples = @($ms); Fail = $fail; Current = ($cur -contains $s.Ip) }
}
,@{ Servers = $out; Current = $cur }
'@

# Resume as amostras: media, minimo, maximo, variacao (jitter) e perda.
function Get-PingStats($Samples, [int]$Sent) {
    $a = @($Samples | ForEach-Object { [double]$_ })
    $st = @{ Avg = -1; Min = -1; Max = -1; Jitter = -1; Loss = 100; Level = 'bad' }
    if ($Sent -gt 0) { $st.Loss = [Math]::Round(100 * ($Sent - $a.Count) / $Sent) }
    if ($a.Count -eq 0) { return $st }
    $st.Avg = [Math]::Round(($a | Measure-Object -Average).Average)
    $st.Min = [Math]::Round(($a | Measure-Object -Minimum).Minimum)
    $st.Max = [Math]::Round(($a | Measure-Object -Maximum).Maximum)
    $j = 0.0; for ($i = 1; $i -lt $a.Count; $i++) { $j += [Math]::Abs($a[$i] - $a[$i - 1]) }
    $st.Jitter = if ($a.Count -gt 1) { [Math]::Round($j / ($a.Count - 1)) } else { 0 }
    $st.Level = if ($st.Loss -ge 20 -or $st.Avg -gt 100) { 'bad' } elseif ($st.Loss -gt 0 -or $st.Avg -gt 60 -or $st.Jitter -gt 15) { 'warn' } else { 'ok' }
    return $st
}

$script:PingGames = @{
    cf = 'Mede a qualidade da sua conexão até a internet: se aqui já está alto ou com perda, o problema é a sua rede ou o provedor.'
    aws = 'Fortnite e muitos outros jogos online usam os servidores da AWS em São Paulo.'
    valve = 'Counter-Strike 2, Dota 2 e Deadlock passam pelos retransmissores da Valve em São Paulo.'
}

# Overlays que desenham por cima do jogo. Close = pode fechar com seguranca; Where = onde desligar o overlay.
$script:OverlayApps = @(
    @{ Proc = 'Discord';            Name = 'Discord';                 Close = $false; Where = 'Configurações do usuário, Overlay do jogo: desligue "Ativar overlay no jogo". O chat de voz continua funcionando.' }
    @{ Proc = 'steam';              Name = 'Steam';                   Close = $false; Where = 'Steam, Configurações, Durante o jogo: desmarque "Ativar o Steam Overlay durante o jogo".' }
    @{ Proc = 'NVIDIA Overlay';     Name = 'Overlay da NVIDIA';       Close = $false; Where = 'No app da NVIDIA, Configurações, Recursos: desligue a sobreposição no jogo (Alt + Z), se não usa gravação nem filtros.' }
    @{ Proc = 'RadeonSoftware';     Name = 'AMD Adrenalin';           Close = $false; Where = 'Adrenalin, Configurações, Preferências: desligue a sobreposição no jogo, se não usa as métricas nem a gravação.' }
    @{ Proc = 'RTSS';               Name = 'RivaTuner (RTSS)';        Close = $true;  Where = 'Desenha o contador do MSI Afterburner em cima do jogo e fica injetado em todos os jogos. Feche se não usa o contador.' }
    @{ Proc = 'MSIAfterburner';     Name = 'MSI Afterburner';         Close = $true;  Where = 'Se não usa overclock nem o contador na tela, pode fechar e tirar da inicialização.' }
    @{ Proc = 'Overwolf';           Name = 'Overwolf';                Close = $true;  Where = 'Plataforma de overlays (Outplayed, apps de estatística). Pesa bastante em PCs de entrada.' }
    @{ Proc = 'Medal';              Name = 'Medal';                   Close = $true;  Where = 'Grava clipes o tempo todo em segundo plano, como o "Gravar o que aconteceu".' }
    @{ Proc = 'RazerCortex';        Name = 'Razer Cortex';            Close = $true;  Where = 'Otimizador e overlay da Razer. Rodar dois otimizadores juntos atrapalha mais do que ajuda.' }
    @{ Proc = 'GeForceExperience';  Name = 'GeForce Experience';      Close = $false; Where = 'Configurações, Geral: desligue "Sobreposição no jogo", se não usa gravação nem filtros.' }
)

function Get-OpenOverlays([string[]]$Running) {
    $set = @{}
    foreach ($p in @($Running)) { $set[([string]$p).ToLowerInvariant()] = $true }
    return @($script:OverlayApps | Where-Object { $set.ContainsKey($_.Proc.ToLowerInvariant()) })
}

# Troca o DNS das placas de rede conectadas. O que estava antes fica guardado (vazio = automatico pelo roteador).
function Get-ActiveAdapters {
    return @(Get-NetIPConfiguration -ErrorAction SilentlyContinue | Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' })
}

function Set-HarleDns([string[]]$Servers) {
    $old = ConvertTo-Hashtable $script:Backup.state['dnsOld']
    foreach ($c in Get-ActiveAdapters) {
        $key = [string]$c.InterfaceIndex
        if (-not $old.ContainsKey($key)) {
            # NameServer vazio no registro = DNS automatico (DHCP)
            $guid = [string]$c.NetAdapter.InterfaceGuid
            $static = ''
            try { $static = [string](Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$guid" -Name NameServer -ErrorAction Stop).NameServer } catch { }
            $old[$key] = $static
        }
        Set-DnsClientServerAddress -InterfaceIndex $c.InterfaceIndex -ServerAddresses $Servers -ErrorAction Stop
    }
    $script:Backup.state['dnsOld'] = $old
    $script:Backup.state['dnsSet'] = ($Servers -join ',')
    Save-Backup
    try { Clear-DnsClientCache -ErrorAction SilentlyContinue } catch { }
    Write-Log "DNS trocado para $($Servers -join ', ')"
}

function Restore-HarleDns {
    $old = ConvertTo-Hashtable $script:Backup.state['dnsOld']
    foreach ($k in @($old.Keys)) {
        try {
            $v = [string]$old[$k]
            if ($v) { Set-DnsClientServerAddress -InterfaceIndex ([int]$k) -ServerAddresses ($v -split '[, ]+' | Where-Object { $_ }) -ErrorAction Stop }
            else { Set-DnsClientServerAddress -InterfaceIndex ([int]$k) -ResetServerAddresses -ErrorAction Stop }
        } catch { Write-Log "DNS da placa $k nao voltou: $($_.Exception.Message)" }
    }
    $script:Backup.state.Remove('dnsOld')
    $script:Backup.state.Remove('dnsSet')
    Save-Backup
    try { Clear-DnsClientCache -ErrorAction SilentlyContinue } catch { }
    Write-Log 'DNS devolvido ao original'
}

# ---------------------------------------------------------------------------
#  Aba Jogos: ajustes por jogo.
#  Auto  = o Harle entra sozinho no modo partida quando o jogo abre (com o Harle aberto, pode estar minimizado).
#  Prio  = prioridade alta fixa pelo proprio Windows (Image File Execution Options), funciona sem o Harle aberto.
#  Gpu   = usa a placa de video dedicada (Configuracoes > Sistema > Tela > Elementos graficos), so muda algo em
#          PCs com duas placas, como notebooks com video integrado.
# ---------------------------------------------------------------------------
$script:IfeoRoot = 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
$script:GpuPrefKey = 'HKCU\Software\Microsoft\DirectX\UserGpuPreferences'

# Nome do exe sem pasta e sem .exe (aceita \ e /).
function Get-ExeBase([string]$Exe) { return (([string]$Exe -split '[\\/]')[-1] -replace '(?i)\.exe$', '') }

function Get-Games {
    $out = @()
    foreach ($g in @($script:Backup.state['games'])) {
        if (-not $g) { continue }
        $h = ConvertTo-Hashtable $g
        if (-not $h.Exe) { continue }
        foreach ($k in 'Auto', 'Prio', 'Gpu') { $h[$k] = [bool]$h[$k] }
        if (-not $h.Name) { $h.Name = (Get-ExeBase ([string]$h.Exe)) }
        $out += $h
    }
    return $out
}

function Save-Games($Games) {
    $script:Backup.state['games'] = @($Games)
    Save-Backup
}

# Nome amigavel a partir do exe: "VALORANT-Win64-Shipping" vira "VALORANT".
function Get-GameLabel([string]$Exe) {
    $n = Get-ExeBase $Exe
    $n = $n -replace '(?i)[-_ ]?(win64|win32|x64|shipping|dx11|dx12|vulkan|retail|launcher)\b', ''
    $n = ($n -replace '[-_]+', ' ').Trim()
    if (-not $n) { $n = Get-ExeBase $Exe }
    return $n
}

function Add-Game([string]$Exe) {
    $games = @(Get-Games)
    if (@($games | Where-Object { [string]$_.Exe -eq $Exe }).Count -gt 0) { return $false }
    $games += @{ Exe = $Exe; Name = (Get-GameLabel $Exe); Auto = $true; Prio = $false; Gpu = $false }
    Save-Games $games
    Write-Log "Jogo adicionado: $Exe"
    return $true
}

# Liga ou desliga um ajuste do jogo no registro, guardando o valor que existia antes.
function Set-GameFlag($Game, [string]$Flag, [bool]$On) {
    $exeName = (Get-ExeBase ([string]$Game.Exe)) + '.exe'
    if ($Flag -eq 'Prio') {
        $path = "$($script:IfeoRoot)\$exeName\PerfOptions"
        if ($On) {
            $old = Get-RegState $path 'CpuPriorityClass'
            if ($old.Exists -and -not $Game.ContainsKey('PrioOld')) { $Game.PrioOld = [int]$old.Value }
            Set-RegValue $path 'CpuPriorityClass' 3 'DWord'
        } else {
            if ($Game.ContainsKey('PrioOld') -and $null -ne $Game.PrioOld) { Set-RegValue $path 'CpuPriorityClass' ([int]$Game.PrioOld) 'DWord' } else { Remove-RegValue $path 'CpuPriorityClass' }
            $Game.Remove('PrioOld')
        }
    } elseif ($Flag -eq 'Gpu') {
        if ($On) {
            $old = Get-RegState $script:GpuPrefKey ([string]$Game.Exe)
            if ($old.Exists -and -not $Game.ContainsKey('GpuOld')) { $Game.GpuOld = [string]$old.Value }
            Set-RegValue $script:GpuPrefKey ([string]$Game.Exe) 'GpuPreference=2;' 'String'
        } else {
            if ($Game.ContainsKey('GpuOld') -and $Game.GpuOld) { Set-RegValue $script:GpuPrefKey ([string]$Game.Exe) ([string]$Game.GpuOld) 'String' } else { Remove-RegValue $script:GpuPrefKey ([string]$Game.Exe) }
            $Game.Remove('GpuOld')
        }
    }
    $Game[$Flag] = $On
}

# Desfaz o que cada jogo mudou no registro (usado pelo Reverter tudo e ao tirar o jogo da lista).
function Reset-GameFlags($Game) {
    foreach ($f in 'Prio', 'Gpu') { if ($Game[$f]) { try { Set-GameFlag $Game $f $false } catch { Write-Log "Jogo $($Game.Name) ($f): $($_.Exception.Message)" } } }
}

# Qual jogo com entrada automatica esta rodando agora. Devolve @{ Game; Pid } ou $null.
function Find-RunningGame($Games, $Procs) {
    foreach ($g in @($Games | Where-Object { $_.Auto })) {
        $want = Get-ExeBase ([string]$g.Exe)
        $p = @($Procs | Where-Object { $_.ProcessName -eq $want }) | Select-Object -First 1
        if ($p) { return @{ Game = $g; Pid = [int]$p.Id } }
    }
    return $null
}

# ----- Historico de FPS: pontos do grafico de um jogo -----
function Get-FpsApps($List) {
    $count = @{}
    foreach ($m in @($List)) { if ($m) { $count[[string]$m.App] = 1 + [int]$count[[string]$m.App] } }
    return @($count.Keys | Where-Object { $count[$_] -ge 2 } | Sort-Object)
}

# Escala as medicoes de um jogo para uma area de W x H. Devolve @{ Avg; Low (listas de pontos); Max; Labels }.
function Get-FpsChart($List, [string]$App, [double]$W, [double]$H) {
    $ms = @($List | Where-Object { $_ -and [string]$_.App -eq $App })
    $res = @{ Avg = @(); Low = @(); Max = 0; Labels = @(); Items = $ms }
    if ($ms.Count -lt 2) { return $res }
    $max = 0.0
    foreach ($m in $ms) { $max = [Math]::Max($max, [double]$m.Avg) }
    $top = [Math]::Ceiling($max / 20) * 20
    if ($top -le 0) { $top = 20 }
    $res.Max = $top
    $step = $W / ($ms.Count - 1)
    for ($i = 0; $i -lt $ms.Count; $i++) {
        $x = [Math]::Round($i * $step, 1)
        $res.Avg += , @($x, [Math]::Round($H - $H * [double]$ms[$i].Avg / $top, 1))
        $res.Low += , @($x, [Math]::Round($H - $H * [double]$ms[$i].Low / $top, 1))
        $res.Labels += ([string]$ms[$i].When -replace ' .*$', '' -replace '/\d{4}$', '')
    }
    return $res
}

function Get-DebloatTweaks {
    return @($script:Tweaks | Where-Object { ('debloat', 'priv') -contains $_.Cat -and -not $_.Run -and -not $_.Manual -and -not $_.Optional -and (Test-Supported $_) })
}

# ----- Debloat em forma de lista: a pessoa escolhe o que sai -----
# Marcado = fica ligado (o item some do Windows); desmarcado = fica como o Windows e, se ja estava ligado, volta ao original.
# Sem escolha salva: o que ja esta ligado vem marcado, os recomendados vem marcados e os opcionais desmarcados.
function Get-DebloatCandidates {
    return @($script:Tweaks | Where-Object { ('debloat', 'priv') -contains $_.Cat -and -not $_.Run -and -not $_.Manual -and (Test-Supported $_) })
}

function Get-DebloatPicks {
    $ov = ConvertTo-Hashtable $script:Backup.state['debloatPick']
    $out = @{}
    foreach ($t in Get-DebloatCandidates) {
        $out[$t.Id] = if ($ov.ContainsKey($t.Id)) { [bool]$ov[$t.Id] } elseif (Get-TweakState $t) { $true } else { -not $t.Optional }
    }
    $out['apps'] = if ($ov.ContainsKey('apps')) { [bool]$ov['apps'] } else { $true }
    return $out
}

function Set-DebloatPicks($Picks) {
    $script:Backup.state['debloatPick'] = $Picks
    Save-Backup
}

# O que o debloat faria agora com as escolhas salvas.
function Get-DebloatPlan {
    $p = Get-DebloatPicks
    $plan = @{ On = @(); Off = @(); Keep = 0; Apps = $false; AppCount = 0 }
    foreach ($t in Get-DebloatCandidates) {
        $is = Get-TweakState $t
        if ($p[$t.Id] -and -not $is) { $plan.On += $t }
        elseif (-not $p[$t.Id] -and $is) { $plan.Off += $t }
        elseif ($p[$t.Id]) { $plan.Keep++ }
    }
    $picks = Get-AppPicks
    $plan.AppCount = @($picks.Keys | Where-Object { $picks[$_] }).Count
    $plan.Apps = [bool]$p['apps'] -and $plan.AppCount -gt 0
    return $plan
}

# ---------------------------------------------------------------------------
#  Aba Memoria: limpeza de RAM no estilo do Mem Reduct (feita do zero, so com chamadas do Windows).
#  Lista em espera (cache) ja conta como memoria disponivel; limpar ajuda em jogos que travam quando a
#  memoria livre de verdade acaba, nao aumenta FPS por si so. Esvaziar o working set dos programas e opcional:
#  os programas recarregam o que perderam e isso pode causar travadas logo depois.
# ---------------------------------------------------------------------------
$script:MemDefaults = @{ Low = $true; Standby = $true; Modified = $true; WorkingSet = $false; Auto = $false; Limit = 1024; PlayOnly = $false }

function Get-MemOptions {
    $ov = ConvertTo-Hashtable $script:Backup.state['mem']
    $o = @{}
    foreach ($k in $script:MemDefaults.Keys) { $o[$k] = if ($ov.ContainsKey($k)) { $ov[$k] } else { $script:MemDefaults[$k] } }
    if (@(512, 1024, 2048, 4096) -notcontains [int]$o.Limit) { $o.Limit = 1024 }
    return $o
}

function Set-MemOption([string]$Key, $Value) {
    $o = Get-MemOptions
    $o[$Key] = $Value
    $script:Backup.state['mem'] = $o
    Save-Backup
}

# Comandos de NtSetSystemInformation na ordem certa: working set e lista modificada antes,
# porque o que sai deles vai para a lista em espera, que e limpa por ultimo.
function Get-MemCommands($Opt) {
    $c = @()
    if ($Opt.WorkingSet) { $c += 2 }
    if ($Opt.Modified)   { $c += 3 }
    if ($Opt.Standby)    { $c += 4 } elseif ($Opt.Low) { $c += 5 }
    return $c
}

# Limpeza automatica: so quando a memoria livre de verdade (zerada + livre) cai abaixo do limite e ha
# pelo menos 1 GB em espera para liberar. Nunca mexe no working set dos programas.
function Test-MemAutoNeeded($Lists, [int]$LimitMB) {
    if (-not $Lists -or $Lists[1] -lt 0) { return $false }
    $free = [double]$Lists[0] + [double]$Lists[1]
    return ($free -lt $LimitMB -and [double]$Lists[5] -ge 1024)
}

$script:MemCleanCode = @'
param([int[]]$Commands)
$before = [Harle.Memory]::Lists()
$res = @()
foreach ($c in $Commands) { $res += "$c=$([Harle.Memory]::Command($c))" }
Start-Sleep -Milliseconds 400
$after = [Harle.Memory]::Lists()
"$($before[0] + $before[1])|$($after[0] + $after[1])|$($res -join ',')|$([Harle.Memory]::LastError)"
'@

# ---------------------------------------------------------------------------
#  Aba Drivers: o que falta depois de formatar.
#  Drivers vem do Windows Update (assinados pela Microsoft, pelo mesmo servico que o Windows usa), mas a pessoa
#  escolhe quais e quando. Placa de video e chipset: o Harle mostra a versao instalada e abre o site oficial,
#  porque o driver do Windows Update costuma ser mais antigo que o do fabricante.
# ---------------------------------------------------------------------------
# Muita gente desliga o Windows Update. O Harle so usa o catalogo de drivers dele, na hora da busca:
# liga o servico (e o BITS) se estiverem desligados, faz a busca ou a instalacao e devolve tudo como estava.
# A politica "nao trazer drivers pelo Windows Update" tambem e suspensa so durante esse tempo.
$script:WuHelperCode = @'
function Open-Wu {
    $st = @{ Svc = @(); Policy = $false; Blocked = '' }
    $script:WuSt = $st
    $k = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    try {
        $pol = Get-ItemProperty -LiteralPath $k -ErrorAction Stop
        if ($pol.DisableWindowsUpdateAccess -eq 1) { $st.Blocked = 'politica' }
        elseif ($pol.WUServer -and (Get-ItemProperty -LiteralPath "$k\AU" -ErrorAction SilentlyContinue).UseWUServer -eq 1) { $st.Blocked = 'wsus' }
    } catch { }
    if ($st.Blocked) { return $st }
    foreach ($n in 'wuauserv', 'bits') {
        $s = Get-CimInstance Win32_Service -Filter "Name='$n'" -ErrorAction SilentlyContinue
        if (-not $s) { continue }
        $st.Svc += @{ Name = $n; Mode = [string]$s.StartMode; Running = ($s.State -eq 'Running') }
        if ($s.StartMode -eq 'Disabled') { Set-Service -Name $n -StartupType Manual -ErrorAction Stop }
        if ($s.State -ne 'Running') { Start-Service -Name $n -ErrorAction Stop }
    }
    try {
        if ((Get-ItemProperty -LiteralPath $k -ErrorAction Stop).ExcludeWUDriversInQualityUpdate -eq 1) {
            Set-ItemProperty -LiteralPath $k -Name ExcludeWUDriversInQualityUpdate -Value 0 -Type DWord
            $st.Policy = $true
        }
    } catch { }
    return $st
}
function Close-Wu($st) {
    if (-not $st) { return }
    if ($st.Policy) { try { Set-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -Name ExcludeWUDriversInQualityUpdate -Value 1 -Type DWord } catch { } }
    foreach ($x in @($st.Svc)) {
        if (-not $x.Running) { Stop-Service -Name $x.Name -Force -ErrorAction SilentlyContinue }
        if ($x.Mode -eq 'Disabled') { Set-Service -Name $x.Name -StartupType Disabled -ErrorAction SilentlyContinue }
    }
}
'@

$script:DriverScanCode = $script:WuHelperCode + @'
$ProgressPreference = 'SilentlyContinue'
$res = @{ Updates = @(); Problems = @(); Error = ''; Opened = $false }
$wu = $null
try {
    $wu = Open-Wu
    if ($wu.Blocked) { throw "bloqueado:$($wu.Blocked)" }
    $res.Opened = (@($wu.Svc | Where-Object { -not $_.Running -or $_.Mode -eq 'Disabled' }).Count -gt 0) -or $wu.Policy
    $session = New-Object -ComObject Microsoft.Update.Session
    $session.ClientApplicationID = 'Harle Optimizer'
    $searcher = $session.CreateUpdateSearcher()
    $found = $searcher.Search("IsInstalled=0 and Type='Driver' and IsHidden=0")
    foreach ($u in $found.Updates) {
        $res.Updates += @{ Id = [string]$u.Identity.UpdateID; Title = [string]$u.Title; Class = [string]$u.DriverClass
            Maker = [string]$u.DriverManufacturer; Model = [string]$u.DriverModel; Date = $(try { [datetime]$u.DriverVerDate } catch { $null })
            Size = [double]$u.MaxDownloadSize }
    }
} catch { $res.Error = $_.Exception.Message } finally { Close-Wu $script:WuSt }
try {
    foreach ($d in @(Get-CimInstance Win32_PnPEntity -ErrorAction Stop | Where-Object { $_.ConfigManagerErrorCode -and $_.ConfigManagerErrorCode -ne 22 })) {
        $res.Problems += @{ Name = $(if ($d.Name) { [string]$d.Name } else { [string]$d.DeviceID }); Code = [int]$d.ConfigManagerErrorCode; Id = [string]$d.DeviceID }
    }
} catch { }
$res
'@

$script:DriverInstallCode = "param([string[]]`$Ids)`n" + $script:WuHelperCode + @'
$ProgressPreference = 'SilentlyContinue'
$out = @()
$wu = $null
try {
    $wu = Open-Wu
    if ($wu.Blocked) { throw "bloqueado:$($wu.Blocked)" }
    $session = New-Object -ComObject Microsoft.Update.Session
    $session.ClientApplicationID = 'Harle Optimizer'
    $found = $session.CreateUpdateSearcher().Search("IsInstalled=0 and Type='Driver' and IsHidden=0")
    $coll = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($u in $found.Updates) {
        if ($Ids -contains [string]$u.Identity.UpdateID) {
            if (-not $u.EulaAccepted) { $u.AcceptEula() }
            [void]$coll.Add($u)
        }
    }
    if ($coll.Count -eq 0) { throw 'nenhum' }
    $dl = $session.CreateUpdateDownloader(); $dl.Updates = $coll; [void]$dl.Download()
    $inst = $session.CreateUpdateInstaller(); $inst.Updates = $coll
    $r = $inst.Install()
    for ($i = 0; $i -lt $coll.Count; $i++) { $out += "item|$($coll.Item($i).Title)|$($r.GetUpdateResult($i).ResultCode)" }
    $out += "fim|$($r.ResultCode)|$($r.RebootRequired)"
} catch { $out += "erro|$($_.Exception.Message)" } finally { Close-Wu $script:WuSt }
$out
'@

# Erro da busca em palavras simples.
function Get-WuErrorText([string]$Err) {
    if ($Err -match 'bloqueado:politica') { return 'O acesso ao Windows Update foi bloqueado por uma política neste PC (algum otimizador ou a empresa). O Harle não desfaz isso sozinho; use os sites oficiais logo abaixo.' }
    if ($Err -match 'bloqueado:wsus') { return 'Este PC busca atualizações num servidor da empresa (WSUS), e não na Microsoft. Use os sites oficiais logo abaixo.' }
    if ($Err -match 'Service|servi') { return 'Não deu para ligar o serviço do Windows Update; algum programa pode ter bloqueado ele. Use os sites oficiais logo abaixo.' }
    if ($Err -match '0x8024402C|0x80072EE7|0x80072EFD|0x8024401C') { return 'Sem conexão com os servidores da Microsoft. Confira a internet e tente de novo.' }
    return $Err
}

# O que cada codigo do Gerenciador de Dispositivos quer dizer.
function Get-DeviceCodeText([int]$Code) {
    switch ($Code) {
        28 { 'Sem driver instalado.' }
        1  { 'Configurado errado: reinstale o driver.' }
        10 { 'O dispositivo não conseguiu iniciar: atualize ou reinstale o driver.' }
        18 { 'Precisa reinstalar o driver.' }
        31 { 'O Windows não conseguiu carregar o driver.' }
        39 { 'O driver está corrompido ou faltando.' }
        43 { 'O Windows parou o dispositivo porque ele relatou um problema (driver ou hardware).' }
        45 { 'Não está conectado agora.' }
        default { (Tx 'Problema com o código {0} no Gerenciador de Dispositivos.' $Code) }
    }
}

# Marcados por padrao: tudo, menos placa de video (o driver do fabricante e melhor e mais novo).
function Test-DriverDefaultPick($U) {
    return -not ([string]$U.Class -match '^(Display|Video)' -or [string]$U.Title -match '(?i)nvidia|radeon|geforce|intel.*graphics|arc\b')
}

function Get-DriverSites($Specs) {
    $out = @()
    foreach ($g in @($Specs.Gpus)) {
        $n = [string]$g.Name
        if ($n -match 'NVIDIA') { $out += @{ Part = $n; Name = 'App da NVIDIA (baixa e atualiza o driver GeForce)'; Url = 'https://www.nvidia.com/pt-br/software/nvidia-app/'; Gpu = $g } }
        elseif ($n -match 'AMD|Radeon') { $out += @{ Part = $n; Name = 'AMD Software: Adrenalin Edition (detecta a placa sozinho)'; Url = 'https://www.amd.com/pt/support/download/drivers.html'; Gpu = $g } }
        elseif ($n -match 'Intel') { $out += @{ Part = $n; Name = 'Assistente de Driver e Suporte da Intel'; Url = 'https://www.intel.com.br/content/www/br/pt/support/detect.html'; Gpu = $g } }
    }
    $cpu = [string]$Specs.Cpu.Name
    if ($cpu -match 'AMD|Ryzen') { $out += @{ Part = $cpu; Name = 'Driver de chipset da AMD (Ryzen): melhora o agendamento dos núcleos e a energia'; Url = 'https://www.amd.com/pt/support/download/drivers.html'; Gpu = $null } }
    elseif ($cpu -match 'Intel') { $out += @{ Part = $cpu; Name = 'Chipset Intel: vem pelo Windows Update; o Assistente da Intel confere se falta algo'; Url = 'https://www.intel.com.br/content/www/br/pt/support/detect.html'; Gpu = $null } }
    return $out
}

# ---------------------------------------------------------------------------
#  Kit de formatacao e runtimes para jogos (aba Drivers).
#  Drivers de rede nao vao dentro do Harle.exe: a licenca dos fabricantes nao permite redistribuir, o exe ficaria
#  enorme e um driver de outro modelo pode derrubar a rede. No lugar, o Harle salva os drivers do PROPRIO PC num
#  pendrive antes de formatar (Export-WindowsDriver) e instala de volta depois, sem internet.
#  Runtimes: so os instaladores oficiais da Microsoft, conferidos pela assinatura digital antes de rodar.
# ---------------------------------------------------------------------------
$script:Runtimes = @(
    @{ Id = 'vc14x64'; Name = 'Visual C++ 2015-2022 (64 bits)'; Year = '2015|2017|2019|2022'; Arch = 'x64'; Rec = $true; File = 'vc_redist.x64.exe'; Url = 'https://aka.ms/vs/17/release/vc_redist.x64.exe'; Args = '/install /quiet /norestart' }
    @{ Id = 'vc14x86'; Name = 'Visual C++ 2015-2022 (32 bits)'; Year = '2015|2017|2019|2022'; Arch = 'x86'; Rec = $true; File = 'vc_redist.x86.exe'; Url = 'https://aka.ms/vs/17/release/vc_redist.x86.exe'; Args = '/install /quiet /norestart' }
    @{ Id = 'vc12x64'; Name = 'Visual C++ 2013 (64 bits)'; Year = '2013'; Arch = 'x64'; Rec = $true; File = 'vcredist2013_x64.exe'; Url = 'https://aka.ms/highdpimfc2013x64enu'; Args = '/install /quiet /norestart' }
    @{ Id = 'vc12x86'; Name = 'Visual C++ 2013 (32 bits)'; Year = '2013'; Arch = 'x86'; Rec = $true; File = 'vcredist2013_x86.exe'; Url = 'https://aka.ms/highdpimfc2013x86enu'; Args = '/install /quiet /norestart' }
    @{ Id = 'vc11x64'; Name = 'Visual C++ 2012 (64 bits)'; Year = '2012'; Arch = 'x64'; Rec = $true; File = 'vcredist2012_x64.exe'; Url = 'https://download.microsoft.com/download/1/6/B/16B06F60-3B20-4FF2-B699-5E9B7962F9AE/VSU_4/vcredist_x64.exe'; Args = '/install /quiet /norestart' }
    @{ Id = 'vc11x86'; Name = 'Visual C++ 2012 (32 bits)'; Year = '2012'; Arch = 'x86'; Rec = $true; File = 'vcredist2012_x86.exe'; Url = 'https://download.microsoft.com/download/1/6/B/16B06F60-3B20-4FF2-B699-5E9B7962F9AE/VSU_4/vcredist_x86.exe'; Args = '/install /quiet /norestart' }
    @{ Id = 'vc10x64'; Name = 'Visual C++ 2010 (64 bits)'; Year = '2010'; Arch = 'x64'; Rec = $true; File = 'vcredist2010_x64.exe'; Url = 'https://download.microsoft.com/download/1/6/5/165255E7-1014-4D0A-B094-B6A430A6BFFC/vcredist_x64.exe'; Args = '/q /norestart' }
    @{ Id = 'vc10x86'; Name = 'Visual C++ 2010 (32 bits)'; Year = '2010'; Arch = 'x86'; Rec = $true; File = 'vcredist2010_x86.exe'; Url = 'https://download.microsoft.com/download/1/6/5/165255E7-1014-4D0A-B094-B6A430A6BFFC/vcredist_x86.exe'; Args = '/q /norestart' }
    @{ Id = 'vc9x64';  Name = 'Visual C++ 2008 (64 bits)'; Year = '2008'; Arch = 'x64'; Rec = $false; File = 'vcredist2008_x64.exe'; Url = 'https://download.microsoft.com/download/5/D/8/5D8C65CB-C849-4025-8E95-C3966CAFD8AE/vcredist_x64.exe'; Args = '/q' }
    @{ Id = 'vc9x86';  Name = 'Visual C++ 2008 (32 bits)'; Year = '2008'; Arch = 'x86'; Rec = $false; File = 'vcredist2008_x86.exe'; Url = 'https://download.microsoft.com/download/5/D/8/5D8C65CB-C849-4025-8E95-C3966CAFD8AE/vcredist_x86.exe'; Args = '/q' }
    @{ Id = 'vc8x64';  Name = 'Visual C++ 2005 (64 bits)'; Year = '2005'; Arch = 'x64'; Rec = $false; File = 'vcredist2005_x64.exe'; Url = 'https://download.microsoft.com/download/8/B/4/8B42259F-5D70-43F4-AC2E-4B208FD8D66A/vcredist_x64.EXE'; Args = '/Q' }
    @{ Id = 'vc8x86';  Name = 'Visual C++ 2005 (32 bits)'; Year = '2005'; Arch = 'x86'; Rec = $false; File = 'vcredist2005_x86.exe'; Url = 'https://download.microsoft.com/download/8/B/4/8B42259F-5D70-43F4-AC2E-4B208FD8D66A/vcredist_x86.EXE'; Args = '/Q' }
    @{ Id = 'dx9';     Name = 'DirectX (junho de 2010)'; Kind = 'dx'; Rec = $true; File = 'directx_Jun2010_redist.exe'; Url = 'https://download.microsoft.com/download/8/4/a/84a35bf1-dafe-4ae8-82af-ad2ae20b6b14/directx_Jun2010_redist.exe'; Args = '' }
    @{ Id = 'net35';   Name = '.NET Framework 3.5'; Kind = 'feature'; Rec = $true; File = ''; Url = ''; Args = '' }
    @{ Id = 'net8';    Name = '.NET 8 Desktop Runtime'; Kind = 'net8'; Rec = $false; File = 'windowsdesktop-runtime-8-x64.exe'; Url = 'https://aka.ms/dotnet/8.0/windowsdesktop-runtime-win-x64.exe'; Args = '/install /quiet /norestart' }
)

$script:RuntimeNotes = @{
    vc14x64 = 'O que a maioria dos jogos e launchers atuais usa.'; vc14x86 = 'Jogos e programas de 32 bits também precisam dele, mesmo no Windows de 64 bits.'
    vc12x64 = 'Jogos de 2014 a 2017.'; vc12x86 = 'Jogos de 2014 a 2017 em 32 bits.'
    vc11x64 = 'Jogos de 2012 a 2014.'; vc11x86 = 'Jogos de 2012 a 2014 em 32 bits.'
    vc10x64 = 'Jogos de 2010 a 2013.'; vc10x86 = 'Jogos de 2010 a 2013 em 32 bits.'
    vc9x64 = 'Jogos antigos (2008 a 2011). Só se algum jogo pedir.'; vc9x86 = 'Jogos antigos (2008 a 2011). Só se algum jogo pedir.'
    vc8x64 = 'Jogos bem antigos (2005 a 2008). Só se algum jogo pedir.'; vc8x86 = 'Jogos bem antigos (2005 a 2008). Só se algum jogo pedir.'
    dx9 = 'As partes antigas do DirectX (d3dx9, XAudio2, XInput 1.3) que o Windows 10 e 11 não trazem. Resolve o erro "d3dx9_43.dll não encontrado".'
    net35 = 'Jogos e programas antigos pedem. Vem do próprio Windows e precisa de internet.'
    net8 = 'Alguns launchers e ferramentas de mods recentes pedem.'
}

# Visual C++ instalado? Olha os nomes na lista de programas instalados (64 e 32 bits).
function Get-InstalledNames {
    $names = @()
    foreach ($k in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*') {
        try { $names += @(Get-ItemProperty -Path $k -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.DisplayName } | Where-Object { $_ }) } catch { }
    }
    return $names
}

function Test-VcInstalled($R, $Names) {
    $hits = @($Names | Where-Object { $_ -match "Visual C\+\+ ($($R.Year))\b" })
    if ($R.Arch -eq 'x64') { return (@($hits | Where-Object { $_ -match 'x64|64-bit' }).Count -gt 0) }
    return (@($hits | Where-Object { $_ -notmatch 'x64|64-bit' }).Count -gt 0)
}

function Test-RuntimeInstalled($R, $Names) {
    switch ([string]$R.Kind) {
        'dx'      { return (Test-Path -LiteralPath (Join-Path $env:WINDIR 'System32\d3dx9_43.dll')) }
        'feature' { try { return ((Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v3.5' -ErrorAction Stop).Install -eq 1) } catch { return $false } }
        'net8'    { return (@(Get-ChildItem -Path (Join-Path $env:ProgramFiles 'dotnet\shared\Microsoft.WindowsDesktop.App') -Directory -Filter '8.*' -ErrorAction SilentlyContinue).Count -gt 0) }
        default   { return (Test-VcInstalled $R $Names) }
    }
}

# Procura kits salvos na raiz de todos os discos e pendrives, e na pasta de onde o Harle foi aberto.
function Find-HarleKits([string[]]$Roots) {
    $found = @()
    foreach ($r in @($Roots)) {
        if (-not $r) { continue }
        foreach ($cand in @((Join-Path $r 'Harle-Kit'), $r)) {
            $j = Join-Path $cand 'kit.json'
            if (Test-Path -LiteralPath $j) {
                try { $k = [IO.File]::ReadAllText($j) | ConvertFrom-Json -ErrorAction Stop; $found += @{ Dir = $cand; Info = $k } } catch { }
            }
        }
    }
    $seen = @{}
    return @($found | Where-Object { if ($seen.ContainsKey($_.Dir)) { $false } else { $seen[$_.Dir] = 1; $true } })
}

# Drivers do kit a instalar: "net" = so placas de rede (cabo e Wi-Fi), "all" = todos.
function Select-KitDrivers($List, [string]$Which) {
    if ($Which -eq 'net') { return @($List | Where-Object { [string]$_.Class -match '^(Net|NetService|Bluetooth)$' }) }
    return @($List)
}

# 3DP Net (3dpchip.com): programa gratuito com drivers de rede de quase todas as placas, para PCs sem internet.
# A licenca dele nao permite que o Harle o distribua, entao ele nao vai no Harle-Kit.zip do GitHub: o Harle baixa
# do site oficial no PC da pessoa, ao salvar o kit, ou acha o arquivo que a pessoa colocou na pasta do kit.
$script:Net3dpUrl  = 'https://www.3dpchip.com/3dp/chip.php?driver=dp_net'
$script:Net3dpPage = 'https://www.3dpchip.com/3dpchip/index_eng.html'

function Find-3dpNet([string[]]$Dirs) {
    foreach ($d in @($Dirs)) {
        if (-not $d -or -not (Test-Path -LiteralPath $d)) { continue }
        foreach ($sub in @($d, (Join-Path $d 'Rede'))) {
            if (-not (Test-Path -LiteralPath $sub)) { continue }
            $f = @(Get-ChildItem -LiteralPath $sub -File -Filter '*.exe' -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '(?i)3dp.?net|dp_net' } | Sort-Object LastWriteTime -Descending) | Select-Object -First 1
            if ($f) { return $f.FullName }
        }
    }
    return $null
}

$script:KitSaveCode = @'
param([string]$Dir, [bool]$Drivers, $Runtimes, [string]$Exe, [string]$Windows, [string]$Net3dp)
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$out = @()
try {
    $kit = Join-Path $Dir 'Harle-Kit'
    New-Item -ItemType Directory -Path $kit -Force | Out-Null
    $list = @()
    if ($Drivers) {
        $dd = Join-Path $kit 'Drivers'
        New-Item -ItemType Directory -Path $dd -Force | Out-Null
        foreach ($d in @(Export-WindowsDriver -Online -Destination $dd -ErrorAction Stop)) {
            $list += [ordered]@{ Folder = (Split-Path (Split-Path ([string]$d.OriginalFileName) -Parent) -Leaf); Class = [string]$d.ClassName; Provider = [string]$d.ProviderName; Version = [string]$d.Version; Date = $(try { ([datetime]$d.Date).ToString('yyyy-MM-dd') } catch { '' }) }
        }
        [IO.File]::WriteAllText((Join-Path $kit 'drivers.json'), (ConvertTo-Json @($list) -Depth 3))
        $out += "drivers|$($list.Count)"
    }
    $got = @()
    if (@($Runtimes).Count -gt 0) {
        $rd = Join-Path $kit 'Runtimes'
        New-Item -ItemType Directory -Path $rd -Force | Out-Null
        foreach ($r in @($Runtimes)) {
            $f = Join-Path $rd $r.File
            try {
                Invoke-WebRequest -Uri $r.Url -OutFile $f -UseBasicParsing -TimeoutSec 300 -ErrorAction Stop
                $sig = Get-AuthenticodeSignature -LiteralPath $f
                if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') { Remove-Item -LiteralPath $f -Force; $out += "rt|$($r.Id)|assinatura"; continue }
                $got += $r.Id; $out += "rt|$($r.Id)|ok"
            } catch { $out += "rt|$($r.Id)|$($_.Exception.Message)" }
        }
    }
    if ($Net3dp) {
        $nd = Join-Path $kit 'Rede'
        New-Item -ItemType Directory -Path $nd -Force | Out-Null
        $nf = Join-Path $nd '3DP_Net.exe'
        try {
            Invoke-WebRequest -Uri $Net3dp -OutFile $nf -UseBasicParsing -TimeoutSec 900 -MaximumRedirection 5 -Headers @{ 'User-Agent' = 'Mozilla/5.0 HarleOptimizer' } -ErrorAction Stop
            $head = [byte[]]::new(2); $fs = [IO.File]::OpenRead($nf); [void]$fs.Read($head, 0, 2); $len = $fs.Length; $fs.Dispose()
            if ($head[0] -ne 0x4D -or $head[1] -ne 0x5A -or $len -lt 20MB) { Remove-Item -LiteralPath $nf -Force; $out += 'net|erro|o site nao entregou o programa' }
            else { $out += "net|ok|$([int]($len / 1MB))" }
        } catch { Remove-Item -LiteralPath $nf -Force -ErrorAction SilentlyContinue; $out += "net|erro|$($_.Exception.Message)" }
    }
    if ($Exe -and (Test-Path -LiteralPath $Exe)) { Copy-Item -LiteralPath $Exe -Destination (Join-Path $kit 'Harle.exe') -Force }
    $info = [ordered]@{ app = 'Harle Optimizer'; created = (Get-Date).ToString('yyyy-MM-dd HH:mm'); pc = $env:COMPUTERNAME; windows = $Windows; drivers = $list.Count; runtimes = $got }
    [IO.File]::WriteAllText((Join-Path $kit 'kit.json'), ($info | ConvertTo-Json -Depth 3))
    $out += "fim|$kit"
} catch { $out += "erro|$($_.Exception.Message)" }
$out
'@

$script:KitDriverCode = @'
param([string]$Kit, [string[]]$Folders)
$out = @()
$dd = Join-Path $Kit 'Drivers'
$ok = 0; $bad = 0; $reboot = $false
foreach ($f in @($Folders)) {
    $p = Join-Path $dd $f
    if (-not (Test-Path -LiteralPath $p)) { $bad++; continue }
    $r = & pnputil.exe /add-driver (Join-Path $p '*.inf') /subdirs /install 2>&1
    if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 3010) { $ok++; if ($LASTEXITCODE -eq 3010) { $reboot = $true } } else { $bad++; $out += "falha|$f|$LASTEXITCODE" }
}
$out += "fim|$ok|$bad|$reboot"
$out
'@

$script:RuntimeInstallCode = "param(`$Items, [string]`$Kit)`n" + $script:WuHelperCode + @'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$out = @()
$tmp = Join-Path ([IO.Path]::GetTempPath()) 'Harle-runtimes'
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
foreach ($r in @($Items)) {
    try {
        if ($r.Kind -eq 'feature') {
            $script:WuSt = $null
            try { $null = Open-Wu; Enable-WindowsOptionalFeature -Online -FeatureName NetFx3 -All -NoRestart -ErrorAction Stop | Out-Null } finally { Close-Wu $script:WuSt }
            $out += "ok|$($r.Id)|0"; continue
        }
        $f = $null
        if ($Kit) { $k = Join-Path (Join-Path $Kit 'Runtimes') $r.File; if (Test-Path -LiteralPath $k) { $f = $k } }
        if (-not $f) { $f = Join-Path $tmp $r.File; Invoke-WebRequest -Uri $r.Url -OutFile $f -UseBasicParsing -TimeoutSec 300 -ErrorAction Stop }
        $sig = Get-AuthenticodeSignature -LiteralPath $f
        if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') { $out += "erro|$($r.Id)|assinatura"; continue }
        if ($r.Kind -eq 'dx') {
            $x = Join-Path $tmp 'dx'
            New-Item -ItemType Directory -Path $x -Force | Out-Null
            $p = Start-Process -FilePath $f -ArgumentList "/Q /T:`"$x`"" -Wait -PassThru
            $p = Start-Process -FilePath (Join-Path $x 'DXSETUP.exe') -ArgumentList '/silent' -Wait -PassThru
        } else {
            $p = Start-Process -FilePath $f -ArgumentList $r.Args -Wait -PassThru
        }
        $code = $p.ExitCode
        if (@(0, 1638, 3010, 1641) -contains $code) { $out += "ok|$($r.Id)|$code" } else { $out += "erro|$($r.Id)|codigo $code" }
    } catch { $out += "erro|$($r.Id)|$($_.Exception.Message)" }
}
Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
$out
'@

# ---------------------------------------------------------------------------
#  Autoteste dos dados (roda sem interface): powershell -File Harle.ps1 -SelfTest
# ---------------------------------------------------------------------------
if ($SelfTest -or $env:HARLE_SELFTEST) {
    $errors = @()
    $ids = @{}
    foreach ($t in $script:Tweaks) {
        if ($ids.ContainsKey($t.Id)) { $errors += "Id repetido: $($t.Id)" }
        $ids[$t.Id] = $true
        foreach ($f in 'Id', 'Cat', 'Name', 'Desc', 'Impact') { if (-not $t[$f]) { $errors += "$($t.Id): falta $f" } }
        if ('Alto', 'Médio', 'Baixo' -notcontains $t.Impact) { $errors += "$($t.Id): impacto invalido" }
        if ('fps', 'gpu', 'reg', 'debloat', 'priv', 'net', 'qol', 'clean', 'keep', 'opt' -notcontains $t.Cat) { $errors += "$($t.Id): categoria invalida" }
        if (-not ($t.Reg -or $t.RegDyn -or $t.Run -or ($t.Apply -and $t.Revert -and $t.Test))) { $errors += "$($t.Id): sem acao" }
        foreach ($e in @($t.Reg)) {
            if ($null -eq $e) { continue }
            if ($e.P -notmatch '^(HKLM|HKCU)\\.+') { $errors += "$($t.Id): caminho invalido $($e.P)" }
            if (-not $e.N) { $errors += "$($t.Id): entrada sem nome" }
            if (-not $e.Del) {
                if ('DWord', 'String' -notcontains $e.T) { $errors += "$($t.Id): tipo invalido em $($e.N)" }
                if (-not $e.ContainsKey('V')) { $errors += "$($t.Id): sem valor em $($e.N)" }
            }
        }
    }
    "Ajustes: $($script:Tweaks.Count)  (reversiveis: $(@($script:Tweaks | Where-Object { -not $_.Run }).Count), acoes: $(@($script:Tweaks | Where-Object { $_.Run }).Count))"
    Get-RegFileText $script:Tweaks $false
    '--- desfazer ---'
    Get-RegFileText $script:Tweaks $true
    if ($errors.Count) { $errors | ForEach-Object { "ERRO: $_" } } else { 'OK' }
    return
}

# ---------------------------------------------------------------------------
#  Elevacao
# ---------------------------------------------------------------------------
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin  = ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# Modo silencioso (tarefa do login): sem janela.
if ($env:HARLE_ARGS -match '(?i)/reaplicar') {
    if ($isAdmin) { Initialize-State; [void](Invoke-Reapply) } else { Write-Log 'Checagem do login sem permissao de administrador' }
    return
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
if (-not $isAdmin) {
    $relaunched = $false
    if (-not $script:Hosted -and -not $Elevated -and $PSCommandPath) {
        try {
            Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Elevated"
            $relaunched = $true
        } catch { }
    }
    if (-not $relaunched) {
        Set-Lang $(if ([Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName -eq 'pt') { 'pt' } else { 'en' })
        [void][System.Windows.MessageBox]::Show((Tr 'O Harle precisa abrir como administrador para ajustar o Windows. Abra de novo e aceite o pedido do Windows.'), 'Harle Optimizer', 'OK', 'Warning')
    }
    return
}

Initialize-State
$savedLang = [string]$script:Backup.state['lang']
if ($savedLang -ne 'pt' -and $savedLang -ne 'en') { $savedLang = if ([Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName -eq 'pt') { 'pt' } else { 'en' } }
Set-Lang $savedLang

# ---------------------------------------------------------------------------
#  Interface
# ---------------------------------------------------------------------------
$Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Harle Optimizer" Width="1172" Height="760" WindowStartupLocation="CenterScreen"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent" ResizeMode="CanMinimize"
        FontFamily="Segoe UI" FontSize="13" UseLayoutRounding="True" SnapsToDevicePixels="True">
  <Window.Resources>
    <SolidColorBrush x:Key="Bg" Color="#141922"/>
    <SolidColorBrush x:Key="Rail" Color="#0F131A"/>
    <SolidColorBrush x:Key="Panel" Color="#1B222E"/>
    <SolidColorBrush x:Key="PanelHi" Color="#232C3B"/>
    <SolidColorBrush x:Key="Line" Color="#2B3547"/>
    <SolidColorBrush x:Key="Text" Color="#E9EDF4"/>
    <SolidColorBrush x:Key="Muted" Color="#8F9BB0"/>
    <SolidColorBrush x:Key="Amber" Color="#62BFFF"/>
    <SolidColorBrush x:Key="Red" Color="#9D8CFF"/>
    <SolidColorBrush x:Key="Ice" Color="#6FE3C8"/>
    <SolidColorBrush x:Key="Ink" Color="#05101E"/>
    <SolidColorBrush x:Key="Bad" Color="#FF8A7A"/>
    <LinearGradientBrush x:Key="Heat" StartPoint="0,0" EndPoint="1,0">
      <GradientStop Color="#6FD0FF" Offset="0"/>
      <GradientStop Color="#3D8BFF" Offset="1"/>
    </LinearGradientBrush>

    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="{StaticResource Panel}"/>
      <Setter Property="CornerRadius" Value="12"/>
      <Setter Property="Padding" Value="20,16"/>
    </Style>
    <Style x:Key="Label" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Muted}"/>
      <Setter Property="FontSize" Value="12"/>
    </Style>
    <Style x:Key="Stat" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="FontFamily" Value="Bahnschrift, Segoe UI"/>
      <Setter Property="FontSize" Value="17"/>
      <Setter Property="Margin" Value="0,5,0,0"/>
      <Setter Property="TextTrimming" Value="CharacterEllipsis"/>
    </Style>

    <Style x:Key="Primary" TargetType="Button">
      <Setter Property="Foreground" Value="{StaticResource Ink}"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="FontSize" Value="14.5"/>
      <Setter Property="Padding" Value="18,13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" CornerRadius="10" Background="{StaticResource Heat}" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Opacity" Value="0.9"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="B" Property="Opacity" Value="0.78"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="B" Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Ghost" TargetType="Button">
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Padding" Value="16,8"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" CornerRadius="9" Background="Transparent" BorderBrush="{StaticResource Line}" BorderThickness="1" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Background" Value="{StaticResource PanelHi}"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="B" Property="Background" Value="{StaticResource Line}"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="B" Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Chrome" TargetType="Button">
      <Setter Property="Foreground" Value="{StaticResource Muted}"/>
      <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/>
      <Setter Property="FontSize" Value="10"/>
      <Setter Property="Width" Value="42"/>
      <Setter Property="Height" Value="30"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" CornerRadius="7" Background="Transparent">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="B" Property="Background" Value="{StaticResource PanelHi}"/>
                <Setter Property="Foreground" Value="{StaticResource Text}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Nav" TargetType="RadioButton">
      <Setter Property="Foreground" Value="{StaticResource Muted}"/>
      <Setter Property="FontSize" Value="13.5"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="12,1"/>
      <Setter Property="GroupName" Value="Nav"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="B" CornerRadius="9" Background="Transparent" Padding="12,7">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="28"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <TextBlock Text="{Binding Tag, RelativeSource={RelativeSource TemplatedParent}}" FontFamily="Segoe MDL2 Assets" FontSize="15" VerticalAlignment="Center"/>
                <ContentPresenter Grid.Column="1" VerticalAlignment="Center"/>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="B" Property="Background" Value="#171D27"/>
                <Setter Property="Foreground" Value="{StaticResource Text}"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="B" Property="Background" Value="{StaticResource Panel}"/>
                <Setter Property="Foreground" Value="{StaticResource Amber}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Seg" TargetType="RadioButton">
      <Setter Property="Foreground" Value="{StaticResource Muted}"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="6,0,0,0"/>
      <Setter Property="Padding" Value="13,5"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="B" CornerRadius="8" Background="Transparent" BorderBrush="{StaticResource Line}" BorderThickness="1" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="B" Property="Background" Value="{StaticResource PanelHi}"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="B" Property="Background" Value="{StaticResource Heat}"/>
                <Setter TargetName="B" Property="BorderBrush" Value="Transparent"/>
                <Setter Property="Foreground" Value="{StaticResource Ink}"/>
                <Setter Property="FontWeight" Value="SemiBold"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="B" Property="Opacity" Value="0.5"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Switch" TargetType="CheckBox">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Border x:Name="Track" Width="46" Height="26" CornerRadius="13" Background="{StaticResource Line}">
              <Ellipse x:Name="Knob" Width="18" Height="18" Margin="4,0" HorizontalAlignment="Left" Fill="{StaticResource Muted}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Track" Property="Background" Value="{StaticResource Heat}"/>
                <Setter TargetName="Knob" Property="HorizontalAlignment" Value="Right"/>
                <Setter TargetName="Knob" Property="Fill" Value="{StaticResource Ink}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Track" Property="Opacity" Value="0.4"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Search" TargetType="TextBox">
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="CaretBrush" Value="{StaticResource Text}"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Height" Value="34"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="B" CornerRadius="9" Background="{StaticResource Panel}" BorderBrush="{StaticResource Line}" BorderThickness="1" Padding="11,0,10,0">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="Auto"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <TextBlock Text="&#xE721;" FontFamily="Segoe MDL2 Assets" FontSize="13" Foreground="{StaticResource Muted}" VerticalAlignment="Center" Margin="0,0,9,0"/>
                <TextBlock x:Name="Hint" Grid.Column="1" Text="{Binding Tag, RelativeSource={RelativeSource TemplatedParent}}" Foreground="{StaticResource Muted}" VerticalAlignment="Center" Margin="2,0,0,0" Visibility="Collapsed" IsHitTestVisible="False"/>
                <ScrollViewer x:Name="PART_ContentHost" Grid.Column="1" VerticalAlignment="Center"/>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="Text" Value="">
                <Setter TargetName="Hint" Property="Visibility" Value="Visible"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="B" Property="BorderBrush" Value="{StaticResource Amber}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ToolTip">
      <Setter Property="Background" Value="{StaticResource PanelHi}"/>
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="11,8"/>
      <Setter Property="FontSize" Value="12"/>
    </Style>

    <Style x:Key="ScrollThumb" TargetType="Thumb">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Thumb">
            <Border CornerRadius="3" Background="{StaticResource Line}"/>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="6"/>
      <Setter Property="MinWidth" Value="6"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent">
              <Track x:Name="PART_Track" IsDirectionReversed="True">
                <Track.Thumb>
                  <Thumb Style="{StaticResource ScrollThumb}"/>
                </Track.Thumb>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Border Margin="16" CornerRadius="14" Background="{StaticResource Bg}" BorderBrush="{StaticResource Line}" BorderThickness="1">
    <Border.Effect>
      <DropShadowEffect BlurRadius="22" ShadowDepth="0" Opacity="0.5" Color="#000000"/>
    </Border.Effect>
    <Grid>
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="212"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <!-- Trilho lateral -->
      <Border x:Name="RailArea" Background="{StaticResource Rail}" CornerRadius="13,0,0,13">
        <DockPanel LastChildFill="True">
          <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="24,22,0,16">
            <Border x:Name="LogoBox" Width="34" Height="34" CornerRadius="9" Background="{StaticResource Heat}">
              <Viewbox x:Name="LogoMark" Width="28" Height="28">
                <Canvas Width="64" Height="64">
                  <Path Data="M32,4 C38,13 42.5,21 42.5,28 L32,45 L21.5,28 C21.5,21 26,13 32,4 Z M30.3,43 L33.7,43 L33.7,60 L30.3,60 Z M20,29 C14,19 7,18 3,23 C8,24 12,27 16.5,34 Z M18.5,36 C13,31 8,31.5 5.5,35.5 C9.5,36 13,38 17.5,42 Z M44,29 C50,19 57,18 61,23 C56,24 52,27 47.5,34 Z M45.5,36 C51,31 56,31.5 58.5,35.5 C54.5,36 51,38 46.5,42 Z" Fill="{StaticResource Ink}"/>
                </Canvas>
              </Viewbox>
            </Border>
            <StackPanel Margin="12,0,0,0" VerticalAlignment="Center">
              <TextBlock Text="Harle" FontFamily="Bahnschrift, Segoe UI" FontSize="21" FontWeight="SemiBold" Foreground="{StaticResource Text}"/>
              <TextBlock Text="Optimizer" FontSize="11.5" Foreground="{StaticResource Muted}" Margin="1,-2,0,0"/>
            </StackPanel>
          </StackPanel>

          <StackPanel DockPanel.Dock="Bottom" Margin="24,0,20,22">
            <TextBlock x:Name="VersionText" FontSize="11.5" Foreground="#5F6B80"/>
          </StackPanel>

          <ScrollViewer VerticalScrollBarVisibility="Hidden" HorizontalScrollBarVisibility="Disabled" Focusable="False">
          <StackPanel>
            <RadioButton x:Name="NavHome" Style="{StaticResource Nav}" Tag="&#xE80F;" Content="Início" IsChecked="True"/>
            <RadioButton x:Name="NavTune" Style="{StaticResource Nav}" Tag="&#xE945;" Content="Otimizar"/>
            <RadioButton x:Name="NavMeasure" Style="{StaticResource Nav}" Tag="&#xE9D9;" Content="Medição"/>
            <RadioButton x:Name="NavMonitor" Style="{StaticResource Nav}" Tag="&#xE9D2;" Content="Monitor"/>
            <RadioButton x:Name="NavPlay" Style="{StaticResource Nav}" Tag="&#xE7FC;" Content="Modo partida"/>
            <RadioButton x:Name="NavGames" Style="{StaticResource Nav}" Tag="&#xE990;" Content="Jogos"/>
            <RadioButton x:Name="NavMem" Style="{StaticResource Nav}" Tag="&#xE72C;" Content="Memória"/>
            <RadioButton x:Name="NavBoot" Style="{StaticResource Nav}" Tag="&#xE7E8;" Content="Inicialização"/>
            <RadioButton x:Name="NavApps" Style="{StaticResource Nav}" Tag="&#xE71D;" Content="Apps"/>
            <RadioButton x:Name="NavDrv" Style="{StaticResource Nav}" Tag="&#xE772;" Content="Drivers"/>
            <Border Height="1" Background="{StaticResource Line}" Margin="24,6" Opacity="0.6"/>
            <RadioButton x:Name="NavScan" Style="{StaticResource Nav}" Tag="&#xE977;" Content="Scanner"/>
            <RadioButton x:Name="NavUpgrade" Style="{StaticResource Nav}" Tag="&#xE74A;" Content="Upgrade"/>
            <RadioButton x:Name="NavBios" Style="{StaticResource Nav}" Tag="&#xE950;" Content="BIOS"/>
            <RadioButton x:Name="NavHealth" Style="{StaticResource Nav}" Tag="&#xE95E;" Content="Saúde do PC"/>
            <RadioButton x:Name="NavDisks" Style="{StaticResource Nav}" Tag="&#xEDA2;" Content="Discos"/>
            <RadioButton x:Name="NavOnline" Style="{StaticResource Nav}" Tag="&#xE774;" Content="Online"/>
            <RadioButton x:Name="NavGuide" Style="{StaticResource Nav}" Tag="&#xE82D;" Content="Guia de vídeo e jogos"/>
            <RadioButton x:Name="NavAbout" Style="{StaticResource Nav}" Tag="&#xE946;" Content="Créditos"/>
            <Border Height="1" Background="{StaticResource Line}" Margin="24,6" Opacity="0.6"/>
            <RadioButton x:Name="NavAdvanced" Style="{StaticResource Nav}" Tag="&#xE7BA;" Content="AVANÇADO"/>
          </StackPanel>
          </ScrollViewer>
        </DockPanel>
      </Border>

      <!-- Area principal -->
      <Grid Grid.Column="1">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <Border x:Name="DragArea" Background="Transparent" Padding="30,14,12,18">
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <StackPanel Margin="0,12,20,0">
              <TextBlock x:Name="PageTitle" Text="Início" FontFamily="Bahnschrift, Segoe UI" FontSize="28" FontWeight="SemiBold" Foreground="{StaticResource Text}"/>
              <TextBlock x:Name="PageSub" TextWrapping="Wrap" Foreground="{StaticResource Muted}" FontSize="13" Margin="1,4,0,0"/>
            </StackPanel>
            <StackPanel Grid.Column="1">
              <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                <Button x:Name="BtnLang" Style="{StaticResource Chrome}" FontFamily="Segoe UI" FontSize="11" FontWeight="SemiBold" Content="EN" ToolTip="Mudar o idioma para inglês"/>
                <Button x:Name="BtnMin" Style="{StaticResource Chrome}" Content="&#xE921;" ToolTip="Minimizar"/>
                <Button x:Name="BtnClose" Style="{StaticResource Chrome}" Content="&#xE8BB;" ToolTip="Fechar"/>
              </StackPanel>
              <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,10,18,0" Height="36">
                <Button x:Name="BtnUpdate" Style="{StaticResource Primary}" FontSize="12.5" Padding="14,8" Margin="0,0,10,0" Visibility="Collapsed"/>
                <Button x:Name="BtnRefresh" Style="{StaticResource Ghost}" Content="Atualizar" Visibility="Collapsed"/>
              </StackPanel>
            </StackPanel>
          </Grid>
        </Border>

        <!-- Otimizar -->
        <Grid x:Name="PageHome" Grid.Row="1" Margin="30,0,30,22">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <UniformGrid Columns="4" Margin="-6,0,-6,12">
            <Border Style="{StaticResource Card}" Margin="6,0" Padding="18,13">
              <StackPanel>
                <TextBlock Text="Processador" Style="{StaticResource Label}"/>
                <TextBlock x:Name="HomeCpu" Text="..." Style="{StaticResource Stat}"/>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}" Margin="6,0" Padding="18,13">
              <StackPanel>
                <TextBlock Text="Placa de vídeo" Style="{StaticResource Label}"/>
                <TextBlock x:Name="HomeGpu" Text="..." Style="{StaticResource Stat}"/>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}" Margin="6,0" Padding="18,13">
              <StackPanel>
                <TextBlock Text="Memória" Style="{StaticResource Label}"/>
                <TextBlock x:Name="HomeRam" Text="..." Style="{StaticResource Stat}"/>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}" Margin="6,0" Padding="18,13">
              <StackPanel>
                <TextBlock Text="Armazenamento" Style="{StaticResource Label}"/>
                <TextBlock x:Name="HomeDisk" Text="..." Style="{StaticResource Stat}"/>
              </StackPanel>
            </Border>
          </UniformGrid>

          <Grid Grid.Row="1">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="318"/>
              <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <Border Style="{StaticResource Card}" Margin="0,0,12,0" Padding="24,18">
              <StackPanel VerticalAlignment="Center">
                <Grid Width="230" Height="200">
                  <Canvas x:Name="GaugeTicks" Width="230" Height="200"/>
                  <Path x:Name="GaugeTrack" Stroke="{StaticResource Line}" StrokeThickness="12" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
                  <Path x:Name="GaugeValue" Stroke="{StaticResource Heat}" StrokeThickness="12" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
                  <StackPanel VerticalAlignment="Top" HorizontalAlignment="Center" Margin="0,66,0,0">
                    <TextBlock x:Name="GaugeNumber" Text="0" FontFamily="Bahnschrift, Segoe UI" FontSize="62" FontWeight="SemiBold" Foreground="{StaticResource Text}" HorizontalAlignment="Center"/>
                    <TextBlock x:Name="GaugeLabel" Text="ajustes ativos" Foreground="{StaticResource Muted}" FontSize="12.5" HorizontalAlignment="Center" Margin="0,-4,0,0"/>
                  </StackPanel>
                </Grid>
                <UniformGrid x:Name="ProfileBar" Columns="3" Margin="-3,2,-3,0"/>
                <Button x:Name="BtnOptimize" Style="{StaticResource Primary}" Content="Aplicar perfil" Margin="0,12,0,0"/>
                <TextBlock x:Name="OptimizeNote" TextWrapping="Wrap" TextAlignment="Center" FontSize="12" LineHeight="17" Foreground="{StaticResource Muted}" Margin="0,12,0,0"/>
                <UniformGrid Columns="2" Margin="0,14,0,0">
                  <Button x:Name="BtnRevertAll" Style="{StaticResource Ghost}" Content="Reverter tudo" Padding="6,8" Margin="0,0,5,0"/>
                  <Button x:Name="BtnRestart" Style="{StaticResource Ghost}" Content="Reiniciar o PC" Padding="6,8" Margin="5,0,0,0"/>
                </UniformGrid>
                <UniformGrid Columns="2" Margin="0,8,0,0">
                  <Button x:Name="BtnCfgSave" Style="{StaticResource Ghost}" Content="Salvar config" Padding="6,8" Margin="0,0,5,0" ToolTip="Salva perfil, ajustes e apps marcados num arquivo para compartilhar"/>
                  <Button x:Name="BtnCfgLoad" Style="{StaticResource Ghost}" Content="Carregar config" Padding="6,8" Margin="5,0,0,0" ToolTip="Aplica a configuração de um arquivo salvo pelo Harle"/>
                </UniformGrid>
              </StackPanel>
            </Border>
            <Border Grid.Column="1" Style="{StaticResource Card}" Padding="24,16,24,6">
              <DockPanel>
                <Grid DockPanel.Dock="Top" Margin="0,0,0,12">
                  <TextBlock Text="Resumo dos ajustes" FontSize="15" FontWeight="SemiBold" Foreground="{StaticResource Text}" VerticalAlignment="Center"/>
                  <Button x:Name="BtnTuneAll" Style="{StaticResource Ghost}" Content="Ver todos, um por um" FontSize="12" Padding="12,5" HorizontalAlignment="Right"/>
                </Grid>
                <StackPanel x:Name="SummaryList"/>
              </DockPanel>
            </Border>
          </Grid>
        </Grid>

        <!-- Otimizar: cartoes com filtro e busca -->
        <Grid x:Name="PageTune" Grid.Row="1" Margin="30,0,14,14" Visibility="Collapsed">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <Grid Margin="0,0,16,12">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBlock x:Name="TuneCount" FontSize="12.5" Foreground="{StaticResource Muted}" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
            <TextBox x:Name="TuneSearch" Grid.Column="1" Style="{StaticResource Search}" Width="230" Tag="Buscar ajuste" Margin="14,0,0,0"/>
            <Button x:Name="BtnExport" Grid.Column="2" Style="{StaticResource Ghost}" Content="Exportar .reg" FontSize="12" Padding="12,0" Height="34" Margin="10,0,0,0"/>
          </Grid>
          <WrapPanel x:Name="TuneChips" Grid.Row="1" Margin="0,0,16,6"/>
          <ScrollViewer x:Name="StepScroll" Grid.Row="2" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
            <StackPanel x:Name="TuneGrid" Margin="-6,0,10,0"/>
          </ScrollViewer>
        </Grid>

        <!-- Medicao -->
        <ScrollViewer x:Name="PageMeasure" Grid.Row="1" Margin="30,0,14,14" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <StackPanel Margin="0,0,16,0">
            <Border Style="{StaticResource Card}" Margin="0,0,0,12">
              <StackPanel>
                <TextBlock Text="Memória e processos" FontSize="15" FontWeight="SemiBold" Foreground="{StaticResource Text}"/>
                <TextBlock TextWrapping="Wrap" FontSize="12.5" LineHeight="18.5" Foreground="{StaticResource Muted}" Margin="0,5,0,0"
                           Text="Compare com os mesmos programas abertos. O número mais fiel é o de logo depois de ligar o PC."/>
                <UniformGrid Columns="2" Margin="0,14,0,0">
                  <StackPanel Margin="0,0,12,0">
                    <TextBlock Text="Antes de otimizar" Style="{StaticResource Label}"/>
                    <TextBlock x:Name="LoadBefore" Text="..." Style="{StaticResource Stat}"/>
                    <TextBlock x:Name="LoadBeforeSub" Style="{StaticResource Label}" Margin="0,4,0,0" TextWrapping="Wrap"/>
                  </StackPanel>
                  <StackPanel>
                    <TextBlock Text="Agora" Style="{StaticResource Label}"/>
                    <TextBlock x:Name="LoadNow" Text="..." Style="{StaticResource Stat}"/>
                    <TextBlock x:Name="LoadNowSub" Style="{StaticResource Label}" Margin="0,4,0,0" TextWrapping="Wrap"/>
                  </StackPanel>
                </UniformGrid>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <Grid>
                  <TextBlock Text="FPS dentro do jogo" FontSize="15" FontWeight="SemiBold" Foreground="{StaticResource Text}" VerticalAlignment="Center"/>
                  <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                    <Button x:Name="BtnCard" Style="{StaticResource Ghost}" Content="Gerar cartão de resultado" Padding="14,8" Margin="0,0,10,0"
                            ToolTip="Imagem com o FPS de antes e depois, para postar no Discord"/>
                    <Button x:Name="BtnMeasure" Style="{StaticResource Primary}" Content="Medir por 60 segundos" FontSize="13" Padding="16,9"/>
                  </StackPanel>
                </Grid>
                <TextBlock x:Name="FpsNote" TextWrapping="Wrap" FontSize="12.5" LineHeight="18.5" Foreground="{StaticResource Muted}" Margin="0,10,0,0"/>
                <StackPanel x:Name="FpsChart" Margin="0,18,0,0" Visibility="Collapsed"/>
                <StackPanel x:Name="FpsList" Margin="0,18,0,0"/>
              </StackPanel>
            </Border>
          </StackPanel>
        </ScrollViewer>

        <!-- Modo partida -->
        <Grid x:Name="PagePlay" Grid.Row="1" Margin="30,0,30,22" Visibility="Collapsed">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="318"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>
          <Border Style="{StaticResource Card}" Margin="0,0,12,0" Padding="24,22">
            <StackPanel>
              <TextBlock x:Name="PlayTitle" Text="Modo partida desligado" FontFamily="Bahnschrift, Segoe UI" FontSize="21" Foreground="{StaticResource Text}" TextWrapping="Wrap"/>
              <TextBlock x:Name="PlayState" TextWrapping="Wrap" FontSize="12.5" LineHeight="18.5" Foreground="{StaticResource Muted}" Margin="0,8,0,0"/>
              <Button x:Name="BtnPlay" Style="{StaticResource Primary}" Content="Entrar no modo partida" Margin="0,18,0,0"/>
              <TextBlock TextWrapping="Wrap" FontSize="12" LineHeight="17" Foreground="{StaticResource Muted}" Margin="0,14,0,0"
                         Text="Deixe o Harle aberto enquanto joga. Quando o jogo fechar, o modo partida sai sozinho e reabre os programas que tinham janela."/>
            </StackPanel>
          </Border>
          <Border Grid.Column="1" Style="{StaticResource Card}" Padding="22,16,10,10">
            <DockPanel>
              <TextBlock DockPanel.Dock="Top" Text="O que fechar ao entrar" FontSize="15" FontWeight="SemiBold" Foreground="{StaticResource Text}"/>
              <TextBlock DockPanel.Dock="Top" TextWrapping="Wrap" FontSize="12.5" LineHeight="18.5" Foreground="{StaticResource Muted}" Margin="0,5,12,14"
                         Text="Só aparecem programas abertos agora. Não marque o launcher do jogo que você vai jogar."/>
              <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                <StackPanel x:Name="PlayList" Margin="0,0,14,0"/>
              </ScrollViewer>
            </DockPanel>
          </Border>
        </Grid>

        <!-- Inicializacao -->
        <ScrollViewer x:Name="PageBoot" Grid.Row="1" Margin="30,0,14,14" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <Border Style="{StaticResource Card}" Margin="0,0,16,0" Padding="22,18,22,6" VerticalAlignment="Top">
            <StackPanel x:Name="BootList"/>
          </Border>
        </ScrollViewer>

        <!-- Apps -->
        <ScrollViewer x:Name="PageApps" Grid.Row="1" Margin="30,0,14,14" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <StackPanel Margin="0,0,16,0">
            <Border Style="{StaticResource Card}" Margin="0,0,0,12">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock x:Name="AppsNote" TextWrapping="Wrap" FontSize="12.5" LineHeight="18.5" Foreground="{StaticResource Muted}" VerticalAlignment="Center"/>
                <Button x:Name="BtnAppsRemove" Grid.Column="1" Style="{StaticResource Primary}" Content="Remover os marcados" FontSize="13" Padding="16,9" Margin="20,0,0,0" VerticalAlignment="Center"/>
              </Grid>
            </Border>
            <Border x:Name="AppsRecCard" Style="{StaticResource Card}" Margin="0,0,0,12" Padding="22,18,22,6">
              <StackPanel>
                <TextBlock Text="Recomendados para remover" FontSize="15" FontWeight="SemiBold" Foreground="{StaticResource Text}" Margin="0,0,0,14"/>
                <StackPanel x:Name="AppsRecList"/>
              </StackPanel>
            </Border>
            <Border x:Name="AppsOptCard" Style="{StaticResource Card}" Padding="22,18,22,6">
              <StackPanel>
                <TextBlock Text="Opcionais: marque só o que você não usa" FontSize="15" FontWeight="SemiBold" Foreground="{StaticResource Text}" Margin="0,0,0,14"/>
                <StackPanel x:Name="AppsOptList"/>
              </StackPanel>
            </Border>
          </StackPanel>
        </ScrollViewer>

        <!-- Scanner -->
        <ScrollViewer x:Name="PageScan" Grid.Row="1" Margin="30,0,14,14" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <StackPanel Margin="0,0,4,0">
            <Border Style="{StaticResource Card}" Margin="0,0,12,12" Padding="22,18,22,6">
              <StackPanel>
                <Grid Margin="0,0,0,12">
                  <TextBlock Text="O que o scanner encontrou" FontSize="15" FontWeight="SemiBold" Foreground="{StaticResource Text}" VerticalAlignment="Center"/>
                  <Button x:Name="BtnReport" Style="{StaticResource Ghost}" Content="Copiar relatório" FontSize="12" Padding="12,5" HorizontalAlignment="Right"
                          ToolTip="Copia specs, ajustes ligados e o fim do log, prontos para colar no Discord"/>
                </Grid>
                <StackPanel x:Name="DiagList"/>
              </StackPanel>
            </Border>
            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <StackPanel x:Name="SpecColA"/>
              <StackPanel x:Name="SpecColB" Grid.Column="1"/>
            </Grid>
          </StackPanel>
        </ScrollViewer>

        <!-- Upgrade -->
        <ScrollViewer x:Name="PageUpgrade" Grid.Row="1" Margin="30,0,14,14" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <StackPanel x:Name="UpList" Margin="0,0,16,0"/>
        </ScrollViewer>

        <!-- Saude do PC -->
        <ScrollViewer x:Name="PageHealth" Grid.Row="1" Margin="30,0,14,14" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <StackPanel x:Name="HealthList" Margin="0,0,16,0"/>
        </ScrollViewer>

        <!-- Drivers -->
        <ScrollViewer x:Name="PageDrv" Grid.Row="1" Margin="30,0,14,14" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <StackPanel x:Name="DrvList" Margin="0,0,16,0"/>
        </ScrollViewer>

        <!-- Memoria -->
        <ScrollViewer x:Name="PageMem" Grid.Row="1" Margin="30,0,14,14" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <StackPanel x:Name="MemList" Margin="0,0,16,0"/>
        </ScrollViewer>

        <!-- Jogos -->
        <ScrollViewer x:Name="PageGames" Grid.Row="1" Margin="30,0,14,14" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <StackPanel x:Name="GamesList" Margin="0,0,16,0"/>
        </ScrollViewer>

        <!-- Online -->
        <ScrollViewer x:Name="PageOnline" Grid.Row="1" Margin="30,0,14,14" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <StackPanel x:Name="OnlineList" Margin="0,0,16,0"/>
        </ScrollViewer>

        <!-- Discos -->
        <ScrollViewer x:Name="PageDisks" Grid.Row="1" Margin="30,0,14,14" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <StackPanel x:Name="DiskList" Margin="0,0,16,0"/>
        </ScrollViewer>

        <!-- BIOS -->
        <ScrollViewer x:Name="PageBios" Grid.Row="1" Margin="30,0,14,14" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <StackPanel x:Name="BiosList" Margin="0,0,16,0"/>
        </ScrollViewer>

        <!-- Monitor -->
        <ScrollViewer x:Name="PageMonitor" Grid.Row="1" Margin="30,0,14,14" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <StackPanel Margin="0,0,10,0">
            <TextBlock x:Name="MonGpuTitle" Text="Placa de vídeo" FontFamily="Bahnschrift, Segoe UI" FontSize="16" Foreground="{StaticResource Text}" Margin="2,0,0,6"/>
            <UniformGrid Columns="4" Margin="-6,0">
              <Border Style="{StaticResource Card}" Margin="6" Padding="18,14">
                <StackPanel>
                  <TextBlock Text="Temperatura" Style="{StaticResource Label}"/>
                  <TextBlock x:Name="MonGpuTemp" Text="..." Style="{StaticResource Stat}" FontSize="22"/>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource Card}" Margin="6" Padding="18,14">
                <StackPanel>
                  <TextBlock Text="Uso" Style="{StaticResource Label}"/>
                  <TextBlock x:Name="MonGpuUse" Text="..." Style="{StaticResource Stat}" FontSize="22"/>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource Card}" Margin="6" Padding="18,14">
                <StackPanel>
                  <TextBlock Text="Memória de vídeo" Style="{StaticResource Label}"/>
                  <TextBlock x:Name="MonVram" Text="..." Style="{StaticResource Stat}" FontSize="22"/>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource Card}" Margin="6" Padding="18,14">
                <StackPanel>
                  <TextBlock Text="Ventoinha" Style="{StaticResource Label}"/>
                  <TextBlock x:Name="MonFan" Text="..." Style="{StaticResource Stat}" FontSize="22"/>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource Card}" Margin="6" Padding="18,14">
                <StackPanel>
                  <TextBlock Text="Consumo" Style="{StaticResource Label}"/>
                  <TextBlock x:Name="MonPower" Text="..." Style="{StaticResource Stat}" FontSize="22"/>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource Card}" Margin="6" Padding="18,14">
                <StackPanel>
                  <TextBlock Text="Clock do núcleo" Style="{StaticResource Label}"/>
                  <TextBlock x:Name="MonCoreClk" Text="..." Style="{StaticResource Stat}" FontSize="22"/>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource Card}" Margin="6" Padding="18,14">
                <StackPanel>
                  <TextBlock Text="Clock da memória" Style="{StaticResource Label}"/>
                  <TextBlock x:Name="MonMemClk" Text="..." Style="{StaticResource Stat}" FontSize="22"/>
                </StackPanel>
              </Border>
            </UniformGrid>
            <TextBlock Text="Sistema" FontFamily="Bahnschrift, Segoe UI" FontSize="16" Foreground="{StaticResource Text}" Margin="2,14,0,6"/>
            <UniformGrid Columns="4" Margin="-6,0">
              <Border Style="{StaticResource Card}" Margin="6" Padding="18,14">
                <StackPanel>
                  <TextBlock Text="Uso do processador" Style="{StaticResource Label}"/>
                  <TextBlock x:Name="MonCpu" Text="..." Style="{StaticResource Stat}" FontSize="22"/>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource Card}" Margin="6" Padding="18,14">
                <StackPanel>
                  <TextBlock Text="Memória RAM" Style="{StaticResource Label}"/>
                  <TextBlock x:Name="MonRam" Text="..." Style="{StaticResource Stat}" FontSize="22"/>
                </StackPanel>
              </Border>
            </UniformGrid>
            <TextBlock Text="Durante o jogo" FontFamily="Bahnschrift, Segoe UI" FontSize="16" Foreground="{StaticResource Text}" Margin="2,14,0,6"/>
            <Border Style="{StaticResource Card}" Padding="20,16,20,4">
              <StackPanel>
                <Grid Margin="0,0,0,14">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                  </Grid.ColumnDefinitions>
                  <StackPanel VerticalAlignment="Center" Margin="0,0,18,0">
                    <TextBlock Text="Overlay no jogo" FontSize="13.5" FontWeight="SemiBold" Foreground="{StaticResource Text}"/>
                    <TextBlock x:Name="OvNote" TextWrapping="Wrap" FontSize="12" LineHeight="17.5" Foreground="{StaticResource Muted}" Margin="0,2,0,0"/>
                  </StackPanel>
                  <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center" Margin="0,0,18,0">
                    <RadioButton x:Name="OvCorner0" Style="{StaticResource Seg}" GroupName="OvCorner" Content="&#x2196;" FontSize="14" Padding="10,3" ToolTip="Canto de cima, à esquerda"/>
                    <RadioButton x:Name="OvCorner1" Style="{StaticResource Seg}" GroupName="OvCorner" Content="&#x2197;" FontSize="14" Padding="10,3" ToolTip="Canto de cima, à direita"/>
                    <RadioButton x:Name="OvCorner2" Style="{StaticResource Seg}" GroupName="OvCorner" Content="&#x2199;" FontSize="14" Padding="10,3" ToolTip="Canto de baixo, à esquerda"/>
                    <RadioButton x:Name="OvCorner3" Style="{StaticResource Seg}" GroupName="OvCorner" Content="&#x2198;" FontSize="14" Padding="10,3" ToolTip="Canto de baixo, à direita"/>
                  </StackPanel>
                  <CheckBox x:Name="OvToggle" Grid.Column="2" Style="{StaticResource Switch}" VerticalAlignment="Center"/>
                </Grid>
                <Grid Margin="0,0,0,14">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                  </Grid.ColumnDefinitions>
                  <StackPanel VerticalAlignment="Center" Margin="0,0,18,0">
                    <TextBlock Text="Alerta de temperatura" FontSize="13.5" FontWeight="SemiBold" Foreground="{StaticResource Text}"/>
                    <TextBlock x:Name="AlertNote" TextWrapping="Wrap" FontSize="12" LineHeight="17.5" Foreground="{StaticResource Muted}" Margin="0,2,0,0"/>
                  </StackPanel>
                  <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center" Margin="0,0,18,0">
                    <Button x:Name="BtnAlertDown" Style="{StaticResource Ghost}" Content="-" FontSize="15" Padding="12,2"/>
                    <TextBlock x:Name="AlertValue" Text="85 °C" FontFamily="Bahnschrift, Segoe UI" FontSize="17" Foreground="{StaticResource Text}" Width="76" TextAlignment="Center" VerticalAlignment="Center"/>
                    <Button x:Name="BtnAlertUp" Style="{StaticResource Ghost}" Content="+" FontSize="15" Padding="12,2"/>
                  </StackPanel>
                  <CheckBox x:Name="AlertToggle" Grid.Column="2" Style="{StaticResource Switch}" VerticalAlignment="Center"/>
                </Grid>
              </StackPanel>
            </Border>
            <TextBlock x:Name="MonNote" TextWrapping="Wrap" FontSize="12.5" LineHeight="18.5" Foreground="{StaticResource Muted}" Margin="2,14,0,0"/>
          </StackPanel>
        </ScrollViewer>

        <!-- Avancado: overclock -->
        <ScrollViewer x:Name="PageAdvanced" Grid.Row="1" Margin="30,0,14,14" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <StackPanel Margin="0,0,16,0">
            <Border Style="{StaticResource Card}" Margin="0,0,0,12" BorderBrush="{StaticResource Amber}" BorderThickness="1">
              <StackPanel>
                <TextBlock Text="Só mexa aqui se você sabe o que está fazendo" FontFamily="Bahnschrift, Segoe UI" FontSize="19" Foreground="{StaticResource Text}" TextWrapping="Wrap"/>
                <TextBlock TextWrapping="Wrap" FontSize="12.5" LineHeight="18.5" Foreground="{StaticResource Muted}" Margin="0,8,0,0"
                           Text="Overclock é por sua conta e risco. Clock alto demais trava o jogo, congela a imagem, mostra defeitos na tela ou reinicia o PC, e forçar a placa por muito tempo pode encurtar a vida dela. O Harle não mexe em tensão nem em ventoinha, só aceita valores dentro da faixa que o próprio driver informa e nunca reaplica sozinho: reiniciar o PC devolve a placa ao padrão de fábrica."/>
                <TextBlock TextWrapping="Wrap" FontSize="12.5" LineHeight="18.5" Foreground="{StaticResource Muted}" Margin="0,8,0,0"
                           Text="Suba aos poucos, um passo de cada vez, e teste em jogo por alguns minutos antes do próximo. Se a imagem falhar ou o jogo fechar, volte ao último valor que funcionou."/>
                <StackPanel Orientation="Horizontal" Margin="0,16,0,0">
                  <CheckBox x:Name="OcAgree" Style="{StaticResource Switch}" VerticalAlignment="Center"/>
                  <TextBlock Text="Entendo os riscos e sei o que estou fazendo" FontSize="13" FontWeight="SemiBold" Foreground="{StaticResource Text}" Margin="12,0,0,0" VerticalAlignment="Center"/>
                </StackPanel>
              </StackPanel>
            </Border>
            <Border x:Name="OcPanel" Style="{StaticResource Card}" IsEnabled="False" Opacity="0.45">
              <StackPanel>
                <TextBlock Text="Overclock da placa de vídeo" FontSize="15" FontWeight="SemiBold" Foreground="{StaticResource Text}"/>
                <TextBlock x:Name="OcInfo" TextWrapping="Wrap" FontSize="12.5" LineHeight="18.5" Foreground="{StaticResource Muted}" Margin="0,5,0,14"/>
                <Grid Margin="0,0,0,12">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                  </Grid.ColumnDefinitions>
                  <StackPanel VerticalAlignment="Center">
                    <TextBlock Text="Clock do núcleo" FontSize="13.5" FontWeight="SemiBold" Foreground="{StaticResource Text}"/>
                    <TextBlock x:Name="OcCoreLimit" FontSize="12" Foreground="{StaticResource Muted}" Margin="0,2,0,0"/>
                  </StackPanel>
                  <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                    <Button x:Name="BtnOcCoreDown" Style="{StaticResource Ghost}" Content="-" FontSize="16" Padding="14,4"/>
                    <TextBlock x:Name="OcCoreValue" Text="+0 MHz" FontFamily="Bahnschrift, Segoe UI" FontSize="20" Foreground="{StaticResource Text}" Width="130" TextAlignment="Center" VerticalAlignment="Center"/>
                    <Button x:Name="BtnOcCoreUp" Style="{StaticResource Ghost}" Content="+" FontSize="16" Padding="14,4"/>
                  </StackPanel>
                </Grid>
                <Grid Margin="0,0,0,6">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                  </Grid.ColumnDefinitions>
                  <StackPanel VerticalAlignment="Center">
                    <TextBlock Text="Clock da memória" FontSize="13.5" FontWeight="SemiBold" Foreground="{StaticResource Text}"/>
                    <TextBlock x:Name="OcMemLimit" FontSize="12" Foreground="{StaticResource Muted}" Margin="0,2,0,0"/>
                  </StackPanel>
                  <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                    <Button x:Name="BtnOcMemDown" Style="{StaticResource Ghost}" Content="-" FontSize="16" Padding="14,4"/>
                    <TextBlock x:Name="OcMemValue" Text="+0 MHz" FontFamily="Bahnschrift, Segoe UI" FontSize="20" Foreground="{StaticResource Text}" Width="130" TextAlignment="Center" VerticalAlignment="Center"/>
                    <Button x:Name="BtnOcMemUp" Style="{StaticResource Ghost}" Content="+" FontSize="16" Padding="14,4"/>
                  </StackPanel>
                </Grid>
                <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,14,0,0">
                  <Button x:Name="BtnOcReset" Style="{StaticResource Ghost}" Content="Voltar ao padrão" Padding="18,10" Margin="0,0,10,0"/>
                  <Button x:Name="BtnOcApply" Style="{StaticResource Primary}" Content="Aplicar" FontSize="13.5" Padding="26,10"/>
                </StackPanel>
                <TextBlock x:Name="OcState" TextWrapping="Wrap" FontSize="12.5" Foreground="{StaticResource Amber}" Margin="0,12,0,0"/>
              </StackPanel>
            </Border>
          </StackPanel>
        </ScrollViewer>

        <!-- Creditos -->
        <ScrollViewer x:Name="PageAbout" Grid.Row="1" Margin="30,0,14,14" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <StackPanel x:Name="AboutList" Margin="0,0,16,0"/>
        </ScrollViewer>

        <!-- Guia -->
        <ScrollViewer x:Name="PageGuide" Grid.Row="1" Margin="30,0,14,14" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <StackPanel x:Name="GuideList" Margin="0,0,16,0"/>
        </ScrollViewer>

        <Border Grid.Row="2" BorderBrush="{StaticResource Line}" BorderThickness="0,1,0,0" Padding="30,11,24,12">
          <DockPanel>
            <TextBlock DockPanel.Dock="Right" Text="Modo administrador" FontSize="12" Foreground="#5F6B80" VerticalAlignment="Center"/>
            <Ellipse Width="7" Height="7" Fill="{StaticResource Ice}" VerticalAlignment="Center"/>
            <TextBlock x:Name="StatusText" Text="Pronto." FontSize="12.5" Foreground="{StaticResource Muted}" Margin="10,0,16,0" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
          </DockPanel>
        </Border>
      </Grid>

      <!-- Aviso antes de aplicar -->
      <Border x:Name="ConfirmOverlay" Grid.Column="1" Background="#EB0F131A" CornerRadius="0,13,13,0" Visibility="Collapsed">
        <Border Style="{StaticResource Card}" Width="580" VerticalAlignment="Center" HorizontalAlignment="Center" Padding="28,24,28,22" BorderBrush="{StaticResource Line}" BorderThickness="1">
          <StackPanel>
            <TextBlock Text="Antes de aplicar" FontFamily="Bahnschrift, Segoe UI" FontSize="24" Foreground="{StaticResource Text}"/>
            <TextBlock x:Name="ConfirmIntro" TextWrapping="Wrap" FontSize="12.5" LineHeight="18.5" Foreground="{StaticResource Muted}" Margin="0,6,0,16"/>
            <StackPanel x:Name="ConfirmList"/>
            <Border BorderBrush="{StaticResource Line}" BorderThickness="0,1,0,0" Padding="0,14,0,4">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <StackPanel Margin="0,0,18,0">
                  <TextBlock Text="Reiniciar o PC sozinho ao terminar" FontSize="13.5" FontWeight="SemiBold" Foreground="{StaticResource Text}"/>
                  <TextBlock TextWrapping="Wrap" FontSize="12" LineHeight="17.5" Foreground="{StaticResource Muted}" Margin="0,2,0,0"
                             Text="Um minuto depois de aplicar, com contagem na tela e botão para cancelar. Salve o que estiver aberto antes: o reinício fecha os programas sem perguntar."/>
                </StackPanel>
                <CheckBox x:Name="AutoRestart" Grid.Column="1" Style="{StaticResource Switch}" VerticalAlignment="Center" IsChecked="True"/>
              </Grid>
            </Border>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,8,0,0">
              <Button x:Name="BtnConfirmNo" Style="{StaticResource Ghost}" Content="Cancelar" Padding="18,10" Margin="0,0,10,0"/>
              <Button x:Name="BtnConfirmYes" Style="{StaticResource Primary}" Content="Aplicar perfil" FontSize="13.5" Padding="24,10"/>
            </StackPanel>
          </StackPanel>
        </Border>
      </Border>
    </Grid>
  </Border>
</Window>
'@

$StepXaml = @'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
      xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Margin="0,0,0,13">
  <Grid.ColumnDefinitions>
    <ColumnDefinition Width="20"/>
    <ColumnDefinition Width="*"/>
    <ColumnDefinition Width="Auto"/>
  </Grid.ColumnDefinitions>
  <Ellipse x:Name="Dot" Width="8" Height="8" VerticalAlignment="Top" HorizontalAlignment="Left" Margin="0,6,0,0" Fill="{DynamicResource Line}"/>
  <StackPanel Grid.Column="1">
    <TextBlock x:Name="Title" FontSize="13.5" FontWeight="SemiBold" Foreground="{DynamicResource Text}" TextWrapping="Wrap"/>
    <TextBlock x:Name="Body" FontSize="12" LineHeight="17.5" Foreground="{DynamicResource Muted}" TextWrapping="Wrap" Margin="0,2,0,0"/>
    <TextBlock x:Name="Meta" FontSize="11.5" Foreground="{DynamicResource Ice}" TextWrapping="Wrap" Margin="0,4,0,0" Visibility="Collapsed"/>
  </StackPanel>
  <StackPanel Grid.Column="2" Margin="16,2,0,0" VerticalAlignment="Top">
    <CheckBox x:Name="Toggle" Style="{DynamicResource Switch}" HorizontalAlignment="Right" Margin="0,0,0,6" Visibility="Collapsed"/>
    <Button x:Name="Run" Style="{DynamicResource Ghost}" FontSize="12" Padding="12,5" HorizontalAlignment="Right" Margin="0,0,0,6" Visibility="Collapsed"/>
    <TextBlock x:Name="State" FontSize="11.5" Foreground="{DynamicResource Muted}" HorizontalAlignment="Right"/>
  </StackPanel>
</Grid>
'@

$SpecXaml = @'
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Style="{DynamicResource Card}" Margin="0,0,12,12">
  <StackPanel>
    <StackPanel Orientation="Horizontal">
      <Border Width="38" Height="38" CornerRadius="10" Background="{DynamicResource PanelHi}">
        <TextBlock x:Name="Icon" FontFamily="Segoe MDL2 Assets" FontSize="17" Foreground="{DynamicResource Amber}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
      </Border>
      <StackPanel Margin="14,0,0,0" VerticalAlignment="Center">
        <TextBlock x:Name="Label" FontSize="12" Foreground="{DynamicResource Muted}"/>
        <TextBlock x:Name="Value" FontFamily="Bahnschrift, Segoe UI" FontSize="17" Foreground="{DynamicResource Text}" Margin="0,2,0,0" MaxWidth="340" TextTrimming="CharacterEllipsis"/>
      </StackPanel>
    </StackPanel>
    <StackPanel x:Name="Rows" Margin="0,14,0,0"/>
  </StackPanel>
</Border>
'@

$RowXaml = @'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
      xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Margin="0,3">
  <Grid.ColumnDefinitions>
    <ColumnDefinition Width="132"/>
    <ColumnDefinition Width="*"/>
  </Grid.ColumnDefinitions>
  <TextBlock x:Name="K" FontSize="12.5" Foreground="{DynamicResource Muted}"/>
  <TextBlock x:Name="V" Grid.Column="1" FontSize="12.5" Foreground="{DynamicResource Text}" TextWrapping="Wrap"/>
</Grid>
'@

$DiagXaml = @'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
      xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Margin="0,0,0,14">
  <Grid.ColumnDefinitions>
    <ColumnDefinition Width="20"/>
    <ColumnDefinition Width="*"/>
  </Grid.ColumnDefinitions>
  <Ellipse x:Name="Dot" Width="8" Height="8" VerticalAlignment="Top" HorizontalAlignment="Left" Margin="0,6,0,0"/>
  <StackPanel Grid.Column="1">
    <TextBlock x:Name="Title" FontSize="13.5" FontWeight="SemiBold" Foreground="{DynamicResource Text}" TextWrapping="Wrap"/>
    <TextBlock x:Name="Body" FontSize="12.5" LineHeight="18.5" Foreground="{DynamicResource Muted}" TextWrapping="Wrap" Margin="0,3,0,0"/>
  </StackPanel>
</Grid>
'@

$GuideXaml = @'
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Style="{DynamicResource Card}" Margin="0,0,0,12">
  <StackPanel>
    <TextBlock x:Name="Title" FontFamily="Bahnschrift, Segoe UI" FontSize="18" Foreground="{DynamicResource Text}"/>
    <TextBlock x:Name="Intro" FontSize="12.5" LineHeight="18.5" Foreground="{DynamicResource Muted}" TextWrapping="Wrap" Margin="0,5,0,8"/>
    <StackPanel x:Name="Rows"/>
  </StackPanel>
</Border>
'@

# Cartao de um ajuste na tela Otimizar.
$TweakXaml = @'
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Background="{DynamicResource Panel}" CornerRadius="12" Padding="18,15,18,12" Margin="6">
  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <Grid>
      <StackPanel Orientation="Horizontal">
        <Border CornerRadius="6" Background="{DynamicResource PanelHi}" Padding="8,3">
          <TextBlock x:Name="Cat" FontSize="11" Foreground="{DynamicResource Muted}"/>
        </Border>
        <Border CornerRadius="6" BorderBrush="{DynamicResource Line}" BorderThickness="1" Padding="7,2" Margin="6,0,0,0">
          <TextBlock x:Name="Kind" FontSize="10" Foreground="{DynamicResource Muted}"/>
        </Border>
      </StackPanel>
      <Border x:Name="Info" HorizontalAlignment="Right" Background="Transparent" Width="24" Height="22" Cursor="Help"
              ToolTipService.InitialShowDelay="120" ToolTipService.ShowDuration="60000">
        <TextBlock Text="&#xE946;" FontFamily="Segoe MDL2 Assets" FontSize="14" Foreground="{DynamicResource Muted}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
      </Border>
    </Grid>
    <TextBlock x:Name="Title" Grid.Row="1" FontSize="14.5" FontWeight="SemiBold" Foreground="{DynamicResource Text}" TextWrapping="Wrap" Margin="0,12,0,0"/>
    <TextBlock x:Name="Body" Grid.Row="2" FontSize="12" LineHeight="17.5" Foreground="{DynamicResource Muted}" TextWrapping="Wrap" Margin="0,5,0,0"/>
    <TextBlock x:Name="Meta" Grid.Row="3" FontSize="11.5" Foreground="{DynamicResource Amber}" TextWrapping="Wrap" Margin="0,10,0,0"/>
    <Border Grid.Row="4" BorderBrush="{DynamicResource Line}" BorderThickness="0,1,0,0" Margin="0,12,0,0" Padding="0,10,0,0">
      <Grid>
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <Ellipse x:Name="D1" Width="6" Height="6" Margin="0,0,3,0" Fill="{DynamicResource Line}"/>
          <Ellipse x:Name="D2" Width="6" Height="6" Margin="0,0,3,0" Fill="{DynamicResource Line}"/>
          <Ellipse x:Name="D3" Width="6" Height="6" Fill="{DynamicResource Line}"/>
          <TextBlock x:Name="Impact" FontSize="11.5" Foreground="{DynamicResource Muted}" Margin="8,0,0,0"/>
        </StackPanel>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
          <TextBlock x:Name="State" FontSize="12" Foreground="{DynamicResource Muted}" VerticalAlignment="Center" Margin="0,0,10,0" MaxWidth="210" TextTrimming="CharacterEllipsis"/>
          <CheckBox x:Name="Toggle" Style="{DynamicResource Switch}" Visibility="Collapsed"/>
          <Button x:Name="Run" Style="{DynamicResource Ghost}" FontSize="12" Padding="14,5" Visibility="Collapsed"/>
        </StackPanel>
      </Grid>
    </Border>
  </Grid>
</Border>
'@

# Linha de uma categoria no resumo da tela Inicio.
$SumXaml = @'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
      xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Margin="0,0,0,9">
  <Grid.ColumnDefinitions>
    <ColumnDefinition Width="*"/>
    <ColumnDefinition Width="Auto"/>
    <ColumnDefinition Width="Auto"/>
  </Grid.ColumnDefinitions>
  <StackPanel VerticalAlignment="Center">
    <Grid>
      <TextBlock x:Name="Title" FontSize="13.5" FontWeight="SemiBold" Foreground="{DynamicResource Text}"/>
      <TextBlock x:Name="Count" FontSize="12" Foreground="{DynamicResource Muted}" HorizontalAlignment="Right" VerticalAlignment="Bottom"/>
    </Grid>
    <Grid Height="4" Margin="0,7,0,0">
      <Grid.ColumnDefinitions>
        <ColumnDefinition x:Name="ColOn" Width="0*"/>
        <ColumnDefinition x:Name="ColOff" Width="1*"/>
      </Grid.ColumnDefinitions>
      <Border Grid.ColumnSpan="2" CornerRadius="2" Background="{DynamicResource Line}"/>
      <Border CornerRadius="2" Background="{DynamicResource Heat}"/>
    </Grid>
  </StackPanel>
  <StackPanel x:Name="Extra" Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center" Margin="10,0,0,0"/>
  <Button x:Name="Open" Grid.Column="2" Style="{DynamicResource Ghost}" Content="Abrir" FontSize="12" Padding="12,4" Margin="14,0,0,0" VerticalAlignment="Center"/>
</Grid>
'@

# Cartao de uma recomendacao na aba Upgrade.
$UpXaml = @'
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Style="{DynamicResource Card}" Margin="0,0,0,12" Padding="22,17,22,10">
  <StackPanel>
    <StackPanel Orientation="Horizontal">
      <Border x:Name="Tag" CornerRadius="6" Padding="9,3" VerticalAlignment="Center" Background="{DynamicResource PanelHi}">
        <TextBlock x:Name="TagText" FontSize="10.5" FontWeight="SemiBold" Foreground="{DynamicResource Muted}"/>
      </Border>
      <TextBlock x:Name="Part" FontSize="12" Foreground="{DynamicResource Muted}" Margin="10,0,0,0" VerticalAlignment="Center"/>
    </StackPanel>
    <TextBlock x:Name="Title" FontFamily="Bahnschrift, Segoe UI" FontSize="18" Foreground="{DynamicResource Text}" TextWrapping="Wrap" Margin="0,10,0,0"/>
    <TextBlock x:Name="Why" FontSize="12.5" LineHeight="18.5" Foreground="{DynamicResource Muted}" TextWrapping="Wrap" Margin="0,5,0,8"/>
    <StackPanel x:Name="Rows"/>
  </StackPanel>
</Border>
'@

# Janela do overlay: fica por cima do jogo, nao recebe clique nem foco. As cores sao fixas porque ela vive fora da janela principal.
$OverlayXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Harle Overlay" WindowStyle="None" AllowsTransparency="True" Background="Transparent" ResizeMode="NoResize"
        ShowInTaskbar="False" ShowActivated="False" Topmost="True" Focusable="False" IsHitTestVisible="False"
        SizeToContent="WidthAndHeight" WindowStartupLocation="Manual" Left="12" Top="12"
        FontFamily="Segoe UI" FontSize="13" UseLayoutRounding="True" SnapsToDevicePixels="True">
  <StackPanel>
    <Border x:Name="Stats" CornerRadius="10" Background="#E00F131A" BorderBrush="#662B3547" BorderThickness="1" Padding="13,7,14,7" HorizontalAlignment="Left">
      <StackPanel Orientation="Horizontal">
        <TextBlock x:Name="Fps" Text="--" FontFamily="Bahnschrift, Segoe UI" FontSize="23" FontWeight="SemiBold" Foreground="#62BFFF" MinWidth="42" TextAlignment="Right" VerticalAlignment="Center"/>
        <TextBlock Text="FPS" FontSize="11" Foreground="#8F9BB0" Margin="5,6,0,0" VerticalAlignment="Center"/>
        <Border Width="1" Background="#2B3547" Margin="13,3,13,3"/>
        <TextBlock Text="Placa" FontSize="11" Foreground="#8F9BB0" Margin="0,4,6,0" VerticalAlignment="Center"/>
        <TextBlock x:Name="Temp" Text="--" FontFamily="Bahnschrift, Segoe UI" FontSize="17" Foreground="#E9EDF4" MinWidth="46" VerticalAlignment="Center"/>
        <TextBlock x:Name="Use" Text="--" FontFamily="Bahnschrift, Segoe UI" FontSize="17" Foreground="#E9EDF4" MinWidth="42" Margin="8,0,0,0" VerticalAlignment="Center"/>
        <Border Width="1" Background="#2B3547" Margin="11,3,13,3"/>
        <TextBlock Text="CPU" FontSize="11" Foreground="#8F9BB0" Margin="0,4,6,0" VerticalAlignment="Center"/>
        <TextBlock x:Name="Cpu" Text="--" FontFamily="Bahnschrift, Segoe UI" FontSize="17" Foreground="#E9EDF4" MinWidth="42" VerticalAlignment="Center"/>
      </StackPanel>
    </Border>
    <Border x:Name="Alert" CornerRadius="10" Background="#F0A1261C" BorderBrush="#FFFF8A7A" BorderThickness="1" Padding="14,9" Margin="0,6,0,0" HorizontalAlignment="Left" Visibility="Collapsed">
      <StackPanel Orientation="Horizontal">
        <TextBlock Text="&#xE7BA;" FontFamily="Segoe MDL2 Assets" FontSize="16" Foreground="#FFFFFF" VerticalAlignment="Center" Margin="0,0,10,0"/>
        <TextBlock x:Name="AlertText" FontSize="14" FontWeight="SemiBold" Foreground="#FFFFFF" VerticalAlignment="Center"/>
      </StackPanel>
    </Border>
  </StackPanel>
</Window>
'@

# Cartao de resultado: desenhado fora da tela e salvo como imagem de 1200 x 630.
$CardXaml = @'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
      xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
      Width="1200" Height="630" TextElement.FontFamily="Segoe UI" UseLayoutRounding="True" SnapsToDevicePixels="True">
  <Grid.Background>
    <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
      <GradientStop Color="#0B1220" Offset="0"/>
      <GradientStop Color="#141922" Offset="0.55"/>
      <GradientStop Color="#0F1B33" Offset="1"/>
    </LinearGradientBrush>
  </Grid.Background>
  <Ellipse Width="900" Height="900" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,-420,-300,0">
    <Ellipse.Fill>
      <RadialGradientBrush>
        <GradientStop Color="#553D8BFF" Offset="0"/>
        <GradientStop Color="#003D8BFF" Offset="1"/>
      </RadialGradientBrush>
    </Ellipse.Fill>
  </Ellipse>
  <Border Height="6" VerticalAlignment="Top">
    <Border.Background>
      <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
        <GradientStop Color="#6FD0FF" Offset="0"/>
        <GradientStop Color="#3D8BFF" Offset="1"/>
      </LinearGradientBrush>
    </Border.Background>
  </Border>
  <Grid Margin="64,54,64,44">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <Grid>
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <Border x:Name="Logo" Width="92" Height="92" CornerRadius="22">
        <Border.Background>
          <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
            <GradientStop Color="#6FD0FF" Offset="0"/>
            <GradientStop Color="#3D8BFF" Offset="1"/>
          </LinearGradientBrush>
        </Border.Background>
        <Viewbox x:Name="LogoMark" Width="72" Height="72">
          <Canvas Width="64" Height="64">
            <Path Data="M32,4 C38,13 42.5,21 42.5,28 L32,45 L21.5,28 C21.5,21 26,13 32,4 Z M30.3,43 L33.7,43 L33.7,60 L30.3,60 Z M20,29 C14,19 7,18 3,23 C8,24 12,27 16.5,34 Z M18.5,36 C13,31 8,31.5 5.5,35.5 C9.5,36 13,38 17.5,42 Z M44,29 C50,19 57,18 61,23 C56,24 52,27 47.5,34 Z M45.5,36 C51,31 56,31.5 58.5,35.5 C54.5,36 51,38 46.5,42 Z" Fill="#05101E"/>
          </Canvas>
        </Viewbox>
      </Border>
      <StackPanel Grid.Column="1" Margin="24,0,0,0" VerticalAlignment="Center">
        <TextBlock Text="Harle Optimizer" FontFamily="Bahnschrift, Segoe UI" FontSize="40" FontWeight="SemiBold" Foreground="#E9EDF4"/>
        <TextBlock Text="FPS medido dentro do jogo, antes e depois" FontSize="19" Foreground="#8F9BB0" Margin="2,2,0,0"/>
      </StackPanel>
      <StackPanel Grid.Column="2" VerticalAlignment="Center">
        <TextBlock Text="JOGO" FontSize="14" Foreground="#8F9BB0" HorizontalAlignment="Right"/>
        <TextBlock x:Name="Game" FontFamily="Bahnschrift, Segoe UI" FontSize="28" Foreground="#E9EDF4" HorizontalAlignment="Right" MaxWidth="420" TextTrimming="CharacterEllipsis" Margin="0,2,0,0"/>
      </StackPanel>
    </Grid>

    <Grid Grid.Row="1" VerticalAlignment="Center">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>
      <Border CornerRadius="22" Background="#CC1B222E" BorderBrush="#2B3547" BorderThickness="1" Padding="34,24,34,26">
        <StackPanel>
          <TextBlock x:Name="BeforeLabel" Text="ANTES" FontSize="16" Foreground="#8F9BB0"/>
          <StackPanel Orientation="Horizontal" Margin="0,4,0,0">
            <TextBlock x:Name="BeforeAvg" FontFamily="Bahnschrift, Segoe UI" FontSize="104" FontWeight="SemiBold" Foreground="#AEB8C9"/>
            <TextBlock Text="FPS" FontSize="24" Foreground="#8F9BB0" Margin="12,0,0,20" VerticalAlignment="Bottom"/>
          </StackPanel>
          <TextBlock x:Name="BeforeLow" FontSize="21" Foreground="#8F9BB0" Margin="2,-4,0,0"/>
        </StackPanel>
      </Border>
      <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="26,0">
        <Border CornerRadius="18" Padding="20,10" HorizontalAlignment="Center">
          <Border.Background>
            <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
              <GradientStop Color="#6FD0FF" Offset="0"/>
              <GradientStop Color="#3D8BFF" Offset="1"/>
            </LinearGradientBrush>
          </Border.Background>
          <TextBlock x:Name="Gain" FontFamily="Bahnschrift, Segoe UI" FontSize="34" FontWeight="SemiBold" Foreground="#05101E"/>
        </Border>
        <TextBlock Text="na média" FontSize="16" Foreground="#8F9BB0" HorizontalAlignment="Center" Margin="0,8,0,0"/>
      </StackPanel>
      <Border Grid.Column="2" CornerRadius="22" Background="#CC1B222E" BorderBrush="#62BFFF" BorderThickness="2" Padding="34,24,34,26">
        <StackPanel>
          <TextBlock x:Name="AfterLabel" Text="DEPOIS" FontSize="16" Foreground="#62BFFF"/>
          <StackPanel Orientation="Horizontal" Margin="0,4,0,0">
            <TextBlock x:Name="AfterAvg" FontFamily="Bahnschrift, Segoe UI" FontSize="104" FontWeight="SemiBold" Foreground="#FFFFFF"/>
            <TextBlock Text="FPS" FontSize="24" Foreground="#8F9BB0" Margin="12,0,0,20" VerticalAlignment="Bottom"/>
          </StackPanel>
          <TextBlock x:Name="AfterLow" FontSize="21" Foreground="#E9EDF4" Margin="2,-4,0,0"/>
        </StackPanel>
      </Border>
    </Grid>

    <Grid Grid.Row="2">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <StackPanel VerticalAlignment="Bottom">
        <TextBlock x:Name="Pc" FontSize="19" Foreground="#E9EDF4" TextTrimming="CharacterEllipsis"/>
        <TextBlock x:Name="How" FontSize="15" Foreground="#8F9BB0" Margin="0,5,0,0" TextTrimming="CharacterEllipsis"/>
      </StackPanel>
      <TextBlock x:Name="Link" Grid.Column="1" FontFamily="Bahnschrift, Segoe UI" FontSize="21" Foreground="#62BFFF" VerticalAlignment="Bottom" Margin="24,0,0,0"/>
    </Grid>
  </Grid>
</Grid>
'@

# ----- Ingles: cada texto que aparece na tela passa pelo dicionario. Em portugues nada disso roda. -----
$script:TrHooked = New-Object 'System.Collections.Generic.HashSet[object]'
$script:TrTextDesc = $null; $script:TrContentDesc = $null; $script:TrTipDesc = $null
$script:TrTextHandler    = [EventHandler]{ param($s, $e) try { $v = $s.Text; $t = Tr $v; if ($t -cne $v) { $s.Text = $t } } catch { } }
$script:TrContentHandler = [EventHandler]{ param($s, $e) try { $v = $s.Content; if ($v -is [string]) { $t = Tr $v; if ($t -cne $v) { $s.Content = $t } } } catch { } }
$script:TrTipHandler     = [EventHandler]{ param($s, $e) try { $v = $s.ToolTip; if ($v -is [string]) { $t = Tr $v; if ($t -cne $v) { $s.ToolTip = $t } } } catch { } }

function Register-Tr($Node) {
    if ($script:Lang -ne 'en' -or $null -eq $Node -or -not ($Node -is [System.Windows.DependencyObject])) { return }
    if (-not $script:TrTextDesc) {
        $script:TrTextDesc    = [System.ComponentModel.DependencyPropertyDescriptor]::FromProperty([System.Windows.Controls.TextBlock]::TextProperty, [System.Windows.Controls.TextBlock])
        $script:TrContentDesc = [System.ComponentModel.DependencyPropertyDescriptor]::FromProperty([System.Windows.Controls.ContentControl]::ContentProperty, [System.Windows.Controls.ContentControl])
        $script:TrTipDesc     = [System.ComponentModel.DependencyPropertyDescriptor]::FromProperty([System.Windows.FrameworkElement]::ToolTipProperty, [System.Windows.FrameworkElement])
    }
    if ($script:TrHooked.Add($Node)) {
        if ($Node -is [System.Windows.Controls.TextBlock]) {
            $script:TrTextDesc.AddValueChanged($Node, $script:TrTextHandler)
            $script:TrTextHandler.Invoke($Node, [EventArgs]::Empty)
        } elseif ($Node -is [System.Windows.Controls.ContentControl]) {
            $script:TrContentDesc.AddValueChanged($Node, $script:TrContentHandler)
            $script:TrContentHandler.Invoke($Node, [EventArgs]::Empty)
        }
        if ($Node -is [System.Windows.FrameworkElement]) {
            $script:TrTipDesc.AddValueChanged($Node, $script:TrTipHandler)
            $script:TrTipHandler.Invoke($Node, [EventArgs]::Empty)
        }
        if ($Node -is [System.Windows.Controls.TextBox] -and $Node.Tag -is [string]) { $Node.Tag = Tr $Node.Tag }
    }
    foreach ($c in @([System.Windows.LogicalTreeHelper]::GetChildren($Node))) { Register-Tr $c }
}

function New-Xaml([string]$Text) {
    $o = [Windows.Markup.XamlReader]::Parse($Text)
    if ($script:Lang -eq 'en') { Register-Tr $o }
    return $o
}

$script:Window = New-Xaml $Xaml
$script:ui = @{}
foreach ($m in [regex]::Matches($Xaml, 'x:Name="(\w+)"')) {
    $n = $m.Groups[1].Value
    $o = $script:Window.FindName($n)
    if ($o) { $script:ui[$n] = $o }
}
$script:ui.VersionText.Text = (Tx 'Versão {0}' ($($script:AppVersion)))

# Em telas pequenas ou com escala alta, encolhe a janela inteira para caber.
try {
    $wa = [System.Windows.SystemParameters]::WorkArea
    $fit = [Math]::Min(($wa.Width - 8) / $script:Window.Width, ($wa.Height - 8) / $script:Window.Height)
    if ($fit -lt 1) {
        $script:Window.Content.LayoutTransform = New-Object System.Windows.Media.ScaleTransform $fit, $fit
        $script:Window.Width  = [Math]::Floor($script:Window.Width * $fit)
        $script:Window.Height = [Math]::Floor($script:Window.Height * $fit)
    }
} catch { }

$script:Pages = @{
    home  = @{ Title = 'Início'; Sub = 'Escolha um perfil e aplique tudo de uma vez, ou abra uma categoria para ligar ajuste por ajuste. O Harle guarda os valores originais de tudo o que muda.' }
    tune  = @{ Title = 'Otimizar'; Sub = 'Cada ajuste tem o próprio botão. Passe o mouse no (i) do cartão para ver exatamente o que ele muda; desligar devolve o valor original.' }
    measure = @{ Title = 'Medição'; Sub = 'A prova do que mudou: memória, processos e FPS medido dentro do jogo.' }
    monitor = @{ Title = 'Monitor'; Sub = 'Temperatura, uso e clocks da placa de vídeo, mais processador e memória, atualizados a cada segundo. Overlay e alerta de temperatura ficam no fim da tela.' }
    advanced = @{ Title = 'AVANÇADO'; Sub = 'Overclock da placa de vídeo. Só mexa aqui se você sabe o que está fazendo.' }
    play  = @{ Title = 'Modo partida'; Sub = 'Fecha o que pesa só enquanto você joga, e devolve depois.' }
    apps  = @{ Title = 'Apps'; Sub = 'Escolha quais apps que vêm com o Windows saem do PC. Só aparecem os que estão instalados agora.' }
    boot  = @{ Title = 'Inicialização'; Sub = 'O que abre junto com o Windows. Desligar aqui é o mesmo que desligar no Gerenciador de Tarefas, e dá para religar quando quiser.' }
    upgrade = @{ Title = 'Upgrade'; Sub = 'O que vale trocar neste PC, na ordem em que rende mais, com base no hardware que o scanner encontrou.' }
    scan  = @{ Title = 'Scanner';  Sub = 'O hardware e o sistema que o Harle encontrou neste PC.' }
    guide = @{ Title = 'Guia de vídeo e jogos'; Sub = 'As configurações do driver de vídeo e de dentro dos jogos que mais pesam no FPS.' }
    drv = @{ Title = 'Drivers'; Sub = 'Para depois de formatar: kit no pendrive com os drivers deste PC, runtimes para jogos, drivers do Windows Update e os sites oficiais de vídeo e chipset.' }
    mem = @{ Title = 'Memória'; Sub = 'Limpeza de RAM: cache do Windows, lista modificada e memória dos programas, na hora ou automática.' }
    games = @{ Title = 'Jogos'; Sub = 'Ajustes por jogo: modo partida automático, prioridade alta e placa de vídeo dedicada.' }
    online = @{ Title = 'Online'; Sub = 'Ping e estabilidade até os data centers dos jogos, DNS mais rápido e overlays que pesam no jogo.' }
    disks = @{ Title = 'Discos'; Sub = 'Saúde, temperatura e atributos S.M.A.R.T. de cada disco, como no CrystalDiskInfo. Só leitura: nada é alterado.' }
    health = @{ Title = 'Saúde do PC'; Sub = 'Erros de hardware, telas azuis, travamentos do driver de vídeo, discos e bateria, pelo que o próprio Windows registrou.' }
    bios  = @{ Title = 'BIOS'; Sub = 'Os ajustes que mais rendem e que só você pode fazer. O Harle confere pelo Windows o que já está ligado e mostra onde fica cada opção na sua placa-mãe.' }
    about = @{ Title = 'Créditos'; Sub = 'Quem fez o Harle e de quem são as peças que ele usa.' }
}
$script:Rows  = @{}
$script:Specs = $null
$script:RestartPending = $false
$script:Page = 'home'
$script:OcWanted = @{ Core = 0; Mem = 0 }

function Update-Ui([string]$Priority = 'Render') {
    try { $script:Window.Dispatcher.Invoke([Action] { }, [System.Windows.Threading.DispatcherPriority]$Priority) } catch { }
}

function Set-Status([string]$Text) {
    $script:ui.StatusText.Text = $Text
    Update-Ui
}

function Show-Error($Err) {
    $msg = if ($Err.Exception) { $Err.Exception.Message } else { [string]$Err }
    Write-Log "ERRO: $msg"
    Set-Status (Tx 'Algo falhou: {0}' $msg)
}

# ----- Lista do que o Harle ajusta -----
# Anota RAM e processos de antes do primeiro ajuste, para a tela Medicao comparar.
function Save-Baseline {
    if (-not $script:Backup.state['baseline']) { try { $script:Backup.state['baseline'] = Get-Load } catch { } }
}

function Sync-Row($t) {
    $r = $script:Rows[$t.Id]
    $on = $false
    if ($t.Run) {
        $res = $script:RunResult[$t.Id]
        if ($res) { $r.State.Text = [string]$res; $on = $true } else { $r.State.Text = '' }
    } elseif (-not (Test-Supported $t)) {
        $r.Toggle.IsChecked = $false
        $r.Toggle.IsEnabled = $false
        $r.State.Text = if ($t.Gpu -and -not $script:Hosted) { 'Só no Harle.exe' } elseif ($t.Gpu -and $script:GpuChoice -ne $t.Gpu) { 'Outra marca escolhida' } elseif ($t.Gpu) { 'Driver não encontrado' } elseif ($t.ExeOnly -and -not $script:Hosted) { 'Só no Harle.exe' } elseif ($t.MaxBuild) { 'Só no Windows 10' } elseif ($t.MinBuild -ge 26100) { 'Pede Windows 11 24H2' } elseif ($t.MinBuild -gt 22000) { 'Pede Windows 11 23H2' } else { 'Só no Windows 11' }
    } else {
        $on = Get-TweakState $t
        $r.Toggle.IsEnabled = -not $script:Busy
        $r.Toggle.IsChecked = $on
        $r.State.Text = if ($on) { 'Ligado' } else { 'Desligado' }
    }
    $r.State.Foreground = $script:Window.FindResource($(if ($on) { 'Amber' } else { 'Muted' }))
}

$script:GpuRadios = @{}
$script:LogoBrush = $null

# Troca a marca da placa de video. O perfil da marca que saiu e desfeito, se estava ativo.
function Set-GpuChoice([string]$Choice) {
    if ($Choice -eq $script:GpuChoice) { return }
    if ($script:Busy) { $script:GpuRadios[$script:GpuChoice].IsChecked = $true; return }
    $profiles = @($script:Tweaks | Where-Object { $_.Gpu })
    foreach ($t in $profiles) {
        if ($t.Gpu -eq $script:GpuChoice -and (Test-Supported $t) -and (Get-TweakState $t -Fresh)) {
            try { Disable-Tweak $t } catch { Write-Log "Falhou ao reverter $($t.Id): $($_.Exception.Message)" }
        }
    }
    $script:GpuChoice = $Choice
    $script:Backup.state['gpu'] = $Choice
    Save-Backup
    foreach ($t in $profiles) { $script:StateCache.Remove($t.Id); Sync-Row $t }
    Update-Gauge
    $label = if ($Choice -eq 'amd') { 'AMD' } else { 'NVIDIA' }
    Set-Status (Tx 'Placa de vídeo: {0}. O perfil de vídeo dela entra na próxima vez que você aplicar um perfil.' ($label))
}

# Cria um cartao por ajuste (uma vez so) e liga os botoes dele. Quem decide quais aparecem e o Update-TuneView.
function Initialize-Steps {
    foreach ($t in $script:Tweaks) {
        $card = New-Xaml $TweakXaml
        $r = @{ Root = $card; State = $card.FindName('State'); Toggle = $card.FindName('Toggle'); Run = $card.FindName('Run') }
        $meta = $card.FindName('Meta')
        $card.FindName('Cat').Text   = Get-CatLabel $t.Cat
        $card.FindName('Kind').Text  = Get-TweakKind $t
        $card.FindName('Title').Text = $t.Name
        $card.FindName('Body').Text  = $t.Desc

        # (i): o texto so e montado quando o mouse chega, porque alguns ajustes leem o registro para saber o que mudariam.
        $tip = New-Object System.Windows.Controls.TextBlock
        $tip.MaxWidth = 560
        $tip.TextWrapping = 'Wrap'
        $tip.FontFamily = New-Object System.Windows.Media.FontFamily 'Consolas, Segoe UI'
        $tip.Text = 'O que este ajuste muda'
        $info = $card.FindName('Info')
        $info.Tag = $t.Id
        $info.ToolTip = $tip
        $info.Add_ToolTipOpening({
            param($s, $e)
            try { $s.ToolTip.Text = Tr (Get-TweakDetail $script:TweakById[[string]$s.Tag]) } catch { }
        })

        $level = switch ($t.Impact) { 'Alto' { 3 } 'Médio' { 2 } default { 1 } }
        $color = if ($level -ge 2) { 'Ice' } else { 'Muted' }
        for ($i = 1; $i -le $level; $i++) { $card.FindName("D$i").Fill = $script:Window.FindResource($color) }
        $imp = $card.FindName('Impact')
        $imp.Text = switch ($level) { 3 { 'Impacto alto' } 2 { 'Impacto médio' } default { 'Impacto baixo' } }
        $imp.Foreground = $script:Window.FindResource($color)

        if ($t.Run) {
            # Acoes (limpeza, remocao de apps): rodam uma vez, na hora do clique.
            $r.Run.Visibility = 'Visible'
            $r.Run.Content = if ($t.Button) { $t.Button } elseif ($t.Apps) { 'Remover' } else { 'Limpar' }
            $r.Run.Tag = $t.Id
            $r.Run.Add_Click({
                param($s, $e)
                try {
                    if ($script:Busy) { return }
                    $tw = $script:TweakById[[string]$s.Tag]
                    Set-Busy $true
                    try {
                        Set-Status ((Tr $tw.Name) + '...')
                        $script:RunResult[$tw.Id] = [string](& $tw.Run $tw | Select-Object -Last 1)
                        Write-Log "Executado: $($tw.Id) -> $($script:RunResult[$tw.Id])"
                    } finally { Set-Busy $false }
                    if ($tw.Apps) {
                        # A remocao liga o bloqueio de reinstalacao; mostra isso no cartao dele.
                        $ads = $script:TweakById['ads']
                        [void](Get-TweakState $ads -Fresh); Sync-Row $ads; Update-Gauge
                        $script:AppsInstalled = $null
                    }
                    Sync-Row $tw
                    Set-Status (Tx '{0}: {1}.' (Tr $tw.Name) (Tr $script:RunResult[$tw.Id]))
                } catch { Show-Error $_ }
            })
            $meta.Text = if ($t.Manual) { 'Só manual: roda só quando você clica' } elseif ($t.Apps) { '★ Recomendado  ·  A remoção é definitiva: os apps não voltam sozinhos' } else { '★ Recomendado  ·  Roda uma vez, ao clicar ou ao aplicar o perfil' }
            if ($t.Manual) { $meta.Foreground = $script:Window.FindResource('Muted') }
        } else {
            $r.Toggle.Visibility = 'Visible'
            $r.Toggle.Tag = $t.Id
            $r.Toggle.Add_Click({
                param($s, $e)
                try {
                    $tw = $script:TweakById[[string]$s.Tag]
                    if ($script:Busy) { $s.IsChecked = (Get-TweakState $tw); return }
                    if ($s.IsChecked) {
                        Save-Baseline
                        Enable-Tweak $tw
                        $tail = if ($tw.Reboot) { ' Vale depois de reiniciar o PC.' } else { '' }
                        if (Get-TweakState $tw -Fresh) { Set-Status (Tx 'Ligado: {0}.{1}' (Tr $tw.Name) (Tr $tail)) } else { Set-Status (Tx 'Este PC não aceitou o ajuste: {0}.' (Tr $tw.Name)) }
                    } else {
                        Disable-Tweak $tw
                        [void](Get-TweakState $tw -Fresh)
                        Set-Status (Tx 'Desligado: {0}. O valor original foi devolvido.' (Tr $tw.Name))
                    }
                    Sync-Row $tw
                    Update-Gauge
                } catch { Show-Error $_ }
            })
            $kind = if ($t.Manual) { 'Só manual: nenhum perfil liga' } elseif ($t.Optional) { 'Opcional: fora do perfil Equilibrado' } else { '★ Recomendado' }
            $meta.Text = if ($t.Reboot) { "$kind  ·  Pede reinício" } else { $kind }
            if ($t.Manual -or $t.Optional) { $meta.Foreground = $script:Window.FindResource('Muted') }
        }
        $script:Rows[$t.Id] = $r
    }
}

# ----- Tela Otimizar: filtros, busca e grade de cartoes -----
$script:TuneFilter = 'all'
$script:TuneChips  = @{}

function Get-TuneFilters {
    $list = @( @('all', 'Todos'), @('rec', 'Recomendados'), @('on', 'Ativos') )
    foreach ($c in $script:TweakCats) { $list += , @($c[0], $c[1]) }
    return $list
}

function Initialize-Tune {
    foreach ($f in (Get-TuneFilters)) {
        $rb = New-Object System.Windows.Controls.RadioButton
        $rb.Style = $script:Window.FindResource('Seg')
        $rb.Tag = $f[0]
        $rb.GroupName = 'TuneFilter'
        $rb.FontSize = 12.5
        $rb.Margin = New-Object System.Windows.Thickness 0, 0, 7, 7
        $rb.Padding = New-Object System.Windows.Thickness 13, 6, 13, 6
        $rb.Content = $f[1]
        $rb.IsChecked = ($f[0] -eq $script:TuneFilter)
        $rb.Add_Checked({
            param($s, $e)
            try {
                $script:TuneFilter = [string]$s.Tag
                if ($script:Page -eq 'tune') { Update-TuneView }
            } catch { Show-Error $_ }
        })
        $script:TuneChips[$f[0]] = $rb
        [void]$script:ui.TuneChips.Children.Add($rb)
    }
    $script:ui.TuneSearch.Add_TextChanged({ try { if ($script:Page -eq 'tune') { Update-TuneView } } catch { Show-Error $_ } })
}

# Numeros dos filtros e a linha de contagem. Roda sempre que algum ajuste muda.
function Update-TuneCounts {
    $labels = @{}
    foreach ($f in (Get-TuneFilters)) { $labels[$f[0]] = $f[1] }
    $active = 0
    foreach ($key in @($script:TuneChips.Keys)) {
        $n = @(Select-Tweaks $key '').Count
        if ($key -eq 'on') { $active = $n }
        $script:TuneChips[$key].Content = "$($labels[$key])  ·  $n"
    }
    $left = @(Get-ManagedToggles | Where-Object { (Test-TweakRecommended $_) -and -not (Get-TweakState $_) }).Count
    $tail = if ($left -eq 0) { 'todos os recomendados ligados' } elseif ($left -eq 1) { '1 recomendado ainda desligado' } else { (Tx '{0} recomendados ainda desligados' $left) }
    $script:ui.TuneCount.Text = (Tx '{0} ajustes  ·  {1} ativos  ·  {2}' @($script:Tweaks | Where-Object { Test-ThisWindows $_ }).Count $active (Tr $tail))
}

# Monta a grade: duas colunas, cada linha com a altura do cartao mais alto dela.
function Update-TuneView {
    $panel = $script:ui.TuneGrid
    foreach ($g in @($panel.Children)) { if ($g -is [System.Windows.Controls.Panel]) { $g.Children.Clear() } }
    $panel.Children.Clear()
    $list = @(Select-Tweaks $script:TuneFilter $script:ui.TuneSearch.Text)
    if ($script:TuneFilter -eq 'debloat' -and -not $script:ui.TuneSearch.Text) {
        [void]$panel.Children.Add((New-DebloatCard))
        $script:ui.StepScroll.ScrollToTop()
        return
    }
    for ($i = 0; $i -lt $list.Count; $i += 2) {
        $g = New-Object System.Windows.Controls.Grid
        [void]$g.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
        [void]$g.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
        $a = $script:Rows[$list[$i].Id].Root
        [System.Windows.Controls.Grid]::SetColumn($a, 0)
        [void]$g.Children.Add($a)
        if ($i + 1 -lt $list.Count) {
            $b = $script:Rows[$list[$i + 1].Id].Root
            [System.Windows.Controls.Grid]::SetColumn($b, 1)
            [void]$g.Children.Add($b)
        }
        [void]$panel.Children.Add($g)
    }
    if ($list.Count -eq 0) {
        $none = New-Object System.Windows.Controls.TextBlock
        $none.Text = 'Nenhum ajuste com esse filtro ou essa busca.'
        $none.Foreground = $script:Window.FindResource('Muted')
        $none.Margin = New-Object System.Windows.Thickness 8, 18, 0, 0
        [void]$panel.Children.Add($none)
        Register-Tr $none
    }
    $script:ui.StepScroll.ScrollToTop()
}

# Lista do Debloat na tela Otimizar: cada item com a propria chave, e um botao que aplica so o que estiver marcado.
function New-DebloatRow($Box, [string]$Id, [string]$Title, [string]$Body, [bool]$Checked, [string]$Note, [string]$Tip) {
    $g = New-Object System.Windows.Controls.Grid
    $g.Margin = New-Object System.Windows.Thickness 0, 7, 0, 7
    $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star); $g.ColumnDefinitions.Add($c1)
    $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = [System.Windows.GridLength]::Auto; $g.ColumnDefinitions.Add($c2)
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Margin = New-Object System.Windows.Thickness 0, 0, 16, 0
    $head = New-Object System.Windows.Controls.TextBlock
    $head.TextWrapping = 'Wrap'
    $r1 = New-Object System.Windows.Documents.Run (Tr $Title)
    $r1.FontWeight = 'SemiBold'; $r1.Foreground = $script:Window.FindResource('Text')
    [void]$head.Inlines.Add($r1)
    if ($Note) {
        $r2 = New-Object System.Windows.Documents.Run ('   ' + (Tr $Note))
        $r2.FontSize = 11; $r2.Foreground = $script:Window.FindResource('Ice')
        [void]$head.Inlines.Add($r2)
    }
    $head.FontSize = 13
    [void]$sp.Children.Add($head)
    if ($Body) {
        $b = New-Object System.Windows.Controls.TextBlock
        $b.Text = $Body; $b.FontSize = 12; $b.LineHeight = 17; $b.TextWrapping = 'Wrap'
        $b.Foreground = $script:Window.FindResource('Muted'); $b.Margin = New-Object System.Windows.Thickness 0, 2, 0, 0
        [void]$sp.Children.Add($b)
    }
    if ($Tip) { $sp.ToolTip = $Tip }
    [void]$g.Children.Add($sp)
    $sw = New-Object System.Windows.Controls.CheckBox
    $sw.Style = $script:Window.FindResource('Switch')
    $sw.VerticalAlignment = 'Center'
    $sw.IsChecked = $Checked
    $sw.IsEnabled = -not $script:Busy
    $sw.Tag = $Id
    $sw.Add_Click({
        param($s, $e)
        try {
            $p = Get-DebloatPicks
            $p[[string]$s.Tag] = [bool]$s.IsChecked
            Set-DebloatPicks $p
            Update-DebloatSummary
        } catch { Show-Error $_ }
    })
    [System.Windows.Controls.Grid]::SetColumn($sw, 1)
    [void]$g.Children.Add($sw)
    [void]$Box.Children.Add($g)
}

function Update-DebloatSummary {
    if (-not $script:DebSummary) { return }
    $plan = Get-DebloatPlan
    $parts = @()
    if (@($plan.On).Count) { $parts += (Tx '{0} para tirar' (@($plan.On).Count)) }
    if (@($plan.Off).Count) { $parts += (Tx '{0} para devolver ao original' (@($plan.Off).Count)) }
    if ($plan.Apps) { $parts += (Tx '{0} apps para remover' ($plan.AppCount)) }
    $script:DebSummary.Text = if ($parts.Count) { (Tx 'Ao aplicar: {0}.' ($parts -join ', ')) } else { 'Nada a mudar: o Windows já está como as chaves marcadas.' }
    if ($script:DebApply) { $script:DebApply.IsEnabled = ($parts.Count -gt 0) -and -not $script:Busy }
}

function New-DebloatCard {
    $card = New-Xaml $GuideXaml
    $card.Margin = New-Object System.Windows.Thickness 6, 6, 6, 8
    $card.FindName('Title').Text = (Tx 'Debloat do {0}' (Get-WinName))
    $card.FindName('Intro').Text = 'Escolha o que sai do Windows: chave ligada tira o item, chave desligada deixa como o Windows vem. Só aparece o que existe nesta versão do Windows. Nada muda até você clicar em Aplicar, e tudo volta com Reverter tudo (menos os apps removidos). A Microsoft Store, o Xbox, a Game Bar, o Windows Update e o Defender nunca são tocados.'
    $rows = $card.FindName('Rows')
    $bar = New-Object System.Windows.Controls.WrapPanel
    $bar.Margin = New-Object System.Windows.Thickness 0, 0, 0, 4
    New-OnlineButton $bar 'Aplicar o que está marcado' 'Primary' $null { try { Show-DebloatConfirm } catch { Show-Error $_ } }
    $script:DebApply = $bar.Children[0]
    New-OnlineButton $bar 'Marcar os recomendados' 'Ghost' $null {
        try {
            $p = Get-DebloatPicks
            foreach ($t in Get-DebloatCandidates) { $p[$t.Id] = -not $t.Optional }
            $p['apps'] = $true
            Set-DebloatPicks $p; Update-TuneView
        } catch { Show-Error $_ }
    }
    New-OnlineButton $bar 'Desmarcar tudo' 'Ghost' $null {
        try {
            $p = Get-DebloatPicks
            foreach ($k in @($p.Keys)) { $p[$k] = $false }
            Set-DebloatPicks $p; Update-TuneView
        } catch { Show-Error $_ }
    }
    [void]$rows.Children.Add($bar)
    $script:DebSummary = New-Object System.Windows.Controls.TextBlock
    $script:DebSummary.FontSize = 12.5; $script:DebSummary.TextWrapping = 'Wrap'
    $script:DebSummary.Margin = New-Object System.Windows.Thickness 0, 2, 0, 6
    $script:DebSummary.Foreground = $script:Window.FindResource('Ice')
    [void]$rows.Children.Add($script:DebSummary)

    $p = Get-DebloatPicks
    $groups = @(
        @('Apps pré-instalados', $null),
        @('Windows, barra de tarefas e menu Iniciar', 'debloat'),
        @('Privacidade', 'priv')
    )
    foreach ($gr in $groups) {
        $h = New-Object System.Windows.Controls.TextBlock
        $h.Text = $gr[0]; $h.FontSize = 11.5; $h.FontWeight = 'SemiBold'
        $h.Foreground = $script:Window.FindResource('Muted')
        $h.Margin = New-Object System.Windows.Thickness 0, 14, 0, 2
        [void]$rows.Children.Add($h)
        $line = New-Object System.Windows.Controls.Border
        $line.Height = 1; $line.Background = $script:Window.FindResource('Line'); $line.Margin = New-Object System.Windows.Thickness 0, 2, 0, 2
        [void]$rows.Children.Add($line)
        if (-not $gr[1]) {
            $picks = Get-AppPicks
            $names = @($script:AppCatalog | Where-Object { $picks[$_.Id] } | ForEach-Object { Tr $_.Label })
            $body = if ($names.Count) { (Tx 'Saem os marcados na tela Apps ({0}): {1}.' ($names.Count) (($names | Select-Object -First 10) -join ', ') ) + $(if ($names.Count -gt 10) { ' ...' } else { '' }) } else { 'Nenhum app marcado na tela Apps.' }
            New-DebloatRow $rows 'apps' 'Remover apps pré-instalados' $body ([bool]$p['apps']) '' ''
            $wp = New-Object System.Windows.Controls.WrapPanel
            New-OnlineButton $wp 'Escolher os apps um por um' 'Ghost' $null { try { $script:ui.NavApps.IsChecked = $true } catch { Show-Error $_ } }
            [void]$rows.Children.Add($wp)
            continue
        }
        foreach ($t in @(Get-DebloatCandidates | Where-Object { $_.Cat -eq $gr[1] })) {
            $note = if (Get-TweakState $t) { 'já tirado' } elseif ($t.Optional) { 'opcional' } else { '' }
            New-DebloatRow $rows $t.Id $t.Name $t.Desc ([bool]$p[$t.Id]) $note (Tr (Get-TweakDetail $t))
        }
    }
    Update-DebloatSummary
    Register-Tr $card
    return $card
}

function Set-ConfirmItems($Items) {
    $script:ui.ConfirmList.Children.Clear()
    foreach ($c in $Items) {
        $row = New-Xaml $DiagXaml
        $row.FindName('Dot').Fill   = $script:Window.FindResource('Amber')
        $row.FindName('Title').Text = $c[0]
        $row.FindName('Body').Text  = $c[1]
        [void]$script:ui.ConfirmList.Children.Add($row)
    }
}

function Show-DebloatConfirm {
    if ($script:Busy) { return }
    $plan = Get-DebloatPlan
    if ((@($plan.On).Count + @($plan.Off).Count) -eq 0 -and -not $plan.Apps) { Set-Status 'Nada a mudar: o Windows já está como as chaves marcadas.'; return }
    $script:ConfirmMode = 'debloat'
    $script:ui.ConfirmIntro.Text = (Tx '{0} detectado. Só o que você marcou muda:' (Get-WinName))
    $items = @()
    $fmt = { param($l) ((@($l | Select-Object -First 8 | ForEach-Object { Tr $_.Name }) -join '; ') + $(if (@($l).Count -gt 8) { ' ...' } else { '' })) }
    if (@($plan.On).Count) { $items += , @((Tx 'Sai do Windows ({0})' (@($plan.On).Count)), (& $fmt $plan.On)) }
    if (@($plan.Off).Count) { $items += , @((Tx 'Volta ao original ({0})' (@($plan.Off).Count)), (& $fmt $plan.Off)) }
    if ($plan.Apps) {
        $picks = Get-AppPicks
        $names = @($script:AppCatalog | Where-Object { $picks[$_.Id] } | ForEach-Object { Tr $_.Label })
        $items += , @((Tx 'Apps removidos ({0})' ($names.Count)), ((($names | Select-Object -First 10) -join ', ') + $(if ($names.Count -gt 10) { ' ...' } else { '' }) + ' ' + (Tr 'Não voltam sozinhos.')))
    }
    $items += , $script:ConfirmItems[4]
    Set-ConfirmItems $items
    $script:ui.BtnConfirmYes.Content = 'Aplicar'
    $script:ui.ConfirmOverlay.Visibility = 'Visible'
}

# Abre a tela Otimizar ja filtrada.
function Show-Tune([string]$Filter) {
    if (-not $script:TuneChips.ContainsKey($Filter)) { $Filter = 'all' }
    $script:ui.TuneSearch.Text = ''
    $script:TuneFilter = $Filter
    $script:TuneChips[$Filter].IsChecked = $true
    if ($script:ui.NavTune.IsChecked) { Update-TuneView } else { $script:ui.NavTune.IsChecked = $true }
}

# ----- Tela Inicio: resumo por categoria -----
$script:SumRows = @{}

function Initialize-Summary {
    foreach ($c in $script:TweakCats) {
        $row = New-Xaml $SumXaml
        $r = @{ Num = $row.FindName('Count'); ColOn = $row.FindName('ColOn'); ColOff = $row.FindName('ColOff') }
        $row.FindName('Title').Text = $c[1]
        $open = $row.FindName('Open')
        $open.Tag = $c[0]
        $open.Add_Click({ param($s, $e) try { Show-Tune ([string]$s.Tag) } catch { Show-Error $_ } })
        if ($c[0] -eq 'gpu') {
            # Seletor de marca: so o perfil de video da marca escolhida entra nos perfis.
            $extra = $row.FindName('Extra')
            foreach ($opt in @( @('nvidia', 'NVIDIA'), @('amd', 'AMD') )) {
                $rb = New-Object System.Windows.Controls.RadioButton
                $rb.Style = $script:Window.FindResource('Seg')
                $rb.Content = $opt[1]
                $rb.Tag = $opt[0]
                $rb.GroupName = 'GpuChoice'
                $rb.IsChecked = ($script:GpuChoice -eq $opt[0])
                $rb.Add_Checked({ param($s, $e) try { Set-GpuChoice ([string]$s.Tag) } catch { Show-Error $_ } })
                $script:GpuRadios[$opt[0]] = $rb
                [void]$extra.Children.Add($rb)
            }
        }
        $script:SumRows[$c[0]] = $r
        [void]$script:ui.SummaryList.Children.Add($row)
    }
}

function Update-Summary {
    foreach ($c in (Get-CatSummary)) {
        $r = $script:SumRows[$c.Cat]
        if (-not $r) { continue }
        $acts = if ($c.Actions -eq 1) { '1 ação' } elseif ($c.Actions -gt 1) { (Tx '{0} ações' $c.Actions) } else { '' }
        if ($c.Total -eq 0) {
            $r.Num.Text = if ($acts) { $acts } else { 'Nada para este PC' }
            $r.ColOn.Width  = New-Object System.Windows.GridLength 0, ([System.Windows.GridUnitType]::Star)
            $r.ColOff.Width = New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star)
            continue
        }
        $r.Num.Text = (Tx '{0} de {1} ligados' $c.On $c.Total) + $(if ($acts) { '  ·  ' + (Tr $acts) } else { '' })
        $r.ColOn.Width  = New-Object System.Windows.GridLength $c.On, ([System.Windows.GridUnitType]::Star)
        $r.ColOff.Width = New-Object System.Windows.GridLength ($c.Total - $c.On), ([System.Windows.GridUnitType]::Star)
    }
}

# ----- Medidor -----
function Get-ArcPoint([double]$Deg, [double]$R) {
    $ci  = [Globalization.CultureInfo]::InvariantCulture
    $rad = $Deg * [Math]::PI / 180
    $x = 115 + $R * [Math]::Cos($rad)
    $y = 115 + $R * [Math]::Sin($rad)
    return @{ X = $x; Y = $y; S = ($x.ToString('0.###', $ci) + ',' + $y.ToString('0.###', $ci)) }
}

function Set-Gauge([double]$Fraction) {
    $r = 100
    $a = Get-ArcPoint 135 $r
    $b = Get-ArcPoint 405 $r
    $script:ui.GaugeTrack.Data = [System.Windows.Media.Geometry]::Parse("M $($a.S) A $r,$r 0 1 1 $($b.S)")
    if ($Fraction -le 0.001) { $script:ui.GaugeValue.Data = $null; return }
    if ($Fraction -gt 1) { $Fraction = 1 }
    $sweep = 270 * $Fraction
    $e = Get-ArcPoint (135 + $sweep) $r
    $large = 0
    if ($sweep -gt 180) { $large = 1 }
    $script:ui.GaugeValue.Data = [System.Windows.Media.Geometry]::Parse("M $($a.S) A $r,$r 0 $large 1 $($e.S)")
}

function Initialize-GaugeTicks {
    $line = $script:Window.FindResource('Line')
    $red  = $script:Window.FindResource('Red')
    for ($i = 0; $i -le 20; $i++) {
        $deg = 135 + 13.5 * $i
        $major = ($i % 2 -eq 0)
        $inner = if ($major) { 76 } else { 80 }
        $p1 = Get-ArcPoint $deg $inner
        $p2 = Get-ArcPoint $deg 85
        $l = New-Object System.Windows.Shapes.Line
        $l.X1 = $p1.X; $l.Y1 = $p1.Y; $l.X2 = $p2.X; $l.Y2 = $p2.Y
        $l.StrokeThickness = if ($major) { 2 } else { 1 }
        $l.Stroke = if ($i -ge 17) { $red } else { $line }
        [void]$script:ui.GaugeTicks.Children.Add($l)
    }
}

# Sem -All devolve os ajustes do perfil atual; com -All, todos os liga/desliga que este PC aceita.
function Get-Toggles([switch]$All) {
    if ($All) { return @($script:Tweaks | Where-Object { -not $_.Run -and (Test-Supported $_) }) }
    return @(Get-ManagedToggles | Where-Object { Test-InProfile $_ })
}

# Quantas mudancas o perfil atual ainda faria: ligar o que falta e desligar o que sobra.
function Get-ProfileDiff {
    $on = @(); $off = @()
    foreach ($t in Get-ManagedToggles) {
        $want = Test-InProfile $t
        $is   = Get-TweakState $t
        if ($want -and -not $is) { $on += $t } elseif (-not $want -and $is) { $off += $t }
    }
    return @{ On = $on; Off = $off }
}

function Update-Gauge {
    $toggles = Get-Toggles
    $active = 0
    foreach ($t in $toggles) { if (Get-TweakState $t) { $active++ } }
    $script:ui.GaugeNumber.Text = [string]$active
    $script:ui.GaugeLabel.Text  = (Tx 'de {0} do perfil ligados' ($($toggles.Count)))
    Set-Gauge ($active / [Math]::Max(1, $toggles.Count))
    try { Update-TuneCounts; Update-Summary } catch { Write-Log "Resumo: $($_.Exception.Message)" }
    if ($script:Busy) { return }
    $p = Get-Profile
    $d = Get-ProfileDiff
    $n = $d.On.Count + $d.Off.Count
    $script:ui.BtnOptimize.Content = (Tx 'Aplicar perfil {0}' (Tr $p.Label))
    $tail = if ($n -eq 0) { 'Este perfil já está aplicado.' } elseif ($n -eq 1) { 'Falta 1 mudança.' } else { (Tx 'Faltam {0} mudanças.' ($n)) }
    $script:ui.OptimizeNote.Text = "$($p.Hint) $tail"
}

$script:ProfileRadios = @{}

function Initialize-Profiles {
    foreach ($p in $script:Profiles) {
        $rb = New-Object System.Windows.Controls.RadioButton
        $rb.Style = $script:Window.FindResource('Seg')
        $rb.Content = $p.Label
        $rb.Tag = $p.Id
        $rb.GroupName = 'Profile'
        $rb.Margin = New-Object System.Windows.Thickness 3, 0, 3, 0
        $rb.Padding = New-Object System.Windows.Thickness 2, 6, 2, 6
        $rb.IsChecked = ($script:ProfileId -eq $p.Id)
        $rb.Add_Checked({
            param($s, $e)
            try {
                $id = [string]$s.Tag
                if ($id -eq $script:ProfileId) { return }
                if ($script:Busy) { $script:ProfileRadios[$script:ProfileId].IsChecked = $true; return }
                $script:ProfileId = $id
                $script:Backup.state['profile'] = $id
                Save-Backup
                Update-Gauge
                Set-Status (Tx 'Perfil {0} escolhido. Nada muda até você clicar em Aplicar perfil.' ($((Get-Profile).Label)))
            } catch { Show-Error $_ }
        })
        $script:ProfileRadios[$p.Id] = $rb
        [void]$script:ui.ProfileBar.Children.Add($rb)
    }
}

function Set-Busy([bool]$On) {
    $script:Busy = $On
    foreach ($n in 'BtnOptimize', 'BtnRevertAll', 'BtnRestart', 'BtnCfgLoad', 'BtnExport', 'BtnRefresh', 'BtnMeasure', 'BtnPlay', 'BtnOcApply', 'BtnOcReset', 'BtnAppsRemove') {
        $script:ui[$n].IsEnabled = (-not $On) -and ($script:Hosted -or ('BtnMeasure', 'BtnPlay' -notcontains $n))
    }
    foreach ($r in $script:Rows.Values) { $r.Toggle.IsEnabled = -not $On; $r.Run.IsEnabled = -not $On }
    if (-not $On) { foreach ($t in $script:Tweaks) { if (-not $t.Run -and -not (Test-Supported $t)) { $script:Rows[$t.Id].Toggle.IsEnabled = $false } } }
    foreach ($rb in $script:GpuRadios.Values) { $rb.IsEnabled = -not $On }
    foreach ($rb in $script:ProfileRadios.Values) { $rb.IsEnabled = -not $On }
    Update-Ui
}

# ----- Otimizar e reverter -----
# ----- Reinicio com contagem e cancelamento -----
$script:AutoRestart  = $true
$script:RestartToBios = $false
$script:BiosPending  = 0
$script:RestartAt    = [datetime]::MinValue
$script:RestartTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:RestartTimer.Interval = [TimeSpan]::FromSeconds(1)

function Update-RestartText {
    $left = [int][Math]::Ceiling(($script:RestartAt - (Get-Date)).TotalSeconds)
    if ($left -le 0) {
        $script:RestartTimer.Stop()
        Set-Status 'Reiniciando o PC...'
        return
    }
    if ($script:RestartToBios) { Set-Status (Tx 'O PC reinicia em {0} s e abre direto na BIOS. Salve o que estiver aberto; para desistir, clique de novo no botão ou em Cancelar reinício, na tela Início.' ($left)) }
    else { Set-Status (Tx 'O PC reinicia em {0} s para os ajustes valerem. Salve o que estiver aberto, ou clique em Cancelar reinício.' ($left)) }
}

function Start-Restart([int]$Seconds, [switch]$Firmware) {
    if ($Firmware) {
        # /fw pede ao Windows para abrir a tela da BIOS no proximo boot. Na primeira chamada ele as vezes so
        # prepara o pedido e devolve erro; a segunda agenda de fato.
        $r = Invoke-Native 'shutdown.exe' "/r /fw /t $Seconds"
        if ($r.Code -ne 0) { $r = Invoke-Native 'shutdown.exe' "/r /fw /t $Seconds" }
        if ($r.Code -ne 0) {
            Write-Log "Reinicio para a BIOS recusado (codigo $($r.Code))"
            Set-Status 'Este PC não aceita abrir a BIOS pelo Windows. Reinicie e aperte a tecla indicada assim que a tela acender.'
            return
        }
    } else {
        $r = Invoke-Native 'shutdown.exe' "/r /t $Seconds /c `"Harle Optimizer: reiniciando para os ajustes valerem.`""
        if ($r.Code -ne 0) {
            Write-Log "Reinicio recusado pelo Windows (codigo $($r.Code))"
            Set-Status 'O Windows não aceitou agendar o reinício. Reinicie pelo menu Iniciar para os ajustes valerem.'
            return
        }
    }
    $script:RestartToBios = [bool]$Firmware
    $script:RestartPending = $true
    $script:RestartAt = (Get-Date).AddSeconds($Seconds)
    $script:ui.BtnRestart.Content = 'Cancelar reinício'
    $script:RestartTimer.Start()
    Write-Log "Reinicio agendado para daqui a $Seconds s"
    Update-RestartText
}

function Stop-Restart {
    [void](Invoke-Native 'shutdown.exe' '/a')
    $script:RestartPending = $false
    $script:RestartTimer.Stop()
    $script:ui.BtnRestart.Content = 'Reiniciar o PC'
    Write-Log 'Reinicio cancelado'
    if ($script:RestartToBios) { Set-Status 'Reinício cancelado. Se o próximo reinício abrir na BIOS mesmo assim, é só sair dela sem salvar.' }
    else { Set-Status 'Reinício cancelado. Os ajustes que pedem reinício só passam a valer depois dele.' }
    $script:RestartToBios = $false
}

$script:RestartTimer.Add_Tick({ try { if ($script:RestartPending) { Update-RestartText } } catch { } })

function Invoke-OptimizeAll {
    if ($script:Busy) { return }
    Set-Busy $true
    try {
        $p = Get-Profile
        $script:ui.OptimizeNote.Text = 'Trabalhando. Pode levar alguns minutos; a janela continua respondendo.'
        Save-Baseline
        if (-not $script:RestoreDone) {
            Set-Status 'Criando um ponto de restauração do Windows...'
            $script:RestoreDone = New-RestorePoint
        }
        $managed = Get-ManagedToggles
        $i = 0
        $changed = 0
        foreach ($t in $managed) {
            $i++
            $want = Test-InProfile $t
            $is   = Get-TweakState $t -Fresh
            if ($want -and $is) { Set-Applied $t.Id $true; continue }
            if (-not $want -and -not $is) { continue }
            $changed++
            if ($want) {
                Set-Status (Tx 'Ligando {0} de {1}: {2}...' ($i) ($($managed.Count)) ($($t.Name)))
                try { Enable-Tweak $t } catch { Write-Log "Falhou $($t.Id): $($_.Exception.Message)" }
            } else {
                Set-Status (Tx 'Desligando {0} de {1}: {2}...' ($i) ($($managed.Count)) ($($t.Name)))
                try { Disable-Tweak $t } catch { Write-Log "Falhou ao desligar $($t.Id): $($_.Exception.Message)" }
            }
            [void](Get-TweakState $t -Fresh)
            Sync-Row $t
            Update-Gauge
            Update-Ui
        }
        foreach ($t in @($script:Tweaks | Where-Object { $_.Run -and -not $_.Manual })) {
            Set-Status ((Tr $t.Name) + '...')
            try {
                $script:RunResult[$t.Id] = [string](& $t.Run $t | Select-Object -Last 1)
                Write-Log "Executado: $($t.Id) -> $($script:RunResult[$t.Id])"
            } catch { Write-Log "Falhou $($t.Id): $($_.Exception.Message)" }
            Sync-Row $t
            Update-Ui
        }
        Save-Backup
        $toggles = Get-Toggles
        $on = @($toggles | Where-Object { Get-TweakState $_ }).Count
        Write-Log "Perfil aplicado: $($p.Id) ($on de $($toggles.Count))"
        $done = (Tx 'Perfil {0} aplicado: {1} de {2} ajustes ligados.' ($($p.Label)) ($on) ($($toggles.Count)))
        # Reinicio automatico: so quando algum ajuste mudou, a pessoa deixou ligado e nao esta no meio de uma partida.
        if ($changed -gt 0 -and $script:AutoRestart -and -not $script:Play.On) {
            Set-Status $done
            Start-Restart 60
        } elseif ($changed -gt 0) {
            Set-Status (Tx '{0} Reinicie o PC para tudo valer.' $done)
        } else {
            Set-Status $done
        }
    } catch {
        Show-Error $_
    } finally {
        Set-Busy $false
        Update-Gauge
    }
}

# ----- Debloat do Windows 10 e 11 num clique -----
# Liga os ajustes recomendados de Debloat e Privacidade que existem nesta versao do Windows e remove os apps
# marcados na tela Apps. Os opcionais ficam de fora. Store, Xbox, Game Bar, Windows Update e Defender nao sao tocados.

function Invoke-Debloat {
    if ($script:Busy) { return }
    Set-Busy $true
    try {
        Save-Baseline
        if (-not $script:RestoreDone) {
            Set-Status 'Criando um ponto de restauração do Windows...'
            $script:RestoreDone = New-RestorePoint
        }
        $plan = Get-DebloatPlan
        $list = @($plan.On) + @($plan.Off)
        $i = 0; $changed = 0
        foreach ($t in $list) {
            $i++
            $want = @($plan.On) -contains $t
            $changed++
            Set-Status (Tx '{0} {1} de {2}: {3}...' $(if ($want) { Tr 'Ligando' } else { Tr 'Desligando' }) ($i) ($list.Count) (Tr $t.Name))
            try { if ($want) { Enable-Tweak $t } else { Disable-Tweak $t } } catch { Write-Log "Falhou $($t.Id): $($_.Exception.Message)" }
            [void](Get-TweakState $t -Fresh)
            Sync-Row $t
            Update-Gauge
            Update-Ui
        }
        $appx = $script:TweakById['appx']
        $res = ''
        if ($appx -and $plan.Apps) {
            Set-Status 'Removendo os apps marcados. Pode levar um ou dois minutos...'
            try {
                $res = [string](& $appx.Run $appx | Select-Object -Last 1)
                $script:RunResult['appx'] = $res
                Write-Log "Debloat, apps: $res"
            } catch { Write-Log "Falhou appx: $($_.Exception.Message)" }
            Sync-Row $appx
        }
        Save-Backup
        Write-Log "Debloat concluido: $(@($plan.On).Count) ligados, $(@($plan.Off).Count) devolvidos, apps=$($plan.Apps)"
        $done = (Tx 'Debloat do {0} concluído: {1} itens tirados e {2} devolvidos ao original.' (Get-WinName) (@($plan.On).Count) (@($plan.Off).Count))
        if ($res) { $done += ' ' + (Tx 'Apps: {0}.' (Tr $res)) }
        if ($changed -gt 0 -and $script:AutoRestart -and -not $script:Play.On) { Set-Status $done; Start-Restart 60 }
        elseif ($changed -gt 0) { Set-Status (Tx '{0} Reinicie o PC para tudo valer.' $done) }
        else { Set-Status $done }
    } catch { Show-Error $_ } finally {
        Set-Busy $false
        Update-Gauge
        if ($script:Page -eq 'tune') { Update-TuneView }
    }
}

# ----- Salvar e carregar configuracao -----
$script:ConfigPending = $null

function Export-HarleConfig {
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Title = Tr 'Salvar a configuração do Harle'
    $dlg.Filter = (Tr 'Configuração do Harle') + ' (*.json)|*.json'
    $dlg.FileName = 'Harle-config.json'
    $dlg.InitialDirectory = [Environment]::GetFolderPath('MyDocuments')
    if (-not $dlg.ShowDialog($script:Window)) { return }
    $data = Get-ConfigData
    [IO.File]::WriteAllText($dlg.FileName, ($data | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding $false))
    Write-Log "Configuracao salva em $($dlg.FileName) ($(@($data.tweaks).Count) ajustes)"
    Set-Status (Tx 'Configuração salva em {0}: {1} ajustes ligados e os apps marcados. Mande o arquivo para quem quiser usar a mesma.' ($dlg.FileName) (@($data.tweaks).Count))
}

function Import-HarleConfig {
    if ($script:Busy) { return }
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Title = Tr 'Carregar uma configuração do Harle'
    $dlg.Filter = (Tr 'Configuração do Harle') + ' (*.json)|*.json'
    if (-not $dlg.ShowDialog($script:Window)) { return }
    $r = Read-ConfigFile $dlg.FileName
    if (-not $r.Ok) { Set-Status $r.Why; return }
    $script:ConfigPending = $r
    $d = $r.Data
    $script:ConfirmMode = 'import'
    $script:ui.ConfirmIntro.Text = (Tx 'Configuração salva em {0} no {1}, com o Harle {2}. Ela liga {3} ajustes e desliga {4}. O que você mais vai notar:' ([string]$d.exported) (Tr ([string]$d.windows)) ([string]$d.version) ($r.On.Count) ($r.Off.Count))
    $items = @()
    if ($r.On.Count -gt 0) { $items += , @('Liga', ((@($r.On | Select-Object -First 8 | ForEach-Object { Tr $_.Name }) -join '; ') + $(if ($r.On.Count -gt 8) { ' ...' } else { '' }))) }
    if ($r.Off.Count -gt 0) { $items += , @('Desliga e devolve o valor original', ((@($r.Off | Select-Object -First 8 | ForEach-Object { Tr $_.Name }) -join '; ') + $(if ($r.Off.Count -gt 8) { ' ...' } else { '' }))) }
    $items += , @('Apps marcados', 'A lista de apps a remover também é copiada, mas nenhum app sai agora. Eles só saem quando você clicar em Remover os marcados, na tela Apps.')
    if ($r.Missing.Count -gt 0) { $items += , @('Fica de fora', (Tx '{0} ajustes do arquivo não existem neste PC (outra versão do Windows ou outra marca de placa de vídeo).' ($r.Missing.Count))) }
    $items += , $script:ConfirmItems[4]
    Set-ConfirmItems $items
    $script:ui.BtnConfirmYes.Content = 'Carregar configuração'
    $script:ui.ConfirmOverlay.Visibility = 'Visible'
}

function Invoke-ImportConfig {
    $r = $script:ConfigPending
    if (-not $r -or $script:Busy) { return }
    Set-Busy $true
    $changed = 0
    try {
        $d = $r.Data
        if (@($script:Profiles | ForEach-Object { $_.Id }) -contains [string]$d.profile) {
            $script:ProfileId = [string]$d.profile
            $script:Backup.state['profile'] = $script:ProfileId
            if ($script:ProfileRadios[$script:ProfileId]) { $script:ProfileRadios[$script:ProfileId].IsChecked = $true }
        }
        if ($d.appsPick) {
            $ov = @{}
            foreach ($a in $script:AppCatalog) { $v = $d.appsPick.($a.Id); if ($null -ne $v) { $ov[$a.Id] = [bool]$v } }
            $script:Backup.state['appsPick'] = $ov
        }
        if ($null -ne $d.autoRestart) { $script:AutoRestart = [bool]$d.autoRestart; $script:Backup.state['autoRestart'] = $script:AutoRestart; $script:ui.AutoRestart.IsChecked = $script:AutoRestart }
        if ($d.alertLimit -ge 60 -and $d.alertLimit -le 95) { $script:Backup.state['alertLimit'] = [int]$d.alertLimit }
        if ($null -ne $d.ovCorner) { $script:Backup.state['ovCorner'] = [int]$d.ovCorner }
        if ($d.playClose) { $script:Backup.state['playClose'] = ConvertTo-Hashtable $d.playClose }
        Save-Backup
        if (($r.On.Count + $r.Off.Count) -gt 0) {
            Save-Baseline
            if (-not $script:RestoreDone) {
                Set-Status 'Criando um ponto de restauração do Windows...'
                $script:RestoreDone = New-RestorePoint
            }
        }
        $all = @($r.On) + @($r.Off)
        $i = 0
        foreach ($t in $all) {
            $i++
            $want = @($r.On) -contains $t
            Set-Status (Tx '{0} {1} de {2}: {3}...' $(if ($want) { Tr 'Ligando' } else { Tr 'Desligando' }) ($i) ($all.Count) (Tr $t.Name))
            try { if ($want) { Enable-Tweak $t } else { Disable-Tweak $t } } catch { Write-Log "Falhou $($t.Id): $($_.Exception.Message)" }
            $changed++
            [void](Get-TweakState $t -Fresh)
            Sync-Row $t
            Update-Gauge
            Update-Ui
        }
        Save-Backup
        Write-Log "Configuracao carregada: $($r.On.Count) ligados, $($r.Off.Count) desligados, $($r.Missing.Count) fora"
        $done = (Tx 'Configuração carregada: {0} ajustes ligados e {1} desligados.' ($r.On.Count) ($r.Off.Count))
        if ($changed -gt 0 -and $script:AutoRestart -and -not $script:Play.On) { Set-Status $done; Start-Restart 60 }
        elseif ($changed -gt 0) { Set-Status (Tx '{0} Reinicie o PC para tudo valer.' $done) }
        else { Set-Status $done }
    } catch { Show-Error $_ } finally {
        $script:ConfigPending = $null
        Set-Busy $false
        Update-Gauge
    }
}

function Invoke-RevertAll {
    if ($script:Busy) { return }
    Set-Busy $true
    try {
        $gms = @(Get-Games)
        if (@($gms | Where-Object { $_.Prio -or $_.Gpu }).Count -gt 0) { foreach ($g in $gms) { Reset-GameFlags $g }; Save-Games $gms }
        $dnsBack = $false
        if ($script:Backup.state['dnsSet']) { try { Restore-HarleDns; $dnsBack = $true } catch { Write-Log "DNS: $($_.Exception.Message)" } }
        $on = @(Get-Toggles -All | Where-Object { Get-TweakState $_ -Fresh })
        if ($on.Count -eq 0) { Set-Status $(if ($dnsBack) { 'DNS original de volta. Não havia ajustes ativos para reverter.' } else { 'Não há ajustes ativos para reverter.' }); return }
        $i = 0
        foreach ($t in $on) {
            $i++
            Set-Status (Tx 'Revertendo {0} de {1}: {2}...' ($i) ($($on.Count)) ($($t.Name)))
            try { Disable-Tweak $t } catch { Write-Log "Falhou ao reverter $($t.Id): $($_.Exception.Message)" }
            [void](Get-TweakState $t -Fresh)
            Sync-Row $t
            Update-Gauge
            Update-Ui
        }
        $script:Backup.state.Remove('baseline')
        Save-Backup
        Set-Status (Tx '{0} ajustes revertidos. Reinicie o PC para concluir.' $on.Count)
    } catch {
        Show-Error $_
    } finally {
        Set-Busy $false
        Update-Gauge
    }
}

# ----- Linhas com titulo, texto, estado e (as vezes) um botao -----
function New-InfoRow([string]$Title, [string]$Body) {
    $row = New-Xaml $StepXaml
    $r = @{ Root = $row; Dot = $row.FindName('Dot'); State = $row.FindName('State'); Toggle = $row.FindName('Toggle'); Body = $row.FindName('Body') }
    $row.FindName('Title').Text = $Title
    if ($Body) { $r.Body.Text = $Body } else { $r.Body.Visibility = 'Collapsed' }
    return $r
}

function Set-RowLight($Row, [string]$Brush, [string]$Text) {
    $Row.Dot.Fill = $script:Window.FindResource($Brush)
    $Row.State.Text = $Text
    $Row.State.Foreground = $script:Window.FindResource($(if ($Brush -eq 'Line') { 'Muted' } else { $Brush }))
}

function Format-Ram([int]$MB) {
    if ($MB -ge 1024) { return ('{0:N1} GB' -f ($MB / 1024)) }
    return "$MB MB"
}

# ----- Medicao -----
function Format-Diff([int]$Value, [string]$Unit) {
    if ($Value -gt 0) { return (Tx '{0} {1} a menos' $Value (Tr $Unit)) }
    if ($Value -lt 0) { return (Tx '{0} {1} a mais' (-$Value) (Tr $Unit)) }
    return (Tx 'sem diferença em {0}' (Tr $Unit))
}

function Update-MeasureView {
    $ui = $script:ui
    $base = $script:Backup.state['baseline']
    $now  = Get-Load
    $ui.LoadNow.Text = Format-Load $now
    if ($base) {
        $ui.LoadBefore.Text    = Format-Load $base
        $ui.LoadBeforeSub.Text = (Tx 'Anotado em {0}, antes do primeiro ajuste.' ($($base.When)))
        $ui.LoadNowSub.Text    = (Tx '{0}, {1}.' (Format-Diff ([int]$base.RamMB - [int]$now.RamMB) 'MB de RAM') (Format-Diff ([int]$base.Procs - [int]$now.Procs) 'processos'))
    } else {
        $ui.LoadBefore.Text    = 'Sem registro'
        $ui.LoadBeforeSub.Text = 'É anotado quando você liga o primeiro ajuste.'
        $ui.LoadNowSub.Text    = ''
    }
    if ($script:Hosted) {
        $ui.FpsNote.Text = 'Abra o jogo e entre em uma cena que dê para repetir. Clique em Medir e volte para o jogo: a medição começa em 10 segundos e dura 60. Meça uma vez antes de otimizar e outra depois, na mesma cena. Diferenças abaixo de 3% são variação normal. Se usar o overlay, deixe-o igual nas duas medições. Com duas medições do mesmo jogo, Gerar cartão de resultado monta a imagem de antes e depois.'
    } else {
        $ui.FpsNote.Text = 'A medição de FPS só existe no Harle.exe.'
    }
    $ui.FpsList.Children.Clear()
    try { Update-FpsChart } catch { Write-Log "Grafico de FPS: $($_.Exception.Message)" }
    $list = @($script:Backup.state['fps'] | Where-Object { $_ })
    if ($list.Count -eq 0) {
        $r = New-InfoRow 'Nenhuma medição ainda' ''
        [void]$ui.FpsList.Children.Add($r.Root)
        return
    }
    for ($i = $list.Count - 1; $i -ge 0; $i--) {
        $m = $list[$i]
        $prev = $null
        for ($j = $i - 1; $j -ge 0; $j--) { if ([string]$list[$j].App -eq [string]$m.App) { $prev = $list[$j]; break } }
        $title = ((Tx '{0}: {1:N1} FPS de média, {2:N1} FPS de 1% low') -f $m.App, [double]$m.Avg, [double]$m.Low)
        $r = New-InfoRow $title (Tx '{0}, com {1} ajustes ativos' $m.When $m.Active)
        if ($prev -and [double]$prev.Avg -gt 0) {
            $pct = 100.0 * ([double]$m.Avg - [double]$prev.Avg) / [double]$prev.Avg
            $brush = if ($pct -ge 3) { 'Amber' } else { 'Line' }
            Set-RowLight $r $brush ((Tx '{0:+0.0;-0.0;0.0}% na média') -f $pct)
        }
        [void]$ui.FpsList.Children.Add($r.Root)
    }
}

function Invoke-FpsMeasure {
    if ($script:Busy -or -not $script:Hosted) { return }
    Set-Busy $true
    $p = $null
    try {
        $exe = Get-AssetPath 'PresentMon.exe'
        [void](Get-AssetPath 'PresentMon-LICENSE.txt')
        if (-not (Test-Path -LiteralPath $script:DataDir)) { New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null }
        $csv = Join-Path $script:DataDir 'medicao.csv'
        Remove-Item -LiteralPath $csv -Force -ErrorAction SilentlyContinue
        $delay = 10; $secs = 60
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $exe
        $psi.Arguments = "--output_file `"$csv`" --delay $delay --timed $secs --terminate_after_timed --no_console_stats --stop_existing_session --session_name HarleFps"
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $start = Get-Date
        $last = ''
        while (-not $p.HasExited) {
            $el = ((Get-Date) - $start).TotalSeconds
            $text = if ($el -lt $delay) { (Tx 'Volte para o jogo. A medição começa em {0} s.' ($([int][Math]::Ceiling($delay - $el)))) }
                    else { (Tx 'Medindo: faltam {0} s. Jogue normalmente.' ([int][Math]::Max(0, [Math]::Ceiling($delay + $secs - $el)))) }
            if ($text -ne $last) { $script:ui.StatusText.Text = $text; $last = $text }
            Update-Ui 'Background'
            Start-Sleep -Milliseconds 100
            if ($el -gt ($delay + $secs + 30)) { try { $p.Kill() } catch { }; break }
        }
        Set-Status 'Calculando o resultado...'
        $stats = Get-FrameStats $csv
        if (-not $stats) {
            Set-Status 'Não encontrei um jogo desenhando quadros durante a medição. Deixe o jogo em primeiro plano e meça de novo.'
            return
        }
        $active = @(Get-Toggles -All | Where-Object { Get-TweakState $_ }).Count
        $entry = @{ When = (Get-Date).ToString('dd/MM/yyyy HH:mm'); App = $stats.App; Avg = $stats.Avg; Low = $stats.Low; Active = $active }
        $list = @($script:Backup.state['fps'] | Where-Object { $_ }) + $entry
        if ($list.Count -gt 40) { $list = $list[($list.Count - 40)..($list.Count - 1)] }
        $script:Backup.state['fps'] = $list
        Save-Backup
        Write-Log "FPS: $($stats.App) media $($stats.Avg) low $($stats.Low) em $($stats.Frames) quadros"
        Update-MeasureView
        Set-Status ((Tx 'Medição concluída: {0}, {1:N1} FPS de média e {2:N1} de 1% low.') -f $stats.App, $stats.Avg, $stats.Low)
    } catch {
        Show-Error $_
    } finally {
        if ($p) { try { $p.Dispose() } catch { } }
        Set-Busy $false
    }
}

# ----- Apps -----
$script:AppsInstalled = $null
$script:AppsScanning  = $false
$script:AppRows       = @{}
$script:AppsShown     = @()

function Sync-AppRow([string]$Id, [bool]$On) {
    $r = $script:AppRows[$Id]
    if (-not $r) { return }
    $r.Toggle.IsChecked = $On
    if ($On) { Set-RowLight $r 'Amber' 'Sai' } else { Set-RowLight $r 'Line' 'Fica' }
}

function Update-AppsView([switch]$Scan) {
    $ui = $script:ui
    if ($script:AppsScanning) { return }
    if ($Scan -or $null -eq $script:AppsInstalled) {
        if ($script:Busy) { $ui.AppsNote.Text = 'Espere o trabalho em andamento terminar e clique em Atualizar.'; return }
        $script:AppsScanning = $true
        Set-Busy $true
        try {
            Set-Status 'Procurando os apps instalados...'
            $script:AppsInstalled = @(Invoke-Background $script:AppScanCode $null | ForEach-Object { [string]$_ })
        } finally {
            $script:AppsScanning = $false
            Set-Busy $false
        }
    }
    $ui.AppsRecList.Children.Clear(); $ui.AppsOptList.Children.Clear()
    $script:AppRows = @{}
    $listed = $script:AppsInstalled.Count -gt 0
    # Se o Windows nao entregou a lista, mostra o catalogo inteiro em vez de uma tela vazia.
    $shown = if ($listed) { @(Get-CatalogInstalled $script:AppsInstalled) } else { @($script:AppCatalog) }
    $script:AppsShown = @($shown | ForEach-Object { $_.Id })
    $picks = Get-AppPicks
    foreach ($a in $shown) {
        $r = New-InfoRow $a.Label $a.Note
        $r.Toggle.Visibility = 'Visible'
        $r.Toggle.Tag = $a.Id
        $r.Toggle.Add_Click({
            param($s, $e)
            try {
                $id = [string]$s.Tag
                if ($script:Busy) { Sync-AppRow $id ([bool](Get-AppPicks)[$id]); return }
                Set-AppPick $id ([bool]$s.IsChecked)
                Sync-AppRow $id ([bool]$s.IsChecked)
                Update-AppsNote
            } catch { Show-Error $_ }
        })
        $script:AppRows[$a.Id] = $r
        Sync-AppRow $a.Id ([bool]$picks[$a.Id])
        if ($a.Rec) { [void]$ui.AppsRecList.Children.Add($r.Root) } else { [void]$ui.AppsOptList.Children.Add($r.Root) }
    }
    foreach ($pair in @(@($ui.AppsRecList, 'Nenhum dos apps recomendados está instalado.'), @($ui.AppsOptList, 'Nenhum dos apps opcionais está instalado.'))) {
        if ($pair[0].Children.Count -eq 0) { [void]$pair[0].Children.Add((New-InfoRow $pair[1] '').Root) }
    }
    Update-AppsNote
    if (-not $listed) { Set-Status 'O Windows não entregou a lista de apps instalados, então a tela mostra todos os que o Harle conhece.' }
    else { Set-Status (Tx '{0} apps que o Harle sabe remover estão instalados.' $shown.Count) }
}

function Update-AppsNote {
    $picks = Get-AppPicks
    $n = @($script:AppsShown | Where-Object { $picks[$_] }).Count
    $script:ui.AppsNote.Text = (Tx 'Marcados para sair: {0}. A remoção vale para todos os usuários do PC, e o Windows não reinstala sozinho depois. Para ter um app de volta, instale de novo pela Microsoft Store. A Store, o login do Xbox e a Game Bar não aparecem aqui porque jogos dependem deles. O botão Aplicar perfil, da tela Início, também remove o que estiver marcado.' ($n))
    $script:ui.BtnAppsRemove.IsEnabled = ($n -gt 0) -and -not $script:Busy
}

function Invoke-AppsRemove {
    if ($script:Busy) { return }
    $names = @(Get-AppNamesToRemove $script:AppsShown)
    if ($names.Count -eq 0) { Set-Status 'Nenhum app marcado.'; return }
    Set-Busy $true
    $res = ''
    try {
        Set-Status 'Removendo os apps marcados. Pode levar um ou dois minutos...'
        $res = Remove-Bloat $names
        $script:RunResult['appx'] = $res
        Write-Log "Tela Apps: $res"
        Sync-Row $script:TweakById['appx']
    } catch {
        Show-Error $_
    } finally {
        Set-Busy $false
    }
    Update-AppsView -Scan
    if ($res) { Set-Status (Tx 'Apps: {0}.' (Tr $res)) }
}

# ----- Inicializacao -----
$script:BootItems = @{}
$script:BootRows  = @{}

function Sync-BootRow([string]$Id) {
    $i = $script:BootItems[$Id]
    $r = $script:BootRows[$Id]
    $r.Toggle.IsChecked = [bool]$i.Enabled
    if ($i.Enabled) { Set-RowLight $r 'Ice' 'Abre com o Windows' } else { Set-RowLight $r 'Line' 'Não abre mais' }
}

function Update-BootView {
    $panel = $script:ui.BootList
    $panel.Children.Clear()
    $script:BootItems = @{}; $script:BootRows = @{}
    $items = @(Get-StartupItems)
    if ($items.Count -eq 0) {
        $r = New-InfoRow 'Nenhum programa configurado para abrir com o Windows' 'Apps da Microsoft Store têm a própria lista em Configurações, Aplicativos, Inicialização.'
        [void]$panel.Children.Add($r.Root)
        return
    }
    $n = 0
    foreach ($i in $items) {
        $n++
        $id = "b$n"
        $body = [string]$i.Exe
        if ($i.RamMB -gt 0) { $body = "$body`n" + (Tx 'Usando {0} de RAM agora.' (Format-Ram $i.RamMB)) }
        $r = New-InfoRow $i.Title $body
        $r.Toggle.Visibility = 'Visible'
        $r.Toggle.Tag = $id
        $r.Toggle.Add_Click({
            param($s, $e)
            try {
                $id = [string]$s.Tag
                $it = $script:BootItems[$id]
                if (-not $script:Busy) {
                    Set-StartupEnabled $it.Appr $it.Key ([bool]$s.IsChecked)
                    $it.Enabled = Test-StartupEnabled $it.Appr $it.Key
                    Write-Log "Inicializacao: $($it.Name) = $($it.Enabled)"
                    $msg = if ($it.Enabled) { 'volta a abrir com o Windows' } else { 'não abre mais com o Windows' }
                    Set-Status ($it.Title + ' ' + (Tr $msg) + '.')
                }
                Sync-BootRow $id
            } catch { Show-Error $_ }
        })
        $script:BootItems[$id] = $i
        $script:BootRows[$id]  = $r
        Sync-BootRow $id
        [void]$panel.Children.Add($r.Root)
    }
}

# ----- Modo partida -----
$script:Play      = @{ On = $false; Closed = @(); GamePid = 0; GameName = ''; Boosted = $false; FreedMB = 0 }
$script:PlayItems = @{}
$script:PlayRows  = @{}
$script:PlayTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:PlayTimer.Interval = [TimeSpan]::FromSeconds(3)

function Get-SessionProcesses {
    $sid = (Get-Process -Id $PID).SessionId
    return @(Get-Process | Where-Object { $_.SessionId -eq $sid -and $_.Id -ne $PID })
}

function Update-PlayTexts {
    $ui = $script:ui
    if (-not $script:Hosted) {
        $ui.PlayTitle.Text = 'Só no Harle.exe'
        $ui.PlayState.Text = 'O modo partida precisa do executável para reconhecer o jogo em tela cheia.'
        return
    }
    if (-not $script:Play.On) {
        $ui.PlayTitle.Text = 'Modo partida desligado'
        $ui.PlayState.Text = 'Ao entrar, o Harle fecha o que está marcado ao lado. Quando o jogo aparecer em tela cheia, ele recebe prioridade alta de processador.'
        $ui.BtnPlay.Content = 'Entrar no modo partida'
        return
    }
    $ui.PlayTitle.Text = 'Modo partida ligado'
    $ui.BtnPlay.Content = 'Sair do modo partida'
    $freed = if ($script:Play.FreedMB -gt 0) { (Tx ' {0} de RAM liberados.' ($(Format-Ram $script:Play.FreedMB))) } else { '' }
    if ($script:Play.GamePid) {
        $pri = if ($script:Play.Boosted) { 'com prioridade alta' } else { 'sem mudar a prioridade, porque o jogo não permitiu' }
        $ui.PlayState.Text = (Tx 'Jogo reconhecido: {0}, {1}.{2}' $script:Play.GameName (Tr $pri) $freed)
    } else {
        $ui.PlayState.Text = (Tx 'Esperando um jogo aparecer em tela cheia.{0}' ($freed))
    }
}

function Sync-PlayRow([string]$Name) {
    $i = $script:PlayItems[$Name]
    $r = $script:PlayRows[$Name]
    $r.Toggle.IsChecked = [bool]$i.Close
    if ($i.Close) { Set-RowLight $r 'Amber' 'Fecha' } else { Set-RowLight $r 'Line' 'Fica aberto' }
}

function Update-PlayView {
    $panel = $script:ui.PlayList
    $panel.Children.Clear()
    $script:PlayItems = @{}; $script:PlayRows = @{}
    Update-PlayTexts
    $cands = @(Get-PlayCandidates (Get-SessionProcesses) $script:Backup.state['playClose'])
    if ($cands.Count -eq 0) {
        $r = New-InfoRow 'Nada pesado aberto agora' 'Navegadores, launchers e outros programas grandes aparecem aqui quando estiverem abertos.'
        [void]$panel.Children.Add($r.Root)
        return
    }
    foreach ($c in $cands) {
        $r = New-InfoRow $c.Label (Tx '{0} de RAM em uso' (Format-Ram $c.RamMB))
        $r.Toggle.Visibility = 'Visible'
        $r.Toggle.Tag = $c.Name
        $r.Toggle.IsEnabled = -not $script:Play.On
        $r.Toggle.Add_Click({
            param($s, $e)
            try {
                $name = [string]$s.Tag
                $script:PlayItems[$name].Close = [bool]$s.IsChecked
                $ov = ConvertTo-Hashtable $script:Backup.state['playClose']
                $ov[$name] = [bool]$s.IsChecked
                $script:Backup.state['playClose'] = $ov
                Save-Backup
                Sync-PlayRow $name
            } catch { Show-Error $_ }
        })
        $script:PlayItems[$c.Name] = $c
        $script:PlayRows[$c.Name]  = $r
        Sync-PlayRow $c.Name
        [void]$panel.Children.Add($r.Root)
    }
}

function Enter-PlayMode {
    if ($script:Busy -or -not $script:Hosted -or $script:Play.On) { return }
    Set-Busy $true
    try {
        $sid    = (Get-Process -Id $PID).SessionId
        $mine   = Get-SessionProcesses
        $closed = @()
        $freed  = [int64]0
        foreach ($c in @($script:PlayItems.Values | Where-Object { $_.Close })) {
            $ps = @($mine | Where-Object { $_.ProcessName -eq $c.Name })
            if ($ps.Count -eq 0) { continue }
            $path = $null; $window = $false
            foreach ($p in $ps) {
                $freed += [int64]$p.WorkingSet64
                if (-not $path) { try { $path = $p.MainModule.FileName } catch { } }
                try { if ($p.MainWindowHandle -ne [IntPtr]::Zero) { $window = $true; [void]$p.CloseMainWindow() } } catch { }
            }
            $closed += @{ Name = $c.Name; Path = $path; Window = $window }
        }
        if ($closed.Count -gt 0) {
            Set-Status 'Fechando os programas marcados...'
            $t0 = Get-Date
            while (((Get-Date) - $t0).TotalSeconds -lt 4) { Update-Ui 'Background'; Start-Sleep -Milliseconds 100 }
            foreach ($c in $closed) {
                Get-Process -Name $c.Name -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $sid } | Stop-Process -Force -ErrorAction SilentlyContinue
            }
        }
        $script:Play = @{ On = $true; Closed = $closed; GamePid = 0; GameName = ''; Boosted = $false; FreedMB = [int]($freed / 1MB) }
        $script:PlayTimer.Start()
        Write-Log "Modo partida: fechou $(@($closed | ForEach-Object { $_.Name }) -join ', ')"
        Set-Status (Tx 'Modo partida ligado. {0} programas fechados.' $closed.Count)
    } catch {
        Show-Error $_
    } finally {
        Set-Busy $false
        Update-PlayView
    }
}

function Exit-PlayMode([string]$Why) {
    $script:PlayTimer.Stop()
    if ($script:Play.GamePid -and $script:Play.Boosted) {
        try { (Get-Process -Id $script:Play.GamePid -ErrorAction Stop).PriorityClass = [System.Diagnostics.ProcessPriorityClass]::Normal } catch { }
    }
    $reopened = 0
    foreach ($c in @($script:Play.Closed)) {
        # Pelo explorer.exe o programa volta sem permissao de administrador, como estava.
        if ($c.Window -and $c.Path -and ($c.Path -notmatch '\\WindowsApps\\') -and (Test-Path -LiteralPath $c.Path)) {
            try { Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$($c.Path)`""; $reopened++ } catch { }
        }
    }
    $script:Play = @{ On = $false; Closed = @(); GamePid = 0; GameName = ''; Boosted = $false; FreedMB = 0 }
    Write-Log "Modo partida desligado ($Why), $reopened reabertos"
    Update-PlayView
    Set-Status (Tx '{0} Modo partida desligado, {1} programas reabertos.' (Tr $Why) $reopened)
}

function Step-PlayMode {
    if (-not $script:Play.On -or $script:Busy) { return }
    if ($script:Play.GamePid) {
        if (-not (Get-Process -Id $script:Play.GamePid -ErrorAction SilentlyContinue)) { Exit-PlayMode 'O jogo fechou.' }
        return
    }
    $fp = [Harle.Native]::FullscreenForegroundPid()
    if ($fp -le 0 -or $fp -eq $PID) { return }
    $p = Get-Process -Id $fp -ErrorAction SilentlyContinue
    if (-not $p) { return }
    if (($script:PlayIgnore -contains $p.ProcessName) -or $script:PlayKnown.ContainsKey($p.ProcessName)) { return }
    $boosted = $false
    try { $p.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::High; $boosted = $true } catch { }
    $script:Play.GamePid  = $fp
    $script:Play.GameName = $p.ProcessName
    $script:Play.Boosted  = $boosted
    Write-Log "Modo partida: jogo $($p.ProcessName) (prioridade alta: $boosted)"
    Update-PlayTexts
}

$script:PlayTimer.Add_Tick({ try { Step-PlayMode } catch { Write-Log "Modo partida: $($_.Exception.Message)" } })

# ----- Monitor, overlay e alerta de temperatura: um unico relogio de 1 segundo -----
$script:MonTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:MonTimer.Interval = [TimeSpan]::FromSeconds(1)
$script:Ov    = @{ On = $false; Corner = 0; Win = $null; El = $null; Hwnd = [IntPtr]::Zero; Proc = $null; Mode = 0; Since = [datetime]::MinValue; FpsDead = $false; Restarts = 0; BannerUntil = [datetime]::MinValue }
$script:Alert = @{ On = $false; Limit = 85; Hot = 0; Active = $false; Last = [datetime]::MinValue }
$script:OverlaySession = 'HarleOverlay'
$script:CoolBrush = (New-Object System.Windows.Media.BrushConverter).ConvertFromString('#E9EDF4')
$script:HotBrush  = (New-Object System.Windows.Media.BrushConverter).ConvertFromString('#FF8A7A')

function Format-Reading($Value, [string]$Format, [string]$Unit) {
    if ($null -eq $Value -or [double]$Value -lt 0) { return 'Sem leitura' }
    return (($Format -f [double]$Value) + $Unit)
}

# Uma leitura de tudo. O uso do processador e a diferenca desde a leitura anterior, por isso so pode ser lido uma vez por segundo.
function Read-Sensors {
    if (-not $script:Hosted) { return $null }
    $g = if ($script:GpuChoice -eq 'amd') { [Harle.Amd]::Monitor() } else { [Harle.Monitor]::Nvidia() }
    return @{ G = $g; Cpu = [Harle.Monitor]::CpuPercent(); Mem = [Harle.Monitor]::Memory() }
}

function Update-Monitor($r) {
    $ui = $script:ui
    if (-not $r) {
        foreach ($n in 'MonGpuTemp', 'MonGpuUse', 'MonVram', 'MonFan', 'MonPower', 'MonCoreClk', 'MonMemClk', 'MonCpu', 'MonRam') { $ui[$n].Text = 'Só no Harle.exe' }
        return
    }
    $g = $r.G
    $ui.MonGpuTitle.Text = if ($script:GpuChoice -eq 'amd') { 'Placa de vídeo AMD' } else { 'Placa de vídeo NVIDIA' }
    $ui.MonGpuTemp.Text  = Format-Reading $g[1] '{0:N0}' ' °C'
    $ui.MonGpuUse.Text   = Format-Reading $g[2] '{0:N0}' ' %'
    $ui.MonVram.Text     = if ($g[3] -ge 0 -and $g[4] -gt 0) { (Tx '{0:N1} de {1:N0} GB') -f ($g[3] / 1024), ($g[4] / 1024) } else { 'Sem leitura' }
    $ui.MonFan.Text      = Format-Reading $g[5] '{0:N0}' ' %'
    $ui.MonPower.Text    = Format-Reading $g[6] '{0:N0}' ' W'
    $ui.MonCoreClk.Text  = Format-Reading $g[7] '{0:N0}' ' MHz'
    $ui.MonMemClk.Text   = Format-Reading $g[8] '{0:N0}' ' MHz'
    $ui.MonCpu.Text      = Format-Reading $r.Cpu '{0:N0}' ' %'
    $m = $r.Mem
    $ui.MonRam.Text      = if ($m[0] -ge 0) { (Tx '{0:N1} de {1:N0} GB') -f ($m[0] / 1024), ($m[1] / 1024) } else { 'Sem leitura' }
    $ui.MonNote.Text = if ($g[0] -eq 0) { 'O driver da placa escolhida na tela Início não respondeu. Confira se a marca está certa e se o driver está instalado.' }
                       else { 'A temperatura do processador não aparece porque o Windows só a entrega por drivers de baixo nível, que antivírus e anti-cheats costumam bloquear.' }
}

# O relogio so roda quando alguem precisa dele: a tela Monitor aberta, o overlay ou o alerta ligados.
function Update-SensorTimer {
    $need = ($script:Page -eq 'monitor') -or $script:Ov.On -or $script:Alert.On
    if ($need) { if (-not $script:MonTimer.IsEnabled) { $script:MonTimer.Start() } } else { $script:MonTimer.Stop() }
}

# ----- Overlay -----
function Get-OverlayWindow {
    if ($script:Ov.Win) { return $script:Ov.Win }
    $w = New-Xaml $OverlayXaml
    $el = @{}
    foreach ($n in 'Stats', 'Fps', 'Temp', 'Use', 'Cpu', 'Alert', 'AlertText') { $el[$n] = $w.FindName($n) }
    # A janela nasce escondida, ja sem aceitar clique nem foco, e so depois aparece.
    $helper = New-Object System.Windows.Interop.WindowInteropHelper $w
    $h = $helper.EnsureHandle()
    [void][Harle.Native]::MakeOverlay($h)
    $script:Ov.Win = $w; $script:Ov.El = $el; $script:Ov.Hwnd = $h
    return $w
}

function Stop-FpsFeed {
    $p = $script:Ov.Proc
    $script:Ov.Proc = $null
    if (-not $script:Hosted) { return }
    try { [Harle.Fps]::Stop() } catch { }
    if (-not $p) { return }
    try { if (-not $p.HasExited) { $p.Kill(); [void]$p.WaitForExit(2000) } } catch { }
    try { $p.Dispose() } catch { }
    # Encerrar o processo nao encerra a coleta do Windows que ele abriu; isto encerra.
    try { [void](Invoke-Native (Get-AssetPath 'PresentMon.exe') "--terminate_existing_session --session_name $($script:OverlaySession)") } catch { }
    $script:Backup.state['ovFeed'] = $false
    Save-Backup
}

# Modo 1: so o necessario para contar quadros (o mais leve). Modo 2: a mesma coleta completa da tela Medicao.
function Start-FpsFeed([int]$Mode) {
    Stop-FpsFeed
    $exe = Get-AssetPath 'PresentMon.exe'
    [void](Get-AssetPath 'PresentMon-LICENSE.txt')
    $light = if ($Mode -eq 1) { '--v1_metrics --no_track_gpu --no_track_input --no_track_display ' } else { '' }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = "--output_stdout $light--stop_existing_session --session_name $($script:OverlaySession)"
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    [void][Harle.Native]::KillWithParent($p.Handle)
    try { $p.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal } catch { }
    [Harle.Fps]::Ignore = [string[]]$script:FpsIgnore
    [Harle.Fps]::Start($p.StandardOutput)
    $script:Ov.Proc = $p; $script:Ov.Mode = $Mode; $script:Ov.Since = Get-Date; $script:Ov.FpsDead = $false
    $script:Backup.state['ovFeed'] = $true
    Save-Backup
    Write-Log "Overlay: contador de FPS ligado (modo $Mode)"
}

# Se nenhum quadro chegar em 8 segundos, troca para a coleta completa; se ainda assim nada, o overlay segue sem FPS.
function Test-FpsFeed {
    $o = $script:Ov
    if (-not $o.On -or $o.FpsDead) { return }
    $lines = [Harle.Fps]::Lines
    $gone = $false
    try { $gone = (-not $o.Proc) -or $o.Proc.HasExited } catch { $gone = $true }
    if ($gone -and $lines -gt 0) {
        # Funcionava e parou (alguem encerrou o PresentMon): religa, no maximo 3 vezes.
        $o.Restarts++
        if ($o.Restarts -le 3) { try { Start-FpsFeed $o.Mode } catch { $o.FpsDead = $true }; return }
        $o.FpsDead = $true; Stop-FpsFeed
        return
    }
    $quiet = ($lines -eq 0) -and (((Get-Date) - $o.Since).TotalSeconds -ge 8)
    if (-not $quiet -and -not $gone) { return }
    if ($o.Mode -eq 1) {
        Write-Log 'Overlay: sem quadros no modo leve, tentando a coleta completa'
        try { Start-FpsFeed 2 } catch { Write-Log "Overlay: $($_.Exception.Message)"; $o.FpsDead = $true }
        return
    }
    $o.FpsDead = $true
    Stop-FpsFeed
    Write-Log 'Overlay: o PresentMon nao entregou quadros; overlay sem FPS'
    Set-Status 'O overlay não conseguiu ler o FPS neste PC. Temperatura e uso continuam aparecendo.'
}

function Update-Overlay($r) {
    $o = $script:Ov
    $banner = ((Get-Date) -lt $o.BannerUntil)
    $show = $script:Hosted -and ($o.On -or $banner)
    if (-not $show) {
        if ($o.Win -and $o.Win.IsVisible) { $o.Win.Hide() }
        return
    }
    $w = Get-OverlayWindow
    $el = $o.El
    $el.Stats.Visibility = if ($o.On) { 'Visible' } else { 'Collapsed' }
    $el.Alert.Visibility = if ($banner) { 'Visible' } else { 'Collapsed' }
    if ($o.On -and $r) {
        Test-FpsFeed
        $fps = -1.0
        if (-not $o.FpsDead) { $fps = [double]([Harle.Fps]::Read([Harle.Native]::ForegroundPid())[0]) }
        $el.Fps.Text  = if ($fps -gt 0) { '{0:0}' -f $fps } else { '--' }
        $temp = [double]$r.G[1]
        $el.Temp.Text = if ($temp -ge 0) { '{0:0} °C' -f $temp } else { '--' }
        $el.Temp.Foreground = if ($script:Alert.Active) { $script:HotBrush } else { $script:CoolBrush }
        $el.Use.Text  = if ([double]$r.G[2] -ge 0) { '{0:0}%' -f [double]$r.G[2] } else { '--' }
        $el.Cpu.Text  = if ([double]$r.Cpu -ge 0) { '{0:0}%' -f [double]$r.Cpu } else { '--' }
    }
    if (-not $w.IsVisible) { $w.Show(); [void][Harle.Native]::MakeOverlay($o.Hwnd) }
    [void][Harle.Native]::PlaceOverlay($o.Hwnd, [int]$o.Corner, 12)
}

function Set-Overlay([bool]$On) {
    $o = $script:Ov
    if ($On -and -not $script:Hosted) { $On = $false }
    $o.On = $On
    if ($On) {
        $o.Restarts = 0
        try { Start-FpsFeed 1 } catch { $o.FpsDead = $true; Write-Log "Overlay: $($_.Exception.Message)" }
    } else {
        Stop-FpsFeed
    }
    $script:Backup.state['ovOn'] = $On
    $script:Backup.state['ovCorner'] = [int]$o.Corner
    Save-Backup
    Update-SensorTimer
    Update-Overlay (Read-Sensors)
    Update-GameTools
}

# ----- Alerta de temperatura -----
function Show-TempAlert([double]$Temp, [bool]$First) {
    $script:Ov.BannerUntil = (Get-Date).AddSeconds(10)
    [void](Get-OverlayWindow)
    $script:Ov.El.AlertText.Text = ((Tx 'Placa de vídeo a {0:0} °C, acima do limite de {1} °C') -f $Temp, $script:Alert.Limit)
    try { [System.Media.SystemSounds]::Exclamation.Play() } catch { }
    if ($First) { Write-Log ('Alerta de temperatura: {0:0} C (limite {1} C)' -f $Temp, $script:Alert.Limit) }
    Set-Status ((Tx 'A placa de vídeo está a {0:0} °C, acima do limite de {1} °C. Confira a ventilação do gabinete e a curva da ventoinha.') -f $Temp, $script:Alert.Limit)
}

function Set-TempAlert([bool]$On, [int]$Limit) {
    $a = $script:Alert
    if ($On -and -not $script:Hosted) { $On = $false }
    $a.Limit = [Math]::Max(60, [Math]::Min(95, $Limit))
    $a.On = $On
    $a.Hot = 0; $a.Active = $false
    $script:Ov.BannerUntil = [datetime]::MinValue
    $script:Backup.state['alertOn'] = $On
    $script:Backup.state['alertLimit'] = [int]$a.Limit
    Save-Backup
    Update-SensorTimer
    Update-GameTools
}

# Textos e botoes do cartao "Durante o jogo".
function Update-GameTools {
    $ui = $script:ui
    $o = $script:Ov; $a = $script:Alert
    $ui.OvToggle.IsChecked = [bool]$o.On
    $ui.AlertToggle.IsChecked = [bool]$a.On
    $ui.AlertValue.Text = "$($a.Limit) °C"
    foreach ($i in 0..3) { $ui["OvCorner$i"].IsChecked = ($i -eq [int]$o.Corner) }
    if (-not $script:Hosted) {
        $ui.OvNote.Text = 'Só no Harle.exe.'
        $ui.AlertNote.Text = 'Só no Harle.exe.'
        foreach ($n in 'OvToggle', 'AlertToggle', 'BtnAlertDown', 'BtnAlertUp', 'OvCorner0', 'OvCorner1', 'OvCorner2', 'OvCorner3') { $ui[$n].IsEnabled = $false }
        return
    }
    $ui.OvNote.Text = 'FPS, temperatura e uso da placa por cima do jogo, sem injetar nada nele. Funciona com o jogo em janela sem bordas; em tela cheia exclusiva ele não aparece. Pode somar um pouco de atraso de imagem, porque o Windows volta a compor a tela: em partida ranqueada, prefira desligado.'
    $ui.AlertNote.Text = (Tx 'Som do Windows e aviso na tela quando a placa de vídeo fica em {0} °C ou mais por 3 segundos seguidos, repetido a cada minuto enquanto continuar quente. Deixe o Harle aberto (pode minimizar).' ($($a.Limit)))
}

function Step-Sensors {
    $r = Read-Sensors
    if ($script:Page -eq 'monitor') { Update-Monitor $r }
    if (-not $r) { return }
    $temp = [double]$r.G[1]
    $what = Step-TempAlert $script:Alert $temp (Get-Date)
    if ($what -eq 'raise')      { Show-TempAlert $temp $true }
    elseif ($what -eq 'repeat') { Show-TempAlert $temp $false }
    elseif ($what -eq 'clear')  {
        $script:Ov.BannerUntil = [datetime]::MinValue
        Set-Status ((Tx 'A placa de vídeo voltou para {0:0} °C.') -f $temp)
    }
    Update-Overlay $r
}

$script:MonTimer.Add_Tick({ try { Step-Sensors } catch { Write-Log "Monitor: $($_.Exception.Message)" } })

# ----- Relatorio para pedir ajuda -----
function Set-ClipboardSafe($Data, [switch]$Image) {
    # A area de transferencia pode estar ocupada por outro programa por um instante; tenta de novo.
    for ($i = 0; $i -lt 5; $i++) {
        try {
            if ($Image) { [System.Windows.Clipboard]::SetImage($Data) } else { [System.Windows.Clipboard]::SetDataObject([string]$Data, $true) }
            return $true
        } catch { Start-Sleep -Milliseconds 80 }
    }
    return $false
}

function Copy-Report {
    $toggles = @(Get-Toggles -All)
    $on  = @($toggles | Where-Object { Get-TweakState $_ } | ForEach-Object { $_.Name })
    $off = @($toggles | Where-Object { -not (Get-TweakState $_) } | ForEach-Object { $_.Name })
    $fps = @($script:Backup.state['fps'] | Where-Object { $_ })
    $state = @{
        Profile = (Get-Profile).Label
        Gpu     = $(if ($script:GpuChoice -eq 'amd') { 'AMD' } else { 'NVIDIA' })
        Hosted  = $script:Hosted
        On = $on; Off = $off
        Fps = $(if ($fps.Count -gt 0) { $fps[$fps.Count - 1] } else { $null })
    }
    $log = @()
    try { if (Test-Path -LiteralPath $script:LogFile) { $log = @(Get-Content -LiteralPath $script:LogFile -Tail 40 -Encoding UTF8) } } catch { }
    $text = Get-ReportText $script:Specs $state $log
    if (Set-ClipboardSafe $text) { Set-Status (Tx 'Relatório copiado ({0} caracteres). Cole no Discord com Ctrl+V.' ($($text.Length))) }
    else { Set-Status 'Não consegui copiar agora, a área de transferência está ocupada. Tente de novo.' }
}

# ----- Cartao de resultado -----
function Format-Fps([double]$Value) {
    if ($Value -ge 100) { return ('{0:0}' -f $Value) }
    return ('{0:0.0}' -f $Value)
}

function New-ResultCard {
    $pair = Get-CardPair $script:Backup.state['fps']
    if (-not $pair) {
        Set-Status 'O cartão precisa de duas medições do mesmo jogo: uma antes de otimizar e outra depois, na mesma cena.'
        return
    }
    $b = $pair.Before; $a = $pair.After
    $card = New-Xaml $CardXaml
    $find = { param($n) $card.FindName($n) }
    (& $find 'Game').Text       = ([string]$a.App -replace '(?i)\.exe$', '')
    (& $find 'BeforeLabel').Text = (Tx 'ANTES  ·  {0} ajustes ativos' $b.Active)
    (& $find 'AfterLabel').Text  = (Tx 'DEPOIS  ·  {0} ajustes ativos' ($($a.Active)))
    (& $find 'BeforeAvg').Text  = Format-Fps ([double]$b.Avg)
    (& $find 'AfterAvg').Text   = Format-Fps ([double]$a.Avg)
    (& $find 'BeforeLow').Text  = "1% low: $(Format-Fps ([double]$b.Low)) FPS"
    $lowGain = Format-Gain ([double]$b.Low) ([double]$a.Low)
    (& $find 'AfterLow').Text   = (Tx '1% low: {0} FPS' ($(Format-Fps ([double]$a.Low)))) + $(if ($lowGain) { "  ($lowGain)" } else { '' })
    (& $find 'Gain').Text       = Format-Gain ([double]$b.Avg) ([double]$a.Avg)
    $s = $script:Specs
    $parts = @()
    if ($s -and $s.Cpu) { $parts += $s.Cpu.Short }
    if ($s -and @($s.Gpus).Count -gt 0) { $g = $s.Gpus[0]; $parts += $(if ($g.VramGB -gt 0) { "$($g.Short) $($g.VramGB) GB" } else { $g.Short }) }
    if ($s -and $s.Ram) { $parts += ("$($s.Ram.TotalGB) GB $($s.Ram.Type)").Trim() }
    (& $find 'Pc').Text   = ($parts -join '  ·  ')
    (& $find 'How').Text  = (Tx 'Medido com PresentMon, 60 segundos por medição. Antes: {0}. Depois: {1}.' ($($b.When)) ($($a.When)))
    (& $find 'Link').Text = ($script:DiscordUrl -replace '^https?://', '')
    if ($script:LogoBrush) {
        (& $find 'Logo').Background = $script:LogoBrush
        (& $find 'LogoMark').Visibility = 'Collapsed'
    }
    $size = New-Object System.Windows.Size 1200, 630
    $card.Measure($size)
    $card.Arrange((New-Object System.Windows.Rect $size))
    $card.UpdateLayout()
    $bmp = New-Object System.Windows.Media.Imaging.RenderTargetBitmap 1200, 630, 96, 96, ([System.Windows.Media.PixelFormats]::Pbgra32)
    $bmp.Render($card)
    $bmp.Freeze()
    $dir = [Environment]::GetFolderPath('MyPictures')
    if (-not $dir -or -not (Test-Path -LiteralPath $dir)) { $dir = [Environment]::GetFolderPath('Desktop') }
    $file = Join-Path $dir 'Harle - resultado.png'
    $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bmp))
    $fs = [IO.File]::Create($file)
    try { $enc.Save($fs) } finally { $fs.Dispose() }
    $copied = Set-ClipboardSafe $bmp -Image
    Write-Log "Cartao de resultado salvo em $file"
    try { Start-Process -FilePath 'explorer.exe' -ArgumentList "/select,`"$file`"" } catch { }
    $extra = if ($copied) { ' e copiado: cole no Discord com Ctrl+V' } else { '' }
    Set-Status (Tx 'Cartão salvo em {0}{1}.' ($file) (Tr $extra))
}

# ----- Avancado: overclock (so NVIDIA) -----
# Tetos do proprio Harle, por cima da faixa do driver, para ninguem pular direto para um valor absurdo.
$script:Oc = @{ Ok = $false; Core = 0; Mem = 0; CoreMax = 0; MemMax = 0; CoreCap = 300; MemCap = 1500; CoreStep = 10; MemStep = 50; Why = '' }

function Read-Oc {
    $o = $script:Oc
    $o.Ok = $false
    if (-not $script:Hosted) { $o.Why = 'O overclock só existe no Harle.exe.'; return }
    if ($script:GpuChoice -ne 'nvidia' -or -not (Test-Nvidia)) { $o.Why = 'Por enquanto o overclock do Harle só funciona em placas NVIDIA. Para placas AMD, use o Adrenalin.'; return }
    $r = [Harle.Nvidia]::OcRead()
    if ($r[0] -ne 0) { $o.Why = (Tx 'O driver não entregou os clocks desta placa (código {0}).' ($($r[0]))); return }
    if ($r[1] -eq 0 -and $r[5] -eq 0) { $o.Why = 'O driver não permite mudar os clocks desta placa. É comum em notebooks.'; return }
    $o.Core    = [int][Math]::Round($r[2] / 1000.0)
    $o.Mem     = [int][Math]::Round($r[6] / 1000.0)
    $o.CoreMax = if ($r[1] -ne 0) { [int][Math]::Min($o.CoreCap, [Math]::Floor($r[4] / 1000.0)) } else { 0 }
    $o.MemMax  = if ($r[5] -ne 0) { [int][Math]::Min($o.MemCap,  [Math]::Floor($r[8] / 1000.0)) } else { 0 }
    $o.Ok = $true
    $o.Why = ''
}

function Update-OcView([switch]$Read) {
    $ui = $script:ui
    $o = $script:Oc
    if ($Read) { Read-Oc; $script:OcWanted = @{ Core = [Math]::Max(0, $o.Core); Mem = [Math]::Max(0, $o.Mem) } }
    $agree = [bool]$ui.OcAgree.IsChecked
    $ui.OcPanel.IsEnabled = ($agree -and $o.Ok -and -not $script:Busy)
    $ui.OcPanel.Opacity = if ($ui.OcPanel.IsEnabled) { 1 } else { 0.45 }
    if (-not $o.Ok) {
        $ui.OcInfo.Text = $o.Why
        $ui.OcState.Text = ''
        return
    }
    $ui.OcInfo.Text = 'O valor é somado ao clock de fábrica. Nada muda até você clicar em Aplicar, e o que for aplicado vale só até reiniciar o PC.'
    $ui.OcCoreValue.Text = "+$($script:OcWanted.Core) MHz"
    $ui.OcMemValue.Text  = "+$($script:OcWanted.Mem) MHz"
    $ui.OcCoreLimit.Text = (Tx 'Passos de {0} MHz, até +{1} MHz' ($($o.CoreStep)) ($($o.CoreMax)))
    $ui.OcMemLimit.Text  = (Tx 'Passos de {0} MHz, até +{1} MHz' ($($o.MemStep)) ($($o.MemMax)))
    $ui.OcState.Text = (Tx 'Na placa agora: núcleo +{0} MHz, memória +{1} MHz.' ($($o.Core)) ($($o.Mem)))
}

function Step-Oc([string]$Which, [int]$Direction) {
    $o = $script:Oc
    if (-not $o.Ok) { return }
    if ($Which -eq 'Core') { $script:OcWanted.Core = [Math]::Max(0, [Math]::Min($o.CoreMax, $script:OcWanted.Core + $Direction * $o.CoreStep)) }
    else                   { $script:OcWanted.Mem  = [Math]::Max(0, [Math]::Min($o.MemMax,  $script:OcWanted.Mem  + $Direction * $o.MemStep)) }
    Update-OcView
}

function Set-Oc([int]$CoreMHz, [int]$MemMHz) {
    $o = $script:Oc
    if (-not $o.Ok -or $script:Busy) { return }
    $CoreMHz = [Math]::Max(0, [Math]::Min($o.CoreMax, $CoreMHz))
    $MemMHz  = [Math]::Max(0, [Math]::Min($o.MemMax,  $MemMHz))
    $a = 0; $b = 0
    if ($o.CoreMax -gt 0 -or $CoreMHz -eq 0) { $a = [Harle.Nvidia]::OcWrite(0, $CoreMHz * 1000) }
    if ($o.MemMax  -gt 0 -or $MemMHz  -eq 0) { $b = [Harle.Nvidia]::OcWrite(4, $MemMHz * 1000) }
    Write-Log "Overclock: nucleo +$CoreMHz MHz (codigo $a), memoria +$MemMHz MHz (codigo $b)"
    Update-OcView -Read
    if (($a -eq 0 -or $a -eq -3) -and ($b -eq 0 -or $b -eq -3)) { Set-Status (Tx 'Clocks aplicados: núcleo +{0} MHz, memória +{1} MHz. Teste em jogo antes de subir mais.' ($($script:Oc.Core)) ($($script:Oc.Mem))) }
    else { Set-Status (Tx 'A placa recusou o valor (códigos {0} e {1}). Nada além do que aparece na tela foi alterado.' ($a) ($b)) }
}

# ----- Scanner na tela -----
function Add-Row($Panel, [string]$Key, [string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return }
    $row = New-Xaml $RowXaml
    $row.FindName('K').Text = $Key
    $row.FindName('V').Text = $Value
    [void]$Panel.Children.Add($row)
}

function Add-SpecCard([int]$Glyph, [string]$Label, [string]$Value, $Rows) {
    $card = New-Xaml $SpecXaml
    $card.FindName('Icon').Text  = [string][char]$Glyph
    $card.FindName('Label').Text = $Label
    $card.FindName('Value').Text = $Value
    $panel = $card.FindName('Rows')
    foreach ($r in $Rows) { Add-Row $panel $r[0] ([string]$r[1]) }
    $weight = 3 + @($Rows).Count
    if ($script:SpecWeightA -le $script:SpecWeightB) { [void]$script:ui.SpecColA.Children.Add($card); $script:SpecWeightA += $weight }
    else                                             { [void]$script:ui.SpecColB.Children.Add($card); $script:SpecWeightB += $weight }
}

function Update-SpecViews {
    $s = $script:Specs
    $ui = $script:ui
    $ui.SpecColA.Children.Clear(); $ui.SpecColB.Children.Clear()
    $script:SpecWeightA = 0; $script:SpecWeightB = 0
    $ui.DiagList.Children.Clear()
    $onOff = { param($b) if ($b) { 'Ligado' } else { 'Desligado' } }

    if ($s.Cpu) {
        $ui.HomeCpu.Text = $s.Cpu.Short
        Add-SpecCard 0xE950 'Processador' $s.Cpu.Short @(
            @('Modelo', $s.Cpu.Name),
            @('Núcleos e threads', (Tx '{0} núcleos, {1} threads' $s.Cpu.Cores $s.Cpu.Threads)),
            @('Frequência base', ('{0:N1} GHz' -f ($s.Cpu.MHz / 1000)))
        )
    } else { $ui.HomeCpu.Text = 'Não identificado' }

    if ($s.Gpus.Count -gt 0) {
        $g = $s.Gpus[0]
        $ui.HomeGpu.Text = if ($g.VramGB -gt 0) { "$($g.Short), $($g.VramGB) GB" } else { $g.Short }
        foreach ($g in $s.Gpus) {
            $date = if ($g.DriverDate) { $g.DriverDate.ToString('dd/MM/yyyy') } else { '' }
            $vram = if ($g.VramGB -gt 0) { "$($g.VramGB) GB" } else { '' }
            Add-SpecCard 0xE7FC 'Placa de vídeo' $g.Short @(
                @('Modelo', $g.Name), @('Memória de vídeo', $vram), @('Driver', $g.Driver), @('Data do driver', $date)
            )
        }
    } else { $ui.HomeGpu.Text = 'Não identificada' }

    if ($s.Ram) {
        $r = $s.Ram
        $ui.HomeRam.Text = ("$($r.TotalGB) GB $($r.Type)").Trim()
        $slots = if ($r.Slots -gt 0) { (Tx '{0} de {1} slots ocupados' $r.Sticks $r.Slots) } else { (Tx '{0} pentes' $r.Sticks) }
        Add-SpecCard 0xE9E9 'Memória RAM' "$($r.TotalGB) GB $($r.Type)" @(
            @('Velocidade atual', $(if ($r.Speed -gt 0) { "$($r.Speed) MHz" } else { '' })),
            @('Pentes', $slots), @('Módulo', $r.Part)
        )
    } else { $ui.HomeRam.Text = 'Não identificada' }

    if ($s.Disks.Count -gt 0) {
        $total = ($s.Disks | ForEach-Object { $_.Bytes } | Measure-Object -Sum).Sum
        $ui.HomeDisk.Text = $(if ($s.Disks.Count -eq 1) { (Tx '{0} em 1 disco' (Format-Capacity $total)) } else { (Tx '{0} em {1} discos' (Format-Capacity $total) $s.Disks.Count) })
        $rows = @()
        foreach ($d in $s.Disks) { $rows += , @($d.Kind, "$($d.Name), $(Format-Capacity $d.Bytes)") }
        foreach ($v in $s.Vols)  { $rows += , @((Tx 'Unidade {0}' $v.Letter), ((Tx '{0:N0} GB livres de {1:N0} GB') -f ($v.Free / 1GB), ($v.Size / 1GB))) }
        Add-SpecCard 0xEDA2 'Armazenamento' (Format-Capacity $total) $rows
    } else { $ui.HomeDisk.Text = 'Não identificado' }

    if ($s.Display) {
        $d = $s.Display
        $max = if ($d.MaxHz -gt 0) { "$($d.MaxHz) Hz" } else { '' }
        Add-SpecCard 0xE7F4 'Monitor' "$($d.W) x $($d.H) a $($d.Hz) Hz" @(
            @('Resolução', "$($d.W) x $($d.H)"), @('Taxa em uso', "$($d.Hz) Hz"), @('Máxima neste modo', $max)
        )
    }
    if ($s.Board) {
        $bd = if ($s.Board.BiosDate) { $s.Board.BiosDate.ToString('dd/MM/yyyy') } else { '' }
        Add-SpecCard 0xE9F5 'Placa-mãe' $s.Board.Model @(
            @('Fabricante', $s.Board.Maker), @('Versão da BIOS', $s.Board.Bios), @('Data da BIOS', $bd)
        )
    }
    if ($s.Os) {
        $up = if ($s.Os.Boot) { $ts = (Get-Date) - $s.Os.Boot; '{0} d {1} h' -f [int][Math]::Floor($ts.TotalDays), $ts.Hours } else { '' }
        Add-SpecCard 0xE770 'Sistema' $s.Os.Name @(
            @('Versão', "$($s.Os.Version) (build $($s.Os.Build))"), @('Arquitetura', $s.Os.Arch), @('Ligado há', $up)
        )
    }
    $planTitle = if ($s.Sys.Plan) { $s.Sys.Plan } else { 'Windows' }
    Add-SpecCard 0xE945 'Estado para jogos' $planTitle @(
        @('Plano de energia', $s.Sys.Plan),
        @('Modo de Jogo', (& $onOff $s.Sys.GameMode)),
        @('Agendamento de GPU', (& $onOff $s.Sys.Hags)),
        @('Integridade de Memória', (& $onOff $s.Sys.Hvci))
    )

    $colors = @{ warn = 'Amber'; ok = 'Ice'; info = 'Muted' }
    $diag = @(Get-Diagnostics $s)
    if ($diag.Count -eq 0) { $diag = @(@{ Level = 'ok'; Title = 'Nada fora do lugar'; Text = 'O scanner não encontrou gargalos de configuração neste PC.' }) }
    $order = @{ warn = 0; info = 1; ok = 2 }
    foreach ($d in ($diag | Sort-Object { $order[$_.Level] })) {
        $row = New-Xaml $DiagXaml
        $row.FindName('Dot').Fill   = $script:Window.FindResource($colors[$d.Level])
        $row.FindName('Title').Text = $d.Title
        $row.FindName('Body').Text  = $d.Text
        [void]$ui.DiagList.Children.Add($row)
    }
}

function Invoke-Scan {
    Set-Status 'Lendo o hardware...'
    $script:Specs = Get-Specs
    Update-SpecViews
    try { Update-BiosBadge } catch { Write-Log "BIOS: $($_.Exception.Message)" }
    Set-Status 'Scanner concluído.'
}

# ----- Cartao usado nas abas Upgrade e BIOS -----
function New-PlanCard($Item, [string]$Label, [string]$Back, [string]$Fore) {
    $card = New-Xaml $UpXaml
    $card.FindName('TagText').Text = $Label
    $card.FindName('Tag').Background = $script:Window.FindResource($Back)
    $card.FindName('TagText').Foreground = $script:Window.FindResource($Fore)
    $card.FindName('Part').Text  = [string]$Item.Part
    $card.FindName('Title').Text = [string]$Item.Title
    $card.FindName('Why').Text   = [string]$Item.Why
    $rows = $card.FindName('Rows')
    foreach ($r in @($Item.Rows)) {
        if (-not $r) { continue }
        $row = New-Xaml $RowXaml
        $row.Margin = New-Object System.Windows.Thickness 0, 5, 0, 5
        $row.ColumnDefinitions[0].Width = New-Object System.Windows.GridLength 150
        $k = $row.FindName('K'); $k.Text = [string]$r[0]; $k.TextWrapping = 'Wrap'; $k.Margin = New-Object System.Windows.Thickness 0, 0, 14, 0
        $k.Foreground = $script:Window.FindResource('Text')
        $v = $row.FindName('V'); $v.Text = [string]$r[1]; $v.LineHeight = 18.5
        $v.Foreground = $script:Window.FindResource('Muted')
        [void]$rows.Children.Add($row)
    }
    return $card
}

# ----- Upgrade -----
function Update-UpgradeView {
    $panel = $script:ui.UpList
    $panel.Children.Clear()
    $plan = Get-UpgradePlan $script:Specs
    $head = New-Xaml $GuideXaml
    $head.FindName('Title').Text = $plan.Headline
    $head.FindName('Intro').Text = (Tx 'A ordem abaixo vai do que rende mais para o que rende menos. As comparações são estimativas pelo modelo das peças, não uma medição deste PC. Os modelos citados são exemplos de {0}: preço e estoque mudam, compare antes de comprar.' (Tr $script:UpgradeDate))
    [void]$panel.Children.Add($head)
    $tags = @{
        free  = @('GRÁTIS', 'Ice', 'Ink');        now  = @('PRIORIDADE', 'Heat', 'Ink')
        later = @('VALE A PENA', 'PanelHi', 'Amber'); ok = @('ESTÁ BOM', 'PanelHi', 'Muted'); info = @('SAIBA', 'PanelHi', 'Muted')
    }
    $n = 0
    foreach ($it in $plan.Items) {
        $tag = $tags[[string]$it.Level]
        if (-not $tag) { $tag = $tags['info'] }
        $label = $tag[0]
        if ($it.Level -eq 'now' -or $it.Level -eq 'later') { $n++; $label = "$n  ·  $label" }
        [void]$panel.Children.Add((New-PlanCard $it $label $tag[1] $tag[2]))
    }
}

# ----- BIOS -----
function Update-BiosBadge {
    $plan = Get-BiosPlan $script:Specs
    $script:BiosPending = [int]$plan.Pending
    $script:ui.NavBios.Content = if ($plan.Pending -gt 0) { "BIOS  ($($plan.Pending))" } else { 'BIOS' }
}

function Update-BiosView {
    $panel = $script:ui.BiosList
    $panel.Children.Clear()
    $plan = Get-BiosPlan $script:Specs
    $head = New-Xaml $GuideXaml
    $head.FindName('Title').Text = $plan.Headline
    $head.FindName('Intro').Text = (Tx 'A BIOS é onde ficam os maiores ganhos gratuitos, e nenhum programa confiável consegue mudá-la de dentro do Windows: é você quem faz, uma vez só. Para entrar, reinicie e aperte {0} assim que a tela acender, ou use o botão abaixo. Mude um item por vez e salve com F10. Se algo der errado, a opção Load Optimized Defaults devolve tudo ao padrão.' ($($plan.Key)))
    $b = New-Object System.Windows.Controls.Button
    $b.Style = $script:Window.FindResource('Primary')
    $b.Content = 'Reiniciar e abrir a BIOS'
    $b.FontSize = 13
    $b.Padding = New-Object System.Windows.Thickness 18, 10, 18, 10
    $b.HorizontalAlignment = 'Left'
    $b.Margin = New-Object System.Windows.Thickness 0, 4, 0, 6
    $b.IsEnabled = -not $plan.Legacy
    $b.Add_Click({
        try {
            if ($script:Busy) { return }
            if ($script:RestartPending) { Stop-Restart } else { Start-Restart 20 -Firmware }
        } catch { Show-Error $_ }
    })
    [void]$head.FindName('Rows').Children.Add($b)
    $note = New-Object System.Windows.Controls.TextBlock
    $note.TextWrapping = 'Wrap'
    $note.FontSize = 12
    $note.Foreground = $script:Window.FindResource('Muted')
    $note.Margin = New-Object System.Windows.Thickness 0, 0, 0, 6
    $note.Text = if ($plan.Legacy) { 'O botão só funciona com o Windows em modo UEFI. Neste PC, entre pela tecla ao ligar.' }
                 else { 'O PC reinicia em 20 segundos e abre direto na BIOS, sem precisar acertar a tecla. Salve o que estiver aberto antes; para desistir, clique de novo no botão.' }
    [void]$head.FindName('Rows').Children.Add($note)
    [void]$panel.Children.Add($head)
    $tags = @{
        do  = @('FAÇA AGORA', 'Heat', 'Ink');       check = @('IMPORTANTE', 'PanelHi', 'Amber')
        opt = @('OPCIONAL', 'PanelHi', 'Muted');    ok    = @('JÁ ESTÁ', 'PanelHi', 'Ice');   info = @('SAIBA', 'PanelHi', 'Muted')
    }
    foreach ($it in $plan.Items) {
        $tag = $tags[[string]$it.Level]
        if (-not $tag) { $tag = $tags['info'] }
        [void]$panel.Children.Add((New-PlanCard $it $tag[0] $tag[1] $tag[2]))
    }
    Register-Tr $panel
    $script:BiosPending = [int]$plan.Pending
    $script:ui.NavBios.Content = if ($plan.Pending -gt 0) { "BIOS  ($($plan.Pending))" } else { 'BIOS' }
}

# ----- Saude do PC -----
$script:Health = $null
$script:HealthImage = ''

function Invoke-HealthScan {
    if ($script:Busy) { return }
    Set-Busy $true
    try {
        Set-Status 'Lendo os registros do Windows e o estado dos discos...'
        $r = @(Invoke-Background $script:HealthCode $null)
        $script:Health = if ($r.Count -gt 0) { $r[$r.Count - 1] } else { $null }
        Set-Status 'Verificação de saúde concluída.'
    } catch { Show-Error $_ } finally { Set-Busy $false }
}

function Invoke-ImageCheck([bool]$Repair) {
    if ($script:Busy) { return }
    Set-Busy $true
    try {
        Set-Status $(if ($Repair) { 'Reparando os arquivos do Windows. Pode levar de 10 a 30 minutos e precisa de internet; a janela continua respondendo.' } else { 'Verificando os arquivos do Windows. Pode levar alguns minutos.' })
        $r = @(Invoke-Background $script:ImageScanCode @{ Repair = $Repair })
        $line = if ($r.Count -gt 0) { [string]$r[$r.Count - 1] } else { 'erro|sem resposta' }
        Write-Log "Imagem do Windows: $line"
        $f = $line.Split('|')
        $script:HealthImage = $line
        if ($f[0] -eq 'erro') { Set-Status (Tx 'A verificação não terminou: {0}' ($($f[1]))) }
        elseif ($f[0] -eq 'repaired') { Set-Status 'Reparo concluído. Reinicie o PC para terminar.' }
        elseif ($f[1] -eq 'Healthy') { Set-Status 'Os arquivos do Windows estão íntegros.' }
        elseif ($f[1] -eq 'Repairable') { Set-Status 'Há arquivos do Windows corrompidos que dá para reparar. Clique em Reparar os arquivos do Windows.' }
        else { Set-Status (Tx 'Resultado da verificação: {0}' ($($f[1]))) }
    } catch { Show-Error $_ } finally { Set-Busy $false }
    Update-HealthView
}

function Update-HealthView {
    $panel = $script:ui.HealthList
    $panel.Children.Clear()
    $plan = Get-HealthPlan $script:Health $script:Specs
    $head = New-Xaml $GuideXaml
    $head.FindName('Title').Text = $plan.Headline
    $head.FindName('Intro').Text = "O que o Windows registrou nos últimos 30 dias, mais o estado que os discos e a bateria informam. Depois de mexer em XMP, PBO ou overclock, volte aqui para ver se apareceram erros."
    $bar = New-Object System.Windows.Controls.WrapPanel
    $bar.Margin = New-Object System.Windows.Thickness 0, 4, 0, 6
    $mk = {
        param([string]$Text, [string]$Style, $Action)
        $b = New-Object System.Windows.Controls.Button
        $b.Style = $script:Window.FindResource($Style)
        $b.Content = $Text
        $b.FontSize = 12.5
        $b.Padding = New-Object System.Windows.Thickness 14, 8, 14, 8
        $b.Margin = New-Object System.Windows.Thickness 0, 0, 10, 6
        $b.IsEnabled = -not $script:Busy
        $b.Add_Click($Action)
        [void]$bar.Children.Add($b)
    }
    & $mk 'Verificar os arquivos do Windows' 'Ghost' { try { Invoke-ImageCheck $false } catch { Show-Error $_ } }
    if ($script:HealthImage -match '^scan\|Repairable') { & $mk 'Reparar os arquivos do Windows' 'Primary' { try { Invoke-ImageCheck $true } catch { Show-Error $_ } } }
    & $mk 'Testar a memória (reinicia o PC)' 'Ghost' {
        try {
            # A Ferramenta de Diagnostico de Memoria do Windows pergunta antes de reiniciar.
            Start-Process -FilePath (Join-Path $env:WINDIR 'System32\mdsched.exe')
            Set-Status 'Escolha "Reiniciar agora e verificar se há problemas". O teste leva uns 15 minutos e o resultado aparece aqui depois.'
        } catch { Show-Error $_ }
    }
    [void]$head.FindName('Rows').Children.Add($bar)
    if ($script:HealthImage) {
        $f = $script:HealthImage.Split('|')
        $txt = switch ($f[0]) {
            'scan'     { switch ($f[1]) { 'Healthy' { 'Última verificação dos arquivos do Windows: íntegros.' } 'Repairable' { 'Última verificação: há arquivos corrompidos, e dá para reparar.' } default { (Tx 'Última verificação: {0}.' ($($f[1]))) } } }
            'repaired' { 'Os arquivos do Windows foram reparados. Reinicie o PC.' }
            default    { (Tx 'A última verificação não terminou: {0}' ($($f[1]))) }
        }
        $t = New-Object System.Windows.Controls.TextBlock
        $t.Text = $txt
        $t.TextWrapping = 'Wrap'
        $t.FontSize = 12
        $t.Foreground = $script:Window.FindResource('Muted')
        [void]$head.FindName('Rows').Children.Add($t)
    }
    [void]$panel.Children.Add($head)
    $tags = @{ bad = @('PROBLEMA', 'Bad', 'Ink'); warn = @('ATENÇÃO', 'PanelHi', 'Amber'); info = @('SAIBA', 'PanelHi', 'Muted'); ok = @('TUDO CERTO', 'PanelHi', 'Ice') }
    foreach ($it in $plan.Items) {
        $tag = $tags[[string]$it.Level]
        if (-not $tag) { $tag = $tags['info'] }
        [void]$panel.Children.Add((New-PlanCard $it $tag[0] $tag[1] $tag[2]))
    }
    Register-Tr $panel
}

# ----- Discos -----
$script:Disks = $null
$script:DiskSel = 0

function Invoke-DiskScan {
    if ($script:Busy) { return }
    Set-Busy $true
    try {
        Set-Status 'Lendo o S.M.A.R.T. dos discos...'
        $r = @(Invoke-Background $script:DiskCode $null)
        $script:Disks = if ($r.Count -gt 0) { @($r[$r.Count - 1]) } else { @() }
        foreach ($d in $script:Disks) { if ($d.SmartError) { Write-Log "SMART do disco $($d.Number) ($($d.Name)): $($d.SmartError)" } }
        Set-Status (Tx 'Leitura concluída: {0}.' (Get-Plural $script:Disks.Count 'disco' 'discos'))
    } catch { Show-Error $_ } finally { Set-Busy $false }
}

function Get-DiskBrush([string]$Status) {
    $c = switch ($Status) { 'good' { '#6FE3C8' } 'caution' { '#FFD166' } 'bad' { '#FF8A7A' } default { '#8F9BB0' } }
    return (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($c)))
}

function New-DiskText([string]$Text, [double]$Size, [string]$Brush) {
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $Text
    $t.FontSize = $Size
    $t.TextWrapping = 'Wrap'
    $t.Foreground = $script:Window.FindResource($Brush)
    return $t
}

# Linha da tabela de atributos: mesmas colunas em todas as linhas, como uma grade.
function New-DiskRow([string[]]$Cells, [double[]]$Widths, [string]$Level, [bool]$Head) {
    $g = New-Object System.Windows.Controls.Grid
    $g.Margin = New-Object System.Windows.Thickness 0, 0, 0, 0
    if (-not $Head) { $g.Background = $script:Window.FindResource($(if ($script:DiskZebra) { 'Panel' } else { 'PanelHi' })); $script:DiskZebra = -not $script:DiskZebra }
    $c0 = New-Object System.Windows.Controls.ColumnDefinition; $c0.Width = New-Object System.Windows.GridLength 22; $g.ColumnDefinitions.Add($c0)
    foreach ($w in $Widths) {
        $c = New-Object System.Windows.Controls.ColumnDefinition
        $c.Width = if ($w -le 0) { New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star) } else { New-Object System.Windows.GridLength $w }
        $g.ColumnDefinitions.Add($c)
    }
    if (-not $Head) {
        $dot = New-Object System.Windows.Shapes.Ellipse
        $dot.Width = 8; $dot.Height = 8; $dot.Margin = New-Object System.Windows.Thickness 8, 0, 0, 0; $dot.VerticalAlignment = 'Center'; $dot.HorizontalAlignment = 'Left'
        $dot.Fill = Get-DiskBrush $(switch ($Level) { 'bad' { 'bad' } 'warn' { 'caution' } default { 'good' } })
        $g.Children.Add($dot) | Out-Null
    }
    for ($i = 0; $i -lt $Cells.Count; $i++) {
        $t = New-DiskText $Cells[$i] 12 $(if ($Head) { 'Muted' } else { 'Text' })
        $t.TextWrapping = 'NoWrap'; $t.TextTrimming = 'CharacterEllipsis'
        $t.Margin = New-Object System.Windows.Thickness 8, 5, 8, 5
        if ($i -ne 1) { $t.TextAlignment = $(if ($i -eq 0) { 'Left' } else { 'Right' }) }
        if ($Head) { $t.FontWeight = 'SemiBold'; $t.FontSize = 11 }
        [System.Windows.Controls.Grid]::SetColumn($t, $i + 1)
        $g.Children.Add($t) | Out-Null
    }
    return $g
}

function Update-DiskView {
    $panel = $script:ui.DiskList
    $panel.Children.Clear()
    $list = @($script:Disks)
    if ($null -eq $script:Disks) { return }
    if ($list.Count -eq 0) {
        $head = New-Xaml $GuideXaml
        $head.FindName('Title').Text = 'Nenhum disco encontrado'
        $head.FindName('Intro').Text = 'O Windows não informou nenhum disco. Clique em Ler de novo.'
        [void]$panel.Children.Add($head); Register-Tr $panel; return
    }
    if ($script:DiskSel -ge $list.Count) { $script:DiskSel = 0 }
    # Seletor no topo, como os botoes de disco do CrystalDiskInfo: estado, temperatura e letras.
    $bar = New-Object System.Windows.Controls.WrapPanel
    $bar.Margin = New-Object System.Windows.Thickness 0, 0, 0, 10
    for ($i = 0; $i -lt $list.Count; $i++) {
        $d = $list[$i]; $rp = Get-DiskReport $d
        $b = New-Object System.Windows.Controls.RadioButton
        $b.Style = $script:Window.FindResource('Seg')
        $b.GroupName = 'DiskSel'
        $b.Margin = New-Object System.Windows.Thickness 0, 0, 8, 6
        $sp = New-Object System.Windows.Controls.StackPanel; $sp.Orientation = 'Horizontal'
        $dot = New-Object System.Windows.Shapes.Ellipse; $dot.Width = 9; $dot.Height = 9; $dot.Fill = Get-DiskBrush $rp.Status; $dot.Margin = New-Object System.Windows.Thickness 0, 0, 7, 0; $dot.VerticalAlignment = 'Center'
        [void]$sp.Children.Add($dot)
        $lbl = (Tr (Get-DiskStatusLabel $rp.Status))
        if ($rp.Temp -gt 0) { $lbl += "  $($rp.Temp) °C" }
        $where = if (@($d.Letters).Count -gt 0) { (@($d.Letters) -join ' ') } else { (Tx 'Disco {0}' ($d.Number)) }
        $t = New-Object System.Windows.Controls.TextBlock; $t.Text = "$lbl  ·  $where"; $t.VerticalAlignment = 'Center'
        [void]$sp.Children.Add($t)
        $b.Content = $sp
        $b.ToolTip = $d.Name
        $b.Tag = $i
        $b.IsChecked = ($i -eq $script:DiskSel)
        $b.Add_Checked({ param($s, $e) try { $script:DiskSel = [int]$s.Tag; Update-DiskView } catch { Show-Error $_ } })
        [void]$bar.Children.Add($b)
    }
    [void]$panel.Children.Add($bar)

    $d = $list[$script:DiskSel]
    $rp = Get-DiskReport $d
    $card = New-Xaml $GuideXaml
    $title = $d.Name
    if ($d.Bytes -gt 0) { $title += "  ·  " + (Format-Capacity $d.Bytes) }
    $card.FindName('Title').Text = $title
    $card.FindName('Intro').Visibility = 'Collapsed'
    $grid = New-Object System.Windows.Controls.Grid
    $grid.Margin = New-Object System.Windows.Thickness 0, 10, 0, 4
    $ca = New-Object System.Windows.Controls.ColumnDefinition; $ca.Width = New-Object System.Windows.GridLength 190; $grid.ColumnDefinitions.Add($ca)
    $cb = New-Object System.Windows.Controls.ColumnDefinition; $cb.Width = New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star); $grid.ColumnDefinitions.Add($cb)
    $left = New-Object System.Windows.Controls.StackPanel
    $left.Margin = New-Object System.Windows.Thickness 0, 0, 22, 0
    $mkBox = {
        param([string]$Cap, [string]$Big, [string]$Small, $Brush)
        $bx = New-Object System.Windows.Controls.Border
        $bx.CornerRadius = New-Object System.Windows.CornerRadius 10
        $bx.BorderThickness = New-Object System.Windows.Thickness 2
        $bx.BorderBrush = $Brush
        $bx.Background = $script:Window.FindResource('PanelHi')
        $bx.Padding = New-Object System.Windows.Thickness 12, 9, 12, 10
        $bx.Margin = New-Object System.Windows.Thickness 0, 0, 0, 10
        $st = New-Object System.Windows.Controls.StackPanel
        $c = New-DiskText $Cap 11 'Muted'; $c.TextAlignment = 'Center'; [void]$st.Children.Add($c)
        $g = New-DiskText $Big 26 'Text'; $g.Foreground = $Brush; $g.FontFamily = 'Bahnschrift, Segoe UI'; $g.FontWeight = 'SemiBold'; $g.TextAlignment = 'Center'; [void]$st.Children.Add($g)
        if ($Small) { $m = New-DiskText $Small 14 'Text'; $m.TextAlignment = 'Center'; [void]$st.Children.Add($m) }
        $bx.Child = $st
        [void]$left.Children.Add($bx)
    }
    & $mkBox 'Estado de saúde' (Tr (Get-DiskStatusLabel $rp.Status)) $(if ($rp.Pct -ge 0) { "$($rp.Pct) %" } else { '' }) (Get-DiskBrush $rp.Status)
    $hot = if ($rp.Ssd) { 70 } else { 55 }
    $tst = if ($rp.Temp -lt 0) { 'unknown' } elseif ($rp.Temp -ge $hot) { 'bad' } elseif ($rp.Temp -ge $hot - 10) { 'caution' } else { 'good' }
    & $mkBox 'Temperatura' $(if ($rp.Temp -gt 0) { "$($rp.Temp) °C" } else { '--' }) '' (Get-DiskBrush $tst)
    [System.Windows.Controls.Grid]::SetColumn($left, 0)
    [void]$grid.Children.Add($left)

    $info = New-Object System.Windows.Controls.StackPanel
    $kind = if ($d.Bus -eq 'NVMe') { 'SSD NVMe' } elseif ($d.Media -eq 'SSD') { 'SSD' } elseif ($d.Media -eq 'HDD') { 'HD' } else { [string]$d.Media }
    if ($d.Media -eq 'HDD' -and $d.Rpm -gt 0) { $kind += (Tx ', {0} RPM' ($d.Rpm)) }
    $rows = @(
        @('Firmware', $d.Firmware), @('Número de série', $d.Serial), @('Interface', $d.Bus), @('Tipo', $kind),
        @('Letras', $(if (@($d.Letters).Count) { @($d.Letters) -join ' ' } else { 'nenhuma' })),
        @('Vezes ligado', $(if ($rp.Cycles -ge 0) { (Tx '{0:N0} vezes' $rp.Cycles) } else { '' })),
        @('Horas ligado', $(if ($rp.Hours -ge 0) { (Tx '{0:N0} horas ({1:N0} dias)' $rp.Hours ([Math]::Floor($rp.Hours / 24))) } else { '' })),
        @('Total lido', (Format-DiskBytes $rp.Read)), @('Total escrito', (Format-DiskBytes $rp.Written))
    )
    foreach ($r in $rows) {
        if (-not $r[1]) { continue }
        $row = New-Xaml $RowXaml
        $row.FindName('K').Text = $r[0]
        $row.FindName('V').Text = [string]$r[1]
        [void]$info.Children.Add($row)
    }
    [System.Windows.Controls.Grid]::SetColumn($info, 1)
    [void]$grid.Children.Add($info)
    [void]$card.FindName('Rows').Children.Add($grid)
    foreach ($n in @($rp.Notes)) {
        $row = New-Xaml $DiagXaml
        $row.Margin = New-Object System.Windows.Thickness 0, 6, 0, 2
        $row.FindName('Dot').Fill = Get-DiskBrush $(switch ($n[0]) { 'bad' { 'bad' } 'warn' { 'caution' } 'ok' { 'good' } default { 'unknown' } })
        $row.FindName('Title').Visibility = 'Collapsed'
        $row.FindName('Body').Text = $n[1]
        $row.FindName('Body').Foreground = $script:Window.FindResource('Text')
        [void]$card.FindName('Rows').Children.Add($row)
    }
    [void]$panel.Children.Add($card)

    if ($rp.Attrs.Count -gt 0) {
        $tab = New-Xaml $GuideXaml
        $tab.FindName('Title').Text = 'Atributos S.M.A.R.T.'
        $tab.FindName('Intro').Text = $(if ($rp.Kind -eq 'nvme') { 'O registro de saúde que o próprio SSD mantém. Dados lidos e escritos já estão convertidos.' } else { 'Atual e pior vão de 100 (ou 200, ou 253) para baixo; quando o atual chega no limite, o fabricante considera o disco em falha. Bruto é o contador de verdade, e o significado de alguns muda de fabricante para fabricante.' })
        $box = $tab.FindName('Rows')
        $script:DiskZebra = $false
        if ($rp.Kind -eq 'nvme') {
            $w = [double[]](44, 0, 150)
            [void]$box.Children.Add((New-DiskRow @('ID', 'Atributo', 'Valor') $w '' $true))
            foreach ($a in $rp.Attrs) { [void]$box.Children.Add((New-DiskRow @($a.Id, $a.Name, [string]$a.Raw) $w $a.Level $false)) }
        } else {
            $w = [double[]](44, 0, 58, 58, 58, 140)
            [void]$box.Children.Add((New-DiskRow @('ID', 'Atributo', 'Atual', 'Pior', 'Limite', 'Bruto') $w '' $true))
            foreach ($a in $rp.Attrs) { [void]$box.Children.Add((New-DiskRow @($a.Id, $a.Name, [string]$a.Cur, [string]$a.Worst, [string]$a.Thr, [string]$a.Raw) $w $a.Level $false)) }
        }
        [void]$panel.Children.Add($tab)
    }
    Register-Tr $panel
}

# ----- Online: ping, DNS e overlays -----
$script:PingRes = $null
$script:DnsRes = $null

function Invoke-PingTest {
    if ($script:Busy) { return }
    Set-Busy $true
    try {
        Set-Status 'Medindo o ping até os data centers de São Paulo. Leva uns 20 segundos...'
        $r = @(Invoke-Background $script:PingCode $null)
        $script:PingRes = if ($r.Count -gt 0) { @($r[$r.Count - 1]) } else { @() }
        Write-Log ('Ping: ' + ((@($script:PingRes) | ForEach-Object { $s = Get-PingStats $_.Samples $_.Sent; "$($_.Id)=$($s.Avg)ms/$($s.Loss)%" }) -join ' '))
        Set-Status 'Teste de ping concluído.'
    } catch { Show-Error $_ } finally { Set-Busy $false }
    Update-OnlineView
}

function Invoke-DnsTest {
    if ($script:Busy) { return }
    Set-Busy $true
    try {
        Set-Status 'Comparando os DNS. Leva uns 15 segundos...'
        $r = @(Invoke-Background $script:DnsCode $null)
        $script:DnsRes = if ($r.Count -gt 0) { $r[$r.Count - 1] } else { $null }
        Set-Status 'Teste de DNS concluído.'
    } catch { Show-Error $_ } finally { Set-Busy $false }
    Update-OnlineView
}

function New-OnlineButton($Panel, [string]$Text, [string]$Style, $Tag, $Action) {
    $b = New-Object System.Windows.Controls.Button
    $b.Style = $script:Window.FindResource($Style)
    $b.Content = $Text
    $b.Tag = $Tag
    $b.FontSize = 12.5
    $b.Padding = New-Object System.Windows.Thickness 14, 7, 14, 7
    $b.Margin = New-Object System.Windows.Thickness 0, 0, 10, 6
    $b.IsEnabled = -not $script:Busy
    $b.Add_Click($Action)
    [void]$Panel.Children.Add($b)
}

function Add-OnlineRow($Rows, [string]$Level, [string]$Title, [string]$Body) {
    $row = New-Xaml $DiagXaml
    $row.Margin = New-Object System.Windows.Thickness 0, 4, 0, 8
    $row.FindName('Dot').Fill = Get-DiskBrush $(switch ($Level) { 'ok' { 'good' } 'warn' { 'caution' } 'bad' { 'bad' } default { 'unknown' } })
    $row.FindName('Title').Text = $Title
    $row.FindName('Body').Text = $Body
    [void]$Rows.Children.Add($row)
    return $row
}

function Update-OnlineView {
    $panel = $script:ui.OnlineList
    $panel.Children.Clear()

    # Ping
    $c = New-Xaml $GuideXaml
    $c.FindName('Title').Text = 'Ping até os servidores'
    $c.FindName('Intro').Text = 'Mede a latência, a variação (jitter) e a perda de pacotes até os data centers de São Paulo onde os jogos rodam. Os jogos não divulgam o endereço exato dos servidores, então o número é uma estimativa muito próxima do ping dentro do jogo. Faça o teste com o cabo de rede, se puder, e com downloads parados.'
    $rows = $c.FindName('Rows')
    $bar = New-Object System.Windows.Controls.WrapPanel
    New-OnlineButton $bar $(if ($script:PingRes) { 'Testar de novo' } else { 'Testar o ping' }) 'Primary' $null { try { Invoke-PingTest } catch { Show-Error $_ } }
    [void]$rows.Children.Add($bar)
    foreach ($t in @($script:PingRes)) {
        if (-not $t) { continue }
        $st = Get-PingStats $t.Samples $t.Sent
        $title = if ($st.Avg -lt 0) { (Tx '{0}: sem resposta' (Tr $t.Name)) } else { (Tx '{0}: {1} ms' (Tr $t.Name) ($st.Avg)) }
        $how = if ($st.Avg -lt 0) { 'Esse destino não respondeu agora. Pode ser bloqueio da rede ou do provedor; não quer dizer que o jogo está fora do ar.' }
               else { (Tx 'Mínimo {0} ms, máximo {1} ms, variação {2} ms, perda {3}%.' ($st.Min) ($st.Max) ($st.Jitter) ($st.Loss)) + ' ' + (Tr $script:PingGames[$t.Id]) }
        [void](Add-OnlineRow $rows $(if ($st.Avg -lt 0) { 'unknown' } else { $st.Level }) $title $how)
    }
    if ($script:PingRes) {
        $all = @($script:PingRes | ForEach-Object { Get-PingStats $_.Samples $_.Sent } | Where-Object { $_.Avg -ge 0 })
        $tip = if (@($all | Where-Object { $_.Loss -gt 0 }).Count -gt 0) { 'Houve perda de pacotes. No Wi-Fi isso é comum: teste com cabo. Se continuar no cabo, reinicie o roteador e, se não resolver, fale com o provedor.' }
               elseif (@($all | Where-Object { $_.Jitter -gt 15 }).Count -gt 0) { 'A variação está alta, o que causa "teleportes" no jogo. Quase sempre é Wi-Fi ou alguém usando muito a internet ao mesmo tempo.' }
               elseif (@($all | Where-Object { $_.Avg -gt 60 }).Count -gt 0) { 'O ping está alto mesmo sem perda. Normalmente é a distância até São Paulo ou a rota do provedor; dá para comparar em outro horário.' }
               else { 'Conexão boa para jogar: ping baixo, estável e sem perda.' }
        $t = New-Object System.Windows.Controls.TextBlock
        $t.Text = $tip; $t.TextWrapping = 'Wrap'; $t.FontSize = 12.5; $t.Margin = New-Object System.Windows.Thickness 0, 2, 0, 4
        $t.Foreground = $script:Window.FindResource('Text')
        [void]$rows.Children.Add($t)
    }
    [void]$panel.Children.Add($c)

    # DNS
    $c = New-Xaml $GuideXaml
    $c.FindName('Title').Text = 'DNS mais rápido'
    $c.FindName('Intro').Text = 'O DNS transforma nomes como riotgames.com em endereços. Ele não muda o ping dentro da partida, mas um DNS rápido faz sites, launchers e o login dos jogos abrirem mais depressa.'
    $rows = $c.FindName('Rows')
    $bar = New-Object System.Windows.Controls.WrapPanel
    New-OnlineButton $bar $(if ($script:DnsRes) { 'Testar de novo' } else { 'Testar os DNS' }) 'Primary' $null { try { Invoke-DnsTest } catch { Show-Error $_ } }
    if ($script:Backup.state['dnsSet']) {
        New-OnlineButton $bar 'Voltar ao DNS original' 'Ghost' $null { try { Restore-HarleDns; Set-Status 'DNS original de volta.'; Update-OnlineView } catch { Show-Error $_ } }
    }
    [void]$rows.Children.Add($bar)
    if ($script:DnsRes) {
        $list = @($script:DnsRes.Servers | ForEach-Object {
            $a = @($_.Samples | ForEach-Object { [double]$_ } | Sort-Object)
            $med = if ($a.Count -gt 0) { [Math]::Round($a[[int][Math]::Floor(($a.Count - 1) / 2)]) } else { -1 }
            @{ S = $_; Med = $med }
        })
        $ok = @($list | Where-Object { $_.Med -ge 0 } | Sort-Object { $_.Med })
        $best = if ($ok.Count -gt 0) { $ok[0] } else { $null }
        foreach ($x in $list) {
            $s = $x.S
            $name = if ($s.Id -eq 'current') { (Tx 'Atual ({0})' ($s.Ip)) } else { "$($s.Name) ($($s.Ip))" }
            if ($s.Current -and $s.Id -ne 'current') { $name += ' ' + (Tr '(o atual)') }
            $title = if ($x.Med -lt 0) { (Tx '{0}: não respondeu' $name) } else { (Tx '{0}: {1} ms' $name ($x.Med)) }
            $body = if ($best -and $x -eq $best) { 'O mais rápido nesta conexão.' } elseif ($s.Fail -gt 0) { (Tx '{0} consultas falharam.' ($s.Fail)) } else { '' }
            $lvl = if ($x.Med -lt 0) { 'bad' } elseif ($best -and $x -eq $best) { 'ok' } else { 'unknown' }
            $row = Add-OnlineRow $rows $lvl $title $body
            if ($s.Id -ne 'current' -and -not $s.Current -and $x.Med -ge 0) {
                $wp = New-Object System.Windows.Controls.WrapPanel
                $wp.Margin = New-Object System.Windows.Thickness 0, 6, 0, 0
                New-OnlineButton $wp (Tx 'Usar o {0}' ($s.Name)) 'Ghost' (@($s.Ip, $s.Ip2) -join ',') {
                    param($b, $e)
                    try {
                        Set-HarleDns @(([string]$b.Tag).Split(',') | Where-Object { $_ })
                        Set-Status (Tx 'DNS trocado para {0}. Para desfazer, use Voltar ao DNS original.' ([string]$b.Tag))
                        Update-OnlineView
                    } catch { Show-Error $_ }
                }
                [void]$row.Children[1].Children.Add($wp)
            }
        }
    }
    [void]$panel.Children.Add($c)

    # Overlays
    $c = New-Xaml $GuideXaml
    $c.FindName('Title').Text = 'Overlays abertos agora'
    $c.FindName('Intro').Text = 'Programas que desenham por cima do jogo (contador de FPS, chat, gravação). Cada um injeta código no jogo e pode custar FPS ou causar travadas. A Xbox Game Bar não entra na lista.'
    $rows = $c.FindName('Rows')
    $running = @(Get-Process -ErrorAction SilentlyContinue | ForEach-Object { $_.ProcessName } | Select-Object -Unique)
    $open = @(Get-OpenOverlays $running)
    if ($open.Count -eq 0) { [void](Add-OnlineRow $rows 'ok' 'Nenhum overlay conhecido aberto agora' 'Abra este teste com seus programas de sempre abertos para ver o que entra junto com o jogo.') }
    foreach ($o in $open) {
        $row = Add-OnlineRow $rows 'warn' $o.Name $o.Where
        if ($o.Close) {
            $wp = New-Object System.Windows.Controls.WrapPanel
            $wp.Margin = New-Object System.Windows.Thickness 0, 6, 0, 0
            New-OnlineButton $wp 'Fechar agora' 'Ghost' $o.Proc {
                param($b, $e)
                try {
                    Get-Process -Name ([string]$b.Tag) -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
                    Write-Log "Overlay fechado: $($b.Tag)"
                    Set-Status (Tx '{0} fechado.' ([string]$b.Tag))
                    Update-OnlineView
                } catch { Show-Error $_ }
            }
            [void]$row.Children[1].Children.Add($wp)
        }
    }
    [void]$panel.Children.Add($c)
    Register-Tr $panel
}

# ----- Drivers -----
$script:DrvScan = $null
$script:DrvPick = @{}
$script:DrvResult = @()

function Invoke-DriverScan {
    if ($script:Busy) { return }
    Set-Busy $true
    try {
        Set-Status 'Procurando drivers no Windows Update. Pode levar de 1 a 3 minutos...'
        $r = @(Invoke-Background $script:DriverScanCode $null)
        $script:DrvScan = if ($r.Count -gt 0) { $r[$r.Count - 1] } else { @{ Updates = @(); Problems = @(); Error = 'sem resposta' } }
        $script:DrvPick = @{}
        foreach ($u in @($script:DrvScan.Updates)) { $script:DrvPick[$u.Id] = Test-DriverDefaultPick $u }
        Write-Log "Drivers: $(@($script:DrvScan.Updates).Count) no Windows Update, $(@($script:DrvScan.Problems).Count) dispositivos com problema $($script:DrvScan.Error)"
        if ($script:DrvScan.Error) { Set-Status (Tx 'O Windows Update não respondeu: {0}' (Get-WuErrorText $script:DrvScan.Error)) }
        else { Set-Status (Tx 'Busca concluída: {0} drivers disponíveis.' (@($script:DrvScan.Updates).Count)) }
    } catch { Show-Error $_ } finally { Set-Busy $false }
    Update-DriversView
}

function Invoke-DriverInstall {
    if ($script:Busy -or -not $script:DrvScan) { return }
    $ids = @($script:DrvScan.Updates | Where-Object { $script:DrvPick[$_.Id] } | ForEach-Object { $_.Id })
    if ($ids.Count -eq 0) { Set-Status 'Marque pelo menos um driver.'; return }
    Set-Busy $true
    $reboot = $false
    try {
        if (-not $script:RestoreDone) {
            Set-Status 'Criando um ponto de restauração do Windows antes de instalar...'
            $script:RestoreDone = New-RestorePoint
        }
        Set-Status (Tx 'Baixando e instalando {0} drivers. Pode levar alguns minutos; a janela continua respondendo.' $ids.Count)
        $lines = @(Invoke-Background $script:DriverInstallCode @{ Ids = [string[]]$ids })
        $script:DrvResult = @()
        $ok = 0; $bad = 0
        foreach ($l in $lines) {
            $f = ([string]$l).Split('|')
            if ($f[0] -eq 'item') {
                $good = (@('2', '3') -contains $f[2])
                if ($good) { $ok++ } else { $bad++ }
                $script:DrvResult += @{ Title = $f[1]; Ok = $good }
                Write-Log "Driver $($f[1]): resultado $($f[2])"
            } elseif ($f[0] -eq 'fim') { $reboot = ($f[2] -eq 'True') }
            elseif ($f[0] -eq 'erro') { Write-Log "Drivers: $($f[1])"; $bad++ }
        }
        $msg = (Tx 'Drivers: {0} instalados, {1} com falha.' $ok $bad)
        if ($reboot) { $msg += ' ' + (Tr 'Reinicie o PC para terminar.') }
        Set-Status $msg
    } catch { Show-Error $_ } finally { Set-Busy $false }
    # Depois de instalar, a lista do Windows Update muda: busca de novo.
    $script:DrvScan = $null
    Update-DriversView
}

# ----- Kit de formatacao e runtimes -----
$script:KitDir = $null
$script:RtPick = $null
$script:RtResult = @()

function Get-KitRoots {
    $roots = @()
    try { $roots += @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | ForEach-Object { $_.Root }) } catch { }
    if ($env:HARLE_EXE) { $roots += (Split-Path -Parent $env:HARLE_EXE) }
    return $roots
}

function Get-CurrentKit {
    if ($script:KitDir -and (Test-Path -LiteralPath (Join-Path $script:KitDir 'kit.json'))) {
        $k = @(Find-HarleKits @($script:KitDir)) | Select-Object -First 1
        if ($k) { return $k }
    }
    $k = @(Find-HarleKits (Get-KitRoots)) | Select-Object -First 1
    if ($k) { $script:KitDir = $k.Dir }
    return $k
}

function Select-Folder([string]$Title) {
    Add-Type -AssemblyName System.Windows.Forms
    $d = New-Object System.Windows.Forms.FolderBrowserDialog
    $d.Description = Tr $Title
    $d.ShowNewFolderButton = $true
    if ($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $d.SelectedPath }
    return $null
}

$script:KitOpt = @{ Runtimes = $true; Net3dp = $true }

function Invoke-KitSave([bool]$WithRuntimes, [bool]$With3dp) {
    if ($script:Busy) { return }
    $dir = Select-Folder 'Escolha o pendrive ou outro disco para salvar o kit (não use o disco do Windows, ele é apagado ao formatar)'
    if (-not $dir) { return }
    $sys = $env:SystemDrive
    if ($dir.StartsWith($sys, [StringComparison]::OrdinalIgnoreCase)) {
        Set-Status (Tx 'Essa pasta fica no disco do Windows ({0}), que é apagado ao formatar. Escolha um pendrive ou outro disco.' $sys)
        return
    }
    Set-Busy $true
    try {
        Set-Status 'Salvando os drivers deste PC e montando o kit. Pode levar alguns minutos...'
        $rts = if ($WithRuntimes) { @($script:Runtimes | Where-Object { $_.Url } | ForEach-Object { @{ Id = $_.Id; File = $_.File; Url = $_.Url } }) } else { @() }
        $lines = @(Invoke-Background $script:KitSaveCode @{ Dir = $dir; Drivers = $true; Runtimes = $rts; Exe = $env:HARLE_EXE; Windows = (Get-WinName); Net3dp = $(if ($With3dp) { $script:Net3dpUrl } else { '' }) })
        $nd = 0; $nr = 0; $err = ''; $net = ''
        foreach ($l in $lines) {
            $f = ([string]$l).Split('|')
            switch ($f[0]) { 'drivers' { $nd = [int]$f[1] } 'rt' { if ($f[2] -eq 'ok') { $nr++ } else { Write-Log "Kit, runtime $($f[1]): $($f[2])" } } 'net' { $net = $f[1]; Write-Log "Kit, 3DP Net: $l" } 'fim' { $script:KitDir = $f[1] } 'erro' { $err = $f[1] } }
        }
        Write-Log "Kit salvo em $($script:KitDir): $nd drivers, $nr runtimes $err"
        if ($err) { Set-Status (Tx 'O kit não terminou: {0}' $err) }
        else {
            $msg = (Tx 'Kit salvo em {0}: {1} drivers deste PC, {2} runtimes e o próprio Harle.exe.' $script:KitDir $nd $nr)
            if ($net -eq 'ok') { $msg += ' ' + (Tr 'O 3DP Net também foi salvo.') } elseif ($net) { $msg += ' ' + (Tr 'O 3DP Net não baixou; dá para colocar o arquivo dele na pasta Rede do kit depois.') }
            Set-Status $msg
        }
    } catch { Show-Error $_ } finally { Set-Busy $false }
    Update-DriversView
}

function Invoke-KitDrivers([string]$Which) {
    if ($script:Busy) { return }
    $kit = Get-CurrentKit
    if (-not $kit) { Set-Status 'Nenhum kit encontrado. Conecte o pendrive com a pasta Harle-Kit.'; return }
    $list = @()
    try { $list = @([IO.File]::ReadAllText((Join-Path $kit.Dir 'drivers.json')) | ConvertFrom-Json) } catch { }
    $sel = @(Select-KitDrivers $list $Which)
    if ($sel.Count -eq 0) { Set-Status $(if ($Which -eq 'net') { 'O kit não tem driver de rede: este PC usava os que já vêm no Windows.' } else { 'O kit não tem drivers.' }); return }
    Set-Busy $true
    try {
        if (-not $script:RestoreDone) { Set-Status 'Criando um ponto de restauração do Windows antes de instalar...'; $script:RestoreDone = New-RestorePoint }
        Set-Status (Tx 'Instalando {0} drivers do kit...' $sel.Count)
        $lines = @(Invoke-Background $script:KitDriverCode @{ Kit = $kit.Dir; Folders = [string[]]@($sel | ForEach-Object { [string]$_.Folder }) })
        $fim = @($lines | Where-Object { ([string]$_).StartsWith('fim|') }) | Select-Object -Last 1
        $f = ([string]$fim).Split('|')
        foreach ($l in $lines) { if (([string]$l).StartsWith('falha|')) { Write-Log "Kit, driver: $l" } }
        $msg = (Tx 'Drivers do kit: {0} instalados, {1} com falha.' $f[1] $f[2])
        if ($f[3] -eq 'True') { $msg += ' ' + (Tr 'Reinicie o PC para terminar.') }
        Set-Status $msg
        Write-Log $msg
    } catch { Show-Error $_ } finally { Set-Busy $false }
    Update-DriversView
}

function Invoke-RuntimeInstall {
    if ($script:Busy) { return }
    $items = @($script:Runtimes | Where-Object { $script:RtPick[$_.Id] } | ForEach-Object { @{ Id = $_.Id; Kind = [string]$_.Kind; File = $_.File; Url = $_.Url; Args = $_.Args } })
    if ($items.Count -eq 0) { Set-Status 'Marque pelo menos um runtime.'; return }
    $kit = Get-CurrentKit
    Set-Busy $true
    try {
        Set-Status (Tx 'Instalando {0} runtimes. Pode levar alguns minutos; a janela continua respondendo.' $items.Count)
        $lines = @(Invoke-Background $script:RuntimeInstallCode @{ Items = $items; Kit = $(if ($kit) { $kit.Dir } else { '' }) })
        $script:RtResult = @()
        $ok = 0; $bad = 0
        foreach ($l in $lines) {
            $f = ([string]$l).Split('|', 3)
            $r = @($script:Runtimes | Where-Object { $_.Id -eq $f[1] }) | Select-Object -First 1
            if (-not $r) { continue }
            if ($f[0] -eq 'ok') { $ok++ } else { $bad++ }
            $script:RtResult += @{ Name = $r.Name; Ok = ($f[0] -eq 'ok'); Why = [string]$f[2] }
            Write-Log "Runtime $($f[1]): $l"
        }
        Set-Status (Tx 'Runtimes: {0} instalados, {1} com falha.' $ok $bad)
    } catch { Show-Error $_ } finally { Set-Busy $false }
    $script:RtPick = $null
    Update-DriversView
}

function Add-KitCards($Panel) {
    # Kit de formatacao
    $kit = Get-CurrentKit
    $c = New-Xaml $GuideXaml
    $c.FindName('Title').Text = 'Kit de formatação (pendrive)'
    $c.FindName('Intro').Text = 'Antes de formatar, salve no pendrive os drivers deste PC (inclusive o de rede), os runtimes e o próprio Harle. Depois de formatar, abra o Harle pelo pendrive e instale tudo sem precisar de internet. São os drivers exatos deste PC, então não tem risco de driver errado. Já formatou sem salvar? Baixe o Harle-Kit.zip na página de versões do GitHub (dá para baixar no celular e passar para o PC): ele traz o Harle e os runtimes.'
    $rows = $c.FindName('Rows')
    if ($kit) {
        $i = $kit.Info
        $body = if ([string]$i.source -eq 'github') { (Tx 'Kit baixado do GitHub (Harle {0}): {1} runtimes oficiais da Microsoft, prontos para instalar sem internet.' ([string]$i.version) (@($i.runtimes).Count)) }
                else { (Tx 'Salvo em {0}, no PC {1} ({2}): {3} drivers e {4} runtimes.' ([string]$i.created) ([string]$i.pc) (Tr ([string]$i.windows)) ([int]$i.drivers) (@($i.runtimes).Count)) }
        [void](Add-OnlineRow $rows 'ok' (Tx 'Kit encontrado em {0}' $kit.Dir) $body)
    } else {
        [void](Add-OnlineRow $rows 'unknown' 'Nenhum kit encontrado' 'Conecte o pendrive com a pasta Harle-Kit, ou salve um kit agora se você ainda não formatou.')
    }
    $t = New-DiskText 'Antes de formatar' 12 'Muted'; $t.FontWeight = 'SemiBold'; $t.Margin = New-Object System.Windows.Thickness 0, 8, 0, 4
    [void]$rows.Children.Add($t)
    $wp = New-Object System.Windows.Controls.WrapPanel
    $optRow = {
        param([string]$Key, [string]$Title, [string]$Body)
        $g = New-Object System.Windows.Controls.Grid
        $g.Margin = New-Object System.Windows.Thickness 0, 4, 0, 4
        $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star); $g.ColumnDefinitions.Add($c1)
        $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = [System.Windows.GridLength]::Auto; $g.ColumnDefinitions.Add($c2)
        $sp = New-Object System.Windows.Controls.StackPanel; $sp.Margin = New-Object System.Windows.Thickness 0, 0, 16, 0
        $t1 = New-DiskText $Title 13 'Text'; $t1.FontWeight = 'SemiBold'
        [void]$sp.Children.Add($t1); [void]$sp.Children.Add((New-DiskText $Body 12 'Muted')); [void]$g.Children.Add($sp)
        $sw = New-Object System.Windows.Controls.CheckBox
        $sw.Style = $script:Window.FindResource('Switch'); $sw.VerticalAlignment = 'Center'
        $sw.IsChecked = [bool]$script:KitOpt[$Key]; $sw.Tag = $Key
        $sw.Add_Click({ param($s, $e) $script:KitOpt[[string]$s.Tag] = [bool]$s.IsChecked })
        [System.Windows.Controls.Grid]::SetColumn($sw, 1); [void]$g.Children.Add($sw)
        [void]$rows.Children.Add($g)
    }
    & $optRow 'Runtimes' 'Incluir os runtimes para jogos (cerca de 200 MB)' 'Instaladores oficiais da Microsoft, para instalar sem internet depois.'
    & $optRow 'Net3dp' 'Incluir o 3DP Net (cerca de 200 MB)' 'Programa gratuito com drivers de rede para quase todas as placas. Serve até para outro PC. Baixado do site oficial (3dpchip.com).'
    New-OnlineButton $wp 'Salvar o kit no pendrive' 'Primary' $null { try { Invoke-KitSave ([bool]$script:KitOpt.Runtimes) ([bool]$script:KitOpt.Net3dp) } catch { Show-Error $_ } }
    [void]$rows.Children.Add($wp)
    $t = New-DiskText 'Depois de formatar' 12 'Muted'; $t.FontWeight = 'SemiBold'; $t.Margin = New-Object System.Windows.Thickness 0, 8, 0, 4
    [void]$rows.Children.Add($t)
    $wp = New-Object System.Windows.Controls.WrapPanel
    New-OnlineButton $wp 'Instalar o driver de rede do kit' 'Primary' $null { try { Invoke-KitDrivers 'net' } catch { Show-Error $_ } }
    $net3 = Find-3dpNet @($(if ($kit) { $kit.Dir }), $(if ($env:HARLE_EXE) { Split-Path -Parent $env:HARLE_EXE }))
    New-OnlineButton $wp 'Abrir o 3DP Net' 'Ghost' $net3 {
        param($b, $e)
        try {
            if ($b.Tag) { Start-Process -FilePath ([string]$b.Tag); Set-Status 'Abrindo o 3DP Net. Ele descobre a placa de rede e instala o driver certo.' }
            else { Start-Process -FilePath 'explorer.exe' -ArgumentList $script:Net3dpPage; Set-Status 'O 3DP Net não está no kit. Abrindo o site oficial para baixar.' }
        } catch { Show-Error $_ }
    }
    New-OnlineButton $wp 'Instalar todos os drivers do kit' 'Ghost' $null { try { Invoke-KitDrivers 'all' } catch { Show-Error $_ } }
    New-OnlineButton $wp 'Escolher a pasta do kit' 'Ghost' $null {
        try { $d = Select-Folder 'Escolha a pasta Harle-Kit'; if ($d) { $script:KitDir = $d; if (-not (Get-CurrentKit)) { Set-Status 'Essa pasta não tem um kit do Harle (falta o kit.json).' }; Update-DriversView } } catch { Show-Error $_ }
    }
    if (-not $kit -or [int]$kit.Info.drivers -eq 0) {
        foreach ($b in @($wp.Children)) { if (@('Instalar o driver de rede do kit', 'Install the network driver from the kit', 'Instalar todos os drivers do kit', 'Install all drivers from the kit') -contains [string]$b.Content) { $b.IsEnabled = $false } }
    }
    [void]$rows.Children.Add($wp)
    [void]$Panel.Children.Add($c)

    # Sem internet depois de formatar: o celular resolve sem nenhum driver extra
    $c = New-Xaml $GuideXaml
    $c.FindName('Title').Text = 'Sem internet depois de formatar?'
    $c.FindName('Intro').Text = 'Use a internet do celular pelo cabo USB. O Windows 10 e 11 já trazem o driver para isso, então funciona mesmo sem o driver da placa de rede. Com a internet ligada, o Harle baixa os runtimes e o Windows Update da aba Drivers encontra o driver da placa de rede.'
    $rows = $c.FindName('Rows')
    [void](Add-OnlineRow $rows 'ok' 'Android' 'Ligue o celular no PC pelo cabo USB. No celular: Configurações, Conexões (ou Rede e internet), Roteador Wi-Fi e ancoragem, e ative Ancoragem USB. O PC conecta sozinho em alguns segundos.')
    [void](Add-OnlineRow $rows 'unknown' 'iPhone' 'O Windows não traz o driver do iPhone pelo cabo. Se o Wi-Fi do PC já funcionar, use o Acesso Pessoal pelo Wi-Fi; se não, passe o kit do GitHub (Harle-Kit.zip) do celular para o PC.')
    [void]$Panel.Children.Add($c)

    # Runtimes
    $names = Get-InstalledNames
    if ($null -eq $script:RtPick) {
        $script:RtPick = @{}
        foreach ($r in $script:Runtimes) { $script:RtPick[$r.Id] = $r.Rec -and -not (Test-RuntimeInstalled $r $names) }
    }
    $c = New-Xaml $GuideXaml
    $c.FindName('Title').Text = 'Runtimes para jogos'
    $c.FindName('Intro').Text = 'Pacotes que os jogos precisam e que o Windows não traz depois de formatar (é o que o "AIO Runtimes" instala). O Harle usa só os instaladores oficiais da Microsoft e confere a assinatura digital de cada um antes de rodar. Se houver um kit no pendrive, instala de lá sem internet; senão, baixa direto da Microsoft.'
    $rows = $c.FindName('Rows')
    $wp = New-Object System.Windows.Controls.WrapPanel
    New-OnlineButton $wp 'Instalar os marcados' 'Primary' $null { try { Invoke-RuntimeInstall } catch { Show-Error $_ } }
    [void]$rows.Children.Add($wp)
    foreach ($x in @($script:RtResult)) { [void](Add-OnlineRow $rows $(if ($x.Ok) { 'ok' } else { 'bad' }) $x.Name $(if ($x.Ok) { 'Instalado.' } elseif ($x.Why -eq 'assinatura') { 'O arquivo não tem a assinatura da Microsoft e não foi executado.' } else { Tx 'Não instalou: {0}' $x.Why })) }
    foreach ($r in $script:Runtimes) {
        $inst = Test-RuntimeInstalled $r $names
        $g = New-Object System.Windows.Controls.Grid
        $g.Margin = New-Object System.Windows.Thickness 0, 6, 0, 6
        $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star); $g.ColumnDefinitions.Add($c1)
        $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = [System.Windows.GridLength]::Auto; $g.ColumnDefinitions.Add($c2)
        $sp = New-Object System.Windows.Controls.StackPanel; $sp.Margin = New-Object System.Windows.Thickness 0, 0, 16, 0
        $head = New-Object System.Windows.Controls.TextBlock
        $r1 = New-Object System.Windows.Documents.Run (Tr $r.Name); $r1.FontWeight = 'SemiBold'; $r1.Foreground = $script:Window.FindResource('Text')
        [void]$head.Inlines.Add($r1)
        if ($inst) { $r2 = New-Object System.Windows.Documents.Run ('   ' + (Tr 'já instalado')); $r2.FontSize = 11; $r2.Foreground = $script:Window.FindResource('Ice'); [void]$head.Inlines.Add($r2) }
        $head.FontSize = 13
        [void]$sp.Children.Add($head)
        [void]$sp.Children.Add((New-DiskText (Tr $script:RuntimeNotes[$r.Id]) 12 'Muted'))
        [void]$g.Children.Add($sp)
        $sw = New-Object System.Windows.Controls.CheckBox
        $sw.Style = $script:Window.FindResource('Switch'); $sw.VerticalAlignment = 'Center'
        $sw.IsChecked = [bool]$script:RtPick[$r.Id]; $sw.Tag = $r.Id; $sw.IsEnabled = -not $script:Busy
        $sw.Add_Click({ param($s, $e) $script:RtPick[[string]$s.Tag] = [bool]$s.IsChecked })
        [System.Windows.Controls.Grid]::SetColumn($sw, 1); [void]$g.Children.Add($sw)
        [void]$rows.Children.Add($g)
    }
    [void]$Panel.Children.Add($c)
}

function Update-DriversView {
    $panel = $script:ui.DrvList
    $panel.Children.Clear()
    Add-KitCards $panel

    # Windows Update
    $c = New-Xaml $GuideXaml
    $c.FindName('Title').Text = 'Drivers pelo Windows Update'
    $c.FindName('Intro').Text = 'Drivers oficiais, assinados pela Microsoft, tirados do catálogo do Windows Update. Funciona mesmo com o Windows Update desligado: o Harle liga o serviço só durante a busca ou a instalação e desliga de novo no final, então nada fica pesando depois. Você vê a lista e escolhe quais instalar. Um ponto de restauração é criado antes. Os de placa de vídeo vêm desmarcados: o do site do fabricante, logo abaixo, é mais novo.'
    $rows = $c.FindName('Rows')
    $bar = New-Object System.Windows.Controls.WrapPanel
    New-OnlineButton $bar $(if ($script:DrvScan) { 'Procurar de novo' } else { 'Procurar drivers' }) $(if ($script:DrvScan) { 'Ghost' } else { 'Primary' }) $null { try { Invoke-DriverScan } catch { Show-Error $_ } }
    $ups = @(if ($script:DrvScan) { $script:DrvScan.Updates })
    if ($ups.Count -gt 0) { New-OnlineButton $bar 'Instalar os marcados' 'Primary' $null { try { Invoke-DriverInstall } catch { Show-Error $_ } } }
    [void]$rows.Children.Add($bar)
    foreach ($r in @($script:DrvResult)) { [void](Add-OnlineRow $rows $(if ($r.Ok) { 'ok' } else { 'bad' }) $r.Title $(if ($r.Ok) { 'Instalado.' } else { 'Não instalou. O motivo está no log.' })) }
    if ($script:DrvScan -and $ups.Count -eq 0 -and -not $script:DrvScan.Error) { [void](Add-OnlineRow $rows 'ok' 'Nenhum driver pendente no Windows Update' 'O Windows já tem tudo o que o Windows Update oferece para este PC.') }
    if ($script:DrvScan -and $script:DrvScan.Error) { [void](Add-OnlineRow $rows 'bad' 'O Windows Update não respondeu' (Get-WuErrorText $script:DrvScan.Error)) }
    if ($script:DrvScan -and $script:DrvScan.Opened -and -not $script:DrvScan.Error) { [void](Add-OnlineRow $rows 'unknown' 'O Windows Update deste PC estava desligado' 'O Harle ligou o serviço só durante a busca e já desligou de novo. Na instalação acontece o mesmo; nada fica rodando depois.') }
    foreach ($u in $ups) {
        $info = @()
        if ($u.Maker) { $info += $u.Maker }
        if ($u.Class) { $info += $u.Class }
        if ($u.Date) { $info += ([datetime]$u.Date).ToString('dd/MM/yyyy') }
        if ($u.Size -gt 0) { $info += (Format-MemMB ($u.Size / 1MB)) }
        $note = if (-not (Test-DriverDefaultPick $u)) { 'placa de vídeo' } else { '' }
        $g = New-Object System.Windows.Controls.Grid
        $g.Margin = New-Object System.Windows.Thickness 0, 6, 0, 6
        $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star); $g.ColumnDefinitions.Add($c1)
        $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = [System.Windows.GridLength]::Auto; $g.ColumnDefinitions.Add($c2)
        $sp = New-Object System.Windows.Controls.StackPanel; $sp.Margin = New-Object System.Windows.Thickness 0, 0, 16, 0
        $t = New-DiskText ([string]$u.Title) 13 'Text'; $t.FontWeight = 'SemiBold'
        $d = New-DiskText (($info -join '  ·  ') + $(if ($note) { '  ·  ' + (Tr $note) } else { '' })) 12 'Muted'
        [void]$sp.Children.Add($t); [void]$sp.Children.Add($d); [void]$g.Children.Add($sp)
        $sw = New-Object System.Windows.Controls.CheckBox
        $sw.Style = $script:Window.FindResource('Switch'); $sw.VerticalAlignment = 'Center'
        $sw.IsChecked = [bool]$script:DrvPick[$u.Id]; $sw.Tag = $u.Id; $sw.IsEnabled = -not $script:Busy
        $sw.Add_Click({ param($s, $e) $script:DrvPick[[string]$s.Tag] = [bool]$s.IsChecked })
        [System.Windows.Controls.Grid]::SetColumn($sw, 1); [void]$g.Children.Add($sw)
        [void]$rows.Children.Add($g)
    }
    [void]$panel.Children.Add($c)

    # Dispositivos com problema
    if ($script:DrvScan) {
        $c = New-Xaml $GuideXaml
        $c.FindName('Title').Text = 'Dispositivos com problema'
        $c.FindName('Intro').Text = 'O que aparece com aviso amarelo no Gerenciador de Dispositivos.'
        $rows = $c.FindName('Rows')
        $probs = @($script:DrvScan.Problems)
        if ($probs.Count -eq 0) { [void](Add-OnlineRow $rows 'ok' 'Nenhum dispositivo com problema' 'Todos os dispositivos conectados têm driver e estão funcionando.') }
        foreach ($p in $probs) { [void](Add-OnlineRow $rows $(if ($p.Code -eq 45) { 'unknown' } else { 'warn' }) ([string]$p.Name) (Get-DeviceCodeText $p.Code)) }
        if (@($probs | Where-Object { $_.Code -eq 28 }).Count -gt 0) {
            $t = New-DiskText 'Se o Windows Update não tiver o driver de algum deles, baixe no site de suporte do fabricante da placa-mãe ou do notebook, procurando pelo modelo exato.' 12.5 'Text'
            $t.Margin = New-Object System.Windows.Thickness 0, 4, 0, 4
            [void]$rows.Children.Add($t)
        }
        [void]$panel.Children.Add($c)
    }

    # Placa de video e chipset
    $c = New-Xaml $GuideXaml
    $c.FindName('Title').Text = 'Placa de vídeo e chipset'
    $c.FindName('Intro').Text = 'Estes drivers rendem mais FPS e estabilidade quando vêm direto do fabricante. O Harle abre a página oficial; nada é baixado de outro lugar.'
    $rows = $c.FindName('Rows')
    $sites = @(if ($script:Specs) { Get-DriverSites $script:Specs })
    if ($sites.Count -eq 0) { [void](Add-OnlineRow $rows 'unknown' 'Sem leitura do hardware' 'Abra a tela Scanner e volte aqui.') }
    foreach ($s in $sites) {
        $lvl = 'unknown'; $body = $s.Name
        if ($s.Gpu -and $s.Gpu.DriverDate) {
            $age = [int]((Get-Date) - $s.Gpu.DriverDate).TotalDays
            $lvl = if ($age -gt 150) { 'warn' } else { 'ok' }
            $body = (Tx 'Driver {0}, de {1} ({2} dias).' ([string]$s.Gpu.Driver) ($s.Gpu.DriverDate.ToString('dd/MM/yyyy')) $age) + ' ' + $(if ($age -gt 150) { Tr 'Vale atualizar.' } else { Tr 'Está em dia.' }) + ' ' + (Tr $s.Name)
        }
        $row = Add-OnlineRow $rows $lvl ([string]$s.Part) $body
        $wp = New-Object System.Windows.Controls.WrapPanel
        $wp.Margin = New-Object System.Windows.Thickness 0, 6, 0, 0
        New-OnlineButton $wp 'Abrir a página oficial' 'Ghost' $s.Url {
            param($b, $e)
            try { Start-Process -FilePath 'explorer.exe' -ArgumentList ([string]$b.Tag); Set-Status 'Abrindo a página oficial no navegador.' } catch { Show-Error $_ }
        }
        [void]$row.Children[1].Children.Add($wp)
    }
    [void]$panel.Children.Add($c)
    Register-Tr $panel
}

# ----- Memoria -----
$script:MemViewTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:MemViewTimer.Interval = [TimeSpan]::FromSeconds(2)
$script:MemAutoTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:MemAutoTimer.Interval = [TimeSpan]::FromSeconds(5)
$script:MemAutoLast = [DateTime]::MinValue
$script:MemAutoCount = 0
$script:MemBars = $null

function Format-MemMB([double]$MB) {
    if ($MB -lt 0) { return '--' }
    if ($MB -ge 1024) { return (Tx '{0:N1} GB' ($MB / 1024)) }
    return (Tx '{0:N0} MB' $MB)
}

function Invoke-MemClean([switch]$Auto) {
    if (-not $script:Hosted) { Set-Status 'A limpeza de memória só funciona no Harle.exe.'; return }
    if ($script:Busy) { return }
    $o = Get-MemOptions
    $cmds = if ($Auto) { @(4) } else { @(Get-MemCommands $o) }
    if ($cmds.Count -eq 0) { Set-Status 'Marque pelo menos uma das opções de limpeza.'; return }
    if (-not $Auto) { Set-Busy $true; Set-Status 'Limpando a memória...' }
    try {
        $r = @(Invoke-Background $script:MemCleanCode @{ Commands = [int[]]$cmds })
        $line = if ($r.Count -gt 0) { [string]$r[$r.Count - 1] } else { '' }
        $f = $line.Split('|')
        $gain = if ($f.Count -ge 2) { [double]$f[1] - [double]$f[0] } else { 0 }
        Write-Log "Memoria limpa ($(if ($Auto) { 'auto' } else { 'manual' })): $line"
        if ($f.Count -ge 4 -and $f[3]) {
            if (-not $Auto) { Set-Status (Tx 'O Windows recusou parte da limpeza: {0}' $f[3]) }
        } elseif ($Auto) {
            $script:MemAutoCount++
            $script:MemAutoLast = Get-Date
        } else {
            Set-Status (Tx 'Memória limpa: {0} a mais de memória livre.' (Format-MemMB ([Math]::Max(0, $gain))))
        }
    } catch { if (-not $Auto) { Show-Error $_ } } finally {
        if (-not $Auto) { Set-Busy $false }
        if ($script:Page -eq 'mem') { Update-MemStats }
    }
}

function Step-MemAuto {
    $o = Get-MemOptions
    if (-not $o.Auto -or $script:Busy) { return }
    if ($o.PlayOnly -and -not $script:Play.On) { return }
    if (((Get-Date) - $script:MemAutoLast).TotalSeconds -lt 30) { return }
    $l = [Harle.Memory]::Lists()
    if (Test-MemAutoNeeded $l ([int]$o.Limit)) { Invoke-MemClean -Auto }
}

function Update-MemAuto {
    $o = Get-MemOptions
    if ($script:Hosted -and $o.Auto) { $script:MemAutoTimer.Start() } else { $script:MemAutoTimer.Stop() }
}

$script:MemAutoTimer.Add_Tick({ try { Step-MemAuto } catch { Write-Log "Memoria automatica: $($_.Exception.Message)" } })
$script:MemViewTimer.Add_Tick({ try { if ($script:Page -eq 'mem') { Update-MemStats } else { $script:MemViewTimer.Stop() } } catch { } })

function Update-MemStats {
    $b = $script:MemBars
    if (-not $b -or -not $script:Hosted) { return }
    $l = [Harle.Memory]::Lists()
    $m = [Harle.Monitor]::Memory()
    if ($l[1] -lt 0 -or $m[1] -le 0) { $b.Note.Text = 'Sem leitura da memória.'; return }
    $total = [double]$m[1]
    $free = [double]$l[0] + [double]$l[1]
    $standby = [double]$l[5]
    $modified = [double]$l[2] + [double]$l[3]
    $used = [Math]::Max(0, $total - $free - $standby - $modified)
    $vals = @($used, $modified, $standby, $free)
    for ($i = 0; $i -lt 4; $i++) {
        $b.Cols[$i].Width = New-Object System.Windows.GridLength ([Math]::Max(0.001, $vals[$i])), ([System.Windows.GridUnitType]::Star)
        $b.Nums[$i].Text = Format-MemMB $vals[$i]
    }
    $b.Note.Text = (Tx 'Total {0}. Disponível para os programas: {1} (livre + em espera).' (Format-MemMB $total) (Format-MemMB ($free + $standby)))
    if ($b.Auto) {
        $o = Get-MemOptions
        $b.Auto.Text = if (-not $o.Auto) { '' } elseif ($script:MemAutoCount -gt 0) { (Tx 'Limpezas automáticas desde que o Harle abriu: {0}, a última às {1}.' $script:MemAutoCount ($script:MemAutoLast.ToString('HH:mm'))) } else { 'Nenhuma limpeza automática foi necessária até agora.' }
    }
}

function Update-MemView {
    $panel = $script:ui.MemList
    $panel.Children.Clear()
    $script:MemBars = $null
    $o = Get-MemOptions

    $c = New-Xaml $GuideXaml
    $c.FindName('Title').Text = 'Memória agora'
    $c.FindName('Intro').Text = 'A memória "em espera" é o cache do Windows: ela já está disponível para os programas e é usada para abrir as coisas mais rápido. Limpar a memória não aumenta o FPS sozinho; ajuda quando um jogo trava porque a memória livre de verdade acabou, o que é mais comum em PCs com 8 ou 16 GB.'
    $rows = $c.FindName('Rows')
    if (-not $script:Hosted) {
        [void]$rows.Children.Add((New-DiskText 'A leitura e a limpeza da memória só funcionam no Harle.exe.' 12.5 'Muted'))
    } else {
        $bar = New-Object System.Windows.Controls.Grid
        $bar.Height = 18; $bar.Margin = New-Object System.Windows.Thickness 0, 4, 0, 8
        $brushes = @('Amber', 'Red', 'Ice', 'Line')
        $names = @('Em uso', 'Modificada', 'Em espera (cache)', 'Livre')
        $cols = @(); $nums = @()
        for ($i = 0; $i -lt 4; $i++) {
            $cd = New-Object System.Windows.Controls.ColumnDefinition
            $bar.ColumnDefinitions.Add($cd); $cols += $cd
            $seg = New-Object System.Windows.Controls.Border
            $seg.Background = $script:Window.FindResource($brushes[$i])
            $seg.Opacity = $(if ($i -eq 2) { 0.55 } else { 1 })
            [System.Windows.Controls.Grid]::SetColumn($seg, $i)
            [void]$bar.Children.Add($seg)
        }
        [void]$rows.Children.Add($bar)
        $leg = New-Object System.Windows.Controls.UniformGrid
        $leg.Columns = 4
        for ($i = 0; $i -lt 4; $i++) {
            $sp = New-Object System.Windows.Controls.StackPanel
            $sp.Orientation = 'Horizontal'
            $dot = New-Object System.Windows.Shapes.Rectangle
            $dot.Width = 10; $dot.Height = 10; $dot.Margin = New-Object System.Windows.Thickness 0, 0, 7, 0
            $dot.Fill = $script:Window.FindResource($brushes[$i]); $dot.Opacity = $(if ($i -eq 2) { 0.55 } else { 1 })
            $tx = New-Object System.Windows.Controls.StackPanel
            $t1 = New-DiskText $names[$i] 11.5 'Muted'
            $t2 = New-DiskText '--' 16 'Text'; $t2.FontFamily = 'Bahnschrift, Segoe UI'
            [void]$tx.Children.Add($t1); [void]$tx.Children.Add($t2)
            [void]$sp.Children.Add($dot); [void]$sp.Children.Add($tx)
            [void]$leg.Children.Add($sp)
            $nums += $t2
        }
        [void]$rows.Children.Add($leg)
        $note = New-DiskText '' 12 'Muted'; $note.Margin = New-Object System.Windows.Thickness 0, 8, 0, 0
        [void]$rows.Children.Add($note)
        $script:MemBars = @{ Cols = $cols; Nums = $nums; Note = $note; Auto = $null }
    }
    [void]$panel.Children.Add($c)

    # Limpar agora
    $c = New-Xaml $GuideXaml
    $c.FindName('Title').Text = 'Limpar a memória'
    $c.FindName('Intro').Text = 'Escolha o que limpar. Nenhum arquivo é apagado e nenhum programa é fechado.'
    $rows = $c.FindName('Rows')
    $mk = {
        param([string]$Key, [string]$Title, [string]$Body)
        $g = New-Object System.Windows.Controls.Grid
        $g.Margin = New-Object System.Windows.Thickness 0, 6, 0, 6
        $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star); $g.ColumnDefinitions.Add($c1)
        $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = [System.Windows.GridLength]::Auto; $g.ColumnDefinitions.Add($c2)
        $sp = New-Object System.Windows.Controls.StackPanel; $sp.Margin = New-Object System.Windows.Thickness 0, 0, 16, 0
        $t = New-DiskText $Title 13 'Text'; $t.FontWeight = 'SemiBold'
        $d = New-DiskText $Body 12 'Muted'; $d.Margin = New-Object System.Windows.Thickness 0, 2, 0, 0
        [void]$sp.Children.Add($t); [void]$sp.Children.Add($d); [void]$g.Children.Add($sp)
        $sw = New-Object System.Windows.Controls.CheckBox
        $sw.Style = $script:Window.FindResource('Switch'); $sw.VerticalAlignment = 'Center'
        $sw.IsChecked = [bool](Get-MemOptions)[$Key]; $sw.Tag = $Key
        $sw.Add_Click({ param($s, $e) try { Set-MemOption ([string]$s.Tag) ([bool]$s.IsChecked); Update-MemAuto } catch { Show-Error $_ } })
        [System.Windows.Controls.Grid]::SetColumn($sw, 1); [void]$g.Children.Add($sw)
        [void]$rows.Children.Add($g)
    }
    & $mk 'Standby' 'Lista em espera (cache)' 'Libera o cache do Windows. É o que mais devolve memória livre; o Windows volta a encher o cache aos poucos.'
    & $mk 'Low' 'Só a parte de baixa prioridade do cache' 'Versão mais leve: libera só o cache que o Windows considera menos importante. Vale quando a opção de cima está desligada.'
    & $mk 'Modified' 'Lista modificada' 'Grava no disco o que estava esperando para ser gravado e libera essa memória.'
    & $mk 'WorkingSet' 'Memória dos programas abertos (working set)' 'Tira da RAM a parte que os programas não estão usando agora. Libera muito, mas eles recarregam tudo depois, o que pode causar travadas. Deixe desligado se for jogar logo em seguida.'
    $wp = New-Object System.Windows.Controls.WrapPanel
    $wp.Margin = New-Object System.Windows.Thickness 0, 8, 0, 0
    New-OnlineButton $wp 'Limpar a memória agora' 'Primary' $null { try { Invoke-MemClean } catch { Show-Error $_ } }
    [void]$rows.Children.Add($wp)
    [void]$panel.Children.Add($c)

    # Automatico
    $c = New-Xaml $GuideXaml
    $c.FindName('Title').Text = 'Limpeza automática'
    $c.FindName('Intro').Text = 'O Harle confere a memória a cada 5 segundos e limpa só o cache quando a memória livre cai abaixo do limite, com no máximo uma limpeza a cada 30 segundos. Funciona com o Harle aberto (pode ficar minimizado). Nunca mexe na memória dos programas abertos.'
    $rows = $c.FindName('Rows')
    & $mk 'Auto' 'Ligar a limpeza automática' 'Útil em jogos que travam depois de muito tempo abertos.'
    & $mk 'PlayOnly' 'Só durante o modo partida' 'Limpa só enquanto você estiver jogando com o modo partida ligado.'
    $t = New-DiskText 'Limpar quando a memória livre cair abaixo de:' 12.5 'Text'; $t.Margin = New-Object System.Windows.Thickness 0, 8, 0, 6
    [void]$rows.Children.Add($t)
    $seg = New-Object System.Windows.Controls.WrapPanel
    $seg.Margin = New-Object System.Windows.Thickness -6, 0, 0, 4
    foreach ($v in 512, 1024, 2048, 4096) {
        $rb = New-Object System.Windows.Controls.RadioButton
        $rb.Style = $script:Window.FindResource('Seg'); $rb.GroupName = 'MemLimit'
        $rb.Content = Format-MemMB $v; $rb.Tag = $v
        $rb.IsChecked = ([int]$o.Limit -eq $v)
        $rb.Add_Checked({ param($s, $e) try { Set-MemOption 'Limit' ([int]$s.Tag) } catch { Show-Error $_ } })
        [void]$seg.Children.Add($rb)
    }
    [void]$rows.Children.Add($seg)
    $auto = New-DiskText '' 12 'Ice'; $auto.Margin = New-Object System.Windows.Thickness 0, 6, 0, 0
    [void]$rows.Children.Add($auto)
    if ($script:MemBars) { $script:MemBars.Auto = $auto }
    [void]$panel.Children.Add($c)
    Register-Tr $panel
    Update-MemStats
    if ($script:Hosted) { $script:MemViewTimer.Start() }
}

# ----- Jogos: ajustes por jogo e entrada automatica no modo partida -----
$script:GameWatch = New-Object System.Windows.Threading.DispatcherTimer
$script:GameWatch.Interval = [TimeSpan]::FromSeconds(4)
$script:GameSeen = @{}

# Programas com janela que podem ser jogos: fora da pasta do Windows e fora das listas conhecidas.
function Get-GameCandidates {
    $win = [Environment]::GetFolderPath('Windows')
    $have = @(Get-Games | ForEach-Object { [string]$_.Exe })
    $out = @()
    foreach ($p in Get-SessionProcesses) {
        try {
            if ($p.MainWindowHandle -eq [IntPtr]::Zero) { continue }
            if (($script:PlayIgnore -contains $p.ProcessName) -or $script:PlayKnown.ContainsKey($p.ProcessName)) { continue }
            $path = $p.MainModule.FileName
            if (-not $path -or $path.StartsWith($win, [StringComparison]::OrdinalIgnoreCase) -or $have -contains $path) { continue }
            if (@($out | Where-Object { $_.Exe -eq $path }).Count -gt 0) { continue }
            $out += @{ Exe = $path; Name = (Get-GameLabel $path); Title = [string]$p.MainWindowTitle }
        } catch { }
    }
    return @($out | Select-Object -First 8)
}

function Update-GameWatch {
    if ($script:Hosted -and @(Get-Games | Where-Object { $_.Auto }).Count -gt 0) { $script:GameWatch.Start() } else { $script:GameWatch.Stop() }
}

function Step-GameWatch {
    if ($script:Busy -or $script:Play.On) { return }
    $hit = Find-RunningGame (Get-Games) (Get-SessionProcesses)
    if (-not $hit) { return }
    # Uma vez por execucao do jogo: se a pessoa sair do modo partida, o Harle nao insiste.
    if ($script:GameSeen.ContainsKey([string]$hit.Pid)) { return }
    $script:GameSeen[[string]$hit.Pid] = $true
    Write-Log "Jogo da lista aberto: $($hit.Game.Name) (pid $($hit.Pid)); entrando no modo partida"
    Update-PlayView
    Enter-PlayMode
    if ($script:Play.On) {
        $p = Get-Process -Id $hit.Pid -ErrorAction SilentlyContinue
        $boosted = $false
        if ($p) { try { $p.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::High; $boosted = $true } catch { } }
        $script:Play.GamePid = $hit.Pid
        $script:Play.GameName = [string]$hit.Game.Name
        $script:Play.Boosted = $boosted
        Update-PlayTexts
        Set-Status (Tx '{0} aberto: modo partida ligado sozinho.' ([string]$hit.Game.Name))
    }
}
$script:GameWatch.Add_Tick({ try { Step-GameWatch } catch { Write-Log "Jogos: $($_.Exception.Message)" } })

function Add-GameAndRefresh([string]$Exe) {
    if (-not $Exe) { return }
    if (Add-Game $Exe) { Set-Status (Tx '{0} adicionado à lista.' (Get-GameLabel $Exe)) } else { Set-Status 'Esse jogo já está na lista.' }
    Update-GameWatch
    Update-GamesView
}

function New-GameSwitch($Panel, $Game, [string]$Flag, [string]$Title, [string]$Body) {
    $g = New-Object System.Windows.Controls.Grid
    $g.Margin = New-Object System.Windows.Thickness 0, 8, 0, 0
    $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star); $g.ColumnDefinitions.Add($c1)
    $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = [System.Windows.GridLength]::Auto; $g.ColumnDefinitions.Add($c2)
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Margin = New-Object System.Windows.Thickness 0, 0, 16, 0
    $t = New-Object System.Windows.Controls.TextBlock; $t.Text = $Title; $t.FontSize = 13; $t.FontWeight = 'SemiBold'; $t.Foreground = $script:Window.FindResource('Text')
    $b = New-Object System.Windows.Controls.TextBlock; $b.Text = $Body; $b.FontSize = 12; $b.TextWrapping = 'Wrap'; $b.Foreground = $script:Window.FindResource('Muted'); $b.Margin = New-Object System.Windows.Thickness 0, 2, 0, 0
    [void]$sp.Children.Add($t); [void]$sp.Children.Add($b)
    [void]$g.Children.Add($sp)
    $sw = New-Object System.Windows.Controls.CheckBox
    $sw.Style = $script:Window.FindResource('Switch')
    $sw.VerticalAlignment = 'Center'
    $sw.IsChecked = [bool]$Game[$Flag]
    $sw.IsEnabled = -not $script:Busy
    $sw.Tag = "$Flag|$($Game.Exe)"
    $sw.Add_Click({
        param($s, $e)
        try {
            $f = ([string]$s.Tag).Split('|', 2)
            $games = @(Get-Games)
            $gm = @($games | Where-Object { [string]$_.Exe -eq $f[1] }) | Select-Object -First 1
            if (-not $gm) { return }
            $on = [bool]$s.IsChecked
            if ($f[0] -eq 'Auto') { $gm.Auto = $on } else { Set-GameFlag $gm $f[0] $on }
            Save-Games $games
            Write-Log "Jogo $($gm.Name): $($f[0]) = $on"
            Update-GameWatch
            Set-Status $(if ($on) { (Tx '{0}: ligado.' (Tr $(switch ($f[0]) { 'Auto' { 'Modo partida automático' } 'Prio' { 'Prioridade alta' } default { 'Placa de vídeo dedicada' } }))) } else { (Tx '{0}: desligado.' (Tr $(switch ($f[0]) { 'Auto' { 'Modo partida automático' } 'Prio' { 'Prioridade alta' } default { 'Placa de vídeo dedicada' } }))) })
        } catch { Show-Error $_ }
    })
    [System.Windows.Controls.Grid]::SetColumn($sw, 1)
    [void]$g.Children.Add($sw)
    [void]$Panel.Children.Add($g)
}

function Update-GamesView {
    $panel = $script:ui.GamesList
    $panel.Children.Clear()
    $head = New-Xaml $GuideXaml
    $head.FindName('Title').Text = 'Seus jogos'
    $head.FindName('Intro').Text = 'Adicione os jogos que você joga. Para cada um, dá para ligar o modo partida automático (o Harle precisa estar aberto, pode ficar minimizado), prioridade alta fixa pelo próprio Windows e a placa de vídeo dedicada. Tudo volta com Reverter tudo.'
    $rows = $head.FindName('Rows')
    $bar = New-Object System.Windows.Controls.WrapPanel
    New-OnlineButton $bar 'Procurar o .exe do jogo' 'Ghost' $null {
        try {
            $dlg = New-Object Microsoft.Win32.OpenFileDialog
            $dlg.Title = Tr 'Escolha o .exe do jogo'
            $dlg.Filter = (Tr 'Programas') + ' (*.exe)|*.exe'
            if ($dlg.ShowDialog($script:Window)) { Add-GameAndRefresh $dlg.FileName }
        } catch { Show-Error $_ }
    }
    [void]$rows.Children.Add($bar)
    if ($script:Hosted) {
        $cands = @(Get-GameCandidates)
        if ($cands.Count -gt 0) {
            $t = New-Object System.Windows.Controls.TextBlock
            $t.Text = 'Abertos agora (clique para adicionar):'
            $t.FontSize = 12; $t.Margin = New-Object System.Windows.Thickness 0, 6, 0, 6
            $t.Foreground = $script:Window.FindResource('Muted')
            [void]$rows.Children.Add($t)
            $wp = New-Object System.Windows.Controls.WrapPanel
            foreach ($c in $cands) {
                New-OnlineButton $wp ('+ ' + $c.Name) 'Ghost' $c.Exe { param($b, $e) try { Add-GameAndRefresh ([string]$b.Tag) } catch { Show-Error $_ } }
                $wp.Children[$wp.Children.Count - 1].ToolTip = $c.Exe
            }
            [void]$rows.Children.Add($wp)
        }
    }
    [void]$panel.Children.Add($head)

    $games = @(Get-Games)
    if ($games.Count -eq 0) {
        $c = New-Xaml $GuideXaml
        $c.FindName('Title').Text = 'Nenhum jogo na lista'
        $c.FindName('Intro').Text = 'Abra o jogo e volte aqui para adicioná-lo com um clique, ou procure o .exe dele. Jogos da Steam ficam em Steam\steamapps\common; os da Epic, em Epic Games.'
        [void]$panel.Children.Add($c)
    }
    foreach ($g in $games) {
        $c = New-Xaml $GuideXaml
        $c.FindName('Title').Text = [string]$g.Name
        $c.FindName('Intro').Text = [string]$g.Exe
        $c.FindName('Intro').FontSize = 11.5
        $rows = $c.FindName('Rows')
        New-GameSwitch $rows $g 'Auto' 'Modo partida automático' 'Quando o jogo abre, o Harle fecha o que está marcado no modo partida e dá prioridade alta ao jogo. Quando o jogo fecha, tudo volta.'
        New-GameSwitch $rows $g 'Prio' 'Prioridade alta' 'O próprio Windows abre o jogo sempre com prioridade alta de processador, mesmo com o Harle fechado. Se o anti-cheat do jogo reclamar, desligue.'
        New-GameSwitch $rows $g 'Gpu' 'Placa de vídeo dedicada' 'Obriga o jogo a usar a placa de vídeo dedicada. Só muda algo em PCs com duas placas, como notebooks com vídeo integrado; em PCs com uma placa, não faz diferença.'
        $wp = New-Object System.Windows.Controls.WrapPanel
        $wp.Margin = New-Object System.Windows.Thickness 0, 10, 0, 0
        New-OnlineButton $wp 'Tirar da lista' 'Ghost' ([string]$g.Exe) {
            param($b, $e)
            try {
                $all = @(Get-Games)
                $gm = @($all | Where-Object { [string]$_.Exe -eq [string]$b.Tag }) | Select-Object -First 1
                if ($gm) { Reset-GameFlags $gm }
                Save-Games @($all | Where-Object { [string]$_.Exe -ne [string]$b.Tag })
                Update-GameWatch
                Set-Status 'Jogo tirado da lista; os ajustes dele foram desfeitos.'
                Update-GamesView
            } catch { Show-Error $_ }
        }
        [void]$rows.Children.Add($wp)
        [void]$panel.Children.Add($c)
    }
    Register-Tr $panel
}

# ----- Historico de FPS em grafico (tela Medicao) -----
$script:FpsChartApp = ''

function Update-FpsChart {
    $box = $script:ui.FpsChart
    $box.Children.Clear()
    $list = @($script:Backup.state['fps'] | Where-Object { $_ })
    $apps = @(Get-FpsApps $list)
    if ($apps.Count -eq 0) { $box.Visibility = 'Collapsed'; return }
    $box.Visibility = 'Visible'
    if ($apps -notcontains $script:FpsChartApp) { $script:FpsChartApp = [string]$list[$list.Count - 1].App; if ($apps -notcontains $script:FpsChartApp) { $script:FpsChartApp = $apps[0] } }
    if ($apps.Count -gt 1) {
        $sel = New-Object System.Windows.Controls.WrapPanel
        $sel.Margin = New-Object System.Windows.Thickness -6, 0, 0, 10
        foreach ($a in $apps) {
            $rb = New-Object System.Windows.Controls.RadioButton
            $rb.Style = $script:Window.FindResource('Seg'); $rb.GroupName = 'FpsApp'; $rb.Content = $a; $rb.Tag = $a
            $rb.IsChecked = ($a -eq $script:FpsChartApp)
            $rb.Add_Checked({ param($s, $e) try { $script:FpsChartApp = [string]$s.Tag; Update-FpsChart } catch { Show-Error $_ } })
            [void]$sel.Children.Add($rb)
        }
        [void]$box.Children.Add($sel)
    }
    $W = 620.0; $H = 150.0; $L = 40.0
    $ch = Get-FpsChart $list $script:FpsChartApp $W $H
    $cv = New-Object System.Windows.Controls.Canvas
    $cv.Width = $W + $L + 20; $cv.Height = $H + 30
    $cv.HorizontalAlignment = 'Left'
    $line = $script:Window.FindResource('Line'); $muted = $script:Window.FindResource('Muted')
    foreach ($f in 0, 0.5, 1) {
        $y = $H - $H * $f
        $gl = New-Object System.Windows.Shapes.Line
        $gl.X1 = $L; $gl.X2 = $L + $W; $gl.Y1 = $y; $gl.Y2 = $y; $gl.Stroke = $line; $gl.StrokeThickness = 1
        [void]$cv.Children.Add($gl)
        $lb = New-Object System.Windows.Controls.TextBlock
        $lb.Text = [string][int]($ch.Max * $f); $lb.FontSize = 10.5; $lb.Foreground = $muted
        [System.Windows.Controls.Canvas]::SetLeft($lb, 0); [System.Windows.Controls.Canvas]::SetTop($lb, $y - 8)
        [void]$cv.Children.Add($lb)
    }
    foreach ($serie in @(@($ch.Avg, 'Amber', 'FPS médio'), @($ch.Low, 'Ice', '1% low'))) {
        $pl = New-Object System.Windows.Shapes.Polyline
        $pl.Stroke = $script:Window.FindResource($serie[1]); $pl.StrokeThickness = 2.5
        $pts = New-Object System.Windows.Media.PointCollection
        foreach ($p in $serie[0]) { $pts.Add((New-Object System.Windows.Point ($L + $p[0]), $p[1])) }
        $pl.Points = $pts
        [void]$cv.Children.Add($pl)
        for ($i = 0; $i -lt $serie[0].Count; $i++) {
            $p = $serie[0][$i]; $m = $ch.Items[$i]
            $dot = New-Object System.Windows.Shapes.Ellipse
            $dot.Width = 9; $dot.Height = 9; $dot.Fill = $script:Window.FindResource($serie[1])
            $dot.ToolTip = (Tx '{0}: {1:N1} FPS de média, {2:N1} FPS de 1% low' ([string]$m.When) ([double]$m.Avg) ([double]$m.Low)) + "`n" + (Tx '{0} ajustes ativos' ([int]$m.Active))
            [System.Windows.Controls.Canvas]::SetLeft($dot, $L + $p[0] - 4.5); [System.Windows.Controls.Canvas]::SetTop($dot, $p[1] - 4.5)
            [void]$cv.Children.Add($dot)
        }
    }
    for ($i = 0; $i -lt $ch.Labels.Count; $i++) {
        $lb = New-Object System.Windows.Controls.TextBlock
        $lb.Text = $ch.Labels[$i]; $lb.FontSize = 10.5; $lb.Foreground = $muted
        [System.Windows.Controls.Canvas]::SetLeft($lb, $L + $ch.Avg[$i][0] - 14); [System.Windows.Controls.Canvas]::SetTop($lb, $H + 8)
        [void]$cv.Children.Add($lb)
    }
    $vb = New-Object System.Windows.Controls.Viewbox
    $vb.Stretch = 'Uniform'; $vb.StretchDirection = 'DownOnly'; $vb.HorizontalAlignment = 'Left'
    $vb.Child = $cv
    [void]$box.Children.Add($vb)
    $leg = New-Object System.Windows.Controls.TextBlock
    $leg.FontSize = 12; $leg.Margin = New-Object System.Windows.Thickness 0, 6, 0, 0; $leg.Foreground = $muted; $leg.TextWrapping = 'Wrap'
    $first = $ch.Items[0]; $last = $ch.Items[$ch.Items.Count - 1]
    $pct = if ([double]$first.Avg -gt 0) { 100.0 * ([double]$last.Avg - [double]$first.Avg) / [double]$first.Avg } else { 0 }
    $leg.Text = (Tx 'Linha azul: FPS médio. Linha verde: 1% low. Da primeira para a última medição: {0:+0.0;-0.0;0.0}% no FPS médio. Passe o mouse nos pontos para ver os detalhes.' $pct)
    [void]$box.Children.Add($leg)
    Register-Tr $box
}

# ----- Guia -----
$script:Guide = @(
    @{ Title = 'Painel de Controle da NVIDIA'
       Intro = 'Os perfis Competitivo e Equilibrado já gravam no driver os três primeiros itens. Para conferir ou mudar o resto: Painel de Controle da NVIDIA, Gerenciar as configurações em 3D, aba de configurações globais.'
       Rows = @(
           @('Modo de gerenciamento de energia', 'Preferência por desempenho máximo.'),
           @('Modo de latência baixa', 'Ativado. Em jogos com NVIDIA Reflex, ligue o Reflex dentro do jogo; ele assume o controle da latência.'),
           @('Filtro de textura, qualidade', 'Alto desempenho.'),
           @('Tamanho do cache de shader', 'Deixe em Padrão do driver, que nos drivers atuais já é grande. Valores pequenos causam travadas de compilação.'),
           @('Sincronização vertical', 'Desligada no painel. Com monitor G-Sync ou FreeSync, limite o FPS 3 abaixo da taxa do monitor.')
       ) }
    @{ Title = 'AMD Software: Adrenalin Edition'
       Intro = 'Para quem tem placa Radeon. Os perfis Competitivo e Equilibrado já ligam o Anti-Lag e desligam o Chill. O resto fica em Jogos, Gráficos.'
       Rows = @(
           @('Radeon Anti-Lag', 'Ligado. Reduz o atraso entre o comando e a imagem.'),
           @('Radeon Chill', 'Desligado. Ele limita o FPS para economizar energia.'),
           @('Qualidade da filtragem de textura', 'Desempenho.'),
           @('Aguardar atualização vertical', 'Desligado, a menos que o aplicativo especifique.'),
           @('FSR dentro do jogo', 'Qualidade ou Equilibrado em 1080p, quando o jogo oferecer.')
       ) }
    @{ Title = 'Dentro dos jogos'
       Intro = 'O que mais pesa é passar do limite da memória de vídeo da placa. A quantidade da sua está na tela Scanner.'
       Rows = @(
           @('DLSS ou FSR', 'Qualidade ou Equilibrado em 1080p. É o ajuste que mais levanta o FPS em placas de entrada.'),
           @('Texturas', 'Com até 6 GB de memória de vídeo, Médio ou Alto; Ultra estoura a memória em jogos recentes e causa travadas fortes. Com 8 GB ou mais, Alto ou Ultra.'),
           @('Ray tracing', 'Desligado em placas de entrada, como RTX 3050 e RX 6600. O custo é alto demais para elas.'),
           @('Sombras e volumétricos', 'Médio. São os efeitos que mais pesam e menos aparecem.'),
           @('NVIDIA Reflex', 'Ligado + Boost nos jogos competitivos que oferecem.')
       ) }
    @{ Title = 'Hábitos que valem mais que qualquer ajuste'
       Intro = ''
       Rows = @(
           @('Driver de vídeo', 'Atualize pelo app da NVIDIA ou da AMD quando sair um jogo que você vai jogar.'),
           @('Driver de chipset', 'Em PCs com Ryzen, instale o driver de chipset pelo site da AMD; ele ajusta o agendamento dos núcleos.'),
           @('Programas abertos', 'Com 16 GB de RAM ou menos, feche o navegador e os launchers parados antes de um jogo pesado. O modo partida faz isso por você.'),
           @('Temperatura', 'Se o processador passar de 85 °C em jogo, limpe o cooler e troque a pasta térmica; calor demais derruba o FPS.')
       ) }
)

# Impressao digital do Harle.exe: quem baixou compara com a da pagina de Releases.
function Get-SelfHash {
    try {
        $exe = $env:HARLE_EXE
        if ($script:Hosted -and $exe -and (Test-Path -LiteralPath $exe)) {
            $sha = [Security.Cryptography.SHA256]::Create()
            $fs = [IO.File]::OpenRead($exe)
            try { $h = $sha.ComputeHash($fs) } finally { $fs.Dispose(); $sha.Dispose() }
            return (Tx "{0}`nIgual ao da página de Releases = arquivo original, sem alteração." (([BitConverter]::ToString($h)).Replace('-', '')))
        }
    } catch { }
    return 'Só no Harle.exe'
}

$script:About = @(
    @{ Title = 'Harle Optimizer'
       Intro = (Tx 'Versão {0}. Otimizador de Windows para jogos, com scanner de hardware, medição de FPS, monitor com overlay e alerta de temperatura, modo partida e perfis de driver.' ($($script:AppVersion)))
       Rows = @(
           @('Criado por', 'Harle'),
           @('Comunidade no Discord', 'discord.gg/rDb9raznQ7'),
           @('Código aberto', 'Licença GPL-3.0. O código e a compilação de cada versão ficam em github.com/Harlezinhuu/HarleOptimizer.'),
           @('Versões novas', 'github.com/Harlezinhuu/HarleOptimizer, na parte Releases. O Harle avisa ao abrir quando sai uma versão mais nova.'),
           @('O que ele muda', 'Tudo aparece na tela Otimizar. O valor original de cada ajuste fica guardado em C:\ProgramData\Harle\backup.json, e Reverter tudo devolve o Windows ao que era.'),
           @('Registro de atividades', 'C:\ProgramData\Harle\harle.log'),
           @('Conferir o arquivo (SHA-256)', (Get-SelfHash)),
           @('Pedir ajuda', 'O botão Copiar relatório, aqui e na tela Scanner, junta as specs, os ajustes ligados e o fim do registro em um texto pronto para colar no Discord. O nome da sua conta do Windows é trocado por "(conta)".')
       ) }
    @{ Title = 'Peças de terceiros'
       Intro = 'O Harle usa estes componentes, cada um do seu autor.'
       Rows = @(
           @('PresentMon 2.6.0', 'Medição de FPS e contador de FPS do overlay. Copyright Intel Corporation, licença MIT. O texto da licença é extraído junto com o programa, em C:\Program Files\Harle.'),
           @('NVAPI e NVML', 'Interfaces da NVIDIA usadas para gravar o perfil global do driver, ler os sensores da tela Monitor e deslocar os clocks na aba AVANÇADO.'),
           @('AMD Display Library', 'Interface da AMD usada para ligar o Radeon Anti-Lag, desligar o Radeon Chill e ler os sensores da tela Monitor.'),
           @('PowerShell e WPF', 'Motor dos ajustes e da interface. São da Microsoft e já vêm no Windows.')
       ) }
)

function Initialize-Guide {
    Add-Cards $script:ui.GuideList $script:Guide
    Add-Cards $script:ui.AboutList $script:About
    # Botao do Discord logo abaixo do primeiro cartao dos creditos.
    $b = New-Object System.Windows.Controls.Button
    $b.Style = $script:Window.FindResource('Primary')
    $b.Content = 'Entrar no Discord do Harle'
    $b.FontSize = 13
    $b.Padding = New-Object System.Windows.Thickness 18, 10, 18, 10
    $b.Margin = New-Object System.Windows.Thickness 0, 0, 0, 12
    $b.Add_Click({
        try {
            # Pelo explorer.exe o navegador abre sem permissao de administrador.
            Start-Process -FilePath 'explorer.exe' -ArgumentList $script:DiscordUrl
            Set-Status 'Abrindo o Discord do Harle no navegador.'
        } catch { Show-Error $_ }
    })
    $r = New-Object System.Windows.Controls.Button
    $r.Style = $script:Window.FindResource('Ghost')
    $r.Content = 'Copiar relatório para pedir ajuda'
    $r.Padding = New-Object System.Windows.Thickness 18, 10, 18, 10
    $r.Margin = New-Object System.Windows.Thickness 10, 0, 0, 12
    $r.Add_Click({ try { Copy-Report } catch { Show-Error $_ } })
    $bar = New-Object System.Windows.Controls.StackPanel
    $bar.Orientation = 'Horizontal'
    [void]$bar.Children.Add($b)
    [void]$bar.Children.Add($r)
    $script:ui.AboutList.Children.Insert(1, $bar)
    # A logo, maior, no topo dos creditos.
    if ($script:LogoBrush) {
        $big = New-Object System.Windows.Controls.Border
        $big.Width = 112; $big.Height = 112
        $big.CornerRadius = New-Object System.Windows.CornerRadius 26
        $big.HorizontalAlignment = 'Left'
        $big.Margin = New-Object System.Windows.Thickness 0, 0, 0, 14
        $big.Background = $script:LogoBrush
        $script:ui.AboutList.Children.Insert(0, $big)
    }
}

function Add-Cards($Target, $Cards) {
    foreach ($g in $Cards) {
        $card = New-Xaml $GuideXaml
        $card.FindName('Title').Text = $g.Title
        $intro = $card.FindName('Intro')
        if ($g.Intro) { $intro.Text = $g.Intro } else { $intro.Visibility = 'Collapsed' }
        $panel = $card.FindName('Rows')
        foreach ($r in $g.Rows) {
            $row = New-Xaml $RowXaml
            $row.Margin = New-Object System.Windows.Thickness 0, 6, 0, 6
            $row.ColumnDefinitions[0].Width = New-Object System.Windows.GridLength 210
            $k = $row.FindName('K'); $k.Text = $r[0]; $k.TextWrapping = 'Wrap'; $k.Margin = New-Object System.Windows.Thickness 0, 0, 16, 0
            $k.Foreground = $script:Window.FindResource('Text')
            $v = $row.FindName('V'); $v.Text = $r[1]; $v.LineHeight = 18.5
            $v.Foreground = $script:Window.FindResource('Muted')
            [void]$panel.Children.Add($row)
        }
        [void]$Target.Children.Add($card)
    }
}

# ----- Navegacao -----
function Show-Page([string]$Key) {
    $ui = $script:ui
    $p = $script:Pages[$Key]
    $ui.PageTitle.Text = $p.Title
    $ui.PageSub.Text   = $p.Sub
    $script:Page = $Key
    $ui.ConfirmOverlay.Visibility = 'Collapsed'
    foreach ($n in 'PageHome', 'PageTune', 'PageMeasure', 'PageMonitor', 'PagePlay', 'PageBoot', 'PageApps', 'PageScan', 'PageUpgrade', 'PageBios', 'PageHealth', 'PageDisks', 'PageOnline', 'PageGames', 'PageMem', 'PageDrv', 'PageGuide', 'PageAbout', 'PageAdvanced') { $ui[$n].Visibility = 'Collapsed' }
    Update-SensorTimer
    $ui.BtnRefresh.Visibility = if ('measure', 'play', 'boot', 'apps', 'scan', 'upgrade', 'bios', 'health', 'disks', 'online', 'games', 'drv' -contains $Key) { 'Visible' } else { 'Collapsed' }
    $ui.BtnRefresh.Content = if ('scan', 'upgrade', 'bios' -contains $Key) { 'Escanear de novo' } elseif ($Key -eq 'health') { 'Verificar de novo' } elseif ($Key -eq 'disks') { 'Ler de novo' } else { 'Atualizar' }
    switch ($Key) {
        'home'    { $ui.PageHome.Visibility = 'Visible' }
        'tune'    { $ui.PageTune.Visibility = 'Visible'; Update-TuneView }
        'measure' { $ui.PageMeasure.Visibility = 'Visible'; Update-MeasureView }
        'play'    { $ui.PagePlay.Visibility = 'Visible'; Update-PlayView }
        'boot'    { $ui.PageBoot.Visibility = 'Visible'; Update-BootView }
        'apps'    { $ui.PageApps.Visibility = 'Visible'; Update-AppsView }
        'scan'    { $ui.PageScan.Visibility = 'Visible' }
        'upgrade' { $ui.PageUpgrade.Visibility = 'Visible'; Update-UpgradeView }
        'bios'    { $ui.PageBios.Visibility = 'Visible'; Update-BiosView }
        'health'  { $ui.PageHealth.Visibility = 'Visible'; Update-HealthView; if ($null -eq $script:Health) { Invoke-HealthScan; Update-HealthView } }
        'online'  { $ui.PageOnline.Visibility = 'Visible'; Update-OnlineView }
        'games'   { $ui.PageGames.Visibility = 'Visible'; Update-GamesView }
        'mem'     { $ui.PageMem.Visibility = 'Visible'; Update-MemView }
        'drv'     { $ui.PageDrv.Visibility = 'Visible'; Update-DriversView }
        'disks'   { $ui.PageDisks.Visibility = 'Visible'; Update-DiskView; if ($null -eq $script:Disks) { Invoke-DiskScan; Update-DiskView } }
        'guide'   { $ui.PageGuide.Visibility = 'Visible' }
        'about'   { $ui.PageAbout.Visibility = 'Visible' }
        'monitor' { $ui.PageMonitor.Visibility = 'Visible'; Update-GameTools; Step-Sensors }
        'advanced' { $ui.PageAdvanced.Visibility = 'Visible'; Update-OcView -Read }
    }
}

# ----- Eventos -----
$script:NavMap = @{ NavHome = 'home'; NavTune = 'tune'; NavMeasure = 'measure'; NavPlay = 'play'; NavBoot = 'boot'; NavApps = 'apps'; NavScan = 'scan'; NavUpgrade = 'upgrade'; NavBios = 'bios'; NavHealth = 'health'; NavDisks = 'disks'; NavOnline = 'online'; NavGames = 'games'; NavMem = 'mem'; NavDrv = 'drv'; NavGuide = 'guide'; NavAbout = 'about'; NavMonitor = 'monitor'; NavAdvanced = 'advanced' }
foreach ($name in $script:NavMap.Keys) {
    $script:ui[$name].Add_Checked({
        param($s, $e)
        try { Show-Page $script:NavMap[$s.Name] } catch { Show-Error $_ }
    })
}

$script:ui.DragArea.Add_MouseLeftButtonDown({ try { $script:Window.DragMove() } catch { } })
$script:ui.RailArea.Add_MouseLeftButtonDown({ try { $script:Window.DragMove() } catch { } })
$script:ui.BtnClose.Add_Click({ $script:Window.Close() })
$script:ui.BtnMin.Add_Click({ $script:Window.WindowState = 'Minimized' })
# Trocar o idioma reabre o Harle: e o jeito seguro de todos os textos trocarem juntos.
$script:ui.BtnLang.Content = if ($script:Lang -eq 'en') { 'PT' } else { 'EN' }
$script:ui.BtnLang.ToolTip = if ($script:Lang -eq 'en') { 'Mudar o idioma para português' } else { 'Mudar o idioma para inglês' }
$script:ui.BtnLang.Add_Click({
    try {
        if ($script:Busy) { Set-Status 'Espere o trabalho em andamento terminar para trocar o idioma.'; return }
        $script:Backup.state['lang'] = $(if ($script:Lang -eq 'en') { 'pt' } else { 'en' })
        Save-Backup
        if ($script:Hosted -and $env:HARLE_EXE) { Start-Process -FilePath $env:HARLE_EXE }
        elseif ($PSCommandPath) { Start-Process -FilePath 'powershell.exe' -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Elevated" }
        $script:Window.Close()
    } catch { Show-Error $_ }
})

# O que a pessoa mais vai notar; aparece antes de aplicar.
$script:ConfirmItems = @(
    @('Widgets e Copilot somem', 'O botão de Widgets sai da barra de tarefas e o Copilot do Windows é desligado. A aparência das janelas continua igual.'),
    @('Alguns hábitos mudam', 'O OneDrive deixa de abrir sozinho, a aceleração do mouse é desligada, a pesquisa do menu Iniciar para de buscar na internet e parte da coleta de dados da Microsoft é desligada.'),
    @('Apps são removidos', 'Saem os que estiverem marcados na tela Apps. Sem mexer lá, são os recomendados: notícias e apps do Bing, Paciência, Clipchamp, Skype, Cortana, o app do Copilot, Candy Crush, TikTok e outros promocionais. Para escolher, cancele e abra a tela Apps antes. Não voltam sozinhos.'),
    @('Arquivos temporários são apagados', 'Temporários do Windows e downloads antigos do Windows Update. Seus arquivos pessoais não são tocados.'),
    @('Dá para voltar atrás', 'Um ponto de restauração é criado antes, e Reverter tudo desfaz os ajustes. Só os apps removidos e os arquivos apagados não voltam.')
)
$script:ConfirmMode = 'profile'
Set-ConfirmItems $script:ConfirmItems

$script:ui.BtnOptimize.Add_Click({
    try {
        if ($script:Busy) { return }
        $p = Get-Profile
        $d = Get-ProfileDiff
        # Com o perfil ja aplicado, o botao so refaz a limpeza: nao ha o que avisar.
        if (($d.On.Count + $d.Off.Count) -eq 0) { Invoke-OptimizeAll; return }
        $off = if ($d.Off.Count -gt 0) { (Tx ' e desliga {0} que não fazem parte dele' ($($d.Off.Count))) } else { '' }
        $script:ConfirmMode = 'profile'
        Set-ConfirmItems $script:ConfirmItems
        $script:ui.ConfirmIntro.Text = (Tx 'O perfil {0} liga {1} ajustes{2}, e faz a limpeza. Se preferir escolher, cancele e use os botões da lista. O que você mais vai notar:' ($($p.Label)) ($($d.On.Count)) ($off))
        $script:ui.BtnConfirmYes.Content = (Tx 'Aplicar perfil {0}' (Tr $p.Label))
        $script:ui.ConfirmOverlay.Visibility = 'Visible'
    } catch { Show-Error $_ }
})
$script:ui.BtnConfirmNo.Add_Click({ $script:ui.ConfirmOverlay.Visibility = 'Collapsed' })
$script:ui.BtnConfirmYes.Add_Click({
    try {
        $script:ui.ConfirmOverlay.Visibility = 'Collapsed'
        Update-Ui
        if ($script:ConfirmMode -eq 'debloat') { Invoke-Debloat } elseif ($script:ConfirmMode -eq 'import') { Invoke-ImportConfig } else { Invoke-OptimizeAll }
    } catch { Show-Error $_ }
})
$script:ui.BtnRevertAll.Add_Click({ try { Invoke-RevertAll } catch { Show-Error $_ } })
$script:ui.BtnCfgSave.Add_Click({ try { Export-HarleConfig } catch { Show-Error $_ } })
$script:ui.BtnCfgLoad.Add_Click({ try { Import-HarleConfig } catch { Show-Error $_ } })
$script:ui.BtnRefresh.Add_Click({
    try {
        if ($script:Busy) { return }
        switch ($script:Page) {
            'scan'    { Invoke-Scan }
            'upgrade' { Invoke-Scan; Update-UpgradeView }
            'bios'    { Invoke-Scan; Update-BiosView }
            'health'  { Invoke-HealthScan; Update-HealthView }
            'disks'   { Invoke-DiskScan; Update-DiskView }
            'online'  { Update-OnlineView; Set-Status 'Lista de overlays atualizada.' }
            'games'   { Update-GamesView; Set-Status 'Lista atualizada.' }
            'drv'     { Invoke-DriverScan }
            'measure' { Update-MeasureView; Set-Status 'Medição atualizada.' }
            'play'    { Update-PlayView;    Set-Status 'Lista atualizada.' }
            'boot'    { Update-BootView;    Set-Status 'Lista atualizada.' }
            'apps'    { Update-AppsView -Scan }
        }
    } catch { Show-Error $_ }
})
$script:ui.BtnMeasure.Add_Click({ try { Invoke-FpsMeasure } catch { Show-Error $_ } })
$script:ui.BtnAppsRemove.Add_Click({ try { Invoke-AppsRemove } catch { Show-Error $_ } })
$script:ui.BtnTuneAll.Add_Click({ try { Show-Tune 'all' } catch { Show-Error $_ } })
$script:ui.BtnCard.Add_Click({ try { if (-not $script:Busy) { New-ResultCard } } catch { Show-Error $_ } })
$script:ui.BtnReport.Add_Click({ try { Copy-Report } catch { Show-Error $_ } })
$script:ui.OvToggle.Add_Click({ param($s, $e) try { Set-Overlay ([bool]$s.IsChecked) } catch { Show-Error $_ } })
$script:ui.AlertToggle.Add_Click({ param($s, $e) try { Set-TempAlert ([bool]$s.IsChecked) $script:Alert.Limit } catch { Show-Error $_ } })
$script:ui.BtnAlertUp.Add_Click({   try { Set-TempAlert $script:Alert.On ($script:Alert.Limit + 5) } catch { Show-Error $_ } })
$script:ui.BtnAlertDown.Add_Click({ try { Set-TempAlert $script:Alert.On ($script:Alert.Limit - 5) } catch { Show-Error $_ } })
foreach ($i in 0..3) {
    $rb = $script:ui["OvCorner$i"]
    $rb.Tag = $i
    $rb.Add_Checked({
        param($s, $e)
        try {
            $c = [int]$s.Tag
            if ($c -eq [int]$script:Ov.Corner) { return }
            $script:Ov.Corner = $c
            $script:Backup.state['ovCorner'] = $c
            Save-Backup
            if ($script:Ov.Win -and $script:Ov.Win.IsVisible) { [void][Harle.Native]::PlaceOverlay($script:Ov.Hwnd, $c, 12) }
        } catch { Show-Error $_ }
    })
}
$script:ui.OcAgree.Add_Click({ try { Update-OcView } catch { Show-Error $_ } })
$script:ui.BtnOcCoreUp.Add_Click({   try { Step-Oc 'Core'  1 } catch { Show-Error $_ } })
$script:ui.BtnOcCoreDown.Add_Click({ try { Step-Oc 'Core' -1 } catch { Show-Error $_ } })
$script:ui.BtnOcMemUp.Add_Click({    try { Step-Oc 'Mem'   1 } catch { Show-Error $_ } })
$script:ui.BtnOcMemDown.Add_Click({  try { Step-Oc 'Mem'  -1 } catch { Show-Error $_ } })
$script:ui.BtnOcApply.Add_Click({ try { Set-Oc $script:OcWanted.Core $script:OcWanted.Mem } catch { Show-Error $_ } })
$script:ui.BtnOcReset.Add_Click({ try { Set-Oc 0 0 } catch { Show-Error $_ } })

# Aviso de versao nova: so aparece se o GitHub tiver uma versao maior que esta.
$script:UpdateUrl = ''
$script:UpdateNew = $null
function Invoke-UpdateCheck {
    if (-not $script:UpdateRepo) { return }
    $r = @(Invoke-Background $script:UpdateCode @{ Repo = $script:UpdateRepo })
    $line = if ($r.Count -gt 0) { [string]$r[$r.Count - 1] } else { '' }
    $f = $line -split '\|'
    $new = Get-NewerVersion $f[0]
    if (-not $new) { return }
    $script:UpdateUrl = (Tx 'https://github.com/{0}/releases/latest' ($($script:UpdateRepo)))
    # Com o exe e o .sha256 na Release, o botao atualiza sozinho; sem eles, abre a pagina como antes.
    if ($script:Hosted -and $f.Count -ge 4 -and $f[2] -and $f[3]) { $script:UpdateNew = @{ Version = $new; Exe = $f[2]; Sha = $f[3] } }
    $script:ui.BtnUpdate.Content = if ($script:UpdateNew) { (Tx 'Atualizar para a {0}' ($new)) } else { (Tx 'Baixar a versão {0}' ($new)) }
    $script:ui.BtnUpdate.Visibility = 'Visible'
    Write-Log "Versao nova disponivel: $new"
}
function Invoke-SelfUpdate {
    if ($script:Busy) { return }
    $u = $script:UpdateNew
    $cur = $env:HARLE_EXE
    if (-not $u -or -not $cur -or -not (Test-Path -LiteralPath $cur)) { return }
    Set-Busy $true
    $ok = $false
    try {
        Set-Status (Tx 'Baixando a versão {0} e conferindo o SHA-256...' ($u.Version))
        $r = @(Invoke-Background $script:SelfUpdateCode @{ ExeUrl = $u.Exe; ShaUrl = $u.Sha; Version = $u.Version })
        $line = if ($r.Count -gt 0) { [string]$r[$r.Count - 1] } else { 'erro|rede' }
        Write-Log "Atualizacao $($u.Version): $line"
        $f = $line.Split('|')
        if ($f[0] -ne 'ok') {
            $why = switch ($f[1]) {
                'hash'   { 'o arquivo baixado não bate com o SHA-256 publicado. Nada foi trocado.' }
                'versao' { 'o arquivo baixado não é da versão anunciada. Nada foi trocado.' }
                'sha'    { 'a Release não tem um SHA-256 válido. Nada foi trocado.' }
                default  { 'não deu para baixar (sem internet ou o GitHub não respondeu). Nada foi trocado.' }
            }
            Set-Status ((Tx 'A atualização parou: {0}' (Tr $why)) + ' ' + (Tr 'Dá para baixar pela página da versão nova.'))
            $script:UpdateNew = $null
            $script:ui.BtnUpdate.Content = (Tx 'Baixar a versão {0}' ($u.Version))
            return
        }
        # O Windows deixa renomear um exe em uso: o atual vira .old (apagado na proxima abertura) e o novo entra no lugar.
        $old = "$cur.old"
        if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $old) { $old = "$cur.$([DateTime]::Now.Ticks).old" }
        Move-Item -LiteralPath $cur -Destination $old -Force -ErrorAction Stop
        try { Move-Item -LiteralPath $f[1] -Destination $cur -Force -ErrorAction Stop }
        catch { Move-Item -LiteralPath $old -Destination $cur -Force -ErrorAction SilentlyContinue; throw }
        # A copia em Program Files (tarefas do login) acompanha a versao nova.
        if ((Test-HarleTask $script:GuardTask) -or (Test-HarleTask $script:TimerTask)) { try { Install-HarleExe } catch { Write-Log "Copia em Program Files: $($_.Exception.Message)" } }
        Write-Log "Atualizado para $($u.Version) (SHA-256 $($f[2]))"
        $ok = $true
    } catch { Show-Error $_ } finally { Set-Busy $false }
    if ($ok) {
        Set-Status (Tx 'Versão {0} instalada e conferida. Reabrindo o Harle...' ($u.Version))
        Update-Ui
        Start-Process -FilePath $cur
        $script:Window.Close()
    }
}

# Sobra da atualizacao anterior: o exe antigo renomeado para .old.
function Remove-UpdateLeftovers {
    try {
        $cur = $env:HARLE_EXE
        if (-not $script:Hosted -or -not $cur) { return }
        foreach ($f in @(Get-ChildItem -LiteralPath (Split-Path -Parent $cur) -Filter ((Split-Path -Leaf $cur) + '*.old') -Force -ErrorAction SilentlyContinue)) {
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
        }
    } catch { }
}

$script:ui.BtnUpdate.Add_Click({
    try {
        if ($script:UpdateNew) { Invoke-SelfUpdate; return }
        if ($script:UpdateUrl) { Start-Process -FilePath 'explorer.exe' -ArgumentList $script:UpdateUrl; Set-Status 'Abrindo a página da versão nova no navegador.' }
    } catch { Show-Error $_ }
})
$script:ui.BtnPlay.Add_Click({
    try {
        if ($script:Busy) { return }
        if ($script:Play.On) { Exit-PlayMode 'Você saiu.' } else { Enter-PlayMode }
    } catch { Show-Error $_ }
})

$script:ui.BtnRestart.Add_Click({
    try {
        if ($script:RestartPending) { Stop-Restart } else { Start-Restart 15 }
    } catch { Show-Error $_ }
})
$script:ui.AutoRestart.Add_Click({
    param($s, $e)
    try {
        $script:AutoRestart = [bool]$s.IsChecked
        $script:Backup.state['autoRestart'] = $script:AutoRestart
        Save-Backup
    } catch { Show-Error $_ }
})

$script:ui.BtnExport.Add_Click({
    try {
        $list = @($script:Tweaks | Where-Object { $_.Reg -and -not $_.Optional })
        $dir  = [Environment]::GetFolderPath('Desktop')
        $f1 = Join-Path $dir 'Harle - aplicar.reg'
        $f2 = Join-Path $dir 'Harle - desfazer.reg'
        [IO.File]::WriteAllText($f1, (Get-RegFileText $list $false), [Text.Encoding]::Unicode)
        [IO.File]::WriteAllText($f2, (Get-RegFileText $list $true),  [Text.Encoding]::Unicode)
        Set-Status 'Dois arquivos salvos na Área de Trabalho: "Harle - aplicar.reg" e "Harle - desfazer.reg".'
    } catch { Show-Error $_ }
})

# Fechar no meio de uma otimizacao deixaria o trabalho pela metade.
$script:Window.Add_Closing({
    param($s, $e)
    if ($script:Busy) { $e.Cancel = $true; Set-Status 'Espere o trabalho em andamento terminar para fechar.'; return }
    if ($script:Play.On) { try { Exit-PlayMode 'O Harle foi fechado.' } catch { } }
    try { $script:MonTimer.Stop(); Stop-FpsFeed } catch { }
    try { if ($script:Ov.Win) { $script:Ov.Win.Close() } } catch { }
})

# ----- Icone da janela -----
try {
    $dv = New-Object System.Windows.Media.DrawingVisual
    $dc = $dv.RenderOpen()
    $dc.DrawRoundedRectangle($script:Window.FindResource('Heat'), $null, (New-Object System.Windows.Rect 0, 0, 64, 64), 15, 15)
    $dc.DrawGeometry($script:Window.FindResource('Ink'), $null, [System.Windows.Media.Geometry]::Parse('M32,4 C38,13 42.5,21 42.5,28 L32,45 L21.5,28 C21.5,21 26,13 32,4 Z M30.3,43 L33.7,43 L33.7,60 L30.3,60 Z M20,29 C14,19 7,18 3,23 C8,24 12,27 16.5,34 Z M18.5,36 C13,31 8,31.5 5.5,35.5 C9.5,36 13,38 17.5,42 Z M44,29 C50,19 57,18 61,23 C56,24 52,27 47.5,34 Z M45.5,36 C51,31 56,31.5 58.5,35.5 C54.5,36 51,38 46.5,42 Z'))
    $dc.Close()
    $bmp = New-Object System.Windows.Media.Imaging.RenderTargetBitmap 64, 64, 96, 96, ([System.Windows.Media.PixelFormats]::Pbgra32)
    $bmp.Render($dv)
    $script:Window.Icon = $bmp
} catch { }

# ----- Logo em imagem (embutida no Harle.exe); sem ela fica a lanca desenhada -----
if ($script:Hosted) {
    try {
        $st = [Harle.Native].Assembly.GetManifestResourceStream('logo.png')
        if ($st) {
            $ms = New-Object System.IO.MemoryStream
            $st.CopyTo($ms); $st.Dispose(); $ms.Position = 0
            $logo = New-Object System.Windows.Media.Imaging.BitmapImage
            $logo.BeginInit()
            $logo.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            $logo.StreamSource = $ms
            $logo.EndInit()
            $logo.Freeze()
            $script:Window.Icon = $logo
            $brush = New-Object System.Windows.Media.ImageBrush $logo
            $brush.Stretch = 'UniformToFill'
            $script:ui.LogoBox.Width = 46; $script:ui.LogoBox.Height = 46
            $script:ui.LogoBox.CornerRadius = New-Object System.Windows.CornerRadius 11
            $script:ui.LogoBox.Background = $brush
            $script:ui.LogoMark.Visibility = 'Collapsed'
            $script:LogoBrush = $brush
        }
    } catch { Write-Log "Logo: $($_.Exception.Message)" }
}

# ----- Inicio -----
Initialize-GaugeTicks
Initialize-Steps
Initialize-Tune
Initialize-Summary
Initialize-Profiles
Initialize-Guide
Set-Gauge 0
Show-Page 'home'
if (-not $script:Hosted) { $script:ui.BtnMeasure.IsEnabled = $false; $script:ui.BtnPlay.IsEnabled = $false }

# Reinicio automatico, overlay e alerta voltam como a pessoa deixou.
if ($null -ne $script:Backup.state['autoRestart']) { $script:AutoRestart = [bool]$script:Backup.state['autoRestart'] }
$script:ui.AutoRestart.IsChecked = $script:AutoRestart
$savedCorner = $script:Backup.state['ovCorner']
if ($null -ne $savedCorner -and 0..3 -contains [int]$savedCorner) { $script:Ov.Corner = [int]$savedCorner }
$savedLimit = $script:Backup.state['alertLimit']
if ($null -ne $savedLimit -and [int]$savedLimit -ge 60 -and [int]$savedLimit -le 95) { $script:Alert.Limit = [int]$savedLimit }
Update-GameTools

Register-Tr $script:Window

$script:Started = $false
$script:Window.Add_ContentRendered({
    if ($script:Started) { return }
    $script:Started = $true
    try {
        [void]$script:Window.Activate()
        Set-Status 'Conferindo o estado atual do Windows...'
        foreach ($t in $script:Tweaks) { Sync-Row $t }
        Update-Gauge
        Invoke-Scan
        if ($script:BiosPending -eq 1) { Set-Status 'Pronto. Importante: há 1 ajuste de BIOS pendente, que rende mais que qualquer ajuste do Windows. Veja a aba BIOS.' }
        elseif ($script:BiosPending -gt 1) { Set-Status (Tx 'Pronto. Importante: há {0} ajustes de BIOS pendentes, que rendem mais que qualquer ajuste do Windows. Veja a aba BIOS.' ($($script:BiosPending))) }
        else { Set-Status 'Pronto.' }
        if ($script:Hosted) {
            try {
                # Se o Harle fechou a forca com o overlay ligado, a coleta do Windows pode ter ficado aberta.
                if ($script:Backup.state['ovFeed']) {
                    [void](Invoke-Native (Get-AssetPath 'PresentMon.exe') "--terminate_existing_session --session_name $($script:OverlaySession)")
                    $script:Backup.state['ovFeed'] = $false
                    Save-Backup
                }
                if ($script:Backup.state['alertOn']) { Set-TempAlert $true $script:Alert.Limit }
                if ($script:Backup.state['ovOn'])    { Set-Overlay $true }
            } catch { Write-Log "Overlay e alerta: $($_.Exception.Message)" }
        }
        Remove-UpdateLeftovers
        Update-GameWatch
        Update-MemAuto
        if ($script:Hosted -and ((Test-HarleTask $script:GuardTask) -or (Test-HarleTask $script:TimerTask)) -and -not (Test-HarleExe)) {
            try { Install-HarleExe } catch { Write-Log "Copia em Program Files: $($_.Exception.Message)" }
        }
        try { Invoke-UpdateCheck } catch { Write-Log "Versao nova: $($_.Exception.Message)" }
    } catch { Show-Error $_ }
})

Write-Log "Harle $($script:AppVersion) aberto (build $($script:Build), exe=$($script:Hosted))"
[void]$script:Window.ShowDialog()
