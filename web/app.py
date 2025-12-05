#!/usr/bin/env python3
"""
Airglow Status Dashboard - Flask Web Interface
Provides real-time status information and configuration for airglow services
"""
import json
import logging
import os
import re
import subprocess
import yaml
from flask import Flask, render_template, jsonify, request
from functools import wraps
from time import time
from datetime import datetime

app = Flask(__name__)

# Configure logging
logging.basicConfig(
    level=logging.WARNING,  # Only log warnings and errors in production
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# Configuration
# Default to 'ledfx' container name for bridge networking, can be overridden via env var
LEDFX_HOST = os.environ.get('LEDFX_HOST', 'ledfx')
LEDFX_PORT = os.environ.get('LEDFX_PORT', '8888')
LEDFX_URL = f"http://{LEDFX_HOST}:{LEDFX_PORT}"

# Config file paths
CONFIG_DIR = '/configs'
HOOKS_YAML = os.path.join(CONFIG_DIR, 'ledfx-hooks.yaml')
SHAIRPORT_CONF = os.path.join(CONFIG_DIR, 'shairport-sync.conf')
DEFAULT_AIRPLAY_NAME = 'Airglow'

# Rate limiting for diagnostic endpoint
DIAGNOSTIC_RATE_LIMIT = {}  # Simple in-memory rate limiter
RATE_LIMIT_WINDOW = 60  # 60 seconds
RATE_LIMIT_MAX_REQUESTS = 5  # Max 5 requests per window


def check_container_status(container_name):
    """Check if a Docker container is running and get its version"""
    status = {
        'running': False,
        'version': None
    }
    try:
        # Use docker ps to check if container is running
        result = subprocess.run(
            ['docker', 'ps', '--format', '{{.Names}}', '--filter', f'name=^{container_name}$'],
            capture_output=True,
            text=True,
            timeout=5
        )
        if result.returncode == 0 and container_name in result.stdout:
            status['running'] = True
            
            # Get version based on container type
            if container_name == 'ledfx':
                # Get LedFX version from API
                try:
                    info = get_ledfx_info()
                    if info.get('connected') and info.get('version'):
                        status['version'] = info['version']
                except Exception:
                    pass
            elif container_name == 'shairport-sync':
                # Get Shairport-Sync version from container
                try:
                    version_result = subprocess.run(
                        ['docker', 'exec', container_name, 'shairport-sync', '-V'],
                        capture_output=True,
                        text=True,
                        timeout=5
                    )
                    if version_result.returncode == 0:
                        # Extract version from output (e.g., "4.3.2")
                        version_line = version_result.stdout.split('\n')[0]
                        # Look for version pattern like "4.3.2" or "4.3.2-..."
                        version_match = re.search(r'(\d+\.\d+\.\d+)', version_line)
                        if version_match:
                            status['version'] = version_match.group(1)
                except Exception:
                    pass
        
        return status
    except (subprocess.TimeoutExpired, FileNotFoundError, subprocess.SubprocessError) as e:
        logger.warning(f"Error checking container {container_name}: {e}")
        return status


def get_ledfx_info():
    """Get LedFX API information"""
    try:
        result = subprocess.run(
            ['curl', '-s', '-f', f'{LEDFX_URL}/api/info'],
            capture_output=True,
            text=True,
            timeout=5
        )
        if result.returncode == 0:
            info = json.loads(result.stdout)
            return {
                'connected': True,
                'version': info.get('version', 'unknown'),
                'data': info
            }
    except (subprocess.TimeoutExpired, json.JSONDecodeError, subprocess.SubprocessError) as e:
        logger.warning(f"Error getting LedFX info: {e}")
        pass
    return {'connected': False, 'version': None, 'data': None}


def get_ledfx_virtuals():
    """Get LedFX virtuals status"""
    try:
        result = subprocess.run(
            ['curl', '-s', '-f', f'{LEDFX_URL}/api/virtuals'],
            capture_output=True,
            text=True,
            timeout=5
        )
        if result.returncode == 0:
            data = json.loads(result.stdout)
            virtuals = {}
            if 'virtuals' in data:
                for vid, vdata in data['virtuals'].items():
                    virtuals[vid] = {
                        'active': vdata.get('active', False),
                        'streaming': vdata.get('streaming', False),
                        'effect': vdata.get('effect', {}).get('type', 'none') if isinstance(vdata.get('effect'), dict) else 'none',
                        'paused': data.get('paused', False)
                    }
            return {'connected': True, 'virtuals': virtuals, 'paused': data.get('paused', False)}
    except (subprocess.TimeoutExpired, json.JSONDecodeError, subprocess.SubprocessError):
        pass
    return {'connected': False, 'virtuals': {}, 'paused': False}


def get_ledfx_devices():
    """Get LedFX devices status"""
    try:
        result = subprocess.run(
            ['curl', '-s', '-f', f'{LEDFX_URL}/api/devices'],
            capture_output=True,
            text=True,
            timeout=5
        )
        if result.returncode == 0:
            data = json.loads(result.stdout)
            devices = {}
            if 'devices' in data:
                for did, ddata in data['devices'].items():
                    devices[did] = {
                        'online': ddata.get('online', False),
                        'type': ddata.get('type', 'unknown'),
                        'config': ddata.get('config', {})
                    }
            return {'connected': True, 'devices': devices}
    except (subprocess.TimeoutExpired, json.JSONDecodeError, subprocess.SubprocessError):
        pass
    return {'connected': False, 'devices': {}}


def get_ledfx_scenes():
    """Get LedFX scenes"""
    try:
        result = subprocess.run(
            ['curl', '-s', '-f', f'{LEDFX_URL}/api/scenes'],
            capture_output=True,
            text=True,
            timeout=5
        )
        if result.returncode == 0:
            data = json.loads(result.stdout)
            scenes = {}
            if 'scenes' in data:
                for sid, sdata in data['scenes'].items():
                    scenes[sid] = {
                        'name': sdata.get('name', sid),
                        'virtuals': sdata.get('virtuals', [])
                    }
            return {'connected': True, 'scenes': scenes}
    except (subprocess.TimeoutExpired, json.JSONDecodeError, subprocess.SubprocessError):
        pass
    return {'connected': False, 'scenes': {}}


def get_ledfx_audio_device():
    """Get LedFX configured audio device name and index
    Returns the actual device name (e.g., 'ALSA: pulse') not just the index
    Reference: https://docs.ledfx.app/en/latest/apis/api.html
    """
    try:
        # Get available audio devices and their mapping
        devices_result = subprocess.run(
            ['curl', '-s', '-f', f'{LEDFX_URL}/api/audio/devices'],
            capture_output=True,
            text=True,
            timeout=5
        )
        if devices_result.returncode == 0:
            devices_data = json.loads(devices_result.stdout)
            devices_map = devices_data.get('devices', {})
            active_index = devices_data.get('active_device_index')
            
            # Get configured device index from config
            config_result = subprocess.run(
                ['curl', '-s', '-f', f'{LEDFX_URL}/api/config'],
                capture_output=True,
                text=True,
                timeout=5
            )
            if config_result.returncode == 0:
                config_data = json.loads(config_result.stdout)
                audio_config = config_data.get('audio', {})
                configured_index = audio_config.get('audio_device')
                
                # Map index to device name
                device_name = devices_map.get(str(configured_index), f'Unknown (index {configured_index})')
                active_device_name = devices_map.get(str(active_index), f'Unknown (index {active_index})') if active_index is not None else None
                
                return {
                    'configured_index': configured_index,
                    'configured_device': device_name,
                    'active_index': active_index,
                    'active_device': active_device_name,
                    'available_devices': devices_map
                }
    except (subprocess.TimeoutExpired, json.JSONDecodeError, subprocess.SubprocessError) as e:
        pass
    return {
        'configured_index': None,
        'configured_device': None,
        'active_index': None,
        'active_device': None,
        'available_devices': {}
    }


def get_audio_status():
    """Get PulseAudio and audio flow status"""
    audio_status = {
        'pulseaudio': {'available': False, 'server': None},
        'shairport_connected': False,
        'shairport_corked': False,
        'active_streams': 0,
        'ledfx_streaming_flag': False  # LedFX API streaming flag (exposed separately)
    }
    
    try:
        # Check PulseAudio server in ledfx container
        result = subprocess.run(
            ['docker', 'exec', 'ledfx', 'pactl', 'info'],
            capture_output=True,
            text=True,
            timeout=5
        )
        if result.returncode == 0:
            for line in result.stdout.split('\n'):
                if 'Server String' in line:
                    audio_status['pulseaudio']['server'] = line.split(':', 1)[1].strip()
                    audio_status['pulseaudio']['available'] = True
                    break
            
            # Check for Shairport-Sync connection
            sink_inputs = subprocess.run(
                ['docker', 'exec', 'ledfx', 'pactl', 'list', 'sink-inputs', 'short'],
                capture_output=True,
                text=True,
                timeout=5
            )
            if sink_inputs.returncode == 0:
                lines = [l for l in sink_inputs.stdout.split('\n') if l.strip()]
                audio_status['active_streams'] = len(lines)
                
                # Check if Shairport is connected and if it's corked (paused)
                list_inputs = subprocess.run(
                    ['docker', 'exec', 'ledfx', 'pactl', 'list', 'sink-inputs'],
                    capture_output=True,
                    text=True,
                    timeout=5
                )
                if 'Shairport Sync' in list_inputs.stdout:
                    audio_status['shairport_connected'] = True
                    # Check if Shairport is corked (paused)
                    # Corked means the stream is paused/muted
                    if 'Corked: yes' in list_inputs.stdout:
                        audio_status['shairport_corked'] = True
                    elif 'Corked: no' in list_inputs.stdout:
                        audio_status['shairport_corked'] = False
    except (subprocess.TimeoutExpired, subprocess.SubprocessError):
        pass
    
    # Note: We don't compute a derived "LedFX Connected" status
    # The individual checks (Shairport connected, Shairport active, LedFX connected)
    # are displayed separately on the dashboard, allowing users to make their own judgment
    
    # Check LedFX API streaming flag (exposed separately, not used as fallback)
    # Reference: https://docs.ledfx.app/en/latest/apis/api.html
    # According to official LedFX API docs:
    # - streaming: false = "ACTIVE (Idle)" - effect ready but not receiving audio
    # - streaming: true = "RUNNING" - receiving audio input and actively processing
    # Note: This flag may take a moment to update or may behave differently than expected,
    # so we expose it separately for visibility rather than using it as a fallback
    try:
        result = subprocess.run(
            ['curl', '-s', '-f', f'{LEDFX_URL}/api/virtuals'],
            capture_output=True,
            text=True,
            timeout=5
        )
        if result.returncode == 0:
            data = json.loads(result.stdout)
            if 'virtuals' in data:
                # Check if any virtual is streaming (API indicator)
                for vid, vdata in data['virtuals'].items():
                    if vdata.get('streaming', False):
                        audio_status['ledfx_streaming_flag'] = True
                        break
    except (subprocess.TimeoutExpired, json.JSONDecodeError, subprocess.SubprocessError):
        pass
    
    return audio_status


def get_hook_config():
    """Read hook enable/disable status from YAML only"""
    try:
        # Read from YAML only (shairport-sync.conf is never edited)
        if os.path.exists(HOOKS_YAML):
            with open(HOOKS_YAML, 'r') as f:
                config = yaml.safe_load(f) or {}
            
            hooks_config = config.get('hooks', {})
            start_hook = hooks_config.get('start', {})
            end_hook = hooks_config.get('end', {})
            
            return {
                'start_hook_enabled': start_hook.get('enabled', True),
                'end_hook_enabled': end_hook.get('enabled', True)
            }
        
        # Default if YAML doesn't exist yet (fresh installation - hooks disabled)
        return {
            'start_hook_enabled': False,
            'end_hook_enabled': False
        }
    except Exception as e:
        logger.error(f"Error reading hook config: {e}")
        return {'error': str(e) if app.debug else 'Error reading configuration'}


def get_virtual_config():
    """Read virtual configuration from YAML file"""
    try:
        # Try YAML first
        if os.path.exists(HOOKS_YAML):
            with open(HOOKS_YAML, 'r') as f:
                config = yaml.safe_load(f) or {}
            
            ledfx_config = config.get('ledfx', {})
            hooks_config = config.get('hooks', {})
            
            start_hook = hooks_config.get('start', {})
            end_hook = hooks_config.get('end', {})
            
            start_virtuals = start_hook.get('virtuals', [])
            end_virtuals = end_hook.get('virtuals', [])
            
            # Check for explicit all_virtuals flag, default to True
            start_all_virtuals = start_hook.get('all_virtuals')
            if start_all_virtuals is None:
                # If flag not present, check if list is empty
                start_all_virtuals = len(start_virtuals) == 0
            
            end_all_virtuals = end_hook.get('all_virtuals')
            if end_all_virtuals is None:
                # If flag not present, check if list is empty
                end_all_virtuals = len(end_virtuals) == 0
            
            return {
                'ledfx': {
                    'host': ledfx_config.get('host', 'localhost'),
                    'port': ledfx_config.get('port', 8888)
                },
                'hooks': {
                    'start': {
                        'enabled': start_hook.get('enabled', True),
                        'mode': start_hook.get('mode', 'toggle'),  # 'toggle' or 'scene'
                        'virtuals': start_virtuals,
                        'all_virtuals': start_all_virtuals,
                        'scenes': start_hook.get('scenes', [])  # List of scene IDs
                    },
                    'end': {
                        'enabled': end_hook.get('enabled', True),
                        'mode': end_hook.get('mode', 'toggle'),  # 'toggle' or 'scene'
                        'virtuals': end_virtuals,
                        'all_virtuals': end_all_virtuals,
                        'scenes': end_hook.get('scenes', [])  # List of scene IDs
                    }
                }
            }
        
        # Default if no config exists (fresh installation - hooks disabled)
        return {
            'ledfx': {'host': 'localhost', 'port': 8888},
            'hooks': {
                'start': {
                    'enabled': False,
                    'mode': 'toggle',  # Default to toggle mode
                    'virtuals': [],
                    'all_virtuals': True,  # Explicit flag, not inferred from empty list
                    'scenes': []
                },
                'end': {
                    'enabled': False,
                    'mode': 'toggle',  # Default to toggle mode
                    'virtuals': [],
                    'all_virtuals': True,  # Explicit flag, not inferred from empty list
                    'scenes': []
                }
            }
        }
    except Exception as e:
        logger.error(f"Error reading virtual config: {e}")
        return {'error': str(e) if app.debug else 'Error reading configuration'}


def get_airplay_name():
    """Return the configured AirPlay display name from shairport-sync.conf"""
    try:
        if not os.path.exists(SHAIRPORT_CONF):
            return DEFAULT_AIRPLAY_NAME
        with open(SHAIRPORT_CONF, 'r') as f:
            content = f.read()
        match = re.search(r'name\s*=\s*"([^"]+)"', content)
        if match:
            return match.group(1).strip()
    except Exception as exc:
        logger.warning(f"Unable to read AirPlay name: {exc}")
    return DEFAULT_AIRPLAY_NAME


def get_airplay_status():
    """Check AirPlay advertisement status by reading config and validating Avahi is advertising"""
    status = {
        'configured': False,
        'device_name': None,
        'advertising': False,
        'running': False,
        'avahi_running': False,
        'error': None
    }
    
    try:
        # Get configured device name from shairport-sync.conf
        device_name = get_airplay_name()
        if device_name:
            status['configured'] = True
            status['device_name'] = device_name
        
        # Check if shairport-sync container is running (has built-in Avahi)
        shairport_status = check_container_status('shairport-sync')
        status['running'] = shairport_status['running']
        status['avahi_running'] = shairport_status['running']  # Avahi is built into shairport-sync
        
        # Check D-Bus connection between shairport-sync and Avahi
        if status['running']:
            try:
                dbus_check = subprocess.run(
                    ['docker', 'exec', 'shairport-sync', 'dbus-send', '--system', '--print-reply', 
                     '--dest=org.freedesktop.DBus', '/org/freedesktop/DBus', 
                     'org.freedesktop.DBus.ListNames'],
                    capture_output=True,
                    text=True,
                    timeout=5
                )
                if dbus_check.returncode == 0 and 'org.freedesktop.Avahi' in dbus_check.stdout:
                    status['dbus_connected'] = True
                else:
                    status['dbus_connected'] = False
            except Exception as e:
                logger.warning(f"Could not check D-Bus connection: {e}")
                status['dbus_connected'] = False
        
        # Validate that Avahi is actually advertising the service
        if status['running'] and status['avahi_running']:
            if not device_name:
                status['error'] = 'Device name not configured'
            else:
                try:
                    # Browse for AirPlay services and parse to find our device
                    # Check both AirPlay 2 (_raop._tcp) and AirPlay 1 (_airplay._tcp)
                    airplay2_result = subprocess.run(
                        ['docker', 'exec', 'shairport-sync', 'avahi-browse', '-rpt', '_raop._tcp'],
                        capture_output=True,
                        text=True,
                        timeout=5
                    )
                    airplay1_result = subprocess.run(
                        ['docker', 'exec', 'shairport-sync', 'avahi-browse', '-rpt', '_airplay._tcp'],
                        capture_output=True,
                        text=True,
                        timeout=5
                    )
                    
                    # Parse the browse output to find our device
                    # Format: =;interface;protocol;name;type;domain;hostname;address;port;txt_record
                    # Device name appears in the name field (after @) or in hostname
                    found_device = False
                    
                    # Check AirPlay 2 results
                    all_found_devices = []
                    if airplay2_result.returncode == 0 and airplay2_result.stdout:
                        devices = parse_avahi_browse_output(airplay2_result.stdout)
                        for device in devices:
                            device_display_name = device.get('name', '').lower()
                            device_hostname = device.get('hostname', '').lower()
                            all_found_devices.append(device_display_name or device_hostname)
                            # Check if device name matches (case-insensitive)
                            # Also check without special characters for matching
                            device_name_clean = device_name.replace('~', '').replace(' ', '').lower()
                            display_clean = device_display_name.replace('~', '').replace(' ', '').lower()
                            hostname_clean = device_hostname.replace('~', '').replace(' ', '').lower()
                            if (device_name.lower() in device_display_name or 
                                device_name.lower() in device_hostname or
                                device_name_clean in display_clean or
                                device_name_clean in hostname_clean):
                                found_device = True
                                break
                    
                    # Check AirPlay 1 results if not found yet
                    if not found_device and airplay1_result.returncode == 0 and airplay1_result.stdout:
                        devices = parse_avahi_browse_output(airplay1_result.stdout)
                        for device in devices:
                            device_display_name = device.get('name', '').lower()
                            device_hostname = device.get('hostname', '').lower()
                            all_found_devices.append(device_display_name or device_hostname)
                            device_name_clean = device_name.replace('~', '').replace(' ', '').lower()
                            display_clean = device_display_name.replace('~', '').replace(' ', '').lower()
                            hostname_clean = device_hostname.replace('~', '').replace(' ', '').lower()
                            if (device_name.lower() in device_display_name or 
                                device_name.lower() in device_hostname or
                                device_name_clean in display_clean or
                                device_name_clean in hostname_clean):
                                found_device = True
                                break
                    
                    status['advertising'] = found_device
                    
                    if not found_device:
                        # Provide more helpful error message with found devices
                        if all_found_devices:
                            status['error'] = f'Device "{device_name}" not found. Found devices: {", ".join(set(all_found_devices[:5]))}'
                        else:
                            status['error'] = f'Device "{device_name}" not found. No AirPlay devices found on network (avahi-browse returned empty)'
                        
                except subprocess.TimeoutExpired:
                    status['error'] = 'Avahi browse timed out'
                except Exception as e:
                    logger.warning(f"Error checking AirPlay advertisement: {e}")
                    status['error'] = str(e)
        elif not status['running']:
            status['error'] = 'Shairport-sync container is not running'
            
    except Exception as e:
        logger.error(f"Error getting AirPlay status: {e}")
        status['error'] = str(e)
    
    return status


def _sanitize_airplay_name(name):
    """Validate and sanitize user-provided AirPlay display name"""
    if name is None:
        raise ValueError('AirPlay name is required.')
    trimmed = name.strip()
    if not trimmed:
        raise ValueError('AirPlay name cannot be empty.')
    if len(trimmed) > 50:
        raise ValueError('AirPlay name must be 50 characters or fewer.')
    if '"' in trimmed or '\n' in trimmed or '\r' in trimmed:
        raise ValueError('AirPlay name cannot contain quotes or new lines.')
    return trimmed


def update_airplay_name(new_name):
    """Persist the AirPlay display name inside shairport-sync.conf"""
    sanitized = _sanitize_airplay_name(new_name)
    if not os.path.exists(SHAIRPORT_CONF):
        raise FileNotFoundError('Shairport configuration file not found.')
    with open(SHAIRPORT_CONF, 'r') as f:
        content = f.read()
    pattern = r'(name\s*=\s*")([^"]*)(";)'

    def replacer(match):
        return f'{match.group(1)}{sanitized}{match.group(3)}'

    updated_content, replacements = re.subn(pattern, replacer, content, count=1)
    if replacements == 0:
        raise ValueError('Unable to locate AirPlay name entry in shairport-sync.conf.')

    with open(SHAIRPORT_CONF, 'w') as f:
        f.write(updated_content)
    return sanitized


# Note: save_hook_config() removed - we never edit shairport-sync.conf
# Hook enable/disable is stored only in YAML and checked by hook scripts


def save_virtual_config(config_data):
    """Write virtual configuration to YAML file"""
    try:
        # Build YAML structure with new nested format
        start_hook_data = config_data.get('start_hook', {})
        end_hook_data = config_data.get('end_hook', {})
        
        yaml_data = {
            'ledfx': {
                'host': 'localhost',  # Fixed - not configurable
                'port': 8888  # Fixed - not configurable
            },
            'hooks': {
                'start': {
                    'enabled': config_data.get('start_enabled', True),
                    'mode': start_hook_data.get('mode', 'toggle'),  # 'toggle' or 'scene'
                    'all_virtuals': start_hook_data.get('all_virtuals', True),
                    'virtuals': start_hook_data.get('virtuals', []),
                    'scenes': start_hook_data.get('scenes', [])  # List of scene IDs
                },
                'end': {
                    'enabled': config_data.get('end_enabled', True),
                    'mode': end_hook_data.get('mode', 'toggle'),  # 'toggle' or 'scene'
                    'all_virtuals': end_hook_data.get('all_virtuals', True),
                    'virtuals': end_hook_data.get('virtuals', []),
                    'scenes': end_hook_data.get('scenes', [])  # List of scene IDs
                }
            }
        }
        
        # Write YAML file
        with open(HOOKS_YAML, 'w') as f:
            yaml.dump(yaml_data, f, default_flow_style=False, sort_keys=False)
        
        return {'success': True}
    except Exception as e:
        logger.error(f"Error saving virtual config: {e}")
        return {'error': str(e) if app.debug else 'Error saving configuration'}


@app.route('/')
def index():
    """Configuration page (home page)"""
    return render_template('config.html')


@app.route('/config')
def config():
    """Configuration page (alias for /)"""
    return render_template('config.html')


@app.route('/status')
def status_page():
    """Status dashboard page"""
    return render_template('index.html')


@app.route('/browser')
def browser():
    """playdar page"""
    return render_template('browser.html')


@app.route('/ledfx')
def ledfx():
    """LedFX page"""
    return render_template('ledfx.html')


def get_diagnostic_warnings():
    """Run a quick diagnostic check and return warning/error counts"""
    warnings = 0
    errors = 0
    warning_messages = []
    error_messages = []
    
    try:
        # Run diagnostic script with --json flag for structured output
        # Use very short timeout for fast page load (2 seconds max)
        # If it takes longer, return empty results - diagnostics can be loaded separately
        result = subprocess.run(
            ['/scripts/diagnose-airglow.sh', '--json'],
            capture_output=True,
            text=True,
            timeout=2,  # Very short timeout - diagnostics should load quickly or be skipped
            cwd='/scripts'
        )
        
        if result.returncode == 0:
            try:
                # Parse JSON output
                diagnostic_data = json.loads(result.stdout)
                warnings = diagnostic_data.get('warnings', 0)
                errors = diagnostic_data.get('errors', 0)
                warning_messages = diagnostic_data.get('warning_messages', [])[:5]  # Limit to first 5
                error_messages = diagnostic_data.get('error_messages', [])[:5]  # Limit to first 5
            except json.JSONDecodeError:
                # Fallback to text parsing if JSON parsing fails
                for line in result.stdout.split('\n'):
                    if '[WARN]' in line:
                        warnings += 1
                        msg = line.split('[WARN]', 1)[1].strip() if '[WARN]' in line else ''
                        if msg and msg not in warning_messages:
                            warning_messages.append(msg)
                    elif '[ERROR]' in line:
                        errors += 1
                        msg = line.split('[ERROR]', 1)[1].strip() if '[ERROR]' in line else ''
                        if msg and msg not in error_messages:
                            error_messages.append(msg)
    except (subprocess.TimeoutExpired, subprocess.SubprocessError, FileNotFoundError) as e:
        logger.warning(f"Could not run diagnostic check: {e}")
        # Don't fail status check if diagnostic script is unavailable
    
    return {
        'warnings': warnings,
        'errors': errors,
        'warning_messages': warning_messages,
        'error_messages': error_messages
    }


@app.route('/api/status')
def status():
    """Get comprehensive status information"""
    # Dynamically get all running containers from Docker (excluding airglow-web as it's the UI itself)
    container_data = {}
    try:
        # Get all container names from docker-compose
        result = subprocess.run(
            ['docker', 'ps', '--format', '{{.Names}}'],
            capture_output=True,
            text=True,
            timeout=5
        )
        if result.returncode == 0:
            container_names = [name.strip() for name in result.stdout.split('\n') if name.strip()]
            # Filter out airglow-web and check status for each container
            for container_name in container_names:
                if container_name != 'airglow-web':
                    # Map container name to key (e.g., 'shairport-sync' -> 'shairport_sync')
                    key = container_name.replace('-', '_')
                    status = check_container_status(container_name)
                    container_data[key] = {
                        'running': status['running'],
                        'version': status.get('version'),
                        'container_name': container_name  # Store original name for restart button
                    }
    except Exception as e:
        logger.warning(f"Could not query Docker for containers: {e}")
        # Fallback to checking known containers if Docker query fails
        known_containers = {
            'avahi': 'avahi',
            'ledfx': 'ledfx',
            'shairport_sync': 'shairport-sync'
        }
        for key, container_name in known_containers.items():
            status = check_container_status(container_name)
            container_data[key] = {
                'running': status['running'],
                'version': status.get('version'),
                'container_name': container_name
            }
    
    # Get diagnostic warnings (non-blocking - return immediately if it takes too long)
    # Diagnostics are loaded asynchronously by the frontend to avoid blocking page load
    diagnostics = None
    try:
        # Try to get diagnostics quickly, but don't block if it takes too long
        diagnostics = get_diagnostic_warnings()
    except Exception as e:
        logger.warning(f"Could not get diagnostics quickly: {e}")
        # Return empty diagnostics - frontend can load them separately
        diagnostics = {'warnings': 0, 'errors': 0, 'warning_messages': [], 'error_messages': []}
    
    # Get AirPlay status (non-blocking - return None if it fails)
    airplay_status = None
    try:
        airplay_status = get_airplay_status()
    except Exception as e:
        logger.warning(f"Could not get AirPlay status: {e}")
        # Return None if it fails - frontend can handle missing data
    
    status_data = {
        'containers': container_data,
        'ledfx': get_ledfx_info(),
        'ledfx_audio_device': get_ledfx_audio_device(),
        'virtuals': get_ledfx_virtuals(),
        'devices': get_ledfx_devices(),
        'audio': get_audio_status(),
        'airplay': airplay_status,
        'diagnostics': diagnostics
    }
    return jsonify(status_data)


@app.route('/api/config', methods=['GET'])
def get_config():
    """Get current configuration"""
    try:
        hook_config = get_hook_config()
        virtual_config = get_virtual_config()
        virtuals_list = get_ledfx_virtuals()
        
        # Get list of available virtual IDs
        available_virtuals = list(virtuals_list.get('virtuals', {}).keys()) if virtuals_list.get('connected') else []
        
        # Get list of available scenes
        scenes_list = get_ledfx_scenes()
        available_scenes = list(scenes_list.get('scenes', {}).keys()) if scenes_list.get('connected') else []
        
        # Get device count
        devices_data = get_ledfx_devices()
        has_devices = devices_data.get('connected') and len(devices_data.get('devices', {})) > 0
        
        # Also check if virtuals are available (virtuals can exist without devices being "online")
        has_virtuals = len(available_virtuals) > 0
        
        return jsonify({
            'hooks': hook_config,
            'virtuals': virtual_config,
            'available_virtuals': available_virtuals,
            'available_scenes': available_scenes,
            'has_devices': has_devices or has_virtuals,  # Show UI if devices OR virtuals exist
            'airplay_name': get_airplay_name()
        })
    except Exception as e:
        logger.error(f"Error getting config: {e}")
        return jsonify({'error': str(e) if app.debug else 'Error reading configuration'}), 500


@app.route('/api/config', methods=['POST'])
def save_config():
    """Save configuration changes"""
    try:
        data = request.get_json()
        
        # Validate input
        start_enabled = data.get('start_enabled', False)
        end_enabled = data.get('end_enabled', False)
        
        # LedFX connection is fixed (localhost:8888) - not configurable
        ledfx_host = 'localhost'
        ledfx_port = 8888
        
        start_hook_data = data.get('start_hook', {})
        end_hook_data = data.get('end_hook', {})
        
        start_mode = start_hook_data.get('mode', 'toggle')
        end_mode = end_hook_data.get('mode', 'toggle')
        
        start_all_virtuals = start_hook_data.get('all_virtuals', True)
        start_virtuals = start_hook_data.get('virtuals', [])
        start_scenes = start_hook_data.get('scenes', [])
        end_all_virtuals = end_hook_data.get('all_virtuals', True)
        end_virtuals = end_hook_data.get('virtuals', [])
        end_scenes = end_hook_data.get('scenes', [])
        
        # Validate mode values
        if start_mode not in ['toggle', 'scene']:
            return jsonify({'error': f'Invalid mode for start hook: {start_mode}. Must be "toggle" or "scene"'}), 400
        if end_mode not in ['toggle', 'scene']:
            return jsonify({'error': f'Invalid mode for end hook: {end_mode}. Must be "toggle" or "scene"'}), 400
        
        # Validate virtual IDs if toggle mode and specific virtuals are selected
        if start_mode == 'toggle':
            virtuals_list = get_ledfx_virtuals()
            available_virtuals = set(virtuals_list.get('virtuals', {}).keys()) if virtuals_list.get('connected') else set()
            
            # Validate start hook virtuals
            if not start_all_virtuals and start_virtuals:
                for v in start_virtuals:
                    vid = v.get('id')
                    if vid and vid not in available_virtuals:
                        return jsonify({'error': f'Invalid virtual ID in start hook: {vid}'}), 400
                    
                    # Validate repeat counts
                    repeats = v.get('repeats', 1)
                    if not isinstance(repeats, int) or repeats < 0:
                        return jsonify({'error': f'Invalid repeats for {vid} in start hook: must be integer >= 0'}), 400
        
        # Validate end hook virtuals
        if end_mode == 'toggle':
            if not end_all_virtuals and end_virtuals:
                for v in end_virtuals:
                    vid = v.get('id')
                    if vid and vid not in available_virtuals:
                        return jsonify({'error': f'Invalid virtual ID in end hook: {vid}'}), 400
                    
                    # Validate repeat counts
                    repeats = v.get('repeats', 0)
                    if not isinstance(repeats, int) or repeats < 0:
                        return jsonify({'error': f'Invalid repeats for {vid} in end hook: must be integer >= 0'}), 400
        
        # Validate scene IDs if scene mode
        if start_mode == 'scene':
            scenes_list = get_ledfx_scenes()
            available_scenes = set(scenes_list.get('scenes', {}).keys()) if scenes_list.get('connected') else set()
            
            for sid in start_scenes:
                if sid not in available_scenes:
                    return jsonify({'error': f'Invalid scene ID in start hook: {sid}'}), 400
        
        if end_mode == 'scene':
            scenes_list = get_ledfx_scenes()
            available_scenes = set(scenes_list.get('scenes', {}).keys()) if scenes_list.get('connected') else set()
            
            for sid in end_scenes:
                if sid not in available_scenes:
                    return jsonify({'error': f'Invalid scene ID in end hook: {sid}'}), 400
        
        # Save virtual configuration (includes hook enable/disable in YAML)
        # No restart needed - hook scripts check YAML dynamically
        virtual_config_data = {
            'ledfx_host': ledfx_host,
            'ledfx_port': ledfx_port,
            'start_enabled': start_enabled,
            'end_enabled': end_enabled,
            'start_hook': {
                'mode': start_mode,
                'all_virtuals': start_all_virtuals,
                'virtuals': start_virtuals,
                'scenes': start_scenes
            },
            'end_hook': {
                'mode': end_mode,
                'all_virtuals': end_all_virtuals,
                'virtuals': end_virtuals,
                'scenes': end_scenes
            }
        }
        virtual_result = save_virtual_config(virtual_config_data)
        if 'error' in virtual_result:
            return jsonify(virtual_result), 500
        
        return jsonify({'success': True})
    except Exception as e:
        logger.error(f"Error saving config: {e}", exc_info=True)
        return jsonify({'error': str(e) if app.debug else 'Error saving configuration'}), 500


@app.route('/api/airplay-name', methods=['POST'])
def set_airplay_name():
    """Update the AirPlay display name (stored in shairport-sync.conf)"""
    try:
        data = request.get_json() or {}
        new_name = data.get('name', '')
        updated_name = update_airplay_name(new_name)
        return jsonify({'success': True, 'name': updated_name})
    except ValueError as e:
        return jsonify({'error': str(e)}), 400
    except FileNotFoundError as e:
        logger.error(str(e))
        return jsonify({'error': 'Shairport configuration file not found on this host.'}), 500
    except Exception as e:
        logger.error(f"Error updating AirPlay name: {e}", exc_info=True)
        return jsonify({'error': 'Failed to update AirPlay name'}), 500


@app.route('/api/shairport/restart', methods=['POST'])
def restart_shairport():
    """Restart the shairport-sync container to apply configuration changes"""
    try:
        result = subprocess.run(
            ['docker', 'restart', 'shairport-sync'],
            capture_output=True,
            text=True,
            timeout=30
        )
        if result.returncode != 0:
            error_output = result.stderr.strip() or 'Unknown error restarting shairport-sync.'
            return jsonify({'error': error_output}), 500
        return jsonify({'success': True, 'output': result.stdout.strip()})
    except subprocess.TimeoutExpired:
        return jsonify({'error': 'Timed out while restarting shairport-sync.'}), 504
    except Exception as e:
        logger.error(f"Error restarting shairport-sync: {e}", exc_info=True)
        return jsonify({'error': 'Failed to restart shairport-sync.'}), 500


def rate_limit_diagnose(f):
    """Simple rate limiter for diagnose endpoint"""
    @wraps(f)
    def decorated_function(*args, **kwargs):
        # Get client IP (simplified - in production use request.remote_addr)
        client_id = request.remote_addr or 'unknown'
        current_time = time()
        
        # Clean old entries
        DIAGNOSTIC_RATE_LIMIT[client_id] = [
            req_time for req_time in DIAGNOSTIC_RATE_LIMIT.get(client_id, [])
            if current_time - req_time < RATE_LIMIT_WINDOW
        ]
        
        # Check rate limit
        if len(DIAGNOSTIC_RATE_LIMIT.get(client_id, [])) >= RATE_LIMIT_MAX_REQUESTS:
            logger.warning(f"Rate limit exceeded for {client_id}")
            return jsonify({
                'success': False,
                'output': '',
                'error': 'Rate limit exceeded. Please wait before running diagnostics again.',
                'returncode': 429
            }), 429
        
        # Add current request
        if client_id not in DIAGNOSTIC_RATE_LIMIT:
            DIAGNOSTIC_RATE_LIMIT[client_id] = []
        DIAGNOSTIC_RATE_LIMIT[client_id].append(current_time)
        
        return f(*args, **kwargs)
    return decorated_function


@app.route('/api/container/<container_name>/restart', methods=['POST'])
def restart_container(container_name):
    """Restart a specific container"""
    # Validate container name (security: only allow known containers)
    # Exclude airglow-web as it's the UI itself
    allowed_containers = ['avahi', 'nqptp', 'ledfx', 'shairport-sync']
    if container_name not in allowed_containers:
        return jsonify({'error': 'Invalid container name'}), 400
    
    try:
        result = subprocess.run(
            ['docker', 'restart', container_name],
            capture_output=True,
            text=True,
            timeout=30
        )
        if result.returncode == 0:
            return jsonify({
                'success': True,
                'message': f'Container {container_name} restarted successfully'
            })
        else:
            return jsonify({
                'success': False,
                'error': result.stderr or 'Failed to restart container'
            }), 500
    except subprocess.TimeoutExpired:
        return jsonify({
            'success': False,
            'error': 'Restart operation timed out'
        }), 500
    except Exception as e:
        logger.error(f"Error restarting container {container_name}: {e}", exc_info=True)
        return jsonify({
            'success': False,
            'error': 'An error occurred while restarting the container' if not app.debug else str(e)
        }), 500


@app.route('/api/diagnose', methods=['POST'])
@rate_limit_diagnose
def diagnose():
    """Run diagnostic check"""
    try:
        # Check if diagnostic script exists
        script_path = '/scripts/diagnose-airglow.sh'
        if os.path.exists(script_path):
            result = subprocess.run(
                ['bash', script_path],
                capture_output=True,
                text=True,
                timeout=60
            )
            return jsonify({
                'success': result.returncode == 0,
                'output': result.stdout,
                'error': result.stderr if result.returncode != 0 else '',
                'returncode': result.returncode
            })
        else:
            return jsonify({
                'success': False,
                'output': '',
                'error': 'Diagnostic script not found',
                'returncode': -1
            }), 500
    except subprocess.TimeoutExpired:
        return jsonify({
            'success': False,
            'output': '',
            'error': 'Diagnostic check timed out',
            'returncode': -1
        }), 500
    except Exception as e:
        logger.error(f"Error running diagnostics: {e}", exc_info=True)
        return jsonify({
            'success': False,
            'output': '',
            'error': 'An error occurred while running diagnostics' if not app.debug else str(e),
            'returncode': -1
        }), 500


def parse_avahi_browse_output(output):
    """Parse avahi-browse parsable output and extract human-readable device information"""
    devices = []
    
    if not output or not output.strip():
        return devices
    
    lines = output.split('\n')
    device_map = {}  # Group devices by hostname
    
    for line in lines:
        line = line.strip()
        if not line:
            continue
        
        # Parsable format: fields separated by semicolons
        # Format for resolved entries (=): =;interface;protocol;name;type;domain;hostname;address;port;txt_record
        # Format for unresolved entries (+): +;interface;protocol;name;type;domain;flags;service_name
        if ';' in line:
            parts = line.split(';')
            event_type = parts[0] if parts else ''
            
            # Only process resolved service entries (= means resolved service with all info)
            # Format: =;interface;protocol;name;type;domain;hostname;address;port;txt_record
            if event_type == '=' and len(parts) >= 10:
                interface = parts[1]
                protocol = parts[2]
                name = parts[3]  # This is the escaped service name like "D6BF5E3BFAF2\064Living\032room"
                service_type = parts[4]
                domain = parts[5]
                hostname = parts[6] if len(parts) > 6 else ''
                address = parts[7] if len(parts) > 7 else ''
                port = parts[8] if len(parts) > 8 else ''
                # TXT record is everything from index 9 onwards (join in case of any edge cases)
                txt_record = ';'.join(parts[9:]) if len(parts) > 9 else ''
                
                # Decode escaped device name (e.g., \064 = @, \032 = space, \126 = ~)
                # Format is typically: DEVICEID\064DeviceName
                device_name = 'Unknown Device'
                if '\\064' in name:
                    # Split on \064 (which is @) and take the part after it
                    name_parts = name.split('\\064')
                    if len(name_parts) > 1:
                        device_name = name_parts[-1]
                        # Replace other escape sequences
                        device_name = device_name.replace('\\032', ' ').replace('\\126', '~').replace('\\040', ' ').replace('\\041', '!')
                elif name:
                    # Try to use the name as-is if no @ separator
                    device_name = name.replace('\\032', ' ').replace('\\126', '~').replace('\\040', ' ').replace('\\041', '!')
                
                # Clean up device name
                device_name = device_name.strip()
                if not device_name or device_name == 'Unknown Device':
                    # Fallback: try to extract from hostname
                    if hostname:
                        device_name = hostname.split('.')[0].replace('-', ' ')
                
                # Parse TXT record for firmware version and feature flags
                firmware_version = None
                feature_flags = None
                if txt_record:
                    # TXT record is a space-separated list of quoted key=value pairs
                    # Extract fv= (firmware version) and ft= (feature flags)
                    fv_match = re.search(r'"fv=([^"]+)"', txt_record)
                    if fv_match:
                        firmware_version = fv_match.group(1)
                    ft_match = re.search(r'"ft=([^"]+)"', txt_record)
                    if ft_match:
                        feature_flags = ft_match.group(1)
                
                # Use hostname + service type as key to differentiate AirPlay 1, AirPlay 2, and video
                # This allows same hostname to show separate entries for different service types
                if hostname:
                    device_key = f"{hostname.lower()}|{service_type.lower()}"
                else:
                    # No hostname - use device name + service type as fallback key
                    device_key = f"{device_name.lower()}|{service_type.lower()}"
                
                # Determine service type label for display
                service_label = ''
                if '_raop._tcp' in service_type.lower():
                    service_label = ' (AirPlay 2 Audio)'
                elif '_airplay._tcp' in service_type.lower():
                    service_label = ' (AirPlay Video)'
                
                # Initialize device entry if not exists
                if device_key not in device_map:
                    device_map[device_key] = {
                        'name': device_name + service_label,
                        'interface': interface,
                        'protocol': protocol,
                        'hostname': hostname,
                        'address': address,  # Prefer first address found
                        'port': port,
                        'firmware_version': firmware_version,
                        'feature_flags': feature_flags,
                        'service_type': service_type,
                        'raw_avahi_data': []
                    }
                
                # Add raw line to this device's data
                device_map[device_key]['raw_avahi_data'].append(line)
                
                # Prefer IPv4 addresses and external IPs (192.168.x.x) over Docker internal (172.x.x.x) and loopback
                existing = device_map[device_key]
                if address:
                    # Prefer 192.168.x.x addresses
                    if address.startswith('192.168.') and not existing['address'].startswith('192.168.'):
                        existing['address'] = address
                        existing['interface'] = interface
                        existing['protocol'] = protocol
                    # Prefer IPv4 over IPv6
                    elif protocol == 'IPv4' and existing.get('protocol') == 'IPv6':
                        existing['address'] = address
                        existing['interface'] = interface
                        existing['protocol'] = protocol
                    # Update if no address set
                    elif not existing.get('address'):
                        existing['address'] = address
                        existing['interface'] = interface
                        existing['protocol'] = protocol
                
                # Update firmware/features if missing
                if not existing.get('firmware_version') and firmware_version:
                    existing['firmware_version'] = firmware_version
                if not existing.get('feature_flags') and feature_flags:
                    existing['feature_flags'] = feature_flags
    
    # Convert device map to list
    devices = []
    for device_key, device in device_map.items():
        if device.get('address') or device.get('hostname'):
            device['address_display'] = device.get('address', '—')
            devices.append(device)
    
    return devices


@app.route('/api/browser')
def get_airplay_devices():
    """Get AirPlay devices using avahi-browse"""
    result = {
        'devices': [],
        'error': None,
        'timestamp': datetime.now().isoformat(),
        'host_ip': None
    }
    
    # Get the host IP address by checking the shairport-sync container's network
    try:
        # Get all IPs from shairport-sync container and find the one in 192.168.2.x range
        inspect_result = subprocess.run(
            ['docker', 'inspect', '--format', '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}', 'shairport-sync'],
            capture_output=True,
            text=True,
            timeout=5
        )
        if inspect_result.returncode == 0:
            # Get all IPs and find the one in 192.168.2.x range (macvlan network)
            all_ips = inspect_result.stdout.strip()
            for ip in all_ips.split():
                if ip and ip.startswith('192.168.2.'):
                    result['host_ip'] = ip
                    break
    except Exception as e:
        logger.warning(f"Could not determine host IP: {e}")
    
    # Check if shairport-sync container is running (has built-in Avahi)
    shairport_status = check_container_status('shairport-sync')
    if not shairport_status['running']:
        result['error'] = 'Shairport-sync container is not running'
        return jsonify(result)
    
    # Combined device map keyed by hostname (to merge AirPlay 2 and AirPlay 1 data)
    all_devices = {}
    
    # Browse AirPlay 2 services (_raop._tcp) - Audio
    try:
        airplay2_result = subprocess.run(
            ['docker', 'exec', 'shairport-sync', 'avahi-browse', '-rpt', '_raop._tcp'],
            capture_output=True,
            text=True,
            timeout=10
        )
        if airplay2_result.returncode == 0:
            airplay2_devices = parse_avahi_browse_output(airplay2_result.stdout)
            for device in airplay2_devices:
                hostname_key = device.get('hostname', '').lower() if device.get('hostname') else device.get('name', '').lower()
                if hostname_key:
                    if hostname_key not in all_devices:
                        all_devices[hostname_key] = device
                        all_devices[hostname_key]['raw_avahi_data_ap2'] = device.get('raw_avahi_data', [])
                    else:
                        # Merge raw data
                        if 'raw_avahi_data_ap2' not in all_devices[hostname_key]:
                            all_devices[hostname_key]['raw_avahi_data_ap2'] = device.get('raw_avahi_data', [])
                        else:
                            all_devices[hostname_key]['raw_avahi_data_ap2'].extend(device.get('raw_avahi_data', []))
                    all_devices[hostname_key]['airplay2'] = True
        else:
            logger.warning(f"AirPlay 2 browse failed: {airplay2_result.stderr}")
    except subprocess.TimeoutExpired:
        logger.warning("AirPlay 2 browse timed out")
    except Exception as e:
        logger.error(f"Error browsing AirPlay 2 services: {e}")
    
    # Browse AirPlay 1 services (_airplay._tcp) - Video
    try:
        airplay1_result = subprocess.run(
            ['docker', 'exec', 'shairport-sync', 'avahi-browse', '-rpt', '_airplay._tcp'],
            capture_output=True,
            text=True,
            timeout=10
        )
        if airplay1_result.returncode == 0:
            airplay1_devices = parse_avahi_browse_output(airplay1_result.stdout)
            for device in airplay1_devices:
                hostname_key = device.get('hostname', '').lower() if device.get('hostname') else device.get('name', '').lower()
                if hostname_key:
                    if hostname_key not in all_devices:
                        all_devices[hostname_key] = device
                        all_devices[hostname_key]['raw_avahi_data_ap1'] = device.get('raw_avahi_data', [])
                    else:
                        # Merge raw data
                        if 'raw_avahi_data_ap1' not in all_devices[hostname_key]:
                            all_devices[hostname_key]['raw_avahi_data_ap1'] = device.get('raw_avahi_data', [])
                        else:
                            all_devices[hostname_key]['raw_avahi_data_ap1'].extend(device.get('raw_avahi_data', []))
                    all_devices[hostname_key]['airplay1'] = True
        else:
            logger.warning(f"AirPlay 1 browse failed: {airplay1_result.stderr}")
    except subprocess.TimeoutExpired:
        logger.warning("AirPlay 1 browse timed out")
    except Exception as e:
        logger.error(f"Error browsing AirPlay 1 services: {e}")
    
    # Combine devices and merge raw data
    for device in all_devices.values():
        versions = []
        if device.get('airplay2'):
            versions.append('AirPlay 2')
        if device.get('airplay1'):
            versions.append('AirPlay Video')
        device['airplay_versions'] = ', '.join(versions) if versions else 'Unknown'
        
        # Combine all raw avahi data from both service types
        raw_data = []
        if device.get('raw_avahi_data_ap2'):
            raw_data.extend(device['raw_avahi_data_ap2'])
        if device.get('raw_avahi_data_ap1'):
            raw_data.extend(device['raw_avahi_data_ap1'])
        device['raw_avahi_data'] = raw_data
        
        result['devices'].append(device)
    
    return jsonify(result)


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=80, debug=False)
