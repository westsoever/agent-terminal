# Ching decision log

Newest first. PLAN.md holds D1-D9 and the v3 scope note; later decisions are recorded here and folded into PLAN.md once the Phase 1 build finishes (the build agent is editing PLAN.md now).

## D12 (2026-10-05): mem0 is not included

**Decision (user):** Do not include mem0, now or later. It is the wrong tool: its defaults send data to OpenAI (LLM and embeddings), it needs a vector database and a separate service, and running it locally means standing up Ollama and Qdrant. The user expected a lightweight harness around Claude, which it is not. If it cannot run locally without that extra stack, it stays out.

**What I checked (README summary only, not the code):** Apache-2.0, very active (pushed 2026-10-05, 66k stars). Three modes: library, self-hosted Docker server, hosted cloud. Defaults: OpenAI `gpt-5-mini` plus `text-embedding-3-small`, Qdrant. Ollama is supported through config. A `.claude-plugin` directory exists; I did not inspect it. Telemetry defaults were not stated in what I read.

**Still open:** the user is looking for other tools for the "mirror me and learn my decisions" job. Requirements to judge any candidate against: runs fully local with no cloud calls by default, no extra always-on service if avoidable, readable and editable storage, works alongside claude-mem, and proposes decisions for approval rather than acting on them. Ching's profile storage (D11) stays backend-agnostic so a tool can be added or dropped later.

## D11 (2026-10-05): Ching is a learning system, not just a voice interface

**Decision (user):** Ching must not be only a voice model or a session manager. It is a place of learning and adapting that improves itself. It understands how the user works, what they are good at, and what they lack. It keeps track of that and keeps improving the way they work, so their output is as high as possible.

**What this adds to the design (proposed, not yet built; needs the user's review):**

- A **profile** in `~/.agent/profile/`: working patterns (when and how sessions run, which kinds of task finish fast or stall), strengths, gaps, and recurring friction. Plain markdown and JSONL, so the user can read, edit and delete it.
- **Signals** come from data the kit already has: session transcripts and registry, `STATE.md` logs (assumptions, decisions, releases), Stop-hook retries, questions asked, overturned assumptions, minutes per handoff. These are the three pilot metrics in PLAN.md section 7, kept continuously instead of for one pilot.
- A **review loop** (daily or weekly, run on a cheaper model) that reads the signals, updates the profile, and proposes concrete changes: a rule for `AGENTS.md`, a hook tweak, a `GOAL.md` template fix, a task split. Proposals are written to `~/.agent/proposals/` and shown to the user.
- **Self-improvement is gated.** Ching proposes changes to its own scripts, policy and the user's `AGENTS.md`; the user approves them. It does not rewrite its own guardrails or `guard.sh` on its own.
- **Local only.** The profile never leaves the machine and is never sent to a service. The user can inspect it, correct it ("that's wrong") and wipe it.
- This replaces the old "director loop deferred" idea (D7) with something broader. It stays out of Phase 1 and gets its own phase after the machine-wide kit is working (Phase 6 in PLAN.md).

**Open questions for the user:** how blunt should "what I'm lacking" be, how often should the review run, and should the profile feed back into the dispatcher's spoken answers.

## D10 (2026-10-05): Split work across multiple agents from the start

**Decision (user, after the orchestrator's admission):** Large phases are not given to one big agent. They are split into several agents working in parallel on independent parts, with a separate verification step.

**Why:** Phase 0 took about 12 minutes and Phase 1 as one agent writing nine scripts plus tests was slow. The orchestrator should have split it at the start.

**How to apply:**
- Split by independent unit: for example hooks, gates, `dash.sh`, installer, tests, docs each get their own agent when they do not share files.
- Define the shared interface first (file formats, JSON schemas, paths such as `~/.agent/`), then fan out.
- A separate verification agent runs the tests and reviews the result; the implementer does not grade its own work.
- The currently running Phase 1 agent is not restarted. Phases after it follow this rule.
