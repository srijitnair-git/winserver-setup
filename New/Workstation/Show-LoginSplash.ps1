<#
Domech Fabricators - post-login splash popup
Deployed as a User Configuration > Logon script via GPO (linked from NETLOGON).
Shows LoginSplash.png (exported from the Illustrator source) for a few seconds after login.
#>

$splashPath = "$PSScriptRoot\LoginSplash.png"
if (-not (Test-Path $splashPath)) { exit }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$img = [System.Drawing.Image]::FromFile($splashPath)

$form = New-Object System.Windows.Forms.Form
$form.FormBorderStyle = 'None'
$form.StartPosition   = 'CenterScreen'
$form.TopMost         = $true
$form.ClientSize      = New-Object System.Drawing.Size($img.Width, $img.Height)
$form.BackgroundImage = $img
$form.BackgroundImageLayout = 'Stretch'

$form.Add_Click({ $form.Close() })
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 4000   # 4 seconds
$timer.Add_Tick({ $form.Close() })
$timer.Start()

$form.ShowDialog() | Out-Null
