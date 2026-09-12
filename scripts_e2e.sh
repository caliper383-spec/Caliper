#!/bin/bash
cd /Users/shaan/Finance/caliper
set -a; . ./.env; set +a
J=deployments/46630.json
get(){ python3 -c "import json;print(json.load(open('$J'))['$1'])"; }
V=$(get vault); W=$(get weth); P=$(get pool); RPC="$RPC_TESTNET"; PK="$DEPLOYER_KEY"
num(){ cast call "$1" "$2" "${@:3}" --rpc-url "$RPC" | awk '{print $1}'; }

echo "waiting for 600s of oracle history..."
for i in $(seq 1 40); do
  if cast call "$P" 'observe(uint32[])(int56[],uint160[])' '[600,0]' --rpc-url "$RPC" >/dev/null 2>&1; then
    echo "oracle ready after ~$((i*30))s"; break
  fi
  sleep 30
done

echo "=== E2E on live testnet ==="
cast send "$W" 'approve(address,uint256)' "$V" 100000000000000000000 --rpc-url "$RPC" --private-key "$PK" --legacy 2>&1 | grep '^status' | sed 's/^/approve : /'
cast send "$V" 'deposit(uint256,address)' 10000000000000000000 "$DEPLOYER_ADDRESS" --rpc-url "$RPC" --private-key "$PK" --legacy 2>&1 | grep -E '^(status|transactionHash)' | sed 's/^/deposit : /'
echo "shares      : $(cast from-wei $(num "$V" 'balanceOf(address)(uint256)' "$DEPLOYER_ADDRESS"))"
echo "totalAssets : $(cast from-wei $(num "$V" 'totalAssets()(uint256)'))"

cast send "$V" 'deploy()' --rpc-url "$RPC" --private-key "$PK" --legacy 2>&1 | grep -E '^(status|transactionHash)' | sed 's/^/deploy  : /'
echo "tokenId     : $(num "$V" 'tokenId()(uint256)')"
echo "tickLower   : $(num "$V" 'tickLower()(int24)')"
echo "tickUpper   : $(num "$V" 'tickUpper()(int24)')"
echo "totalAssets : $(cast from-wei $(num "$V" 'totalAssets()(uint256)'))"
echo "=== E2E DONE ==="
