#!/bin/bash
# Create game servers on all panels using clock-mock
# Usage: ./create-servers.sh <panel|all> [count] [start_from]
# Example: ./create-servers.sh gameap-4 900 101   # creates loadtest-101..loadtest-1000

PANEL="${1:-all}"
COUNT="${2:-900}"
START="${3:-101}"
END=$((START + COUNT - 1))

echo "============================================"
echo "  Creating servers: loadtest-${START}..loadtest-${END}"
echo "  Panel: $PANEL"
echo "  $(date)"
echo "============================================"
echo ""

create_gameap3() {
    local count=$1 start=$2
    echo "=== GameAP 3.x: creating $count servers (from $start) ==="

    local BASE="http://10.10.10.10"
    local TOKEN="1|n38ZgfkmkIzFvmkRmXloNsvQBT8JnRgIlHTTBtnz"
    local ok=0 fail=0

    for i in $(seq $start $((start + count - 1))); do
        local port=$((27000 + i))
        local code=$(curl -s -o /dev/null -w "%{http_code}" \
            -X POST "$BASE/api/servers" \
            -H "Authorization: Bearer $TOKEN" \
            -H "Accept: application/json" \
            -H "Content-Type: application/json" \
            -d "{
                \"name\": \"loadtest-${i}\",
                \"ds_id\": 1,
                \"game_id\": \"clock-mock\",
                \"game_mod_id\": 75,
                \"server_ip\": \"10.10.10.20\",
                \"server_port\": ${port},
                \"query_port\": ${port},
                \"rcon_port\": ${port},
                \"install\": false
            }")

        if [ "$code" = "200" ] || [ "$code" = "201" ]; then
            ok=$((ok + 1))
        else
            fail=$((fail + 1))
            [ $fail -le 3 ] && echo "  FAIL #$i: HTTP $code"
        fi
        [ $(( (i - start + 1) % 100)) -eq 0 ] && echo "  Progress: $((i - start + 1))/$count (ok=$ok, fail=$fail)"
    done
    echo "  DONE: ok=$ok, fail=$fail"
}

create_gameap4() {
    local count=$1 start=$2
    echo "=== GameAP 4.x: creating $count servers (from $start) ==="

    local BASE="http://10.10.10.11"
    local TOKEN="2|JlSKKrSNDU7jYLdvQw86kWNabqnp0Ayfgxl9K56lXeT8AT4V"
    local ok=0 fail=0

    for i in $(seq $start $((start + count - 1))); do
        local port=$((27000 + i))
        local code=$(curl -s -o /dev/null -w "%{http_code}" \
            -X POST "$BASE/api/servers" \
            -H "Authorization: Bearer $TOKEN" \
            -H "Accept: application/json" \
            -H "Content-Type: application/json" \
            -d "{
                \"name\": \"loadtest-${i}\",
                \"ds_id\": 1,
                \"game_id\": \"clock-mock\",
                \"game_mod_id\": 33,
                \"server_ip\": \"10.10.10.22\",
                \"server_port\": ${port},
                \"query_port\": ${port},
                \"rcon_port\": ${port},
                \"install\": false
            }")

        if [ "$code" = "200" ] || [ "$code" = "201" ]; then
            ok=$((ok + 1))
        else
            fail=$((fail + 1))
            [ $fail -le 3 ] && echo "  FAIL #$i: HTTP $code"
        fi
        [ $(( (i - start + 1) % 100)) -eq 0 ] && echo "  Progress: $((i - start + 1))/$count (ok=$ok, fail=$fail)"
    done
    echo "  DONE: ok=$ok, fail=$fail"
}

create_pterodactyl() {
    local count=$1 start=$2
    echo "=== Pterodactyl: creating $count servers (from $start) ==="

    local BASE="http://10.10.10.12"
    local TOKEN="ptlc_CMnVpS17utremKIboJhm0rl2AKi8cmZ0zTX1CuYMzwh"

    # Find node
    local node_id=$(curl -s "$BASE/api/application/nodes" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Accept: application/json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d['data'][0]['attributes']['id'])
" 2>/dev/null)

    if [ -z "$node_id" ]; then
        echo "  ERROR: Cannot list nodes."
        return 1
    fi
    echo "  Node ID: $node_id"

    # Find Clock Mock egg
    local egg_id=""
    local nests=$(curl -s "$BASE/api/application/nests" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Accept: application/json" | python3 -c "
import sys, json
for n in json.load(sys.stdin).get('data', []):
    print(n['attributes']['id'])
" 2>/dev/null)

    for nest_id in $nests; do
        egg_id=$(curl -s "$BASE/api/application/nests/${nest_id}/eggs" \
            -H "Authorization: Bearer $TOKEN" \
            -H "Accept: application/json" | python3 -c "
import sys, json
for e in json.load(sys.stdin).get('data', []):
    if 'clock' in e['attributes']['name'].lower():
        print(e['attributes']['id'])
        break
" 2>/dev/null)
        [ -n "$egg_id" ] && break
    done

    if [ -z "$egg_id" ]; then
        echo "  ERROR: Clock Mock egg not found."
        return 1
    fi
    echo "  Egg ID: $egg_id"

    # Batch create allocations first
    echo "  Creating allocations in batches..."
    local batch_size=50
    for batch_start in $(seq $start $batch_size $((start + count - 1))); do
        local batch_end=$((batch_start + batch_size - 1))
        [ $batch_end -gt $((start + count - 1)) ] && batch_end=$((start + count - 1))

        # Build ports array for batch
        local ports_json="["
        for p in $(seq $batch_start $batch_end); do
            [ "$ports_json" != "[" ] && ports_json="${ports_json},"
            ports_json="${ports_json}\"$((30000 + p))\""
        done
        ports_json="${ports_json}]"

        curl -s -o /dev/null -X POST "$BASE/api/application/nodes/${node_id}/allocations" \
            -H "Authorization: Bearer $TOKEN" \
            -H "Accept: application/json" \
            -H "Content-Type: application/json" \
            -d "{\"ip\": \"0.0.0.0\", \"ports\": ${ports_json}}" 2>/dev/null
    done
    echo "  Allocations created"

    # Fetch all allocations once
    echo "  Fetching allocation map..."
    local alloc_map=$(curl -s "$BASE/api/application/nodes/${node_id}/allocations?per_page=50000" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Accept: application/json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for a in d.get('data', []):
    attr = a['attributes']
    if not attr['assigned']:
        print(f\"{attr['port']}:{attr['id']}\")
" 2>/dev/null)

    # Build port->alloc_id map
    declare -A ALLOC_MAP
    while IFS=: read -r port alloc_id; do
        ALLOC_MAP[$port]=$alloc_id
    done <<< "$alloc_map"
    echo "  Available allocations: ${#ALLOC_MAP[@]}"

    local ok=0 fail=0
    for i in $(seq $start $((start + count - 1))); do
        local port=$((30000 + i))
        local alloc_id="${ALLOC_MAP[$port]}"

        if [ -z "$alloc_id" ]; then
            fail=$((fail + 1))
            [ $fail -le 3 ] && echo "  FAIL #$i: No allocation for port $port"
            continue
        fi

        local code=$(curl -s -o /dev/null -w "%{http_code}" \
            -X POST "$BASE/api/application/servers" \
            -H "Authorization: Bearer $TOKEN" \
            -H "Accept: application/json" \
            -H "Content-Type: application/json" \
            -d "{
                \"name\": \"loadtest-${i}\",
                \"user\": 1,
                \"egg\": ${egg_id},
                \"docker_image\": \"ghcr.io/pterodactyl/yolks:debian\",
                \"startup\": \"./clock.sh\",
                \"environment\": {},
                \"limits\": {\"memory\": 128, \"swap\": 0, \"disk\": 512, \"io\": 500, \"cpu\": 10},
                \"feature_limits\": {\"databases\": 0, \"backups\": 0, \"allocations\": 1},
                \"allocation\": {\"default\": ${alloc_id}},
                \"start_on_completion\": false,
                \"skip_scripts\": true
            }")

        if [ "$code" = "200" ] || [ "$code" = "201" ]; then
            ok=$((ok + 1))
        else
            fail=$((fail + 1))
            [ $fail -le 3 ] && echo "  FAIL #$i: HTTP $code"
        fi
        [ $(( (i - start + 1) % 100)) -eq 0 ] && echo "  Progress: $((i - start + 1))/$count (ok=$ok, fail=$fail)"
    done
    echo "  DONE: ok=$ok, fail=$fail"
}

create_pelican() {
    local count=$1 start=$2
    echo "=== Pelican: creating $count servers (from $start) ==="

    local BASE="http://10.10.10.13"
    local TOKEN="papp_9n5NSc9iMIlkMIlc2M87KX1F8CwAsinUvPW6Ae9W3QF"

    # Find node
    local node_id=$(curl -s "$BASE/api/application/nodes" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Accept: application/json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d['data'][0]['attributes']['id'])
" 2>/dev/null)

    if [ -z "$node_id" ]; then
        echo "  ERROR: Cannot list nodes."
        return 1
    fi
    echo "  Node ID: $node_id"

    # Find Clock Mock egg
    local egg_id=""
    egg_id=$(curl -s "$BASE/api/application/eggs" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Accept: application/json" | python3 -c "
import sys, json
for e in json.load(sys.stdin).get('data', []):
    if 'clock' in e['attributes']['name'].lower():
        print(e['attributes']['id'])
        break
" 2>/dev/null)

    if [ -z "$egg_id" ]; then
        local nests=$(curl -s "$BASE/api/application/nests" \
            -H "Authorization: Bearer $TOKEN" \
            -H "Accept: application/json" | python3 -c "
import sys, json
for n in json.load(sys.stdin).get('data', []):
    print(n['attributes']['id'])
" 2>/dev/null)
        for nest_id in $nests; do
            egg_id=$(curl -s "$BASE/api/application/nests/${nest_id}/eggs" \
                -H "Authorization: Bearer $TOKEN" \
                -H "Accept: application/json" | python3 -c "
import sys, json
for e in json.load(sys.stdin).get('data', []):
    if 'clock' in e['attributes']['name'].lower():
        print(e['attributes']['id'])
        break
" 2>/dev/null)
            [ -n "$egg_id" ] && break
        done
    fi

    if [ -z "$egg_id" ]; then
        echo "  ERROR: Clock Mock egg not found."
        return 1
    fi
    echo "  Egg ID: $egg_id"

    # Batch create allocations
    echo "  Creating allocations in batches..."
    local batch_size=50
    for batch_start in $(seq $start $batch_size $((start + count - 1))); do
        local batch_end=$((batch_start + batch_size - 1))
        [ $batch_end -gt $((start + count - 1)) ] && batch_end=$((start + count - 1))

        local ports_json="["
        for p in $(seq $batch_start $batch_end); do
            [ "$ports_json" != "[" ] && ports_json="${ports_json},"
            ports_json="${ports_json}\"$((30000 + p))\""
        done
        ports_json="${ports_json}]"

        curl -s -o /dev/null -X POST "$BASE/api/application/nodes/${node_id}/allocations" \
            -H "Authorization: Bearer $TOKEN" \
            -H "Accept: application/json" \
            -H "Content-Type: application/json" \
            -d "{\"ip\": \"0.0.0.0\", \"ports\": ${ports_json}}" 2>/dev/null
    done
    echo "  Allocations created"

    # Fetch all allocations once
    echo "  Fetching allocation map..."
    local alloc_map=$(curl -s "$BASE/api/application/nodes/${node_id}/allocations?per_page=50000" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Accept: application/json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for a in d.get('data', []):
    attr = a['attributes']
    if not attr['assigned']:
        print(f\"{attr['port']}:{attr['id']}\")
" 2>/dev/null)

    declare -A ALLOC_MAP
    while IFS=: read -r port alloc_id; do
        ALLOC_MAP[$port]=$alloc_id
    done <<< "$alloc_map"
    echo "  Available allocations: ${#ALLOC_MAP[@]}"

    local ok=0 fail=0
    for i in $(seq $start $((start + count - 1))); do
        local port=$((30000 + i))
        local alloc_id="${ALLOC_MAP[$port]}"

        if [ -z "$alloc_id" ]; then
            fail=$((fail + 1))
            [ $fail -le 3 ] && echo "  FAIL #$i: No allocation for port $port"
            continue
        fi

        local code=$(curl -s -o /dev/null -w "%{http_code}" \
            -X POST "$BASE/api/application/servers" \
            -H "Authorization: Bearer $TOKEN" \
            -H "Accept: application/json" \
            -H "Content-Type: application/json" \
            -d "{
                \"name\": \"loadtest-${i}\",
                \"user\": 1,
                \"egg\": ${egg_id},
                \"docker_image\": \"ghcr.io/pterodactyl/yolks:debian\",
                \"startup\": \"./clock.sh\",
                \"environment\": {},
                \"limits\": {\"memory\": 128, \"swap\": 0, \"disk\": 512, \"io\": 500, \"cpu\": 10},
                \"feature_limits\": {\"databases\": 0, \"backups\": 0, \"allocations\": 1},
                \"allocation\": {\"default\": ${alloc_id}},
                \"start_on_completion\": false,
                \"skip_scripts\": true
            }")

        if [ "$code" = "200" ] || [ "$code" = "201" ]; then
            ok=$((ok + 1))
        else
            fail=$((fail + 1))
            [ $fail -le 3 ] && echo "  FAIL #$i: HTTP $code"
        fi
        [ $(( (i - start + 1) % 100)) -eq 0 ] && echo "  Progress: $((i - start + 1))/$count (ok=$ok, fail=$fail)"
    done
    echo "  DONE: ok=$ok, fail=$fail"
}

create_pufferpanel() {
    local count=$1 start=$2
    echo "=== PufferPanel: creating $count servers (from $start) ==="

    local BASE="http://10.10.10.14:8080"
    local CLIENT_ID="7f7aa0c8-f484-4425-ad83-5a206e77c502"
    local CLIENT_SECRET="jO7q-s8fFJXU1HZlHGhNjCh7Hcu1zDhgG1mF9L5DzAXJMmtM"

    local token=$(curl -s -X POST "$BASE/oauth2/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "grant_type=client_credentials&client_id=${CLIENT_ID}&client_secret=${CLIENT_SECRET}" \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))")

    if [ -z "$token" ]; then
        echo "  ERROR: Cannot get OAuth2 token"
        return 1
    fi

    local ok=0 fail=0
    for i in $(seq $start $((start + count - 1))); do
        local server_id=$(python3 -c "import secrets; print(secrets.token_hex(4))")
        local port=$((27000 + i))
        local code=$(curl -s -o /dev/null -w "%{http_code}" \
            -X PUT "$BASE/api/servers/${server_id}" \
            -H "Authorization: Bearer $token" \
            -H "Accept: application/json" \
            -H "Content-Type: application/json" \
            -d "{
                \"type\": \"clock-mock\",
                \"display\": \"loadtest-${i}\",
                \"data\": {},
                \"install\": [
                    {\"type\": \"download\", \"files\": [\"https://files.gameap.ru/clock.sh.tar.gz\"]},
                    {\"type\": \"extract\", \"source\": \"clock.sh.tar.gz\", \"destination\": \"\"}
                ],
                \"uninstall\": null,
                \"run\": {
                    \"command\": [{\"command\": \"./clock.sh\", \"if\": \"\"}],
                    \"stdin\": {\"type\": \"stdin\"},
                    \"autostart\": false, \"autorecover\": false, \"autorestart\": false
                },
                \"environment\": {\"type\": \"host\", \"disableUnshare\": false, \"mounts\": []},
                \"supportedEnvironments\": [{\"type\": \"host\"}],
                \"requirements\": {},
                \"stats\": {\"type\": \"\"},
                \"query\": {\"type\": \"\"},
                \"keepAlive\": {\"frequency\": \"\", \"command\": \"\"},
                \"name\": \"loadtest-${i}\",
                \"node\": 1,
                \"users\": [\"admin\"]
            }")

        if [ "$code" = "200" ] || [ "$code" = "201" ] || [ "$code" = "204" ]; then
            ok=$((ok + 1))
        else
            fail=$((fail + 1))
            [ $fail -le 3 ] && echo "  FAIL #$i (id=$server_id): HTTP $code"
        fi
        [ $(( (i - start + 1) % 100)) -eq 0 ] && echo "  Progress: $((i - start + 1))/$count (ok=$ok, fail=$fail)"
    done
    echo "  DONE: ok=$ok, fail=$fail"
}

# ========================
# MAIN
# ========================

case "$PANEL" in
    gameap-3|gameap3)     create_gameap3 $COUNT $START ;;
    gameap-4|gameap4)     create_gameap4 $COUNT $START ;;
    pterodactyl)          create_pterodactyl $COUNT $START ;;
    pelican)              create_pelican $COUNT $START ;;
    pufferpanel)          create_pufferpanel $COUNT $START ;;
    all)
        create_gameap4 $COUNT $START
        echo ""
        create_gameap3 $COUNT $START
        echo ""
        create_pterodactyl $COUNT $START
        echo ""
        create_pelican $COUNT $START
        echo ""
        create_pufferpanel $COUNT $START
        ;;
    *)
        echo "Usage: $0 [gameap-3|gameap-4|pterodactyl|pelican|pufferpanel|all] [count] [start_from]"
        exit 1
        ;;
esac

echo ""
echo "=== ALL DONE ==="
