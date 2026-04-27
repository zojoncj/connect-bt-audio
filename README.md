# connect-bt-audio

Connect a paired Bluetooth audio device and set it as the default output - from the terminal, no GUI needed.

Built for Windows 10/11. Works with AirPods, Sony WH-1000XM series, Bose, and any other Bluetooth audio device.

## Usage

```powershell
# List paired Bluetooth devices
.\connect-bt-audio.ps1

# Connect a device by name
.\connect-bt-audio.ps1 AirPods
.\connect-bt-audio.ps1 "WH-1000XM5"
.\connect-bt-audio.ps1 Bose
```

## How it works

1. On first run, compiles a small C# helper (`btconnect.exe`) using the built-in .NET compiler and WinRT APIs
2. Opens a persistent RFCOMM Bluetooth socket to the device, keeping the radio link alive
3. Waits for Windows to negotiate audio profiles (A2DP for stereo, HFP for mic)
4. Sets the device as both the default playback and communication device
5. Releases the socket once the audio connection is stable

## Requirements

- Windows 10 or 11
- PowerShell 5.1 (ships with Windows)
- .NET Framework 4.5+ (ships with Windows)
- Device must already be paired in Windows Bluetooth settings
- [AudioDeviceCmdlets](https://www.powershellgallery.com/packages/AudioDeviceCmdlets) module (auto-installed on first run)

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `DeviceName` | *(none - lists devices)* | Name (or partial name) of the Bluetooth device to connect |
| `RetryCount` | 12 | Number of attempts to wait for the audio endpoint |
| `RetryDelaySeconds` | 3 | Seconds between each attempt |

## Tips

- If your device auto-connects to your phone, disconnect it there first or just wait - the script will keep trying
- Add a shortcut to your PowerShell profile for quick access:
  ```powershell
  # Add to $PROFILE
  function bt { & "$HOME\bt\connect-bt-audio.ps1" @args }
  ```
  Then just run `bt AirPods`

## Generated files

`btconnect.exe` is compiled automatically on first run and cached next to the script. It's safe to delete - it will be regenerated.
