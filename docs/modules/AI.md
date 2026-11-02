# AI

The AI module sends text to an AI service when you ask it to, with your own API key. It adds two quick actions, Proofread and Summarize, to `>`, and two commands, `$ask` and `$img`, to `$`. The Knowledge module's `$note`, `$todo` and `$tidy` send through the same service. The module also keeps a count of what you used and a rough cost. OpenAI is the only service so far; others are added as described in [ADDING_AI_PROVIDER.md](../ADDING_AI_PROVIDER.md). Nothing is sent in the background, and nothing is sent until you press ⏎ on one of these.

The module is **off by default**. Switch it on in Settings → AI and paste an [OpenAI API key](https://platform.openai.com/api-keys). It needs the Quick Actions module on, and the Commands module for `$ask` and `$img`.

## Using it

| | Where | Sends | Pastes |
| --- | --- | --- | --- |
| Proofread | `>` | The text, with instructions to fix spelling, grammar and punctuation and change nothing else (language, meaning, tone, line breaks, Markdown), and not to follow instructions in the text. | The corrected text. |
| Summarize | `>` | The text, with instructions to summarize it in its own language: a few sentences, or short bullet points for a long text. | The summary. |
| `$ask why is the sky blue` | `$` | What you type, as the whole prompt. Nothing is added. | The answer. |
| `$img a cat on the moon` | `$` | What you type, as the picture's description. | The picture (PNG). |

Proofread and Summarize work like every `>` action ([ACTIONS.md](ACTIONS.md)): on the clipboard, a clip (⌘K), text from the Services menu, the selection hotkey (⌃⌥⌘S by default; ⏎ replaces the selection) and in Shortcuts ("Transform Text with Cortex"). `$ask` and `$img` work like every `$` command ([COMMANDS.md](COMMANDS.md)) and run only on what you type. To ask about what you copied, type `$ask`, ⏎, ↓ (the clipboard is the form's suggestion) and then edit it or press ⏎. The `$img` form also has a Model option: the image model set in Settings (the default) or another of the service's image models, remembered for next time. `$ask` and `$img` take several lines in their form; ⇧⏎ breaks a line.

Nothing is sent until ⏎. These actions are not previewed; the pane says what they will do instead: "Sends the text to OpenAI (gpt-6-luna) and pastes the corrected text." They run as background jobs: after a second the progress card shows, and a result that takes more than 5 seconds is put on the clipboard with a notification instead of being pasted (pictures usually take that long). Text and picture results become clips in the history.

Errors are notifications and say what to do: "No OpenAI API key yet: add one in Cortex Settings → AI", "OpenAI rejected the API key. Check it in Settings → AI.", the service's own message for an unknown model or a reached quota, or "Could not reach OpenAI: …".

## Settings

Settings → AI has the Enabled switch (off by default; the switch is off and says why while Quick Actions is off) and:

| Option | Default | Meaning |
| --- | --- | --- |
| Service | OpenAI | Which service the actions use. Each service has its own key and models. |
| API key | none | Paste it and press *Save*; the field then says "Saved". *Remove* deletes it. Kept in the Keychain. |
| Text model | empty (`gpt-6-luna`) | For Proofread, Summarize, `$ask`, and the knowledge base's `$note`, `$todo` and `$tidy`. Empty means the service's default. |
| Image model | empty (`gpt-image-2.5-flare`) | For `$img`. Empty means the default. |

Below the options is the usage section, "Usage since <date>": the estimated cost, the number of requests, and one row per model with its cost and its requests, input tokens and output tokens. *Reset* asks first, then starts counting from zero; it changes nothing at the service. The cost is estimated from the service's list prices as of October 2026 (`AIPricing.asOf`); the vendor's bill is what counts. Requests to a model without a known price (for example `gpt-image-2`) are counted in tokens only, and the footer says so.

There is no palette trigger and no hotkey.

## Data and privacy

| What | Where |
| --- | --- |
| API key | The login Keychain, service `dev.jonaszell.cortex`, account `ai.openai-api-key` (`ai.<service>-api-key`). Readable only while the Mac is unlocked, not synchronised through iCloud, and not part of Cortex sync. Cortex reads it for each request and does not keep it. |
| Chosen service | UserDefaults key `ai.vendor`. |
| Models | UserDefaults keys `ai.openai.textModel` and `ai.openai.imageModel` (`ai.<service>.textModel` and `.imageModel`), one pair per service, so one service's model name is never sent to another. |
| Usage totals | UserDefaults key `ai.usage` (JSON: the start date and, per service and model, requests, tokens, estimated cost). |
| The module switch | UserDefaults key `module.ai.enabled`. |

Nothing here syncs. Prompts and answers are not stored by the module; a pasted answer or picture is a clip like any other result (see [CLIPBOARD.md](CLIPBOARD.md)). Switching the module off removes the actions and commands and keeps the key, the settings and the totals. The log gets the model and token counts of each request, not the text.

### What is sent, and when

Requests go over HTTPS to `api.openai.com`, with the key in the `Authorization` header, and only when you run one of these:

| Run | Request | Body |
| --- | --- | --- |
| Proofread, Summarize | `POST /v1/responses` | `model`, `input` (the text), `instructions` (the fixed instructions above) and `store: false`. |
| `$ask` | `POST /v1/responses` | `model`, `input` (your prompt) and `store: false`. No instructions. |
| `$img` | `POST /v1/images/generations` | `model`, `prompt`, `n: 1`, `output_format: "png"`. This request has no `store` field. |
| `$note`, `$todo` | `POST /v1/responses` with a JSON schema | The text you typed, with instructions that contain the filing rules, your project ids, names and summaries, and your tag names. |
| `$tidy` | `POST /v1/responses` with a JSON schema | For each inbox item: its path, kind, title, tags, the paths and titles of notes it could be merged into, and the first 400 characters of its body; also the filing rules, projects and tags. Items that look like a password or key are left out. |

The service answers with text, JSON or a base64 picture. Requests time out after 300 seconds, since a picture can take over a minute. The knowledge base's requests are described in [KNOWLEDGE.md](KNOWLEDGE.md).

### Sensitive content

- **Sensitive clips are never sent.** A clip or pasteboard marked sensitive (a password manager's copy, or text that looks like a token) is input that `>` does not list Proofread and Summarize for, and `ActionsService.run` refuses it whatever the way in: nothing is sent, and a notification says "The input is marked sensitive, so it is not sent anywhere."
- **The `$` forms never suggest it.** The clipboard suggestion in the `$ask`, `$img`, `$note` and `$todo` forms is left out when the pasteboard is sensitive, and the recent-clip lookups leave sensitive clips out.
- **Typed text is sent as typed.** What you type after `$ask` or `$img` is never marked sensitive, so Cortex does not check it. `$note` and `$todo` refuse typed text that looks like a password or key ("It looks like a password or key, so it is not sent to OpenAI. Save it with ? instead."), and `$tidy` leaves such inbox items out.
- **Shortcuts.** Text passed in by a shortcut is not a clip and has no sensitive mark, so it is sent.
- **OpenAI's side.** The text requests ask OpenAI not to store the response (`store: false`). The image request has no such parameter. What the service does with requests is covered by its own terms.

## How it works

Everything that does not need the app is in `CortexCore/Sources/CortexCore/AI/`; the module is in `Cortex/Modules/AI/`.

| File | Role |
| --- | --- |
| `AI/AIVendor.swift` | `AIVendorID` (the services; the raw value is stored), `AIRequest` (`.text`, `.image`, `.json`), `AIResponse`, `AIUsage`, the `AIVendor` protocol, `HTTPClient` (so tests answer without a network). |
| `AI/OpenAIVendor.swift` | OpenAI: the Responses API for text and JSON, the Images API for pictures, usage and error mapping. |
| `AI/AIPricing.swift` | List prices per million tokens (input, cached input, output) and `AIUsageTotals`. A dated snapshot of a model (`gpt-image-2.5-flare-2026-09-08`) finds its model's price. |
| `AI/AIAction.swift` | `AIAction`: Proofread and Summarize, with their instructions. A `QuickAction` that is `isRemote`. |
| `AI/AICommand.swift` | `AICommand`: `$ask` and `$img`. A `Command` that is `isRemote`, with a `prompt` argument that suggests the clipboard text, and `$img`'s Model option. It resolves to a job: the pane shows the plan, nothing is sent while the command is merely selected, and the request goes out when the job runs on ⏎. |
| `Modules/AI/AIModule.swift` | The `CortexModule`: id `ai`, no trigger, off by default, requires `actions`, order 35. Implements `ActionContributing`, `CommandContributing` and `AIAPI`. Builds the Settings options. |
| `Modules/AI/AIService.swift` | Reads the key from the Keychain for each request, sends through the chosen `AIVendor`, records the usage and saves it. |
| `Modules/AI/AISettings.swift` | The chosen service and the models, stored per service. |
| `Modules/AI/AISettingsView.swift` | The usage section. |
| `Modules/AI/AIAPI.swift` | What other modules use: `vendor`, `textModel` and `send`. Knowledge's `$note`, `$todo` and `$tidy` send through it, so they use the same key and are counted in the same totals. It exists only while AI is on. |

Both the actions and the commands are rebuilt on every listing with the service and models as they are set now, so changing a model takes effect at once. All three kinds of request go through `AIService.send`, which adds the key and counts the usage. `AIModule` names no module: Quick Actions asks `ActionContributing` and Commands asks `CommandContributing` on every listing (see [ARCHITECTURE.md](../ARCHITECTURE.md)). The IDs `ai.proofread`, `ai.summarize`, `ai.ask` and `ai.image` are stored in usage counts and must not change.

**Adding a service** is a case in `AIVendorID`, a type that conforms to `AIVendor`, and prices in `AIPricing`; the app needs no change, because Settings lists every `AIVendorID` in its Service picker. [ADDING_AI_PROVIDER.md](../ADDING_AI_PROVIDER.md) has the steps.

## Tests

- `CortexCore/Tests/CortexCoreTests/AI/AITests.swift`: `OpenAIVendorTests` (text goes to the Responses API, JSON answers with a strict schema, `$ask` sends no instructions, images go to the Images API, error messages, an answer without text), `AIPricingTests` (`defaultModelsHavePrices` for every service, cached input, dated snapshots, totals by model), `AIActionTests` (stable IDs, remote actions are never instant and take only text, the plan names the service and model, the instructions) and `AICommandTests` (names and IDs, the prompt is typed and only suggested from the clipboard, the Model option, resolving gives a job and sends nothing, `$ask` sends the prompt as it is, the picture comes back).
- `CortexTests/Modules/AI/AIServiceTests.swift`: nothing is sent without a key, runs count their usage and keep it, models default to the service's and are kept per service, sensitive input is not offered and never sent. `ModuleLifecycleTests` checks that the actions and commands follow the module's switch.
- Manual: [MANUAL_TESTS.md](../MANUAL_TESTS.md) M24 (a real key: Proofread, the selection hotkey, `$ask`, `$img`, the usage numbers, sensitive input, a missing or wrong key, switching AI off) and M31 (filing with AI).
