# Research

Verbatim user voices and competitive evidence backing the feature claims in the project README and any future landing-page copy. Nothing in this folder is canonical product spec, only the basis for it. Feature copy should use words taken from `voices.md` so the project speaks to users in the language they already use.

The folder is organized around one question: why a developer goes back to a session that is already finished. `use-case-survey.md` sorts those reasons by whether writing state forward could have prevented the return. That line is the thesis of the research: the ecosystem's memory systems already serve the forward-preventable returns, so questlog's least-substitutable value is the returns that cannot be foreseen at session time, closing a loop you did not know you left open and defending a conclusion you did not know would be challenged.

## Files

- `voices.md`: quotebook of user pain-points by category. Each entry is a verbatim quote (or a clearly marked paraphrase) with link, date, context, and the USP it maps to. The corpus from which feature copy is written in words users already think in.
- `competitive-landscape.md`: feature matrix of Claude Code session viewers, managers, and adjacent tools, plus a per-USP differentiation verdict. Dated snapshot.
- `use-case-survey.md`: survey of what people do with Claude Code session history, ranked by frequency of evidence. Dated snapshot.
- `usp-ranking.md`: synthesis of the above into a re-ranked USP list and a list of confirmed gaps.

## The USP numbering

The twelve USPs are numbered once, in `usp-ranking.md`, and every entry in the other three files maps to a USP number or labels itself `gap` (real demand, no current feature). The numbers are stable identifiers, not a ranking; the ranking is a separate table inside `usp-ranking.md`.

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

Add new quotes to `voices.md` under the matching category. A new category is fine once it has at least two entries; until then keep the singleton in the closest sibling category. Re-snapshot `competitive-landscape.md` and `use-case-survey.md` when the field changes meaningfully: a new session tool reaches the top tier, an existing one is abandoned, or Anthropic ships a feature that changes local session storage.

When a USP changes (added, removed, renumbered), update the cross-reference in `voices.md`, `competitive-landscape.md`, `use-case-survey.md`, and `usp-ranking.md` together.
