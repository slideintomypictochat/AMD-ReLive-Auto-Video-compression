# ReLive Compressor - main window (WPF). Dot-sourced by ReLiveCompressor.ps1; uses its state and functions.

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, WindowsFormsIntegration
Add-Type @'
public class RlcGame {
    public string Name { get; set; }  public string Path { get; set; }  public string Initial { get; set; }
    public int Clips { get; set; }     public string Size { get; set; }  public string Done { get; set; }
    public double DonePct { get; set; } public object Thumb { get; set; }
}
public class RlcRow {
    public string Time { get; set; }   public string Game { get; set; }  public string File { get; set; }
    public string Before { get; set; } public string After { get; set; } public string Saved { get; set; }
    public string Result { get; set; } public string Note { get; set; }
    public string Path { get; set; }   public string Tip { get; set; }
    public string ResultText { get; set; } public string Problem { get; set; } public bool HasProblem { get; set; }
    public string FixText { get; set; }    public string FixTag { get; set; }  public bool HasFix { get; set; }
    public string CompareTag { get; set; } public bool HasCompare { get; set; }
}

// Compress page: one recording with a check box
public class RlcClip : System.ComponentModel.INotifyPropertyChanged {
    public event System.ComponentModel.PropertyChangedEventHandler PropertyChanged;
    bool isChecked;
    public bool IsChecked { get { return isChecked; } set { if (isChecked == value) return; isChecked = value; Notify("IsChecked"); if (Owner != null) Owner.ChildChanged(); } }
    public RlcGroup Owner;
    public string Path { get; set; }     public string Name { get; set; }     public string Recorded { get; set; }
    public string Size { get; set; }     public double Bytes { get; set; }    public bool CanSelect { get; set; }
    public string Status { get; set; }   public string StatusTip { get; set; }
    public string ChipBg { get; set; }   public string ChipFg { get; set; }   public string NameColor { get; set; }
    public string PlayTag { get { return "play:" + Path; } }
    void Notify(string n) { var h = PropertyChanged; if (h != null) h(this, new System.ComponentModel.PropertyChangedEventArgs(n)); }
}

// Compress page: one game folder; its check box is checked / empty / partly checked from its clips
public class RlcGroup : System.ComponentModel.INotifyPropertyChanged {
    public event System.ComponentModel.PropertyChangedEventHandler PropertyChanged;
    public System.Collections.Generic.List<RlcClip> Clips { get; set; }
    public string Name { get; set; }  public string Path { get; set; }  public string Initial { get; set; }
    public string Counts { get; set; } public object Thumb { get; set; }
    public string FolderTag { get { return "folder:" + Path; } }
    public bool HasSelectable { get { foreach (var c in Clips) if (c.CanSelect) return true; return false; } }
    bool expanded, syncing;
    public bool IsExpanded { get { return expanded; } set { expanded = value; Notify("IsExpanded"); } }
    public bool? IsChecked {
        get {
            int on = 0, all = 0;
            foreach (var c in Clips) if (c.CanSelect) { all++; if (c.IsChecked) on++; }
            if (on == 0) return false;
            if (on == all) return true;
            return null;
        }
        set {
            // clicking cycles empty -> checked -> (partly) -> empty; "partly" from a click means "clear"
            bool v = value == true;
            syncing = true;
            foreach (var c in Clips) if (c.CanSelect) c.IsChecked = v;
            syncing = false;
            Notify("IsChecked");
        }
    }
    public void ChildChanged() { if (!syncing) Notify("IsChecked"); }
    void Notify(string n) { var h = PropertyChanged; if (h != null) h(this, new System.ComponentModel.PropertyChangedEventArgs(n)); }
}
'@

$script:Win = $null
$script:W = @{}            # named elements
$script:Loading = $false   # true while settings controls are being filled (suppresses change handlers)
$script:Page = 'Home'
$script:LastHeavyRefresh = [DateTime]::MinValue
$script:ThumbCache = @{}
$script:CmpGroups = $null    # Compress page: RlcGroup list currently shown
$script:CmpLastFile = $null  # file being compressed when the Compress page was last rebuilt
$script:AddedFiles = @()     # videos added from outside the recordings folder (right-click / drag and drop)
$script:SaveRatio = 0.45     # average compressed / original size, from the log
$script:UpdateDismissed = $null
$script:ManualCheck = $false
$IdleChoices = 5, 10, 15, 20, 30, 45, 60
$ModeNames   = 'Test', 'Replace', 'Move'
$PresetNames = 'speed', 'balanced', 'quality'
$script:Gpu = (Get-CimInstance Win32_VideoController | Sort-Object { $_.Name -notmatch ' RX ' } | Select-Object -First 1).Name

# ---------- data helpers ----------
function Format-Size([double]$bytes) {
    if ($bytes -ge 1GB) { '{0:N1} GB' -f ($bytes / 1GB) } else { '{0:N0} MB' -f ($bytes / 1MB) }
}

function Format-Count([int]$n, [string]$word) { if ($n -eq 1) { "1 $word" } else { "$n ${word}s" } }

function Get-ThumbPath([string]$dir) {
    $base = $script:Settings.RecordingsFolder.TrimEnd('\')
    $rel = if ($dir.Length -gt $base.Length) { $dir.Substring($base.Length + 1) } else { '_root' }
    Join-Path $AppDir ('thumbs\' + ($rel -replace '[\\/:*?"<>|]', '_') + '.jpg')
}

function Get-Thumb([string]$dir) {
    $p = Get-ThumbPath $dir
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    $stamp = (Get-Item -LiteralPath $p).LastWriteTimeUtc.Ticks
    $c = $script:ThumbCache[$p]
    if ($c -and $c.Stamp -eq $stamp) { return $c.Image }
    $bmp = New-Object Windows.Media.Imaging.BitmapImage
    $bmp.BeginInit()
    $bmp.CacheOption = 'OnLoad'          # don't keep the file locked
    $bmp.DecodePixelWidth = 400
    $bmp.UriSource = New-Object Uri $p
    $bmp.EndInit(); $bmp.Freeze()
    $script:ThumbCache[$p] = @{ Stamp = $stamp; Image = $bmp }
    $bmp
}

function Get-GameName([string]$dir) {
    if ($dir.TrimEnd('\') -eq $script:Settings.RecordingsFolder.TrimEnd('\')) { 'Other recordings' } else { Split-Path $dir -Leaf }
}

# every recording the worker has seen: path, size, codec
function Get-Clips {
    $cachePath = Join-Path $AppDir 'scan-cache.json'
    if (-not (Test-Path $cachePath)) { return @() }
    try { $c = Get-Content $cachePath -Raw | ConvertFrom-Json } catch { return @() }
    foreach ($p in $c.PSObject.Properties) {
        [pscustomobject]@{
            Path  = $p.Name
            Dir   = [IO.Path]::GetDirectoryName($p.Name)
            Size  = [double]($p.Value.Stamp -split '\|')[0]
            Codec = $p.Value.Codec
            Done  = if ($null -ne $p.Value.Done) { [bool]$p.Value.Done } else { $p.Value.Codec -eq 'av1' }
        }
    }
}

function Get-LogRows {
    $log = Join-Path $AppDir 'compress-log.csv'
    if (-not (Test-Path $log)) { return @() }
    try { @(Import-Csv $log) } catch { @() }
}

function ConvertTo-Row($r) {
    $row = New-Object RlcRow
    $row.Time = ([datetime]$r.Time).ToString('dd MMM HH:mm')
    $row.Game = Get-GameName ([IO.Path]::GetDirectoryName($r.File))
    $row.File = [IO.Path]::GetFileNameWithoutExtension($r.File)
    $row.Before = if ($r.OrigMB) { Format-Size ([double]$r.OrigMB * 1MB) } else { '' }
    $row.After = if ($r.NewMB) { Format-Size ([double]$r.NewMB * 1MB) } else { '' }
    $row.Saved = if ($r.SavedPct) { "-$([math]::Round([double]$r.SavedPct))%" } else { '' }
    $row.Result = $r.Result
    $row.Note = if ($r.Note) { $r.Note } else { $null }
    # what clicking the row plays: the test copy for test runs, otherwise the file at the original path
    $row.Path = $r.File
    $base = $script:Settings.RecordingsFolder.TrimEnd('\') + '\'
    if ($r.Result -eq 'TEST-OK' -and $r.File.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) {
        $row.Path = Join-Path $script:Settings.TestFolder $r.File.Substring($base.Length)
    }
    $row.Tip = if ($row.Note) { "$($row.Note)`n$($row.Path)" } else { $row.Path }
    $row.ResultText = switch ($r.Result) {
        'OK' { 'Compressed' } 'OK-MOVED' { 'Compressed, moved' } 'TEST-OK' { 'Test copy' }
        'FAILED' { 'Failed' } 'KEPT' { 'Kept as is' } 'SKIPPED' { 'Skipped' } default { $r.Result }
    }
    # plain-language explanation and a button that fixes it
    $reason = Get-RowReason $r
    if ($reason -and $ReasonText[$reason]) {
        $info = $ReasonText[$reason]
        $row.Problem = if ($reason -eq 'DISK_FULL' -and $r.Note -like 'Not enough free disk space on*') { "$($r.Note). Free up some space, or compress to another drive with Move mode." } else { $info.Text }
        $row.HasProblem = $true
        if ($info.Fix) { $row.FixText = $info.Fix; $row.FixTag = "fix:$reason|$($r.File)"; $row.HasFix = $true }
    }
    if ($r.Result -in 'OK', 'OK-MOVED', 'TEST-OK') {
        $row.HasCompare = $true; $row.CompareTag = "cmp:$($r.File)"
    }
    $row
}

# ---------- problems in plain language ----------
# Reason codes come from Worker.ps1 (Get-FailReason). Old logs have none, so they're worked out from the note.
$ReasonText = @{
    DISK_FULL       = @{ Text = 'Not enough free disk space to compress this video. Free up some space and it will be tried again.'; Fix = 'Open drive' }
    IN_USE          = @{ Text = 'The video was open in another program, or was still being recorded. It will be tried again automatically.' }
    ENCODER         = @{ Text = "The graphics driver couldn't start the video encoder. Updating the AMD graphics driver usually fixes this."; Fix = 'Get AMD driver' }
    DAMAGED         = @{ Text = 'This recording seems damaged (probably cut off when a game crashed), so it was left as it is.'; Fix = 'Play it' }
    MOVE_FOLDER     = @{ Text = "The 'Move originals to' folder isn't available (drive unplugged?). Nothing was changed."; Fix = 'Choose folder' }
    RECYCLE_TOO_BIG = @{ Text = 'Too big for the Recycle Bin, so nothing was deleted and the original was kept. Turn off the Recycle Bin option to compress it.'; Fix = 'Settings' }
    SMALL           = @{ Text = 'Already small: compressing would not save space, so it was left as it is.' }
    ALREADY         = @{ Text = 'This video is already compressed.' }
    OTHER           = @{ Text = 'Something went wrong while compressing. The original was not touched.'; Fix = 'Show details' }
}

function Get-RowReason($r) {
    if ($r.PSObject.Properties['Reason'] -and $r.Reason) { return $r.Reason }
    switch ($r.Result) {
        'KEPT'    { 'SMALL' }
        'SKIPPED' { if ($r.Note -like 'Not enough free*') { 'DISK_FULL' } elseif ($r.Note -like 'Already*') { 'ALREADY' } else { 'IN_USE' } }
        'FAILED'  {
            if ($r.Note -match 'No space left|not enough space') { 'DISK_FULL' }
            elseif ($r.Note -match 'moov atom|Invalid data|Duration mismatch|corrupt|truncat|Error while decoding') { 'DAMAGED' }
            elseif ($r.Note -match 'AMF|amf|encoder|Output codec') { 'ENCODER' }
            else { 'OTHER' }
        }
        default { $null }
    }
}

# one sentence for the end-of-run notification when something went wrong (or $null)
function Get-RunProblem([datetime]$since) {
    $bad = @(Get-LogRows | Where-Object { [datetime]$_.Time -ge $since.AddSeconds(-2) -and $_.Result -in 'FAILED', 'SKIPPED', 'KEPT' } |
        ForEach-Object { Get-RowReason $_ } | Where-Object { $_ -and $_ -notin 'SMALL', 'ALREADY' })
    if (-not $bad.Count) { return $null }
    $first = $bad[0]
    $what = switch ($first) {
        'DISK_FULL'       { 'there was not enough free disk space' }
        'IN_USE'          { 'a video was open in another program' }
        'ENCODER'         { "the graphics driver couldn't start the encoder" }
        'DAMAGED'         { 'a recording is damaged' }
        'MOVE_FOLDER'     { "the 'Move originals to' folder isn't available" }
        'RECYCLE_TOO_BIG' { 'a video was too big for the Recycle Bin' }
        default           { 'something went wrong' }
    }
    "$(Format-Count $bad.Count 'video') could not be compressed: $what. See Activity for details."
}

# fix buttons on Activity rows
function Invoke-Fix([string]$tag) {
    $reason, $path = $tag.Substring(4) -split '\|', 2
    switch ($reason) {
        'DISK_FULL'       { Start-Process explorer.exe '::{20D04FE0-3AEA-1069-A2D8-08002B30309D}' }   # This PC, shows free space per drive
        'ENCODER'         { Start-Process 'https://www.amd.com/en/support/download/drivers.html' }
        'DAMAGED'         { Open-Video $path }
        'MOVE_FOLDER'     { $script:W.NavSettings.IsChecked = $true; $script:W.SetMoveBrowse.RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Button]::ClickEvent))) }
        'RECYCLE_TOO_BIG' { $script:W.NavSettings.IsChecked = $true }
        default {
            $row = Get-LogRows | Where-Object { $_.File -eq $path } | Select-Object -Last 1
            [void](Show-RlcMessage 'What went wrong' "$path`n`n$($row.Note)")
        }
    }
}

# Average new size / original size from the log, for "about X GB after" estimates
function Get-SaveRatio {
    $ok = @(Get-LogRows | Where-Object { $_.Result -in 'OK', 'OK-MOVED', 'TEST-OK' -and [double]$_.OrigMB -gt 0 })
    if ($ok.Count -lt 1) { return 0.45 }
    ($ok | ForEach-Object { [double]$_.NewMB / [double]$_.OrigMB } | Measure-Object -Average).Average
}

# Where AMD Software (Adrenalin) saves recordings, or $null
function Get-AdrenalinFolder {
    $p = (Get-ItemProperty 'HKCU:\Software\AMD\DVR' -ErrorAction SilentlyContinue).CaptureFileOutput
    if ($p -and (Test-Path -LiteralPath $p)) { $p.TrimEnd('\') } else { $null }
}

# before/after frames saved by Worker.ps1 (Save-CompareFrames), same naming
function Get-ComparePath([string]$original, [string]$which) {
    $md5 = [Security.Cryptography.MD5]::Create()
    $key = (($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($original.ToLowerInvariant())) | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 16)
    Join-Path $AppDir "compare\$key-$which.jpg"
}

# ---------- videos ----------
function Set-Setting([string]$name, $value) {
    if ($script:Settings.PSObject.Properties[$name]) { $script:Settings.$name = $value }
    else { $script:Settings | Add-Member -NotePropertyName $name -NotePropertyValue $value }
}

# video players found on this PC, plus the one picked with "Choose another program"
function Get-Players {
    $list = New-Object Collections.Generic.List[object]
    $list.Add([pscustomobject]@{ Name = 'Windows default app'; Path = '' })
    $vlc = foreach ($k in 'HKLM:\SOFTWARE\VideoLAN\VLC', 'HKLM:\SOFTWARE\WOW6432Node\VideoLAN\VLC') {
        $d = (Get-ItemProperty $k -ErrorAction SilentlyContinue).InstallDir; if ($d) { Join-Path $d 'vlc.exe' }
    }
    $known = @(
        @('VLC media player', @($vlc) + "$env:ProgramFiles\VideoLAN\VLC\vlc.exe", "${env:ProgramFiles(x86)}\VideoLAN\VLC\vlc.exe"),
        @('Windows Media Player (Legacy)', "$env:ProgramFiles\Windows Media Player\wmplayer.exe", "${env:ProgramFiles(x86)}\Windows Media Player\wmplayer.exe"),
        @('MPC-HC', "$env:ProgramFiles\MPC-HC\mpc-hc64.exe", "${env:ProgramFiles(x86)}\MPC-HC\mpc-hc.exe"),
        @('PotPlayer', "$env:ProgramFiles\DAUM\PotPlayer\PotPlayerMini64.exe", "${env:ProgramFiles(x86)}\DAUM\PotPlayer\PotPlayerMini.exe"))
    foreach ($p in $known) {
        $exe = @($p[1..($p.Count - 1)] | ForEach-Object { $_ } | Where-Object { $_ -and (Test-Path $_) }) | Select-Object -First 1
        if ($exe) { $list.Add([pscustomobject]@{ Name = $p[0]; Path = $exe }) }
    }
    $mine = [string]$script:Settings.Player
    if ($mine -and (Test-Path $mine) -and -not ($list | Where-Object { $_.Path -eq $mine })) {
        $desc = (Get-Item $mine).VersionInfo.FileDescription
        $list.Add([pscustomobject]@{ Name = $(if ($desc) { $desc } else { [IO.Path]::GetFileNameWithoutExtension($mine) }); Path = $mine })
    }
    $list.Add([pscustomobject]@{ Name = 'Choose another program...'; Path = '*' })
    $list
}

function Open-Video([string]$path) {
    if (-not $path -or -not (Test-Path -LiteralPath $path)) {
        [void](Show-RlcMessage 'Video not found' "This video isn't there any more:`n$path")
        return
    }
    $player = [string]$script:Settings.Player
    if ($player -and (Test-Path $player)) { Start-Process -FilePath $player -ArgumentList "`"$path`"" }
    else { Start-Process -FilePath $path }
}

# ---------- dialogs (same dark look as the window) ----------
# $content: text or a WPF element. $buttons: @{ Text; Value; Style; Disabled } left to right. Returns the clicked button's Value.
function New-RlcDialog([string]$title, $content, [object[]]$buttons, [int]$width = 540) {
    if (-not $script:Win) { Initialize-MainWindow }
    $d = New-Object Windows.Window
    $d.Resources.MergedDictionaries.Add($script:Win.Resources)
    $d.Title = $AppName; $d.Width = $width; $d.SizeToContent = 'Height'
    $d.WindowStyle = 'None'; $d.ResizeMode = 'NoResize'; $d.ShowInTaskbar = $false
    $d.Background = '#1C1C1C'; $d.Foreground = '#EDEDED'; $d.FontFamily = 'Segoe UI'; $d.FontSize = 13
    $d.BorderBrush = '#3A3A3A'; $d.BorderThickness = 1
    $d.UseLayoutRounding = $true; [Windows.Media.TextOptions]::SetTextFormattingMode($d, 'Display')
    if ($script:Win.IsVisible) { $d.Owner = $script:Win; $d.WindowStartupLocation = 'CenterOwner' }
    else { $d.WindowStartupLocation = 'CenterScreen'; $d.Topmost = $true }
    $d.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Escape') { $s.Close() } })

    $root = New-Object Windows.Controls.DockPanel
    $root.Background = '#1C1C1C'    # solid background keeps text crisp (transparent areas render it dim)
    $head = New-Object Windows.Controls.Border
    $head.Background = '#151515'; $head.Padding = '20,13'; $head.BorderBrush = $script:Win.Resources['Accent']; $head.BorderThickness = '0,0,0,2'
    $ht = New-Object Windows.Controls.TextBlock; $ht.Text = $title; $ht.FontSize = 15; $ht.FontWeight = 'SemiBold'
    $head.Child = $ht
    $head.Add_MouseLeftButtonDown({ param($s) [Windows.Window]::GetWindow($s).DragMove() })
    [Windows.Controls.DockPanel]::SetDock($head, 'Top'); [void]$root.Children.Add($head)

    $bar = New-Object Windows.Controls.StackPanel
    $bar.Orientation = 'Horizontal'; $bar.HorizontalAlignment = 'Right'; $bar.Margin = '20,0,20,18'
    $byValue = @{}
    foreach ($b in $buttons) {
        $btn = New-Object Windows.Controls.Button
        $btn.Content = $b.Text; $btn.Tag = $b.Value; $btn.Margin = '10,0,0,0'
        $btn.Style = $script:Win.Resources[$(if ($b.Style) { $b.Style } else { 'BtnDark' })]
        if ($b.Disabled) { $btn.IsEnabled = $false }
        $btn.Add_Click({ param($s) $w = [Windows.Window]::GetWindow($s); $w.Tag = $s.Tag; $w.Close() })
        [void]$bar.Children.Add($btn); $byValue[[string]$b.Value] = $btn
    }
    [Windows.Controls.DockPanel]::SetDock($bar, 'Bottom'); [void]$root.Children.Add($bar)

    $body = New-Object Windows.Controls.Border; $body.Padding = '20,16,20,20'
    if ($content -is [string]) {
        $t = New-Object Windows.Controls.TextBlock; $t.Text = $content; $t.TextWrapping = 'Wrap'; $t.Foreground = '#C8C8C8'; $t.LineHeight = 19
        $body.Child = $t
    }
    else { $body.Child = $content }
    [void]$root.Children.Add($body)
    $d.Content = $root
    @{ Window = $d; Buttons = $byValue }
}

function Show-RlcDialog($dlg) { [void]$dlg.Window.ShowDialog(); $dlg.Window.Tag }

function Show-RlcMessage([string]$title, [string]$text) {
    Show-RlcDialog (New-RlcDialog $title $text @(@{ Text = 'OK'; Value = 'ok'; Style = 'BtnPrimary' }))
}

# small WPF builders for dialog content
function New-Text([string]$text, [double]$size = 13, [string]$color = '#C8C8C8', [string]$margin = '0,0,0,10') {
    $t = New-Object Windows.Controls.TextBlock
    $t.Text = $text; $t.TextWrapping = 'Wrap'; $t.FontSize = $size; $t.Foreground = $color; $t.Margin = $margin; $t.LineHeight = $size * 1.45
    $t
}
function New-ModeChoice([string]$name, [string]$glyph, [string]$color, [string]$title, [string]$text) {
    $rb = New-Object Windows.Controls.RadioButton
    $rb.GroupName = $name; $rb.Style = $script:Win.Resources['ModeTile']
    $sp = New-Object Windows.Controls.StackPanel
    $g = New-Text $glyph 22 $color '0'; $g.FontFamily = 'Segoe MDL2 Assets'
    $h = New-Text $title 15 '#EDEDED' '0,10,0,4'; $h.FontWeight = 'SemiBold'
    [void]$sp.Children.Add($g); [void]$sp.Children.Add($h); [void]$sp.Children.Add((New-Text $text 11.5 '#8E8E8E' '0'))
    $rb.Content = $sp
    $rb
}

# Automatic compression can't run in Test mode: offer to switch Test mode off right here.
# Returns $true when the user picked Replace or Move.
function Show-TestModeDialog {
    if (-not $script:Win) { Initialize-MainWindow }
    $panel = New-Object Windows.Controls.StackPanel
    [void]$panel.Children.Add((New-Text "You're still in Test mode. Test mode only makes a few compressed copies and never changes your originals, so automatic compression can't run in it."))
    [void]$panel.Children.Add((New-Text "To turn automatic compression on, switch Test mode off and choose what happens to each original after it has been compressed and checked:" 13 '#C8C8C8' '0,0,0,14'))
    $grid = New-Object Windows.Controls.Primitives.UniformGrid; $grid.Columns = 2
    $rep = New-ModeChoice 'tm' ([string][char]0xE74D) '#E5202E' 'Replace' 'The compressed file takes its place and the original is deleted. Saves the most space. Cannot be undone.'
    $mov = New-ModeChoice 'tm' ([string][char]0xE8DE) '#D29922' 'Move' "The compressed file takes its place and the original is moved to:`n$($script:Settings.MoveFolder)"
    $rep.Margin = '0,0,6,0'; $mov.Margin = '6,0,0,0'
    [void]$grid.Children.Add($rep); [void]$grid.Children.Add($mov); [void]$panel.Children.Add($grid)
    $dlg = New-RlcDialog 'Turn on automatic compression' $panel @(
        @{ Text = 'Keep Test mode'; Value = 'keep' },
        @{ Text = 'Turn Test mode off'; Value = 'off'; Style = 'BtnPrimary'; Disabled = $true }) 600
    $script:DlgOff = $dlg.Buttons['off']
    foreach ($rb in $rep, $mov) { $rb.Add_Checked({ $script:DlgOff.IsEnabled = $true }) }
    if ((Show-RlcDialog $dlg) -ne 'off') { return $false }
    $script:Settings.Mode = if ($mov.IsChecked) { 'Move' } else { 'Replace' }
    Save-Settings
    $true
}

# ---------- "i" explanations ----------
function Show-AutoInfo {
    $p = New-Object Windows.Controls.StackPanel
    $idle = $script:Settings.IdleMinutes
    [void]$p.Children.Add((New-Text "Automatic compression shrinks new recordings while you're away from the PC, so it never slows down your games."))
    [void]$p.Children.Add((New-Text 'WHEN IT STARTS' 11 '#8E8E8E' '0,6,0,4'))
    [void]$p.Children.Add((New-Text "$([char]0x2022)  No keyboard or mouse input for $idle minutes (change this under Settings > Start after being idle for). Moving the mouse even once restarts the countdown.`n$([char]0x2022)  No fullscreen game or presentation is running.`n$([char]0x2022)  It checks for new recordings every 10 minutes. Clips are only picked up once they're 10 minutes old, so a recording in progress is never touched."))
    [void]$p.Children.Add((New-Text 'WHEN YOU COME BACK' 11 '#8E8E8E' '0,6,0,4'))
    [void]$p.Children.Add((New-Text "The moment you touch the keyboard or mouse, compression pauses instantly (no CPU or GPU use) and carries on where it left off the next time you're away. Long recordings are finished over several idle periods."))
    [void]$p.Children.Add((New-Text 'GOOD TO KNOW' 11 '#8E8E8E' '0,6,0,4'))
    [void]$p.Children.Add((New-Text "$([char]0x2022)  ReLive Compressor has to be running (its icon next to the clock). Leave 'Start with Windows' on so it is.`n$([char]0x2022)  It doesn't run in Test mode, which only makes a few copies to compare.`n$([char]0x2022)  To compress straight away instead, use 'Compress all waiting' on Home, or pick videos on the Compress page." 13 '#C8C8C8' '0'))
    [void](Show-RlcDialog (New-RlcDialog 'How automatic compression works' $p @(@{ Text = 'Got it'; Value = 'ok'; Style = 'BtnPrimary' }) 600))
}

function Show-PresetInfo {
    $p = New-Object Windows.Controls.StackPanel
    [void]$p.Children.Add((New-Text "The preset tells the graphics card how hard to work on each frame. File size is set by the video bitrate, so it stays about the same with every preset. What changes is speed, and a little quality."))
    # measured on an RX 9070 XT, 1440p60 Call of Duty footage at 20 Mbps
    $rows = @(
        @('Speed', 'The least work per frame. On fast cards it is no quicker than Balanced (143 vs 151 fps measured), because reading the original video is the limit. Can help on older graphics cards.'),
        @('Balanced (recommended)', 'About 150 frames per second on an RX 9070 XT, so a 10-minute 60 fps clip takes around 4 minutes. Quality score (VMAF) 97.9 of 100.'),
        @('Quality', 'Less than half the speed (about 70 fps) for a tiny gain: VMAF 98.1 instead of 97.9, which you will not see. Only worth it at low bitrates.'))
    foreach ($r in $rows) {
        [void]$p.Children.Add((New-Text $r[0] 13.5 '#EDEDED' '0,8,0,2'))
        [void]$p.Children.Add((New-Text $r[1] 12.5 '#A8A8A8' '0'))
    }
    [void]$p.Children.Add((New-Text "Compression only runs while you're away from the PC, so a slower preset means it needs more idle time, never that your games run slower." 12.5 '#8E8E8E' '0,14,0,0'))
    [void](Show-RlcDialog (New-RlcDialog 'Encoder preset' $p @(@{ Text = 'Got it'; Value = 'ok'; Style = 'BtnPrimary' }) 560))
}

# side-by-side style comparison: one crop of the same gameplay frame at each bitrate, switched with buttons
function Show-RateInfo {
    $p = New-Object Windows.Controls.StackPanel
    [void]$p.Children.Add((New-Text "Video bitrate is how much data each second of video may use. More bitrate keeps more detail but makes bigger files. The pictures below are the same moment of a 1440p 60 fps recording at 100% zoom, compressed by this app at each setting. Busy, fast-moving scenes show the difference most."))
    $samples = [ordered]@{
        'src' = @('Original', 'The recording as Radeon ReLive saved it (about 40 Mbps H.264): about 320 MB per minute.')
        '10'  = @('10 Mbps', 'About 65 MB per minute. Visibly softer: textures like concrete, snow and foliage smear in motion. Quality score (VMAF) 82 of 100.')
        '20'  = @('20 Mbps (default)', 'About 145 MB per minute. Very close to the original; differences are hard to spot while playing. VMAF 97.')
        '40'  = @('40 Mbps', 'About 240 MB per minute. Practically identical to the original, but saves much less space. VMAF 99.')
    }
    $tabs = New-Object Windows.Controls.StackPanel; $tabs.Orientation = 'Horizontal'; $tabs.Margin = '0,4,0,10'
    $img = New-Object Windows.Controls.Image; $img.Width = 800; $img.Height = 450; $img.Stretch = 'Uniform'
    $frame = New-Object Windows.Controls.Border; $frame.Background = '#111111'; $frame.Child = $img; $frame.HorizontalAlignment = 'Left'
    $caption = New-Text '' 12.5 '#C8C8C8' '0,10,0,0'
    $script:RateInfo = @{ Img = $img; Caption = $caption; Samples = $samples; Tabs = $tabs }
    foreach ($k in $samples.Keys) {
        $b = New-Object Windows.Controls.Button
        $b.Content = $samples[$k][0]; $b.Tag = $k; $b.Margin = '0,0,8,0'; $b.Style = $script:Win.Resources['BtnSmall']
        $b.Add_Click({ param($s) Set-RateSample $s.Tag })
        [void]$tabs.Children.Add($b)
    }
    [void]$p.Children.Add($tabs); [void]$p.Children.Add($frame); [void]$p.Children.Add($caption)
    [void]$p.Children.Add((New-Text "Tip: compare 10 and 20 Mbps on the concrete block and the snow. Sizes are for 1440p 60 fps AV1. On older graphics cards that use HEVC, the app adds 25% to the bitrate for the same quality." 11.5 '#8E8E8E' '0,10,0,0'))
    Set-RateSample '20'
    [void](Show-RlcDialog (New-RlcDialog 'Video bitrate: what it looks like' $p @(@{ Text = 'Got it'; Value = 'ok'; Style = 'BtnPrimary' }) 842))
}

function Set-RateSample([string]$key) {
    $ri = $script:RateInfo
    $file = Join-Path $AppDir "bitrate-$key.jpg"
    if (Test-Path $file) {
        $bmp = New-Object Windows.Media.Imaging.BitmapImage
        $bmp.BeginInit(); $bmp.CacheOption = 'OnLoad'; $bmp.UriSource = New-Object Uri $file; $bmp.EndInit(); $bmp.Freeze()
        $ri.Img.Source = $bmp
    }
    $ri.Caption.Text = $ri.Samples[$key][1]
    foreach ($b in $ri.Tabs.Children) {
        $b.Background = if ($b.Tag -eq $key) { $script:Win.Resources['Accent'] } else { [Windows.Media.Brush](New-Object Windows.Media.BrushConverter).ConvertFrom('#2C2C2C') }
    }
}

# Activity > Clear log: everything, or everything before a chosen date and time
function Show-ClearLogDialog {
    if (Test-WorkerRunning) { [void](Show-RlcMessage 'Clear log' 'Please wait until compressing has finished (or press Stop on the Home page), then clear the log.'); return }
    $rows = @(Get-LogRows)
    if (-not $rows.Count) { [void](Show-RlcMessage 'Clear log' 'The log is already empty.'); return }
    $p = New-Object Windows.Controls.StackPanel
    [void]$p.Children.Add((New-Text "Remove entries from the Activity log ($($rows.Count) entries)." 13 '#C8C8C8' '0,0,0,12'))
    $all = New-Object Windows.Controls.RadioButton; $all.Style = $script:Win.Resources['DarkRadio']; $all.Content = 'Clear everything'; $all.IsChecked = $true; $all.GroupName = 'cl'
    $before = New-Object Windows.Controls.RadioButton; $before.Style = $script:Win.Resources['DarkRadio']; $before.Content = 'Clear entries from before:'; $before.GroupName = 'cl'
    [void]$p.Children.Add($all); [void]$p.Children.Add($before)
    $pick = New-Object Windows.Controls.StackPanel; $pick.Orientation = 'Horizontal'; $pick.Margin = '26,6,0,0'
    $dates = @($rows | ForEach-Object { ([datetime]$_.Time).Date } | Sort-Object -Unique -Descending)
    $cbDate = New-Object Windows.Controls.ComboBox; $cbDate.Style = $script:Win.Resources['DarkCombo']; $cbDate.Width = 170; $cbDate.Height = 32
    foreach ($d in $dates) { [void]$cbDate.Items.Add($d.ToString('ddd dd MMM yyyy')) }
    $cbTime = New-Object Windows.Controls.ComboBox; $cbTime.Style = $script:Win.Resources['DarkCombo']; $cbTime.Width = 90; $cbTime.Height = 32
    for ($h = 0; $h -lt 24; $h++) { [void]$cbTime.Items.Add(('{0:00}:00' -f $h)) }
    $cbDate.SelectedIndex = 0; $cbTime.SelectedIndex = 0
    foreach ($cb in $cbDate, $cbTime) {
        $wrap = New-Object Windows.Controls.Border; $wrap.Background = '#252525'; $wrap.Padding = '10,0'; $wrap.Margin = '0,0,8,0'; $wrap.Child = $cb
        [void]$pick.Children.Add($wrap)
        $cb.Add_SelectionChanged({ $script:ClearBefore.IsChecked = $true })
    }
    $script:ClearBefore = $before
    [void]$p.Children.Add($pick)
    $warn = New-Text ("This can't be undone. Your videos are not affected, but:`n$([char]0x2022)  'Saved so far' and the Activity history lose the cleared entries.`n$([char]0x2022)  Recordings that failed or were skipped will be tried again.`n$([char]0x2022)  In Test mode, clips may get new test copies.") 12.5 '#D29922' '0,16,0,0'
    [void]$p.Children.Add($warn)
    $r = Show-RlcDialog (New-RlcDialog 'Clear Activity log' $p @(@{ Text = 'Cancel'; Value = 'cancel' }, @{ Text = 'Clear log'; Value = 'clear'; Style = 'BtnPrimary' }) 560)
    if ($r -ne 'clear') { return }

    $cutoff = if ($before.IsChecked) { $dates[$cbDate.SelectedIndex].AddHours($cbTime.SelectedIndex) } else { [DateTime]::MaxValue }
    $keep = @($rows | Where-Object { [datetime]$_.Time -ge $cutoff })
    $gone = $rows.Count - $keep.Count
    if (-not $gone) { [void](Show-RlcMessage 'Clear log' "There are no entries before $($cutoff.ToString('dd MMM yyyy HH:mm'))."); return }
    $what = if ($before.IsChecked) { "$gone entries from before $($cutoff.ToString('dd MMM yyyy HH:mm'))" } else { "all $gone entries" }
    $ok = Show-RlcDialog (New-RlcDialog 'Are you sure?' "Permanently remove $what from the Activity log?" @(@{ Text = 'Cancel'; Value = 'cancel' }, @{ Text = 'Yes, clear'; Value = 'yes'; Style = 'BtnPrimary' }))
    if ($ok -ne 'yes') { return }
    $log = Join-Path $AppDir 'compress-log.csv'
    if ($keep.Count) { $keep | Export-Csv -Path $log -NoTypeInformation -Encoding UTF8 } else { Remove-Item $log -Force }
    Update-Activity; Update-MainWindow -Heavy
}

# ---------- window ----------
function Initialize-MainWindow {
    $xaml = [IO.File]::ReadAllText((Join-Path $AppDir 'MainWindow.xaml'))
    $script:Win = [Windows.Markup.XamlReader]::Parse($xaml)
    foreach ($m in [regex]::Matches($xaml, 'x:Name="(\w+)"')) { $script:W[$m.Groups[1].Value] = $script:Win.FindName($m.Groups[1].Value) }
    [Windows.Forms.Integration.ElementHost]::EnableModelessKeyboardInterop($script:Win)
    $script:Win.Icon = if (Test-Path $IconPath) { [Windows.Media.Imaging.BitmapFrame]::Create([Uri]$IconPath) }
                       else { [Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon($Icons.Logo.Handle, [Windows.Int32Rect]::Empty, [Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions()) }
    $W = $script:W

    # window chrome
    $W.BtnClose.Add_Click({ $script:Win.Hide() })
    $W.BtnMin.Add_Click({ $script:Win.WindowState = 'Minimized' })
    $W.BtnMax.Add_Click({ $script:Win.WindowState = if ($script:Win.WindowState -eq 'Maximized') { 'Normal' } else { 'Maximized' } })
    $script:Win.Add_StateChanged({
        $max = $script:Win.WindowState -eq 'Maximized'
        $script:W.Root.Margin = if ($max) { 7 } else { 0 }       # borderless windows overhang the screen when maximized
        $script:W.BtnMax.Content = if ($max) { [string][char]0xE923 } else { [string][char]0xE922 }
    })
    $script:Win.Add_Closing({ param($s, $e) $e.Cancel = $true; $script:Win.Hide() })   # closing the window keeps the tray app running

    # navigation
    foreach ($n in 'Home', 'Compress', 'Activity', 'Settings') {
        $W["Nav$n"].Tag = $n
        $W["Nav$n"].Add_Checked({ param($s) Set-Page $s.Tag })
    }

    # home
    $W.AutoToggle.Add_Click({ Invoke-AutoToggleFromUi $script:W.AutoToggle })
    $W.BtnRun.Add_Click({ Invoke-CompressNowToggle; Update-MainWindow })
    $W.BtnPause.Add_Click({ Invoke-PauseToggle; Update-MainWindow })
    $W.BtnChoose.Add_Click({ $script:W.NavCompress.IsChecked = $true })
    $W.UpdNow.Add_Click({ Invoke-UpdateInstall })
    $W.UpdLater.Add_Click({ $script:UpdateDismissed = [string]$script:Update.version; Update-MainWindow })
    $W.AwaySee.Add_Click({ $script:AwaySummary = $null; $script:W.NavActivity.IsChecked = $true })
    $W.AwayClose.Add_Click({ $script:AwaySummary = $null; Update-MainWindow })
    $W.QOpenRec.Add_Click({ Start-Process explorer.exe "`"$($script:Settings.RecordingsFolder)`"" })
    $W.QRescan.Add_Click({ if (-not (Test-WorkerRunning)) { Start-Worker 'scan' }; Update-MainWindow })
    $W.QLog.Add_Click({ $script:W.NavActivity.IsChecked = $true })
    $W.QSettings.Add_Click({ $script:W.NavSettings.IsChecked = $true })

    # compress page: check boxes update the totals; play and open-folder buttons
    $W.CmpList.AddHandler([Windows.Controls.Primitives.ButtonBase]::ClickEvent, [Windows.RoutedEventHandler]{
        param($s, $e)
        $src = $e.OriginalSource
        if ($src -is [Windows.Controls.CheckBox]) { Update-CompressTotals; return }
        $tag = [string]$src.Tag
        if ($tag -like 'play:*') { Open-Video $tag.Substring(5) }
        elseif ($tag -like 'folder:*') { $dir = $tag.Substring(7); if (Test-Path -LiteralPath $dir) { Start-Process explorer.exe "`"$dir`"" } }
    })
    $W.CmpAll.Add_Click({ foreach ($g in @($script:CmpGroups)) { foreach ($c in $g.Clips) { if ($c.CanSelect) { $c.IsChecked = $true } } }; Update-CompressTotals })
    $W.CmpNone.Add_Click({ foreach ($g in @($script:CmpGroups)) { foreach ($c in $g.Clips) { $c.IsChecked = $false } }; Update-CompressTotals })
    $W.CmpStart.Add_Click({ Start-CompressSelection })
    $W.CmpStop.Add_Click({ Invoke-CompressNowToggle; Update-CompressPage })
    $W.CmpPause.Add_Click({ Invoke-PauseToggle; Update-CompressLive })
    $W.CmpModeChange.Add_Click({ $script:W.NavSettings.IsChecked = $true })

    # rows of Home > Recently compressed and Activity: click plays the video; small buttons compare or fix
    foreach ($list in $W.RecentList, $W.ActList) {
        $list.AddHandler([Windows.Controls.Primitives.ButtonBase]::ClickEvent, [Windows.RoutedEventHandler]{
            param($s, $e)
            $tag = [string]$e.OriginalSource.Tag
            $e.Handled = $true
            if ($tag -like 'cmp:*') { Show-Compare $tag.Substring(4) }
            elseif ($tag -like 'fix:*') { Invoke-Fix $tag }
            elseif ($tag) { Open-Video $tag }
        })
    }

    # drop videos (or folders of videos) anywhere on the window to compress them
    $script:Win.Add_DragOver({
        param($s, $e)
        $e.Effects = if ($e.Data.GetDataPresent([Windows.DataFormats]::FileDrop)) { 'Copy' } else { 'None' }
        $e.Handled = $true
    })
    $script:Win.Add_Drop({
        param($s, $e)
        if ($e.Data.GetDataPresent([Windows.DataFormats]::FileDrop)) { Add-VideosFromPaths @($e.Data.GetData([Windows.DataFormats]::FileDrop)) }
    })
    $W.ActClear.Add_Click({ Show-ClearLogDialog })
    $W.InfoAuto.Add_Click({ Show-AutoInfo })
    $W.InfoAuto2.Add_Click({ Show-AutoInfo })
    $W.InfoRate.Add_Click({ Show-RateInfo })
    $W.InfoPreset.Add_Click({ Show-PresetInfo })

    # settings
    foreach ($m in $IdleChoices) { [void]$W.SetIdle.Items.Add("$m minutes") }
    $W.SetAppDir.Text = $AppDir
    $W.SetRecycle.Add_Click({ Set-Setting 'RecycleOriginals' ([bool]$script:W.SetRecycle.IsChecked); Save-Settings; Update-MainWindow })
    $W.InfoRecycle.Add_Click({ Show-RecycleInfo })
    $W.AdrUse.Add_Click({
        $script:Settings.RecordingsFolder = Get-AdrenalinFolder; Save-Settings; Sync-SettingsControls
        if (-not (Test-WorkerRunning)) { Start-Worker 'scan' }
    })
    $W.SetWelcome.Add_Click({ Show-WelcomeGuide })
    $W.SetCheckUpd.Add_Click({ $script:ManualCheck = $true; Start-UpdateCheck; Update-VersionText })
    $W.SetUpdAuto.Add_Click({ Set-Setting 'CheckUpdates' ([bool]$script:W.SetUpdAuto.IsChecked); Save-Settings; Sync-SettingsControls })

    foreach ($m in $ModeNames) {
        $W["Mode$m"].Tag = $m
        $W["Mode$m"].Add_Checked({ param($s) if (-not $script:Loading) { Set-Mode $s.Tag } })
    }
    $W.SetRate.Add_ValueChanged({
        $v = [int]$script:W.SetRate.Value
        $script:W.SetRateText.Text = if ($v -eq 20) { '20 Mbps (default)' } else { "$v Mbps" }
        if ($script:Loading -or $v -eq [int]$script:Settings.TargetMbps) { return }
        $script:Settings.TargetMbps = $v; Save-Settings; Update-MainWindow
    })
    $W.SetPlayer.Add_SelectionChanged({
        if ($script:Loading -or $script:W.SetPlayer.SelectedIndex -lt 0) { return }
        $choice = $script:Players[$script:W.SetPlayer.SelectedIndex]
        if ($choice.Path -eq '*') {
            $d = New-Object Microsoft.Win32.OpenFileDialog
            $d.Title = 'Choose the program that should play your videos'; $d.Filter = 'Programs (*.exe)|*.exe'
            $d.InitialDirectory = $env:ProgramFiles
            if ($d.ShowDialog($script:Win)) { Set-Setting 'Player' $d.FileName; Save-Settings }
        }
        else { Set-Setting 'Player' $choice.Path; Save-Settings }
        Sync-SettingsControls
    })
    $W.SetPreset.Add_SelectionChanged({
        if ($script:Loading -or $script:W.SetPreset.SelectedIndex -lt 0) { return }
        $script:Settings.Preset = $PresetNames[$script:W.SetPreset.SelectedIndex]; Save-Settings; Update-MainWindow
    })
    $W.SetIdle.Add_SelectionChanged({
        if ($script:Loading -or $script:W.SetIdle.SelectedIndex -lt 0) { return }
        $script:Settings.IdleMinutes = $IdleChoices[$script:W.SetIdle.SelectedIndex]; Save-Settings; Update-MainWindow
    })
    $W.SetAuto.Add_Click({ Invoke-AutoToggleFromUi $script:W.SetAuto })
    $W.SetBoot.Add_Click({ Set-StartWithWindows ([bool]$script:W.SetBoot.IsChecked); Sync-SettingsControls })

    foreach ($pair in @(@('SetRecBrowse', 'SetRec', 'RecordingsFolder'), @('SetTestBrowse', 'SetTest', 'TestFolder'), @('SetMoveBrowse', 'SetMove', 'MoveFolder'))) {
        $W[$pair[0]].Tag = $pair
        $W[$pair[0]].Add_Click({
            param($s)
            $d = New-Object Windows.Forms.FolderBrowserDialog
            $d.SelectedPath = $script:Settings.($s.Tag[2])
            if ($d.ShowDialog() -ne 'OK') { return }
            $script:Settings.($s.Tag[2]) = $d.SelectedPath
            Save-Settings; Sync-SettingsControls
            if ($s.Tag[2] -eq 'RecordingsFolder' -and -not (Test-WorkerRunning)) { Start-Worker 'scan' }
        })
    }
    $W.SetOpenLog.Add_Click({ $log = Join-Path $AppDir 'compress-log.csv'; if (Test-Path $log) { Start-Process $log } })
    $W.SetOpenApp.Add_Click({ Start-Process explorer.exe "`"$AppDir`"" })
    $W.SetUninstall.Add_Click({ Invoke-Uninstall })
}

function Set-Mode([string]$mode) {
    if ($mode -eq $script:Settings.Mode) { return }
    if ($mode -eq 'Replace') {
        $p = New-Object Windows.Controls.StackPanel
        [void]$p.Children.Add((New-Text "Replace mode removes each original recording after its compressed copy has been checked (same length, has video and audio, smaller)."))
        $cb = New-RecycleCheck
        [void]$p.Children.Add($cb)
        $r = Show-RlcDialog (New-RlcDialog 'Switch to Replace mode?' $p @(
            @{ Text = 'Cancel'; Value = 'cancel' }, @{ Text = 'Use Replace mode'; Value = 'yes'; Style = 'BtnPrimary' }))
        if ($r -ne 'yes') { Sync-SettingsControls; return }
        Set-Setting 'RecycleOriginals' ([bool]$cb.IsChecked)
    }
    $script:Settings.Mode = $mode
    if ($mode -eq 'Test') { $script:Settings.AutoEnabled = $false }
    Save-Settings; Sync-SettingsControls; Update-MainWindow; Update-Ui
}

function Invoke-AutoToggleFromUi($toggle) {
    if (-not (Set-AutoEnabled ([bool]$toggle.IsChecked))) { $toggle.IsChecked = [bool]$script:Settings.AutoEnabled }
    Sync-SettingsControls; Update-MainWindow
}

function Show-MainWindow([string]$page = 'Home') {
    if (-not $script:Win) { Initialize-MainWindow }
    $script:W["Nav$page"].IsChecked = $true
    Set-Page $page
    $script:Win.Show()
    if ($script:Win.WindowState -eq 'Minimized') { $script:Win.WindowState = 'Normal' }
    [void]$script:Win.Activate()
}

function Set-Page([string]$page) {
    $script:Page = $page
    foreach ($n in 'Home', 'Compress', 'Activity', 'Settings') {
        $script:W["Page$n"].Visibility = if ($n -eq $page) { 'Visible' } else { 'Collapsed' }
    }
    switch ($page) {
        'Compress' { Update-CompressPage }
        'Activity' { Update-Activity }
        'Settings' { Sync-SettingsControls }
    }
    Update-MainWindow -Heavy
}

function Sync-SettingsControls {
    $script:Loading = $true
    $W = $script:W; $st = $script:Settings
    foreach ($m in $ModeNames) { $W["Mode$m"].IsChecked = $st.Mode -eq $m }
    # Move mode: the destination folder matters, so outline it in red
    $move = $st.Mode -eq 'Move'
    $W.RowMove.BorderBrush = if ($move) { $script:Win.Resources['Accent'] } else { [Windows.Media.Brush](New-Object Windows.Media.BrushConverter).ConvertFrom('#131313') }
    $W.RowMove.BorderThickness = if ($move) { 2 } else { '0,0,0,1' }
    $W.RowMoveHint.Visibility = if ($move) { 'Visible' } else { 'Collapsed' }
    $W.SetRate.Value = [int]$st.TargetMbps
    $W.SetRateText.Text = if ([int]$st.TargetMbps -eq 20) { '20 Mbps (default)' } else { "$($st.TargetMbps) Mbps" }
    $script:Players = @(Get-Players)
    $W.SetPlayer.Items.Clear()
    foreach ($p in $script:Players) { [void]$W.SetPlayer.Items.Add($p.Name) }
    $sel = [array]::IndexOf(@($script:Players | ForEach-Object Path), [string]$st.Player)
    $W.SetPlayer.SelectedIndex = if ($sel -ge 0) { $sel } else { 0 }
    $W.SetPreset.SelectedIndex = [array]::IndexOf($PresetNames, [string]$st.Preset)
    $W.SetIdle.SelectedIndex = [array]::IndexOf($IdleChoices, [int]$st.IdleMinutes)
    $W.SetAuto.IsChecked = [bool]$st.AutoEnabled
    $W.SetAutoText.Text = if ($st.AutoEnabled) { 'Enabled' } else { 'Disabled' }
    $boot = Test-Path $StartupLnk
    $W.SetBoot.IsChecked = $boot
    $W.SetBootText.Text = if ($boot) { 'Enabled' } else { 'Disabled' }
    $W.SetRec.Text = $st.RecordingsFolder
    $W.SetTest.Text = $st.TestFolder
    $W.SetMove.Text = $st.MoveFolder
    $W.SetRecycle.IsChecked = [bool]$st.RecycleOriginals
    $W.SetRecycle.IsEnabled = $st.Mode -eq 'Replace'
    # Adrenalin now saves somewhere else than the folder we watch
    $adr = Get-AdrenalinFolder
    $diff = $adr -and $adr -ne ([string]$st.RecordingsFolder).TrimEnd('\')
    $W.AdrHint.Visibility = if ($diff) { 'Visible' } else { 'Collapsed' }
    if ($diff) { $W.AdrText.Text = "AMD Software now saves new recordings to $adr. Use that folder?" }
    $W.SetUpdAuto.IsChecked = $st.CheckUpdates -ne $false
    $W.SetUpdAutoText.Text = if ($st.CheckUpdates -ne $false) { 'Automatically, once a day' } else { "Off - use 'Check now'" }
    Update-VersionText
    $script:Loading = $false
}

# Called every 2 s by the tray timer while the window is open. -Heavy also recomputes storage numbers.
function Update-MainWindow([switch]$Heavy) {
    if (-not $script:Win -or -not $script:Win.IsVisible) { return }
    $W = $script:W; $st = $script:Settings; $s = $script:Status
    $running = (Test-WorkerRunning) -and $script:RunKind -ne 'scan'
    $scanning = (Test-WorkerRunning) -and $script:RunKind -eq 'scan'
    $pending = if ($s -and $null -ne $s.Pending) { [int]$s.Pending } else { $null }
    # AV1 on RX 7000+, HEVC (with 25% more bitrate) on older Radeons - the worker picks and reports it
    $hevc = $s -and $s.Encoder -eq 'hevc'
    $codecName = if ($hevc) { 'HEVC' } else { 'AV1' }
    $mbps = if ($hevc) { [math]::Round($st.TargetMbps * 1.25) } else { $st.TargetMbps }

    # top-right status pill
    if ($running -and $script:Paused) { $W.StatusDot.Fill = '#D29922'; $W.StatusPillText.Text = 'Paused' }
    elseif ($running) { $W.StatusDot.Fill = '#3FB950'; $W.StatusPillText.Text = "Compressing $([math]::Round([double]$s.Percent))%" }
    elseif ($scanning) { $W.StatusDot.Fill = '#58A6FF'; $W.StatusPillText.Text = 'Checking recordings' }
    elseif ($st.AutoEnabled) { $W.StatusDot.Fill = '#E5202E'; $W.StatusPillText.Text = 'Automatic - waiting for idle' }
    else { $W.StatusDot.Fill = '#7A7A7A'; $W.StatusPillText.Text = 'Automatic off' }

    # automatic card
    $W.AutoToggle.IsChecked = [bool]$st.AutoEnabled
    $W.AutoBig.Text = if ($st.AutoEnabled) { 'On' } else { 'Off' }
    $W.AutoText.Text = if ($st.Mode -eq 'Test') { "Test mode: use Compress now to make test copies. Pick Replace or Move in Settings to allow automatic runs." }
                       elseif ($st.AutoEnabled) { "Starts after $($st.IdleMinutes) idle minutes (no keyboard/mouse, no fullscreen game) and pauses the moment you're back." }
                       else { "Nothing runs on its own. Turn on to compress new recordings while you're away from the PC." }

    # update banner and "while you were away"
    $u = $script:Update
    $showUpd = $u -and [string]$u.version -ne $script:UpdateDismissed
    $W.UpdBanner.Visibility = if ($showUpd) { 'Visible' } else { 'Collapsed' }
    if ($showUpd) {
        $W.UpdTitle.Text = "Update available: ReLive Compressor $($u.version)"
        $notes = @($u.notes | Where-Object { $_ })
        $W.UpdNotes.Text = if ($notes.Count) { "What's new: " + ($notes -join "  $([char]0x00B7)  ") } else { "You have version $AppVersion." }
    }
    $W.AwayCard.Visibility = if ($script:AwaySummary) { 'Visible' } else { 'Collapsed' }
    if ($script:AwaySummary) { $W.AwayText.Text = "While you were away: compressed $(Format-Count $script:AwaySummary.Count 'clip') and saved $($script:AwaySummary.SavedGB) GB." }
    if ($script:Page -eq 'Settings') { Update-VersionText }

    # now card
    if ($running -and $s.File) {
        $dir = [IO.Path]::GetDirectoryName($s.File)
        $W.NowGame.Text = (Get-GameName $dir).ToUpper()
        $W.NowTitle.Text = [IO.Path]::GetFileNameWithoutExtension($s.File)
        $W.NowSub.Text = if ($script:Paused) { 'Paused - continues when you click Resume or step away again.' } else { "Re-encoding to $codecName at $mbps Mbps, 60 fps, original audio." }
        $W.NowBar.Value = [double]$s.Percent
        $W.NowPct.Text = "$([math]::Round([double]$s.Percent, 1))%"
        $W.NowCount.Text = "File $([int]$s.QueueDone + 1) of $($s.QueueTotal)" + $(if ($s.EtaSeconds -and -not $script:Paused) { "  $([char]0x00B7)  $(Format-Eta $s.EtaSeconds) left" } else { '' })
        $W.NowFree.Visibility = 'Collapsed'
        $W.NowThumb.Source = Get-Thumb $dir
    }
    else {
        $W.NowGame.Text = ''
        $noEnc = -not $scanning -and $s -and $s.State -eq 'noencoder'
        $W.NowTitle.Text = if ($scanning) { 'Checking recordings...' } elseif ($noEnc) { 'No hardware encoder found' } elseif ($pending -eq 0) { 'All caught up' } else { 'Ready' }
        $W.NowSub.Text = if ($noEnc) { "This PC's graphics card has no AV1 or HEVC hardware encoder that works, so nothing can be compressed. ReLive Compressor needs an AMD Radeon RX 400 series or newer GPU with an up-to-date driver." }
                         elseif ($null -eq $pending) { '' }
                         elseif ($pending -eq 0) { 'Every recording is already compressed. New clips are picked up automatically.' }
                         elseif ($st.Mode -eq 'Test') { "$(Format-Count $pending 'recording') without a test copy yet. 'Make test copies' makes up to $($st.TestCount) copies in $($st.TestFolder) - or choose exactly which videos to try." }
                         else {
                             $what = "$(Format-Count $pending 'recording') ($($s.PendingGB) GB) waiting."
                             $tested = [int]$s.PendingTested
                             if ($tested) { $what += " $(if ($tested -eq $pending) { $(if ($tested -eq 1) { 'It has' } else { 'They have' }) } else { "$tested of them have" }) a test copy, but the original itself hasn't been compressed yet." }
                             if ($st.AutoEnabled) { "$what They're compressed automatically after $($st.IdleMinutes) idle minutes. To start right now, press Compress all waiting, or choose videos." }
                             else { "$what Compress all waiting starts right now. Automatic compression (left) does it for you while you're away." }
                         }
        $W.NowBar.Value = 0; $W.NowPct.Text = ''; $W.NowCount.Text = ''
        $W.NowThumb.Source = $null
        # the headline: how much space the waiting recordings would give back
        $freeGB = if ($pending -and $st.Mode -ne 'Test' -and -not $noEnc) { [math]::Round([double]$s.PendingGB * (1 - $script:SaveRatio), 1) } else { 0 }
        $W.NowFree.Visibility = if ($freeGB -ge 0.1) { 'Visible' } else { 'Collapsed' }
        $W.NowFree.Text = "You could free about $freeGB GB"
    }
    $W.BtnRun.Content = if ($running) { 'Stop' } elseif ($st.Mode -eq 'Test') { 'Make test copies' } elseif ($pending) { "Compress all waiting ($pending)" } else { 'Compress all waiting' }
    $W.BtnChoose.Visibility = if ($running) { 'Collapsed' } else { 'Visible' }
    if ($script:Page -eq 'Compress') { Update-CompressLive }
    $W.BtnPause.IsEnabled = $running
    $W.BtnPause.Visibility = if ($running) { 'Visible' } else { 'Collapsed' }   # only one of Choose videos / Pause at a time, so the buttons fit
    $W.BtnPause.Content = if ($script:Paused) { 'Resume' } else { 'Pause' }

    # encoder card
    $W.EncGpu.Text = $script:Gpu
    $W.EncCodec.Text = if ($s -and $s.State -eq 'noencoder') { 'None available' } elseif ($s -and $s.Encoder) { "$codecName (hardware)" } else { '-' }
    $W.EncRate.Text = "$mbps Mbps (peak $([math]::Round($mbps * 1.6)))"
    $W.EncPreset.Text = (Get-Culture).TextInfo.ToTitleCase([string]$st.Preset)
    $W.EncMode.Text = switch ($st.Mode) { 'Replace' { if ($st.RecycleOriginals) { 'Replace - to Recycle Bin after check' } else { 'Replace - deleted after check' } } 'Move' { "Move to $($st.MoveFolder)" } default { 'Test - kept, copies made' } }

    if ($Heavy -or ((Get-Date) - $script:LastHeavyRefresh).TotalSeconds -ge 30) { Update-HomeStats }
}

function Update-HomeStats {
    $script:LastHeavyRefresh = Get-Date
    $script:SaveRatio = Get-SaveRatio
    $W = $script:W; $s = $script:Status
    $clips = @(Get-Clips)
    $total = ($clips | Measure-Object Size -Sum).Sum
    $done = @($clips | Where-Object Done).Count
    $W.StTotal.Text = Format-Size $total
    $W.StTotalSub.Text = "$($clips.Count) recordings"
    $W.StBar.Value = if ($clips.Count) { 100 * $done / $clips.Count } else { 0 }
    $W.StBarText.Text = "$done of $($clips.Count) compressed"

    $rows = Get-LogRows
    $done = @($rows | Where-Object { $_.Result -in 'OK', 'OK-MOVED' })
    $savedMB = ($done | ForEach-Object { [double]$_.OrigMB - [double]$_.NewMB } | Measure-Object -Sum).Sum
    $W.StSaved.Text = Format-Size ($savedMB * 1MB)
    $W.StWaiting.Text = if ($s -and $null -ne $s.Pending) { Format-Count ([int]$s.Pending) 'clip' } else { '-' }

    $recent = @($rows | Where-Object { $_.Result -in 'OK', 'OK-MOVED', 'TEST-OK' } | Select-Object -Last 6)
    [array]::Reverse($recent)
    $W.RecentList.ItemsSource = @($recent | ForEach-Object { ConvertTo-Row $_ })
    $W.RecentEmpty.Visibility = if ($recent.Count) { 'Collapsed' } else { 'Visible' }
}

# ---------- Compress page: pick recordings and compress them now ----------
function New-Chip($clip, [string]$text, [string]$bg, [string]$fg, [bool]$canSelect, [string]$tip = '') {
    $clip.Status = $text; $clip.ChipBg = $bg; $clip.ChipFg = $fg; $clip.CanSelect = $canSelect; $clip.StatusTip = $tip
}

function Update-CompressPage {
    $W = $script:W; $st = $script:Settings; $s = $script:Status
    # keep what was ticked and opened across refreshes
    $checked = @{}; $expanded = @{}
    foreach ($g in @($script:CmpGroups)) {
        if (-not $g) { continue }
        $expanded[$g.Path] = $g.IsExpanded
        foreach ($c in $g.Clips) { if ($c.IsChecked) { $checked[$c.Path] = $true } }
    }
    $last = @{}
    foreach ($r in Get-LogRows) { $last[$r.File] = $r }
    $running = (Test-WorkerRunning) -and $script:RunKind -ne 'scan'
    $current = if ($running -and $s) { [string]$s.File } else { '' }
    $inRun = @{}
    if ($running) { foreach ($p in @($script:RunFiles) + @($script:QueuedFiles)) { if ($p) { $inRun[$p] = $true } } }
    $script:CmpLastFile = $current

    $clips = New-Object Collections.Generic.List[object]
    foreach ($c in Get-Clips) { $clips.Add($c) }
    $known = @{}; foreach ($c in $clips) { $known[$c.Path] = $true }
    # videos added from outside the recordings folder get their own group at the top
    foreach ($p in $script:AddedFiles) {
        if ($known[$p] -or -not (Test-Path -LiteralPath $p)) { continue }
        $clips.Add([pscustomobject]@{ Path = $p; Dir = '*'; Size = (Get-Item -LiteralPath $p).Length; Codec = ''; Done = $false })
    }

    $groups = New-Object Collections.Generic.List[object]
    $waitAll = 0; $waitBytes = 0
    foreach ($grp in ($clips | Group-Object Dir | Sort-Object { if ($_.Name -eq '*') { '' } else { Get-GameName $_.Name } })) {
        $g = New-Object RlcGroup
        $g.Path = $grp.Name
        $g.Name = if ($grp.Name -eq '*') { 'Added videos' } else { Get-GameName $grp.Name }
        $g.Initial = $g.Name.Substring(0, 1).ToUpper()
        if ($grp.Name -ne '*') { $g.Thumb = Get-Thumb $grp.Name }
        $list = New-Object 'Collections.Generic.List[RlcClip]'
        foreach ($item in ($grp.Group | Sort-Object { [IO.File]::GetLastWriteTime($_.Path) } -Descending)) {
            $c = New-Object RlcClip
            $c.Path = $item.Path
            $c.Name = [IO.Path]::GetFileNameWithoutExtension($item.Path)
            $c.Recorded = [IO.File]::GetLastWriteTime($item.Path).ToString('dd MMM yyyy  HH:mm')
            $c.Bytes = [double]$item.Size; $c.Size = Format-Size $item.Size
            $c.NameColor = '#EDEDED'
            $r = $last[$item.Path]
            $reason = if ($r) { Get-RowReason $r } else { $null }
            if ($current -and $item.Path -eq $current) { New-Chip $c 'Compressing now' '#16301D' '#3FB950' $false }
            elseif ($inRun[$item.Path]) { New-Chip $c 'In the queue' '#16301D' '#3FB950' $false }
            elseif ($item.Done -or ($r -and $r.Result -in 'OK', 'OK-MOVED')) { New-Chip $c 'Compressed' '#262626' '#8E8E8E' $false; $c.NameColor = '#8A8A8A' }
            elseif ($r -and $r.Result -eq 'FAILED') { New-Chip $c 'Failed - tick to try again' '#3A1518' '#F85149' $true $ReasonText[$reason].Text }
            elseif ($r -and $r.Result -eq 'KEPT' -and $reason -eq 'RECYCLE_TOO_BIG') { New-Chip $c 'Kept (too big for Recycle Bin)' '#3A2E12' '#D29922' $true $ReasonText[$reason].Text }
            elseif ($r -and $r.Result -eq 'KEPT') { New-Chip $c 'Already small' '#262626' '#8E8E8E' $false $ReasonText['SMALL'].Text; $c.NameColor = '#8A8A8A' }
            elseif ($r -and $r.Result -eq 'TEST-OK' -and $st.Mode -eq 'Test') { New-Chip $c 'Test copy made' '#132A40' '#58A6FF' $false; $c.NameColor = '#8A8A8A' }
            elseif ($r -and $r.Result -eq 'TEST-OK') { New-Chip $c 'Waiting (has a test copy)' '#132A40' '#58A6FF' $true 'A test copy was made earlier; the original itself is not compressed yet.' }
            elseif ($r -and $r.Result -eq 'SKIPPED' -and $reason -ne 'ALREADY') { New-Chip $c 'Waiting (will retry)' '#3A2E12' '#D29922' $true $ReasonText[$reason].Text }
            elseif ($r -and $reason -eq 'ALREADY') { New-Chip $c 'Compressed' '#262626' '#8E8E8E' $false; $c.NameColor = '#8A8A8A' }
            else { New-Chip $c 'Waiting' '#3A2E12' '#D29922' $true }
            $c.Owner = $g
            if ($c.CanSelect -and $checked[$c.Path]) { $c.IsChecked = $true }
            $list.Add($c)
        }
        $g.Clips = $list
        $wait = @($list | Where-Object CanSelect)
        $waitAll += $wait.Count
        $wb = ($wait | Measure-Object Bytes -Sum).Sum; $waitBytes += $wb
        $g.Counts = if ($wait.Count) { "$($wait.Count) of $($list.Count) waiting  $([char]0x00B7)  $(Format-Size $wb)" } else { "All $($list.Count) done" }
        $g.IsExpanded = if ($expanded.ContainsKey($g.Path)) { $expanded[$g.Path] } else { $wait.Count -gt 0 -or $grp.Name -eq '*' }
        $groups.Add($g)
    }
    $script:CmpGroups = $groups.ToArray()   # a plain array: @() on a List of these objects fails in PowerShell 5.1
    $W.CmpList.ItemsSource = $script:CmpGroups
    $W.CmpEmpty.Visibility = if ($groups.Count) { 'Collapsed' } else { 'Visible' }
    $W.CmpSummary.Text = "$(Format-Count $waitAll 'recording') waiting  $([char]0x00B7)  $(Format-Size $waitBytes)  $([char]0x00B7)  $(Format-Count $clips.Count 'recording') in total"
    Update-CompressTotals
}

function Get-CompressSelection { @($script:CmpGroups | ForEach-Object { if ($_) { $_.Clips } } | Where-Object { $_.CanSelect -and $_.IsChecked }) }

function Update-CompressTotals {
    $sel = Get-CompressSelection
    $bytes = ($sel | Measure-Object Bytes -Sum).Sum
    $script:W.CmpSel.Text = if ($sel.Count) { "$(Format-Count $sel.Count 'video') selected  $([char]0x00B7)  $(Format-Size $bytes)  $([char]0x2192)  about $(Format-Size ($bytes * $script:SaveRatio))" }
                            else { 'Nothing selected - tick the videos you want to compress' }
    $script:CmpSelCount = $sel.Count
    Update-CompressLive
}

# the bottom bar: where originals go, start / add / stop, live progress. Runs every 2 s while the page is open.
function Update-CompressLive {
    $W = $script:W; $st = $script:Settings; $s = $script:Status
    $running = (Test-WorkerRunning) -and $script:RunKind -ne 'scan'
    # a new file started: refresh the list so its status moves along
    if ($running -and $s -and $s.File -and [string]$s.File -ne $script:CmpLastFile) { Update-CompressPage; return }
    $W.CmpMode.Text = switch ($st.Mode) {
        'Test'    { "Originals are kept. Test copies go to $($st.TestFolder)" }
        'Move'    { "Originals are moved to $($st.MoveFolder) after each video is checked (Move mode)" }
        default   { if ($st.RecycleOriginals) { 'Originals go to the Recycle Bin after each video is checked (Replace mode)' } else { 'Originals are deleted after each video is checked (Replace mode)' } }
    }
    $n = [int]$script:CmpSelCount
    $W.CmpStop.Visibility = if ($running) { 'Visible' } else { 'Collapsed' }
    $W.CmpPause.Visibility = $W.CmpStop.Visibility
    $W.CmpPause.Content = if ($script:Paused) { 'Resume' } else { 'Pause' }
    $W.CmpStart.IsEnabled = $n -gt 0
    if ($running) {
        $W.CmpStartGlyph.Text = [string][char]0xE710
        $W.CmpStartText.Text = if ($n) { "Add $n to the queue" } else { 'Add to the queue' }
        $W.CmpNote.Text = 'Running now. Videos you add start when the current ones are done.'
        $live = if ($s -and $s.File) {
            $eta = if ($s.EtaSeconds -and -not $script:Paused) { "  $([char]0x00B7)  $(Format-Eta $s.EtaSeconds) left" } else { '' }
            "$(if ($script:Paused) { 'Paused' } else { 'Compressing' }) $([int]$s.QueueDone + 1) of $($s.QueueTotal)  $([char]0x00B7)  $([math]::Round([double]$s.Percent))%$eta  $([char]0x00B7)  $([IO.Path]::GetFileNameWithoutExtension($s.File))"
        } else { 'Starting...' }
        $W.CmpLive.Text = $live
        $W.CmpLive.Foreground = if ($script:Paused) { '#D29922' } else { '#3FB950' }
        $W.CmpLive.Visibility = 'Visible'; $W.CmpBar.Visibility = 'Visible'
        $W.CmpBar.Value = if ($s) { [double]$s.Percent } else { 0 }
    }
    else {
        $W.CmpStartGlyph.Text = [string][char]0xE768
        $W.CmpStartText.Text = if ($n) { "Start compressing ($n)" } else { 'Start compressing' }
        $W.CmpNote.Text = 'Runs right now, even while you use the PC. Pause or stop anytime.'
        $W.CmpLive.Visibility = 'Collapsed'; $W.CmpBar.Visibility = 'Collapsed'
    }
}

function Start-CompressSelection {
    $sel = Get-CompressSelection
    if (-not $sel.Count) { return }
    Start-SelectedCompression @($sel | ForEach-Object Path)
    foreach ($c in $sel) { $c.IsChecked = $false }
    Update-CompressPage
}

# Explorer's right-click menu and drag and drop: compress these files (or the .mp4 files in these folders) now
function Add-VideosFromPaths([string[]]$paths) {
    $files = @(foreach ($p in $paths) {
        if (-not $p) { continue }
        if (Test-Path -LiteralPath $p -PathType Container) { Get-ChildItem -LiteralPath $p -Recurse -File -Filter '*.mp4' | ForEach-Object FullName }
        elseif ($p -like '*.mp4' -and (Test-Path -LiteralPath $p)) { (Get-Item -LiteralPath $p).FullName }
    }) | Select-Object -Unique
    if (-not $files.Count) { Show-Balloon 'Only .mp4 videos can be compressed.'; return }
    $base = ([string]$script:Settings.RecordingsFolder).TrimEnd('\') + '\'
    $outside = @($files | Where-Object { -not $_.StartsWith($base, [StringComparison]::OrdinalIgnoreCase) })
    $script:AddedFiles = @(@($script:AddedFiles) + $outside | Select-Object -Unique)
    Start-SelectedCompression $files
    Show-MainWindow 'Compress'
}

# ---------- Recycle Bin option ----------
function New-RecycleCheck {
    $cb = New-Object Windows.Controls.CheckBox
    $cb.Style = $script:Win.Resources['DarkCheck']; $cb.Margin = '0,4,0,0'
    $cb.Content = 'Send originals to the Recycle Bin instead of deleting them (recommended)'
    $cb.IsChecked = if ($null -ne $script:Settings.RecycleOriginals) { [bool]$script:Settings.RecycleOriginals } else { $true }
    $cb
}

function Show-RecycleInfo {
    $p = New-Object Windows.Controls.StackPanel
    [void]$p.Children.Add((New-Text "In Replace mode the original recording is removed once its compressed copy has been checked. With this option on, it goes to the Recycle Bin instead of being deleted for good."))
    [void]$p.Children.Add((New-Text 'WHY USE IT' 11 '#8E8E8E' '0,6,0,4'))
    [void]$p.Children.Add((New-Text "$([char]0x2022)  A safety net: if you don't like how a compressed video turned out, restore the original from the Recycle Bin (right-click it > Restore). It goes back to the same folder with the same name; delete the compressed copy first."))
    [void]$p.Children.Add((New-Text 'GOOD TO KNOW' 11 '#8E8E8E' '0,6,0,4'))
    [void]$p.Children.Add((New-Text "$([char]0x2022)  The space is only freed once the Recycle Bin is emptied - by you, or automatically by Windows Storage Sense.`n$([char]0x2022)  Windows limits how big the Recycle Bin can get (about 5% of the drive unless changed). Recordings bigger than that limit can't go there, so they are kept untouched and listed in Activity, never deleted for good.`n$([char]0x2022)  When the Recycle Bin is full, Windows removes its oldest items to make room." 13 '#C8C8C8' '0'))
    [void](Show-RlcDialog (New-RlcDialog 'Recycle Bin safety net' $p @(@{ Text = 'Got it'; Value = 'ok'; Style = 'BtnPrimary' }) 600))
}

# ---------- before / after ----------
# The worker saves one frame of the original and the same frame of the compressed copy (Save-CompareFrames).
# For clips without saved frames whose original still exists (Test and Move mode), they are made now.
function Show-Compare([string]$original) {
    $a = Get-ComparePath $original 'a'; $b = Get-ComparePath $original 'b'
    $row = Get-LogRows | Where-Object { $_.File -eq $original -and $_.Result -in 'OK', 'OK-MOVED', 'TEST-OK' } | Select-Object -Last 1
    if (-not ((Test-Path -LiteralPath $a) -and (Test-Path -LiteralPath $b))) {
        $base = ([string]$script:Settings.RecordingsFolder).TrimEnd('\') + '\'
        $rel = if ($original.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) { $original.Substring($base.Length) } else { Split-Path $original -Leaf }
        $pair = switch ($row.Result) {
            'TEST-OK'  { @($original, (Join-Path $script:Settings.TestFolder $rel)) }
            'OK-MOVED' { @((Join-Path $script:Settings.MoveFolder $rel), $original) }
        }
        if ($pair -and (Test-Path -LiteralPath $pair[0]) -and (Test-Path -LiteralPath $pair[1])) {
            $ff = if (Test-Path ([string]$script:Settings.FFmpegPath)) { $script:Settings.FFmpegPath } else { Join-Path $AppDir 'ffmpeg.exe' }
            New-Item -ItemType Directory -Force (Split-Path $a) | Out-Null
            foreach ($x in @(@($pair[0], $a), @($pair[1], $b))) {
                $psi = New-Object Diagnostics.ProcessStartInfo $ff, "-hide_banner -nostdin -loglevel error -ss 8 -i `"$($x[0])`" -frames:v 1 -q:v 1 -y `"$($x[1])`""
                $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
                $proc = [Diagnostics.Process]::Start($psi); [void]$proc.WaitForExit(30000)
            }
        }
    }
    if (-not ((Test-Path -LiteralPath $a) -and (Test-Path -LiteralPath $b))) {
        [void](Show-RlcMessage 'Before / after' "No comparison was saved for this video.`n`nFrames are saved for videos compressed with version 1.6 or newer (the newest 20 are kept). In Test and Move mode they can also be made later, while the original still exists.")
        return
    }
    $imgs = foreach ($f in $a, $b) {
        $bmp = New-Object Windows.Media.Imaging.BitmapImage
        $bmp.BeginInit(); $bmp.CacheOption = 'OnLoad'; $bmp.UriSource = New-Object Uri $f; $bmp.EndInit(); $bmp.Freeze(); $bmp
    }
    $w = [double]$imgs[0].PixelWidth; $h = [double]$imgs[0].PixelHeight
    $vw = 1024.0; $vh = [math]::Round($vw * $h / $w)

    $canvas = New-Object Windows.Controls.Canvas; $canvas.Width = $w; $canvas.Height = $h
    $imgB = New-Object Windows.Controls.Image; $imgB.Source = $imgs[1]; $imgB.Width = $w; $imgB.Height = $h
    $imgA = New-Object Windows.Controls.Image; $imgA.Source = $imgs[0]; $imgA.Width = $w; $imgA.Height = $h
    $clip = New-Object Windows.Media.RectangleGeometry (New-Object Windows.Rect 0, 0, ($w / 2), $h); $imgA.Clip = $clip
    $line = New-Object Windows.Shapes.Rectangle; $line.Fill = 'White'; $line.Height = $h
    [void]$canvas.Children.Add($imgB); [void]$canvas.Children.Add($imgA); [void]$canvas.Children.Add($line)
    $scale = New-Object Windows.Media.ScaleTransform; $move = New-Object Windows.Media.TranslateTransform
    $tg = New-Object Windows.Media.TransformGroup; $tg.Children.Add($scale); $tg.Children.Add($move); $canvas.RenderTransform = $tg

    $view = New-Object Windows.Controls.Border; $view.Width = $vw; $view.Height = $vh; $view.ClipToBounds = $true; $view.Background = '#000000'; $view.Cursor = 'SizeWE'
    $grid = New-Object Windows.Controls.Grid; [void]$grid.Children.Add($canvas)
    $origMB = [double]$row.OrigMB; $newMB = [double]$row.NewMB
    foreach ($lbl in @(@("ORIGINAL  $([char]0x00B7)  $(Format-Size ($origMB * 1MB))", 'Left'), @("COMPRESSED  $([char]0x00B7)  $(Format-Size ($newMB * 1MB))$(if ($origMB) { "  (-$([math]::Round(100 * (1 - $newMB / $origMB)))%)" })", 'Right'))) {
        $tb = New-Object Windows.Controls.Border; $tb.Background = '#C0000000'; $tb.Padding = '10,5'; $tb.Margin = '10'
        $tb.HorizontalAlignment = $lbl[1]; $tb.VerticalAlignment = 'Top'; $tb.IsHitTestVisible = $false
        $tt = New-Object Windows.Controls.TextBlock; $tt.Text = $lbl[0]; $tt.FontSize = 12; $tt.FontWeight = 'SemiBold'; $tt.Foreground = 'White'; $tb.Child = $tt
        [void]$grid.Children.Add($tb)
    }
    # round grab handle on the divider (in view space, so it keeps its size when zoomed)
    $handle = New-Object Windows.Controls.Border
    $handle.Width = 34; $handle.Height = 34; $handle.CornerRadius = 17; $handle.Background = 'White'
    $handle.HorizontalAlignment = 'Left'; $handle.VerticalAlignment = 'Center'; $handle.IsHitTestVisible = $false
    $hg = New-Object Windows.Controls.TextBlock; $hg.Text = "$([char]0x25C0) $([char]0x25B6)"; $hg.FontSize = 10; $hg.Foreground = '#1C1C1C'
    $hg.HorizontalAlignment = 'Center'; $hg.VerticalAlignment = 'Center'; $handle.Child = $hg
    $handle.Effect = New-Object Windows.Media.Effects.DropShadowEffect -Property @{ BlurRadius = 8; ShadowDepth = 0; Opacity = 0.6 }
    [void]$grid.Children.Add($handle)
    $view.Child = $grid
    $script:Cmp = @{ W = $w; H = $h; VW = $vw; VH = $vh; Split = $w / 2; Zoom = $false; Scale = $scale; Move = $move; Clip = $clip; Line = $line; View = $view; PanFrom = $null; Handle = $handle }

    $view.Add_MouseLeftButtonDown({ param($s, $e) [void]$s.CaptureMouse(); Set-CompareSplit $e.GetPosition($s) })
    $view.Add_MouseLeftButtonUp({ param($s, $e) $s.ReleaseMouseCapture() })
    $view.Add_MouseRightButtonDown({ param($s, $e) if ($script:Cmp.Zoom) { [void]$s.CaptureMouse(); $script:Cmp.PanFrom = $e.GetPosition($s) } })
    $view.Add_MouseRightButtonUp({ param($s, $e) $s.ReleaseMouseCapture(); $script:Cmp.PanFrom = $null; $e.Handled = $true })
    $view.Add_MouseMove({
        param($s, $e)
        $pos = $e.GetPosition($s)
        if ($e.LeftButton -eq 'Pressed') { Set-CompareSplit $pos }
        elseif ($e.RightButton -eq 'Pressed' -and $script:Cmp.PanFrom) {
            Set-ComparePan ($script:Cmp.Move.X + $pos.X - $script:Cmp.PanFrom.X) ($script:Cmp.Move.Y + $pos.Y - $script:Cmp.PanFrom.Y)
            $script:Cmp.PanFrom = $pos
        }
    })

    $bar = New-Object Windows.Controls.DockPanel; $bar.Margin = '0,10,0,0'
    $zoom = New-Object Windows.Controls.Button; $zoom.Style = $script:Win.Resources['BtnSmall']; $zoom.Content = 'Zoom to 100%'
    [Windows.Controls.DockPanel]::SetDock($zoom, 'Right'); [void]$bar.Children.Add($zoom)
    $script:Cmp.ZoomBtn = $zoom
    $zoom.Add_Click({
        $c = $script:Cmp; $c.Zoom = -not $c.Zoom
        $c.ZoomBtn.Content = if ($c.Zoom) { 'Fit to window' } else { 'Zoom to 100%' }
        Update-CompareView
        if ($c.Zoom) { Set-ComparePan ($c.VW / 2 - $c.Split) ($c.VH / 2 - $c.H / 2) }
    })
    [void]$bar.Children.Add((New-Text "Drag across the picture to move the divider: original on the left, compressed on the right. Zoom in for a closer look (right-drag to move around)." 12 '#8E8E8E' '0'))

    $p = New-Object Windows.Controls.StackPanel
    [void]$p.Children.Add($view); [void]$p.Children.Add($bar)
    Update-CompareView
    [void](Show-RlcDialog (New-RlcDialog "Before / after: $([IO.Path]::GetFileNameWithoutExtension($original))" $p @(@{ Text = 'Close'; Value = 'ok'; Style = 'BtnPrimary' }) ([int]$vw + 42)))
}

function Update-CompareView {
    $c = $script:Cmp
    $s = if ($c.Zoom) { 1.0 } else { $c.VW / $c.W }
    $c.Scale.ScaleX = $s; $c.Scale.ScaleY = $s
    if (-not $c.Zoom) { $c.Move.X = 0; $c.Move.Y = 0 }
    $c.Line.Width = 3 / $s
    Set-CompareSplitAt $c.Split
}

function Set-CompareSplit($viewPos) {
    $c = $script:Cmp
    Set-CompareSplitAt (($viewPos.X - $c.Move.X) / $c.Scale.ScaleX)
}

function Set-CompareSplitAt([double]$x) {
    $c = $script:Cmp
    $c.Split = [math]::Max(0, [math]::Min($c.W, $x))
    $c.Clip.Rect = New-Object Windows.Rect 0, 0, $c.Split, $c.H
    [Windows.Controls.Canvas]::SetLeft($c.Line, $c.Split - $c.Line.Width / 2)
    $c.Handle.Margin = New-Object Windows.Thickness (($c.Split * $c.Scale.ScaleX + $c.Move.X) - 17), 0, 0, 0
}

function Set-ComparePan([double]$x, [double]$y) {
    $c = $script:Cmp
    $c.Move.X = [math]::Min(0, [math]::Max($c.VW - $c.W, $x))
    $c.Move.Y = [math]::Min(0, [math]::Max($c.VH - $c.H, $y))
    Set-CompareSplitAt $c.Split   # keeps the handle on the divider
}

# ---------- updates ----------
function Update-VersionText {
    if (-not $script:W.SetVersion) { return }
    $v = "ReLive Compressor $AppVersion"
    $script:W.SetVersion.Text = switch ($script:UpdateState) {
        'checking'  { "$v  $([char]0x00B7)  checking for updates..." }
        'current'   { "$v  $([char]0x00B7)  up to date" }
        'available' { "$v  $([char]0x00B7)  version $($script:Update.version) is available" }
        'error'     { if ($script:ManualCheck) { "$v  $([char]0x00B7)  couldn't reach GitHub, try again later" } else { $v } }
        default     { $v }
    }
}

# Downloads the new Setup.exe from GitHub, checks it against update.json (size + SHA-256) and runs it in update mode.
function Invoke-UpdateInstall {
    $u = $script:Update
    if (-not $u) { return }
    $url = if ($u.url) { [string]$u.url } else { "https://github.com/$UpdateRepo/releases/download/v$($u.version)/$($u.asset)" }
    $uri = [Uri]$url
    # only ever download from GitHub (UpdateUrl is a hidden test setting)
    if (-not $script:Settings.UpdateUrl -and -not ($uri.Scheme -eq 'https' -and $uri.Host -eq 'github.com')) {
        [void](Show-RlcMessage 'Update' "This update doesn't come from the official download page, so it wasn't installed.`n`n$url"); return
    }
    if ((Test-WorkerRunning) -and $script:RunKind -ne 'scan') {
        $r = Show-RlcDialog (New-RlcDialog 'Update now?' "A video is being compressed. Updating stops it; that video starts again later and its original is untouched." @(
            @{ Text = 'Not now'; Value = 'no' }, @{ Text = 'Stop and update'; Value = 'yes'; Style = 'BtnPrimary' }))
        if ($r -ne 'yes') { return }
    }
    $dir = Join-Path $env:TEMP 'ReLiveCompressor-update'
    New-Item -ItemType Directory -Force $dir | Out-Null
    $file = Join-Path $dir "ReLiveCompressorSetup-$($u.version).exe"
    Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue

    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $wc = New-Object Net.WebClient
    $wc.Headers['User-Agent'] = "ReLiveCompressor/$AppVersion"
    $p = New-Object Windows.Controls.StackPanel
    [void]$p.Children.Add((New-Text "Downloading ReLive Compressor $($u.version) from GitHub..."))
    $pb = New-Object Windows.Controls.ProgressBar; $pb.Height = 6; $pb.Maximum = 100; [void]$p.Children.Add($pb)
    $detail = New-Text '' 12 '#8E8E8E' '0,8,0,0'; [void]$p.Children.Add($detail)
    $dlg = New-RlcDialog 'Updating' $p @(@{ Text = 'Cancel'; Value = 'cancel' }) 480
    $script:Dl = @{ Task = $wc.DownloadFileTaskAsync($uri, $file); File = $file; Size = [double]$u.size; Bar = $pb; Detail = $detail; Window = $dlg.Window }
    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(200)
    $timer.Add_Tick({
        $d = $script:Dl
        $got = if (Test-Path -LiteralPath $d.File) { (Get-Item -LiteralPath $d.File).Length } else { 0 }
        if ($d.Size -gt 0) { $d.Bar.Value = [math]::Min(100, 100 * $got / $d.Size); $d.Detail.Text = "{0:N1} of {1:N1} MB" -f ($got / 1MB), ($d.Size / 1MB) }
        if ($d.Task.IsCompleted) { $d.Window.Tag = if ($d.Task.Status -eq 'RanToCompletion') { 'done' } else { 'error' }; $d.Window.Close() }
    })
    $timer.Start()
    $result = Show-RlcDialog $dlg
    $timer.Stop()
    if ($result -ne 'done') {
        $wc.CancelAsync()
        Start-Sleep -Milliseconds 300
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
        if ($result -eq 'error') { [void](Show-RlcMessage 'Update' "The download didn't finish. Check your internet connection and try again.") }
        return
    }
    # make sure it's exactly the file that was published
    $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
    if ((Get-Item -LiteralPath $file).Length -ne [long]$u.size -or $hash -ne ([string]$u.sha256).ToUpperInvariant()) {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
        [void](Show-RlcMessage 'Update' "The downloaded file didn't match the published update, so it wasn't installed. Please try again later.")
        return
    }
    Stop-Worker
    Start-Process -FilePath $file -ArgumentList '/update'
    Exit-App
}

# ---------- welcome guide (first start) ----------
function New-WizSwitch([string]$label, [string]$sub, [bool]$on) {
    $row = New-Object Windows.Controls.DockPanel; $row.Margin = '0,6,0,6'
    $t = New-Object Windows.Controls.Primitives.ToggleButton; $t.Style = $script:Win.Resources['Switch']; $t.IsChecked = $on; $t.VerticalAlignment = 'Center'
    [Windows.Controls.DockPanel]::SetDock($t, 'Right'); [void]$row.Children.Add($t)
    $sp = New-Object Windows.Controls.StackPanel; $sp.Margin = '0,0,20,0'
    [void]$sp.Children.Add((New-Text $label 14 '#EDEDED' '0'))
    [void]$sp.Children.Add((New-Text $sub 12 '#8E8E8E' '0,3,0,0'))
    [void]$row.Children.Add($sp)
    @{ Row = $row; Toggle = $t }
}

function Show-WelcomeGuide {
    if (-not $script:Win) { Initialize-MainWindow }
    $st = $script:Settings
    $adr = Get-AdrenalinFolder
    $wz = @{ Step = 0; Folder = $(if ($adr) { $adr } else { [string]$st.RecordingsFolder }); MoveFolder = [string]$st.MoveFolder }
    $script:Wiz = $wz

    $root = New-Object Windows.Controls.DockPanel
    $stepText = New-Text '' 11 '#8E8E8E' '0,0,0,8'
    [Windows.Controls.DockPanel]::SetDock($stepText, 'Top'); [void]$root.Children.Add($stepText)
    $nav = New-Object Windows.Controls.DockPanel; $nav.Margin = '0,22,0,0'
    [Windows.Controls.DockPanel]::SetDock($nav, 'Bottom'); [void]$root.Children.Add($nav)
    $pages = New-Object Windows.Controls.Grid; [void]$root.Children.Add($pages)
    $wz.StepText = $stepText

    # step 1: recordings folder
    $p1 = New-Object Windows.Controls.StackPanel
    [void]$p1.Children.Add((New-Text 'Where are your recordings?' 17 '#EDEDED' '0,0,0,6'))
    [void]$p1.Children.Add((New-Text 'ReLive Compressor watches this folder (and its game folders) for new Radeon ReLive recordings.'))
    $box = New-Object Windows.Controls.Border; $box.Background = '#252525'; $box.Padding = '12,10'; $box.Margin = '0,6,0,6'
    $bd = New-Object Windows.Controls.DockPanel
    $chg = New-Object Windows.Controls.Button; $chg.Style = $script:Win.Resources['BtnSmall']; $chg.Content = 'Change...'; $chg.VerticalAlignment = 'Center'; $chg.Margin = '12,0,0,0'
    [Windows.Controls.DockPanel]::SetDock($chg, 'Right'); [void]$bd.Children.Add($chg)
    $folderText = New-Text '' 13.5 '#EDEDED' '0'; $folderText.VerticalAlignment = 'Center'; [void]$bd.Children.Add($folderText)
    $box.Child = $bd; [void]$p1.Children.Add($box)
    $folderInfo = New-Text '' 12.5 '#3FB950' '0,2,0,0'; [void]$p1.Children.Add($folderInfo)
    $wz.FolderText = $folderText; $wz.FolderInfo = $folderInfo; $wz.FromAdrenalin = [bool]$adr
    $chg.Add_Click({
        $d = New-Object Windows.Forms.FolderBrowserDialog; $d.SelectedPath = $script:Wiz.Folder
        if ($d.ShowDialog() -eq 'OK') { $script:Wiz.Folder = $d.SelectedPath; $script:Wiz.FromAdrenalin = $false; Update-WizFolder }
    })

    # step 2: originals
    $p2 = New-Object Windows.Controls.StackPanel
    [void]$p2.Children.Add((New-Text 'What should happen to the original recordings?' 17 '#EDEDED' '0,0,0,6'))
    [void]$p2.Children.Add((New-Text 'Each compressed video is checked first (same length, has picture and sound, smaller). Only then is the original changed. You can change this later in Settings.' 13 '#C8C8C8' '0,0,0,12'))
    $grid = New-Object Windows.Controls.Primitives.UniformGrid; $grid.Columns = 3
    $mt = New-ModeChoice 'wz' ([string][char]0xE8C8) '#58A6FF' 'Try it first' 'Originals are kept. A few compressed copies go to a test folder so you can compare. Nothing runs automatically.'
    $mr = New-ModeChoice 'wz' ([string][char]0xE74D) '#E5202E' 'Replace' 'The compressed video takes the original''s place. Saves the most space.'
    $mm = New-ModeChoice 'wz' ([string][char]0xE8DE) '#D29922' 'Move' 'The compressed video takes its place; the original is moved to another folder or drive.'
    $mt.Margin = '0,0,5,0'; $mr.Margin = '5,0'; $mm.Margin = '5,0,0,0'
    foreach ($x in $mt, $mr, $mm) { [void]$grid.Children.Add($x) }
    [void]$p2.Children.Add($grid)
    $recycle = New-RecycleCheck; $recycle.Margin = '2,14,0,0'
    [void]$p2.Children.Add($recycle)
    $moveRow = New-Object Windows.Controls.DockPanel; $moveRow.Margin = '2,12,0,0'
    $moveChg = New-Object Windows.Controls.Button; $moveChg.Style = $script:Win.Resources['BtnSmall']; $moveChg.Content = 'Change...'; $moveChg.Margin = '12,0,0,0'
    [Windows.Controls.DockPanel]::SetDock($moveChg, 'Right'); [void]$moveRow.Children.Add($moveChg)
    $moveText = New-Text '' 12.5 '#D29922' '0'; $moveText.VerticalAlignment = 'Center'; [void]$moveRow.Children.Add($moveText)
    [void]$p2.Children.Add($moveRow)
    switch ($st.Mode) { 'Replace' { $mr.IsChecked = $true } 'Move' { $mm.IsChecked = $true } default { $mt.IsChecked = $true } }
    $wz.ModeTest = $mt; $wz.ModeReplace = $mr; $wz.ModeMove = $mm; $wz.Recycle = $recycle; $wz.MoveRow = $moveRow; $wz.MoveText = $moveText
    foreach ($x in $mt, $mr, $mm) { $x.Add_Checked({ Update-WizMode }) }
    $moveChg.Add_Click({
        $d = New-Object Windows.Forms.FolderBrowserDialog; $d.SelectedPath = $script:Wiz.MoveFolder
        if ($d.ShowDialog() -eq 'OK') { $script:Wiz.MoveFolder = $d.SelectedPath; Update-WizMode }
    })

    # step 3: automatic
    $p3 = New-Object Windows.Controls.StackPanel
    [void]$p3.Children.Add((New-Text 'Compress automatically?' 17 '#EDEDED' '0,0,0,6'))
    [void]$p3.Children.Add((New-Text 'ReLive Compressor can shrink new recordings by itself while you are away from the PC, so it never slows down your games.' 13 '#C8C8C8' '0,0,0,10'))
    $auto = New-WizSwitch 'Automatic compression' 'Starts when there has been no keyboard or mouse input for a while and no fullscreen game is running. Pauses the moment you are back.' ([bool]$st.AutoEnabled -or $st.Mode -ne 'Test')
    [void]$p3.Children.Add($auto.Row)
    $idleRow = New-Object Windows.Controls.DockPanel; $idleRow.Margin = '0,4,0,6'
    $idle = New-Object Windows.Controls.ComboBox; $idle.Style = $script:Win.Resources['DarkCombo']; $idle.Width = 140; $idle.Height = 30
    foreach ($m in $IdleChoices) { [void]$idle.Items.Add("$m minutes") }
    $idle.SelectedIndex = [math]::Max(0, [array]::IndexOf($IdleChoices, [int]$st.IdleMinutes))
    $idleWrap = New-Object Windows.Controls.Border; $idleWrap.Background = '#252525'; $idleWrap.Padding = '10,0'; $idleWrap.Child = $idle
    [Windows.Controls.DockPanel]::SetDock($idleWrap, 'Right'); [void]$idleRow.Children.Add($idleWrap)
    [void]$idleRow.Children.Add((New-Text 'Start after being away for' 13 '#C8C8C8' '0,6,0,0'))
    [void]$p3.Children.Add($idleRow)
    $boot = New-WizSwitch 'Start with Windows' 'Keeps ReLive Compressor running next to the clock, so automatic compression can do its job.' ((Test-Path $StartupLnk) -or $st.FirstRun)
    [void]$p3.Children.Add($boot.Row)
    $autoNote = New-Text '' 12.5 '#D29922' '0,8,0,0'; [void]$p3.Children.Add($autoNote)
    [void]$p3.Children.Add((New-Text "Tip: to compress right away, use 'Compress all waiting' on Home, or tick videos on the Compress page. You can also right-click videos in File Explorer > Compress with ReLive Compressor." 12 '#8E8E8E' '0,12,0,0'))
    $wz.Auto = $auto.Toggle; $wz.Idle = $idle; $wz.Boot = $boot.Toggle; $wz.AutoNote = $autoNote

    $wz.Pages = @($p1, $p2, $p3)
    foreach ($pg in $wz.Pages) { [void]$pages.Children.Add($pg) }

    $skip = New-Object Windows.Controls.Button; $skip.Style = $script:Win.Resources['BtnSmall']; $skip.Content = 'Skip for now'; $skip.VerticalAlignment = 'Center'
    [Windows.Controls.DockPanel]::SetDock($skip, 'Left'); [void]$nav.Children.Add($skip)
    $right = New-Object Windows.Controls.StackPanel; $right.Orientation = 'Horizontal'; $right.HorizontalAlignment = 'Right'
    $back = New-Object Windows.Controls.Button; $back.Style = $script:Win.Resources['BtnDark']; $back.Content = 'Back'; $back.Margin = '0,0,10,0'
    $next = New-Object Windows.Controls.Button; $next.Style = $script:Win.Resources['BtnPrimary']; $next.Content = 'Next'
    [void]$right.Children.Add($back); [void]$right.Children.Add($next); [void]$nav.Children.Add($right)
    $wz.Back = $back; $wz.Next = $next
    $skip.Add_Click({ param($s) $w = [Windows.Window]::GetWindow($s); $w.Tag = 'skip'; $w.Close() })
    $back.Add_Click({ $script:Wiz.Step--; Update-WizPage })
    $next.Add_Click({
        param($s)
        if ($script:Wiz.Step -lt 2) { $script:Wiz.Step++; Update-WizPage }
        else { $w = [Windows.Window]::GetWindow($s); $w.Tag = 'finish'; $w.Close() }
    })

    Update-WizFolder; Update-WizMode; Update-WizPage
    $dlg = New-RlcDialog 'Welcome to ReLive Compressor' $root @() 660
    $result = Show-RlcDialog $dlg

    $st.FirstRun = $false
    if ($result -eq 'finish') {
        $folderChanged = $wz.Folder -ne $st.RecordingsFolder
        $st.RecordingsFolder = $wz.Folder
        $st.MoveFolder = $wz.MoveFolder
        $st.Mode = if ($wz.ModeReplace.IsChecked) { 'Replace' } elseif ($wz.ModeMove.IsChecked) { 'Move' } else { 'Test' }
        Set-Setting 'RecycleOriginals' ([bool]$wz.Recycle.IsChecked)
        $st.IdleMinutes = $IdleChoices[[math]::Max(0, $wz.Idle.SelectedIndex)]
        $st.AutoEnabled = [bool]$wz.Auto.IsChecked -and $st.Mode -ne 'Test'
        Save-Settings
        Set-StartWithWindows ([bool]$wz.Boot.IsChecked)
        if ($folderChanged -and -not (Test-WorkerRunning)) { $script:ThumbCache = @{}; Start-Worker 'scan' }
    }
    else { Save-Settings }
    Sync-SettingsControls; Update-Ui; Update-MainWindow -Heavy
}

function Update-WizPage {
    $wz = $script:Wiz
    for ($i = 0; $i -lt 3; $i++) { $wz.Pages[$i].Visibility = if ($i -eq $wz.Step) { 'Visible' } else { 'Hidden' } }
    $wz.StepText.Text = "STEP $($wz.Step + 1) OF 3"
    $wz.Back.Visibility = if ($wz.Step -gt 0) { 'Visible' } else { 'Collapsed' }
    $wz.Next.Content = if ($wz.Step -lt 2) { 'Next' } else { 'Finish' }
    if ($wz.Step -eq 2) { Update-WizMode }
}

function Update-WizFolder {
    $wz = $script:Wiz
    $wz.FolderText.Text = $wz.Folder
    if (-not (Test-Path -LiteralPath $wz.Folder)) {
        $wz.FolderInfo.Text = "This folder doesn't exist yet. Pick the folder Radeon ReLive saves to (AMD Software > Record & Stream > Settings)."
        $wz.FolderInfo.Foreground = '#D29922'; return
    }
    $files = @(Get-ChildItem -LiteralPath $wz.Folder -Recurse -File -Filter '*.mp4' -ErrorAction SilentlyContinue)
    $size = ($files | Measure-Object Length -Sum).Sum
    $src = if ($wz.FromAdrenalin) { 'Found in your AMD Software settings. ' } else { '' }
    $wz.FolderInfo.Text = "$src$(Format-Count $files.Count 'recording') ($(Format-Size $size)) in this folder."
    $wz.FolderInfo.Foreground = '#3FB950'
}

function Update-WizMode {
    $wz = $script:Wiz
    $wz.Recycle.IsEnabled = [bool]$wz.ModeReplace.IsChecked
    $wz.Recycle.Visibility = if ($wz.ModeReplace.IsChecked) { 'Visible' } else { 'Collapsed' }
    $wz.MoveRow.Visibility = if ($wz.ModeMove.IsChecked) { 'Visible' } else { 'Collapsed' }
    $wz.MoveText.Text = "Originals are moved to: $($wz.MoveFolder)"
    $test = [bool]$wz.ModeTest.IsChecked
    $wz.Auto.IsEnabled = -not $test
    if ($test) { $wz.Auto.IsChecked = $false }
    $wz.AutoNote.Text = if ($test) { "Automatic compression is off while you're trying it out. Once you're happy with the test copies, pick Replace or Move in Settings and turn it on." } else { '' }
}

function Update-Activity {
    $rows = @(Get-LogRows)
    $list = New-Object Collections.Generic.List[object]
    for ($i = $rows.Count - 1; $i -ge 0; $i--) { $list.Add((ConvertTo-Row $rows[$i])) }
    $script:W.ActList.ItemsSource = $list
    $script:W.ActEmpty.Visibility = if ($rows.Count) { 'Collapsed' } else { 'Visible' }
    $ok = @($rows | Where-Object { $_.Result -in 'OK', 'OK-MOVED' })
    $savedMB = ($ok | ForEach-Object { [double]$_.OrigMB - [double]$_.NewMB } | Measure-Object -Sum).Sum
    $failed = @($rows | Where-Object Result -eq 'FAILED').Count
    $script:W.ActSummary.Text = "$($ok.Count) compressed  ·  $(Format-Size ($savedMB * 1MB)) saved  ·  $failed failed"
}

# after a run finishes, refresh whatever page is open
function Update-MainWindowAfterRun {
    if (-not $script:Win -or -not $script:Win.IsVisible) { return }
    $script:ThumbCache = @{}
    switch ($script:Page) { 'Compress' { Update-CompressPage } 'Activity' { Update-Activity } }
    Update-MainWindow -Heavy
}
