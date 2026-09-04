# Football Drone Simulator

A local-first FAI F9A-B drone soccer training simulator. The desktop app runs
the simulation and serves a low-latency, landscape phone controller over the
same Wi-Fi network. No account, cloud service, or Internet connection is used
during play.

## Download and install

Download the latest ready-to-run release directly:

- [Windows 10/11 x64 installer](https://github.com/Lowis-Mamilton/footballdrone_simulator/releases/download/v1.0.0/FootballDroneSimulator-1.0.0-win-x64-setup.exe)
- [macOS Universal app for Apple Silicon and Intel](https://github.com/Lowis-Mamilton/footballdrone_simulator/releases/download/v1.0.0/FootballDroneSimulator-1.0.0-macOS-universal.zip)

On Windows, run the installer and approve the private-network firewall prompt
so a phone on the same Wi-Fi can connect. The unsigned installer may trigger
Microsoft SmartScreen; select **More info > Run anyway**.

On macOS, unzip the download, move **Football Drone Simulator.app** to
**Applications**, then use **Control-click > Open** the first time. Allow local
network access when prompted. This build is unsigned and unnotarized, so macOS
may display a Gatekeeper warning.

## Version 1.0.0

- Godot 4.7 desktop simulator for Windows 10/11 x64 and Universal macOS builds
  for Apple Silicon and Intel.
- 20 cm, sub-300 g configurable drone ball with four-motor thrust, reaction
  torque, motor lag, drag, fixed-step PID control, and cage collision physics.
- Angle and Acro modes, arm safety, disconnect failsafe, instant reset, and
  turtle recovery.
- FAI-sized 6 x 3 x 3 m arena, 40 cm goal openings, LOS, follow, and FPV
  cameras, orientation LEDs, procedural motor/impact audio, and training markers.
- QR pairing, a 60 Hz WebSocket input protocol, one-controller enforcement,
  sequence checks, RTT display, and a 250 ms failsafe.
- Responsive iOS Safari / Android Chrome control page with Mode 1, Mode 2, and
  custom desktop-configured axis mapping.
- Free flight plus six scored lessons, Bronze/Silver/Gold thresholds, and local
  personal bests.
- Stable, Standard, and Responsive presets; advanced PID, Rates, physics, and
  controller settings; versioned JSON import/export.

The included presets are informed generic starting points. They are not yet
validated against a particular commercial drone or flight log.

## Run in development

1. Install or download Godot 4.7.2 Standard (not .NET).
2. Open `project.godot`, or run:

   ```powershell
   .\scripts\run-dev.ps1 -GodotPath "C:\path\to\Godot_v4.7.2-stable_win64.exe"
   ```

3. Start the project, choose **PAIR**, and scan the QR code with a phone on the
   same Wi-Fi. Allow Windows private-network access if prompted.
4. Keep the phone in landscape, lower throttle, then arm.

Keyboard fallback is available for development: `R/F` throttle, `W/S` pitch,
`A/D` roll, `Q/E` yaw, `Space` arm, and `C` camera.

## Tests

Static data, schema, resource, and browser JavaScript checks:

```powershell
npm.cmd test
```

Godot logic tests:

```powershell
godot --headless --path . --script res://tests/godot/test_runner.gd
```

Runtime smoke test:

```powershell
godot --headless --path . --quit-after 360
Invoke-WebRequest http://127.0.0.1:41730/health
```

With a simulator instance running under the fixed test token, the integration
suite exercises HTTP delivery, authenticated WebSocket input, real rigid-body
lift, status delivery, and the 250 ms failsafe:

```powershell
godot --headless --path . -- --pairing-token=0123456789abcdef0123456789abcdef
npm.cmd run test:integration
```

## Windows build

Install the matching Godot export templates, then run:

```powershell
.\scripts\build-windows.ps1 -GodotPath "C:\path\to\Godot.exe"
```

Pass `-InnoSetupPath "C:\path\to\ISCC.exe"` to also build the installer. The
installer adds an inbound Windows Firewall rule restricted to private network
profiles and removes it during uninstall. User profiles and results are retained
unless `scripts/remove-user-data.ps1` is run and explicitly confirmed.

The installer is unsigned and may trigger Microsoft SmartScreen. Production
releases should configure a real code-signing certificate while keeping the PCK
separate from the executable.

## macOS build

Install the matching Godot export templates, then build a Universal archive for
Intel and Apple Silicon Macs:

```powershell
.\scripts\build-macos.ps1 -GodotPath "C:\path\to\Godot.exe"
```

The resulting `.zip` contains a standard macOS `.app` bundle. This development
build is unsigned and unnotarized, so Gatekeeper may require the recipient to
open it from Finder using **Control-click > Open**. Public distribution should
use an Apple Developer ID certificate and notarization.

## Module seams

- `src/core/flight_controller.gd`: normalized input to four motor commands.
- `src/sim/drone_ball.gd`: rigid-body dynamics, collision, recovery, and audio.
- `src/network/control_server.gd`: pairing, protocol, ordering, status, and
  failsafe; a future gamepad adapter can provide the same `DroneInputFrame`.
- `src/training/lesson_manager.gd`: lesson state, objectives, scoring, and bests.
- `src/data/profile_store.gd`: validated, atomic, versioned local persistence.

Third-party notices are recorded in `THIRD_PARTY_NOTICES.md`.
