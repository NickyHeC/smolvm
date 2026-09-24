# smolvm documentation

One folder per task. Each topic holds a `README.md` with the facts and why they hold, and where a
procedure exists, a `SKILL.md` an agent can follow, with its own `scripts/` and `references/`.

Install a topic into an agent's skills directory with:

```bash
npx skills add smol-machines/smolvm --skill <topic>
```

`llms.txt` lists every `SKILL.md` path for agents that read the tree directly.

## Topics

| Topic | What it covers | Procedure |
|---|---|---|
| [dev-env](dev-env/README.md) | a machine you come back to, and what survives a stop and start | [SKILL.md](dev-env/SKILL.md) |
| [local-api](local-api/README.md) | driving the machine lifecycle over the local HTTP API | [SKILL.md](local-api/SKILL.md) |
| [docker-in-machine](docker-in-machine/README.md) | a Docker daemon inside a machine, for Testcontainers and Compose | [SKILL.md](docker-in-machine/SKILL.md) |
| [gpu-cuda](gpu-cuda/README.md) | CUDA Driver API calls remoted to the host NVIDIA GPU | [SKILL.md](gpu-cuda/SKILL.md) |
| [pack](pack/README.md) | packing an image or a machine into a portable artifact | [SKILL.md](pack/SKILL.md) |
| [gpu-vulkan](gpu-vulkan/README.md) | Vulkan over virtio-gpu, and why it has no procedure yet | |
| [branch-and-checkpoint](branch-and-checkpoint/README.md) | scheduled checkpoints with history, restores, pause and resume, and branches with their branch point kept | [SKILL.md](branch-and-checkpoint/SKILL.md) |
| [kubernetes](kubernetes/README.md) | a pod as its own microVM through the containerd shim | |
| [headless-browser](headless-browser/README.md) | headless Chromium, and pre-warmed browser pools | |
| [smolfile](smolfile/README.md) | the Smolfile format, the one reference | |
| [contributing](contributing/DEVELOPMENT.md) | building and developing smolvm | |
