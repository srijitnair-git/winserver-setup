<#
Domech Fabricators - post-login splash popup
Deployed as a User Configuration > Logon script via GPO (linked from NETLOGON).
Shows LoginSplash.png (the static Domech background/card art) for a few
seconds after login, with the logged-in user's real name drawn on top live -
so one background image works for everyone, not just whoever the design was
originally mocked up with.

Needs LoginSplash.png and Fonts\Geist-Bold.ttf sitting next to this script
(both copied to NETLOGON alongside it by Setup-DFLocal-Full.ps1).
#>

$splashPath = "$PSScriptRoot\LoginSplash.png"
$fontPath   = "$PSScriptRoot\Fonts\Geist-Bold.ttf"
if (-not (Test-Path $splashPath)) { exit }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ---- Look up the logged-in user's real display name ----
# Works without RSAT/ActiveDirectory module - System.DirectoryServices ships
# with Windows PowerShell 5.1 by default.
$displayName = $env:USERNAME
try {
    $searcher = New-Object System.DirectoryServices.DirectorySearcher
    $searcher.Filter = "(samaccountname=$env:USERNAME)"
    $searcher.PropertiesToLoad.Add("displayname") | Out-Null
    $result = $searcher.FindOne()
    if ($result -and $result.Properties["displayname"].Count -gt 0) {
        $displayName = $result.Properties["displayname"][0]
    }
} catch {
    # AD lookup failed (offline, workgroup, etc.) - fall back to the Windows username
}
$displayName = $displayName.ToUpper()

# ---- Draw the name onto a copy of the background ----
$bg = [System.Drawing.Image]::FromFile($splashPath)
$canvas = New-Object System.Drawing.Bitmap($bg.Width, $bg.Height)
$g = [System.Drawing.Graphics]::FromImage($canvas)
$g.SmoothingMode = 'AntiAlias'
$g.TextRenderingHint = 'AntiAliasGridFit'
$g.DrawImage($bg, 0, 0, $bg.Width, $bg.Height)

# Position matches the original design's text baseline (translate(615.69
# 503.29), "WELCOME " tspan ending at x=81.07) - name starts right after it.
$nameX = 615.69 + 81.07
$nameY = 503.29 - 12   # GDI+ draws from the top of the text box, SVG used a baseline - shift up ~1 line height

$fonts = New-Object System.Drawing.Text.PrivateFontCollection
if (Test-Path $fontPath) {
    $fonts.AddFontFile($fontPath)
    $fontFamily = $fonts.Families[0]
} else {
    $fontFamily = [System.Drawing.FontFamily]::GenericSansSerif
}
$font = New-Object System.Drawing.Font($fontFamily, 12, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
$brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 41, 84, 163))   # #2954a3, matches the design

$g.DrawString("$displayName,", $font, $brush, [float]$nameX, [float]$nameY)
$g.Dispose()

# Fit the splash to this screen. The artwork is 1920x1080; on a smaller
# display (the laptop) a form that size hangs off the edges and the card gets
# cut off, so scale down proportionally when it doesn't fit. WorkingArea
# rather than Bounds, so it never covers the taskbar.
$screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$scale  = [Math]::Min(1.0, [Math]::Min($screen.Width / $canvas.Width, $screen.Height / $canvas.Height))

$form = New-Object System.Windows.Forms.Form
$form.FormBorderStyle = 'None'
$form.StartPosition   = 'CenterScreen'
$form.TopMost         = $true
# The artwork's margins are transparent. Without this they render as the
# default grey control colour instead of blending into the white card.
$form.BackColor       = [System.Drawing.Color]::White
$form.ClientSize      = New-Object System.Drawing.Size([int]($canvas.Width * $scale), [int]($canvas.Height * $scale))
$form.BackgroundImage = $canvas
$form.BackgroundImageLayout = 'Zoom'   # Zoom keeps the aspect ratio; Stretch distorted it

$form.Add_Click({ $form.Close() })
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 4000   # 4 seconds
$timer.Add_Tick({ $form.Close() })
$timer.Start()

$form.ShowDialog() | Out-Null
