# The local API on Windows

**Not re-run by this packet.** Everything below was executed once on Windows 11 Home build 26200
x86_64 against smolvm v1.14.2.

The whole lifecycle works, over **loopback TCP only**.

## Starting the server

`machine start` on the CLI never returns to a caller that captures its output. The HTTP API is a
clean way to drive smolvm from PowerShell precisely because it avoids that, but the server itself
still has to be launched without capturing:

```powershell
Start-Process -FilePath $exe -ArgumentList @('serve','start','--listen','127.0.0.1:18899') `
  -RedirectStandardOutput serve.out -RedirectStandardError serve.err -WindowStyle Hidden -PassThru
```

## What was observed

```
health         : {"status":"ok","version":"1.14.2","machines":{"total":0,"running":0},...}
POST /machines : {"name":"wapi","state":"created","cpus":4,"memoryMb":2048,...}
POST start     : {"name":"wapi","state":"running","pid":3664,...}
POST exec      : {"exitCode":0,"stdout":"WIN_API_OK\nLinux x86_64\n",...}
PUT  files/root%2Fw.txt : {"path":"/root/w.txt","size":10}
GET  files/root%2Fw.txt : WINPAYLOAD
POST stop / DELETE      : stopped / deleted
GET  /machines          : {"machines":[]}
```

`serve openapi -o spec.json` wrote 153291 bytes.

## Four Windows differences that change how you write a client

- **The Unix socket transport is not applicable.** The default listen address on Unix is
  `unix://$XDG_RUNTIME_DIR/smolvm.sock`; this run used loopback TCP only and no `--listen unix://`
  form was attempted. Loopback is therefore the only boundary you have, and there is no
  authentication, so treat the port as equivalent to a shell on the host.
- **The create field is `network`, not `net`.** The same as everywhere, but it matters more here
  because of the next point.
- **400 and 404 return empty bodies.** A wrong field name gets no diagnostic at all. On macOS and
  Linux the same requests come back with `{"error":"...","code":"..."}`, so a client that reads the
  error text works there and goes silent here. Export the spec and read
  `components.schemas.CreateMachineRequest` before writing a body.
- **`serve openapi` reports `info.version "0.5.2"`** while `/health` on the same server reports
  `1.14.2`. Also true on macOS, so it is not a Windows quirk, but it was found here.

## One result that differs from Linux, and does not clear it

**A file PUT before `start` survived the start on this host.** On Linux the same sequence lost the
file. That does not lift the ordering rule in `references/traps.md`: the rule costs nothing, the
loss is real on Linux, and the Windows result is one run. Upload after a successful `exec`.

## Everything else about Windows

State cannot be relocated and reached 30 GB in one session, `machine list` is not read-only, and
PowerShell renders the exe's stderr as error records on a fully successful run. Those are in the
`install` and `teardown` packets.
