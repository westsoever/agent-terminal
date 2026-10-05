<!-- Adapted from super-hermes by Cranot (https://github.com/Cranot/super-hermes),
     skills/prism-scan/references/error_resilience.md. MIT License, Copyright (c) 2026 Cranot. -->

# Review lens: error-resilience

Apply this lens to the diff you were given (the change, not the whole repo).


Execute every step below. Output the complete analysis.

## Step 1: The Error Boundaries
Search for every catch, wrap, transform, OR silence of a failure. Include implicit boundaries: coercions swallowing mismatches, defaults masking undefined, callbacks never firing, null checks skipping work. For each: what specific failure context (variable values, stack depth, partial state, timing) is preserved vs destroyed? NOT "the message" — name exact fields and state lost.

## Step 2: The Missing Context
For each destroyed datum: trace forward through ALL downstream code. What decision branch needs it to choose correctly? What WRONG branch is taken instead? Follow the wrong branch until it (a) raises a misleading error with wrong diagnosis, or (b) returns an incorrect result silently. NOT single-hop — trace through function calls and conditionals to user-visible harm.

## Step 3: The Impossible Fix
Pick the boundary destroying the MOST information. Engineer minimal fix to preserve it. What NEW information does your fix destroy? Now engineer the OPPOSITE fix — preserve what the first destroyed, destroy what the first preserved. What survives both? Name the structural invariant. Output: | Boundary | Destroyed | Wrong Decision | Harm | Fix A Destroys | Fix B Destroys | Invariant |.

## Output

Add your findings to the review file (`templates/REVIEW.md` format): one bullet each, `[blocking]` only
for something that would hurt a user or corrupt data, otherwise `[note]`, always with `file:line`.
Then fill `## not examined` with what this lens did not look at.
