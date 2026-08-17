# Speaks a UTF-8 text file through Windows SAPI, with the engine's trailing
# silence trimmed off first.
#
# Why not just $s.Speak($text): the ja-JP Haruka voice pads every utterance with
# a fixed ~550ms of trailing silence (measured 2026-08-15: "あ" produces 724ms of
# audio of which only 176ms is speech; the padding is 553-590ms regardless of
# text length). Speak() blocks until the audio device finishes, so that padding
# is dead wall time on every call. This matters here beyond politeness: the
# on-device voice is what covers a cloud engine's first-chunk generation during a
# hybrid handover, and it is called once per unit, so the padding is paid
# repeatedly inside the window the cloud is racing against.
#
# So synthesise to a memory stream, cut the silence, and play the result.
# Measured 1108ms -> 752ms for a single character, a ~350ms saving at any length.
#
# PlaySync() is required, not Play(): the caller (speak_windows_sapi in
# bin/tts-lib.sh) treats this process's exit as "the audio has finished", which is
# how the hybrid handover knows when to start the cloud voice and how the stop
# switch takes effect between units. Play() would return immediately and every
# one of those would break.
#
# THIS FILE MUST KEEP ITS UTF-8 BOM — see the same note in bin/stop-button.ps1.
param(
  # A file, not a string argument: PowerShell 5.1 mangles non-ASCII passed on the
  # command line, so the text is handed over as UTF-8 bytes and decoded here.
  [Parameter(Mandatory = $true)][string]$TextFile,
  [int]$Rate = 3
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Speech

$text = [System.IO.File]::ReadAllText($TextFile, [System.Text.Encoding]::UTF8)
if (-not $text) { exit 0 }

$ms = New-Object System.IO.MemoryStream
$synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
$synth.Rate = $Rate
$synth.SetOutputToWaveStream($ms)
$synth.Speak($text)
$synth.Dispose()
$bytes = $ms.ToArray()

# Walk the RIFF chunks rather than assuming the textbook 44-byte header. This
# synthesiser emits an 18-byte fmt chunk, putting the data at offset 46, and
# hardcoding 44 corrupts the header: PlaySync() then returns in about a
# millisecond and the readout is silently lost. Found the hard way 2026-08-15.
$fmtOff = -1; $dataOff = -1; $dataLen = 0
$p = 12
while ($p -lt $bytes.Length - 8) {
  $id = [System.Text.Encoding]::ASCII.GetString($bytes, $p, 4)
  $sz = [System.BitConverter]::ToInt32($bytes, $p + 4)
  if ($id -eq 'fmt ') { $fmtOff = $p + 8 }
  if ($id -eq 'data') { $dataOff = $p + 8; $dataLen = $sz; break }
  $p += 8 + $sz + ($sz % 2)
}

# Any surprise in the container is a reason to fall back to plain Speak(), not to
# fail: a readout that happens is worth more than 350ms.
if ($dataOff -lt 0 -or $fmtOff -lt 0) {
  $s2 = New-Object System.Speech.Synthesis.SpeechSynthesizer
  $s2.Rate = $Rate
  $s2.Speak($text)
  $s2.Dispose()
  exit 0
}

$bytesPerSec = [System.BitConverter]::ToInt32($bytes, $fmtOff + 4)
$bits = [System.BitConverter]::ToInt16($bytes, $fmtOff + 14)
if ($bits -ne 16) {
  $s2 = New-Object System.Speech.Synthesis.SpeechSynthesizer
  $s2.Rate = $Rate
  $s2.Speak($text)
  $s2.Dispose()
  exit 0
}

# Last sample above the noise floor, searched inside the data chunk only. The
# threshold is on amplitude, not exact zero: the padding is not digital silence.
$dataEnd = [Math]::Min($bytes.Length, $dataOff + $dataLen)
$last = $dataOff
for ($i = $dataOff; $i -lt $dataEnd - 1; $i += 2) {
  if ([Math]::Abs([System.BitConverter]::ToInt16($bytes, $i)) -gt 300) { $last = $i }
}
# 80ms of tail kept deliberately. Cutting flush to the last loud sample clips the
# decay of a final consonant and sounds abrupt, and this runs straight into the
# cloud voice on a handover, where a hard cut is audible as a click.
$keep = [Math]::Min($dataEnd, $last + [int]($bytesPerSec * 0.08))
$newDataLen = $keep - $dataOff

$out = New-Object byte[] $keep
[System.Array]::Copy($bytes, $out, $keep)
# Both length fields have to be rewritten or the player trusts the old ones and
# reads past the end of the buffer.
[System.Array]::Copy([System.BitConverter]::GetBytes($keep - 8), 0, $out, 4, 4)
[System.Array]::Copy([System.BitConverter]::GetBytes($newDataLen), 0, $out, $dataOff - 4, 4)

$player = New-Object System.Media.SoundPlayer
$player.Stream = New-Object System.IO.MemoryStream (,$out)
$player.PlaySync()
$player.Dispose()
exit 0
