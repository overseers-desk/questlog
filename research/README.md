# Research

Verbatim user voices and competitive evidence about Claude Code session management, plus a record of what questlog covers. The market files (voices, competitive-landscape, use-case-survey, discussion-drivers) are the basis for feature and landing-page copy, drawn from the field rather than from the code; feature copy should use words taken from `voices.md` so the project speaks to users in the language they already use. `status.md` is the one code-grounded file: it records which pains questlog covers and where in the source.

The folder is organized around the session-management pain points developers voice, and what the field supplies for each. `use-case-survey.md` defines the pain taxonomy (P1-P13) and holds the canonical numbers; `voices.md`, `competitive-landscape.md`, and `discussion-drivers.md` map their evidence to those numbers, and `status.md` maps each pain to questlog's coverage.

## Files

- `voices.md`: quotebook of user pain-points by category. Each entry is a verbatim quote (or a clearly marked paraphrase) with link, date, context, and the pain it maps to. The corpus from which feature copy is written in words users already think in.
- `competitive-landscape.md`: feature matrix of Claude Code session viewers, managers, and adjacent tools (the field), plus a per-pain supply note. Dated snapshot. questlog is not in the matrix; its coverage is in `status.md`.
- `use-case-survey.md`: the pain taxonomy and per-pain demand signal. Holds the canonical pain numbers. Dated snapshot.
- `discussion-drivers.md`: what drives comment volume on session-tool posts, and why cost posts outpoll session-tool posts. Dated snapshot.
- `naming.md`: why the project is called questlog, and the rename history.
- `status.md`: questlog's coverage of each pain, its differentiation against the field, the gaps, and the positioning that follows. The only file written from the code.

## The pain-category numbering

The thirteen pains are numbered once, in `use-case-survey.md`, and every entry in the market files maps to a pain number. The numbers are stable identifiers, not a ranking.

## Conventions

- Verbatim quotes get double quotes and an attribution line. The attribution line is the one place an em-dash is allowed.
- Verbatim user text is reproduced faithfully, including any punctuation inside the quote.
- Paraphrases are marked `[paraphrase]` with a link, so a future contributor can re-read the source and replace with verbatim text. Treat every paraphrase as a TODO for verbatim recovery.
- Every entry carries a working link and a date. Approximate dates are written `~2025` or `early 2026`; precision is never invented.
- Absence of evidence for a claim is recorded as such ("no verbatim complaint found; closest is ..."), kept distinct from evidence of absence.
- Within a category, sort by source date, oldest first, so the corpus reads as a timeline.

## Sources

The May 2026 snapshot draws verbatim material chiefly from Reddit (r/ClaudeAI, r/ClaudeCode), the `anthropics/claude-code` GitHub issue tracker, Hacker News, and developer blogs. Reddit is the primary source: it carries the densest first-person account of how developers live with session sprawl, fetched through the `reddit.com` skill (old.reddit `.json` via the headless wrapper).

## Growing the folder

Add new quotes to `voices.md` under the matching category. A new category is fine once it has at least two entries; until then keep the singleton in the closest sibling category. Re-snapshot `competitive-landscape.md`, `use-case-survey.md`, and `discussion-drivers.md` when the field changes meaningfully: a new session tool reaches the top tier, an existing one is abandoned, or Anthropic ships a feature that changes local session storage. Update `status.md` when questlog's code changes.

When a pain category changes (added, removed, renumbered), update the cross-reference in `voices.md`, `competitive-landscape.md`, `use-case-survey.md`, and `status.md` together.
