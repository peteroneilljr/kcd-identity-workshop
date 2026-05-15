# Contributing

Thanks for helping improve this workshop. Small, focused pull requests are easiest to review.

## Try your changes locally

1. **Cluster:** minikube, kind, Docker Desktop Kubernetes, or any cluster where you can `kubectl apply`.
2. **Deploy:** from the repo root, `kubectl apply -f k8s/` and wait for workloads (see [`follow-along/00-setup.md`](follow-along/00-setup.md)).
3. **Smoke test:** with the namespace up, run:

   ```bash
   ./tests/test-demo.sh
   ```

   The script starts its own port-forwards and prints a pass/fail summary. It requires `kubectl`, `curl`, `jq`, `python3`, `ssh`, `ssh-keygen`, `nc`, `psql`, and `openssl` on your `PATH`.

4. **Hands-on spot-check:** if you change behaviour visible to attendees, re-run the affected [`follow-along/`](follow-along/) module(s).

## Editing Kubernetes config

Sources of truth for several ConfigMaps live under [`k8s/config-src/`](k8s/config-src/). After editing, regenerate the embedded manifest (see tables in [`k8s/README.md`](k8s/README.md)) so `kubectl apply -f k8s/` stays one-step for workshop users.

## Editing demo services

Container sources are under [`docker/`](docker/). CI builds and pushes to GHCR; for local iteration see [`docker/README.md`](docker/README.md).

## Documentation

- Workshop steps live in [`follow-along/`](follow-along/); keep commands copy-pasteable and note macOS/Linux differences where it matters.
- Broader concepts live in [`docs/`](docs/).

## PR checklist

- [ ] Scope is clear (one concern per PR when possible).
- [ ] No secrets (`.env`, realm passwords beyond the documented demo `password`, private keys, etc.).
- [ ] `./tests/test-demo.sh` passes if your change touches cluster behaviour, manifests, or demo images.
- [ ] Linked follow-along sections still match reality (URLs, ports, expected status codes).

## Questions

Open a [GitHub issue](https://github.com/peteroneilljr/kcd-identity-workshop/issues) or discuss in your PR. For minikube/Docker/kubectl friction, see [Troubleshooting](follow-along/99-cleanup.md#troubleshooting) in the workshop docs.
