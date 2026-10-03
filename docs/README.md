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
| [branch-and-checkpoint](branch-and-checkpoint/README.md) | scheduled checkpoints with history, restores, pause and resume, and branches with their branch point kept | [SKILL.md](branch-and-checkpoint/SKILL.md) |
| [credentials](credentials/README.md) | an API key a workload can use but never read, substituted on the way out | [SKILL.md](credentials/SKILL.md) |
| [dev-env](dev-env/README.md) | a machine you come back to, and what survives a stop and start | [SKILL.md](dev-env/SKILL.md) |
| [docker-in-machine](docker-in-machine/README.md) | a Docker daemon inside a machine, for Testcontainers and Compose | [SKILL.md](docker-in-machine/SKILL.md) |
| [gpu-cuda](gpu-cuda/README.md) | CUDA Driver API calls remoted to the host NVIDIA GPU | [SKILL.md](gpu-cuda/SKILL.md) |
| [install](install/README.md) | installing smolvm and proving the host can boot a microVM | [SKILL.md](install/SKILL.md) |
| [local-api](local-api/README.md) | driving the machine lifecycle over the local HTTP API | [SKILL.md](local-api/SKILL.md) |
| [pack](pack/README.md) | packing an image or a machine into a portable artifact | [SKILL.md](pack/SKILL.md) |
| [teardown](teardown/README.md) | what state exists, where it lives, and how to leave nothing running | [SKILL.md](teardown/SKILL.md) |
