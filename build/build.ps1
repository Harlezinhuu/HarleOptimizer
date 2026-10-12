# Compila o Harle.exe: o C# do Host.cs com o Harle.ps1, o PresentMon, a logo e o dicionario embutidos.
# Roda no PowerShell 7 (Windows, Linux ou GitHub Actions), que ja traz o compilador Roslyn.
#   pwsh build/build.ps1 -Script Harle.ps1 -Out out/Harle.exe
param([string]$Script, [string]$Out, [string]$RefDir)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
if (-not $RefDir) { $RefDir = Join-Path $here 'ref' }
if (-not $Script) { $Script = Join-Path (Split-Path -Parent $here) 'Harle.ps1' }
if (-not $Out) { $Out = Join-Path (Split-Path -Parent $here) 'out/Harle.exe' }
$outDir = Split-Path -Parent $Out
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
foreach ($n in 'Microsoft.CodeAnalysis.dll', 'Microsoft.CodeAnalysis.CSharp.dll') {
    $p = Join-Path $PSHOME $n
    if (Test-Path -LiteralPath $p) { try { Add-Type -Path $p } catch { } }
}
Add-Type -TypeDefinition 'public class VxRes { byte[] d; public VxRes(byte[] x) { d = x; } public System.IO.Stream Open() { return new System.IO.MemoryStream(d, false); } }'
function New-Res([string]$Name, [byte[]]$Bytes) {
    $holder = [VxRes]::new($Bytes)
    $open = [Delegate]::CreateDelegate([Func[IO.Stream]], $holder, 'Open')
    return [Microsoft.CodeAnalysis.ResourceDescription]::new($Name, $open, $true)
}
# script embutido: UTF-8 com BOM e CRLF
$text = [IO.File]::ReadAllText($Script, [Text.Encoding]::UTF8).Replace("`r`n", "`n").Replace("`n", "`r`n")
$res = [Microsoft.CodeAnalysis.ResourceDescription[]]@(
    (New-Res 'Harle.ps1' ([byte[]]([Text.Encoding]::UTF8.GetPreamble() + [Text.Encoding]::UTF8.GetBytes($text)))),
    (New-Res 'PresentMon.exe' ([IO.File]::ReadAllBytes("$here/PresentMon.exe"))),
    (New-Res 'PresentMon-LICENSE.txt' ([IO.File]::ReadAllBytes("$here/PresentMon-LICENSE.txt"))),
    (New-Res 'logo.png' ([IO.File]::ReadAllBytes("$here/logo.png"))),
    (New-Res 'en.tsv' ([IO.File]::ReadAllBytes("$here/en.tsv")))
)
$code  = [IO.File]::ReadAllText("$here/Host.cs", [Text.Encoding]::UTF8)
if ($code -notmatch 'Version=" \+ "3\.0" \+ "\.0\.0,') { throw 'Host.cs: a referencia ao PowerShell do Windows precisa ser Version=3.0.0.0' }
$popt  = [Microsoft.CodeAnalysis.CSharp.CSharpParseOptions]::new([Microsoft.CodeAnalysis.CSharp.LanguageVersion]::CSharp7_3)
$tree  = [Microsoft.CodeAnalysis.CSharp.CSharpSyntaxTree]::ParseText($code, $popt)
$refs  = [Microsoft.CodeAnalysis.MetadataReference[]]@('mscorlib', 'System', 'System.Core' | ForEach-Object { [Microsoft.CodeAnalysis.MetadataReference]::CreateFromFile("$RefDir/$_.dll") })
$copt  = [Microsoft.CodeAnalysis.CSharp.CSharpCompilationOptions]::new([Microsoft.CodeAnalysis.OutputKind]::WindowsApplication)
$copt  = $copt.WithPlatform([Microsoft.CodeAnalysis.Platform]::AnyCpu).WithOptimizationLevel([Microsoft.CodeAnalysis.OptimizationLevel]::Release).WithDeterministic($true)
$comp  = [Microsoft.CodeAnalysis.CSharp.CSharpCompilation]::Create('Harle', [Microsoft.CodeAnalysis.SyntaxTree[]]@($tree), $refs, $copt)
$manifest = [IO.File]::OpenRead("$here/app.manifest")
$icon     = [IO.File]::OpenRead("$here/harle.ico")
$win32    = $comp.CreateDefaultWin32Resources($true, $false, $manifest, $icon)
$pe       = [IO.File]::Create($Out)
try { $r = $comp.Emit($pe, $null, $null, $win32, $res) } finally { $pe.Dispose(); $manifest.Dispose(); $icon.Dispose() }
$r.Diagnostics | Where-Object { $_.Severity -ne 'Hidden' } | ForEach-Object { $_.ToString() }
"emit ok: $($r.Success)  ->  $((Get-Item $Out).Length) bytes"
if (-not $r.Success) { Remove-Item $Out -Force; exit 1 }
