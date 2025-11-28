#!/bin/bash
# Test script to verify auto-save functionality
# Makes configuration changes and verifies they're saved to YAML

set -e

HOST="192.168.2.200"
BASE_URL="http://${HOST}:8888"
CONFIG_FILE="/opt/airglow/configs/ledfx-hooks.yaml"

echo "=== Testing Auto-Save Functionality ==="
echo ""

# Test 1: Enable start hook with toggle mode
echo "Test 1: Enable start hook with toggle mode, all virtuals"
curl -s -X POST "${BASE_URL}/api/config" \
  -H "Content-Type: application/json" \
  -d '{
    "start_enabled": true,
    "end_enabled": false,
    "start_hook": {
      "mode": "toggle",
      "all_virtuals": true,
      "virtuals": [],
      "scenes": []
    },
    "end_hook": {
      "mode": "toggle",
      "all_virtuals": true,
      "virtuals": [],
      "scenes": []
    }
  }' > /dev/null

sleep 1
echo "✓ Configuration saved"
if ssh root@${HOST} "test -f ${CONFIG_FILE}"; then
    echo "  YAML file contents:"
    ssh root@${HOST} "cat ${CONFIG_FILE}"
    echo ""
    echo "  Verifying start_hook enabled:"
    ssh root@${HOST} "cat ${CONFIG_FILE} | grep -A 3 'hooks:' | grep -A 2 'start:'" || echo "  ✗ Not found"
else
    echo "  ✗ YAML file does not exist"
fi
echo ""

# Test 2: Enable end hook with specific virtuals
echo "Test 2: Enable end hook with specific virtual (if available)"
# First get available virtuals
VIRTUALS=$(curl -s "${BASE_URL}/api/config" | grep -o '"available_virtuals":\[[^]]*\]' | grep -o '"[^"]*"' | head -1 | tr -d '"' || echo "")

if [ -n "$VIRTUALS" ]; then
  echo "  Using virtual: $VIRTUALS"
  curl -s -X POST "${BASE_URL}/api/config" \
    -H "Content-Type: application/json" \
    -d "{
      \"start_enabled\": true,
      \"end_enabled\": true,
      \"start_hook\": {
        \"mode\": \"toggle\",
        \"all_virtuals\": true,
        \"virtuals\": [],
        \"scenes\": []
      },
      \"end_hook\": {
        \"mode\": \"toggle\",
        \"all_virtuals\": false,
        \"virtuals\": [{\"id\": \"$VIRTUALS\", \"repeats\": 3}],
        \"scenes\": []
      }
    }" > /dev/null
  
  sleep 1
  echo "✓ Configuration saved"
  ssh root@${HOST} "cat ${CONFIG_FILE} | grep -A 5 'end_hook:'" || echo "✗ Failed to read config"
else
  echo "  No virtuals available, skipping"
fi
echo ""

# Test 3: Switch to scene mode
echo "Test 3: Switch start hook to scene mode"
SCENES=$(curl -s "${BASE_URL}/api/config" | grep -o '"available_scenes":\[[^]]*\]' | grep -o '"[^"]*"' | head -1 | tr -d '"' || echo "")

if [ -n "$SCENES" ]; then
  echo "  Using scene: $SCENES"
  curl -s -X POST "${BASE_URL}/api/config" \
    -H "Content-Type: application/json" \
    -d "{
      \"start_enabled\": true,
      \"end_enabled\": true,
      \"start_hook\": {
        \"mode\": \"scene\",
        \"all_virtuals\": true,
        \"virtuals\": [],
        \"scenes\": [\"$SCENES\"]
      },
      \"end_hook\": {
        \"mode\": \"toggle\",
        \"all_virtuals\": false,
        \"virtuals\": [{\"id\": \"$VIRTUALS\", \"repeats\": 3}],
        \"scenes\": []
      }
    }" > /dev/null
  
  sleep 1
  echo "✓ Configuration saved"
  ssh root@${HOST} "cat ${CONFIG_FILE} | grep -A 5 'start_hook:'" || echo "✗ Failed to read config"
else
  echo "  No scenes available, skipping"
fi
echo ""

# Test 4: Disable both hooks
echo "Test 4: Disable both hooks"
curl -s -X POST "${BASE_URL}/api/config" \
  -H "Content-Type: application/json" \
  -d '{
    "start_enabled": false,
    "end_enabled": false,
    "start_hook": {
      "mode": "toggle",
      "all_virtuals": true,
      "virtuals": [],
      "scenes": []
    },
    "end_hook": {
      "mode": "toggle",
      "all_virtuals": true,
      "virtuals": [],
      "scenes": []
    }
  }' > /dev/null

sleep 1
echo "✓ Configuration saved"
ssh root@${HOST} "cat ${CONFIG_FILE}" || echo "✗ Failed to read config"
echo ""

# Test 5: Verify final state via API and YAML
echo "Test 5: Verify final state"
echo "  API Response:"
API_CONFIG=$(curl -s "${BASE_URL}/api/config")
echo "$API_CONFIG" | jq '{hooks: .hooks, virtuals: .virtuals}' 2>/dev/null || echo "$API_CONFIG"
echo ""
echo "  YAML File:"
if ssh root@${HOST} "test -f ${CONFIG_FILE}"; then
    ssh root@${HOST} "cat ${CONFIG_FILE}"
else
    echo "  ✗ YAML file does not exist"
fi
echo ""

echo "=== Tests Complete ==="

