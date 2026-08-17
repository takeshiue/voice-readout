# The Windows stop button: a small always-on-top window with the stop switch and
# the settings the statusline would otherwise show.
#
# This is the Windows counterpart to the persistent Termux notification that
# bin/readout-switch.sh posts on Android. Same contract for the stop half: the
# readout polls for a FILE, so the button's whole job is to touch or delete it.
# Nothing here talks to the readout, and deliberately so — a stop that depends
# on the thing it is stopping is not a stop. If Claude Code, the hook, or the
# TTS backend is wedged, this process is unaffected and the file still flips.
#
# The settings rows exist because the statusline does not show on this platform,
# which left the Windows user with no way to see whether the cloud voice or the
# greetings were on — state the phone user reads off the status row at a glance.
# They carry the same information as bin/statusline.sh's segments (greet / notif
# / resp) but NOT its abbreviations: that row is squeezed onto one line of a
# phone terminal, while this window has a column to itself, so everything here is
# spelled out (応答の読み上げ, ElevenLabs) rather than shortened to resp/11labs.
#
# Unlike the stop switch, the settings rows DO go through bin/toggle.sh rather
# than writing the config file here. The config has defaults, per-function keys
# and validation living in that script; a second writer in PowerShell would be a
# copy to keep in sync, and the failure mode is silent (a key written in a form
# toggle.sh does not read). The stop switch is the deliberate exception — it must
# work when nothing else does, so it stays a bare file operation.
#
# Started by bin/stop-button.sh (SessionStart), which owns the single-instance
# guard and passes the paths in. Run directly only for debugging.
#
# THIS FILE MUST KEEP ITS UTF-8 BOM. Windows PowerShell 5.1 — the powershell.exe
# every Windows box has, as opposed to pwsh 7+ — reads a BOM-less script as the
# system ANSI code page, which on a Japanese install is CP932, so the Japanese
# below renders as mojibake (observed 2026-08-15: 停止する displayed as 蛛懈｣).
# The BOM is the only in-band way to tell 5.1 the file is UTF-8; there is no
# switch on the command line that fixes it. Anything that rewrites this file
# wholesale must re-add it — see the *.ps1 rule in .gitattributes.
param(
  # Passed in rather than recomputed so there is exactly one definition of the
  # switch path (tts-lib.sh) and no chance of the button writing somewhere the
  # readout is not looking.
  [Parameter(Mandatory = $true)][string]$StopFile,
  # Written on exit so stop-button.sh's next run knows this one is gone. Also
  # how the launcher's single-instance check identifies a live button.
  [Parameter(Mandatory = $true)][string]$PidFile,
  # The config file the settings rows READ. Writes go through toggle.sh.
  [Parameter(Mandatory = $true)][string]$ConfigFile,
  # The API-key file, read ONLY to test which KEY NAMES are present so the voice
  # row can offer the engines that will actually work. Key VALUES are never read
  # into a variable, printed, or passed anywhere — see Get-AvailableBackends.
  [Parameter(Mandatory = $true)][string]$EnvFile,
  # bash.exe and bin/toggle.sh, for applying a settings change.
  [Parameter(Mandatory = $true)][string]$BashExe,
  [Parameter(Mandatory = $true)][string]$ToggleScript,
  # Whether speak_hybrid() can actually run here. Decided by the launcher, which
  # tests for the same commands speak_hybrid() itself requires, rather than being
  # re-derived here from a guess about the OS.
  [switch]$HybridSupported
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Colours are set explicitly rather than inherited. A button that means "stop"
# has to read as such at a glance in a tray of other windows, and the default
# grey does not — the user is reaching for this while sound is coming out.
$colStopped = [System.Drawing.Color]::FromArgb(190, 40, 40)
$colActive  = [System.Drawing.Color]::FromArgb(40, 140, 70)
$colRowOn   = [System.Drawing.Color]::FromArgb(30, 30, 30)
$colRowOff  = [System.Drawing.Color]::FromArgb(150, 150, 150)
$colHover   = [System.Drawing.Color]::FromArgb(230, 236, 245)

$form = New-Object System.Windows.Forms.Form
$form.Text = 'voice-readout'
# ClientSize, not Size: Size counts the title bar and borders, whose height
# varies with the Windows theme and DPI, so sizing by it left the last row
# touching the bottom edge on this machine (observed 2026-08-15). ClientSize is
# the drawable area, which is what the row coordinates below are in.
# 320 = last row's bottom (282 + 24) + 14, and 14 is the gap between the stop
# button and the first row — so the padding under the last row matches the
# spacing already in the layout instead of being a new invented number.
# Width 360 rather than 314: the hybrid row's value can read オン (要約中は無効),
# which is the longest string any row produces.
$form.ClientSize = New-Object System.Drawing.Size(360, 320)
$form.TopMost = $true
# FixedSingle + no maximise: resizing has no meaning here, and a stray drag on
# the corner should not turn the stop button into something hard to hit.
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.StartPosition = 'Manual'
$form.BackColor = [System.Drawing.Color]::White
# Bottom-right, above the taskbar: out of the way of the terminal the user is
# reading, and the corner the eye already goes to for status.
$wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
# Offset from the work area's far corner by the window's own outer size plus a
# 20px margin, read from the form rather than hardcoded: ClientSize above fixes
# the drawable area, and the border/title-bar thickness added on top of it is
# what varies by theme and DPI. Hardcoded numbers here drifted out of step with
# the size every time the layout grew.
$form.Location = New-Object System.Drawing.Point(
  ($wa.Right - $form.Width - 20), ($wa.Bottom - $form.Height - 20))

$fontUi  = New-Object System.Drawing.Font('Yu Gothic UI', 10)
$fontBtn = New-Object System.Drawing.Font('Yu Gothic UI', 13, [System.Drawing.FontStyle]::Bold)

$label = New-Object System.Windows.Forms.Label
$label.AutoSize = $false
$label.Size = New-Object System.Drawing.Size(346, 26)
$label.Location = New-Object System.Drawing.Point(10, 10)
$label.TextAlign = 'MiddleCenter'
$label.Font = New-Object System.Drawing.Font('Yu Gothic UI', 11)
$form.Controls.Add($label)

$button = New-Object System.Windows.Forms.Button
$button.Size = New-Object System.Drawing.Size(330, 46)
$button.Location = New-Object System.Drawing.Point(15, 40)
$button.Font = $fontBtn
$button.ForeColor = [System.Drawing.Color]::White
$button.FlatStyle = 'Flat'
$form.Controls.Add($button)

# Read one KEY=value from the config. Enable semantics match is_enabled() in
# tts-lib.sh: only the literal "off" is off, and an absent key (or no file) is
# on — the shipped default. Getting this backwards would show a fresh install as
# silent when it is not.
function Get-Cfg([string]$key) {
  if (-not (Test-Path -LiteralPath $ConfigFile)) { return '' }
  $line = Select-String -LiteralPath $ConfigFile -Pattern "^$key=" -ErrorAction SilentlyContinue |
          Select-Object -Last 1
  if (-not $line) { return '' }
  return ($line.Line -replace "^$key=", '')
}
function Test-CfgOn([string]$key) { return (Get-Cfg $key) -ne 'off' }

# Engine names, spelled out. bin/statusline.sh abbreviates (11labs, fish, local)
# because that row shares one terminal line with the rest of the statusline on a
# phone; this window has a column to itself and nothing to buy back, so the
# abbreviations would be a cost with no benefit — "fish" and "local" are the
# plugin's own shorthand, not names the user chose or will recognise from the
# vendors' own docs. ElevenLabs, Inworld and Fish Audio are written the way the
# services write themselves; the on-device voice has no product name, so it is
# described by what distinguishes it (runs on this machine, no network).
# Config VALUES are untouched by this: `toggle.sh backend ondevice` still takes
# the short form, and Switch-Backend passes those, not these labels.
function Get-BackendLabel([string]$b) {
  switch ($b) {
    'ondevice'   { '端末内蔵 (SAPI)' }
    'gemini'     { 'Gemini' }
    'inworld'    { 'Inworld' }
    'elevenlabs' { 'ElevenLabs' }
    'fishaudio'  { 'Fish Audio' }
    default      { if ($b) { $b } else { '端末内蔵 (SAPI)' } }
  }
}

# Which backend the response actually uses: the per-function key for the live
# mode, falling back to the global, then ondevice. Same resolution order as
# get_tts_backend() in tts-lib.sh — a row that showed the global while a
# per-function key overrode it would misreport which engine is speaking.
function Get-RespBackend {
  $mode = Get-Cfg 'READOUT_MODE'
  $b = if ($mode -eq 'full') { Get-Cfg 'TTS_BACKEND_FULL' } else { Get-Cfg 'TTS_BACKEND_SUMMARY' }
  if (-not $b) { $b = Get-Cfg 'TTS_BACKEND' }
  if (-not $b) { $b = 'ondevice' }
  return $b
}

# Runs `toggle.sh <args>` and returns $true on success. Hidden window so a
# console box does not flash on every click; -NoProfile is not applicable here
# but bash is invoked with the script path only, no login shell, for the same
# reason: speed and no user rc surprises.
function Invoke-Toggle([string[]]$ToggleArgs) {
  try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $BashExe
    $all = @($ToggleScript) + $ToggleArgs
    $psi.Arguments = ($all | ForEach-Object { '"' + $_ + '"' }) -join ' '
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    # Bounded: a wedged toggle.sh must not freeze the window that also holds the
    # stop button. 10s is far beyond a config write.
    if (-not $p.WaitForExit(10000)) { try { $p.Kill() } catch {} ; return $false }
    return ($p.ExitCode -eq 0)
  } catch {
    return $false
  }
}

# One clickable settings row. Rendered as a Label rather than a Button because
# these are status first and controls second — the statusline equivalent is text,
# and a stack of six raised buttons would compete with the stop button for the
# eye. The hover tint is what advertises clickability.
$rows = @()
function New-Row([int]$y, [string]$caption, [scriptblock]$getState, [scriptblock]$onClick) {
  $row = New-Object System.Windows.Forms.Label
  $row.AutoSize = $false
  $row.Size = New-Object System.Drawing.Size(130, 24)
  $row.Location = New-Object System.Drawing.Point(15, $y)
  $row.TextAlign = 'MiddleLeft'
  $row.Font = $fontUi
  $row.Cursor = [System.Windows.Forms.Cursors]::Hand

  # The value sits in its own label at a fixed x so the column is straight
  # regardless of caption width (see Sync-Ui). Bold: the caption is what the row
  # IS and rarely changes, the value is what the user came to read.
  $val = New-Object System.Windows.Forms.Label
  $val.AutoSize = $false
  $val.Size = New-Object System.Drawing.Size(195, 24)
  $val.Location = New-Object System.Drawing.Point(150, $y)
  $val.TextAlign = 'MiddleLeft'
  $val.Font = New-Object System.Drawing.Font('Yu Gothic UI', 10, [System.Drawing.FontStyle]::Bold)
  $val.Cursor = [System.Windows.Forms.Cursors]::Hand
  $form.Controls.Add($val)

  $row.Tag = @{ Caption = $caption; GetState = $getState; Value = $val }
  # Both halves hover and click as one row: a user aiming at the value — the part
  # they are trying to change — must not find it dead because only the caption
  # carried the handler.
  $enter = { $this.BackColor = $colHover }.GetNewClosure()
  $leave = { $this.BackColor = [System.Drawing.Color]::Transparent }.GetNewClosure()
  $row.Add_MouseEnter($enter); $row.Add_MouseLeave($leave); $row.Add_Click($onClick)
  $val.Add_MouseEnter($enter); $val.Add_MouseLeave($leave); $val.Add_Click($onClick)
  $form.Controls.Add($row)
  $script:rows += $row
  return $row
}

# Which engines this install can actually speak with: ondevice always (no key,
# no network), plus every cloud backend whose key is registered. Selecting an
# engine with no key would fail at speak time with only a log line to show for
# it — the readout falls back and the row would still claim the engine is live —
# so the unusable ones are left out of the cycle entirely.
#
# Only the presence of a KEY NAME at the start of a line is tested. Values are
# never captured: -Quiet returns a bool, so no part of the secret enters a
# variable or this window's memory.
function Get-AvailableBackends {
  $avail = @('ondevice')
  if (-not (Test-Path -LiteralPath $EnvFile)) { return $avail }
  $keyFor = [ordered]@{
    gemini     = 'GEMINI_API_KEY'
    inworld    = 'INWORLD_API_KEY'
    elevenlabs = 'ELEVENLABS_API_KEY'
    fishaudio  = 'FISHAUDIO_API_KEY'
  }
  foreach ($b in $keyFor.Keys) {
    # "KEY=" with something after it — a bare "KEY=" line is a cleared key
    # (that is what `toggle.sh <engine>-key clear` leaves behind), not a usable
    # one, and offering it would be the same broken state as no key at all.
    if (Select-String -LiteralPath $EnvFile -Pattern "^$($keyFor[$b])=.+" -Quiet -ErrorAction SilentlyContinue) {
      $avail += $b
    }
  }
  return $avail
}

# Steps to the next usable engine, wrapping around. A cycle rather than a
# dropdown: the row is one line of status the user clicks, and with at most five
# entries stepping through is fewer interactions than opening a list, choosing,
# and dismissing it. Both TTS_BACKEND_FULL and _SUMMARY are set, plus the
# global, so the switch holds whichever mode the readout is in.
function Switch-Backend {
  $avail = Get-AvailableBackends
  if ($avail.Count -le 1) { return }
  $cur = Get-RespBackend
  $i = [array]::IndexOf($avail, $cur)
  # An unknown current value (an engine whose key was since cleared, or a hand
  # edited config) lands on -1, and -1 + 1 = 0 restarts the cycle — which is the
  # right recovery: the first entry is ondevice, the one that always works.
  $next = $avail[($i + 1) % $avail.Count]
  [void](Invoke-Toggle @('backend', $next))
  [void](Invoke-Toggle @('backend-full', $next))
  [void](Invoke-Toggle @('backend-summary', $next))
}

function Switch-Flag([string]$subcommand, [string]$key) {
  $next = if (Test-CfgOn $key) { 'off' } else { 'on' }
  [void](Invoke-Toggle @($subcommand, $next))
}

# Captions spelled out for the same reason as the engine names above: the
# statusline's resp/notif/greet are abbreviations bought with a phone's line
# width, and this window has the room to just say what each row is. States are
# words too — オン/オフ rather than on/off, 全文/要約 rather than full/sum —
# because the row is read as a sentence ("応答の読み上げ  オン"), and a mode
# named "sum" tells you nothing unless you already know it means summary.
$rowBackend = New-Row 100 '音声エンジン' { Get-BackendLabel (Get-RespBackend) } { Switch-Backend; Sync-Ui }
$rowMode    = New-Row 126 '読み上げ方' { if ((Get-Cfg 'READOUT_MODE') -eq 'full') { '全文' } else { '要約' } } {
  $next = if ((Get-Cfg 'READOUT_MODE') -eq 'full') { 'summary' } else { 'full' }
  [void](Invoke-Toggle @('mode', $next)); Sync-Ui
}
# Hybrid: the on-device voice speaks the opening while the cloud engine is still
# generating, then hands over. It is the only thing that hides a slow engine's
# first-sound wait — 13-15s on gemini here, measured 2026-08-15 — so it belongs
# on the panel next to the engine it compensates for.
#
# HYBRID_TTS is only consulted in full mode with a cloud backend; in summary mode
# or on ondevice the setting is inert. statusline.sh handles that by not drawing
# the tag at all, which works for a row that has to earn its width, but a panel
# row that vanishes reads as "the feature is gone". So the row stays and says
# それでも効きません — the state is reported honestly instead of the config value
# being shown as if it were in effect.
#
# The platform check comes FIRST because it outranks the other two: where
# speak_hybrid() cannot run, nothing the config, the mode or the engine says can
# make the feature happen, and a row reporting a stored value as though it were
# its effect is the one thing a status panel must not do. $HybridSupported is
# decided by the launcher from the same test speak_hybrid() applies, so this
# stays honest if that requirement changes again.
#
# Named for what it does — hand the readout over from one voice to the other
# partway through — not for the prefetching that happens to be how it is built.
# 先読み described the implementation (a speculative generator running ahead) and
# said nothing about what the listener gets, which is two voices in one readout.
$rowHybrid  = New-Row 152 '音声の引き継ぎ' {
  if (-not $HybridSupported) {
    if (Test-CfgOn 'HYBRID_TTS') { 'オン (この環境では非対応)' } else { 'オフ (この環境では非対応)' }
  }
  elseif (-not (Test-CfgOn 'HYBRID_TTS')) { 'オフ' }
  elseif ((Get-Cfg 'READOUT_MODE') -ne 'full') { 'オン (要約中は無効)' }
  elseif ((Get-RespBackend) -eq 'ondevice') { 'オン (端末内蔵では無効)' }
  else { 'オン' }
} { Switch-Flag 'hybrid' 'HYBRID_TTS'; Sync-Ui }
$rowResp    = New-Row 178 '応答の読み上げ' { if (Test-CfgOn 'STOP_READOUT') { 'オン' } else { 'オフ' } } {
  Switch-Flag 'stop' 'STOP_READOUT'; Sync-Ui
}
$rowNotif   = New-Row 204 '通知の読み上げ' { if (Test-CfgOn 'NOTIFICATION_READOUT') { 'オン' } else { 'オフ' } } {
  Switch-Flag 'notification' 'NOTIFICATION_READOUT'; Sync-Ui
}
$rowGreet   = New-Row 230 '開始のあいさつ' { if (Test-CfgOn 'STARTUP_GREETING') { 'オン' } else { 'オフ' } } {
  Switch-Flag 'greeting' 'STARTUP_GREETING'; Sync-Ui
}
$rowFarewell= New-Row 256 '終了のあいさつ' { if (Test-CfgOn 'SESSION_END_GREETING') { 'オン' } else { 'オフ' } } {
  Switch-Flag 'farewell' 'SESSION_END_GREETING'; Sync-Ui
}
# Diagnostic, and the only row whose default is off. Kept on the panel anyway:
# it is turned on to hear where the chunk boundaries fall, and the moment it
# matters most is when cues are sounding and the listener has forgotten what is
# making the noise. statusline.sh draws it only while on, for width; here it can
# just say オフ. Note CHUNK_MARKER's own default is off, so Test-CfgOn — which
# treats an absent key as ON — would be wrong for this one key.
$rowMarker  = New-Row 282 '区切り音' { if ((Get-Cfg 'CHUNK_MARKER') -eq 'on') { 'オン' } else { 'オフ' } } {
  $next = if ((Get-Cfg 'CHUNK_MARKER') -eq 'on') { 'off' } else { 'on' }
  [void](Invoke-Toggle @('chunk-marker', $next)); Sync-Ui
}

# The file is the single source of truth, never a variable in this process.
# The switch can also be flipped by `readout-switch.sh stop` or by Claude, and
# a cached copy here would drift and start showing 停止する while already
# stopped — at which point the button lies about what pressing it will do. The
# settings rows are re-read for the same reason: `toggle.sh` on the command line
# is the other way they change.
function Sync-Ui {
  $stopped = Test-Path -LiteralPath $StopFile
  if ($stopped) {
    $label.Text = '● 読み上げ 停止中'
    $button.Text = '再開する'
    $button.BackColor = $colActive
  } else {
    $label.Text = '● 読み上げ 有効'
    $button.Text = '停止する'
    $button.BackColor = $colStopped
  }
  # Mirrored onto the tray so the state is readable while the panel is hidden —
  # which, once [×] hides instead of closing, is most of the time. Guarded
  # because Sync-Ui runs once before the tray exists.
  if ($script:tray) {
    $script:tray.Icon = if ($stopped) { $script:iconOff } else { $script:iconOn }
    $script:tray.Text = if ($stopped) { 'voice-readout — 停止中' } else { 'voice-readout — 有効' }
  }
  foreach ($r in $script:rows) {
    $state = & $r.Tag.GetState
    # Two labels rather than one padded string: -f padding counts CHARACTERS,
    # and these captions are full-width Japanese, so a character count does not
    # line up as a column — 音声エンジン and 読み上げ方 differ by two characters
    # but by four columns on screen. The value label is positioned instead, which
    # is exact whatever the caption is.
    $r.Text = $r.Tag.Caption
    $r.Tag.Value.Text = $state
    # Greyed when off, so the rows that are not contributing sound recede
    # instead of reading as equal to the ones that are.
    # Grey for オフ AND for the hybrid row's オン (…は無効) states: both mean the
    # setting is not contributing sound right now, which is what the greying is
    # telling the eye. An exact -eq 'オフ' test left "オン (要約中は無効)" in
    # full black, reading as though the feature were live.
    $col = if ($state -eq 'オフ' -or $state -like '*無効*') { $colRowOff } else { $colRowOn }
    $r.ForeColor = $col
    $r.Tag.Value.ForeColor = $col
  }
}

$button.Add_Click({
  try {
    if (Test-Path -LiteralPath $StopFile) {
      Remove-Item -LiteralPath $StopFile -Force -ErrorAction Stop
    } else {
      New-Item -ItemType File -Path $StopFile -Force -ErrorAction Stop | Out-Null
    }
  } catch {
    # Show the failure instead of flipping the label anyway. A button that
    # reports success it did not achieve is worse than one that admits it is
    # stuck, because the user stops reaching for the real remedy.
    [System.Windows.Forms.MessageBox]::Show(
      "停止スイッチを切り替えられませんでした:`n$($_.Exception.Message)",
      'voice-readout', 'OK', 'Error') | Out-Null
  }
  Sync-Ui
})

# Picks up changes made outside this window (readout-switch.sh, toggle.sh,
# Claude, another button instance) so the labels cannot go stale. 1s is well
# below the time it takes to look over and read them.
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({ Sync-Ui })
$timer.Start()

# The tray icon, and why [×] does not close.
#
# A window whose close box ENDS the process is wrong for this one: pressing 停止
# then [×] leaves the readout silenced with the only control gone, and there is
# nothing on screen to bring it back — the launcher runs at SessionStart, so
# recovery meant a new Claude Code session or a shell command, which is exactly
# the dependency the stop switch exists to remove. So [×] hides to the tray and
# the icon is what stays: always somewhere to click, whatever state the switch
# is in. Quitting for real is an explicit item in the tray menu.
$script:tray = New-Object System.Windows.Forms.NotifyIcon
$script:tray.Text = 'voice-readout'
$script:tray.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miShow = $menu.Items.Add('パネルを表示')
$miShow.Add_Click({ Show-Panel })
# Separated from 表示 so a mis-click on the way to 表示 does not end the process.
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$miQuit = $menu.Items.Add('終了')
$miQuit.Add_Click({
  # Deliberately does NOT clear the stop switch: quitting the panel is not a
  # decision to start speaking again. Same rule as closing the window.
  $script:reallyExit = $true
  $script:tray.Visible = $false
  $form.Close()
})
$script:tray.ContextMenuStrip = $menu

function Show-Panel {
  $form.Show()
  # A hidden form stays minimised-in-spirit; both lines are needed or it can
  # come back behind the terminal it is supposed to sit in front of.
  $form.WindowState = 'Normal'
  [void]$form.Activate()
}

# Double-click is the Windows convention for "open the thing"; single left click
# is left alone so it cannot be confused with the stop action.
$script:tray.Add_MouseDoubleClick({ Show-Panel })

# The icon carries the state too, so a glance at the tray answers "is it muted"
# without opening the panel. Drawn rather than shipped as a .ico: two solid
# circles in the same red/green as the button need no asset, and an asset would
# be one more file to keep in sync with the colours above.
$script:iconOn = $null
$script:iconOff = $null
function New-DotIcon([System.Drawing.Color]$fill) {
  $bmp = New-Object System.Drawing.Bitmap 16, 16
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = 'AntiAlias'
  $g.Clear([System.Drawing.Color]::Transparent)
  $brush = New-Object System.Drawing.SolidBrush $fill
  $g.FillEllipse($brush, 1, 1, 14, 14)
  $brush.Dispose(); $g.Dispose()
  # GetHicon hands back an unmanaged handle; the Icon wraps it for the lifetime
  # of this process, which is exactly as long as the tray needs it.
  return [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}
$script:iconOn  = New-DotIcon $colActive
$script:iconOff = New-DotIcon $colStopped

# Hide instead of close, unless 終了 asked for the real thing. FormClosing (not
# FormClosed) is the only place this can be intercepted — by the time FormClosed
# fires the window is already gone.
$script:reallyExit = $false
$form.Add_FormClosing({
  param($sender, $e)
  if (-not $script:reallyExit) {
    $e.Cancel = $true
    $form.Hide()
  }
})

# The switch persists on disk, so hiding or quitting never changes it: a user who
# pressed 停止 stays stopped until they press 再開. Only the pid file is cleaned
# up, and only on a real exit.
$form.Add_FormClosed({
  $timer.Stop()
  $script:tray.Visible = $false
  $script:tray.Dispose()
  Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
})

Sync-Ui
[System.Windows.Forms.Application]::Run($form)
