#Requires -Version 5.1
<#
  WinMole - dọn dẹp & tối ưu Windows dạng portable (lấy cảm hứng từ tw93/mole cho macOS)
  Chạy: mo [lệnh] [tùy chọn]    ·    mo --help    ·    cài để gọi 'mo' ở mọi nơi: mo.cmd install
#>

$script:Version = '0.1.0'
$argv = @($args)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

$MoleRoot      = $PSScriptRoot
$ConfigDir = Join-Path $MoleRoot 'config'
$LogDir    = Join-Path $MoleRoot 'logs'
$LibDir    = Join-Path $MoleRoot 'lib'
$LogFile   = Join-Path $LogDir 'operations.log'
$script:Session = (Get-Date).ToString('yyyyMMdd-HHmmss')

$LAD  = $env:LOCALAPPDATA
$RAD  = $env:APPDATA
$UHOME  = $env:USERPROFILE
$WINDIR  = $env:SystemRoot
$PDATA = $env:ProgramData

$script:Interactive = $true
try { if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) { $script:Interactive = $false } } catch { $script:Interactive = $false }

# ───────────────────────────── Tham số ─────────────────────────────
$Cmd = ''
$Flags = @{}
$Pos = New-Object System.Collections.Generic.List[string]
$valueFlags = @('interval', 'depth', 'days')
for ($i = 0; $i -lt $argv.Count; $i++) {
    $a = [string]$argv[$i]
    if ($a -match '^--?([\w-]+)(=(.*))?$') {
        $k = $Matches[1].ToLower()
        if ($Matches[2]) { $Flags[$k] = $Matches[3] }
        elseif ($valueFlags -contains $k -and $i + 1 -lt $argv.Count) { $Flags[$k] = $argv[++$i] }
        else { $Flags[$k] = $true }
    }
    elseif (-not $Cmd) { $Cmd = $a.ToLower() }
    else { $Pos.Add($a) }
}
$DryRun = [bool]$Flags['dry-run']

# ───────────────────────────── Lõi C# ─────────────────────────────
$CSharp = @'
using System;
using System.IO;
using System.Collections.Generic;
using System.Threading.Tasks;

namespace WinMole
{
    public class Entry
    {
        public string Path; public string Name; public long Bytes; public long Files;
        public bool IsDir; public bool IsLink; public DateTime Modified;
    }

    public class DeleteResult { public long Bytes; public long Files; public long Failed; }

    public class Artifact
    {
        public string Path; public string Project; public string Kind; public DateTime Modified; public long Bytes;
    }

    public static class Fs
    {
        const StringComparison OIC = StringComparison.OrdinalIgnoreCase;

        static bool IsLink(FileSystemInfo fi)
        {
            try { return (fi.Attributes & FileAttributes.ReparsePoint) != 0; } catch { return true; }
        }

        // Tổng dung lượng + số file, không đi theo junction/symlink
        public static long[] Measure(string path)
        {
            long bytes = 0, files = 0;
            var stack = new Stack<DirectoryInfo>();
            try
            {
                var root = new DirectoryInfo(path);
                if (!root.Exists)
                {
                    var f = new FileInfo(path);
                    return f.Exists ? new long[] { f.Length, 1 } : new long[] { 0, 0 };
                }
                stack.Push(root);
            }
            catch { return new long[] { 0, 0 }; }
            while (stack.Count > 0)
            {
                var d = stack.Pop();
                FileSystemInfo[] items;
                try { items = d.GetFileSystemInfos(); } catch { continue; }
                foreach (var it in items)
                {
                    if (IsLink(it)) continue;
                    var fi = it as FileInfo;
                    if (fi != null) { bytes += fi.Length; files++; }
                    else stack.Push((DirectoryInfo)it);
                }
            }
            return new long[] { bytes, files };
        }

        public static long[] MeasureMany(string[] paths)
        {
            var r = new long[paths.Length];
            Parallel.For(0, paths.Length, i => { r[i] = Measure(paths[i])[0]; });
            return r;
        }

        public static Entry[] Children(string path)
        {
            FileSystemInfo[] items;
            try { items = new DirectoryInfo(path).GetFileSystemInfos(); } catch { return new Entry[0]; }
            var result = new Entry[items.Length];
            Parallel.For(0, items.Length, i =>
            {
                var it = items[i];
                var e = new Entry();
                e.Path = it.FullName; e.Name = it.Name;
                try { e.Modified = it.LastWriteTime; } catch { }
                var fi = it as FileInfo;
                if (fi != null) { e.Bytes = fi.Length; e.Files = 1; }
                else
                {
                    e.IsDir = true;
                    if (IsLink(it)) e.IsLink = true;
                    else { var m = Measure(it.FullName); e.Bytes = m[0]; e.Files = m[1]; }
                }
                result[i] = e;
            });
            Array.Sort(result, (a, b) => b.Bytes.CompareTo(a.Bytes));
            return result;
        }

        // Xóa an toàn: junction/symlink chỉ gỡ liên kết, không bao giờ xóa nội dung đích
        public static DeleteResult Delete(string path, bool keepRoot, double minAgeHours, bool dryRun)
        {
            var r = new DeleteResult();
            DateTime cutoff = minAgeHours > 0 ? DateTime.Now.AddHours(-minAgeHours) : DateTime.MaxValue;
            try
            {
                if (File.Exists(path)) { DelFile(new FileInfo(path), cutoff, dryRun, r); return r; }
                if (!Directory.Exists(path)) return r;
                var di = new DirectoryInfo(path);
                if (IsLink(di))
                {
                    if (!keepRoot && !dryRun) { try { di.Delete(false); } catch { r.Failed++; } }
                    return r;
                }
                DelDir(di, cutoff, dryRun, r, !keepRoot);
            }
            catch { r.Failed++; }
            return r;
        }

        static void DelFile(FileInfo f, DateTime cutoff, bool dry, DeleteResult r)
        {
            try
            {
                if (f.LastWriteTime > cutoff) return;
                long len = f.Length;
                if (!dry)
                {
                    if ((f.Attributes & FileAttributes.ReadOnly) != 0) f.Attributes = FileAttributes.Normal;
                    f.Delete();
                }
                r.Bytes += len; r.Files++;
            }
            catch { r.Failed++; }
        }

        static void DelDir(DirectoryInfo d, DateTime cutoff, bool dry, DeleteResult r, bool removeSelf)
        {
            FileSystemInfo[] items;
            try { items = d.GetFileSystemInfos(); } catch { r.Failed++; return; }
            foreach (var it in items)
            {
                if (IsLink(it))
                {
                    if (!dry)
                    {
                        try
                        {
                            var sub = it as DirectoryInfo;
                            if (sub != null) sub.Delete(false); else it.Delete();
                        }
                        catch { r.Failed++; }
                    }
                    continue;
                }
                var fi = it as FileInfo;
                if (fi != null) DelFile(fi, cutoff, dry, r);
                else DelDir((DirectoryInfo)it, cutoff, dry, r, true);
            }
            if (removeSelf && !dry) { try { d.Delete(false); } catch { } }
        }

        static Dictionary<string, bool> MakeSet(string[] a)
        {
            var d = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase);
            foreach (var s in a) d[s] = true;
            return d;
        }

        static readonly Dictionary<string, bool> Always = MakeSet(new string[] {
            "node_modules", ".next", ".nuxt", ".turbo", ".parcel-cache", ".svelte-kit", ".angular",
            ".dart_tool", "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".expo", "Pods" });

        // Tìm thư mục build/phụ thuộc có thể tạo lại trong các dự án
        public static Artifact[] FindArtifacts(string root, int maxDepth)
        {
            var result = new List<Artifact>();
            var stack = new Stack<KeyValuePair<DirectoryInfo, int>>();
            try { stack.Push(new KeyValuePair<DirectoryInfo, int>(new DirectoryInfo(root), 0)); }
            catch { return result.ToArray(); }
            while (stack.Count > 0)
            {
                var cur = stack.Pop();
                var d = cur.Key; int depth = cur.Value;
                DirectoryInfo[] subs; FileInfo[] files;
                try { subs = d.GetDirectories(); files = d.GetFiles(); } catch { continue; }
                var names = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase);
                bool hasProj = false;
                foreach (var f in files)
                {
                    names[f.Name] = true;
                    string ext = f.Extension.ToLowerInvariant();
                    if (ext == ".csproj" || ext == ".fsproj" || ext == ".vbproj") hasProj = true;
                }
                bool gradle = names.ContainsKey("build.gradle") || names.ContainsKey("build.gradle.kts")
                           || names.ContainsKey("settings.gradle") || names.ContainsKey("settings.gradle.kts");
                foreach (var s in subs)
                {
                    if (IsLink(s)) continue;
                    string n = s.Name; string kind = null;
                    if (Always.ContainsKey(n)) kind = n;
                    else if (n.Equals("target", OIC) && (names.ContainsKey("Cargo.toml") || names.ContainsKey("pom.xml"))) kind = "target";
                    else if (n.Equals("build", OIC) && (gradle || names.ContainsKey("pubspec.yaml") || names.ContainsKey("CMakeLists.txt") || names.ContainsKey("package.json"))) kind = "build";
                    else if (n.Equals("dist", OIC) && names.ContainsKey("package.json")) kind = "dist";
                    else if ((n.Equals("bin", OIC) || n.Equals("obj", OIC)) && hasProj) kind = n.ToLowerInvariant();
                    else if (n.Equals(".gradle", OIC) && gradle) kind = ".gradle";
                    else if (n.Equals("vendor", OIC) && names.ContainsKey("composer.json")) kind = "vendor";
                    else if ((n.Equals(".venv", OIC) || n.Equals("venv", OIC)) && File.Exists(System.IO.Path.Combine(s.FullName, "pyvenv.cfg"))) kind = "venv";

                    if (kind != null)
                    {
                        var a = new Artifact();
                        a.Path = s.FullName; a.Project = d.FullName; a.Kind = kind;
                        try { a.Modified = s.LastWriteTime; } catch { }
                        result.Add(a);
                    }
                    else if (depth < maxDepth && !n.Equals(".git", OIC) && !n.StartsWith("$"))
                        stack.Push(new KeyValuePair<DirectoryInfo, int>(s, depth + 1));
                }
            }
            var arr = result.ToArray();
            Parallel.For(0, arr.Length, i => { arr[i].Bytes = Measure(arr[i].Path)[0]; });
            return arr;
        }
    }
}
'@

function Initialize-Core {
    if ('WinMole.Fs' -as [type]) { return }
    $sha = [Security.Cryptography.SHA1]::Create()
    $hash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($CSharp))) -replace '-', '').Substring(0, 10)
    $dll = Join-Path $LibDir "WinMole.Core.$hash.dll"
    try {
        if (-not (Test-Path -LiteralPath $dll)) {
            if (-not (Test-Path $LibDir)) { New-Item -ItemType Directory -Path $LibDir | Out-Null }
            Get-ChildItem $LibDir -Filter 'WinMole.Core.*.dll' -EA SilentlyContinue | Remove-Item -Force -EA SilentlyContinue
            Add-Type -TypeDefinition $CSharp -OutputAssembly $dll -OutputType Library -EA Stop
        }
        Add-Type -Path $dll -EA Stop
    }
    catch {
        # Thư mục chỉ đọc (USB khóa ghi...) → biên dịch trong bộ nhớ
        if (-not ('WinMole.Fs' -as [type])) { Add-Type -TypeDefinition $CSharp }
    }
}

# ───────────────────────────── Tiện ích ─────────────────────────────
function Fmt([double]$b) {
    if ($b -ge 1TB) { '{0:N2} TB' -f ($b / 1TB) }
    elseif ($b -ge 1GB) { '{0:N2} GB' -f ($b / 1GB) }
    elseif ($b -ge 1MB) { '{0:N1} MB' -f ($b / 1MB) }
    elseif ($b -ge 1KB) { '{0:N0} KB' -f ($b / 1KB) }
    else { '{0:N0} B' -f $b }
}

function Fit([string]$s, [int]$n) {
    if ($null -eq $s) { $s = '' }
    if ($s.Length -gt $n) { $s.Substring(0, [Math]::Max(0, $n - 1)) + '~' } else { $s.PadRight($n) }
}

function Age([datetime]$t) {
    if ($t -eq [datetime]::MinValue) { return '?' }
    $d = ((Get-Date) - $t).TotalDays
    if ($d -lt 1) { 'hôm nay' } elseif ($d -lt 30) { '{0:N0} ngày' -f $d } elseif ($d -lt 365) { '{0:N0} tháng' -f ($d / 30) } else { '{0:N1} năm' -f ($d / 365) }
}

function S([string]$Text, $Color = $null) { [pscustomobject]@{ T = $Text; C = $Color } }

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-FreeC { try { (New-Object IO.DriveInfo($env:SystemDrive)).AvailableFreeSpace } catch { 0 } }

function Write-Banner([string]$Title) {
    Write-Host ''
    Write-Host '  WinMole' -ForegroundColor Cyan -NoNewline
    Write-Host " v$script:Version" -ForegroundColor DarkGray -NoNewline
    if ($Title) { Write-Host "  ·  $Title" -ForegroundColor White } else { Write-Host '' }
    if ($DryRun) { Write-Host '  [DRY-RUN] chỉ xem trước, không thay đổi gì' -ForegroundColor Yellow }
    Write-Host ''
}

function Confirm-Action([string]$Msg) {
    if ($Flags['yes']) { return $true }
    if (-not $script:Interactive) { Write-Host "  $Msg → bỏ qua (không tương tác, thêm --yes để đồng ý)" -ForegroundColor Yellow; return $false }
    Write-Host "  $Msg (y/N): " -ForegroundColor Yellow -NoNewline
    $r = Read-Host
    return ($r -match '^\s*(y|yes|c|co|có)\s*$')
}

function Write-OpLog([string]$Command, [string]$Action, [string]$Target, [int64]$Bytes) {
    if ($DryRun) { return }
    try {
        if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }
        $o = [ordered]@{ time = (Get-Date).ToString('s'); session = $script:Session; cmd = $Command; action = $Action; path = $Target; bytes = $Bytes }
        Add-Content -LiteralPath $LogFile -Value ($o | ConvertTo-Json -Compress) -Encoding UTF8
    }
    catch { }
}

# Chặn xóa các vị trí hệ thống / thư mục gốc
function Test-Deletable([string]$Path) {
    if (-not $Path) { return $false }
    try { $p = [IO.Path]::GetFullPath($Path).TrimEnd('\') } catch { return $false }
    if ($p.Length -lt 4) { return $false }
    $deny = @($WINDIR, "$WINDIR\System32", "$WINDIR\SysWOW64", "$WINDIR\WinSxS", $env:ProgramFiles, ${env:ProgramFiles(x86)}, $PDATA,
        "$env:SystemDrive\Users", $UHOME, $RAD, $LAD, "$LAD\Programs", "$LAD\Microsoft", "$RAD\Microsoft", $MoleRoot,
        "$UHOME\Desktop", "$UHOME\Documents", "$UHOME\Downloads", "$UHOME\Pictures", "$UHOME\Videos", "$UHOME\Music", "$UHOME\OneDrive") |
        Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') }
    foreach ($d in $deny) { if ($p -ieq $d) { return $false } }
    if ($p.StartsWith("$MoleRoot\", 'OrdinalIgnoreCase')) { return $false }
    if ($p.StartsWith("$WINDIR\", 'OrdinalIgnoreCase')) {
        $ok = @("$WINDIR\Temp", "$WINDIR\SoftwareDistribution\Download", "$WINDIR\Logs", "$WINDIR\Minidump", "$WINDIR\LiveKernelReports")
        foreach ($a in $ok) { if ($p -ieq $a -or $p.StartsWith("$a\", 'OrdinalIgnoreCase')) { return $true } }
        return $false
    }
    return $true
}

# ───────────────────────────── Giao diện terminal ─────────────────────────────
function Draw-Screen($Lines) {
    $w = [Math]::Max(20, [Console]::WindowWidth - 1)
    $h = [Console]::WindowHeight
    $top = [Console]::WindowTop
    [Console]::SetCursorPosition(0, $top)
    $def = [Console]::ForegroundColor
    $n = 0
    foreach ($line in $Lines) {
        if ($n -ge $h - 1) { break }
        $len = 0
        foreach ($s in @($line)) {
            if ($null -eq $s) { continue }
            $t = [string]$s.T
            if ($len + $t.Length -gt $w) { $t = $t.Substring(0, [Math]::Max(0, $w - $len)) }
            if ($t.Length) {
                if ($s.C) { [Console]::ForegroundColor = $s.C } else { [Console]::ForegroundColor = $def }
                [Console]::Write($t)
                $len += $t.Length
            }
        }
        [Console]::ForegroundColor = $def
        [Console]::Write((' ' * [Math]::Max(0, $w - $len)) + "`n")
        $n++
    }
    for (; $n -lt $h - 1; $n++) { [Console]::Write((' ' * $w) + "`n") }
    [Console]::ForegroundColor = $def
}

function Enter-Screen { Clear-Host; try { [Console]::CursorVisible = $false } catch { } }
function Exit-Screen { try { [Console]::CursorVisible = $true } catch { }; Clear-Host }

function Bar([double]$Pct, [int]$Width = 20) {
    $Pct = [Math]::Max(0, [Math]::Min(100, $Pct))
    $f = [int][Math]::Round($Pct / 100 * $Width)
    $c = if ($Pct -ge 85) { 'Red' } elseif ($Pct -ge 60) { 'Yellow' } else { 'Green' }
    @((S ('█' * $f) $c), (S ('░' * ($Width - $f)) 'DarkGray'))
}

# Danh sách chọn nhiều: ↑↓ Space A Enter Q. Items cần: Label, Group, Bytes, Selected, Disabled, Note
function Select-Checklist([string]$Title, [object[]]$Items, [string]$Footer = '') {
    if (-not $script:Interactive -or $Flags['yes']) { return @($Items | Where-Object { $_.Selected -and -not $_.Disabled }) }
    if ($Items.Count -eq 0) { return @() }
    $idx = 0; $off = 0
    Enter-Screen
    try {
        while ($true) {
            $view = [Math]::Max(3, [Console]::WindowHeight - 8)
            if ($idx -lt $off) { $off = $idx }
            if ($idx -ge $off + $view) { $off = $idx - $view + 1 }
            $lines = New-Object 'System.Collections.Generic.List[object]'
            $lines.Add(@((S "  $Title" 'Cyan')))
            $lines.Add(@((S '  ↑↓ di chuyển · Space chọn/bỏ · A chọn/bỏ tất cả · Enter xác nhận · Q hủy' 'DarkGray')))
            $lines.Add(@())
            $end = [Math]::Min($Items.Count, $off + $view)
            for ($i = $off; $i -lt $end; $i++) {
                $it = $Items[$i]
                $cur = ($i -eq $idx)
                $box = if ($it.Disabled) { '[-]' } elseif ($it.Selected) { '[x]' } else { '[ ]' }
                $boxC = if ($it.Disabled) { 'DarkGray' } elseif ($it.Selected) { 'Green' } else { 'Gray' }
                $lblC = if ($it.Disabled) { 'DarkGray' } elseif ($cur) { 'Cyan' } else { $null }
                $seg = @(
                    (S $(if ($cur) { ' > ' } else { '   ' }) 'Cyan'),
                    (S "$box " $boxC),
                    (S (Fit $it.Group 14) 'DarkCyan'),
                    (S (Fit $it.Label 44) $lblC),
                    (S $(if ($null -ne $it.Bytes) { (Fmt $it.Bytes).PadLeft(11) } else { ''.PadLeft(11) }) 'Yellow')
                )
                if ($it.Note) { $seg += (S "  $($it.Note)" 'DarkGray') }
                $lines.Add($seg)
            }
            if ($Items.Count -gt $view) { $lines.Add(@((S "   … $($off + 1)-$end / $($Items.Count)" 'DarkGray'))) }
            $sel = @($Items | Where-Object { $_.Selected -and -not $_.Disabled })
            $sum = ($sel | Measure-Object -Property Bytes -Sum).Sum
            $lines.Add(@())
            $lines.Add(@((S "  Đã chọn: $($sel.Count) mục · $(Fmt $sum)" 'Green'), (S "  $Footer" 'DarkGray')))
            Draw-Screen $lines

            $k = [Console]::ReadKey($true)
            switch ($k.Key) {
                'UpArrow' { if ($idx -gt 0) { $idx-- } }
                'K' { if ($idx -gt 0) { $idx-- } }
                'DownArrow' { if ($idx -lt $Items.Count - 1) { $idx++ } }
                'J' { if ($idx -lt $Items.Count - 1) { $idx++ } }
                'PageUp' { $idx = [Math]::Max(0, $idx - $view) }
                'PageDown' { $idx = [Math]::Min($Items.Count - 1, $idx + $view) }
                'Home' { $idx = 0 }
                'End' { $idx = $Items.Count - 1 }
                'Spacebar' { if (-not $Items[$idx].Disabled) { $Items[$idx].Selected = -not $Items[$idx].Selected } }
                'A' {
                    $en = @($Items | Where-Object { -not $_.Disabled })
                    $all = -not ($en | Where-Object { -not $_.Selected })
                    foreach ($x in $en) { $x.Selected = -not $all }
                }
                'Enter' { return @($Items | Where-Object { $_.Selected -and -not $_.Disabled }) }
                'Escape' { return $null }
                'Q' { return $null }
            }
        }
    }
    finally { Exit-Screen }
}

function Select-Menu([string]$Title, [object[]]$Options) {
    $idx = 0
    Enter-Screen
    try {
        while ($true) {
            $lines = New-Object 'System.Collections.Generic.List[object]'
            $lines.Add(@())
            $lines.Add(@((S '   __        ___       __  __       _      ' 'Cyan')))
            $lines.Add(@((S '   \ \      / (_)_ __ |  \/  | ___ | | ___ ' 'Cyan')))
            $lines.Add(@((S '    \ \ /\ / /| | ''_ \| |\/| |/ _ \| |/ _ \' 'Cyan')))
            $lines.Add(@((S '     \ V  V / | | | | | |  | | (_) | |  __/' 'Cyan')))
            $lines.Add(@((S '      \_/\_/  |_|_| |_|_|  |_|\___/|_|\___|' 'Cyan'), (S "  v$script:Version" 'DarkGray')))
            $lines.Add(@())
            $lines.Add(@((S "   $Title" 'White')))
            $lines.Add(@())
            for ($i = 0; $i -lt $Options.Count; $i++) {
                $o = $Options[$i]
                if ($i -eq $idx) { $lines.Add(@((S '  > ' 'Cyan'), (S (Fit $o.Label 26) 'Cyan'), (S $o.Desc 'Gray'))) }
                else { $lines.Add(@((S '    '), (S (Fit $o.Label 26)), (S $o.Desc 'DarkGray'))) }
            }
            $lines.Add(@())
            $lines.Add(@((S '   ↑↓ chọn · Enter mở · Q thoát' 'DarkGray')))
            Draw-Screen $lines
            $k = [Console]::ReadKey($true)
            switch ($k.Key) {
                'UpArrow' { $idx = ($idx - 1 + $Options.Count) % $Options.Count }
                'DownArrow' { $idx = ($idx + 1) % $Options.Count }
                'Enter' { return $idx }
                'Escape' { return -1 }
                'Q' { return -1 }
                default {
                    $c = [string]$k.KeyChar
                    if ($c -match '^[1-9]$' -and [int]$c -le $Options.Count) { return [int]$c - 1 }
                }
            }
        }
    }
    finally { Exit-Screen }
}

function Show-Plan([object[]]$Items, [switch]$ShowPaths) {
    $sum = 0
    foreach ($it in $Items) {
        $mark = if ($it.Disabled) { '[-]' } elseif ($it.Selected) { '[x]' } else { '[ ]' }
        $c = if ($it.Disabled) { 'DarkGray' } elseif ($it.Selected) { 'Green' } else { 'Gray' }
        Write-Host "  $mark " -ForegroundColor $c -NoNewline
        Write-Host (Fit $it.Group 14) -ForegroundColor DarkCyan -NoNewline
        Write-Host (Fit $it.Label 44) -NoNewline
        Write-Host $(if ($null -ne $it.Bytes) { (Fmt $it.Bytes).PadLeft(11) } else { ''.PadLeft(11) }) -ForegroundColor Yellow -NoNewline
        if ($it.Note) { Write-Host "  $($it.Note)" -ForegroundColor DarkGray } else { Write-Host '' }
        if ($ShowPaths -and $it.Paths) { foreach ($p in $it.Paths) { Write-Host "        $p" -ForegroundColor DarkGray } }
        if ($it.Selected -and -not $it.Disabled) { $sum += $it.Bytes }
    }
    Write-Host ''
    Write-Host "  Sẽ xử lý ([x]): $(Fmt $sum)" -ForegroundColor Green
}

function Remove-ToRecycleBin([string]$Path) {
    Add-Type -AssemblyName Microsoft.VisualBasic
    if (Test-Path -LiteralPath $Path -PathType Container) {
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($Path, 'OnlyErrorDialogs', 'SendToRecycleBin')
    }
    else {
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($Path, 'OnlyErrorDialogs', 'SendToRecycleBin')
    }
}

# ───────────────────────────── clean ─────────────────────────────
function Resolve-Paths([string]$p) {
    if ($p -match '[\*\?]') { @(Get-Item -Path $p -Force -EA SilentlyContinue | ForEach-Object { $_.FullName }) }
    elseif (Test-Path -LiteralPath $p) { @($p) }
    else { @() }
}

function New-Target {
    param($Id, $Group, $Name, [string[]]$Patterns, $Mode = 'contents', [double]$MinAge = 0, [switch]$Admin, $Proc = $null, $Default = $true)
    $paths = @()
    foreach ($p in $Patterns) { $paths += Resolve-Paths $p }
    [pscustomobject]@{ Id = $Id; Group = $Group; Name = $Name; Paths = @($paths | Select-Object -Unique); Mode = $Mode
        MinAge = $MinAge; Admin = [bool]$Admin; Proc = $Proc; Default = $Default; Bytes = [int64]0 }
}

function Get-BrowserPatterns([string]$UserData) {
    @("$UserData\*\Cache", "$UserData\*\Code Cache", "$UserData\*\GPUCache", "$UserData\*\Service Worker\CacheStorage",
      "$UserData\*\Service Worker\ScriptCache", "$UserData\*\DawnGraphiteCache", "$UserData\*\DawnWebGPUCache",
      "$UserData\ShaderCache", "$UserData\GrShaderCache", "$UserData\GraphiteDawnCache")
}

function Get-OldVersionPaths {
    $out = @()
    # Ứng dụng kiểu Squirrel (GitHub Desktop, Discord, Slack...): giữ thư mục app-* mới nhất
    foreach ($d in Get-ChildItem $LAD -Directory -Force -EA SilentlyContinue) {
        $apps = @(Get-ChildItem $d.FullName -Directory -Filter 'app-*' -EA SilentlyContinue | Where-Object { $_.Name -match '^app-\d+(\.\d+)+$' })
        if ($apps.Count -gt 1) {
            $out += $apps | Sort-Object { [version]($_.Name -replace '^app-', '') } -Descending | Select-Object -Skip 1 | ForEach-Object { $_.FullName }
        }
    }
    # CapCut: Apps\<phiên bản>
    $cc = @(Get-ChildItem "$LAD\CapCut\Apps" -Directory -EA SilentlyContinue | Where-Object { $_.Name -match '^\d+(\.\d+)+$' })
    if ($cc.Count -gt 1) { $out += $cc | Sort-Object { [version]$_.Name } -Descending | Select-Object -Skip 1 | ForEach-Object { $_.FullName } }
    $out
}

function Get-CleanTargets {
    $t = @()
    $t += New-Target 'temp-user' 'Hệ thống' 'Temp của người dùng (>24h)' @($env:TEMP) -MinAge 24
    $t += New-Target 'temp-win' 'Hệ thống' 'Windows Temp (>24h)' @("$WINDIR\Temp") -MinAge 24 -Admin
    $t += New-Target 'wu-cache' 'Hệ thống' 'Bản tải Windows Update' @("$WINDIR\SoftwareDistribution\Download") -Admin
    $t += New-Target 'win-logs' 'Hệ thống' 'Log Windows (>7 ngày)' @("$WINDIR\Logs") -MinAge 168 -Admin
    $t += New-Target 'crash-user' 'Hệ thống' 'Crash dump & báo lỗi (user)' @("$LAD\CrashDumps", "$LAD\Microsoft\Windows\WER\ReportArchive", "$LAD\Microsoft\Windows\WER\ReportQueue")
    $t += New-Target 'crash-sys' 'Hệ thống' 'Crash dump & báo lỗi (hệ thống)' @("$PDATA\Microsoft\Windows\WER\ReportArchive", "$PDATA\Microsoft\Windows\WER\ReportQueue", "$WINDIR\Minidump", "$WINDIR\LiveKernelReports") -Admin
    $t += New-Target 'recycle' 'Hệ thống' 'Thùng rác' @()
    $t += New-Target 'd3d' 'GPU' 'DirectX shader cache' @("$LAD\D3DSCache")
    $t += New-Target 'nvidia' 'GPU' 'NVIDIA shader cache' @("$LAD\NVIDIA\DXCache", "$LAD\NVIDIA\GLCache", "$LAD\NVIDIA Corporation\NV_Cache")
    $t += New-Target 'nvidia-pkg' 'GPU' 'NVIDIA App: bộ cài driver cũ' @("$PDATA\NVIDIA Corporation\NVIDIA App\UpdateFramework\ota-artifacts")
    $t += New-Target 'amd' 'GPU' 'AMD shader cache' @("$LAD\AMD\DxCache", "$LAD\AMD\DxcCache", "$LAD\AMD\VkCache", "$LAD\AMD\GLCache", "$LAD\AMD\OglCache")
    $t += New-Target 'intel' 'GPU' 'Intel shader cache' @("$LAD\Intel\ShaderCache")
    $t += New-Target 'edge' 'Trình duyệt' 'Microsoft Edge cache' (Get-BrowserPatterns "$LAD\Microsoft\Edge\User Data") -Proc 'msedge'
    $t += New-Target 'chrome' 'Trình duyệt' 'Google Chrome cache' (Get-BrowserPatterns "$LAD\Google\Chrome\User Data") -Proc 'chrome'
    $t += New-Target 'brave' 'Trình duyệt' 'Brave cache' (Get-BrowserPatterns "$LAD\BraveSoftware\Brave-Browser\User Data") -Proc 'brave'
    $t += New-Target 'coccoc' 'Trình duyệt' 'Cốc Cốc cache' (Get-BrowserPatterns "$LAD\CocCoc\Browser\User Data") -Proc 'browser'
    $t += New-Target 'firefox' 'Trình duyệt' 'Firefox cache' @("$LAD\Mozilla\Firefox\Profiles\*\cache2") -Proc 'firefox'
    $t += New-Target 'npm' 'Lập trình' 'npm cache' @("$LAD\npm-cache")
    $t += New-Target 'pnpm' 'Lập trình' 'pnpm cache' @("$LAD\pnpm-cache")
    $t += New-Target 'yarn' 'Lập trình' 'Yarn cache' @("$LAD\Yarn\Cache")
    $t += New-Target 'bun' 'Lập trình' 'Bun cache' @("$UHOME\.bun\install\cache")
    $t += New-Target 'pip' 'Lập trình' 'pip cache' @("$LAD\pip\cache")
    $t += New-Target 'uv' 'Lập trình' 'uv cache' @("$LAD\uv\cache")
    $t += New-Target 'go' 'Lập trình' 'Go build cache' @("$LAD\go-build")
    $t += New-Target 'nuget-http' 'Lập trình' 'NuGet HTTP cache' @("$LAD\NuGet\v3-cache", "$LAD\NuGet\plugins-cache")
    $t += New-Target 'gradle' 'Lập trình' 'Gradle cache (tải lại khi build)' @("$UHOME\.gradle\caches", "$UHOME\.gradle\wrapper\dists", "$UHOME\.gradle\daemon") -Default $false
    $t += New-Target 'maven' 'Lập trình' 'Maven repository (tải lại khi build)' @("$UHOME\.m2\repository") -Default $false
    $t += New-Target 'nuget-pkg' 'Lập trình' 'NuGet packages (tải lại khi build)' @("$UHOME\.nuget\packages") -Default $false
    $t += New-Target 'cargo' 'Lập trình' 'Cargo registry cache' @("$UHOME\.cargo\registry\cache") -Default $false
    $t += New-Target 'pub' 'Lập trình' 'Dart/Flutter Pub cache' @("$LAD\Pub\Cache") -Default $false
    $t += New-Target 'dartserver' 'Lập trình' 'Dart analysis server cache' @("$LAD\.dartServer") -Default $false
    $electron = [ordered]@{ 'Code' = 'Code'; 'Cursor' = 'Cursor'; 'Windsurf' = 'Windsurf'; 'discord' = 'Discord'; 'Slack' = 'slack'
        'Postman' = 'Postman'; 'Notion' = 'Notion'; 'Figma' = 'Figma'; 'obsidian' = 'Obsidian'; 'GitHub Desktop' = 'GitHubDesktop'; 'Claude' = 'claude' }
    foreach ($app in $electron.Keys) {
        $base = "$RAD\$app"
        $t += New-Target "app-$($app.ToLower() -replace ' ', '')" 'Ứng dụng' "$app cache" @("$base\Cache", "$base\CachedData", "$base\CachedExtensionVSIXs", "$base\Code Cache", "$base\GPUCache", "$base\DawnGraphiteCache", "$base\DawnWebGPUCache", "$base\logs") -Proc $electron[$app]
    }
    $t += New-Target 'old-versions' 'Ứng dụng' 'Phiên bản app cũ (CapCut, Squirrel...)' @(Get-OldVersionPaths) -Mode 'dir'
    $t
}

function Get-Whitelist {
    $f = Join-Path $ConfigDir 'whitelist.txt'
    if (Test-Path -LiteralPath $f) { @(Get-Content -LiteralPath $f -Encoding UTF8 | Where-Object { $_ -and $_ -notmatch '^\s*#' } | ForEach-Object { $_.Trim() }) } else { @() }
}

function Get-RecycleBytes {
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $total = 0
    foreach ($d in [IO.DriveInfo]::GetDrives()) {
        if (-not $d.IsReady -or $d.DriveType -ne 'Fixed') { continue }
        $p = Join-Path $d.RootDirectory.FullName "`$Recycle.Bin\$sid"
        if (Test-Path -LiteralPath $p) { $total += [WinMole.Fs]::Measure($p)[0] }
    }
    $total
}

function Edit-Whitelist {
    Write-Banner 'Whitelist dọn dẹp'
    $f = Join-Path $ConfigDir 'whitelist.txt'
    $wl = Get-Whitelist
    $items = foreach ($t in Get-CleanTargets) {
        [pscustomobject]@{ Label = $t.Name; Group = $t.Group; Bytes = $null; Selected = ($wl -contains "id:$($t.Id)"); Disabled = $false; Note = $t.Id; Id = $t.Id }
    }
    $sel = Select-Checklist 'Chọn mục cần BẢO VỆ (không bao giờ dọn)' @($items)
    if ($null -eq $sel) { Write-Host '  Đã hủy.'; return }
    if (-not (Test-Path $ConfigDir)) { New-Item -ItemType Directory -Path $ConfigDir | Out-Null }
    $keep = @($wl | Where-Object { $_ -notmatch '^id:' })
    $lines = @('# WinMole whitelist', '# id:<mã>  = bảo vệ cả nhóm  ·  đường dẫn (cho phép * ?) = bảo vệ đường dẫn cụ thể') + ($sel | ForEach-Object { "id:$($_.Id)" }) + $keep
    Set-Content -LiteralPath $f -Value $lines -Encoding UTF8
    Write-Host "  Đã lưu $($sel.Count) mục vào $f" -ForegroundColor Green
}

function Invoke-Clean {
    if ($Flags['whitelist']) { Edit-Whitelist; return }
    Write-Banner 'Dọn dẹp hệ thống'
    Write-Host '  Đang quét...' -ForegroundColor DarkGray
    $isAdmin = Test-Admin
    $wl = Get-Whitelist
    $wlPaths = @($wl | Where-Object { $_ -notmatch '^id:' })
    $targets = @(Get-CleanTargets)

    $all = New-Object System.Collections.Generic.List[string]
    $owner = New-Object System.Collections.Generic.List[object]
    foreach ($t in $targets) {
        $t.Paths = @($t.Paths | Where-Object { $p = $_; -not ($wlPaths | Where-Object { $p -like $_ }) } | Where-Object { Test-Deletable $_ })
        foreach ($p in $t.Paths) { $all.Add($p); $owner.Add($t) }
    }
    $sizes = [WinMole.Fs]::MeasureMany($all.ToArray())
    for ($i = 0; $i -lt $sizes.Length; $i++) { $owner[$i].Bytes += $sizes[$i] }
    ($targets | Where-Object Id -eq 'recycle').Bytes = Get-RecycleBytes

    $items = foreach ($t in $targets) {
        if ($t.Bytes -le 0) { continue }
        $note = ''; $dis = $false
        if ($wl -contains "id:$($t.Id)") { $dis = $true; $note = 'whitelist' }
        elseif ($t.Admin -and -not $isAdmin) { $dis = $true; $note = 'cần Admin: mo clean --admin' }
        elseif ($t.Proc -and (Get-Process -Name $t.Proc -EA SilentlyContinue)) { $dis = $true; $note = "đang chạy, hãy đóng $($t.Proc) trước" }
        elseif ($t.MinAge -gt 0) { $note = 'ước tính' }
        [pscustomobject]@{ Label = $t.Name; Group = $t.Group; Bytes = $t.Bytes; Selected = [bool]$t.Default; Disabled = $dis; Note = $note; Ref = $t; Paths = $t.Paths }
    }
    $items = @($items)
    if ($items.Count -eq 0) { Write-Host '  Không có gì để dọn. Máy đã sạch!' -ForegroundColor Green; return }

    if ($DryRun) { Show-Plan $items -ShowPaths:([bool]$Flags['debug']); return }

    $sel = Select-Checklist 'Chọn mục cần dọn' $items 'Mục [-] bị khóa (xem ghi chú)'
    if ($null -eq $sel) { Write-Host '  Đã hủy.'; return }
    if ($sel.Count -eq 0) { Write-Host '  Không có mục nào được chọn.'; return }
    Write-Banner 'Dọn dẹp hệ thống'
    $est = ($sel | Measure-Object Bytes -Sum).Sum
    if (-not (Confirm-Action "Dọn $($sel.Count) mục (~$(Fmt $est))?")) { Write-Host '  Đã hủy.'; return }

    $before = Get-FreeC
    $total = 0
    foreach ($it in $sel) {
        $t = $it.Ref; $freed = 0; $fail = 0
        if ($t.Id -eq 'recycle') {
            Clear-RecycleBin -Force -EA SilentlyContinue; $freed = $t.Bytes
            Write-OpLog 'clean' 'empty-recycle-bin' 'RecycleBin' $freed
        }
        else {
            foreach ($p in $t.Paths) {
                $r = [WinMole.Fs]::Delete($p, ($t.Mode -eq 'contents'), $t.MinAge, $false)
                $freed += $r.Bytes; $fail += $r.Failed
                Write-OpLog 'clean' 'delete' $p $r.Bytes
            }
        }
        $total += $freed
        Write-Host '  ✓ ' -ForegroundColor Green -NoNewline
        Write-Host (Fit $t.Name 44) -NoNewline
        Write-Host ((Fmt $freed).PadLeft(11)) -ForegroundColor Yellow -NoNewline
        if ($fail) { Write-Host "  ($fail file đang được dùng, bỏ qua)" -ForegroundColor DarkGray } else { Write-Host '' }
    }
    $after = Get-FreeC
    Write-Host ''
    Write-Host "  Đã dọn: $(Fmt $total)" -ForegroundColor Green -NoNewline
    Write-Host "  ·  Ổ $env:SystemDrive trống: $(Fmt $before) → $(Fmt $after)" -ForegroundColor Cyan
}

# ───────────────────────────── purge ─────────────────────────────
function Get-PurgeRoots {
    $f = Join-Path $ConfigDir 'purge-paths.txt'
    if (Test-Path -LiteralPath $f) {
        return @(Get-Content -LiteralPath $f -Encoding UTF8 | Where-Object { $_ -and $_ -notmatch '^\s*#' } | ForEach-Object { $_.Trim() } | Where-Object { Test-Path -LiteralPath $_ })
    }
    $c = @("$UHOME\source\repos", "$UHOME\Projects", "$UHOME\projects", "$UHOME\code", "$UHOME\dev", "$UHOME\workspace", "$UHOME\workspaces", "$UHOME\Documents\GitHub", "$UHOME\StudioProjects", "$UHOME\AndroidStudioProjects")
    foreach ($d in [IO.DriveInfo]::GetDrives()) {
        if ($d.IsReady -and $d.DriveType -eq 'Fixed') {
            foreach ($n in 'workspace', 'workspaces', 'projects', 'code', 'dev', 'src', 'repos') { $c += Join-Path $d.RootDirectory.FullName $n }
        }
    }
    @($c | Where-Object { Test-Path -LiteralPath $_ } | ForEach-Object { (Get-Item -LiteralPath $_).FullName } | Select-Object -Unique)
}

function Invoke-Purge {
    if ($Flags['paths']) {
        if (-not (Test-Path $ConfigDir)) { New-Item -ItemType Directory -Path $ConfigDir | Out-Null }
        $f = Join-Path $ConfigDir 'purge-paths.txt'
        if (-not (Test-Path -LiteralPath $f)) {
            Set-Content -LiteralPath $f -Encoding UTF8 -Value (@('# Mỗi dòng một thư mục chứa dự án cần quét') + (Get-PurgeRoots))
        }
        Start-Process notepad.exe $f
        Write-Host "  Đã mở $f" -ForegroundColor Green
        return
    }
    Write-Banner 'Dọn thư mục build trong dự án'
    $roots = if ($Pos.Count) { @($Pos | ForEach-Object { (Resolve-Path -LiteralPath $_ -EA SilentlyContinue).Path } | Where-Object { $_ }) } else { Get-PurgeRoots }
    if (-not $roots) { Write-Host '  Không tìm thấy thư mục dự án. Dùng: mo purge <đường dẫn>  hoặc  mo purge --paths' -ForegroundColor Yellow; return }
    $days = if ($Flags['days']) { [int]$Flags['days'] } else { 7 }
    $depth = if ($Flags['depth']) { [int]$Flags['depth'] } else { 6 }
    foreach ($r in $roots) { Write-Host "  Quét: $r" -ForegroundColor DarkGray }

    $found = @()
    foreach ($r in $roots) { $found += [WinMole.Fs]::FindArtifacts($r, $depth) }
    $found = @($found | Where-Object { $_.Bytes -gt 0 } | Sort-Object Bytes -Descending)
    if ($found.Count -eq 0) { Write-Host '  Không có thư mục build nào.' -ForegroundColor Green; return }

    $items = foreach ($a in $found) {
        $proj = $a.Project
        foreach ($r in $roots) { if ($proj.StartsWith($r, 'OrdinalIgnoreCase')) { $proj = $proj.Substring($r.Length).TrimStart('\'); break } }
        if (-not $proj) { $proj = Split-Path $a.Project -Leaf }
        $recent = ((Get-Date) - $a.Modified).TotalDays -lt $days
        [pscustomobject]@{ Label = "$proj\$(Split-Path $a.Path -Leaf)"; Group = $a.Kind; Bytes = $a.Bytes
            Selected = (-not $recent -and $a.Kind -ne 'venv'); Disabled = $false
            Note = "sửa $(Age $a.Modified)" + $(if ($recent) { ' · mới dùng' } else { '' }); Ref = $a }
    }
    $items = @($items)
    if ($DryRun) { Show-Plan $items; return }
    $sel = Select-Checklist "Thư mục build/phụ thuộc (mặc định bỏ chọn mục sửa trong $days ngày)" $items
    if ($null -eq $sel -or $sel.Count -eq 0) { Write-Host '  Đã hủy.'; return }
    $est = ($sel | Measure-Object Bytes -Sum).Sum
    if (-not (Confirm-Action "Xóa $($sel.Count) thư mục (~$(Fmt $est))?")) { Write-Host '  Đã hủy.'; return }
    $total = 0
    foreach ($it in $sel) {
        if (-not (Test-Deletable $it.Ref.Path)) { continue }
        $r = [WinMole.Fs]::Delete($it.Ref.Path, $false, 0, $false)
        $total += $r.Bytes
        Write-OpLog 'purge' 'delete' $it.Ref.Path $r.Bytes
        Write-Host '  ✓ ' -ForegroundColor Green -NoNewline; Write-Host (Fit $it.Label 60) -NoNewline; Write-Host ((Fmt $r.Bytes).PadLeft(11)) -ForegroundColor Yellow
    }
    Write-Host ''
    Write-Host "  Đã giải phóng: $(Fmt $total)" -ForegroundColor Green
}

# ───────────────────────────── installer ─────────────────────────────
function Invoke-Installer {
    Write-Banner 'File cài đặt thừa'
    $dirs = @("$UHOME\Downloads", "$UHOME\Desktop", "$UHOME\OneDrive\Desktop", "$UHOME\Documents") | Where-Object { Test-Path -LiteralPath $_ }
    $pkgExt = '.msi', '.msix', '.msixbundle', '.appx', '.appxbundle', '.iso', '.img'
    $files = foreach ($d in $dirs) {
        $isDl = $d -like '*\Downloads'
        $depth = if ($isDl) { 2 } else { 0 }
        Get-ChildItem -LiteralPath $d -File -Recurse -Depth $depth -Force -EA SilentlyContinue | Where-Object {
            $e = $_.Extension.ToLower(); $n = $_.Name
            # .exe chỉ lấy ở gốc Downloads, tránh đụng vào game/app portable đã giải nén
            ($pkgExt -contains $e) -or ($e -eq '.exe' -and $isDl -and $_.DirectoryName -ieq $d) -or
            (('.zip', '.rar', '.7z') -contains $e -and $n -match '(?i)setup|install')
        }
    }
    $items = foreach ($f in @($files)) {
        $isSetup = ($pkgExt -contains $f.Extension.ToLower()) -or ($f.Name -match '(?i)setup|install|bootstrap|_x64|x86_64|win64|-win')
        [pscustomobject]@{ Label = $f.Name; Group = $f.Extension.TrimStart('.').ToUpper(); Bytes = $f.Length; Selected = $isSetup; Disabled = $false
            Note = "$(Age $f.LastWriteTime) · $(Split-Path $f.DirectoryName -Leaf)"; Ref = $f }
    }
    $items = @($items | Sort-Object Bytes -Descending)
    if ($items.Count -eq 0) { Write-Host '  Không có file cài đặt nào.' -ForegroundColor Green; return }
    if ($DryRun) { Show-Plan $items; return }
    $sel = Select-Checklist 'File cài đặt (sẽ chuyển vào Thùng rác)' $items
    if ($null -eq $sel -or $sel.Count -eq 0) { Write-Host '  Đã hủy.'; return }
    $est = ($sel | Measure-Object Bytes -Sum).Sum
    if (-not (Confirm-Action "Chuyển $($sel.Count) file (~$(Fmt $est)) vào Thùng rác?")) { Write-Host '  Đã hủy.'; return }
    foreach ($it in $sel) {
        try { Remove-ToRecycleBin $it.Ref.FullName; Write-OpLog 'installer' 'recycle' $it.Ref.FullName $it.Bytes; Write-Host "  ✓ $($it.Label)" -ForegroundColor Green }
        catch { Write-Host "  ✗ $($it.Label): $($_.Exception.Message)" -ForegroundColor Red }
    }
    Write-Host ''
    Write-Host "  Xong. Chạy 'mo clean' để dọn Thùng rác khi chắc chắn." -ForegroundColor Cyan
}

# ───────────────────────────── uninstall ─────────────────────────────
function Get-InstalledApps {
    $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
    Get-ItemProperty $keys -EA SilentlyContinue | Where-Object {
        $_.DisplayName -and ($_.UninstallString -or $_.QuietUninstallString) -and $_.SystemComponent -ne 1 -and -not $_.ParentKeyName -and $_.ReleaseType -notmatch 'Update|Hotfix'
    } | ForEach-Object {
        [pscustomobject]@{ Name = $_.DisplayName.Trim(); Version = $_.DisplayVersion; Publisher = $_.Publisher; Uninstall = $_.UninstallString
            Quiet = $_.QuietUninstallString; Location = $_.InstallLocation; Bytes = [int64]$_.EstimatedSize * 1KB; Key = $_.PSChildName }
    } | Sort-Object Name -Unique
}

function Get-NormName([string]$s) {
    if (-not $s) { return '' }
    ($s -replace '\(.*?\)', '' -replace '(?i)\b(x64|x86|64-bit|32-bit|version)\b', '' -replace 'v?\d+(\.\d+)+', '' -replace '_is1$', '').Trim(' -_.')
}

function Get-Leftovers($App) {
    $name = Get-NormName $App.Name
    $keys = @($name, ($name -replace '[\s\-_\.]', ''))
    if ($App.Location) { try { $keys += Split-Path $App.Location.Trim('"').TrimEnd('\') -Leaf } catch { } }
    if ($App.Key -notmatch '^\{') { $keys += Get-NormName $App.Key }
    $keys = @($keys | Where-Object { $_ -and $_.Length -ge 4 } | Select-Object -Unique)
    $pub = if ($App.Publisher) { ($App.Publisher -replace '(?i)[,\.]?\s+(Inc|LLC|Ltd|Corporation|Corp|GmbH|Co|Limited)\.?$', '').Trim() } else { $null }

    $found = @()
    foreach ($root in @($RAD, $LAD, "$LAD\Programs", $PDATA, $env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if (-not $root -or -not (Test-Path -LiteralPath $root)) { continue }
        foreach ($k in $keys) {
            try {
                $c = Join-Path $root $k; if (Test-Path -LiteralPath $c) { $found += $c }
                if ($pub) { $c2 = Join-Path (Join-Path $root $pub) $k; if (Test-Path -LiteralPath $c2) { $found += $c2 } }
            }
            catch { }
        }
    }
    foreach ($k in $keys) { try { $c = Join-Path $UHOME ('.' + ($k.ToLower() -replace '\s', '')); if (Test-Path -LiteralPath $c) { $found += $c } } catch { } }
    if ($App.Location) { $loc = $App.Location.Trim('"').TrimEnd('\'); if ($loc -and (Test-Path -LiteralPath $loc)) { $found += $loc } }

    $out = @()
    foreach ($p in @($found | ForEach-Object { (Get-Item -LiteralPath $_ -Force).FullName } | Select-Object -Unique)) {
        if (Test-Deletable $p) { $out += [pscustomobject]@{ Kind = 'dir'; Path = $p; Bytes = [WinMole.Fs]::Measure($p)[0] } }
    }
    foreach ($k in $keys) {
        foreach ($rk in @("HKCU:\Software\$k") + $(if ($pub) { @("HKCU:\Software\$pub\$k") } else { @() })) {
            if (Test-Path -LiteralPath $rk) { $out += [pscustomobject]@{ Kind = 'reg'; Path = $rk; Bytes = 0 } }
        }
    }
    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $run = Get-ItemProperty $runKey -EA SilentlyContinue
    if ($run) {
        foreach ($prop in $run.PSObject.Properties) {
            if ($prop.Name -like 'PS*') { continue }
            foreach ($k in $keys) { if ($prop.Name -like "*$k*" -or ([string]$prop.Value) -like "*\$k\*") { $out += [pscustomobject]@{ Kind = 'run'; Path = "$runKey\$($prop.Name)"; Bytes = 0; Value = $prop.Name }; break } }
        }
    }
    $out
}

function Split-Command([string]$s) {
    $s = $s.Trim()
    if ($s.StartsWith('"')) { $i = $s.IndexOf('"', 1); return @($s.Substring(1, $i - 1), $s.Substring($i + 1).Trim()) }
    $m = [regex]::Match($s, '(?i)^(.+?\.exe)\s*(.*)$')
    if ($m.Success) { return @($m.Groups[1].Value, $m.Groups[2].Value) }
    @($s, '')
}

function Invoke-Uninstall {
    Write-Banner 'Gỡ ứng dụng + dọn file sót'
    $apps = @(Get-InstalledApps)
    $q = ($Pos -join ' ').Trim()
    if (-not $q -and $script:Interactive) { $q = Read-Host '  Tìm ứng dụng (Enter = xem tất cả)' }
    if ($q) { $apps = @($apps | Where-Object { $_.Name -like "*$q*" -or $_.Publisher -like "*$q*" }) }
    if ($apps.Count -eq 0) { Write-Host '  Không tìm thấy ứng dụng nào.' -ForegroundColor Yellow; return }
    $items = foreach ($a in $apps) {
        [pscustomobject]@{ Label = $a.Name; Group = (Fit ([string]$a.Version) 13); Bytes = $a.Bytes; Selected = ($apps.Count -eq 1); Disabled = $false; Note = $a.Publisher; Ref = $a }
    }
    $items = @($items)
    if ($DryRun -or -not $script:Interactive) {
        if ($apps.Count -gt 15) { Show-Plan $items; Write-Host '  Thu hẹp bằng: mo uninstall --dry-run <tên>' -ForegroundColor DarkGray; return }
        foreach ($a in $apps) {
            Write-Host "  ■ $($a.Name) $($a.Version)" -ForegroundColor Cyan
            Write-Host "    Lệnh gỡ: $(if ($a.Quiet) { $a.Quiet } else { $a.Uninstall })" -ForegroundColor DarkGray
            foreach ($l in Get-Leftovers $a) { Write-Host ("    [{0}] {1}  {2}" -f $l.Kind, $l.Path, $(if ($l.Bytes) { Fmt $l.Bytes } else { '' })) }
        }
        return
    }
    $sel = Select-Checklist 'Chọn ứng dụng cần gỡ' $items
    if ($null -eq $sel -or $sel.Count -eq 0) { Write-Host '  Đã hủy.'; return }
    if (-not (Confirm-Action "Gỡ $($sel.Count) ứng dụng: $(($sel | ForEach-Object Label) -join ', ')?")) { Write-Host '  Đã hủy.'; return }

    foreach ($it in $sel) {
        $a = $it.Ref
        Write-Host ''
        Write-Host "  ■ Đang gỡ $($a.Name)..." -ForegroundColor Cyan
        $us = if ($a.Uninstall) { $a.Uninstall } else { $a.Quiet }
        try {
            if ($us -match '(?i)msiexec' -and $us -match '(\{[0-9A-F\-]+\})') { Start-Process msiexec.exe -ArgumentList "/x $($Matches[1])" -Wait }
            else { $p = Split-Command $us; if ($p[1]) { Start-Process -FilePath $p[0] -ArgumentList $p[1] -Wait } else { Start-Process -FilePath $p[0] -Wait } }
            Write-OpLog 'uninstall' 'run-uninstaller' $a.Name $a.Bytes
        }
        catch { Write-Host "    Không chạy được trình gỡ: $($_.Exception.Message)" -ForegroundColor Red }
        if ($script:Interactive) { Read-Host '    Nhấn Enter khi trình gỡ cài đặt đã hoàn tất' | Out-Null }

        $left = @(Get-Leftovers $a)
        if ($left.Count -eq 0) { Write-Host '    Không còn file sót.' -ForegroundColor Green; continue }
        $litems = @($left | ForEach-Object { [pscustomobject]@{ Label = $_.Path; Group = $_.Kind; Bytes = $_.Bytes; Selected = $true; Disabled = $false; Note = ''; Ref = $_ } })
        $lsel = Select-Checklist "File/registry sót lại của $($a.Name)" $litems
        if ($null -eq $lsel) { continue }
        foreach ($l in $lsel) {
            $o = $l.Ref
            try {
                switch ($o.Kind) {
                    'dir' { $r = [WinMole.Fs]::Delete($o.Path, $false, 0, $false); if ($r.Failed) { Write-Host "    ! $($o.Path): $($r.Failed) mục không xóa được (cần Admin?)" -ForegroundColor Yellow } }
                    'reg' { Remove-Item -LiteralPath $o.Path -Recurse -Force -EA Stop }
                    'run' { Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name $o.Value -EA Stop }
                }
                Write-OpLog 'uninstall' "delete-$($o.Kind)" $o.Path $o.Bytes
                Write-Host "    ✓ $($o.Path)" -ForegroundColor Green
            }
            catch { Write-Host "    ✗ $($o.Path): $($_.Exception.Message)" -ForegroundColor Red }
        }
    }
}

# ───────────────────────────── startup ─────────────────────────────
function Get-StartupItems {
    $ap = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'
    $srcs = @(
        @{ Src = 'HKCU Run'; Key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; Appr = "HKCU:\$ap\Run"; Admin = $false },
        @{ Src = 'HKLM Run'; Key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; Appr = "HKLM:\$ap\Run"; Admin = $true },
        @{ Src = 'HKLM Run32'; Key = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Appr = "HKLM:\$ap\Run32"; Admin = $true }
    )
    $procs = Get-Process -EA SilentlyContinue | Group-Object Name -AsHashTable -AsString
    $out = @()
    foreach ($s in $srcs) {
        $props = Get-ItemProperty -LiteralPath $s.Key -EA SilentlyContinue
        if (-not $props) { continue }
        foreach ($p in $props.PSObject.Properties) {
            if ($p.Name -like 'PS*') { continue }
            $v = [string]$p.Value
            if ($v -notmatch '\\|\.exe|\.cmd|\.bat|\.vbs') { continue }   # bỏ qua giá trị dữ liệu, không phải lệnh
            $out += [pscustomobject]@{ Name = $p.Name; Command = $v; Src = $s.Src; Appr = $s.Appr; ApprName = $p.Name; Admin = $s.Admin }
        }
    }
    foreach ($f in @(@{ Dir = [Environment]::GetFolderPath('Startup'); Appr = "HKCU:\$ap\StartupFolder"; Admin = $false; Src = 'Startup (user)' },
                     @{ Dir = [Environment]::GetFolderPath('CommonStartup'); Appr = "HKLM:\$ap\StartupFolder"; Admin = $true; Src = 'Startup (chung)' })) {
        foreach ($file in Get-ChildItem -LiteralPath $f.Dir -File -EA SilentlyContinue | Where-Object Name -ne 'desktop.ini') {
            $out += [pscustomobject]@{ Name = $file.BaseName; Command = $file.FullName; Src = $f.Src; Appr = $f.Appr; ApprName = $file.Name; Admin = $f.Admin }
        }
    }
    foreach ($o in $out) {
        $val = (Get-ItemProperty -LiteralPath $o.Appr -Name $o.ApprName -EA SilentlyContinue).($o.ApprName)
        $enabled = -not ($val -and ($val[0] -band 1))
        $exe = [IO.Path]::GetFileNameWithoutExtension(((Split-Command $o.Command)[0]))
        $mem = 0
        if ($exe -and $procs -and $procs.ContainsKey($exe)) { $mem = ($procs[$exe] | Measure-Object WorkingSet64 -Sum).Sum }
        $o | Add-Member Enabled $enabled; $o | Add-Member Mem ([int64]$mem); $o | Add-Member Exe $exe
    }
    $out
}

function Invoke-Startup {
    Write-Banner 'Ứng dụng khởi động cùng Windows'
    $isAdmin = Test-Admin
    $list = @(Get-StartupItems)
    if ($list.Count -eq 0) { Write-Host '  Không có ứng dụng khởi động nào.'; return }
    $items = @($list | ForEach-Object {
        $note = $_.Src
        if ($_.Mem) { $note += " · đang chạy $(Fmt $_.Mem)" }
        if ($_.Admin -and -not $isAdmin) { $note += ' · cần Admin' }
        [pscustomobject]@{ Label = $_.Name; Group = $(if ($_.Enabled) { 'Bật' } else { 'Tắt' }); Bytes = $_.Mem; Selected = $_.Enabled
            Disabled = ($_.Admin -and -not $isAdmin); Note = $note; Ref = $_ }
    })
    if ($DryRun -or -not $script:Interactive) {
        foreach ($it in $items) {
            $c = if ($it.Selected) { 'Green' } else { 'DarkGray' }
            Write-Host ('  [{0}] ' -f $(if ($it.Selected) { 'x' } else { ' ' })) -ForegroundColor $c -NoNewline
            Write-Host (Fit $it.Label 40) -NoNewline; Write-Host "  $($it.Note)" -ForegroundColor DarkGray
            Write-Host "       $($it.Ref.Command)" -ForegroundColor DarkGray
        }
        return
    }
    $sel = Select-Checklist '[x] = khởi động cùng Windows. Bỏ chọn để tắt (có thể bật lại bất cứ lúc nào)' $items 'Cột dung lượng = RAM đang dùng'
    if ($null -eq $sel) { Write-Host '  Đã hủy.'; return }
    $changed = 0
    foreach ($it in $items) {
        if ($it.Disabled) { continue }
        $want = [bool]$it.Selected
        if ($want -eq $it.Ref.Enabled) { continue }
        $bytes = if ($want) { [byte[]](2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0) } else { [byte[]](@(3, 0, 0, 0) + [BitConverter]::GetBytes((Get-Date).ToFileTime())) }
        try {
            if (-not (Test-Path -LiteralPath $it.Ref.Appr)) { New-Item -Path $it.Ref.Appr -Force | Out-Null }
            Set-ItemProperty -LiteralPath $it.Ref.Appr -Name $it.Ref.ApprName -Value $bytes -Type Binary -EA Stop
            Write-OpLog 'startup' $(if ($want) { 'enable' } else { 'disable' }) $it.Ref.Name 0
            Write-Host ('  {0} {1}' -f $(if ($want) { '✓ Bật' } else { '○ Tắt' }), $it.Label) -ForegroundColor $(if ($want) { 'Green' } else { 'Yellow' })
            $changed++
        }
        catch { Write-Host "  ✗ $($it.Label): $($_.Exception.Message)" -ForegroundColor Red }
    }
    if (-not $changed) { Write-Host '  Không có thay đổi.' } else { Write-Host "`n  Có hiệu lực từ lần khởi động sau." -ForegroundColor Cyan }
}

# ───────────────────────────── optimize ─────────────────────────────
function Get-OptimizeTasks {
    @(
        [pscustomobject]@{ Id = 'dns'; Label = 'Xóa cache DNS'; Admin = $false; Default = $true; Note = 'ipconfig /flushdns'
            Run = { ipconfig /flushdns | Out-Null } },
        [pscustomobject]@{ Id = 'icons'; Label = 'Làm mới cache icon & thumbnail'; Admin = $false; Default = $false; Note = 'khởi động lại Explorer'
            Run = {
                $ex = "$LAD\Microsoft\Windows\Explorer"
                Stop-Process -Name explorer -Force -EA SilentlyContinue
                for ($i = 0; $i -lt 5; $i++) {
                    Get-ChildItem $ex -Filter 'iconcache_*.db' -Force -EA SilentlyContinue | Remove-Item -Force -EA SilentlyContinue
                    Get-ChildItem $ex -Filter 'thumbcache_*.db' -Force -EA SilentlyContinue | Remove-Item -Force -EA SilentlyContinue
                    Remove-Item "$LAD\IconCache.db" -Force -EA SilentlyContinue
                    Start-Sleep -Milliseconds 300
                }
                if (-not (Get-Process explorer -EA SilentlyContinue)) { Start-Process explorer.exe }
            } },
        [pscustomobject]@{ Id = 'trim'; Label = "TRIM SSD ($env:SystemDrive)"; Admin = $true; Default = $true; Note = 'Optimize-Volume -ReTrim'
            Run = { Optimize-Volume -DriveLetter $env:SystemDrive.Substring(0, 1) -ReTrim -EA Stop } },
        [pscustomobject]@{ Id = 'delivery'; Label = 'Xóa cache Delivery Optimization'; Admin = $true; Default = $true; Note = 'bản cập nhật chia sẻ P2P'
            Run = { Delete-DeliveryOptimizationCache -Force -EA Stop } },
        [pscustomobject]@{ Id = 'dism'; Label = 'Dọn WinSxS (DISM)'; Admin = $true; Default = $false; Note = 'chậm 10-30 phút'
            Run = { Dism.exe /Online /Cleanup-Image /StartComponentCleanup } },
        [pscustomobject]@{ Id = 'wsl'; Label = 'Nén ổ ảo WSL/Docker (.vhdx)'; Admin = $true; Default = $false; Note = 'tắt WSL & Docker'
            Run = {
                $vhds = @(Get-ChildItem "$LAD\Docker\wsl" -Recurse -Filter '*.vhdx' -EA SilentlyContinue) + @(Get-ChildItem "$LAD\Packages\*\LocalState\*.vhdx" -EA SilentlyContinue)
                if (-not $vhds) { Write-Host '    Không có file .vhdx' -ForegroundColor DarkGray; return }
                Get-Process 'Docker Desktop', 'com.docker.backend', 'com.docker.build' -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
                wsl.exe --shutdown; Start-Sleep 3
                foreach ($v in $vhds) {
                    $before = $v.Length
                    $s = Join-Path $env:TEMP 'winmole-compact.txt'
                    Set-Content $s -Encoding ASCII -Value "select vdisk file=`"$($v.FullName)`"`r`nattach vdisk readonly`r`ncompact vdisk`r`ndetach vdisk`r`nexit"
                    diskpart.exe /s $s | Out-Null
                    Remove-Item $s -Force -EA SilentlyContinue
                    Write-Host "    $($v.Name): $(Fmt $before) → $(Fmt (Get-Item -LiteralPath $v.FullName).Length)" -ForegroundColor DarkGray
                }
            } }
    )
}

function Invoke-Optimize {
    Write-Banner 'Tối ưu hệ thống'
    $isAdmin = Test-Admin
    $wl = Get-Whitelist
    $items = @(Get-OptimizeTasks | ForEach-Object {
        $dis = $false; $note = $_.Note
        if ($wl -contains "opt:$($_.Id)") { $dis = $true; $note = 'whitelist' }
        elseif ($_.Admin -and -not $isAdmin) { $dis = $true; $note = "cần Admin: mo optimize --admin" }
        [pscustomobject]@{ Label = $_.Label; Group = $(if ($_.Admin) { 'Admin' } else { 'User' }); Bytes = $null; Selected = $_.Default; Disabled = $dis; Note = $note; Ref = $_ }
    })
    if ($DryRun) { Show-Plan $items; return }
    $sel = Select-Checklist 'Chọn tác vụ tối ưu' $items
    if ($null -eq $sel -or $sel.Count -eq 0) { Write-Host '  Đã hủy.'; return }
    Write-Banner 'Tối ưu hệ thống'
    foreach ($it in $sel) {
        Write-Host "  » $($it.Label)..." -ForegroundColor Cyan
        try { & $it.Ref.Run; Write-OpLog 'optimize' $it.Ref.Id '' 0; Write-Host '    ✓ xong' -ForegroundColor Green }
        catch { Write-Host "    ✗ $($_.Exception.Message)" -ForegroundColor Red }
    }
}

# ───────────────────────────── analyze ─────────────────────────────
function Get-DriveEntries {
    @([IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady -and ($_.DriveType -eq 'Fixed' -or $_.DriveType -eq 'Removable') } | ForEach-Object {
        [pscustomobject]@{ Path = $_.RootDirectory.FullName; Name = "$($_.Name) $($_.VolumeLabel)  (trống $(Fmt $_.AvailableFreeSpace) / $(Fmt $_.TotalSize))"
            Bytes = $_.TotalSize - $_.AvailableFreeSpace; Files = 0; IsDir = $true; IsLink = $false; Modified = [datetime]::MinValue }
    })
}

function Invoke-Analyze {
    $start = if ($Pos.Count) { (Resolve-Path -LiteralPath $Pos[0] -EA SilentlyContinue).Path } else { $null }
    if ($Pos.Count -and -not $start) { Write-Host "  Không tìm thấy: $($Pos[0])" -ForegroundColor Red; return }

    if ($Flags['json'] -or -not $script:Interactive) {
        if (-not $start) { $start = (Get-Location).Path }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $ch = [WinMole.Fs]::Children($start)
        $tot = ($ch | Measure-Object Bytes -Sum).Sum
        if ($Flags['json']) {
            [ordered]@{ path = $start; bytes = [int64]$tot; files = [int64](($ch | Measure-Object Files -Sum).Sum); scanMs = $sw.ElapsedMilliseconds; status = 'complete'
                children = @($ch | ForEach-Object { [ordered]@{ name = $_.Name; path = $_.Path; bytes = $_.Bytes; files = $_.Files; isDir = $_.IsDir; isLink = $_.IsLink; modified = $_.Modified.ToString('s') } })
            } | ConvertTo-Json -Depth 4
        }
        else {
            Write-Banner "Phân tích $start"
            foreach ($e in $ch | Select-Object -First 25) {
                $pct = if ($tot) { $e.Bytes / $tot * 100 } else { 0 }
                Write-Host ('  {0,10}  {1,5:N1}%  {2}{3}' -f (Fmt $e.Bytes), $pct, $e.Name, $(if ($e.IsDir) { '\' } else { '' }))
            }
            Write-Host "`n  Tổng: $(Fmt $tot) · quét $($sw.ElapsedMilliseconds) ms" -ForegroundColor Cyan
        }
        return
    }

    $cache = @{}
    $stack = New-Object System.Collections.Generic.Stack[object]
    $cur = $start; $idx = 0; $off = 0; $msg = ''
    Enter-Screen
    try {
        while ($true) {
            if ($null -eq $cur) { $entries = Get-DriveEntries; $title = 'Chọn ổ đĩa' }
            else {
                if (-not $cache.ContainsKey($cur)) {
                    Draw-Screen @(, @((S "  Đang quét $cur ..." 'Yellow')))
                    $cache[$cur] = [System.Collections.ArrayList]@([WinMole.Fs]::Children($cur))
                }
                $entries = $cache[$cur]; $title = $cur
            }
            $n = @($entries).Count
            if ($idx -ge $n) { $idx = [Math]::Max(0, $n - 1) }
            $tot = (@($entries) | Measure-Object Bytes -Sum).Sum
            $view = [Math]::Max(3, [Console]::WindowHeight - 7)
            if ($idx -lt $off) { $off = $idx }
            if ($idx -ge $off + $view) { $off = $idx - $view + 1 }

            $lines = New-Object 'System.Collections.Generic.List[object]'
            $lines.Add(@((S '  WinMole · ' 'Cyan'), (S $title 'White'), (S "   $(Fmt $tot) · $n mục" 'DarkGray')))
            $lines.Add(@((S '  ↑↓ chọn · Enter/→ mở · ←/Backspace lùi · O mở Explorer · Del xóa (Thùng rác) · R quét lại · Q thoát' 'DarkGray')))
            $lines.Add(@())
            $end = [Math]::Min($n, $off + $view)
            for ($i = $off; $i -lt $end; $i++) {
                $e = $entries[$i]
                $pct = if ($tot) { $e.Bytes / $tot * 100 } else { 0 }
                $sel = ($i -eq $idx)
                $nameC = if ($sel) { 'Cyan' } elseif ($e.IsLink) { 'DarkGray' } elseif ($e.IsDir) { 'White' } else { 'Gray' }
                $name = $e.Name + $(if ($e.IsLink) { '  → (liên kết)' } elseif ($e.IsDir -and $null -ne $cur) { '\' } else { '' })
                $seg = @((S $(if ($sel) { ' > ' } else { '   ' }) 'Cyan'), (S ((Fmt $e.Bytes).PadLeft(10) + '  ') 'Yellow'))
                $seg += Bar $pct 16
                $seg += (S ('  {0,5:N1}%  ' -f $pct) 'DarkGray')
                $seg += (S $name $nameC)
                $lines.Add($seg)
            }
            if ($n -eq 0) { $lines.Add(@((S '   (trống hoặc không có quyền đọc)' 'DarkGray'))) }
            $lines.Add(@())
            if ($msg) { $lines.Add(@((S "  $msg" 'Yellow'))); $msg = '' }
            Draw-Screen $lines

            $k = [Console]::ReadKey($true)
            $e = if ($n) { $entries[$idx] } else { $null }
            switch ($k.Key) {
                'UpArrow' { if ($idx -gt 0) { $idx-- } }
                'DownArrow' { if ($idx -lt $n - 1) { $idx++ } }
                'PageUp' { $idx = [Math]::Max(0, $idx - $view) }
                'PageDown' { $idx = [Math]::Min([Math]::Max(0, $n - 1), $idx + $view) }
                'Home' { $idx = 0 }
                'End' { $idx = [Math]::Max(0, $n - 1) }
                { $_ -eq 'Enter' -or $_ -eq 'RightArrow' } {
                    if ($e -and $e.IsDir -and -not $e.IsLink) { $stack.Push(@($cur, $idx, $off)); $cur = $e.Path; $idx = 0; $off = 0 }
                }
                { $_ -eq 'LeftArrow' -or $_ -eq 'Backspace' } {
                    if ($stack.Count) { $f = $stack.Pop(); $cur = $f[0]; $idx = $f[1]; $off = $f[2] }
                    elseif ($null -ne $cur) {
                        $parent = Split-Path $cur -Parent
                        $cur = if ($parent) { $parent } else { $null }; $idx = 0; $off = 0
                    }
                }
                'O' { if ($e) { Start-Process explorer.exe "/select,`"$($e.Path)`"" } }
                'R' { if ($null -ne $cur) { $cache.Remove($cur) } }
                { $_ -eq 'Delete' -or $_ -eq 'D' } {
                    if (-not $e -or $null -eq $cur) { break }
                    if (-not (Test-Deletable $e.Path)) { $msg = 'Thư mục được bảo vệ, không thể xóa.'; break }
                    $lines.Add(@((S "  Xóa '$($e.Name)' ($(Fmt $e.Bytes)) vào Thùng rác? y/N" 'Red')))
                    Draw-Screen $lines
                    if ([Console]::ReadKey($true).Key -ne 'Y') { break }
                    try {
                        Remove-ToRecycleBin $e.Path
                        Write-OpLog 'analyze' 'recycle' $e.Path $e.Bytes
                        $entries.RemoveAt($idx)
                        foreach ($key in @($cache.Keys)) {
                            if ($key -ne $cur -and $cur.StartsWith($key, 'OrdinalIgnoreCase')) {
                                foreach ($x in $cache[$key]) { if ($cur.StartsWith($x.Path, 'OrdinalIgnoreCase')) { $x.Bytes -= $e.Bytes } }
                            }
                        }
                        $msg = "Đã chuyển vào Thùng rác: $($e.Name)"
                    }
                    catch { $msg = "Lỗi: $($_.Exception.Message)" }
                }
                'Escape' { return }
                'Q' { return }
            }
        }
    }
    finally { Exit-Screen }
}

# ───────────────────────────── status ─────────────────────────────
function Get-Status {
    $cores = [Environment]::ProcessorCount
    $cpu = @(Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -EA SilentlyContinue)
    $os = Get-CimInstance Win32_OperatingSystem
    $pm = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory -EA SilentlyContinue
    $dio = Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk -Filter "Name='_Total'" -EA SilentlyContinue
    $net = @(Get-CimInstance Win32_PerfFormattedData_Tcpip_NetworkInterface -EA SilentlyContinue)
    $eng = @(Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine -EA SilentlyContinue | Where-Object { $_.Name -match 'engtype_3D' })
    $vram = (Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUAdapterMemory -EA SilentlyContinue | Measure-Object DedicatedUsage -Sum).Sum
    $bat = Get-CimInstance Win32_Battery -EA SilentlyContinue | Select-Object -First 1
    $procs = @(Get-CimInstance Win32_PerfFormattedData_PerfProc_Process -EA SilentlyContinue | Where-Object { $_.Name -ne '_Total' -and $_.Name -ne 'Idle' })

    $gpu = 0
    if ($eng) {
        $per = $eng | Group-Object { if ($_.Name -match 'luid_(0x\w+_0x\w+)') { $Matches[1] } else { 'x' } } | ForEach-Object { ($_.Group | Measure-Object UtilizationPercentage -Sum).Sum }
        $gpu = [Math]::Min(100, ($per | Measure-Object -Maximum).Maximum)
    }
    $memTotal = [int64]$os.TotalVisibleMemorySize * 1KB
    $memFree = [int64]$os.FreePhysicalMemory * 1KB
    [ordered]@{
        time     = (Get-Date).ToString('s')
        uptime   = [int]((Get-Date) - $os.LastBootUpTime).TotalSeconds
        cpu      = [ordered]@{ percent = [int](($cpu | Where-Object Name -eq '_Total').PercentProcessorTime); threads = $cores
            cores = @($cpu | Where-Object Name -ne '_Total' | Sort-Object { [int]$_.Name } | ForEach-Object { [int]$_.PercentProcessorTime }) }
        memory   = [ordered]@{ total = $memTotal; used = $memTotal - $memFree; percent = [Math]::Round(($memTotal - $memFree) / $memTotal * 100, 1)
            committed = [int64]$pm.CommittedBytes; commitLimit = [int64]$pm.CommitLimit }
        gpu      = [ordered]@{ percent3d = [int]$gpu; vramUsed = [int64]$vram }
        disks    = @([IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady -and $_.DriveType -eq 'Fixed' } | ForEach-Object {
                [ordered]@{ name = $_.Name.TrimEnd('\'); total = $_.TotalSize; free = $_.AvailableFreeSpace; percent = [Math]::Round(($_.TotalSize - $_.AvailableFreeSpace) / $_.TotalSize * 100, 1) } })
        diskIO   = [ordered]@{ readBps = [int64]$dio.DiskReadBytesPersec; writeBps = [int64]$dio.DiskWriteBytesPersec }
        network  = [ordered]@{ rxBps = [int64](($net | Measure-Object BytesReceivedPersec -Sum).Sum); txBps = [int64](($net | Measure-Object BytesSentPersec -Sum).Sum) }
        battery  = if ($bat) { [ordered]@{ percent = [int]$bat.EstimatedChargeRemaining; charging = ($bat.BatteryStatus -eq 2 -or $bat.BatteryStatus -ge 6) } } else { $null }
        topCpu   = @($procs | Sort-Object PercentProcessorTime -Descending | Select-Object -First 7 | ForEach-Object {
                [ordered]@{ name = ($_.Name -replace '#\d+$', ''); pid = [int]$_.IDProcess; cpu = [Math]::Round($_.PercentProcessorTime / $cores, 1) } })
        topMem   = @($procs | Group-Object { $_.Name -replace '#\d+$', '' } | ForEach-Object {
                [ordered]@{ name = $_.Name; count = $_.Count; bytes = [int64](($_.Group | Measure-Object WorkingSetPrivate -Sum).Sum) } } |
                Sort-Object { $_.bytes } -Descending | Select-Object -First 7)
    }
}

function Format-Uptime([int]$s) { $t = [TimeSpan]::FromSeconds($s); if ($t.Days) { '{0}d {1}h {2}m' -f $t.Days, $t.Hours, $t.Minutes } else { '{0}h {1}m' -f $t.Hours, $t.Minutes } }

function Get-StatusLines($s, [double]$CpuAlert) {
    $L2 = New-Object 'System.Collections.Generic.List[object]'
    $L2.Add(@((S '  WinMole · Trạng thái hệ thống' 'Cyan'), (S "   $((Get-Date).ToString('HH:mm:ss')) · uptime $(Format-Uptime $s.uptime) · Q thoát" 'DarkGray')))
    $L2.Add(@())
    $L2.Add(@((S '  CPU    ' 'White')) + (Bar $s.cpu.percent 30) + @((S ('  {0,3}%' -f $s.cpu.percent)), (S "   $($s.cpu.threads) luồng" 'DarkGray')))
    $coreSeg = @((S '         ' ))
    foreach ($c in $s.cpu.cores) { $col = if ($c -ge 85) { 'Red' } elseif ($c -ge 50) { 'Yellow' } else { 'DarkGreen' }; $coreSeg += (S ('{0,3} ' -f $c) $col) }
    $L2.Add($coreSeg)
    $m = $s.memory
    $L2.Add(@((S '  RAM    ' 'White')) + (Bar $m.percent 30) + @((S ('  {0,3:N0}%' -f $m.percent)), (S "   $(Fmt $m.used) / $(Fmt $m.total) · commit $(Fmt $m.committed) / $(Fmt $m.commitLimit)" 'DarkGray')))
    $L2.Add(@((S '  GPU    ' 'White')) + (Bar $s.gpu.percent3d 30) + @((S ('  {0,3}%' -f $s.gpu.percent3d)), (S "   VRAM $(Fmt $s.gpu.vramUsed)" 'DarkGray')))
    foreach ($d in $s.disks) {
        $L2.Add(@((S ('  Ổ {0,-4}' -f $d.name) 'White')) + (Bar $d.percent 30) + @((S ('  {0,3:N0}%' -f $d.percent)), (S "   trống $(Fmt $d.free) / $(Fmt $d.total)" 'DarkGray')))
    }
    $L2.Add(@((S '  Đĩa    ' 'White'), (S "đọc $(Fmt $s.diskIO.readBps)/s · ghi $(Fmt $s.diskIO.writeBps)/s")))
    $L2.Add(@((S '  Mạng   ' 'White'), (S "↓ $(Fmt $s.network.rxBps)/s · ↑ $(Fmt $s.network.txBps)/s")))
    if ($s.battery) { $L2.Add(@((S '  Pin    ' 'White')) + (Bar (100 - $s.battery.percent) 30) + @((S ('  {0,3}%' -f $s.battery.percent)), (S $(if ($s.battery.charging) { '   đang sạc' } else { '   dùng pin' }) 'DarkGray'))) }
    $L2.Add(@())
    $L2.Add(@((S (Fit '  Top CPU' 42) 'Cyan'), (S 'Top RAM' 'Cyan')))
    for ($i = 0; $i -lt 7; $i++) {
        $a = $s.topCpu | Select-Object -Index $i
        $b = $s.topMem | Select-Object -Index $i
        $left = if ($a) { '  {0} {1,6:N1}%' -f (Fit $a.name 30), $a.cpu } else { '' }
        $lc = if ($a -and $a.cpu -ge $CpuAlert) { 'Red' } else { $null }
        $right = if ($b) { '{0} {1,10}' -f (Fit ("$($b.name)" + $(if ($b.count -gt 1) { " ($($b.count))" } else { '' })) 28), (Fmt $b.bytes) } else { '' }
        $L2.Add(@((S (Fit $left 42) $lc), (S $right)))
    }
    $L2
}

function Invoke-Status {
    $interval = if ($Flags['interval']) { [double](([string]$Flags['interval']) -replace '[^\d\.]', '') } else { 2 }
    if ($interval -lt 0.5) { $interval = 0.5 }
    $cpuAlert = if ($Flags['proc-cpu-threshold']) { [double]$Flags['proc-cpu-threshold'] } else { 50 }
    if ($Flags['json'] -or ($Flags['watch'] -and -not $script:Interactive) -or (-not $script:Interactive)) {
        $null = Get-Status; Start-Sleep -Milliseconds 800   # lần đầu bộ đếm hiệu năng thường = 0
        if ($Flags['watch']) { while ($true) { Get-Status | ConvertTo-Json -Depth 4 -Compress; Start-Sleep -Seconds $interval } }
        Get-Status | ConvertTo-Json -Depth 4
        return
    }
    if ($Flags['watch']) { while ($true) { Get-Status | ConvertTo-Json -Depth 4 -Compress; Start-Sleep -Seconds $interval } }
    Enter-Screen
    try {
        Draw-Screen @(, @((S '  Đang đọc bộ đếm hiệu năng...' 'DarkGray')))
        $null = Get-Status
        while ($true) {
            Draw-Screen (Get-StatusLines (Get-Status) $cpuAlert)
            $until = (Get-Date).AddSeconds($interval)
            while ((Get-Date) -lt $until) {
                if ([Console]::KeyAvailable) { $k = [Console]::ReadKey($true); if ($k.Key -eq 'Q' -or $k.Key -eq 'Escape') { return } }
                Start-Sleep -Milliseconds 100
            }
        }
    }
    finally { Exit-Screen }
}

# ───────────────────────────── history ─────────────────────────────
function Invoke-History {
    if (-not (Test-Path -LiteralPath $LogFile)) { Write-Host '  Chưa có lịch sử.'; return }
    $rows = @(Get-Content -LiteralPath $LogFile -Encoding UTF8 | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } })
    if ($Flags['json']) { $rows | ConvertTo-Json -Depth 3; return }
    Write-Banner 'Lịch sử thao tác'
    $grand = 0
    foreach ($g in $rows | Group-Object session | Select-Object -Last 25) {
        $f = $g.Group[0]
        $b = ($g.Group | Measure-Object bytes -Sum).Sum; $grand += $b
        Write-Host ('  {0}  ' -f ([datetime]$f.time).ToString('yyyy-MM-dd HH:mm')) -ForegroundColor DarkGray -NoNewline
        Write-Host (Fit $f.cmd 11) -ForegroundColor Cyan -NoNewline
        Write-Host ('{0,4} mục  ' -f $g.Count) -NoNewline
        Write-Host (Fmt $b).PadLeft(11) -ForegroundColor Yellow
    }
    Write-Host ''
    Write-Host "  Tổng đã giải phóng (25 lần gần nhất): $(Fmt $grand)" -ForegroundColor Green
    Write-Host "  Log chi tiết: $LogFile" -ForegroundColor DarkGray
}

# ───────────────────────────── install / remove ─────────────────────────────
$InstallDir = Join-Path $LAD 'Programs\WinMole'

function Get-UserPath {
    $k = Get-Item HKCU:\Environment
    $kind = try { $k.GetValueKind('Path') } catch { 'ExpandString' }
    [pscustomobject]@{ Raw = [string]$k.GetValue('Path', '', 'DoNotExpandEnvironmentNames'); Kind = $kind }
}

# Ghi PATH vào registry giữ nguyên kiểu (REG_EXPAND_SZ) để không làm hỏng các mục %VAR%,
# sau đó đặt WINMOLE_HOME qua .NET để Windows phát WM_SETTINGCHANGE cho terminal mới
function Set-UserPath([string]$Value, $Kind, [string]$HomeValue) {
    Set-ItemProperty -Path HKCU:\Environment -Name Path -Value $Value -Type $Kind
    [Environment]::SetEnvironmentVariable('WINMOLE_HOME', $HomeValue, 'User')
}

function Invoke-Install {
    Write-Banner 'Cài đặt'
    $src = $MoleRoot.TrimEnd('\')
    if ($src -ine $InstallDir) {
        if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }
        foreach ($f in 'mo.cmd', 'winmole.ps1', 'README.md') {
            if (Test-Path -LiteralPath "$src\$f") { Copy-Item -LiteralPath "$src\$f" -Destination $InstallDir -Force }
        }
        foreach ($d in 'config', 'logs') {
            if ((Test-Path -LiteralPath "$src\$d") -and -not (Test-Path -LiteralPath "$InstallDir\$d")) { Copy-Item -LiteralPath "$src\$d" -Destination $InstallDir -Recurse }
        }
        Write-Host "  ✓ Đã chép vào $InstallDir" -ForegroundColor Green
    }
    $p = Get-UserPath
    $parts = @($p.Raw -split ';' | Where-Object { $_ })
    if ($parts | Where-Object { $_.TrimEnd('\') -ieq $InstallDir }) { Write-Host '  ✓ Đã có trong PATH' -ForegroundColor Green }
    else {
        Set-UserPath (($parts + $InstallDir) -join ';') $p.Kind $InstallDir
        Write-Host '  ✓ Đã thêm vào PATH của user' -ForegroundColor Green
    }
    # Biên dịch sẵn lõi C# ở vị trí mới
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$InstallDir\winmole.ps1" analyze --json "$InstallDir" | Out-Null
    Write-Host ''
    Write-Host '  Mở terminal MỚI rồi gõ: ' -NoNewline; Write-Host 'mo' -ForegroundColor Cyan
    Write-Host '  Gỡ cài đặt: mo remove' -ForegroundColor DarkGray
}

function Invoke-Remove {
    Write-Banner 'Gỡ WinMole'
    if (-not (Confirm-Action "Xóa WinMole khỏi PATH và xóa $InstallDir (kèm config, log)?")) { Write-Host '  Đã hủy.'; return }
    $p = Get-UserPath
    $parts = @($p.Raw -split ';' | Where-Object { $_ -and $_.TrimEnd('\') -ine $InstallDir })
    Set-UserPath ($parts -join ';') $p.Kind $null
    Write-Host '  ✓ Đã xóa khỏi PATH' -ForegroundColor Green
    if (Test-Path -LiteralPath $InstallDir) {
        # Thư mục đang bị khóa bởi chính tiến trình này (lib\*.dll) → xóa sau khi thoát
        Start-Process cmd.exe -ArgumentList "/c timeout /t 2 /nobreak >nul & rmdir /s /q `"$InstallDir`"" -WindowStyle Hidden
        Write-Host "  ✓ $InstallDir sẽ được xóa sau vài giây" -ForegroundColor Green
    }
    if ($MoleRoot.TrimEnd('\') -ine $InstallDir) { Write-Host "  (Bản portable tại $MoleRoot vẫn giữ nguyên)" -ForegroundColor DarkGray }
}

# ───────────────────────────── help / menu ─────────────────────────────
function Show-Help {
    Write-Banner ''
    $h = @'
  Cách dùng: mo [lệnh] [tùy chọn]        (không có lệnh = menu tương tác)

  clean        Dọn cache, temp, log, crash dump, thùng rác, cache trình duyệt/dev/GPU, bản app cũ
               --dry-run  xem trước · --debug  kèm đường dẫn · --whitelist  chọn mục bảo vệ · --yes  không hỏi
  uninstall    Gỡ ứng dụng + dọn thư mục, registry, mục khởi động còn sót      [tên] --dry-run
  optimize     Xóa cache DNS, làm mới icon, TRIM SSD, dọn WinSxS, nén ổ WSL/Docker   --dry-run
  startup      Bật/tắt ứng dụng khởi động cùng Windows (giống Task Manager, có thể bật lại)
  analyze      Duyệt dung lượng ổ đĩa trong terminal      [đường dẫn] --json
  status       Bảng theo dõi CPU/RAM/GPU/ổ đĩa/mạng/pin/tiến trình
               --json · --watch --interval 2 · --proc-cpu-threshold 50
  purge        Dọn node_modules, build, dist, target, .dart_tool... trong dự án
               [đường dẫn] --paths (sửa thư mục quét) --days 7 --depth 6 --dry-run --yes
  installer    Tìm file cài đặt (.msi .exe .iso...) trong Downloads/Desktop → Thùng rác   --dry-run
  history      Lịch sử dọn dẹp      --json
  install      Cài vào %LOCALAPPDATA%\Programs\WinMole + thêm vào PATH (gõ 'mo' ở mọi nơi)
  remove       Gỡ WinMole khỏi máy

  Chung:       --admin  chạy lại với quyền Admin · --version · --help
'@
    Write-Host $h
}

function Show-Menu {
    $opts = @(
        [pscustomobject]@{ Label = '1  Dọn dẹp'; Desc = 'cache, temp, log, thùng rác...'; Cmd = 'clean' },
        [pscustomobject]@{ Label = '2  Gỡ ứng dụng'; Desc = 'gỡ app + file sót'; Cmd = 'uninstall' },
        [pscustomobject]@{ Label = '3  Tối ưu'; Desc = 'DNS, icon, TRIM, WinSxS, WSL'; Cmd = 'optimize' },
        [pscustomobject]@{ Label = '4  Khởi động'; Desc = 'bật/tắt app chạy cùng Windows'; Cmd = 'startup' },
        [pscustomobject]@{ Label = '5  Phân tích ổ đĩa'; Desc = 'xem thư mục nào chiếm chỗ'; Cmd = 'analyze' },
        [pscustomobject]@{ Label = '6  Trạng thái'; Desc = 'CPU, RAM, GPU, ổ đĩa, mạng'; Cmd = 'status' },
        [pscustomobject]@{ Label = '7  Dọn dự án'; Desc = 'node_modules, build, dist...'; Cmd = 'purge' },
        [pscustomobject]@{ Label = '8  File cài đặt'; Desc = '.msi .exe .iso đã tải'; Cmd = 'installer' },
        [pscustomobject]@{ Label = '9  Lịch sử'; Desc = 'các lần dọn trước'; Cmd = 'history' }
    )
    $admin = if (Test-Admin) { 'Đang chạy với quyền Admin' } else { 'Quyền thường (thêm --admin để mở khóa tác vụ hệ thống)' }
    while ($true) {
        $i = Select-Menu $admin $opts
        if ($i -lt 0) { return }
        Invoke-MoCommand $opts[$i].Cmd
        Write-Host ''
        Write-Host '  Nhấn phím bất kỳ để quay lại menu...' -ForegroundColor DarkGray
        $null = [Console]::ReadKey($true)
    }
}

function Invoke-MoCommand([string]$c) {
    switch ($c) {
        'clean' { Invoke-Clean }
        'uninstall' { Invoke-Uninstall }
        'optimize' { Invoke-Optimize }
        'startup' { Invoke-Startup }
        'analyze' { Invoke-Analyze }
        'status' { Invoke-Status }
        'purge' { Invoke-Purge }
        'installer' { Invoke-Installer }
        'history' { Invoke-History }
        'install' { Invoke-Install }
        'remove' { Invoke-Remove }
        default { Write-Host "  Lệnh không hợp lệ: $c" -ForegroundColor Red; Show-Help }
    }
}

# ───────────────────────────── main ─────────────────────────────
if ($Flags['version']) { "WinMole $script:Version"; return }
if ($Flags['help'] -or $Flags['h'] -or $Cmd -eq 'help') { Show-Help; return }
if ($Flags['admin'] -and -not (Test-Admin)) {
    $rest = @($argv | Where-Object { $_ -ne '--admin' } | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }) -join ' '
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -NoExit -File `"$PSCommandPath`" $rest"
    return
}
Initialize-Core
if (-not $Cmd) {
    if ($script:Interactive) { Show-Menu } else { Show-Help }
}
else { Invoke-MoCommand $Cmd }
