commit: <full 40-char sha of HEAD>
surface: ui
none_reason:
app_url: http://localhost:3000/the/changed/view
screenshot: .agent/verify/<full sha>.png

<!--
Evidence file for release-gate.sh. Save as .agent/verify/<full HEAD sha>.md.

The gate parses this file MECHANICALLY and ignores any verdict you write. It rejects the release if:
  - `commit:` is not the exact HEAD sha
  - `surface: ui` and the screenshot file does not exist, or there is no `## exercised` bullet
  - `surface: none` and `none_reason:` has fewer than 10 characters
  - the console block has any line with an error (`[error]`, "error", "uncaught", "unhandled",
    "exception") that is not covered by an `## allowed` pattern
  - the network block has any line whose HTTP status is not 2xx (304 is accepted), including 404,
    unless covered by an `## allowed` pattern. Every non-blank line must END with the status.
  - the "## not examined" section has fewer than 10 characters once HTML comments are removed
    (the placeholder under it is a comment on purpose: an untouched copy of this file is rejected)

Paste RAW output. Do not summarise, do not delete lines you dislike. If a line is genuinely
benign (favicon 404), add a pattern under `## allowed` WITH a reason.
Write `none` as the only line of a block that is really empty.
-->

## console

```console
none
```

## network

```network
GET http://localhost:3000/the/changed/view 200
```

## allowed

<!-- One extended regex per bullet, each with a reason after `#`. Example:
- favicon\.ico  # no favicon in dev
-->

## exercised

- Opened the changed view, did X, saw Y.

## not examined

<!-- Write what this verification deliberately did not check (other views, mobile, write paths on preview, load), at least one real sentence. Comments do not count. -->
