# MyType

**Connect spoken intent to desktop Agent workflows.**

MyType is a voice-first personal Agent interaction project for macOS. Building on [Type4Me](https://github.com/joewongjc/type4me)'s voice input and text processing, I added desktop Agent session search, task routing, context handoff and a shared Inbox to explore the path from expressing an idea to continuing the work.

[Follow the workflow](#from-a-spoken-request-to-continuing-the-work) · [Explore the implementation](#key-design-decisions) · [Build from source](#build-from-source)

## Why I built it

When work spans several desktop Agents, an idea often still requires finding an old conversation, checking its project, supplying context, handing work over and checking the result. These manual connections separate expressing a request from advancing the task.

I wanted an entry point organized around the work itself: describe an activity or next step, find its working context, prepare a handoff or new task, and return to the right conversation when feedback arrives.

MyType retains everyday voice input while focusing its development on those connections after input.

## From a spoken request to continuing the work

In the dedicated Agent entry point, a spoken request is classified before entering the appropriate workflow:

```text
Spoken request
  ├─ Resume work → Search candidates → Confirm and open the original chat
  ├─ New task → Confirm the project → Prepare a new Agent task
  └─ Handoff → Select source and recipient → Review context and deliver
                                                        ↓
                                    Inbox collects feedback and requests
                                                        ↓
                                      Return to the chat and continue
```

| What the user needs | How MyType connects the steps |
| --- | --- |
| Find earlier work | Search by activity, project or content; retain the application source and locate the original desktop conversation. |
| Start a new task | Recognize an explicit request to create work, confirm its project and prepare the new Agent task. |
| Give another Agent the background | Select the source and recipient, organize visible history and next-step instructions, and deliver through native interfaces. |
| Respond to Agent feedback | Collect completion feedback, waiting states and pending requests in one Inbox, with a route back to the corresponding conversation. |

The current public implementation covers **Codex and Claude** desktop conversations. Those Agents perform the tasks; MyType connects the entry point, work discovery, handoff and feedback.

## Key design decisions

### 1. Determine how the user wants to advance the work

A spoken request may refer to an existing activity, a new task or a transfer of context. I separated these operations so an activity description does not casually become a new task, and a handoff has an explicit source, recipient and confirmation step.

The implementation includes intent classification, activity queries, candidate selection, new-task preparation and a handoff window.

[Intent classification](https://github.com/duroey/MyType/blob/main/Type4Me/Services/AgentIntentClassifier.swift) · [Task routing](https://github.com/duroey/MyType/blob/main/Type4Me/Services/AgentRouterService.swift) · [New-task service](https://github.com/duroey/MyType/blob/main/Type4Me/Services/AgentNewTaskService.swift)

### 2. Connect retrieved content to the correct conversation

A search result needs a working destination. I combined activity matching with native session catalogs: **Qwen3-Embedding** supports semantic matching, AgentsView searches historical content, and results are mapped to Codex / Claude session identities and navigation capabilities.

Candidate matching, original-chat mapping and an open request have separate states. If content is found but its desktop conversation cannot be located, the user receives explicit feedback.

[Session catalog](https://github.com/duroey/MyType/blob/main/Type4Me/Services/AgentSessionCatalog.swift) · [Index service](https://github.com/duroey/MyType/blob/main/Type4Me/Services/AgentIndexService.swift) · [Embedding service](https://github.com/duroey/MyType/blob/main/Type4Me/Services/AgentEmbeddingService.swift)

### 3. Keep handoff and feedback tied to the same task identity

A handoff contains visible history from the selected source, the receiving conversation and the user's next-step instructions. MyType integrates native **Codex queue** and **Claude inbox** paths, with states for unavailable recipients, ambiguous identities and delivery failures.

The shared Inbox carries the same application and conversation identities. It separates completion messages, waiting states and pending requests so feedback remains connected to the work. Delivery status and the Agent's task-completion feedback are presented separately.

[Native handoff](https://github.com/duroey/MyType/blob/main/Type4Me/Services/AgentHandoffDeliveryService.swift) · [Source observers](https://github.com/duroey/MyType/blob/main/Type4Me/Services/AgentNotificationService.swift) · [Inbox state](https://github.com/duroey/MyType/blob/main/Type4Me/Services/AgentInboxStore.swift)

## Current results and iteration

The public code connects voice input, two Agent session catalogs, search, task routing, native handoff, new-task preparation and the Inbox into one workflow.

This is an actively developed personal project. Its current evidence is the inspectable implementation and workflow; end-to-end behavior continues to be validated against desktop Agent versions and native interfaces.

Local development also explores additional Agent integrations, overlapping recording and context binding, and low-interruption multimodal, full-duplex interaction. These developments are tracked separately from the current public version.

## Build from source

1. Prepare **macOS 14 or later** and Xcode Command Line Tools.
2. Follow [CONTRIBUTING.md](CONTRIBUTING.md) to build and configure MyType, including optional local ASR dependencies.
3. Configure the speech-recognition, language-model or local-model services you intend to use.
4. Agent history search requires the **AgentsView backend and its license**. Configure them as described in the build guide, then authorize local conversation access in settings.
5. Keep the corresponding Codex / Claude environment available, then use the Agent entry point to resume, create or hand off work.

MyType is currently provided through source builds in this repository. Upstream Type4Me packages and demos show the base product and do not include MyType's Agent extensions.

<details>
<summary><b>Retained voice-input and text-processing capabilities</b></summary>

MyType retains Type4Me's input foundation, including:

- Local and cloud speech recognition and provider configuration.
- Text polishing, translation, spoken questions, custom prompts and manual input.
- Hotwords, text replacements, history and usage management.
- Configurable shortcuts and menu-bar controls.

See [Modes & Features](docs/usage/modes.en.md) and the [URL Scheme reference](docs/usage/url-scheme.en.md).

</details>

## Project origins and my contribution

[Type4Me](https://github.com/joewongjc/type4me) provides the speech-recognition, text-processing and original interface foundation. My work focuses on desktop Agent session search, task routing, native handoff, new tasks and feedback, developed through personal use, problem investigation and iterative implementation.

MyType retains a separate application identity, data and configuration boundary. Upstream documentation and interface assets retain their attribution and do not demonstrate MyType's added Agent capabilities or product outcomes.

Documentation: [Build & contribute](CONTRIBUTING.md) · [Docs index](docs/README.md) · [Development guide](AGENTS.md)

Thanks to [SenseVoice](https://github.com/FunAudioLLM/SenseVoice), [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx), [Qwen3-ASR](https://github.com/QwenLM/Qwen3-ASR) and other foundation components. See the complete [third-party notices](Type4Me/Resources/THIRD_PARTY_LICENSES.txt).

## License

MyType uses a [proprietary commercial licensing notice](LICENSE). Original additions that the rights holders can license on new terms require separate authorization.
Upstream Type4Me remains under the [MIT License](Type4Me/Resources/ThirdPartyNotices/Type4Me-LICENSE); other components retain their own licenses. See the [third-party notices](Type4Me/Resources/THIRD_PARTY_LICENSES.txt).
Rights already granted for earlier releases and other material under MIT or another license are unaffected.
