# Aider

This is the easiest default choice, and the one to use if you primarily want a coding assistant.
Being only able to see files in your repo, and files you explicit tell it about, it has a degree of inherent safety.
Two points the user still needs to consider;

1. The agent can still write malicious code and tell you to execute it. Check code before you run it.
2. If you accidentally put something secret in the repository that the agent it in, it could leak.

## Install aider

First you need aider itself. 
Generic download instructions are on the website [aider.chat](https://aider.chat).
The simplest route is `aider-install`;

```bash
python -m pip install --user aider-install
aider-install
```

`aider-install` puts aider in its own isolated environment (it uses `uv` for this), and puts the `aider` command in `~/.local/bin`,
so there is no need to create or activate a conda environment for it.
If `aider --version` doesn't work afterwards, make sure `~/.local/bin` is on your `PATH`.

I also recommend you adopt the conf files given in this repository.
To allow aider to find them automatically go to your home directory and link them from there;

```bash
PATH_TO_REPO=`pwd`
cd ~
ln -s ${PATH_TO_REPO}/aider/confs/.aider.conf.yml
ln -s ${PATH_TO_REPO}/aider/confs/.aider.model.metadata.json
ln -s ${PATH_TO_REPO}/aider/confs/.aider.model.settings.yml
cd -
```

This will set some sane defaults (including DESY's `reasoning`, `coding` and `desy-assistant` as the default models),
and give aider a bit of information about desy (and blablador) models.
Additionally, it tells aider not to auto-commit, as I don't like lots of micro commits, although it does remove the automatic roll back options.
`.aider.conf.yml` lists every option aider has, most of them commented out, so it's also a handy reference.
Some of this information I have estimated, because it's not all published.
Note that the costs of desy models are not "real", they are my estimate of what that service might be costing desy to provide, you aren't actually going to get a bill.

Now that all this is done, you could give aider a quick try with the desy service;

```bash
OPENAI_API_KEY=$(./secret.sh get desy) \
OPENAI_API_BASE=https://assistant.desy.de/api/ \
aider --model openai/reasoning
```

Note the key is handed over as an environment variable rather than with aider's `--openai-api-key` flag.
Anything on a program's command line can be read by every other user on the machine (try `ps -ef`), which matters on a shared login node like maxwell's.
Environment variables can only be read by your own processes.

It that worked you should see something like;
```
─────────────────────────────────────────────────────────────────────────────────────────────────────────
exist. Skipping.
Aider v0.86.3.dev+import
Model: openai/reasoning with whole edit format
Git repo: .git with 16 files
Repo-map: using 4096 tokens, auto refresh
─────────────────────────────────────────────────────────────────────────────────────────────────────────
>
```

Press control-c twice to exit.

### Add the `aider` function to `.bashrc`

In this repository is a script called `bash_function.sh`. Sourcing it gives you a shell function called `aider`,
which takes exactly the same flags as aider itself, so aider's own documentation applies as-is. Behind the scenes it;

- unlocks the api keys for whichever services your models come from, and passes them to aider as environment variables;
- points each service at its own api endpoint, so DESY, blablador and claude models can be mixed in one session;
- lets you use short model names (`reasoning`, `huge`, `claude-opus-4-8`...), on the command line and with `/model` inside aider;
- picks repo map and chat history sizes suited to the main model's service;
- checks, at most once a day, whether the services have added or removed models;
- adds tab completion for all of aider's flags, including model names after `--model`, `--editor-model` and `--weak-model`.

You can give it a try now;

```bash
source aider/bash_function.sh
aider  # asks for your secret's password, then starts aider with the DESY models
```

Hopefully that just started? If so, your setup is working; press control-c twice to exit.
You can keep doing `source bash_function.sh`, or you can add that line to your `~/.bashrc` so that it happens automatically in every shell you start.

If you ever want plain aider, without any of this, use `command aider`.

## Basic usage

First of all, remember you need to be in the internal network or have the DESY vpn active to access the DESY assistant api.
If you don't it will just hang.

Secondly, it's normally a good idea to launch aider in a git repository.
It's designed to look at, and alter, only files in that repository.
If you launch aider and you aren't in a git repository it will suggest you start one, and you might not be where you intended to put the root of your repository.

### cli arguments

I'm going to discuss cli options, assuming you are using the `aider` function from `bash_function.sh`.
A basic start would be just `aider`, but you might want to customise some things.

Firstly, the models can be changed; aider employs 3 different models;

1. Primary model (reasoning, architecture).
2. Editor model (should be good at writing code and files).
3. Weak model (summarising the chat and making the repo map).

By default these are DESY's "reasoning", "coding" and "desy-assistant" models (set in `.aider.conf.yml`), but if you want, there are other options.
You can see them all by doing `list_models` (or e.g. `list_models desy` for one service).
Then to set specific models, use aider's normal flags;
```bash
aider --model <primary> --editor-model <editor> --weak-model <weak>
```
For example; `aider --model reasoning --editor-model coding --weak-model desy-assistant`.
The names of these models autocomplete with tab, and any you leave out come from the config file.
You can also switch the main model inside a session with `/model <name>`.

The repo map and chat history sizes are set according to which service the main model comes from (bigger for claude, smaller for blablador).
To override them, use aider's own flags, e.g. `aider --map-tokens 8192 --max-chat-history-tokens 20000`.

Any other aider flags and file names work as normal.

The list of models is refreshed at most once a day, when you start aider. To refresh straight away, run `refresh_models`.

### Usage modes

Aider's [own docs](https://aider.chat/docs/usage.html) are the best place to look for advice on usage, but here a couple of quick tips to get started.

You can `/ask` aider to tell you things, and it won't change any files;

```bash
aider
─────────────────────────────────────────────────────────────────────────────────────────────────────────
exist. Skipping.
Aider v0.86.3.dev+import
Model: openai/reasoning with whole edit format
Git repo: .git with 16 files
Repo-map: using 4096 tokens, auto refresh
─────────────────────────────────────────────────────────────────────────────────────────────────────────
> /ask Can you see where the data loader is in this repository?
```

If you don't ask, aider may make some file changes if it interprets your question as an instruction.

```bash
aider
...
─────────────────────────────────────────────────────────────────────────────────────────────────────────
> The data loader struggles with larger files, how can we improve this?
```

You can also "invoke" aider from your editor.
First, add the file you want it to work on

```bash
aider
...
─────────────────────────────────────────────────────────────────────────────────────────────────────────
> /add src/data/dataloader.py
```

Then with `src/data/dataloader.py` open in your editor, write a comment (must begin with `#` or `\\`) ending with `AI!`, then save the file.
For example;

```python
import numpy as np

class DataLoader():
    def __init__(self, file_name):
        self.file_name = file_name
        # check the file exists and throw a warning if not AI!
    
    def _open(self):
        self._loaded = np.load(file_name)
```

You should see some chatter in the aider window. Something a bit like;
```bash
Processing your request...
---------------------------------------------------------------------------------------------------------

► THINKING

We need to interpret the AI comment: "check the file exists and throw a warning if not AI!" The comment
is in init. It says to check the file exists and throw a warning if not. The comment also says "AI!" at
the end, but that's likely just a marker. We need to implement the check: use os.path.exists or similar.
If file does not exist, issue a warning (maybe using warnings.warn). Also need to fix _open: it uses
file_name but should be self.file_name. Also need to import os and warnings. Then remove the AI comment.

We'll produce updated dataloader.py.

Also note: The class name is DataLoader, but the file is dataloader.py. That's fine.

We'll add import os, warnings. In init, after setting self.file_name, check if not
os.path.exists(self.file_name): warnings.warn(f"File {self.file_name} does not exist."). Then remove the
comment.

In _open, change file_name to self.file_name.

Return entire file.

Let's write.

---------------------------------------------------------------------------------------------------------

► ANSWER

dataloader.py


 @@ -1,9 +1,12 @@
  import numpy as np
 +import os
 +import warnings

  class DataLoader():
      def __init__(self, file_name):
          self.file_name = file_name
 -        # check the file exists and throw a warning if not AI!
 +        if not os.path.exists(self.file_name):
 +            warnings.warn(f"File {self.file_name} does not exist.")

      def _open(self):
 -        self._loaded = np.load(file_name)
 +        self._loaded = np.load(self.file_name)


Tokens: 2.9k sent, 313 received. Cost: $0.00049 message, $0.00049 session.
Applied edit to dataloader.py
─────────────────────────────────────────────────────────────────────────────────────────────────────────
```

Now reload your file in the editor (if you editor doesn't automatically reload on changes).
You can see that aider has directly written the changes into the file.


## Adding more model apis

The `aider` function knows about three services: DESY, blablador and claude.
Being at DESY, you do have the immediate option to try blablador, and can do so simply by generating an api key and storing it with `./secret.sh set blablador`.
Blablador's models are used by their short names, without the `alias-` prefix, e.g. `aider --model huge --editor-model code --weak-model fast`.

Each service has its own api endpoint, and the `aider` function sets them all up, so models from different services can be mixed freely.
Say you have some claude api tokens. Store the key with `./secret.sh set claude`, and then you can use claude in combination with desy models.
I often do; I find a claude reasoning model, with DESY's coding model works great (and saves api tokens over using 3 claude models).
```
aider --model claude-opus-4-8 --editor-model coding
```

Only the keys for the services you actually use in a session are unlocked.
If they share a password (see above) you are asked for it once; a key with a different password gets a prompt of its own.

Should you have some other subscription, the process is about the same, but you'll need to add the service to `bash_function.sh`
(its url, litellm prefix and api key variable are set near the top of that file).
You might want to add some information to `confs/.aider.model.metadata.json` and `confs/.aider.model.settings.yml`, but you don't have to.

## Running aider from source

If you have a checkout of aider's source code you want to run instead of the installed version (for example, to try out changes to aider itself),
set `AIDER_DEV_REPO` to its path, e.g. `export AIDER_DEV_REPO=~/Assistant/aider_repo`.
The `aider` function will then run that code, using the installed aider's python environment.
