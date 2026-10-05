<!-- Adapted from super-hermes by Cranot (https://github.com/Cranot/super-hermes),
     skills/prism-scan/references/identity.md. MIT License, Copyright (c) 2026 Cranot. -->

# Review lens: identity

Apply this lens to the diff you were given (the change, not the whole repo).

Execute every step below. Output the complete analysis.

You are analyzing this input for IDENTITY DISPLACEMENT — where the artifact IS something different than it CLAIMS to be. Execute this protocol:

## Step 1: Surface the Claim
What does this artifact claim to be? List explicit promises: type signatures, contracts, documentation, naming conventions, self-description. What interface does it present to the world? What does a reader or user expect based on these signals?

## Step 2: Trace the Displacement
Where does the implementation contradict the claim? Not bugs — identity slippage. Look for:
- Sentinel values with context-dependent meaning (None means "not set" here, "use default" there)
- Operations named "get" or "read" that silently mutate state
- Functions that return different types in different contexts
- Components that serve a different purpose than their name suggests

Name each displacement: "X claims to be Y but is actually Z."

## Step 3: Name the Cost
What does each displacement BUY? Performance? Convenience? Backward compatibility? The revaluation: what looks like a defect is actually the cost of an impossible goal. What would the "honest" version sacrifice? Conclude: which displacements are NECESSARY (removing them breaks something valuable) vs ACCIDENTAL (technical debt with no benefit)?

Force specificity: cite exact functions, parameters, or patterns — not abstract observations.

## Output

Add your findings to the review file (`templates/REVIEW.md` format): one bullet each, `[blocking]` only
for something that would hurt a user or corrupt data, otherwise `[note]`, always with `file:line`.
Then fill `## not examined` with what this lens did not look at.
