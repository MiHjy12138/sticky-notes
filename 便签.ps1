# ============================================================
#  便签 StickyNotes v1.6  (Win7 风格便签)
#  双击运行 = 新建一张便签;再次双击 = 再开一张(可多张)
#  特点:黄色小窗置顶显示 / 文本自动保存 / 位置记忆 / 可拖动缩放
#       / 6 色切换 / 历史窗口 / 全部关闭
#  v1.6: 右键菜单「删除线」—— 选中文字加/取消删除线(无选中=全文切换)
#        RichTextBox 富文本; 纯文本存储用 ~~文字~~ 标记删除线, .txt 兼容
#  数据默认保存在: %APPDATA%\StickyNotes\
#  可通过环境变量 STICKYNOTE_DATA_DIR 覆盖(便携/测试用)
#  脚本自身自动滚动备份: 改完启动时自动 .bak-<时间戳>, 留最近 5 份
#  可通过环境变量 STICKYNOTE_NO_BACKUP=1 跳过(测试用)
# ============================================================
param(
    [string]$NoteFile = '',
    [switch]$RestoreAll,
    [switch]$ShowHistory
)

# ---------- 加载所有程序集(修 8) ----------
$ErrorActionPreference = 'Stop'
try {
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase
    Add-Type -AssemblyName Microsoft.VisualBasic
} catch {
    try { [System.Windows.MessageBox]::Show("加载程序集失败: $_", "便签错误", 'OK', 'Error') } catch {}
    exit 1
}

# ---------- 脚本自身路径(备份用) ----------
$scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $PSCommandPath }
$scriptPath = Join-Path $scriptRoot '便签.ps1'

# ---------- 数据目录(修 1: 合并; 加 STICKYNOTE_DATA_DIR 支持) ----------
$dataDir = $env:STICKYNOTE_DATA_DIR
if (-not $dataDir) { $dataDir = Join-Path $env:APPDATA 'StickyNotes' }
if (-not (Test-Path -LiteralPath $dataDir)) {
    New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
}
$stateFile = Join-Path $dataDir 'session-state.txt'
$pidFile   = Join-Path $dataDir 'running.pids'

# ---------- 自动滚动备份(修 6) ----------
function Invoke-AutoBackup {
    param([string]$ScriptPath, [int]$MaxBackups = 5)
    if (-not (Test-Path -LiteralPath $ScriptPath)) { return }
    $bakPattern = "$ScriptPath.bak-*"
    $existing = @(Get-ChildItem -Path $bakPattern -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending)
    $psTime = (Get-Item -LiteralPath $ScriptPath).LastWriteTime
    $needBackup = $true
    if ($existing.Count -gt 0) {
        $needBackup = $psTime -gt $existing[0].LastWriteTime
    }
    if ($needBackup) {
        $ts = $psTime.ToString('yyyyMMdd_HHmmss')
        $newBak = "$ScriptPath.bak-$ts"
        Copy-Item -LiteralPath $ScriptPath -Destination $newBak -Force
        $all = @(Get-ChildItem -Path $bakPattern -File | Sort-Object LastWriteTime -Descending)
        if ($all.Count -gt $MaxBackups) {
            $all | Select-Object -Skip $MaxBackups | Remove-Item -Force
        }
    }
    # 清理老的无时间戳 .bak(兼容老格式)
    $legacyBak = "$ScriptPath.bak"
    if (Test-Path -LiteralPath $legacyBak) {
        Remove-Item -LiteralPath $legacyBak -Force
    }
}
if (-not $env:STICKYNOTE_NO_BACKUP) {
    Invoke-AutoBackup -ScriptPath $scriptPath
}

# ---------- 颜色表(修 10: 单一源) ----------
$script:colors = [ordered]@{
    '黄' = @{ bg = '#FFFFE0'; title = '#FFE9C4'; border = '#D0C080' }
    '绿' = @{ bg = '#E8F5D8'; title = '#D4E8B8'; border = '#A8C878' }
    '蓝' = @{ bg = '#E0F0FF'; title = '#C8E0F8'; border = '#90B8E0' }
    '粉' = @{ bg = '#FFE8F0'; title = '#FFD0E0'; border = '#E0A0B8' }
    '紫' = @{ bg = '#F0E8FF'; title = '#E0D0F8'; border = '#B8A0E0' }
    '橙' = @{ bg = '#FFF0E0'; title = '#FFE0C0'; border = '#E0B080' }
}
$script:noteColor = '黄'

# ---------- 心跳文件(修 2: 替代 CIM 扫进程) ----------
# 修 16: 写文件统一走临时文件+Move 原子替换+重试, 消除并发启动的文件锁竞态
# 修 22(workbuddy B4/T1): 改用 WriteAllText, 不追加尾随换行(Out-File 的隐藏行为), 内容往返一致
function Write-TextFile {
    param([string]$Path, [string]$Content)
    for ($i = 0; $i -lt 5; $i++) {
        try {
            $tmp = "$Path.tmp"
            [System.IO.File]::WriteAllText($tmp, $Content, (New-Object System.Text.UTF8Encoding $true))
            Move-Item -LiteralPath $tmp -Destination $Path -Force -ErrorAction Stop
            return
        } catch {
            Remove-Item -LiteralPath "$Path.tmp" -Force -ErrorAction SilentlyContinue
            if ($i -lt 4) { Start-Sleep -Milliseconds (80 * ($i + 1)) }
        }
    }
}
# 修 19: 心跳文件 读-改-写 整体原子化(独占锁 FileShare.None + 重试)。
#        修 16 只原子化了"写", 并发注册时 读-改-写 仍有竞态 → 后写者覆盖先写者 → 丢 PID。
#        Mutator 接收现有 PID 数组, 返回新数组; 返回 $null = 无变化; 返回空数组 = 标记清空(调用方删文件)
function Update-PidFile {
    param([string]$PidFile, [scriptblock]$Mutator)
    for ($i = 0; $i -lt 5; $i++) {
        try {
            $fs = [System.IO.File]::Open($PidFile, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            try {
                $reader = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
                $content = $reader.ReadToEnd()
                $lines = @($content -split "`r?`n" | Where-Object { $_ -match '^\d+$' })
                $result = & $Mutator $lines
                if ($null -eq $result) { return }   # 无变化(或由 Mutator 标记 $script:pidFileEmpty)
                $fs.SetLength(0); $fs.Position = 0
                $bytes = [System.Text.Encoding]::UTF8.GetBytes(($result -join "`n"))
                $fs.Write($bytes, 0, $bytes.Length)
                $fs.Flush()
            } finally { $fs.Close() }
            return
        } catch {
            if ($i -lt 4) { Start-Sleep -Milliseconds (80 * ($i + 1)) }
        }
    }
}
function Register-Heartbeat {
    param([string]$PidFile)
    Update-PidFile -PidFile $PidFile -Mutator {
        param($lines)
        if ($lines -contains "$PID") { return $null }
        $lines + "$PID"
    }
}
function Unregister-Heartbeat {
    param([string]$PidFile)
    if (-not (Test-Path -LiteralPath $PidFile)) { return }
    $script:pidFileEmpty = $false
    Update-PidFile -PidFile $PidFile -Mutator {
        param($lines)
        $remaining = @($lines | Where-Object { $_ -ne "$PID" -and (Get-Process -Id $_ -ErrorAction SilentlyContinue) })
        if ($remaining.Count -eq $lines.Count) { return $null }   # 无变化
        if ($remaining.Count -eq 0) { $script:pidFileEmpty = $true; return $null }  # 全部清空 → 删文件
        $remaining
    }
    if ($script:pidFileEmpty) { Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue }
}
function Update-SessionStateOnClose {
    param([string]$DataDir, [string]$StateFile, [string]$PidFile)
    $others = 0
    if (Test-Path -LiteralPath $PidFile) {
        $others = @(Get-Content -LiteralPath $PidFile -Encoding UTF8 -ErrorAction SilentlyContinue |
            Where-Object { $_ -ne "$PID" -and (Get-Process -Id $_ -ErrorAction SilentlyContinue) }).Count
    }
    $state = if ($others -gt 0) { 'running' } else { 'closed' }
    Write-TextFile -Path $StateFile -Content $state
}

# ---------- WPF 工具函数 ----------
# 修 18: 无边框窗口 MainWindowHandle=0, CloseMainWindow 无效; 改用 EnumWindows + PostMessage WM_CLOSE
if (-not ('NoteWin32' -as [type])) {
    Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class NoteWin32 {
    public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
    [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr hWnd, StringBuilder sb, int max);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
}
'@
}
function Close-NoteWindowByPid {
    param([int]$TargetPid)
    if ($TargetPid -le 0) { return }
    $script:foundHwnd = [IntPtr]::Zero
    $cb = [NoteWin32+EnumProc]{
        param($hwnd, $l)
        $p = 0
        [NoteWin32]::GetWindowThreadProcessId($hwnd, [ref]$p) | Out-Null
        if ($p -eq $TargetPid) {
            $sb = New-Object System.Text.StringBuilder 256
            [NoteWin32]::GetWindowText($hwnd, $sb, 256) | Out-Null
            if ($sb.ToString() -match '便签') { $script:foundHwnd = $hwnd; return $false }
        }
        return $true
    }
    [NoteWin32]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
    if ($script:foundHwnd -ne [IntPtr]::Zero) {
        [NoteWin32]::PostMessage($script:foundHwnd, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null  # WM_CLOSE
    }
}

function Set-NoteColor {
    param([System.Windows.Window]$Win, [string]$Name)
    if (-not $script:colors.Contains($Name)) { return }
    $c = $script:colors[$Name]
    $script:noteColor = $Name
    $br = $Win.FindName('Border')
    $tb = $Win.FindName('TitleBar')
    if ($br) {
        $br.Background  = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($c.bg))
        $br.BorderBrush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($c.border))
    }
    if ($tb) {
        $tb.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($c.title))
    }
}
function Update-TitleText {  # 修 15
    param([System.Windows.Window]$Win, [string]$NotePath)
    $tt = $Win.FindName('TitleText')
    if ($tt) {
        $name = [System.IO.Path]::GetFileNameWithoutExtension($NotePath) -replace '^note_', ''
        $tt.Text = "便签 $name"
    }
}
# ---------- 富文本 ⇄ 纯文本标记 双向转换 (v1.6 删除线) ----------
# 纯文本中 ~~文字~~ = 删除线, 其余为普通文本, 换行 = 段落分隔
# 设计: 保持 .txt 纯文本可读/历史窗口兼容/旧便签零迁移
function Get-NotePlainText {
    param([System.Windows.Controls.RichTextBox]$Box)
    $tr = New-Object System.Windows.Documents.TextRange($Box.Document.ContentStart, $Box.Document.ContentEnd)
    return $tr.Text
}
function Get-NoteMarkedText {
    param([System.Windows.Controls.RichTextBox]$Box)
    $lines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($block in $Box.Document.Blocks) {
        if ($block -is [System.Windows.Documents.Paragraph]) {
            $paraText = ''
            foreach ($inline in $block.Inlines) {
                if ($inline -is [System.Windows.Documents.Run]) {
                    $t = $inline.Text
                    $hasStrike = $false
                    if ($null -ne $inline.TextDecorations) {
                        foreach ($d in $inline.TextDecorations) {
                            if ($d.Location -eq [System.Windows.TextDecorationLocation]::Strikethrough) { $hasStrike = $true; break }
                        }
                    }
                    $paraText += if ($hasStrike -and $t.Length -gt 0) { '~~' + $t + '~~' } else { $t }
                }
                elseif ($inline -is [System.Windows.Documents.LineBreak]) { $paraText += "`n" }
            }
            $lines.Add($paraText)
        }
    }
    return ($lines -join "`n")
}
function Set-NoteMarkedText {
    param([System.Windows.Controls.RichTextBox]$Box, [string]$Text)
    $doc = $Box.Document
    $doc.Blocks.Clear()
    $Text = $Text -replace "`r`n", "`n" -replace "`r", "`n"
    $segments = @($Text -split "`n")
    $para = New-Object System.Windows.Documents.Paragraph
    $doc.Blocks.Add($para)
    for ($i = 0; $i -lt $segments.Count; $i++) {
        $seg = $segments[$i]
        $ms = [regex]::Matches($seg, '~~(.*?)~~')
        $pos = 0
        foreach ($m in $ms) {
            if ($m.Index -gt $pos) {
                $run = New-Object System.Windows.Documents.Run ($seg.Substring($pos, $m.Index - $pos))
                $para.Inlines.Add($run) | Out-Null
            }
            $runS = New-Object System.Windows.Documents.Run $m.Groups[1].Value
            $runS.TextDecorations = [System.Windows.TextDecorations]::Strikethrough
            $para.Inlines.Add($runS) | Out-Null
            $pos = $m.Index + $m.Length
        }
        if ($pos -lt $seg.Length) {
            $run = New-Object System.Windows.Documents.Run ($seg.Substring($pos))
            $para.Inlines.Add($run) | Out-Null
        }
        if ($i -lt $segments.Count - 1) {
            $para = New-Object System.Windows.Documents.Paragraph
            $doc.Blocks.Add($para)
        }
    }
}
function Save-Note {
    param(
        [System.Windows.Controls.RichTextBox]$NoteBox,
        [System.Windows.Window]$Win,
        [string]$NotePath,
        [string]$PosPath
    )
    # 修 17: 目录保障 + 容错(数据目录被外部删除/不可写时, 保存静默失败不炸掉关闭流程)
    # 修 22(workbuddy B1/O1): 失败时不再静默, 标题提示「保存失败!」并记录错误
    try {
        $dir = Split-Path -Parent $NotePath
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Write-TextFile -Path $NotePath -Content (Get-NoteMarkedText -Box $NoteBox)
        if (-not [double]::IsNaN($Win.Left)) {
            # 修 13: 加 WindowState 字段 (格式: Left|Top|Width|Height|Topmost|Color|WindowState)
            # 修 22(workbuddy B4): pos 也走原子写
            $state = "$($Win.Left)|$($Win.Top)|$($Win.Width)|$($Win.Height)|$($Win.Topmost)|$script:noteColor|$($Win.WindowState)"
            Write-TextFile -Path $PosPath -Content $state
        }
        $script:saveLastError = $null
    } catch {
        $script:saveLastError = $_.Exception.Message
        try {
            $tt = $window.FindName('TitleText')
            if ($tt) { $tt.Text = '保存失败!'; $tt.Foreground = [System.Windows.Media.Brushes]::Red }
        } catch {}
    }
}

# ============================================================
#  ShowHistory 模式
# ============================================================
if ($ShowHistory) {
    $hxaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" Width="460" Height="540"
        Title="便签历史" ResizeMode="NoResize" WindowStartupLocation="CenterScreen">
  <Border CornerRadius="4" Background="#FFFFE0" BorderBrush="#D0C080" BorderThickness="1">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>
      <Border Grid.Row="0" Background="#FFE9C4" Height="26" CornerRadius="4,4,0,0">
        <Grid>
          <TextBlock Text="便签历史" Foreground="#8A6D2B" FontSize="12" FontFamily="Microsoft YaHei" FontWeight="Bold" Margin="8,0,0,0" VerticalAlignment="Center"/>
          <Button x:Name="CloseBtn" Content="✕" Width="20" Height="18" HorizontalAlignment="Right" Margin="0,4,6,0" Background="Transparent" BorderThickness="0" Foreground="#8A6D2B" FontSize="10" Cursor="Hand"/>
        </Grid>
      </Border>
      <Grid Grid.Row="1" Margin="8">
        <ListBox x:Name="HistoryList" BorderThickness="0" Background="Transparent" ScrollViewer.VerticalScrollBarVisibility="Auto" ScrollViewer.HorizontalScrollBarVisibility="Disabled" HorizontalContentAlignment="Stretch">
          <ListBox.ItemTemplate>
            <DataTemplate>
              <StackPanel Margin="2,4">
                <TextBlock Text="{Binding Time}" FontWeight="Bold" FontSize="12" Foreground="#8A6D2B"/>
                <TextBlock Text="{Binding Preview}" FontSize="12" Foreground="#444444" TextWrapping="Wrap" Margin="0,3,0,0"/>
              </StackPanel>
            </DataTemplate>
          </ListBox.ItemTemplate>
        </ListBox>
        <TextBlock x:Name="EmptyHint" Text="暂无有文字的便签" Foreground="#999999" FontSize="13" HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed"/>
      </Grid>
      <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,0,10,10">
        <TextBlock Text="双击条目打开便签" Foreground="#999999" FontSize="11" VerticalAlignment="Center" Margin="0,0,12,0"/>
        <Button x:Name="RefreshBtn" Content="刷新" Width="54" Height="24" Margin="0,0,6,0"/>
        <Button x:Name="OpenDirBtn" Content="数据文件夹" Width="82" Height="24" Margin="0,0,6,0"/>
        <Button x:Name="CloseWinBtn" Content="关闭" Width="54" Height="24"/>
      </StackPanel>
    </Grid>
  </Border>
</Window>
'@
    $hReader = New-Object System.Xml.XmlTextReader (New-Object System.IO.StringReader $hxaml)
    $hWin = [System.Windows.Markup.XamlReader]::Load($hReader)
    $hList = $hWin.FindName('HistoryList')
    $hEmpty = $hWin.FindName('EmptyHint')

    function Update-HistoryList {
        $hList.Items.Clear()
        $count = 0
        $files = Get-ChildItem -Path $dataDir -Filter '*.txt' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne 'session-state.txt' } |
            Sort-Object LastWriteTime -Descending
        foreach ($f in $files) {
            $c = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            if ($null -eq $c -or $c.Trim().Length -eq 0) { continue }
            $count++
            $ts = $f.BaseName -replace '^note_', ''
            $timeStr = $ts
            if ($ts -match '^(\d{8})_(\d{6})(_\d+)?$') {
                try { $timeStr = ([datetime]::ParseExact($matches[1] + $matches[2], 'yyyyMMddHHmmss', [System.Globalization.CultureInfo]::InvariantCulture)).ToString('yyyy-MM-dd HH:mm') } catch {}
            } else {
                $timeStr = $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm')   # 重命名过的便签用修改时间
            }
            $preview = $c.Trim()
            if ($preview.Length -gt 300) { $preview = $preview.Substring(0, 300) + ' …' }
            $hList.Items.Add([pscustomobject]@{ Time = $timeStr; Preview = $preview; Path = $f.FullName }) | Out-Null
        }
        $hEmpty.Visibility = if ($count -eq 0) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
    }

    $hList.Add_MouseDoubleClick({
        $sel = $hList.SelectedItem
        if ($sel -and $sel.Path) {
            # 修 5: 数组传参, 避免手搓引号拼接
            Start-Process powershell -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File', $scriptPath, '-NoteFile', $sel.Path)
        }
    })
    $hWin.FindName('RefreshBtn').Add_Click({ Update-HistoryList })
    $hWin.FindName('OpenDirBtn').Add_Click({ explorer.exe $dataDir })
    $hWin.FindName('CloseWinBtn').Add_Click({ $hWin.Close() })
    $hWin.FindName('CloseBtn').Add_Click({ $hWin.Close() })

    Update-HistoryList
    $hWin.ShowDialog() | Out-Null
    exit 0
}

# ============================================================
#  RestoreAll 模式(开机自启) —— 已取消(2026-08-12 公子要求)
#  保留参数兼容旧启动项调用, 但不再恢复任何便签
# ============================================================
if ($RestoreAll) {
    exit 0
}

# ============================================================
#  普通便签模式
# ============================================================

# 修 3: 同秒撞名加随机后缀
if ($NoteFile -eq '') {
    $baseName = 'note_' + (Get-Date -Format 'yyyyMMdd_HHmmss')
    $NoteFile = Join-Path $dataDir "$baseName.txt"
    $counter = 1
    while (Test-Path -LiteralPath $NoteFile) {
        $NoteFile = Join-Path $dataDir "${baseName}_${counter}.txt"
        $counter++
        if ($counter -gt 99) { break }
    }
}
$posFile = [System.IO.Path]::ChangeExtension($NoteFile, '.pos')
$script:notePath = $NoteFile
$script:posPath = $posFile

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" Width="260" Height="240"
        Title="便签" WindowStartupLocation="Manual"
        ResizeMode="CanResizeWithGrip" MinWidth="150" MinHeight="120">
  <Border x:Name="Border" CornerRadius="4" Background="#FFFFE0"
          BorderBrush="#D0C080" BorderThickness="1">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
      </Grid.RowDefinitions>
      <Border x:Name="TitleBar" Grid.Row="0" Background="#FFE9C4" Height="24" CornerRadius="4,4,0,0">
        <Grid>
          <TextBlock x:Name="TitleText" Text="便签" Foreground="#8A6D2B" FontSize="11"
                     FontFamily="Microsoft YaHei" Margin="8,0,0,0" VerticalAlignment="Center"/>
          <TextBox x:Name="TitleEdit" Visibility="Collapsed" Margin="4,2,26,2"
                   Background="White" BorderBrush="#D0C080" BorderThickness="1"
                   FontFamily="Microsoft YaHei" FontSize="11" VerticalContentAlignment="Center"
                   Padding="2,0"/>
          <Button x:Name="CloseBtn" Content="✕" Width="20" Height="18" HorizontalAlignment="Right"
                  Margin="0,3,6,0" Background="Transparent" BorderThickness="0"
                  Foreground="#8A6D2B" FontSize="10" Cursor="Hand"/>
        </Grid>
      </Border>
      <RichTextBox x:Name="NoteBox" Grid.Row="1" Background="Transparent" BorderThickness="0"
               FontFamily="Microsoft YaHei" FontSize="13"
               AcceptsReturn="True" VerticalScrollBarVisibility="Auto" Padding="8,6"
               CaretBrush="Black" Foreground="#333333" SelectionBrush="#FFF3B0"/>
    </Grid>
  </Border>
</Window>
'@

$xmlReader = New-Object System.Xml.XmlTextReader (New-Object System.IO.StringReader $xaml)
$window = [System.Windows.Markup.XamlReader]::Load($xmlReader)

$noteBox  = $window.FindName('NoteBox')
$titleBar = $window.FindName('TitleBar')
$closeBtn = $window.FindName('CloseBtn')

# ---------- 心跳注册 ----------
Register-Heartbeat -PidFile $pidFile

# ---------- 加载已有内容(若有, v1.6: 纯文本+~~标记~~ 解析进富文本) ----------
if (Test-Path -LiteralPath $NoteFile) {
    $c = Get-Content -LiteralPath $NoteFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    if ($null -ne $c) { Set-NoteMarkedText -Box $noteBox -Text $c }
}
# 启动即保存一次, 确保文件生成
Save-Note -NoteBox $noteBox -Win $window -NotePath $NoteFile -PosPath $posFile

# ---------- 加载位置 ----------
# 修 4: 新建便签基于上一张位置偏移
# 修 11: Get-Content $posFile 加 -Raw
# 修 13: 恢复 WindowState
$isNewNote = -not (Test-Path -LiteralPath $posFile)
if ($isNewNote) {
    $lastPos = $null
    $posFiles = @(Get-ChildItem -Path $dataDir -Filter '*.pos' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -ne $posFile } |
        Sort-Object LastWriteTime -Descending)
    foreach ($pf in $posFiles) {
        $c = Get-Content -LiteralPath $pf.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if (-not $c) { continue }
        $arr = $c.Split('|')
        if ($arr.Count -ge 4) {
            try {
                $l = [double]$arr[0]; $t = [double]$arr[1]
                if ($l -ge 0 -and $t -ge 0 -and $l -lt [System.Windows.SystemParameters]::VirtualScreenWidth) {
                    $lastPos = @{ Left = $l + 24; Top = $t + 24 }
                    break
                }
            } catch {}
        }
    }
    if ($lastPos) { $window.Left = $lastPos.Left; $window.Top = $lastPos.Top }
    else { $window.Left = 100; $window.Top = 100 }
} elseif (Test-Path -LiteralPath $posFile) {
    $s = (Get-Content -LiteralPath $posFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue).Split('|')
    if ($s.Count -ge 5) {
        try {
            $window.Left   = [double]$s[0]; $window.Top    = [double]$s[1]
            $window.Width  = [double]$s[2]; $window.Height = [double]$s[3]
            $window.Topmost = [bool]::Parse($s[4])
            if ($s.Count -ge 6 -and $s[5] -ne '') { Set-NoteColor -Win $window -Name $s[5] }
            if ($s.Count -ge 7 -and $s[6] -ne '') {
                $ws = [System.Windows.WindowState]::Normal
                [Enum]::TryParse([System.Windows.WindowState], $s[6], [ref]$ws) | Out-Null
                $window.WindowState = $ws
            }
        } catch {}
    }
}
# 防止跑出屏幕
if ($window.Left -lt 0 -or $window.Top -lt 0 -or $window.Left -gt [System.Windows.SystemParameters]::VirtualScreenWidth) {
    $window.Left = 100; $window.Top = 100
}

# ---------- 窗口 Loaded 事件: 保存真实位置 + 自动聚焦 + 同步颜色勾选 ----------
$window.Add_Loaded({
    Save-Note -NoteBox $noteBox -Win $window -NotePath $script:notePath -PosPath $script:posPath
    $noteBox.Focus() | Out-Null
    [System.Windows.Input.Keyboard]::Focus($noteBox) | Out-Null
    # 修 22(workbuddy B3): stateFile 走原子写, 与 Update-SessionStateOnClose 一致
    Write-TextFile -Path $stateFile -Content 'running'
    $mc = $window.ContextMenu
    foreach ($top in $mc.Items) {
        if ($top.Header -eq '颜色') {
            foreach ($item in $top.Items) { $item.IsChecked = ($item.Header -eq $script:noteColor) }
        }
    }
})

# ---------- 拖动 ----------
$titleBar.Add_MouseLeftButtonDown({
    if ($_.ButtonState -eq 'Pressed') { $window.DragMove() }
})

# ---------- 标题点击重命名 + Ctrl+S 保存(修 21) ----------
$titleEdit = $window.FindName('TitleEdit')
$titleText = $window.FindName('TitleText')

function Get-NoteBaseName {
    ([System.IO.Path]::GetFileNameWithoutExtension($script:notePath)) -replace '^note_', ''
}
function Rename-NoteTo {
    param([string]$NewName)
    if ($NewName -match '[\\/:*?"<>|]') { return $false }
    $newTxt = Join-Path $dataDir ($NewName + '.txt')
    if (Test-Path -LiteralPath $newTxt) { return $false }   # 重名冲突
    if (-not (Test-Path -LiteralPath $script:notePath)) { return $false }
    try {
        Rename-Item -LiteralPath $script:notePath -NewName ($NewName + '.txt') -ErrorAction Stop
        $oldPos = $script:posPath
        $script:notePath = $newTxt
        $script:posPath = [System.IO.Path]::ChangeExtension($newTxt, '.pos')
        if (Test-Path -LiteralPath $oldPos) { Rename-Item -LiteralPath $oldPos -NewName ($NewName + '.pos') -ErrorAction SilentlyContinue }
        return $true
    } catch { return $false }
}
function Start-TitleEdit {
    $titleEdit.Text = Get-NoteBaseName
    $titleEdit.Visibility = 'Visible'
    $titleText.Visibility = 'Collapsed'
    $titleEdit.Focus() | Out-Null
    $titleEdit.SelectAll()
}
function Apply-TitleEdit {
    $newName = $titleEdit.Text.Trim()
    $titleEdit.Visibility = 'Collapsed'
    $titleText.Visibility = 'Visible'
    if ($newName -ne '' -and $newName -ne (Get-NoteBaseName)) {
        if (Rename-NoteTo -NewName $newName) { Update-TitleText -Win $window -NotePath $script:notePath }
    }
}
function Cancel-TitleEdit {
    $titleEdit.Visibility = 'Collapsed'
    $titleText.Visibility = 'Visible'
}
function Show-SavedFeedback {
    $tt = $window.FindName('TitleText')
    if ($tt) {
        $tt.Text = '已保存 ✓'
        $tt.Foreground = [System.Windows.Media.Brushes]::DarkGoldenrod
        # 修 22(workbuddy B8): 复用 script 级 timer, 连按时先 Stop 旧的, 避免旧 timer 用旧路径回写标题
        if ($script:feedbackTimer) { $script:feedbackTimer.Stop() }
        $script:feedbackTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:feedbackTimer.Interval = [TimeSpan]::FromMilliseconds(1200)
        $script:feedbackTimer.Add_Tick({
            $script:feedbackTimer.Stop()
            Update-TitleText -Win $window -NotePath $script:notePath
            $tt2 = $window.FindName('TitleText')
            if ($tt2) { $tt2.Foreground = [System.Windows.Media.Brushes]::DarkGoldenrod }
        })
        $script:feedbackTimer.Start()
    }
}

# 点击标题 → 编辑重命名(Handled 阻止冒泡触发窗口拖动)
$titleText.Add_MouseLeftButtonDown({ $_.Handled = $true; Start-TitleEdit })
$titleEdit.Add_KeyDown({
    if ($_.Key -eq 'Return') { $_.Handled = $true; Apply-TitleEdit }
    elseif ($_.Key -eq 'Escape') { $_.Handled = $true; Cancel-TitleEdit }
})
$titleEdit.Add_LostFocus({ Apply-TitleEdit })

# Ctrl+S 保存 / Ctrl+N 新建 / Ctrl+W 关闭 / Ctrl+H 历史 (修 22, workbuddy O9)
$noteBox.Add_KeyDown({
    if ($_.Key -eq 'S' -and $_.KeyboardDevice.Modifiers -eq 'Control') {
        $_.Handled = $true
        Save-Note -NoteBox $noteBox -Win $window -NotePath $script:notePath -PosPath $script:posPath
        Show-SavedFeedback
    }
})
$window.Add_PreviewKeyDown({
    if ($titleEdit.Visibility -eq 'Visible') { return }   # 标题编辑中禁用全局快捷键
    $mod = $_.KeyboardDevice.Modifiers
    if ($mod -eq 'Control') {
        if ($_.Key -eq 'N') {
            $_.Handled = $true
            Save-Note -NoteBox $noteBox -Win $window -NotePath $script:notePath -PosPath $script:posPath
            Start-Process powershell -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File', $scriptPath)
        }
        elseif ($_.Key -eq 'W') { $_.Handled = $true; $window.Close() }
        elseif ($_.Key -eq 'H') {
            $_.Handled = $true
            Start-Process powershell -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File', $scriptPath, '-ShowHistory')
        }
    }
})

# ---------- 关闭按钮 ----------
$closeBtn.Add_Click({ $window.Close() })

# ---------- 右键菜单 ----------
$menu = New-Object System.Windows.Controls.ContextMenu
$mNew       = New-Object System.Windows.Controls.MenuItem; $mNew.Header       = '新建便签'
$mSave      = New-Object System.Windows.Controls.MenuItem; $mSave.Header      = '保存'
$mStrike    = New-Object System.Windows.Controls.MenuItem; $mStrike.Header    = '删除线'   # v1.6
$mTop       = New-Object System.Windows.Controls.MenuItem; $mTop.Header       = '置顶显示'; $mTop.IsCheckable = $true; $mTop.IsChecked = $true
$mColor     = New-Object System.Windows.Controls.MenuItem; $mColor.Header     = '颜色'
$mHistory   = New-Object System.Windows.Controls.MenuItem; $mHistory.Header   = '查看历史'
$mOpen      = New-Object System.Windows.Controls.MenuItem; $mOpen.Header      = '打开数据文件夹'
$mClose     = New-Object System.Windows.Controls.MenuItem; $mClose.Header     = '关闭便签'
$mCloseAll  = New-Object System.Windows.Controls.MenuItem; $mCloseAll.Header  = '全部关闭'   # 修 14
$menu.Items.Add($mNew)      | Out-Null
$menu.Items.Add($mSave)     | Out-Null
$menu.Items.Add($mStrike)   | Out-Null
$menu.Items.Add($mTop)      | Out-Null
$menu.Items.Add($mColor)    | Out-Null
$menu.Items.Add($mHistory)  | Out-Null
$menu.Items.Add($mOpen)     | Out-Null
$menu.Items.Add($mClose)    | Out-Null
$menu.Items.Add($mCloseAll) | Out-Null

# 修 10: 颜色子菜单用 $script:colors.Keys 遍历, 不再硬编码 6 个
foreach ($cn in $script:colors.Keys) {
    $mi = New-Object System.Windows.Controls.MenuItem
    $mi.Header = $cn
    $mi.IsCheckable = $true
    $sb = {
        param($s, $e)
        $cnLocal = $s.Header
        Set-NoteColor -Win $window -Name $cnLocal
        Save-Note -NoteBox $noteBox -Win $window -NotePath $script:notePath -PosPath $script:posPath
        foreach ($it in $mColor.Items) { $it.IsChecked = ($it.Header -eq $cnLocal) }
    }
    $mi.Add_Click($sb)
    $mColor.Items.Add($mi) | Out-Null
}

$mNew.Add_Click({
    Save-Note -NoteBox $noteBox -Win $window -NotePath $script:notePath -PosPath $script:posPath
    Start-Process powershell -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File', $scriptPath)
})
$mSave.Add_Click({
    Save-Note -NoteBox $noteBox -Win $window -NotePath $script:notePath -PosPath $script:posPath
    Show-SavedFeedback
})
# v1.6: 删除线 —— 选中文字 toggle; 无选中则全文 toggle
$mStrike.Add_Click({
    $sel = $noteBox.Selection
    $target = if ($sel.IsEmpty) {
        New-Object System.Windows.Documents.TextRange($noteBox.Document.ContentStart, $noteBox.Document.ContentEnd)
    } else { $sel }
    $hasStrike = $false
    $propVal = $target.GetPropertyValue([System.Windows.Documents.Run]::TextDecorationsProperty)
    if ($propVal -is [System.Windows.TextDecorationCollection]) {
        foreach ($d in $propVal) {
            if ($d.Location -eq [System.Windows.TextDecorationLocation]::Strikethrough) { $hasStrike = $true; break }
        }
    }
    if ($hasStrike) {
        $target.ApplyPropertyValue([System.Windows.Documents.Run]::TextDecorationsProperty, $null)
    } else {
        $target.ApplyPropertyValue([System.Windows.Documents.Run]::TextDecorationsProperty, [System.Windows.TextDecorations]::Strikethrough)
    }
    Save-Note -NoteBox $noteBox -Win $window -NotePath $script:notePath -PosPath $script:posPath
})
$mTop.Add_Click({ $window.Topmost = $mTop.IsChecked })
$mHistory.Add_Click({
    Start-Process powershell -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File', $scriptPath, '-ShowHistory')
})
$mOpen.Add_Click({ explorer.exe $dataDir })
$mClose.Add_Click({ $window.Close() })
$mCloseAll.Add_Click({                                     # 修 14, 修 18: CloseMainWindow 对无边框窗口无效, 改 WM_CLOSE
    if (Test-Path -LiteralPath $pidFile) {
        Get-Content -LiteralPath $pidFile -Encoding UTF8 -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_ -match '^\d+$' -and [int]$_ -ne $PID) {
                Close-NoteWindowByPid -TargetPid ([int]$_)
            }
        }
    }
    Start-Sleep -Milliseconds 500
    $window.Close()
})

$window.ContextMenu = $menu
# v1.6: NoteBox 显式绑定同一菜单, 覆盖 RichTextBox 自带编辑菜单(剪切/复制/粘贴)
#       否则选中文字后右键/Shift+F10 打开的是系统编辑菜单, 删除线无处安放
$noteBox.ContextMenu = $menu

# ---------- 输入防抖(1.5s) + 兜底(30s) ----------
$debounce = New-Object System.Windows.Threading.DispatcherTimer
$debounce.Interval = [TimeSpan]::FromMilliseconds(1500)
$debounce.Add_Tick({ $debounce.Stop(); Save-Note -NoteBox $noteBox -Win $window -NotePath $script:notePath -PosPath $script:posPath })
$noteBox.Add_TextChanged({ $debounce.Stop(); $debounce.Start() })

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(30)
$timer.Add_Tick({ Save-Note -NoteBox $noteBox -Win $window -NotePath $script:notePath -PosPath $script:posPath })
$timer.Start()

# ---------- 关闭事件: 保存 + 更新会话状态 + 空便签回收站删除 ----------
$window.Add_Closing({
    Save-Note -NoteBox $noteBox -Win $window -NotePath $script:notePath -PosPath $script:posPath
    if ((Get-NotePlainText -Box $noteBox).Trim().Length -eq 0) {
        if (Test-Path -LiteralPath $script:notePath) {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($script:notePath, 'OnlyErrorDialogs', 'SendToRecycleBin')
        }
        if (Test-Path -LiteralPath $script:posPath) {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($script:posPath, 'OnlyErrorDialogs', 'SendToRecycleBin')
        }
    }
    Unregister-Heartbeat -PidFile $pidFile
    Update-SessionStateOnClose -DataDir $dataDir -StateFile $stateFile -PidFile $pidFile
})

# ---------- 标题(修 15) ----------
Update-TitleText -Win $window -NotePath $script:notePath

$window.ShowDialog() | Out-Null
