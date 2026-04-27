# connect-bt-audio.ps1 - Connect a paired Bluetooth audio device and set it as the default output.
#
# Usage:
#   .\connect-bt-audio.ps1                    # List paired Bluetooth devices
#   .\connect-bt-audio.ps1 AirPods            # Connect device matching "AirPods"
#   .\connect-bt-audio.ps1 "WH-1000XM5"      # Connect Sony headphones
#   .\connect-bt-audio.ps1 -DeviceName Bose   # Connect Bose headphones
#
# How it works:
#   1. Compiles a small C# helper (btconnect.exe) on first run using WinRT APIs
#   2. Opens a persistent RFCOMM Bluetooth socket to the device
#   3. Waits for Windows to negotiate audio profiles (A2DP/HFP)
#   4. Sets the device as the default audio output
#
# Requirements:
#   - Windows 10/11 with .NET Framework 4.5+
#   - PowerShell 5.1 (ships with Windows)
#   - AudioDeviceCmdlets module (auto-installed from PSGallery on first run)
#   - Device must already be paired in Windows Bluetooth settings

#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$DeviceName,

    [int]$RetryCount = 12,
    [int]$RetryDelaySeconds = 3
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Ensure AudioDeviceCmdlets module
# ---------------------------------------------------------------------------
function Ensure-AudioDeviceCmdlets {
    if (-not (Get-Module -ListAvailable -Name 'AudioDeviceCmdlets')) {
        Write-Host "[*] Installing AudioDeviceCmdlets from PSGallery..."
        if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 `
                -Scope CurrentUser -Force | Out-Null
        }
        Install-Module -Name AudioDeviceCmdlets -Scope CurrentUser -Force
    }
    Import-Module AudioDeviceCmdlets -ErrorAction Stop
}

# ---------------------------------------------------------------------------
# Compile btconnect.exe (cached next to this script - only runs once)
# ---------------------------------------------------------------------------
$script:BtExePath = Join-Path $PSScriptRoot 'btconnect.exe'

function Build-BluetoothHelper {
    if (Test-Path $script:BtExePath) { return }

    $csFile = [IO.Path]::GetTempFileName()
    Set-Content -Path $csFile -Value @'
using System;
using System.Threading;
using Windows.Devices.Bluetooth;
using Windows.Devices.Bluetooth.Rfcomm;
using Windows.Devices.Enumeration;
using Windows.Foundation;
using Windows.Networking.Sockets;

class Program {
    static T AwaitOp<T>(IAsyncOperation<T> op) {
        int ms = 0;
        while (op.Status == AsyncStatus.Started) {
            Thread.Sleep(100);
            ms += 100;
            if (ms > 30000) { Console.Error.WriteLine("TIMEOUT"); Environment.Exit(1); }
        }
        if (op.Status != AsyncStatus.Completed) {
            Console.Error.WriteLine("ASYNC_FAIL:" + op.Status);
            Environment.Exit(1);
        }
        return op.GetResults();
    }

    static void AwaitAction(IAsyncAction action) {
        int ms = 0;
        while (action.Status == AsyncStatus.Started) {
            Thread.Sleep(100);
            ms += 100;
            if (ms > 30000) { Console.Error.WriteLine("TIMEOUT"); Environment.Exit(1); }
        }
        if (action.Status != AsyncStatus.Completed) {
            Console.Error.WriteLine("ACTION_FAIL:" + action.Status +
                " err=" + action.ErrorCode.HResult.ToString("X"));
            Environment.Exit(1);
        }
    }

    static void Main(string[] args) {
        string mode   = args.Length > 0 ? args[0] : "list";
        string filter = args.Length > 1 ? args[1] : "";

        string selector = BluetoothDevice.GetDeviceSelectorFromPairingState(true);
        var devices = AwaitOp(DeviceInformation.FindAllAsync(selector));

        if (mode == "list") {
            foreach (var d in devices)
                Console.WriteLine(d.Name + "\t" + d.Id);
            return;
        }

        if (mode == "connect") {
            DeviceInformation target = null;
            foreach (var d in devices) {
                if (filter.Length == 0 ||
                    d.Name.IndexOf(filter, StringComparison.OrdinalIgnoreCase) >= 0) {
                    target = d;
                    break;
                }
            }
            if (target == null) {
                Console.Error.WriteLine("NOT_FOUND");
                Environment.Exit(1);
            }
            Console.WriteLine("FOUND\t" + target.Name);

            var btDevice = AwaitOp(BluetoothDevice.FromIdAsync(target.Id));
            if (btDevice == null) {
                Console.Error.WriteLine("DEVICE_NULL");
                Environment.Exit(1);
            }

            var svcResult = AwaitOp(
                btDevice.GetRfcommServicesAsync(BluetoothCacheMode.Uncached));

            Console.WriteLine("RFCOMM\t" + svcResult.Error + "\t" +
                              svcResult.Services.Count);

            if (svcResult.Services.Count == 0) {
                Console.Error.WriteLine("NO_SERVICES");
                Thread.Sleep(90000);
                Environment.Exit(1);
            }

            // Open a persistent StreamSocket to the first RFCOMM service.
            // This creates a real Bluetooth data channel that keeps the ACL
            // radio link alive, giving Windows time to negotiate A2DP/HFP.
            var service = svcResult.Services[0];
            Console.WriteLine("CONNECTING\t" + service.ServiceId.Uuid);

            var socket = new StreamSocket();
            try {
                AwaitAction(socket.ConnectAsync(
                    service.ConnectionHostName,
                    service.ConnectionServiceName,
                    SocketProtectionLevel.BluetoothEncryptionAllowNullAuthentication));
                Console.WriteLine("SOCKET_CONNECTED");
            } catch (Exception ex) {
                Console.WriteLine("SOCKET_FAIL\t" + ex.Message);
            }

            // Hold connection alive (PowerShell kills us when audio is ready)
            Console.WriteLine("HOLDING");
            Console.Out.Flush();
            Thread.Sleep(90000);
        }
    }
}
'@

    $csc = "$env:SystemRoot\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    $srt = "$env:SystemRoot\Microsoft.NET\Framework64\v4.0.30319\System.Runtime.dll"
    $wmd = "$env:SystemRoot\System32\WinMetadata"

    Write-Host "[*] Compiling btconnect.exe (first run only)..."
    $output = & $csc /nologo /target:exe "/out:$($script:BtExePath)" `
        "/r:$srt" `
        "/r:$wmd\Windows.Devices.winmd" `
        "/r:$wmd\Windows.Foundation.winmd" `
        "/r:$wmd\Windows.Networking.winmd" `
        $csFile 2>&1

    Remove-Item $csFile -ErrorAction SilentlyContinue

    if ($LASTEXITCODE -ne 0) { throw "Compilation failed:`n$output" }
    Write-Host "[+] btconnect.exe compiled."
}

# ---------------------------------------------------------------------------
# List paired Bluetooth devices
# ---------------------------------------------------------------------------
function Get-PairedBluetoothDevices {
    $lines = & $script:BtExePath list 2>&1
    if ($LASTEXITCODE -ne 0) { throw "btconnect.exe list failed: $lines" }

    $devices = @()
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = "$line" -split "`t", 2
        if ($parts.Count -ge 2) { $devices += @{ Name = $parts[0]; Id = $parts[1] } }
    }
    return $devices
}

# ---------------------------------------------------------------------------
# Find a specific paired device by name pattern
# ---------------------------------------------------------------------------
function Find-PairedBluetoothDevice {
    param([string]$NamePattern)

    $devices = Get-PairedBluetoothDevices

    if ($devices.Count -eq 0) { throw "No paired Bluetooth devices found." }

    Write-Host "[*] Found $($devices.Count) paired device(s):"
    $match = $null
    foreach ($d in $devices) {
        Write-Host "      - $($d.Name)"
        if ($d.Name -like $NamePattern -and $null -eq $match) { $match = $d }
    }

    if ($null -eq $match) {
        throw "No device matching '$NamePattern'.`nUse -DeviceName with a different name, or run without arguments to list devices."
    }

    Write-Host "[+] Matched: '$($match.Name)'"
    return $match
}

# ---------------------------------------------------------------------------
# Connect + wait for audio (background exe + audio polling)
# ---------------------------------------------------------------------------
function Connect-AndWaitForAudio {
    param(
        [string]$SearchTerm,
        [string]$AudioPattern,
        [int]$RetryCount,
        [int]$RetryDelaySeconds
    )

    $totalSecs = $RetryCount * $RetryDelaySeconds
    Write-Host ""
    Write-Host "[*] Opening persistent Bluetooth connection (up to ${totalSecs}s)..."
    Write-Host "    Tip: If your device connected to another device (e.g. phone), disconnect it there."
    Write-Host ""

    $outFile = Join-Path ([IO.Path]::GetTempPath()) 'btconnect_out.txt'
    $errFile = Join-Path ([IO.Path]::GetTempPath()) 'btconnect_err.txt'

    $bgProc = Start-Process -FilePath $script:BtExePath `
        -ArgumentList "connect", $SearchTerm `
        -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $outFile `
        -RedirectStandardError  $errFile

    Start-Sleep -Seconds 5

    if ($bgProc.HasExited) {
        $err = if (Test-Path $errFile) { Get-Content $errFile -Raw } else { "unknown" }
        $out = if (Test-Path $outFile) { Get-Content $outFile -Raw } else { "" }
        throw "btconnect.exe exited early:`nstdout: $out`nstderr: $err"
    }

    if (Test-Path $outFile) {
        $btOutput = Get-Content $outFile -ErrorAction SilentlyContinue
        foreach ($line in $btOutput) {
            if ("$line" -match '^FOUND')            { Write-Host "[+] Device located." }
            if ("$line" -match '^RFCOMM')            { Write-Host "[+] RFCOMM services queried." }
            if ("$line" -match '^SOCKET_CONNECTED')  { Write-Host "[+] Persistent Bluetooth socket connected!" }
            if ("$line" -match '^SOCKET_FAIL')       { Write-Warning "Socket failed: $line (still holding link)" }
            if ("$line" -match '^HOLDING')           { Write-Host "[+] Connection held open. Waiting for audio..." }
        }
    }

    try {
        for ($i = 1; $i -le $RetryCount; $i++) {
            Write-Host "[*] Checking for audio endpoint ($i of $RetryCount)..."

            $playback = Get-AudioDevice -List | Where-Object { $_.Type -eq 'Playback' }
            $candidates = @($playback | Where-Object { $_.Name -like $AudioPattern })
            $match = ($candidates | Where-Object { $_.Name -notlike "*Headset*" } |
                      Select-Object -First 1)
            if ($null -eq $match -and $candidates.Count -gt 0) { $match = $candidates[0] }

            if ($null -ne $match) {
                Write-Host "[+] Audio endpoint found: '$($match.Name)'"
                return @{ AudioDevice = $match; BgProcess = $bgProc }
            }

            if ($i -lt $RetryCount) {
                Write-Host "    Not yet. Waiting ${RetryDelaySeconds}s..."
                Start-Sleep -Seconds $RetryDelaySeconds
            }
        }

        # Timeout - kill the background process and throw
        if (-not $bgProc.HasExited) {
            Stop-Process -Id $bgProc.Id -Force -ErrorAction SilentlyContinue
        }
        throw "Audio endpoint did not appear after ${totalSecs}s.`nMake sure your device is out of any case and not connected to another device."
    } catch {
        if (-not $bgProc.HasExited) {
            Stop-Process -Id $bgProc.Id -Force -ErrorAction SilentlyContinue
        }
        throw
    }
}

# ---------------------------------------------------------------------------
# Set default audio output
# ---------------------------------------------------------------------------
function Set-DefaultAudioOutput {
    param([object]$AudioDevice)

    Write-Host "[*] Setting '$($AudioDevice.Name)' as default playback device..."
    Set-AudioDevice -Index $AudioDevice.Index | Out-Null
    Write-Host "[*] Setting '$($AudioDevice.Name)' as default communication device..."
    Set-AudioDevice -Index $AudioDevice.Index -CommunicationOnly | Out-Null

    $default = Get-AudioDevice -Playback
    if ($default.ID -eq $AudioDevice.ID) {
        Write-Host "[+] SUCCESS: '$($AudioDevice.Name)' is now the default audio output."
    } else {
        Write-Warning "Default playback is still '$($default.Name)' - you may need to switch manually."
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
try {
    Build-BluetoothHelper

    # No device name given - list mode
    if ([string]::IsNullOrWhiteSpace($DeviceName)) {
        $devices = Get-PairedBluetoothDevices
        if ($devices.Count -eq 0) {
            Write-Host "No paired Bluetooth devices found."
        } else {
            Write-Host "Paired Bluetooth devices:"
            foreach ($d in $devices) {
                Write-Host "  - $($d.Name)"
            }
            Write-Host ""
            Write-Host "Usage: .\connect-bt-audio.ps1 <device-name>"
            Write-Host "  e.g. .\connect-bt-audio.ps1 AirPods"
        }
        exit 0
    }

    # Connect mode
    Write-Host "=== Connecting: $DeviceName ==="
    Write-Host ""

    Ensure-AudioDeviceCmdlets

    $namePattern = "*$DeviceName*"
    $device = Find-PairedBluetoothDevice -NamePattern $namePattern

    $result = Connect-AndWaitForAudio `
        -SearchTerm $DeviceName `
        -AudioPattern $namePattern `
        -RetryCount $RetryCount `
        -RetryDelaySeconds $RetryDelaySeconds

    Set-DefaultAudioOutput -AudioDevice $result.AudioDevice

    # Give A2DP time to fully establish the audio stream before
    # releasing the RFCOMM socket (A2DP uses L2CAP separately)
    Write-Host "[*] Stabilizing audio connection..."
    Start-Sleep -Seconds 5

    # Release the RFCOMM channel so the Windows audio driver can use it
    if (-not $result.BgProcess.HasExited) {
        Stop-Process -Id $result.BgProcess.Id -Force -ErrorAction SilentlyContinue
    }
    Write-Host "[+] Bluetooth helper released."

    Write-Host ""
    Write-Host "=== Done ==="
} catch {
    Write-Error "FAILED: $_"
    exit 1
}
