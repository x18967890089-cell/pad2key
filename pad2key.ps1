#Requires -Version 5.1
<#
.SYNOPSIS
  pad2key - bridge a game controller to keyboard input for games without controller support.

.DESCRIPTION
  Loads SDL2.dll, opens the first recognised game controller and turns its buttons and
  left stick into key presses (keybd_event). Keys are injected only while the target game
  owns the foreground window, and all keys are released the moment the game is no longer
  in the foreground. The bridge exits by itself when the game process goes away.

  No install, no service, no dependencies besides SDL2.dll.

.PARAMETER GamePid
  PID of the game process. The most reliable option when a launcher starts the game.

.PARAMETER GameName
  Process name of the game, with or without ".exe" (e.g. "game").
  Leave it empty to watch -GamePid only: pad2key never guesses process names on its own.

.PARAMETER ForceOn
  Inject keys even while the game is not in the foreground. Off by default on purpose:
  it is the main way to type into the wrong window by accident.

.PARAMETER SelfTest
  Print the environment (PowerShell bitness, SDL2 location, controller list) and exit.
  Injects no keys and needs no game process: use it to check the setup first.

.EXAMPLE
  .\pad2key.ps1 -SelfTest

.EXAMPLE
  .\pad2key.ps1 -GameName game

.EXAMPLE
  $game = Start-Process .\game.exe -PassThru
  .\pad2key.ps1 -GamePid $game.Id
#>
[CmdletBinding()]
param(
  [int]$GamePid = 0,
  [string]$GameName = '',
  [switch]$ForceOn,
  [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
if (-not $here) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
$log = Join-Path $here 'pad2key.log'

function Log([string]$m) {
  try {
    Add-Content -LiteralPath $log -Value ('{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) -Encoding UTF8
  } catch { }
}

function Say([string]$m) {
  Log $m
  Write-Host $m
}

# ---- config: this is the only block you need to touch to change the bindings ----
$KEY_LEFT   = 0x41   # A  <- left stick left
$KEY_RIGHT  = 0x44   # D  <- left stick right
$KEY_JUMP   = 0x57   # W  <- pad X
$KEY_CROUCH = 0x53   # S  <- pad A
$KEY_FIRE   = 0x5A   # Z  <- LB
$KEY_NADE   = 0x58   # X  <- RB
$DEAD       = 8000   # stick dead zone, axis range is -32768..32767

$BTN_A  = 0
$BTN_X  = 2
$BTN_LB = 9
$BTN_RB = 10
# ---------------------------------------------------------------------------------

# Get-Process reports names without the .exe suffix.
if ($GameName) { $GameName = ($GameName.Trim() -replace '\.exe$', '') }

# ---- 1. locate SDL2.dll: next to this script first, then anywhere on PATH ----
function Find-Sdl2Directory([string]$scriptDir) {
  $local = Join-Path $scriptDir 'SDL2.dll'
  if (Test-Path -LiteralPath $local -PathType Leaf) {
    return [pscustomobject]@{ Directory = $scriptDir; Found = 'next to pad2key.ps1' }
  }
  foreach ($raw in ($env:PATH -split ';')) {
    $dir = $raw.Trim().Trim('"')
    if (-not $dir) { continue }
    $dir = [Environment]::ExpandEnvironmentVariables($dir)
    try {
      if (Test-Path -LiteralPath (Join-Path $dir 'SDL2.dll') -PathType Leaf) {
        return [pscustomobject]@{ Directory = $dir; Found = 'on PATH' }
      }
    } catch { }
  }
  return $null
}

$sdl = Find-Sdl2Directory $here
if ($null -eq $sdl) {
  Write-Host ''
  Write-Host 'pad2key: SDL2.dll was not found.' -ForegroundColor Red
  Write-Host ''
  Write-Host "  Looked in: 1) $here"
  Write-Host '             2) every directory on PATH'
  Write-Host ''
  Write-Host '  How to fix:'
  Write-Host '    1. Download the SDL2 runtime binary for Windows:'
  Write-Host '         https://libsdl.org    (Download -> SDL2 -> SDL2-2.x.y-win32-x64.zip)'
  Write-Host '    2. Unzip it and put SDL2.dll next to pad2key.ps1 (recommended),'
  Write-Host '       or into any directory that is on PATH.'
  Write-Host '    3. The bitness must match: 64-bit PowerShell needs the 64-bit SDL2.dll.'
  Write-Host ''
  exit 3
}

$env:PATH = $sdl.Directory + ';' + $env:PATH

# ---- 2. SDL2 / user32 bindings ----
if (-not ('PADK' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class PADK {
  [DllImport("SDL2.dll")] public static extern int SDL_Init(uint flags);
  [DllImport("SDL2.dll")] public static extern void SDL_Quit();
  [DllImport("SDL2.dll")] public static extern int SDL_NumJoysticks();
  [DllImport("SDL2.dll")] public static extern int SDL_IsGameController(int idx);
  [DllImport("SDL2.dll")] public static extern IntPtr SDL_JoystickNameForIndex(int idx);
  [DllImport("SDL2.dll")] public static extern IntPtr SDL_GameControllerOpen(int idx);
  [DllImport("SDL2.dll")] public static extern void SDL_GameControllerClose(IntPtr gc);
  [DllImport("SDL2.dll")] public static extern IntPtr SDL_GameControllerName(IntPtr gc);
  [DllImport("SDL2.dll")] public static extern void SDL_GameControllerUpdate();
  [DllImport("SDL2.dll")] public static extern byte SDL_GameControllerGetButton(IntPtr gc, int button);
  [DllImport("SDL2.dll")] public static extern short SDL_GameControllerGetAxis(IntPtr gc, int axis);
  [DllImport("SDL2.dll")] public static extern IntPtr SDL_GetError();
  [DllImport("SDL2.dll")] public static extern IntPtr SDL_GetRevision();
  [DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
}
'@
}

function Start-Sdl {
  try {
    $rc = [PADK]::SDL_Init([uint32]0x00002000)   # SDL_INIT_GAMECONTROLLER
  } catch {
    throw ('SDL2.dll could not be loaded from "{0}": {1}' -f $sdl.Directory, $_.Exception.Message)
  }
  if ($rc -ne 0) {
    $msg = ''
    try { $msg = [Runtime.InteropServices.Marshal]::PtrToStringAnsi([PADK]::SDL_GetError()) } catch { }
    throw ('SDL_Init failed (rc={0}): {1}' -f $rc, $msg)
  }
}

function Get-SdlString([IntPtr]$ptr) {
  if ($ptr -eq [IntPtr]::Zero) { return '' }
  return [Runtime.InteropServices.Marshal]::PtrToStringAnsi($ptr)
}

# ---- 3. self-test: environment only, no keys, no game required ----
if ($SelfTest) {
  $bits = '32'
  if ([Environment]::Is64BitProcess) { $bits = '64' }
  Say 'pad2key self-test'
  Say ('  PowerShell : {0} ({1}-bit)' -f $PSVersionTable.PSVersion, $bits)
  Say ('  SDL2 dir   : {0}  [{1}]' -f $sdl.Directory, $sdl.Found)
  try { Start-Sdl } catch {
    Say ('ERROR: ' + $_.Exception.Message)
    Say 'Download SDL2 for Windows: https://libsdl.org'
    exit 4
  }
  $rev = ''
  try { $rev = Get-SdlString ([PADK]::SDL_GetRevision()) } catch { }
  if ($rev) { Say ('  SDL2 build : {0}' -f $rev) }
  $count = [PADK]::SDL_NumJoysticks()
  Say ('  joysticks  : {0}' -f $count)
  for ($i = 0; $i -lt $count; $i++) {
    $name = ''
    try { $name = Get-SdlString ([PADK]::SDL_JoystickNameForIndex($i)) } catch { }
    $isGc = [PADK]::SDL_IsGameController($i)
    Say ('    [{0}] {1}  (game controller: {2})' -f $i, $name, $isGc)
  }
  if ($count -le 0) { Say 'waiting for controller...' }
  try { [PADK]::SDL_Quit() | Out-Null } catch { }
  Say 'self-test finished, no keys were injected'
  exit 0
}

# ---- 4. which process is the game? ----
if ($GamePid -eq 0 -and -not $GameName) {
  Say 'ERROR: no target game to watch.'
  Say '  Pass -GamePid <pid> (most reliable) or -GameName <process name>.'
  Say '  Example: .\pad2key.ps1 -GameName notepad'
  Say '  Setup check only: .\pad2key.ps1 -SelfTest'
  exit 2
}

# ---- 5. single instance: two bridges would inject every key twice ----
try {
  $mutex = New-Object System.Threading.Mutex($false, 'Global\pad2key_singleton')
  if (-not $mutex.WaitOne(0)) { Say 'another pad2key instance is already running - exit'; exit 0 }
} catch {
  Log ('mutex unavailable, continuing without single-instance guard: ' + $_.Exception.Message)
}

try { Start-Sdl } catch {
  Say ('ERROR: ' + $_.Exception.Message)
  Say 'Download SDL2 for Windows: https://libsdl.org'
  exit 4
}

$vkMap = @{
  'L'      = $KEY_LEFT
  'R'      = $KEY_RIGHT
  'JUMP'   = $KEY_JUMP
  'CROUCH' = $KEY_CROUCH
  'FIRE'   = $KEY_FIRE
  'NADE'   = $KEY_NADE
}
$order    = @('L', 'R', 'JUMP', 'CROUCH', 'FIRE', 'NADE')
$held     = @{}
foreach ($k in $order) { $held[$k] = $false }
$downFlag = [uint32]0
$upFlag   = [uint32]2

function Send-Key([int]$vk, [bool]$down) {
  $flag = $upFlag
  if ($down) { $flag = $downFlag }
  [PADK]::keybd_event([byte]$vk, [byte]0, [uint32]$flag, [UIntPtr]::Zero)
}

function Release-All([string]$why) {
  $any = $false
  foreach ($k in $order) { if ($held[$k]) { $any = $true } }
  if (-not $any) { return }
  foreach ($k in $order) {
    if ($held[$k]) {
      Send-Key ([int]$vkMap[$k]) $false
      $held[$k] = $false
    }
  }
  Log ('release-all: ' + $why)
}

function Get-GameProcess {
  if ($GamePid -ne 0) {
    # PID only: if it is gone, the game is gone.
    return (Get-Process -Id $GamePid -ErrorAction SilentlyContinue)
  }
  if ($GameName) {
    return (Get-Process -Name $GameName -ErrorAction SilentlyContinue | Select-Object -First 1)
  }
  return $null
}

# ---- 6. wait for the game (up to 90s) so a stray start does not linger ----
Say ('start: pid={0} name="{1}" forceOn={2}' -f $GamePid, $GameName, [bool]$ForceOn)
Say 'waiting for game process (up to 90s)...'
$deadline = (Get-Date).AddSeconds(90)
$game = $null
while ($true) {
  $game = Get-GameProcess
  if ($game) { break }
  if ((Get-Date) -gt $deadline) {
    Say 'game process not found in 90s - exit'
    try { [PADK]::SDL_Quit() | Out-Null } catch { }
    exit 1
  }
  Start-Sleep -Milliseconds 400
}
Say ('game found: pid={0} name={1}' -f $game.Id, $game.ProcessName)

$gc = [IntPtr]::Zero
$padName = ''
$lastScan = [datetime]::MinValue
$script:lastWaitLog = [datetime]::MinValue
$waitAnnounced = $false
$wasActive = $false

try {
  while ($true) {
    # ---- is the game still there? (~500ms) ----
    $game = Get-GameProcess
    if (-not $game) { Log 'game exited'; break }

    # ---- controller hot-plug (~1.5s) ----
    $now = Get-Date
    if (($now - $lastScan).TotalMilliseconds -gt 1500) {
      $lastScan = $now
      $count = [PADK]::SDL_NumJoysticks()
      if ($gc -eq [IntPtr]::Zero) {
        if ($count -gt 0) {
          for ($i = 0; $i -lt $count; $i++) {
            if ([PADK]::SDL_IsGameController($i) -eq 1) {
              $h = [PADK]::SDL_GameControllerOpen($i)
              if ($h -ne [IntPtr]::Zero) {
                $gc = $h
                $padName = Get-SdlString ([PADK]::SDL_GameControllerName($h))
                $waitAnnounced = $false
                Say ('controller connected: ' + $padName)
                break
              }
            }
          }
        }
        if ($gc -eq [IntPtr]::Zero) {
          if (-not $waitAnnounced) {
            $waitAnnounced = $true
            $script:lastWaitLog = $now
            Say 'waiting for controller...'
          } elseif (($now - $script:lastWaitLog).TotalSeconds -ge 30) {
            $script:lastWaitLog = $now
            Log 'waiting for controller...'
          }
        }
      } elseif ($count -eq 0) {
        Release-All 'controller unplugged'
        [PADK]::SDL_GameControllerClose($gc) | Out-Null
        $gc = [IntPtr]::Zero
        Say ('controller disconnected: ' + $padName)
      }
    }

    # ---- foreground check (~150ms): inject only into the game ----
    if (-not $ForceOn) {
      $fg = [PADK]::GetForegroundWindow()
      $fgPid = [uint32]0
      [PADK]::GetWindowThreadProcessId($fg, [ref]$fgPid) | Out-Null
      $isGame = ($fgPid -eq $game.Id)
      if (-not $isGame -and $GamePid -eq 0 -and $GameName) {
        try { $isGame = ((Get-Process -Id $fgPid -ErrorAction Stop).ProcessName -ieq $GameName) } catch { }
      }
    } else {
      $isGame = $true
    }

    if (-not $isGame) {
      Release-All 'game not in foreground'
      if ($wasActive) { Say 'paused: game is not in the foreground'; $wasActive = $false }
      Start-Sleep -Milliseconds 150
      continue
    }
    if (-not $wasActive) { Say 'active: game is in the foreground'; $wasActive = $true }

    if ($gc -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 150; continue }

    try {
      [PADK]::SDL_GameControllerUpdate()
      $lx  = [PADK]::SDL_GameControllerGetAxis($gc, 0)
      $bA  = [PADK]::SDL_GameControllerGetButton($gc, $BTN_A)
      $bX  = [PADK]::SDL_GameControllerGetButton($gc, $BTN_X)
      $bLB = [PADK]::SDL_GameControllerGetButton($gc, $BTN_LB)
      $bRB = [PADK]::SDL_GameControllerGetButton($gc, $BTN_RB)
    } catch {
      Log ('read error: ' + $_.Exception.Message)
      $gc = [IntPtr]::Zero
      continue
    }

    $want = @{
      'L'      = ($lx -lt (-$DEAD))
      'R'      = ($lx -gt $DEAD)
      'JUMP'   = ($bX -ne 0)
      'CROUCH' = ($bA -ne 0)
      'FIRE'   = ($bLB -ne 0)
      'NADE'   = ($bRB -ne 0)
    }
    foreach ($k in $order) {
      if ($want[$k] -ne $held[$k]) {
        $vk = [int]$vkMap[$k]
        Send-Key $vk $want[$k]
        if ($want[$k]) { Log ('DOWN {0} (vk={1})' -f $k, $vk) } else { Log ('UP   {0} (vk={1})' -f $k, $vk) }
        $held[$k] = $want[$k]
      }
    }
    Start-Sleep -Milliseconds 12
  }
} finally {
  Release-All 'bridge stopping'
  if ($gc -ne [IntPtr]::Zero) { try { [PADK]::SDL_GameControllerClose($gc) | Out-Null } catch { } }
  try { [PADK]::SDL_Quit() | Out-Null } catch { }
}
Say 'bridge stopped'
