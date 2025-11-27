# Airglow Configuration Guide

## Overview

Airglow uses a YAML-based configuration system for managing AirPlay session hooks and LedFX virtual control. The configuration is managed through a web interface and stored in `/configs/ledfx-hooks.yaml`. Changes take effect dynamically without requiring container restarts.

## Configuration File Structure

The configuration file is located at `/configs/ledfx-hooks.yaml` and follows this structure:

```yaml
ledfx:
  host: localhost
  port: 8888

hooks:
  start:
    enabled: true
    virtuals: []  # Empty list = control all virtuals
  end:
    enabled: true
    virtuals: []  # Empty list = control all virtuals
```

### LedFX Connection

- **host**: LedFX API hostname (default: `localhost`)
- **port**: LedFX API port (default: `8888`)

### Hooks Configuration

Each hook (start/end) has two properties:

- **enabled**: Boolean to enable/disable the hook
- **virtuals**: List of virtual configurations

#### Virtual Configuration

When `virtuals` is an empty list (`[]`), all LedFX virtuals are controlled by that hook.

To control specific virtuals, provide a list of virtual objects:

```yaml
hooks:
  start:
    enabled: true
    virtuals:
      - id: dig-quad
        repeats: 1
      - id: floor-lamp-1
        repeats: 2
  end:
    enabled: true
    virtuals:
      - id: dig-quad
        repeats: 1
      - id: floor-lamp-1
        repeats: 0  # 0 means don't control this virtual
```

Each virtual object contains:
- **id**: The LedFX virtual ID (e.g., `dig-quad`, `floor-lamp-1`)
- **repeats**: Number of times to repeat the command (1-10, default: 1)
  - For start hook: Number of times to activate the virtual
  - For end hook: Number of times to deactivate the virtual
  - Use `0` to exclude a virtual from a hook

## Web Interface

Access the configuration page at: `http://airglow.office.lab:8080/config`

### Start Hook Section

- **Toggle**: Enable/disable the start hook
- **Virtuals List**: Configure which virtuals are controlled when AirPlay session starts
  - "All Virtuals" checkbox: When checked, controls all virtuals (clears individual selections)
  - Individual checkboxes: Select specific virtuals
  - Repeat inputs: Set repeat count for each virtual (1-10)

### End Hook Section

- **Toggle**: Enable/disable the end hook
- **Virtuals List**: Configure which virtuals are controlled when AirPlay session ends
  - "All Virtuals" checkbox: When checked, controls all virtuals (clears individual selections)
  - Individual checkboxes: Select specific virtuals
  - Repeat inputs: Set repeat count for each virtual (1-10)
  - Use `0` repeats to exclude a virtual from the end hook

### LedFX Connection

- **Host**: LedFX API hostname
- **Port**: LedFX API port

## How It Works

### Hook Execution Flow

1. **AirPlay Session Starts** → `ledfx-session-hook.sh start` is called
   - Checks if start hook is enabled in YAML
   - If enabled, calls `ledfx-start.sh` with configured virtuals
   - Each virtual is activated the specified number of times (repeats)

2. **AirPlay Session Ends** → `ledfx-session-hook.sh stop` is called
   - Checks if end hook is enabled in YAML
   - If enabled, calls `ledfx-stop.sh` with configured virtuals
   - Each virtual is deactivated the specified number of times (repeats)

### Script Behavior

#### `ledfx-session-hook.sh`

- Reads YAML configuration dynamically (no restart needed)
- Checks `hooks.start.enabled` and `hooks.end.enabled` before executing
- Logs hook execution and skips if disabled

#### `ledfx-start.sh`

- Reads virtual list from `hooks.start.virtuals`
- If empty list, gets all virtuals from LedFX API
- Activates each virtual with its configured repeat count
- For Govee devices, uses toggle pattern for reliability

#### `ledfx-stop.sh`

- Reads virtual list from `hooks.end.virtuals`
- If empty list, gets all virtuals from LedFX API
- Deactivates each virtual with its configured repeat count
- For Govee devices, uses toggle pattern with repeats
- Skips virtuals with `repeats: 0`

## Repeat Counts

Repeat counts are useful for device reliability, especially with Govee devices:

- **Start Hook Repeats**: Number of times to activate a virtual when AirPlay starts
- **End Hook Repeats**: Number of times to deactivate a virtual when AirPlay ends
- **0 Repeats**: Excludes the virtual from that hook (useful for end hook to keep some virtuals active)

### Example Use Cases

1. **Govee Device Reliability**: Set `repeats: 2` or `3` for Govee devices to ensure commands are received
2. **Selective Control**: Set `repeats: 0` in end hook to keep certain virtuals active after AirPlay ends
3. **Standard Devices**: Use `repeats: 1` for reliable devices like WLED

## Configuration Examples

### Control All Virtuals (Default)

```yaml
hooks:
  start:
    enabled: true
    virtuals: []  # Empty = all virtuals
  end:
    enabled: true
    virtuals: []  # Empty = all virtuals
```

### Control Specific Virtuals

```yaml
hooks:
  start:
    enabled: true
    virtuals:
      - id: dig-quad
        repeats: 1
      - id: floor-lamp-1
        repeats: 1
  end:
    enabled: true
    virtuals:
      - id: dig-quad
        repeats: 1
      - id: floor-lamp-1
        repeats: 2  # Extra repeats for Govee reliability
```

### Keep Some Virtuals Active After AirPlay Ends

```yaml
hooks:
  start:
    enabled: true
    virtuals:
      - id: dig-quad
        repeats: 1
      - id: floor-lamp-1
        repeats: 1
      - id: table-lamp
        repeats: 1
  end:
    enabled: true
    virtuals:
      - id: dig-quad
        repeats: 1
      - id: floor-lamp-1
        repeats: 2
      # table-lamp not listed = stays active after AirPlay ends
```

### Disable One Hook

```yaml
hooks:
  start:
    enabled: true
    virtuals: []
  end:
    enabled: false  # End hook disabled
    virtuals: []
```

## Dynamic Configuration

**No Restart Required**: Configuration changes take effect immediately on the next AirPlay session event. The scripts read the YAML file dynamically each time they're called.

**shairport-sync.conf is Read-Only**: The `shairport-sync.conf` file is never modified. Hook enable/disable is controlled entirely through YAML configuration.

## Backward Compatibility

The system supports reading from the legacy `.conf` format (`ledfx-hooks.conf`) for backward compatibility, but all new configurations should use YAML format.

## API Endpoints

### GET `/api/config`

Returns current configuration:
```json
{
  "hooks": {
    "start_hook_enabled": true,
    "end_hook_enabled": true
  },
  "virtuals": {
    "ledfx": {
      "host": "localhost",
      "port": 8888
    },
    "hooks": {
      "start": {
        "enabled": true,
        "virtuals": [],
        "all_virtuals": true
      },
      "end": {
        "enabled": true,
        "virtuals": [],
        "all_virtuals": true
      }
    }
  },
  "available_virtuals": ["dig-quad", "floor-lamp-1", "floor-lamp-2", "table-lamp"]
}
```

### POST `/api/config`

Saves configuration changes:
```json
{
  "start_enabled": true,
  "end_enabled": true,
  "ledfx_host": "localhost",
  "ledfx_port": 8888,
  "start_hook": {
    "all_virtuals": false,
    "virtuals": [
      {"id": "dig-quad", "repeats": 1},
      {"id": "floor-lamp-1", "repeats": 2}
    ]
  },
  "end_hook": {
    "all_virtuals": false,
    "virtuals": [
      {"id": "dig-quad", "repeats": 1},
      {"id": "floor-lamp-1", "repeats": 2}
    ]
  }
}
```

## Troubleshooting

### Configuration Not Taking Effect

1. Verify YAML syntax is correct: `yq eval . /configs/ledfx-hooks.yaml`
2. Check hook script logs: `docker compose logs shairport-sync | grep ledfx-session-hook`
3. Verify virtual IDs exist: Check `/api/config` for `available_virtuals`

### Virtual Not Responding

1. Check if virtual ID is correct (case-sensitive)
2. Verify repeat count is >= 1 (0 excludes the virtual)
3. Check LedFX API connection: `curl http://localhost:8888/api/virtuals`

### Hook Not Executing

1. Verify hook is enabled in YAML
2. Check shairport-sync logs for hook execution
3. Verify `ledfx-session-hook.sh` has execute permissions

## File Locations

- **Configuration File**: `/configs/ledfx-hooks.yaml`
- **Hook Scripts**: `/scripts/ledfx-session-hook.sh`, `/scripts/ledfx-start.sh`, `/scripts/ledfx-stop.sh`
- **Web Interface**: `http://airglow.office.lab:8080/config`
- **Status Dashboard**: `http://airglow.office.lab:8080`

