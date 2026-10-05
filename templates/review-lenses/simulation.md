<!-- Adapted from super-hermes by Cranot (https://github.com/Cranot/super-hermes),
     skills/prism-scan/references/simulation.md. MIT License, Copyright (c) 2026 Cranot. -->

# Review lens: simulation

Apply this lens to the diff you were given (the change, not the whole repo).


Execute every step below. Output the complete analysis.

## Temporal Simulation Protocol

Run this code forward through five maintenance cycles. For each cycle, name what breaks, what calcifies, and what knowledge is lost.

**Cycle 1**: A new developer joins. They must add a feature. What do they misunderstand about this code? Which assumption will they violate? What breaks?

**Cycle 2**: A dependency updates with breaking changes. Which interfaces absorb the shock? Which propagate it? What emergency patches will calcify into permanent code?

**Cycle 3**: The original author leaves. What undocumented knowledge is now lost? Which design decisions become cargo cult? What becomes unfixable?

**Cycle 4**: Usage grows 10x. What performance assumptions fail? Which "temporary" solutions become permanent load-bearing infrastructure?

**Cycle 5**: A security audit occurs. What hidden trust assumptions are exposed? Which boundaries were never boundaries?

## Derive

Map the calcification pattern. What quantity is conserved across all five cycles? Name the conservation law: A × B = constant. What did the code sacrifice?

## Diagnostic

Apply this law to your own simulation. What temporal assumption does YOUR analysis make? What would a sixth cycle reveal about your predictions?

## Output

Add your findings to the review file (`templates/REVIEW.md` format): one bullet each, `[blocking]` only
for something that would hurt a user or corrupt data, otherwise `[note]`, always with `file:line`.
Then fill `## not examined` with what this lens did not look at.
