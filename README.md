# voxtype-llm-wrapper

[Ollama](https://ollama.com) models that clean up dictated text for
[voxtype](https://github.com/peteonrails/voxtype), fully local. The goal of the
project is to find the best-performing cleanup LLM at each level of memory and
latency.

The model reads a raw transcript on stdin and prints an edited version:
punctuation and capitalization fixed, fillers and false starts removed,
self-corrections resolved ("Tuesday, no wait, Wednesday" → "Wednesday"), and
emails, messages, and lists formatted. Questions and requests are edited, not
answered.

## Profiles

Every profile uses the same system prompt and examples on a different base
model. All base models are licensed for commercial use.

| Profile | Base model | Download | Loaded in memory | Warm latency | Pass / fail (of 57) |
| --- | --- | --- | --- | --- | --- |
| `max` | Qwen3.5-4B, text-only GGUF | 2.7 GB | 4.9 GB | 0.68 s | 50 / 2 |
| `standard` | Qwen3.5-2B, text-only GGUF | 1.3 GB | 2.4 GB | 0.45 s | 45 / 9 |
| `fast` | `granite3.3:2b` | 1.5 GB | 2.1 GB | 0.19 s | 41 / 13 |

- **Loaded in memory** is `ollama ps` at the default 4096-token context.
- **Warm latency** is one `ollama run` request with the model already loaded.
  Qwen3.5 can't use Ollama's prompt cache, so it re-evaluates the prompt on
  every request; that, more than size, is why `fast` is faster.
- **Pass / fail** is `./test.sh` on `test-cases.tsv`; the remainder are near
  misses on punctuation or quote style.

Known failures: all profiles miss "three no four o'clock" and return "Um" for a
lone "um". `standard` also leaves most self-corrections unresolved and
sometimes answers requests. `fast` also flips pronouns on questions aimed at
the model ("who are you" → "Who am I?") and answers a few.

The Qwen profiles use Unsloth's text-only GGUFs because Ollama's `qwen3.5`
builds include a vision tower that costs 1.3–2 GB of extra memory. The
profiles supply Qwen's chat template with thinking disabled.

### Rejected models

| Model | Reason |
| --- | --- |
| `qwen2.5:7b` | Same memory as `max`, 6 failures; acts on requests |
| `qwen2.5:3b` | License forbids commercial use |
| `qwen3:0.6b`, `qwen3:1.7b` | Barely edit: missing punctuation, no formatting |
| `granite4:micro`, `qwen3:4b-instruct` | Slower than `fast`, worse than `standard` |
| `gemma3:1b`, `granite3.1-moe` 1b/3b, Qwen3.5-0.8B | Mostly garbage output |
| `qwen3.5:9b` | Same score as `max`, 8.9 GB |
| `granite3.3:8b` | Echoes example turns |
| `gemma3:4b` | Curly-quotes everything; license adds redistribution terms |
| `llama3.2:3b`, `qwen2.5:1.5b` | Answer questions instead of editing |
| `qwen3:4b` | Reasons out loud with thinking disabled |

## Setup

Requires Ollama (running) and voxtype 1.0+.

```sh
git clone https://github.com/xuancongwen/voxtype-llm-wrapper
cd voxtype-llm-wrapper
./setup.sh                      # default profile: max (standard on macOS)
./setup.sh --profile fast       # or pick one
./setup.sh --model-only         # build the model, skip voxtype config
./setup.sh gemma3:4b            # try another base model for this run only
```

The script downloads the base model, builds it as `voxtype-llm-wrapper`, runs a
smoke test, adds an `[output.post_process]` block to
`~/.config/voxtype/config.toml` (backing it up first, never overwriting an
existing block), and restarts the `voxtype` user service. Re-run with another
profile to switch; the config doesn't change.

Test it directly:

```sh
echo "um so let's meet tuesday no wait wednesday at four" | ollama run --nowordwrap voxtype-llm-wrapper
# So, let's meet Wednesday at four.
```

### Manual voxtype config

```toml
[output.post_process]
command = "ollama run --nowordwrap voxtype-llm-wrapper"
timeout_ms = 30000
trim = true
fallback_on_empty = true
```

On timeout or error voxtype types the raw transcript. Set
`OLLAMA_KEEP_ALIVE=24h` on the Ollama server to avoid a multi-second reload
after it goes idle.

## Changing behaviour

- `system_prompt.txt`: editing rules, becomes the `SYSTEM` block.
- `examples.tsv`: dictation/output pairs, rendered as `MESSAGE` turns. This is
  the most effective lever; add a pair showing the edit you want, plus a
  different hold-out case in `test-cases.tsv`.
- `profiles/<name>`: base model, parameters, and for GGUFs the chat template,
  URL, and sha256.
- `gen-modelfiles.sh` renders these into the committed `Modelfile.<name>`
  files. Don't edit those by hand; `setup.sh` regenerates them.

Run `./test.sh [MODEL]` after any change.

## Troubleshooting

- **Text typed unchanged**: the command failed or timed out. Run the `echo`
  test above and check `voxtype -v daemon`.
- **Model answers instead of editing**: use `max`, or add an example pair.
- **Seconds of delay**: the model is reloading; set `OLLAMA_KEEP_ALIVE`.
- **Reasoning or `<think>` in output**: a Qwen GGUF was built without its
  template. Rebuild from `Modelfile.<profile>`.
