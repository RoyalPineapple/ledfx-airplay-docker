# Airglow Configuration Files

## shairport-sync.conf

Main Shairport-Sync configuration file. **AirPlay session hooks are disabled by default.**

To enable automatic LedFx control when AirPlay connects/disconnects:
1. Edit `configs/shairport-sync.conf`
2. Uncomment the hook lines in the `sessioncontrol` section:
   ```conf
   run_this_before_entering_active_state = "/scripts/ledfx-session-hook.sh start active_state";
   run_this_after_exiting_active_state = "/scripts/ledfx-session-hook.sh stop exit_active";
   active_state_timeout = 10.0;
   wait_for_completion = "yes";
   ```
3. Redeploy: `./scripts/maintenance/update-airglow.sh <CT_ID>`

## ledfx-hooks.conf

Configuration file for AirPlay session hooks that control LedFx virtuals.
**Only used when hooks are enabled in shairport-sync.conf.**

### Configuration Options

#### VIRTUAL_IDS
Comma-separated list of LedFx virtual IDs to control when AirPlay connects/disconnects.

**Examples:**
```bash
# Control a single virtual
VIRTUAL_IDS="virtual-1"

# Control multiple virtuals
VIRTUAL_IDS="virtual-1,virtual-2,virtual-3"

# Control all virtuals (leave empty or unset)
VIRTUAL_IDS=""
```

**Default:** (empty - controls all virtuals)

#### LEDFX_HOST
LedFx API hostname or IP address.

**Default:** `localhost`

#### LEDFX_PORT
LedFx API port.

**Default:** `8888`

### How to Configure

1. **Edit the config file** (recommended):
   ```bash
   vim configs/ledfx-hooks.conf
   ```

2. **Or use environment variables** in `docker-compose.yml`:
   ```yaml
   environment:
     - LEDFX_VIRTUAL_IDS=virtual-1,virtual-2
   ```

3. **Redeploy** to apply changes:
   ```bash
   ./scripts/maintenance/update-airglow.sh <CT_ID>
   ```

### Finding Your Virtual IDs

List all virtuals in LedFx:
```bash
curl -s http://localhost:8888/api/virtuals | jq '.virtuals | keys'
```

Or check the LedFx web UI at `http://<host>:8888` - virtual IDs are shown in the device list.

### Behavior

- **On AirPlay Connect:** All specified virtuals are activated and unpaused
- **On AirPlay Disconnect:** All specified virtuals are paused and deactivated
- **If VIRTUAL_IDS is empty:** All virtuals in LedFx are controlled automatically

