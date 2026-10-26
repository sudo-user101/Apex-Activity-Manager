# AI diagnostics: architecture (future)

Status: **design only**. Nothing here is in the app yet, and no AI controls
are shown until the matching piece is built and secure. Today every doctor
(Drive Doctor first) is deterministic: measured evidence in, rule-based
findings out (`Sources/TaskManager/Diagnostics`).

## Principles

1. **Measurements first.** AI never replaces a reading. It explains,
   correlates and suggests next checks on top of a `DiagnosisReport`.
2. **Labelled sources.** Every sentence an AI writes is tagged as AI-written
   and shown apart from `Evidence` (source `device` / `measured` / `macOS`).
   AI output never changes a finding's severity or confidence by itself.
3. **No actions.** AI may recommend; only the existing `SafeAction`s run, and
   only when the user clicks them. No AI-triggered deletes, kills or settings.
4. **Minimum data.** The prompt holds the report (findings, evidence values,
   model names), never file names, paths, user names or process command lines,
   unless the user previews and allows it per request.
5. **No browsing by assumption.** An API key doesn't mean the model can read
   the web. Online research happens only through a research step Apex runs
   (fetching from an allow-list of sources: Apple Support, vendor
   documentation, NVMe/USB specs) and cites in the answer.

## Shape in code

```
DiagnosisReport ──► DiagnosticExplainer (protocol)
                       ├─ ByokExplainer        (user's key, provider API)
                       ├─ LocalModelExplainer  (Ollama / LM Studio on this Mac)
                       └─ ApexCloudExplainer   (Apex Intelligence backend)
                    ◄── Explanation { text, citations[], provider, model, isAI = true }
```

- `DiagnosticExplainer.explain(_ report: DiagnosisReport, research: Bool) async throws -> Explanation`
- One prompt builder (`ExplainerPrompt`) turns a report into redacted JSON plus
  instructions; every provider gets the same input, so answers are comparable
  and testable with fixtures.
- Answers are cached per report hash; nothing is sent automatically. The user
  presses "Explain with AI" on a finding.

## A. Bring your own key

- Providers: done (2026-10-26). Cloud API takes any provider (Anthropic, Google Gemini, Mistral, OpenAI, OpenRouter, any OpenAI-compatible address) with named, grouped keys; Lumen AI is CyberNet Labs' own service (monthly plan or API access), coming soon until its address exists.
- Key stored in the **macOS Keychain** (`kSecClassGenericPassword`, service
  `com.cybernetlabs.apex.ai`, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`),
  never in UserDefaults, files or logs. Shown masked; "Remove key" deletes it.
- Requests go straight from the Mac to the provider over HTTPS. Apex has no
  server in the path.
- Cost: show the model and an estimate per request; a monthly cap the user sets.

## B. Local model

- Reuse Local AI detection (`System/LocalAI.swift`): Ollama (`:11434`) and LM
  Studio (`:1234`, OpenAI-compatible) already found and queried.
- No internet needed. The UI states the model in use and its memory need; if
  the model would push memory pressure to Critical, warn first (Memory page data).
- Research step is unavailable offline and the UI says so.

## C. Apex Intelligence (subscription)

- Apex-managed backend holds provider keys; **no secrets in the app bundle**.
- Sign in with Apple → short-lived access token in the Keychain; the backend
  checks entitlement (StoreKit 2 receipt or the payment provider) per request.
- Backend applies per-account rate limits, monthly quotas, request size caps,
  abuse detection and spend alerts; logs hold no report content beyond 30 days
  (or none, configurable), documented in a privacy policy.
- Same `Explanation` shape, so the UI doesn't care which option answered.

## Order to build

1. `DiagnosticExplainer` + prompt builder + fixtures (tests, no network).
2. Local model (no secrets, no cost): proves the UI and labelling.
3. BYOK with Keychain.
4. Backend + subscription, only with authentication, quotas and a privacy policy.
