# Draws the app logo (red tile with the white "compress" arrows, as in the window's top bar)
# and writes a multi-size .ico. Sizes up to 128 are stored as 32-bit BMP, 256 as PNG.
#   powershell -File Make-Icon.ps1 -Out ..\ReLive` Compressor\ReLiveCompressor.ico [-PreviewPng logo.png]
param(
    [Parameter(Mandatory)] [string]$Out,
    [string]$PreviewPng
)
Add-Type -AssemblyName System.Drawing

# same glyph as MainWindow.xaml and Setup.cs (24x24 units): a play button squeezed by two arrows
$Arrows   = @(@(1, 1, 6.2, 6.2), @(6.2, 2.6, 6.2, 6.2), @(6.2, 6.2, 2.6, 6.2), @(23, 23, 17.8, 17.8), @(17.8, 21.4, 17.8, 17.8), @(17.8, 17.8, 21.4, 17.8))
$Circle   = @(12, 12, 5.9)                        # centre x, y, radius
$Triangle = @(9.9, 8.4, 9.9, 15.6, 16, 12)        # play symbol

function New-LogoBitmap([int]$size) {
    $bmp = New-Object Drawing.Bitmap $size, $size, ([Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.PixelOffsetMode = 'HighQuality'
    $g.Clear([Drawing.Color]::Transparent)

    # tile with slightly rounded corners
    $r = [math]::Max(1.0, $size * 0.06)
    $path = New-Object Drawing.Drawing2D.GraphicsPath
    $w = $size - 0.0
    $path.AddArc(0, 0, 2 * $r, 2 * $r, 180, 90)
    $path.AddArc($w - 2 * $r, 0, 2 * $r, 2 * $r, 270, 90)
    $path.AddArc($w - 2 * $r, $w - 2 * $r, 2 * $r, 2 * $r, 0, 90)
    $path.AddArc(0, $w - 2 * $r, 2 * $r, 2 * $r, 90, 90)
    $path.CloseFigure()
    $g.FillPath((New-Object Drawing.SolidBrush ([Drawing.ColorTranslator]::FromHtml('#E5202E'))), $path)

    # glyph fills the tile, so the arrows start at its corners (a little more margin on big icons)
    $t = [math]::Min(1.0, [math]::Max(0.0, ($size - 16) / (128 - 16)))
    $frac = 0.97 - 0.06 * $t
    $k = $size * $frac / 24
    $off = ($size - 24 * $k) / 2
    $pen = New-Object Drawing.Pen ([Drawing.Color]::White), ([math]::Max(1.3, 2.0 * $k))
    $pen.StartCap = 'Round'; $pen.EndCap = 'Round'; $pen.LineJoin = 'Round'
    foreach ($l in $Arrows) {
        $g.DrawLine($pen, [single]($off + $l[0] * $k), [single]($off + $l[1] * $k), [single]($off + $l[2] * $k), [single]($off + $l[3] * $k))
    }
    $ring = New-Object Drawing.Pen ([Drawing.Color]::White), ([math]::Max(1.0, 1.6 * $k))
    $r = $Circle[2] * $k
    $g.DrawEllipse($ring, [single]($off + $Circle[0] * $k - $r), [single]($off + $Circle[1] * $k - $r), [single](2 * $r), [single](2 * $r))
    $pts = for ($i = 0; $i -lt 6; $i += 2) { New-Object Drawing.PointF ([single]($off + $Triangle[$i] * $k)), ([single]($off + $Triangle[$i + 1] * $k)) }
    $g.FillPolygon([Drawing.Brushes]::White, [Drawing.PointF[]]$pts)
    $g.Dispose()
    $bmp
}

function Get-BmpEntryBytes([Drawing.Bitmap]$bmp) {
    $n = $bmp.Width
    $ms = New-Object IO.MemoryStream
    $bw = New-Object IO.BinaryWriter $ms
    $maskRow = [int]([math]::Ceiling($n / 32.0) * 4)
    # BITMAPINFOHEADER (height doubled: XOR image + AND mask)
    $bw.Write([int]40); $bw.Write([int]$n); $bw.Write([int]($n * 2)); $bw.Write([int16]1); $bw.Write([int16]32)
    $bw.Write([int]0); $bw.Write([int]($n * $n * 4 + $maskRow * $n)); $bw.Write([int]0); $bw.Write([int]0); $bw.Write([int]0); $bw.Write([int]0)
    $rect = New-Object Drawing.Rectangle 0, 0, $n, $n
    $data = $bmp.LockBits($rect, 'ReadOnly', ([Drawing.Imaging.PixelFormat]::Format32bppArgb))
    $row = New-Object byte[] ($n * 4)
    for ($y = $n - 1; $y -ge 0; $y--) {     # bottom-up
        [Runtime.InteropServices.Marshal]::Copy([IntPtr]($data.Scan0.ToInt64() + $y * $data.Stride), $row, 0, $n * 4)
        $bw.Write($row)
    }
    $bmp.UnlockBits($data)
    $bw.Write((New-Object byte[] ($maskRow * $n)))   # AND mask unused (alpha channel wins)
    $bw.Flush()
    $ms.ToArray()
}

$sizes = 16, 20, 24, 32, 40, 48, 64, 128, 256
$images = foreach ($s in $sizes) {
    $bmp = New-LogoBitmap $s
    if ($s -ge 256) {
        $ms = New-Object IO.MemoryStream
        $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png)
        $bytes = $ms.ToArray()
    }
    else { $bytes = Get-BmpEntryBytes $bmp }
    if ($PreviewPng -and $s -eq 256) { $bmp.Save($PreviewPng, [Drawing.Imaging.ImageFormat]::Png) }
    $bmp.Dispose()
    , @($s, $bytes)
}

$fs = [IO.File]::Create($Out)
$bw = New-Object IO.BinaryWriter $fs
$bw.Write([int16]0); $bw.Write([int16]1); $bw.Write([int16]$sizes.Count)    # ICONDIR
$offset = 6 + 16 * $sizes.Count
foreach ($img in $images) {                                                   # ICONDIRENTRY
    $s = $img[0]; $len = $img[1].Length
    $dim = if ($s -ge 256) { 0 } else { $s }
    $bw.Write([byte]$dim); $bw.Write([byte]$dim); $bw.Write([byte]0); $bw.Write([byte]0)
    $bw.Write([int16]1); $bw.Write([int16]32); $bw.Write([int]$len); $bw.Write([int]$offset)
    $offset += $len
}
foreach ($img in $images) { $bw.Write([byte[]]$img[1]) }
$bw.Close()
Write-Host "Wrote $Out ($((Get-Item $Out).Length) bytes, sizes $($sizes -join ', '))"
