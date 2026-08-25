# bench/container/ -- the Tier-1 trial image

`Dockerfile` builds the one image every Tier-1 trial container is instantiated
from (design doc "Environment"; see `bench/README`'s Tier-1 stanza for the
full harness layout). Every pin's provenance is recorded in the Dockerfile's
own header comment -- read that before re-pinning anything here.

## Building

```
docker build -t agent-kit-bench-tally:local bench/container
```

Not run in CI and not exercised by `tests/test-bench-harness.sh`: a real
build pulls ~150MB of packages over the network and is exactly the kind of
slow, environment-dependent step the design doc's Tier-1 acceptance criteria
carve out as an operator action, not a CI gate ("CI green (harness dry-run
mode; no real trials in CI)"). `bench/lib/container-lifecycle.sh`'s dry-run
mode exercises the *lifecycle logic* (build/run/destroy sequencing, the
per-trial destruction check) without ever invoking `docker build`/`docker
run` for real; see that file's header comment.

## Re-pinning

Re-run the exact commands in the Dockerfile's header comment against a fresh
`debian:13` digest, update every version string that changed, and rebuild.
Do not hand-edit a version string without re-running its resolution command
-- a guessed version is not a pin.

## Secrets

Never build an image with a secret as `--build-arg`, `ARG`, or `ENV`: any of
those persist in a layer any image consumer can read back out (`docker
history`, `docker save`). Secrets are injected at `docker run` time only, via
`bench/lib/container-lifecycle.sh`'s `container_run` (`-e` flags), which the
Dockerfile itself never references.
