# Adding an AI provider

The AI module ([README](../README.md#ai-actions)) talks to a provider through the `AIVendor` protocol. Nearly all of a provider lives in `CortexCore/Sources/CortexCore/AI/`. The app needs no change: Settings → AI lists every `AIVendorID` in its Service picker, and the API key, models and usage follow the chosen one. OpenAI (`OpenAIVendor.swift`) is the example throughout.

## 1. The ID

Add a case to `AIVendorID` (`AIVendor.swift`) and fill in every `switch` (the compiler lists them):

- the raw value: lowercase, **stable forever**. The choice (`ai.vendor`), the models (`ai.<raw>.textModel`, `ai.<raw>.imageModel`), the Keychain account (`ai.<raw>-api-key`) and the usage entries are stored under it.
- `name` ("Anthropic"): shown in Settings, the palette's pane ("Sends the text to …") and the error messages.
- `defaultTextModel` and `defaultImageModel`: used while the model fields are empty.
- `keysURL`: where a key is created, shown under the key field.
- `makeVendor(apiKey:http:)`: returns your type.

## 2. The vendor

A `struct <Name>Vendor: AIVendor` in `AI/<Name>Vendor.swift`. It gets the key and an `HTTPClient` (always send through it, never `URLSession` directly, so tests can answer), and implements `perform(_:)`:

| Request | Send | Return |
| --- | --- | --- |
| `.text(model:instructions:input:)` | `instructions` as the system prompt (nil for Ask AI: `input` is the whole prompt), `input` as the user's message. Ask the provider not to keep the request, if it can. | `.text` with the answer's text |
| `.image(model:prompt:)` | One picture | `.image` with PNG data |
| `.json(model:instructions:input:schema:)` | Like `.text`, but `instructions` is always set and the answer must fit `schema`, an `AIJSONSchema` (a `name` and a `json` string holding a JSON Schema in the strict subset: every property required, optional ones nullable, no other properties). Use the provider's structured-output mode. The schema is only a string, so throw a `QuickActionError` if it is not valid JSON. | `.text` with the JSON as text |

- **Usage:** fill `AIUsage` from what the provider reports. `inputTokens` counts all input, cached included, and `cachedInputTokens` is the cached part of it. `outputTokens` counts everything billed as output (reasoning tokens, image tokens). Missing counts are 0, not an error.
- **Errors:** throw `QuickActionError`s the user can act on. They appear in the palette and in notifications. Say "<Name> rejected the API key. Check it in Settings → AI." for a bad key, and quote the provider's own message otherwise. Let cancellation through as `CancellationError` (a cancelled job is not a failure).
- **No images?** Throw `QuickActionError("<Name> cannot draw pictures")` for `.image`. Generate Image is still listed for every provider, so the user reads why it fails.
- **`.json`** is used by the knowledge base's filing commands (`$note`, `$todo` and `$tidy`), with the text model. A provider without a structured-output mode should throw `QuickActionError("<Name> cannot answer in JSON")`, so those commands say why they fail.

## 3. Prices

Add the provider's models to `AIPricing.prices`, in US dollars per million tokens (input, cached input, output), and update `asOf` if you looked prices up again. At least the two default models need a price. Dated snapshots (`model-2026-09-08`) find their model's price on their own. Models without a price are counted in tokens only.

## 4. Tests and docs

- `CortexCore/Tests/CortexCoreTests/AI/`: a suite like `OpenAIVendorTests` with `CannedHTTP`. Check the request (URL, headers, body, that instructions are left out for Ask AI), the parsed answer and usage, and the error messages. `AIPricingTests.defaultModelsHavePrices` already checks every `AIVendorID`. Run `make test`.
- README → AI actions: name the provider and its default models.
- [Stored keys and names that must not change](ARCHITECTURE.md#stored-keys-and-names-that-must-not-change): add its keys (`ai.<raw>.textModel`, `ai.<raw>.imageModel`) and Keychain account (`ai.<raw>-api-key`).
- MANUAL_TESTS.md M24: a step that switches the Service to it, saves a key and runs Proofread and Generate Image.
