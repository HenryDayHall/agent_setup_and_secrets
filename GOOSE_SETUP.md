# Goose in a sealed Apptainer box on Maxwell (DESY Assistant + Blablador)

These instructions set up [Goose](https://goose-docs.ai) so it can write and run code for you on a cluster.
Use it if you want a highly autonomous agent to design solutions and generate data with minimal intervention.
 Throughout, Goose:

- runs in an Apptainer container ("the box") with **no network**, **no credentials** and **only the folders you hand it**. If you choose, it can also make HTTPS connections to host names you list (section 4);
- cannot reach SSH, Slurm or anything else on the cluster: it has no route out and nothing to log in with;
- never sees your API keys. They stay GPG-encrypted on disk and are decrypted only into a small proxy (Caddy) that runs outside the box and adds the key to each request.

```
 Apptainer box (no network)             outside the box
 ┌──────────────────────────┐   Unix    ┌────────────────────────┐
 │ Goose + your workspace   │──socket──►│ Caddy: holds the keys  │──► assistant.desy.de
 │                          │           └────────────────────────┘──► Blablador
 │                          │ optional  ┌────────────────────────┐
 │                          │──socket──►│ netproxy: allowlist    │──► pypi.org, github.com, …
 └──────────────────────────┘           └────────────────────────┘
```

Everything lives in one directory on DUST, called `$AB` below. All commands are bash.

## 1. One-time setup

### 1.1 Directories

```bash
module load maxwell apptainer  # no need to do anything on the naf, it's loaded by default
export AB=/data/dust/user/$USER/agentbox  # need to do this every time you run, or put in ~/.bashrc
export APPTAINER_CACHEDIR=$AB/cache APPTAINER_TMPDIR=$AB/tmp
mkdir -p $AB/{bin,home,ws,cache,tmp} $AB/home/.config/goose/custom_providers
```

### 1.2 Get the files and store the keys, encrypted

This repository, [agent_setup_and_secrets](https://github.com/HenryDayHall/agent_setup_and_secrets) has a folder called `goose` with lots of files we will need.
For convince `SRC` points at its `goose/` folder for the rest of the setup.

```bash
SRC=${PATH_TO_REPO}/goose
```

As the aim is to have Caddy automate the outgoing connections of this model, we need `secret.sh` in a place it can find.
I assume you have already used it to encrypt at least one api key, which you will be using in goose (otherwise, check the main [README.md](../README.md).

```bash
install -m 700 $SRC/../secret.sh $AB/secret.sh   # cp + chmod 700 in one step
```

### 1.3 Build the image

The image starts from the key4hep AlmaLinux 9 image, so `/cvmfs` software also works inside the box. On top of that it adds Goose, socat, Python and LaTeX. The definition is `agentbox.def`:

```bash
install -m 644 $SRC/agentbox.def $AB/agentbox.def
```

Build it on a local disk, not on DUST. A `--fakeroot` build unpacks the image into `APPTAINER_TMPDIR`.
On a network filesystem such as DUST, the package installs then fail with errors like `cpio: open failed - Permission denied`. `/dev/shm` is local, because it lives in memory. First check that it has a few GB free and is not mounted `noexec`:

```bash
findmnt -no FSTYPE,AVAIL,OPTIONS -T /dev/shm        # want: tmpfs, 5G or more, no "noexec"
cd $AB
BUILD=$(mktemp -d /dev/shm/agentbox-build.XXXXXX)
APPTAINER_TMPDIR=$BUILD apptainer build --fakeroot agentbox.sif agentbox.def
chmod -R u+w "$BUILD"; rm -rf "$BUILD"               # frees the memory again
```

The finished image is written to `$AB`. The `APPTAINER_TMPDIR` on DUST from section 1.1 is still right for running the box.

If `/dev/shm` is too small or `noexec`, use any other local directory with the space. You can also run the build in an interactive job, if the worker node can reach the internet. If `--fakeroot` is not allowed for you, build the same file on any Linux machine with Apptainer, then copy `agentbox.sif` into `$AB`.

### 1.4 The key proxy

First download Caddy, a single static binary, and check it against the release's checksums. Then copy its config, `Caddyfile`.

The config contains no secrets:

- `{env.…}` is filled in at request time from Caddy's own environment.
- `persist_config off` stops Caddy saving its running config to disk.
- `admin off` matters on a shared login node. Without it, Caddy's admin API listens on localhost, where any user could reconfigure the proxy.

```bash
VER=2.11.7        # or newer: https://github.com/caddyserver/caddy/releases
URL=https://github.com/caddyserver/caddy/releases/download/v$VER
cd $AB/bin && curl -fsSLO "$URL/caddy_${VER}_linux_amd64.tar.gz"
curl -fsSL "$URL/caddy_${VER}_checksums.txt" | grep "_linux_amd64.tar.gz$" | sha512sum -c - \
  && tar -xzf "caddy_${VER}_linux_amd64.tar.gz" caddy && rm "caddy_${VER}_linux_amd64.tar.gz"

install -m 644 $SRC/Caddyfile $AB/Caddyfile
```

### 1.5 Goose configuration

There are two custom providers, one for each API. Both point Goose at the proxy, through a bridge on port 8080 inside the box. Their keys are placeholders, because the proxy swaps in the real ones.

```bash
G=$AB/home/.config/goose
install -m 644 $SRC/goose/config.yaml $G/config.yaml
install -m 644 $SRC/goose/custom_providers/custom_desy.json \
               $SRC/goose/custom_providers/custom_blablador.json $G/custom_providers/
```

`config.yaml` sets `GOOSE_MODE: smart_approve` and enables Goose's built-in `developer` extension. The provider files name each API's models and their `context_limit`.

**Other model settings.** The box doesn't inherit your shell's environment, so `export GOOSE_...` on the host has no effect inside it. Goose reads the same names from `config.yaml`, so add them to your copy, for example:

```yaml
GOOSE_TEMPERATURE: 1.0
GOOSE_MAX_TOKENS: 32768
```

Choose the model per session with the launcher's `--model` option (section 2). A `GOOSE_MODEL` line in `config.yaml` would be ignored, because the launcher sets it as an environment variable, and those take precedence.

Each model's context window is its `context_limit` in the provider file. `GOOSE_CONTEXT_LIMIT` in `config.yaml` would override it for every model. Goose compacts the conversation when it reaches 80% of the limit, without counting the reply, and many servers refuse a request whose prompt plus `GOOSE_MAX_TOKENS` exceeds their window. So set `context_limit` to about the server's window minus `GOOSE_MAX_TOKENS`.


### 1.6 The start script and the launcher

```bash
install -m 755 $SRC/start $SRC/agentbox $AB/
```

`start` runs inside the box. It refuses to launch Goose unless the box is sealed: only a loopback interface, no Kerberos, SSH, X.509, Slurm or API-key variables, no munge socket or `~/.ssh`, and the proxy socket and Goose config present. It then bridges the proxy socket to port 8080 on the box's loopback (and the net proxy to port 3128, with `--net-allow`) and starts `goose session` in `/work`.

`agentbox` runs on the host. It does three things:

1. Decrypts only the keys the session needs, into Caddy and nothing else.
2. Starts the proxy, and the net proxy too if you pass `--net-allow` (section 5).
3. Starts the box with only the mounts listed in the script.

What the main box flags in `agentbox` do:

- `--containall` gives the box a private `/tmp`, a clean environment and its own process list, so it cannot see the proxy process or the keys it holds. `--home` makes `$AB/home`, not your real home, its home directory.
- `--no-mount hostfs,cwd,bind-paths` drops the mounts Apptainer or the site would add by default.
- `--net --network none` leaves the box with only a loopback interface.
- `keyctl session -` gives the box an empty session keyring, so Kerberos and AFS tokens kept there stay outside.


## 2. Run a session

```bash
module load maxwell apptainer
mkdir -p $AB/ws/pi-demo && cd $AB/ws/pi-demo && git init -q
$AB/agentbox $AB/ws/pi-demo --api blablador        # or: --api desy
```

You are asked for the passphrase of each key the session needs, then Goose starts inside the box.

- `--api desy` uses DESY's `coding` model.
- `--api blablador` uses Blablador's `alias-code`.
- `--model` picks another model from the same API, for example `--api desy --model reasoning`. To give it a context window, list it in that API's provider file (section 1.5).

**Where to run it.** Use a login or display node, or an interactive allocation, for example `srun --partition=<partition> --time=02:00:00 --pty bash`. The proxy runs on the same node, so that node must reach the APIs. The DESY Assistant is only reachable from the DESY network, and Blablador needs outbound internet.

**Sharing storage.** Nothing outside the workspace is visible unless you add it, for that session only:

- `--ro /data/dust/group/<group>/dataset` mounts it read-only.
- `--rw /data/dust/group/<group>/agent-drop` mounts it writable.

Inside a writable folder, Goose can do anything you can, including delete, so point `--rw` at a dedicated folder.

**Check the seal once.** Start a shell in the box instead of Goose:

```bash
$AB/agentbox $AB/ws/pi-demo --shell
curl -m 5 https://example.com                           # fails: no network
ls ~/.ssh /afs /data                                    # not there
curl -s http://127.0.0.1:8080/blablador/v1/models | head -c 400   # works, via the proxy
```

The last command also lists Blablador's models and their context lengths. Use them to update `context_limit` in section 1.5.

DESY's model list doesn't include context lengths. In a shell started with `--api desy --shell`, ask for an impossibly long reply. The server will often state its limit in the error:

```bash
curl -s http://127.0.0.1:8080/desy/api/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"reasoning","max_tokens":10000000,"messages":[{"role":"user","content":"hi"}]}'
```

## 3. Sample task: run code, summarise the output in LaTeX

In the Goose session, paste:

> Write `mc_pi.py`, which estimates π by Monte Carlo for N = 10^3, 10^4, 10^5 and 10^6 with a fixed seed, using only the Python standard library. Run it and save N, the estimate, the absolute error and 1/sqrt(N) to `results.csv`. Then write `summary.tex`, a one-page LaTeX article with a table of the results and two sentences on how the error scales with N, using only standard packages. Compile it with `pdflatex` and fix any errors until `summary.pdf` builds.

Goose writes the script, runs it, reads the CSV, then writes and compiles the LaTeX, all inside the box. With `GOOSE_MODE: smart_approve` it asks before risky steps. Press Ctrl-D to leave.

Now we want to use git to review the new code on the host, but we need to be careful because git hooks can do arbitrary code execution.
A local clone doesn't copy the hooks, so on the host we can do;

```bash
git clone file://$AB/ws/pi-demo $AB/ws/pi-demo-review
cd $AB/ws/pi-demo-review  # git hooks didn't get copied here
git status && cat -v results.csv
less summary.tex      # then open summary.pdf
```

When reading content from the box `cat -v` is a little safer, because it converts non-printable characters to printable ones, which prevents terminal escapes.

If `/cvmfs` is mounted on your node, you can instead ask Goose to `source /cvmfs/sw.hsf.org/key4hep/setup.sh` and do the same with ROOT. It runs in the same box.


## 4. Internet access for pip and GitHub (optional)

By default the box has no network at all. With `--net-allow`, it can also make HTTPS connections to host names you list, and nothing else. The box still gets no network interface. A second small proxy outside the box, `netproxy.py`, makes the connections for it, and:

- accepts only HTTPS (`CONNECT` to port 443) to the listed names, checked before any DNS lookup;
- looks the name up itself, refuses private, loopback, link-local and DESY addresses, and connects to exactly the address it checked;
- logs every request, allowed or refused, with the bytes sent each way, in `$AB/net.log`.

Copy the proxy. It runs on the system Python and needs no extra packages:

```bash
install -m 644 $SRC/netproxy.py $AB/netproxy.py
```

Choose what to allow for each session. `pypi` and `github` stand for the host names those services use (the `GROUPS` table in `netproxy.py`), and you can add other host names:

```bash
$AB/agentbox $AB/ws/pi-demo --net-allow pypi,github
$AB/agentbox $AB/ws/pi-demo --net-allow pypi,download.pytorch.org
```

Inside the box, pip, git and curl use the proxy automatically. git works over HTTPS only, not SSH. Ask Goose to install packages into a virtual environment in the workspace, for example `python3 -m venv .venv && .venv/bin/pip install numpy`, so that nothing builds up in the box's home.

**Check it once.** Start a shell in the box:

```bash
$AB/agentbox $AB/ws/pi-demo --net-allow pypi --shell
curl -sSI https://pypi.org/simple/ | head -1          # works
curl -sSI https://example.com                         # fails: not on the list
curl -sSI --noproxy '*' https://pypi.org/simple/      # fails: no way around the proxy
```

Then run `cat -v $AB/net.log` on the host to see what was allowed and refused. When pip can't find a package or git can't reach a repository, a `DENY` line there names the host you would need to add.

DESY's own services, such as gitlab.desy.de, are refused even if you list them, because they have DESY addresses. The DESY ranges in `BLOCKED` in `netproxy.py` come from the RIPE database; add any other internal ranges DESY IT lists to your copy. The proxy connects directly, so use it on a node with outbound internet, such as a login node.

**What internet access still allows,** even with a short list:

- **Data can leave.** Goose can upload anything the box can see to a listed host that accepts uploads. GitHub does, given any token, and a malicious web page or README can supply one. Large `up=` counts in `net.log` are worth a look.
- **Packages run code.** `pip install` runs each package's build and install code inside the box, and look-alike package names are common. Pin versions and check what Goose installed.
- **Fetched text can steer Goose.** READMEs, issues and package descriptions can contain instructions aimed at the model.
- **The traffic is yours.** It leaves DESY under your account. Check what Maxwell and DESY IT allow, and watch your DUST quota.

If you know the packages in advance, there are safer options. You can install them into the image in `%post` of your copy of `agentbox.def` (section 1.3). Or you can download wheels on the host with `pip download --only-binary=:all: -r requirements.txt -d wheels/`, then install them in the box with `pip install --no-index --find-links wheels/`. `--only-binary` matters, because downloading a source package can run its build code on the host. Batch jobs (section 4) never get internet access.

## 6. Notes

- **Where the keys are.** They exist only in `~/.secrets/*.gpg` (encrypted), and in Caddy's memory while a session runs.
  - Never `export` a key in your shell: `sbatch` copies your environment into the job record.
  - Don't run `goose configure` for these providers. On a headless machine Goose stores keys in a plain-text `secrets.yaml`.
- **Updating the files.** `cd $AB/agent_setup_and_secrets && git pull`, then compare with your copies, for example `diff $SRC/agentbox $AB/agentbox`, before copying again. Keep your own edits (`context_limit`, partition, extra `BLOCKED` ranges) when you do.
- **Tool calling.** Goose needs a model that supports OpenAI-style tool calls. If it only chats and never runs anything, try another model.
- **Blablador models.** The `alias-*` names stay the same but point at newer models over time. The token expires after at most a year.
- **Troubleshooting.** The proxy log is `$AB/proxy.log`. A request that hangs usually means the node can't reach that API. If a `/cvmfs` repository looks empty in the box, run `ls /cvmfs/sw.hsf.org` on the host first so autofs mounts it. With `--net-allow`, `$AB/net.log` names the rule behind each refusal.
- **Goose's own settings.** Goose can edit its own config in `$AB/home`, but that only affects the box.

## References

- [Goose installation](https://goose-docs.ai/docs/getting-started/installation), [configuration](https://goose-docs.ai/docs/guides/config-files) and [CI install options](https://block.github.io/goose/docs/tutorials/cicd)
- [Blablador Python client (token and alias notes)](https://pypi.org/project/blablador/)
- [Maxwell: running containers](https://wiki.desy.de/maxwell/documentation/container/)
- [Apptainer: networking](https://apptainer.org/docs/user/1.0/networking.html) and [bind paths](https://apptainer.org/docs/user/latest/bind_paths_and_mounts.html)
- [RIPEstat: DESY's network, AS1754](https://stat.ripe.net/AS1754), the source of the DESY ranges in `netproxy.py`
