# Build your own

checkup is a template, not a product — "take the principles and build your own"
is a first-class path (ADR-0005). The reusable core is the
[contract](architecture.md), not the bundled images. Keep your customisations in
**your** copy; this upstream is generic and isn't a place to send them
(ADR-0006).

## Recipe 1 — run the bare runner on a host

No image needed. checkup degrades to whatever tools are on `$PATH`:

```bash
git clone https://github.com/maudlin/checkup && cd checkup
# install only the tools you care about, e.g.:
#   apt install shellcheck   |   brew install gitleaks scc semgrep
CHECKUP_TARGET=/path/to/repo CHECKUP_OUT_DIR=/tmp/out bin/checkup.sh
```

Absent tools `skip` honestly — you get exactly the checks your host can run.

## Recipe 2 — a slim custom image

Copy only the tool blocks you want from [`Dockerfile`](../Dockerfile) into your
own image. Each block is self-contained and carries its pinned checksum:

```dockerfile
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
        bash git jq curl ca-certificates && rm -rf /var/lib/apt/lists/*
# paste the gitleaks + scc RUN blocks (with their *_SHA256 ARGs) from Dockerfile
COPY bin/ /opt/checkup/bin/
COPY lib/ /opt/checkup/lib/
ENTRYPOINT ["/opt/checkup/bin/checkup.sh"]
```

Keep the `sha256sum -c` verification when you copy a block (ADR-0001).

## Recipe 3 — extract a baked binary

```bash
docker create --name tmp checkup-core
docker cp tmp:/usr/local/bin/gitleaks ./gitleaks
docker rm tmp
```

See [tools.md](tools.md) for the full catalogue and upstreams.

## Recipe 4 — add a check

Follow the [contract](architecture.md#the-parsed-json-record): a documented
`intent`, then emit `reports/parsed/<slug>.json` via `write_parsed` /
`write_skipped` / `write_failed`. The renderer picks it up automatically — no
renderer changes. A new tool you bundle must be version-pinned **and**
SHA256-verified.

## Recipe 5 — your own stack overlay

`FROM checkup-core`, add that one stack's toolbelt (nothing extraneous —
ADR-0004), and add the stack's checks to an overlay script in the
[`checkup-dotnet`](../bin/checkup-dotnet.sh) shape: run core, append your
`parsed/*.json`, render once.

---

If you build something broadly useful (a new _universal_ check, a bug fix),
open an issue to discuss — but project-specific tailoring belongs in your copy,
not a PR here (ADR-0006).
