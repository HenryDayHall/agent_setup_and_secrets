# Setup and Secrets

This repository is aimed at getting DESY users started quickly on using an LLM,
either as a coding assistant, or as a more autonomous agent.
It contains;

- Instructions for getting your API keys for;
    * DESY assistant
    * Blablador
- Simple scripts for securely handling those api keys without writing them into any plain text files.
- Setup instructions for;
    * aider (very safe coding assistant)
    * goose (more autonomous local harness), including the instructions needed to sandbox this securely.
- A quick description of the models provided by DESY and Blablador, and some starting recommendations.

## Start with secret storage

No matter how you are going to use the api, you need keys.
Start on the computer (or cluster computer) you intend to work on,
and follow these steps to store your keys securely.
Lots of setup instructions tell you to paste your api keys into a text file somewhere, which is as convenient and secure as keeping your credit card pin on a bit of paper in your wallet.
Don't do it.

Using `gpg` to store and retrieve secrets is very portable, safe, and easy.
Inside this repository is a script called `secret.sh`, it's a wrapper for using `gpg` to store your api keys (but would work equally well on anything password adjacent).

1. Use it to store your key; `./secret.sh set <name>`
2. Check you can retrieve it with `./secret.sh get <name>`

The secret names `desy`, `blablador` and `claude` are the ones the scripts look for.

You can see the file you created at `~/.secrets/<name>.gpg` -- that's your encrypted api key.

> Aside, if you have your own solution for storing secrets at the cli,
> this can be easily implemented by altering the `_da_get_secret()` and `_da_has_secret()` functions in `bash_function.sh`.

Now go pick up at least one api key (using one of the sections below) and store it.

### DESY Assistant

The official instructions for this are here; [it.desy.de/services/desy_assistant](https://it.desy.de/services/desy_assistant/index_eng.html);
search this page for "i would like to use desy assistant as a model provider in a local ai chat tool." and expand the corresponding section.

Just for completeness, as of today's date the process is;

1. be in the desy internal network, or connected via vpn.
2. go to [assistant.desy.de](assistant.desy.de).
3. open the sidebar (top left) and click the "profile picture" in the bottom left and select "settings" from the drop down menu.
4. when the settings window pops up select the "account" tab on the left.
5. click "show" by the "api keys" option, and generate a new key.

### Blablador

As of the time of writing, the official instructions for this are outdated.
They can be found [here](https://sdlaml.pages.jsc.fz-juelich.de/ai/guides/blablador_api_access/), 
and have hopefully been updated by the time you read this.

Just for completeness, as of today's date the process is;

1. Go to [https://codebase.helmholtz.cloud/-/user_settings/personal_access_tokens](https://codebase.helmholtz.cloud/-/user_settings/personal_access_tokens) and log in if asked.
2. In the "Personal access tokens" title bar, click the "Generate token" drop-down, and select "Legacy token".
3. Give the token a name, and the "read_user" scope.
4. When shown the api key, encode it in a secret immediately as described above; this can't be seen a second time.

### Other commercial provider

Lots of commercial providers offer api keys, which you could fetch and add in a similar way.
Everything else in this repository would also work for them.
Watch the bill though; apis tend to be expensive.


## Now chose your path

What do you want to do;

- If you are not sure, or just looking for a coding assistant then pick *aider*. Go to [AIDER_SETUP.md](./AIDER_SETUP.md) and follow the instructions there. This is the fastest and safest option.
- If you want a more autonomous agent on your computer, that takes some instructions and will run commands and process data, then you should try *goose*. This has the potential to do a lot of damage, so sandboxing instructions are included in [GOOSE_SETUP.md](./GOOSE_SETUP.md). Check the passage below on safety.


## General safety advice

For the sake of proper compliance, members of DESY should make sure to do the AI safety training. 

As researchers, we are fairly accustomed to trying code we find on StackExchange without worrying that it will sabotage us.
After all, this code has been seen by many people, and would likely get flagged if there were some kind of problem.
We know that open source packages occasionally turn out to have malicious content, but normally popular packages are safe.
Anything that popular will have had plenty of people testing it and reporting issues.
Besides, these popular destinations are also normally the most efficient solutions.
There is little incentive to go anywhere else.

In the same way that AI removes the restraints of prefabricated solutions, it also destroys their safety guarantees. 
A malicious actor can create a site full of useful content for the AI to train on, and hide inside it just one or to lines that would cause a data leak or give them control of a unsuspecting users computer.
This could be very well hidden; for example, a subtly misspelt package name in a tutorial downloads a spoof of a program that does exactly what the real version does, plus a few hard to detect extras.
The AI learns to do this, and does it on your machine.
It's not just a possibility, it's a well documented phenomenon.
Code written for you by an AI has never been seen by anyone but you, so you are the only one checking it.
Anyone using AI for long enough will create some code that aims to compromise their machine. 

You have two defences;

1. Agents executing their own commands need to be sandboxed such that nothing they do would be too destructive.
2. Sooner or later, you are likely to want to run something outside the sandbox, or share it with someone else -- now you must read it, understand it, and decide if it can be trusted.

The bottom line, is that agents are relatively likely to try something malicious given enough time, and when you start an agent, you are completely responsible for everything it does.
You need to proactively control everything you run, and vet everything you set loose.
