# smolvm documentation

The flat pages here (`branching.md`, `smolfile.md`, `security-model.md` and the rest) are the
reference for each feature. Each folder is a task: a `README.md` with the facts and why they hold,
and a `SKILL.md` an agent can follow, with its own `scripts/` and `references/`. A topic links to
the reference page it builds on rather than repeating it.

Install a topic into an agent's skills directory with:

```bash
npx skills add smol-machines/smolvm --skill <topic>
```

`llms.txt` lists every `SKILL.md` path for agents that read the tree directly.

## Topics

| Topic | What it covers | Procedure |
|---|---|---|
| [throwaway-machine](throwaway-machine/README.md) | running untrusted code in a throwaway machine, with egress granted one host at a time | [SKILL.md](throwaway-machine/SKILL.md) |
