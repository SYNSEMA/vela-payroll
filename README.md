# vela-payroll — private payroll on Vela (Horizen), in Synsema

An employer funds the app with a stablecoin and runs payroll. Each person sees only their own
payslips. Names, amounts and balances never leave the enclave: the chain sees deposits,
withdrawals and one public receipt per run (run number, head count, a hash of the items) — enough
to prove a run happened and to let anyone who holds the items prove they were paid, and nothing
more. An auditor the employer allows can ask the enclave for the plain picture.

Built on [Vela](https://docs.horizen.io/vela/introduction/), whose Executor runs the app inside a
TEE and settles every result on-chain. The app is **one `.syn` file** with its tests; the module is
the release's guest with that program in its slot (no compiler); and the side outside the enclave is
Synsema too: a **web console** (the recipe's entry) and a command-line client on the same library.
Verified end to end against Horizen's starter kit v0.2.0 (the real Executor, the real contracts) on
the public devnet.

## The console

Deploy the recipe on [synsema.com](https://synsema.com) — the project's environment is provisioned
from the public devnet at creation (a token of your own, the addresses, the keys) — or run it
locally: `synsema serve web.syn` from this folder, with `.env` copied from `.env.example` and filled
by `cd client && synsema run vela_client.syn -- devnet`. Then, in the browser:

1. **Deploy the payroll.** The console embeds `app/app.syn` into the release's guest module, deploys
   it to Vela for this employer and token, and registers the employer's key with the enclave.
2. **Fund.** Approves the token and deposits it: the employer's balance inside the enclave.
3. **Onboard people.** A key is made for each person and registered through the facilitator — they
   need no ETH. (The console keeps those keys on its volume: the shape of an HR portal that custodies
   keys for its people. A person with their own wallet uses the CLI with their own `.env`.)
4. **Run payroll.** A period, a memo, an amount per person. Every person gets an encrypted payslip,
   the employer a summary, the chain a receipt.
5. **Payslips and payouts.** Each person's page shows their payslips, decrypted with their key, and
   pays out to their wallet: a withdrawal they sign, submitted by the employer's facilitator, and the
   on-chain claim.

Every action is one request to the enclave: 30 to 60 seconds on a devnet. The console's state
(app id, keys, people, runs) lives in `data/payroll.json`, a volume on the platform.

## What you get

```
web.syn                      the console: deploy · fund · onboard · pay run · payslips · payouts (the recipe's entry, kind = web)
pages/                       its two pages
app/app.syn                  the payroll app, inside the enclave: deploy · deposit · payrun · withdraw · deanonymize, with tests
client/vela_lib.syn          Vela's client protocol as a module (keys, cipher, submit, events, facilitator, reports, token amounts)
client/vela_client.syn       the command-line client on the same module: everything the console does, and more, from a terminal
client/payroll.example.csv   the CSV shape for the CLI: to,amount,memo
scripts/embed_lib.syn        the app slot of a guest module (what build.sh and the console use to embed the program)
scripts/build.sh             app/app.syn → build/app.wasm with the release's guest, for the CLI's deploy
scripts/smoke.mjs            probe of the module under Node's WASI, the way the Executor drives it
scripts/devnet.sh            Horizen's starter kit in Docker, the test token deployed and allowlisted, client/.env written
scripts/erc20/               the test stablecoin (TST, 6 decimals, permit) and the forge script that deploys and allowlists it
scripts/e2e.sh               the CLI's whole cycle: deploy → fund → onboard → pay run → payslip → withdraw → claim
.github/workflows/build.yml  CI: tests, build, Node 24 + wasmtime-go probes, build/app.wasm as an artifact
syn.toml                     the recipe descriptor: the console as entry, the public devnet as default, [provision] for the token
```

## How it works

```
employer ──fund (approve + deposit of the token)──▶ ┌──────────── enclave ────────────┐
employer ──payrun (encrypted items)───────────────▶ │ balances[employer] -= total      │──▶ chain: receipt(run, count, keccak(items))
                                                    │ balances[each person] += amount  │──▶ each person: an encrypted payslip
                                                    │ payslips += …                    │──▶ employer: an encrypted summary
person ────withdraw (encrypted; via facilitator)──▶ │ balances[person] -= amount       │──▶ chain: a pull-payment in the token
anyone ────claim(token, person) on-chain ─────────▶ the tokens land in the person's wallet
auditor ───report (deanonymize) ──────────────────▶ balances or payslips, encrypted to the auditor
```

- **Only the employer runs payroll**, and never beyond the balance it deposited. An item list is
  checked whole before anything moves.
- **People need no ETH.** They sign typed data; the employer's facilitator submits and pays the fee.
  Anyone can trigger the on-chain `claim` for a person.
- **Deterministic by construction.** No clock, no randomness, no network inside; amounts are the
  token's smallest unit as text, exact to 256 bits. The console and the CLI convert from `1500.50`
  using the token's `decimals()`.
- **One token per app.** Deposits in anything else are rejected; the token must be on Vela's
  allowlist (the public devnet has one: `VELA_TOKEN`).

## The command line

`client/vela_client.syn`, run from `client/` with `client/.env` (`vela_client.syn -- devnet` writes
it, keys included):

| `synsema run vela_client.syn -- …` | who | does |
|---|---|---|
| `fund <tokens>` | employer | approves and deposits the token into the app |
| `payrun <csv> [period]` | employer | one pay run from a CSV with columns `to,amount,memo` |
| `events [n]` | employer | its decrypted events: the summaries of the runs |
| `payslips [n]` · `payslips-for [n]` | person | their payslips, decrypted (with their key, or the facilitator's `VELA_USER_KEY`) |
| `withdraw <tokens> [to]` · `withdraw-for …` | person | a pull-payment in the token (the person pays the fee, or the facilitator does) |
| `pending <address>` · `claim-for <address>` · `token-balance <address>` | anyone | claims and balances |
| `user-keys` · `register-for` | employer | a fresh key for a person and their onboarding through the facilitator |
| `report '{"report_type":"balances"}'` · `report '{"report_type":"payslips","address":"0x…"}'` | auditor | the plain picture, from the enclave (allowed with `allow-authority`) |
| `devnet` · `allow-token` · `allow-authority` | anyone | a token of your own on the public devnet; allowlists with the admin key |

`scripts/e2e.sh` runs the CLI's whole cycle; `sh scripts/build.sh` makes `build/app.wasm` for the
CLI's `deploy` (the console embeds the program itself).

## What the chain sees

Per run, one public app event, subtype `payrun`, with `abi.encode(uint256 run, uint256 count,
bytes32 keccak256(items))`; deposits and withdrawals in the token; request fees. No addresses of
payees, no amounts, no periods.

## Gotchas

- Every payee must be registered **before** the run that pays them (the console onboards; the CLI
  `register`s): an event for an unregistered address fails the whole run, nothing moves.
- The app is deployed for one employer and one token; redeploying creates a new application id, a
  new ledger.
- Deploying needs an account with `DEPLOYER_ROLE` (Anvil #0 on a devnet, which the provision hands
  out); the auditor needs `DefaultAuthority.addAllowedAuthority(appId, address)` (`allow-authority`).
- A run takes at most 500 items and the enclave keeps the last 2 000 payslips in state; the
  encrypted payslip events on-chain are the permanent record.
- Node 22 crashes intermittently inside V8 running this module; use Node 20 or 24+ for `smoke.mjs`.

The full reference is the docs page [Vela (Horizen)](https://synsema.dev/en/0.6.x/73-vela); the
adapter lives in [kitecosmic/synsema — packages/guests/vela](https://github.com/kitecosmic/synsema/tree/main/packages/guests/vela).

## Guía rápida (español)

Nómina privada: la empresa fondea la app con una stablecoin y corre la nómina; cada persona ve sólo
sus recibos; la cadena ve depósitos, retiros y un recibo por corrida. Desplegá la receta en
synsema.com (el entorno se aprovisiona solo desde el devnet público) o corré `synsema serve web.syn`
con un `.env` de `vela_client.syn -- devnet`, y desde el navegador: desplegar, fondear, dar de alta
personas, correr la nómina, ver recibos y pagar a la billetera. Cada acción es un request al enclave
(30 a 60 s en un devnet). Referencia completa en [synsema.dev/es/0.6.x/73-vela](https://synsema.dev/es/0.6.x/73-vela).

## License

Apache-2.0.
