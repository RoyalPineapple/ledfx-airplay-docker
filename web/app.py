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

app = Flask(__name__)

# Configure logging
logging.basicConfig(
    level=logging.WARNING,  # Only log warnings and errors in production
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# Configuration
LEDFX_HOST = os.environ.get('LEDFX_HOST', 'localhost')
LEDFX_PORT = os.environ.get('LEDFX_PORT', '8888')
LEDFX_URL = f"http://{LEDFX_HOST}:{LEDFX_PORT}"

# Config file paths
CONFIG_DIR = '/configs'
SHAIRPORT_CONF = os.path.join(CONFIG_DIR, 'shairport-sync.conf')
HOOKS_YAML = os.path.join(CONFIG_DIR, 'ledfx-hooks.yaml')
HOOKS_CONF = os.path.join(CONFIG_DIR, 'ledfx-hooks.conf')  # For backward compatibility

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
        
        # Default if YAML doesn't exist yet
        return {
            'start_hook_enabled': True,
            'end_hook_enabled': True
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
            
            # Check for explicit all_virtuals flag, default to True for backward compatibility
            start_all_virtuals = start_hook.get('all_virtuals')
            if start_all_virtuals is None:
                # Backward compatibility: if flag not present, check if list is empty
                start_all_virtuals = len(start_virtuals) == 0
            
            end_all_virtuals = end_hook.get('all_virtuals')
            if end_all_virtuals is None:
                # Backward compatibility: if flag not present, check if list is empty
                end_all_virtuals = len(end_virtuals) == 0
            
            return {
                'ledfx': {
                    'host': ledfx_config.get('host', 'localhost'),
                    'port': ledfx_config.get('port', 8888)
                },
                'hooks': {
                    'start': {
                        'enabled': start_hook.get('enabled', True),
                        'virtuals': start_virtuals,
                        'all_virtuals': start_all_virtuals
                    },
                    'end': {
                        'enabled': end_hook.get('enabled', True),
                        'virtuals': end_virtuals,
                        'all_virtuals': end_all_virtuals
                    }
                }
            }
        
        # Fallback to old .conf format for backward compatibility
        elif os.path.exists(HOOKS_CONF):
            virtual_ids = []
            with open(HOOKS_CONF, 'r') as f:
                for line in f:
                    if line.startswith('VIRTUAL_IDS='):
                        # Parse VIRTUAL_IDS="id1,id2" or VIRTUAL_IDS=""
                        match = re.search(r'VIRTUAL_IDS="([^"]*)"', line)
                        if match:
                            ids_str = match.group(1)
                            if ids_str:
                                virtual_ids = [vid.strip() for vid in ids_str.split(',') if vid.strip()]
            
            all_virtuals = len(virtual_ids) == 0
            # Convert old format to new format
            virtuals_list = [{'id': vid, 'repeats': 1} for vid in virtual_ids]
            
            return {
                'ledfx': {'host': 'localhost', 'port': 8888},
                'hooks': {
                    'start': {
                        'enabled': True,
                        'virtuals': virtuals_list,
                        'all_virtuals': all_virtuals
                    },
                    'end': {
                        'enabled': True,
                        'virtuals': virtuals_list,
                        'all_virtuals': all_virtuals
                    }
                }
            }
        
        # Default if no config exists
        return {
            'ledfx': {'host': 'localhost', 'port': 8888},
            'hooks': {
                'start': {
                    'enabled': True,
                    'virtuals': [],
                    'all_virtuals': True  # Explicit flag, not inferred from empty list
                },
                'end': {
                    'enabled': True,
                    'virtuals': [],
                    'all_virtuals': True  # Explicit flag, not inferred from empty list
                }
            }
        }
    except Exception as e:
        logger.error(f"Error reading virtual config: {e}")
        return {'error': str(e) if app.debug else 'Error reading configuration'}


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
                    'all_virtuals': start_hook_data.get('all_virtuals', True),
                    'virtuals': start_hook_data.get('virtuals', [])
                },
                'end': {
                    'enabled': config_data.get('end_enabled', True),
                    'all_virtuals': end_hook_data.get('all_virtuals', True),
                    'virtuals': end_hook_data.get('virtuals', [])
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
    """Main status dashboard page"""
    return render_template('index.html')


@app.route('/ledfx')
def ledfx():
    """LedFX devices and virtuals page"""
    return render_template('ledfx.html')


@app.route('/config')
def config():
    """Configuration page"""
    return render_template('config.html')


@app.route('/api/status')
def status():
    """Get comprehensive status information"""
    # Get container statuses with versions
    ledfx_status = check_container_status('ledfx')
    shairport_status = check_container_status('shairport-sync')
    
    status_data = {
        'containers': {
            'ledfx': {
                'running': ledfx_status['running'],
                'version': ledfx_status.get('version')
            },
            'shairport_sync': {
                'running': shairport_status['running'],
                'version': shairport_status.get('version')
            }
        },
        'ledfx': get_ledfx_info(),
        'ledfx_audio_device': get_ledfx_audio_device(),
        'virtuals': get_ledfx_virtuals(),
        'devices': get_ledfx_devices(),
        'audio': get_audio_status()
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
        
        return jsonify({
            'hooks': hook_config,
            'virtuals': virtual_config,
            'available_virtuals': available_virtuals
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
        
        start_all_virtuals = start_hook_data.get('all_virtuals', True)
        start_virtuals = start_hook_data.get('virtuals', [])
        end_all_virtuals = end_hook_data.get('all_virtuals', True)
        end_virtuals = end_hook_data.get('virtuals', [])
        
        # Validate virtual IDs if specific virtuals are selected
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
        if not end_all_virtuals and end_virtuals:
            for v in end_virtuals:
                vid = v.get('id')
                if vid and vid not in available_virtuals:
                    return jsonify({'error': f'Invalid virtual ID in end hook: {vid}'}), 400
                
                # Validate repeat counts
                repeats = v.get('repeats', 0)
                if not isinstance(repeats, int) or repeats < 0:
                    return jsonify({'error': f'Invalid repeats for {vid} in end hook: must be integer >= 0'}), 400
        
        # Save virtual configuration (includes hook enable/disable in YAML)
        # No restart needed - hook scripts check YAML dynamically
        virtual_config_data = {
            'ledfx_host': ledfx_host,
            'ledfx_port': ledfx_port,
            'start_enabled': start_enabled,
            'end_enabled': end_enabled,
            'start_hook': {
                'all_virtuals': start_all_virtuals,
                'virtuals': start_virtuals
            },
            'end_hook': {
                'all_virtuals': end_all_virtuals,
                'virtuals': end_virtuals
            }
        }
        virtual_result = save_virtual_config(virtual_config_data)
        if 'error' in virtual_result:
            return jsonify(virtual_result), 500
        
        return jsonify({'success': True})
    except Exception as e:
        logger.error(f"Error saving config: {e}", exc_info=True)
        return jsonify({'error': str(e) if app.debug else 'Error saving configuration'}), 500


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


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080, debug=False)
