# LedFx API Documentation Summary

Based on official documentation: https://docs.ledfx.app/en/latest/apis/api.html

## Key Endpoints for Session Control

### Virtuals Control

#### GET /api/virtuals
Get configuration of all virtuals

#### GET /api/virtuals/{virtual_id}
Returns information about a specific virtual

#### PUT /api/virtuals/{virtual_id}
**Set a virtual to active or inactive**

Example to deactivate:
```json
{
  "active": false
}
```

Example to activate:
```json
{
  "active": true
}
```

#### DELETE /api/virtuals/{virtual_id}/effects
**Clear the active effect of a virtual** (stops visualization)

This removes the effect but keeps the virtual active.

### Effects Control

#### GET /api/virtuals/{virtual_id}/effects
Returns the active effect config of a virtual

#### POST /api/virtuals/{virtual_id}/effects
Set the virtual to a new effect based on JSON configuration

#### PUT /api/virtuals/{virtual_id}/effects
Update the active effect config of a virtual

#### DELETE /api/virtuals/{virtual_id}/effects
Clear the active effect of a virtual

## Virtual States

LedFx virtuals can be in multiple states:

1. **INACTIVE**: `active: false`
   - Virtual is not active
   - No effect running
   - No visualization

2. **ACTIVE (No Effect)**: `active: true, effect: {}`
   - Virtual is active but no effect is loaded
   - No visualization (black/off)

3. **ACTIVE (Idle)**: `active: true, effect exists, streaming: false`
   - Virtual is active with an effect loaded
   - Effect is ready but not receiving audio
   - Visualization paused/waiting

4. **RUNNING**: `active: true, effect exists, streaming: true`
   - Virtual is active with an effect
   - Receiving audio input
   - Visualization is active and responding to audio

5. **GLOBAL PAUSED**: `paused: true` (affects all virtuals)
   - All effects paused globally
   - Virtuals remain active but effects don't update

## State Transitions

### To INACTIVE:
```bash
PUT /api/virtuals/{virtual_id}
{"active": false}
```

### To ACTIVE (No Effect):
```bash
PUT /api/virtuals/{virtual_id}
{"active": true}
# Then clear effect if one exists:
DELETE /api/virtuals/{virtual_id}/effects
```

### To ACTIVE (Idle):
```bash
PUT /api/virtuals/{virtual_id}
{"active": true}
# Effect should already exist, or restore last_effect
```

### To RUNNING:
- Virtual must be `active: true`
- Effect must exist
- Audio input must be present (handled by LedFx automatically)

## Strategy for AirPlay Session Hooks

**To Start Visualization (AirPlay Connected):**
1. Check current state
2. If INACTIVE: Activate virtual (`PUT` with `{"active": true}`)
3. If no effect exists but `last_effect` is available: Restore the last effect
4. Ensure virtual is ready to receive audio (LedFx will start streaming when audio arrives)

**To Stop Visualization (AirPlay Disconnected):**
1. Clear active effect: `DELETE /api/virtuals/{virtual_id}/effects`
   - This stops visualization but preserves `last_effect` for next time
2. Deactivate virtual: `PUT /api/virtuals/{virtual_id}` with `{"active": false}`
   - This relinquishes control and returns virtual to INACTIVE state

**State Handling:**
- Always check current state before making changes
- Preserve `last_effect` when stopping (don't clear it, just clear active effect)
- Handle all possible starting states (inactive, active with no effect, active with effect)


