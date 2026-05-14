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
    if ((Test-Path $script:BtExePath) -and
        (Get-Item $script:BtExePath).LastWriteTime -ge (Get-Item $PSCommandPath).LastWriteTime) {
        return
    }

    $csFile = [IO.Path]::GetTempFileName()
    Set-Content -Path $csFile -Value @'
using System;
using System.Runtime.InteropServices;
using System.Threading;
using Windows.Devices.Bluetooth;
using Windows.Devices.Bluetooth.Rfcomm;
using Windows.Devices.Enumeration;
using Windows.Foundation;
using Windows.Networking.Sockets;

class Program {
    [StructLayout(LayoutKind.Sequential)]
    struct BLUETOOTH_FIND_RADIO_PARAMS { public uint dwSize; }

    [StructLayout(LayoutKind.Sequential)]
    struct SYSTEMTIME {
        public ushort wYear, wMonth, wDayOfWeek, wDay;
        public ushort wHour, wMinute, wSecond, wMilliseconds;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct BLUETOOTH_DEVICE_INFO {
        public uint dwSize;
        public ulong Address;
        public uint ulClassofDevice;
        [MarshalAs(UnmanagedType.Bool)] public bool fConnected;
        [MarshalAs(UnmanagedType.Bool)] public bool fRemembered;
        [MarshalAs(UnmanagedType.Bool)] public bool fAuthenticated;
        public SYSTEMTIME stLastSeen;
        public SYSTEMTIME stLastUsed;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 248)]
        public string szName;
    }

    [DllImport("BluetoothAPIs.dll", SetLastError = true)]
    static extern IntPtr BluetoothFindFirstRadio(
        ref BLUETOOTH_FIND_RADIO_PARAMS pbtfrp, out IntPtr phRadio);

    [DllImport("BluetoothAPIs.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool BluetoothFindRadioClose(IntPtr hFind);

    [DllImport("BluetoothAPIs.dll", SetLastError = true)]
    static extern uint BluetoothSetServiceState(
        IntPtr hRadio, ref BLUETOOTH_DEVICE_INFO pbtdi,
        ref Guid pGuidService, uint dwServiceFlags);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool CloseHandle(IntPtr hObject);

    static readonly Guid A2DP_SINK_UUID =
        new Guid("0000110b-0000-1000-8000-00805f9b34fb");
    const uint BLUETOOTH_SERVICE_DISABLE = 0x00;
    const uint BLUETOOTH_SERVICE_ENABLE  = 0x01;

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

    static bool CycleBluetoothService(ulong bluetoothAddress) {
        var radioParams = new BLUETOOTH_FIND_RADIO_PARAMS();
        radioParams.dwSize = (uint)Marshal.SizeOf(typeof(BLUETOOTH_FIND_RADIO_PARAMS));

        IntPtr hRadio;
        IntPtr hFind = BluetoothFindFirstRadio(ref radioParams, out hRadio);
        if (hFind == IntPtr.Zero) {
            Console.Error.WriteLine("RADIO_NOT_FOUND");
            return false;
        }
        BluetoothFindRadioClose(hFind);

        var btdi = new BLUETOOTH_DEVICE_INFO();
        btdi.dwSize = (uint)Marshal.SizeOf(typeof(BLUETOOTH_DEVICE_INFO));
        btdi.Address = bluetoothAddress;

        Console.WriteLine("CYCLING_SERVICE");

        Guid svc = A2DP_SINK_UUID;
        uint result = BluetoothSetServiceState(
            hRadio, ref btdi, ref svc, BLUETOOTH_SERVICE_DISABLE);
        if (result != 0) {
            Console.Error.WriteLine("DISABLE_FAILED\t" + result);
            CloseHandle(hRadio);
            return false;
        }
        Console.WriteLine("SERVICE_DISABLED");

        Thread.Sleep(3000);

        result = BluetoothSetServiceState(
            hRadio, ref btdi, ref svc, BLUETOOTH_SERVICE_ENABLE);
        if (result != 0) {
            Console.Error.WriteLine("ENABLE_FAILED\t" + result);
            CloseHandle(hRadio);
            return false;
        }
        Console.WriteLine("SERVICE_ENABLED");

        CloseHandle(hRadio);
        Thread.Sleep(2000);
        return true;
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

        if (mode == "connect" || mode == "reconnect") {
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

            if (mode == "reconnect") {
                if (!CycleBluetoothService(btDevice.BluetoothAddress)) {
                    Console.Error.WriteLine("CYCLE_FAILED");
                }
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
        [string]$Mode = "connect",
        [int]$RetryCount,
        [int]$RetryDelaySeconds
    )

    $totalSecs = $RetryCount * $RetryDelaySeconds
    Write-Host ""
    if ($Mode -eq 'reconnect') {
        Write-Host "[*] Cycling Bluetooth audio service to force a fresh connection..."
    } else {
        Write-Host "[*] Opening persistent Bluetooth connection (up to ${totalSecs}s)..."
        Write-Host "    Tip: If your device connected to another device (e.g. phone), disconnect it there."
    }
    Write-Host ""

    $outFile = Join-Path ([IO.Path]::GetTempPath()) 'btconnect_out.txt'
    $errFile = Join-Path ([IO.Path]::GetTempPath()) 'btconnect_err.txt'

    $bgProc = Start-Process -FilePath $script:BtExePath `
        -ArgumentList $Mode, $SearchTerm `
        -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $outFile `
        -RedirectStandardError  $errFile

    $initialWait = if ($Mode -eq 'reconnect') { 12 } else { 5 }
    Start-Sleep -Seconds $initialWait

    if ($bgProc.HasExited) {
        $err = if (Test-Path $errFile) { Get-Content $errFile -Raw } else { "unknown" }
        $out = if (Test-Path $outFile) { Get-Content $outFile -Raw } else { "" }
        if ($Mode -eq 'reconnect' -and $err -match 'DISABLE_FAILED|CYCLE_FAILED') {
            throw "Could not cycle Bluetooth service (may need admin).`nTry disconnecting manually in Settings > Bluetooth, then run this script again.`nstderr: $err"
        }
        throw "btconnect.exe exited early:`nstdout: $out`nstderr: $err"
    }

    if (Test-Path $outFile) {
        $btOutput = Get-Content $outFile -ErrorAction SilentlyContinue
        foreach ($line in $btOutput) {
            if ("$line" -match '^FOUND')             { Write-Host "[+] Device located." }
            if ("$line" -match '^CYCLING_SERVICE')   { Write-Host "[*] Disabling A2DP service..." }
            if ("$line" -match '^SERVICE_DISABLED')  { Write-Host "[+] A2DP service disabled." }
            if ("$line" -match '^SERVICE_ENABLED')   { Write-Host "[+] A2DP service re-enabled." }
            if ("$line" -match '^RFCOMM')            { Write-Host "[+] RFCOMM services queried." }
            if ("$line" -match '^SOCKET_CONNECTED')  { Write-Host "[+] Persistent Bluetooth socket connected!" }
            if ("$line" -match '^SOCKET_FAIL')       { Write-Warning "Socket failed: $line (still holding link)" }
            if ("$line" -match '^HOLDING')           { Write-Host "[+] Connection held open. Waiting for audio..." }
        }
    }

    if ($Mode -eq 'reconnect') {
        $errContent = if (Test-Path $errFile) { Get-Content $errFile -Raw } else { "" }
        if ($errContent -match 'DISABLE_FAILED|CYCLE_FAILED') {
            if (-not $bgProc.HasExited) {
                Stop-Process -Id $bgProc.Id -Force -ErrorAction SilentlyContinue
            }
            throw "Could not cycle Bluetooth service (may need admin).`nTry disconnecting manually in Settings > Bluetooth, then run this script again."
        }
    }

    try {
        # In reconnect mode, wait for the stale endpoint to disappear first
        if ($Mode -eq 'reconnect') {
            for ($w = 1; $w -le 5; $w++) {
                $stale = Get-AudioDevice -List | Where-Object {
                    $_.Type -eq 'Playback' -and $_.Name -like $AudioPattern -and
                    $_.Name -notlike "*Headset*" -and $_.Name -notlike "*Find My*"
                }
                if ($null -eq $stale) {
                    Write-Host "[+] Stale audio endpoint removed. Waiting for fresh connection..."
                    break
                }
                if ($w -eq 5) {
                    Write-Warning "Stale endpoint persisted - polling for a fresh one anyway."
                }
                Start-Sleep -Seconds 2
            }
        }

        for ($i = 1; $i -le $RetryCount; $i++) {
            Write-Host "[*] Checking for audio endpoint ($i of $RetryCount)..."

            $playback = Get-AudioDevice -List | Where-Object { $_.Type -eq 'Playback' }
            $candidates = @($playback | Where-Object { $_.Name -like $AudioPattern })
            $match = ($candidates | Where-Object {
                $_.Name -notlike "*Headset*" -and $_.Name -notlike "*Find My*"
            } | Select-Object -First 1)

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

    $default = Get-AudioDevice -Playback
    if ($default.ID -eq $AudioDevice.ID) {
        Write-Host "[+] SUCCESS: '$($AudioDevice.Name)' is now the default audio output (A2DP stereo)."
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

    # Detect stale connection: audio endpoint exists but audio may not be flowing
    $mode = "connect"
    $playback = Get-AudioDevice -List | Where-Object { $_.Type -eq 'Playback' }
    $staleEndpoint = $playback | Where-Object {
        $_.Name -like $namePattern -and
        $_.Name -notlike "*Headset*" -and
        $_.Name -notlike "*Find My*"
    } | Select-Object -First 1

    if ($null -ne $staleEndpoint) {
        Write-Host ""
        Write-Host "[!] '$($staleEndpoint.Name)' is already connected but audio may be stale."
        Write-Host "    Forcing a reconnect to re-establish the audio stream..."
        $mode = "reconnect"
    }

    $result = Connect-AndWaitForAudio `
        -SearchTerm $DeviceName `
        -AudioPattern $namePattern `
        -Mode $mode `
        -RetryCount $RetryCount `
        -RetryDelaySeconds $RetryDelaySeconds

    Set-DefaultAudioOutput -AudioDevice $result.AudioDevice

    # Let btconnect.exe keep the RFCOMM socket alive in the background.
    # It will exit on its own after 90s. This ensures the Bluetooth link
    # stays up while A2DP fully stabilizes (sometimes takes 10-15s).
    Write-Host "[+] Bluetooth helper running in background (exits automatically)."

    Write-Host ""
    Write-Host "=== Done ==="
} catch {
    Write-Error "FAILED: $_"
    exit 1
}
