<!-- Prompt templates for bin/learn-corrections.sh (spec 5.2). Two tasks, each starting at its
     "<!-- template: NAME -->" line and running to the next one. The script fills each line that is exactly
     {{NAME}} with data, and sends everything from the "ching-learn-task:" line on. The labelling policy below is
     pending the owner's spot-check: change it here, nothing else needs to change. -->

<!-- template: corrections-classify -->
ching-learn-task: corrections-classify

You label prompts that a person (the owner) typed to an AI coding assistant. For each snippet, decide whether
the owner is CORRECTING HOW THE ASSISTANT WORKED: telling it that something it did, or was about to do, was
wrong, or repeating a standing instruction it ignored.

Label "correction" when the owner:
- stops or reverses something the assistant did ("no, don't bump the version", "stop using npm here");
- repeats a standing instruction or habit the assistant should already know ("I told you, YYYY-MM-DD dates");
- tells the assistant to do a step itself instead of handing it back ("you have the token, run it yourself",
  "why do I have to do this for you", "you should be able to apply the migration", "don't ask, just merge").

Label "not" for everything else, including:
- a new request, a question, an answer to the assistant's question, or a plain next step;
- feedback on the product being built, not on how the assistant works ("too much text on this page",
  "that number looks wrong", "the button is still broken");
- a condition stated up front with a new task ("merge it without losing anything"). It is a correction only
  when it repeats a standing rule the assistant broke or ignored before, as the previous assistant message or
  the wording ("again", "as always", "like I said") shows;
- pointing the assistant at a previous session's context ("in the last session we built X, continue"). It is a
  correction only when the assistant acted without knowing that context and the owner is fixing the result.

When unsure, say "not". A false "correction" costs the owner a review; a missed one comes back when it repeats.

For each correction, write a one-line normalised pattern: the general rule the assistant should follow from
now on, in plain imperative words, without names of files, numbers or projects unless the rule is about them
(for example "do not bump the version number; the owner releases by hand"). If a correction states the same
rule as one of the known patterns below, copy that pattern EXACTLY, so that repeats group together.

Known patterns (one per line; may be empty):
{{KNOWN_PATTERNS}}

Snippets, one JSON object per line. "text" is the owner's prompt, "prev_assistant_tail" is the end of the
assistant message just before it, "after_interrupt" is true when the owner had just interrupted the assistant:
{{SNIPPETS}}

Answer with exactly one JSON document and nothing else, in this shape, one entry per snippet id:
{"labels":[{"id":"<id>","label":"correction","pattern":"<pattern>"},{"id":"<id>","label":"not"}]}

<!-- template: corrections-draft -->
ching-learn-task: corrections-draft

You draft rules for an AI coding assistant's instruction files. Each cluster below is one correction the owner
repeated in several sessions. For each cluster, first check the rule files below: if an existing rule already
says the same thing (even in other words), the cluster is covered. Otherwise draft a short rule.

Write for the owner, plainly: short sentences, no filler, no marketing words. The rule itself is one to three
sentences, imperative, general enough to apply next time, specific enough to act on.

For each cluster that is NOT covered, give:
- "slug": 2 to 5 lower-case words joined by dashes, naming the rule;
- "target": copy the cluster's target exactly;
- "proposal": two to five plain sentences: what the rule says and why (how often it came up);
- "patch": a unified diff that adds the rule to the cluster's target file as shown below, with paths
  "a/<file name>" and "b/<file name>" (the file name only, for example a/CLAUDE.md), correct @@ line numbers and
  counts, and two or three unchanged context lines around the change. Put the rule in the section where it fits,
  or add a short "## " section at the end. Change nothing else. For a target shown as "(missing)", the diff
  creates it: "--- /dev/null", "+++ b/<file name>", "@@ -0,0 +1,N @@";
- "why_not_covered": which existing rules you checked, and why none of them covers this.

Clusters, one JSON object per line ("quotes" are the owner's own words):
{{CLUSTERS}}

Rule files (the current text of each target, and of the repos the evidence came from):
{{RULES}}

Answer with exactly one JSON document and nothing else, in this shape, one entry per cluster pattern (copy
each "pattern" exactly):
{"rules":[{"pattern":"<pattern>","covered":false,"slug":"<slug>","target":"<target>","proposal":"<text>","patch":"<diff>","why_not_covered":"<text>"},
          {"pattern":"<pattern>","covered":true,"covered_by":"<file and the rule that covers it>"}]}
