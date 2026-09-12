#!/bin/sh
# One whole payroll cycle against a Vela stack (the one in client/.env): keys → deploy → the employer
# registers and funds → an employee is onboarded through the facilitator (they hold no ETH) → one
# pay run from a CSV → the employee reads their payslip and withdraws → the on-chain claim.
#
#   sh scripts/e2e.sh                                   # deploys build/app.wasm on VELA_TOKEN (client/.env)
#   FUND=5000 CSV=client/payroll.csv PERIOD=2026-09 sh scripts/e2e.sh
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_WASM="${APP_WASM:-$ROOT/build/app.wasm}"
FUND="${FUND:-5000}"
PERIOD="${PERIOD:-$(date +%Y-%m)}"
cd "$ROOT/client"
[ -f .env ] || { echo "client/.env is missing: run scripts/devnet.sh, or copy .env.example and point it at a hosted devnet"; exit 2; }
[ -f "$APP_WASM" ] || { echo "$APP_WASM is missing: run scripts/build.sh (or download the CI artifact)"; exit 2; }
TOKEN="$(sed -n 's/^VELA_TOKEN=//p' .env | tr -d '\r')"
[ -n "$TOKEN" ] || { echo "VELA_TOKEN is empty in client/.env: the payroll needs an allowlisted ERC-20 (scripts/devnet.sh deploys one locally; on the public devnet copy VELA_TEST_TOKEN into VELA_TOKEN, or allow-token another)"; exit 2; }
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) APP_WASM="$(cygpath -w "$APP_WASM")" ;; esac

run() { synsema run vela_client.syn -- "$@"; }
put() { sed -i.bak "s/^$1=.*/$1=$2/" .env && rm -f .env.bak; }

if ! grep -q '^VELA_P521_KEY=.\{10,\}' .env; then
  echo "== keys: a fresh P-521 pair, written to .env"
  KEYS="$(run keys)"
  put VELA_P521_KEY "$(echo "$KEYS" | sed -n 's/^VELA_P521_KEY=//p')"
  put VELA_P521_PUB "$(echo "$KEYS" | sed -n 's/^VELA_P521_PUB=//p')"
fi
if ! grep -q '^VELA_USER_KEY=.\{10,\}' .env; then
  echo "== user-keys: a fresh secp256k1 key for the employee (it never needs ETH), written to .env"
  put VELA_USER_KEY "$(run user-keys | sed -n 's/^VELA_USER_KEY=//p')"
fi

EMPLOYER="$(run address | tail -1)"
EMPLOYEE="$(run user | tail -1)"
echo "== employer $EMPLOYER pays in $TOKEN; employee $EMPLOYEE"

echo "== deploy $APP_WASM"
OUT="$(run deploy "$APP_WASM" "{\"employer\":\"$EMPLOYER\",\"token\":\"$TOKEN\"}")"; echo "$OUT"
APP_ID="$(echo "$OUT" | sed -n 's/.*VELA_APP_ID=\([0-9]*\).*/\1/p')"
[ -n "$APP_ID" ] || { echo "no application id in the deploy output"; exit 1; }
put VELA_APP_ID "$APP_ID"

echo "== register (the employer: it receives the pay-run summaries)"; run register
echo "== fund $FUND tokens (approve + deposit)"; run fund "$FUND"
echo "== register-for (the employee, onboarded by the facilitator: no ETH on their side)"; run register-for

if [ -z "${CSV:-}" ]; then
  CSV="$ROOT/client/payroll.csv"
  printf 'to,amount,memo\n%s,1500.50,%s salary\n' "$EMPLOYEE" "$PERIOD" > "$CSV"
  echo "== wrote $CSV (one row: the employee)"
fi
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) CSV="$(cygpath -w "$CSV")" ;; esac
echo "== payrun $CSV $PERIOD"; run payrun "$CSV" "$PERIOD"
echo "== events 1 (the employer's summary, decrypted)"; run events 1
echo "== payslips-for 3 (the employee's payslips, decrypted)"; run payslips-for 3
echo "== withdraw-for 500.25 (the employee, through the facilitator)"; run withdraw-for 500.25
echo "== pending $EMPLOYEE"; run pending "$EMPLOYEE"
echo "== claim-for $EMPLOYEE (anyone may trigger it; the tokens go to the employee)"; run claim-for "$EMPLOYEE"
echo "== token-balance $EMPLOYEE"; run token-balance "$EMPLOYEE"
echo "done: VELA_APP_ID=$APP_ID is in client/.env"
