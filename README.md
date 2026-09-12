# vela-payroll — private payroll on Vela (Horizen), in Synsema

An employer funds the app with a stablecoin and runs payroll from a CSV. Each person sees only
their own payslips. Names, amounts and balances never leave the enclave: the chain sees deposits,
withdrawals and one public receipt per run (run number, head count, a hash of the items) — enough
to prove a run happened and to let anyone who holds the items prove they were paid, and nothing
more. An auditor the employer allows can ask the enclave for the plain picture.

Built on [Vela](https://docs.horizen.io/vela/introduction/), whose Executor runs the app inside a
TEE and settles every result on-chain, and on the [vela-app](https://github.com/SYNSEMA/vela-app)
starter kit: the app is **one `.syn` file** with its tests, the module is built for you (locally or
by CI), and the client — keys, deploy, funding, pay runs, payslips, withdrawals, on-chain claims,
gasless meta-transactions for employees — is a Synsema program too. Verified end to end against
Horizen's starter kit v0.2.0 (the real Executor and contracts), locally and on the shared devnet.

## What you get

```
app/app.syn                  the payroll app: deploy · deposit · payrun · withdraw · deanonymize, with tests
client/vela_client.syn       the client: everything the starter kit's does + fund · payrun · payslips · withdraw · pending · claim-for
client/payroll.example.csv   the CSV shape: to,amount,memo (amounts in tokens, e.g. 1500.50)
client/.env.example          addresses, URLs, keys and the payroll token the client reads
scripts/build.sh             app/app.syn → build/app.wasm (the guest module Vela loads) + sha256
scripts/smoke.mjs            probe of the module under Node's WASI, the way the Executor drives it
scripts/devnet.sh            Horizen's starter kit in Docker, the test token deployed and allowlisted, client/.env written
scripts/erc20/               the test stablecoin (TST, 6 decimals, permit) and the forge script that deploys and allowlists it
scripts/e2e.sh               a whole payroll cycle: deploy → fund → onboard → pay run → payslip → withdraw → claim
.github/workflows/build.yml  CI: tests, build, Node 24 + wasmtime-go probes, build/app.wasm as an artifact
syn.toml                     the recipe descriptor for the Synsema platform
```

## How it works

```
employer ──fund (approve + deposit of the token)──▶ ┌──────────── enclave ────────────┐
employer ──payrun (encrypted CSV items)───────────▶ │ balances[employer] -= total      │──▶ chain: receipt(run, count, keccak(items))
                                                    │ balances[each person] += amount  │──▶ each person: an encrypted payslip
                                                    │ payslips += …                    │──▶ employer: an encrypted summary
person ────withdraw (encrypted; via facilitator)──▶ │ balances[person] -= amount       │──▶ chain: a pull-payment in the token
anyone ────claim(token, person) on-chain ─────────▶ the tokens land in the person's wallet
auditor ───report (deanonymize) ──────────────────▶ balances or payslips, encrypted to the auditor
```

- **Only the employer runs payroll**, and never beyond the balance it deposited. An item list is
  checked whole before anything moves: one bad address or an amount over the balance fails the run
  and changes nothing.
- **People need no ETH.** They sign typed data; the employer's facilitator submits and pays the fee
  (`register-for`, `withdraw-for`). Anyone can trigger the on-chain `claim` for a person.
- **Deterministic by construction.** No clock, no randomness, no network inside; amounts are the
  token's smallest unit as text, exact to 256 bits. The client converts from `1500.50` using the
  token's `decimals()`.
- **One token per app.** The app is deployed for one stablecoin; deposits in anything else are
  rejected. The token must be on Vela's allowlist.

## Ten minutes

You need the [`synsema` binary](https://synsema.org) (`npm i -g synsema`, or the install script) and,
to build the module, Rust (`rustup`) — or push to GitHub and download `app.wasm` from the CI run.
For the stack you need Docker, or a hosted devnet's URLs and token.

```sh
synsema test app/app.syn                 # 1. the app, natively — the same code runs in the enclave
sh scripts/build.sh                      # 2. build/app.wasm (first time ≈ 5 min: it compiles the interpreter)
node scripts/smoke.mjs build/app.wasm    #    Node 20 or 24+ (not 22)
sh scripts/devnet.sh                     # 3. Vela in Docker + the test token; writes client/.env
sh scripts/e2e.sh                        # 4. the whole cycle: deploy, fund, onboard, pay run, payslip, withdraw, claim
```

`scripts/e2e.sh` deploys the app for the signing address (Anvil #0 on the kit) and `VELA_TOKEN`,
funds it, creates an employee key if `.env` has none, onboards that employee through the
facilitator, writes a one-row `client/payroll.csv`, runs it, prints the employee's payslip, withdraws
part of it and claims it on-chain. Then edit the CSV and run `payrun` again.

The payroll token: Horizen's kit ships no ERC-20, so `scripts/devnet.sh` deploys one for you
(`scripts/erc20/TestToken.sol`: TST, 6 decimals, with EIP-2612 `permit`, the whole supply to
Anvil #0), allowlists it and writes it to `client/.env` as `VELA_TOKEN`. On a hosted devnet the
operator gives you the address of an allowlisted token; on Synsema's shared devnet one is already
there. In production it is the stablecoin your company pays in, once Vela allowlists it.

## The commands

`client/vela_client.syn` has everything the starter kit's client has (`keys`, `deploy`, `register`,
`deposit`, `send`, `report`, `events`, the facilitator flow) plus the payroll:

| `synsema run vela_client.syn -- …` | who | does |
|---|---|---|
| `fund <tokens>` | employer | approves and deposits the token into the app (`fund 5000`) |
| `payrun <csv> [period]` | employer | one pay run from a CSV with columns `to,amount,memo`; encrypted for the enclave; waits for the on-chain result |
| `events [n]` | employer | its decrypted events: the summaries of the runs (`payrun`: count, total, balance) |
| `payslips [n]` · `payslips-for [n]` | person | their payslips, decrypted (with the person's key, or the facilitator's `VELA_USER_KEY`) |
| `withdraw <tokens> [to]` · `withdraw-for …` | person | a pull-payment in the token (the person pays the fee, or the facilitator does) |
| `pending <address>` | anyone | what an address can claim on-chain, in tokens |
| `claim-for <address>` | anyone | triggers `claim(token, address)` on the Processor: the tokens land in the wallet |
| `token-balance <address>` | anyone | the wallet's on-chain balance of the token |
| `user-keys` · `user` · `register-for` | employer | a fresh key for a person, their address, and their onboarding through the facilitator |
| `report '{"report_type":"balances"}'` · `report '{"report_type":"payslips","address":"0x…"}'` | auditor | the plain picture, from the enclave, encrypted to the auditor (must be allowed in `DefaultAuthority`) |

Amounts are in tokens (`1500.50`); the client reads the token's `decimals()` and converts by text,
never through a float. A CSV row with more decimals than the token has is rejected before anything
is sent.

Configuration is `client/.env` (copy `.env.example`): the stack's URLs and contract addresses,
`VELA_TOKEN`, the employer's signing key, the P-521 pair for the private channel, and for the
facilitator commands the person's key.

## Keys, and who holds them

The enclave encrypts each person's payslips to the P-521 key they registered. In this kit one
`.env` holds both the employer's keys and one employee's (`VELA_USER_KEY`), which is the shape of
an HR portal that custodies the keys for its people, and of the demo. A person who holds their own
wallet runs the client with their own `.env` (their `VELA_SECP_KEY` and P-521 pair), registers with
`register`, reads with `payslips`, withdraws with `withdraw` — and pays the request fee themselves.

Every payee must be registered **before** the run that pays them: the enclave refuses an event for
an address without a key, and that fails the whole run (nothing moves). Onboarding is the
`register` / `register-for` step.

## What the chain sees

Per run, one public app event, subtype `payrun`, with `abi.encode(uint256 run, uint256 count,
bytes32 keccak256(items))`; deposits and withdrawals in the token; request fees. Nothing else:
no addresses of payees, no amounts, no periods. Whoever holds the items (the employer, or a person
who received their own row) can show the hash matches.

## Gotchas

- The app is deployed for one employer and one token (`constructorParams`); redeploying creates a
  new application id, a new ledger.
- Deploying needs an account with `DEPLOYER_ROLE` (Anvil #0 on the kit); the token needs
  `TokenAllowlist.addAllowedToken`; the auditor needs `DefaultAuthority.addAllowedAuthority(appId, address)`
  from the admin, per application.
- A run takes at most 500 items and the enclave keeps the last 2 000 payslips in state; the
  encrypted payslip events on-chain are the permanent record.
- Node 22 crashes intermittently inside V8 running this module; use Node 20 or 24+.
- On Windows, run the scripts from Git Bash.

The full reference is the docs page [Vela (Horizen)](https://synsema.dev/en/0.6.x/73-vela); the
adapter lives in [kitecosmic/synsema — packages/guests/vela](https://github.com/kitecosmic/synsema/tree/main/packages/guests/vela).

## Guía rápida (español)

Nómina privada: la empresa fondea la app con una stablecoin y corre la nómina desde un CSV
(`to,amount,memo`, montos en tokens); cada persona ve sólo sus recibos; la cadena ve depósitos,
retiros y un recibo público por corrida (número, cantidad, hash). 1. `synsema test app/app.syn`.
2. `sh scripts/build.sh`. 3. `sh scripts/devnet.sh` y un token permitido en `VELA_TOKEN`.
4. `sh scripts/e2e.sh`: deploy, fondeo, alta de un empleado por el facilitador (sin ETH), una
corrida, su recibo descifrado, un retiro y el `claim` en cadena. Después editá el CSV y `payrun`.
Toda persona debe estar registrada antes de la corrida que la paga. Referencia completa en
[synsema.dev/es/0.6.x/73-vela](https://synsema.dev/es/0.6.x/73-vela).

## License

Apache-2.0.
