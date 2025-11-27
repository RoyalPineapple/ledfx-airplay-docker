# Airglow — AirPlay ➜ LedFX Stack

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Docker](https://img.shields.io/badge/Docker-20.10%2B-blue.svg)](https://www.docker.com/)

Airglow exposes a clean AirPlay 2 endpoint and routes the audio stream into LedFX.

## Features

- **Zero-Config AirPlay 2 Support** - Instantly appears as an AirPlay device on your network
- **No ALSA Configuration Required** - Uses PulseAudio for clean audio routing
- **Docker-Based** - Easy deployment with Docker Compose

## Architecture

```
AirPlay Device (iPhone/Mac)
    ↓ (AirPlay 2)
Shairport-Sync (AirPlay Receiver)
    ↓ (PulseAudio)
LedFX (Audio Visualization)
    ↓ (E1.31/UDP)
LED Strips/Devices
```

**How it works:**
- **LedFX** runs a PulseAudio server that Shairport connects to via Unix socket
- **Shairport-Sync** receives AirPlay audio streams and outputs to PulseAudio
- **Network mode: host** - Services use host networking for mDNS discovery and LED protocols

## Prerequisites

- **Linux Host** - Debian/Ubuntu recommended (see [Platform Support](#platform-support))
- **Docker Engine** - Version 20.10 or later
- **Docker Compose** - Version 2.0 or later (plugin version recommended)
- **Network Access** - mDNS/Avahi for AirPlay discovery (port 5353/UDP)
- **Permissions** - Root/sudo access for installation script

## Quick Start

### Method 1: Docker Compose (Manual)

1. Clone the repository and enter the directory:
   ```bash
   git clone https://github.com/RoyalPineapple/airglow.git
   cd airglow
   ```
2. Start the stack:
   ```bash
   docker compose up -d
   ```
3. Check status and logs:
   ```bash
   docker compose ps
   docker compose logs
   ```
4. Open the LedFX web UI: `http://localhost:8888`

### Method 2: Install Script (Automated)

Run the installer which handles Docker installation and setup:
```bash
chmod +x install.sh
sudo ./install.sh
```

## Configuration

### Web Interface

Airglow includes a web interface for status monitoring and configuration:

- **Status Dashboard**: `http://localhost:8080`
- **Configuration Page**: `http://localhost:8080/config`
- **LedFX Details**: `http://localhost:8080/ledfx`

The configuration page allows you to:
- Enable/disable AirPlay session hooks
- Select which LedFX virtuals to control
- Configure repeat counts per virtual (useful for Govee device reliability)
- All changes take effect dynamically (no restart required)

See [CONFIGURATION.md](CONFIGURATION.md) for detailed configuration documentation.

### Set AirPlay Device Name (Optional)
Edit `configs/shairport-sync.conf` and change the `name` field:
```
general = {
    name = "Airglow";  // Change this
    ...
}
```

### Configure LedFX Audio Settings
1. Open LedFX Settings tab: `http://localhost:8888/#/Settings`
2. Select "pulse" from the audio device dropdown
3. Click "Save" to apply

This connects LedFX to the PulseAudio monitor that receives audio from Shairport.

### Add LED Devices
1. Open LedFX Devices tab: `http://localhost:8888/#/Devices`
2. Add your Led devices
3. Configure effects and start visualizing

## Troubleshooting

### Check Services
```bash
# View container status
docker compose ps

# View logs
docker compose logs -f ledfx
docker compose logs -f shairport-sync
```

### Verify AirPlay Discovery
The AirPlay device "Airglow" should appear in your device's AirPlay menu. If not:
- Check that containers are running (`docker compose ps`)
- Verify network mode is `host`
- Ensure mDNS/Avahi is working on your network

### Check Audio Flow
Inside the LedFX container:
```bash
# List PulseAudio sources
docker exec ledfx pactl list sources short

# Check for Shairport audio stream
docker exec ledfx pactl list sink-inputs
```

You should see a "Shairport Sync" sink input when audio is playing.

### Debug PulseAudio
```bash
# Check Pulse socket
ls -la pulse/

# Verify Pulse server in LedFX
docker exec ledfx pactl info

# Check Shairport Pulse connection
docker logs shairport-sync | grep -i pulse
```

### Common Issues

**AirPlay device not showing up:**
- Restart containers: `docker compose restart`
- Check firewall allows mDNS (port 5353/UDP)

**No audio in LedFX:**
- Verify audio is playing to the AirPlay device
- Check PulseAudio sink-inputs (see above)
- In LedFX UI, confirm audio device is set to "pulse"

**Permission errors:**
- Ensure `pulse/` directory has correct permissions:
  ```bash
  sudo chown -R 1000:1000 pulse/
  ```

## Updating

Pull latest images and restart:
```bash
docker compose pull
docker compose up -d
```

## Ports

- **8888** - LedFX web UI (HTTP)
- **7000** - Shairport-Sync AirPlay (TCP)
- **5353** - mDNS/Avahi discovery (UDP)

## Architecture Details

### PulseAudio Bridge

This setup uses a PulseAudio socket to route audio between containers:

1. LedFX container runs PulseAudio in server mode
2. Creates socket at `./pulse/pulseaudio.socket`
3. Shairport-Sync connects as Pulse client via this socket
4. LedFX reads from the Pulse monitor source (`auto_null.monitor`)

**Benefits:**
- No ALSA loopback configuration needed
- Clean container isolation
- Reliable audio routing
- Easy to debug with `pactl` commands

### Why Host Networking?

- **mDNS Discovery**: AirPlay uses mDNS/Bonjour for device discovery
- **E1.31/UDP**: LED protocols work better with direct host access
- **Simplified Routing**: No port mapping needed

**Security Note:** Host networking gives containers direct access to the host's network stack. Only run this stack on trusted networks.

## Platform Support

This project is designed for Linux systems, specifically:

- **Tested on:** Debian 11+, Ubuntu 20.04+ (x86_64)
- **Not supported:** macOS (Docker Desktop networking limitations), Windows

For non-Debian systems, you may need to manually install Docker and adapt the installation script.

## Contributing

Contributions are welcome! Here's how you can help:

1. **Report Issues** - Found a bug? Open an issue with details about your setup
2. **Suggest Improvements** - Have ideas for better configuration or documentation?
3. **Submit Pull Requests** - Fix bugs or add features (please discuss major changes first)

### Development Guidelines

- Test changes with `docker compose up` before submitting
- Update documentation for any configuration changes
- Follow existing code style and formatting
- Keep commits focused and write clear commit messages

## Support

- **Issues & Bugs:** [GitHub Issues](https://github.com/RoyalPineapple/airglow/issues)
- **Discussions:** [GitHub Discussions](https://github.com/RoyalPineapple/airglow/discussions)
- **LedFX Project:** [https://github.com/LedFX/LedFX](https://github.com/LedFX/LedFX)
- **Shairport Sync:** [https://github.com/mikebrady/shairport-sync](https://github.com/mikebrady/shairport-sync)

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

This is a Docker orchestration project that combines:
- [LedFX](https://github.com/LedFX/LedFX) - Licensed under GPL-3.0
- [Shairport Sync](https://github.com/mikebrady/shairport-sync) - Licensed under multiple licenses

Please review the individual project licenses for their respective terms.

