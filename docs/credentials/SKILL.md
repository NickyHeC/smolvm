---
name: credentials
description: Gives a workload in a smolvm machine an API key or token it can use but never read, by binding the credential to named HTTPS hosts so the guest holds only a placeholder and the host substitutes the value on the way out, then proves on the host that the value never entered the machine. Use when an agent or untrusted code inside a machine has to call an API with your key; when deciding between a credential binding and --secret-env; when a request from a credentialed machine comes back 403 or 502 from smolvm itself; or when you need evidence that a key stayed out of a sandbox. Do not use it for a value the program must read and parse, such as a database URL, which is --secret-env, or for git and ssh keys, which is SSH agent forwarding.
---

# A credential the machine can use and never hold

Verified on **smolvm v1.18.2** on macOS arm64 and Linux aarch64, 2026-09-24, for everything that
is decided on the host; **the substitution arriving at a real API was not observed in this run**,
for the reason under "What was not run". Done means the guest's variable is a placeholder, the value
is nowhere in the guest, the machine's record or smolvm's database, TLS to the bound host goes
through the machine's own CA, and a placeholder anywhere but a request header is refused before it
leaves the host.

`README.md` is how the feature works: bindings, where the value comes from, what the guest sees,
what happens to each request, and the limits. This file is how to set it up and prove it.

## Procedure

```
- [ ] 1. preflight.sh             the flag, the network backend, the host variable
- [ ] 2. create-credentialed.sh   a machine bound to one host
- [ ] 3. verify-containment.sh    the value stays out; the interceptor is on the path
- [ ] 4. your own request         the first call that sends the value
- [ ] 5. cleanup.sh
```

**1. Preflight.** Read-only, and it never prints the value or its length.

```bash
export API_TOKEN=...          # however your secrets manager hands it over
scripts/preflight.sh --var API_TOKEN --host api.example.com
```

```
has_credential_flag=yes
default_backend=virtio-net
tsi_stream_intercept=yes
host_var_set=yes
host_form=ok
memory_required_mib=1024
result=ready
```

`tsi_stream_intercept` is read from the symbols of the bundled libkrun: a binding selects virtio-net
by default, and `--net-backend tsi` carries a credential only when libkrun exports
`krun_set_stream_intercept`, which both v1.18.2 release libraries do. `host_form=rejected` means the
host is not an exact lowercase DNS name; `create` would refuse it anyway, with a clearer message.

**2. Create the machine.** The value is read from the environment of this command's `machine
start`, and that is the value the machine uses until its next start.

```bash
scripts/create-credentialed.sh --var API_TOKEN --host api.example.com
```

```
workload_ready_after_s=1
guest_sees=placeholder
binding=api-token host=api.example.com
result=up
```

The command it runs is `smolvm machine create ... --credential api-token=API_TOKEN@api.example.com`
and then `machine start`. `--credential` implies `--net`. In a Smolfile the same binding is a
`[[network.credentials]]` table, in `README.md`.

**3. Prove the value stayed out.** Nothing this sends carries the placeholder where it would be
substituted, so the value goes nowhere during the check.

```bash
scripts/verify-containment.sh --var API_TOKEN --host api.example.com --other-host example.org
```

```
guest_variable=ok (placeholder)
value_in_guest=ok (0)
value_in_record=ok (0)
interception=ok (on)
passthrough=ok (real)
query_refused=ok (403)
refusal_text=smolvm credentials: placeholders are substituted in request headers only
result=contained
```

`value_in_guest` searches every process environment and the writable trees inside the guest;
`value_in_record` searches the machine's directory and smolvm's database on the host;
`interception` reads the issuer of the bound host's certificate as the guest sees it, which is
`smolvm <machine> credential CA`, while `--other-host` keeps its real issuer.

**4. Use it.** The workload sends the placeholder in a header, exactly where the real key would go:

```bash
smolvm machine exec --name smolskill-cred -- sh -c \
  'curl -sS -H "Authorization: Bearer $API_TOKEN" https://api.example.com/v1/me'
```

That is the first request that carries the value, and it goes only to the host you bound. Judge it
by the API's answer, the way you would without smolvm.

**5. Clean up.**

```bash
scripts/cleanup.sh --purge
```

## Traps

Full detail in `references/traps.md`.

- **The value is the one the machine started with.** Unsetting or changing the host variable for
  a later `machine exec` changed nothing: the interceptor runs in the process `machine start`
  launched. Start with the variable unset and every substituted request answers
  `smolvm credentials: credential unavailable` with a `502`. Rotate an environment value with a
  restart, or use a file reference, which `README.md` says is read per request.
- **Never put the real value on an `exec` command line.** smolvm writes exec commands into the
  machine's console log on the host, so a check that interpolated the value into its own `grep`
  planted it in `agent-console.log` and failed itself. `verify-containment.sh` splits the value
  and rejoins it inside the guest for that reason.
- **A 403 from smolvm is a refusal, not the API.** The body says which rule: a placeholder in the
  path, query or body; in a routing or framing header such as `Cookie`; more than one in a request;
  or one the machine did not mint. A `405` means the binding does not allow this host or method.
- **On v1.18.2 a machine created from a pack ignores `--credential`**, silently: no placeholder and
  no CA in the guest. Create it from an image, as the script does; the fix is upstream after the
  release.
- **Port 80 is not intercepted.** Plaintext HTTP is relayed untouched, so a placeholder there
  travels as the literal string and the API sees garbage.
- **The machine's CA is the only one the guest trusts for the bound host.** curl, Python, Node,
  Deno and Git pick it up from the variables smolvm sets; a client with its own trust store needs
  `/run/smol/credentials/ca.pem` added.

## Security defaults, and why they are the defaults

- **A binding is narrower than a secret.** `--secret-env` puts the plaintext in the workload's
  environment, where any code in the guest can read and send it anywhere the network allows. A
  binding lets the workload use the key only in a header, only toward the hosts named.
- **Bind to the exact host and nothing wider.** Hosts are exact names with no wildcards, and when
  the machine also has `--allow-host`, every credential host has to sit inside that list; a create
  that breaks either rule is refused.
- **Substitution is not data-loss prevention.** An API that echoes your key back in a response
  body hands it to the guest. Bind keys only to APIs you trust with them.
- **The scripts never print the value**, its length or its halves, and the preflight reports only
  whether the variable is set.
- **Cleanup deletes only machines the scripts recorded** under the `smolskill-` prefix.

## Platform arms

`references/platforms.md`. Both hosts here gave the same results on v1.18.2, on the default
virtio-net backend and on `--net-backend tsi`. Linux x86_64 and Windows were not run.

## Eval prompts, and what they produced

Run 2026-09-24 PT against v1.18.2 from the published release, under an isolated `HOME`, on macOS
26.6.2 arm64 and Lima `linux-kvm` (Ubuntu 24.04 aarch64), with a random throwaway value and
`example.com` as the bound host.

**1. "Let the agent in this sandbox call the API with my token without the sandbox ever having the
token."**

`preflight.sh`, `create-credentialed.sh` and `verify-containment.sh` in order, both hosts:
`result=ready`, `guest_sees=placeholder`, then `result=contained` with all six checks as shown
above. The guest's variable read `SMOL_PLACEHOLDER_DEMO_E0226293E472287B661DFAB687C5DE0C` on macOS.

**2. "Every request from my machine to the API now comes back 502 from smolvm."**

The machine was started without the variable in its environment. Reproduced on both hosts by
stopping a working machine and starting it again with the variable unset:

```
smolvm credentials: credential unavailable [502]
```

and by contrast, unsetting it only for `machine exec` on a machine started with it did not produce
the 502. Start the machine with the variable set.

**3. "Prove the key cannot be sent anywhere but the API I named."**

`verify-containment.sh` shows the bound host's certificate is the machine's own CA and another
host's is its real one, and these refusals were measured on both hosts with the placeholder, none
of which forwarded anything:

```
?k=<placeholder> in the query            -> 403 placeholders are substituted in request headers only
-d k=<placeholder> in the body           -> 403 placeholders are substituted in request headers only
two headers carrying the placeholder      -> 403 a request may carry one placeholder
a forged SMOL_PLACEHOLDER_DEMO_...        -> 403 unknown placeholder
Cookie: a=<placeholder>                   -> 403 placeholders are not substituted in routing or framing headers
```

Create-time rules, both hosts: `*.example.com` and an IP address are refused with `must be an exact
lowercase DNS name`, and a credential host outside the machine's `--allow-host` with `is not
reachable under the machine's network allow_hosts`.

## What was not run

- **The value arriving at a real API.** Observing it needs an HTTPS service that reports the header
  it received, and sending even a throwaway token to a third-party echo service was stopped by this
  run's own safety controls. Everything on the host side of that request was observed; the far
  side is the one step not seen. One request did reach `example.com` with a dummy value substituted,
  by mistake, in the check that led to the first trap above; `example.com` ignores the header.
- **File references and rotation in place**, which `README.md` describes; nothing here changed a
  value under a running machine except by the variable.
- **Credentials over the HTTP API**, branches and checkpoints carrying bindings, and portable
  restores on another host.
- **Linux x86_64 and Windows.**

## Related packets

- `sandbox` for the machine this usually protects, and `--allow-host`, which a binding must fit.
- `local-api` for the `credentials` field on a create body.
- `teardown` for the wider cleanup.
