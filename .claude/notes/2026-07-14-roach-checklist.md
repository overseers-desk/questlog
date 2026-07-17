# questlog: design-vs-code roach checklist (audit of 2026-07-13, code at 66f4b4f)

A "roach": a feature the design CONTRACTED and the code IMPLEMENTS, but implements
differently (wrong default, dropped state, wrong wording/order). Excludes deferred
features and clam-theme visual limits (docs/design-ttk-gaps.md). Five readers, one
slice each: toolbar/criteria, view/lenses, strip/columns/cost, rows/menus,
viewer/supporting. Design truth = the screens.jsx render functions + app.jsx
annotations + screenshots, not stale comments or width constants.

Execution: plan ~/.claude/plans/eager-humming-bentley.md (approved 2026-07-14).
Items numbered 1-19 there. Line numbers below were read at 66f4b4f.

EXECUTED AND PUSHED 2026-07-14, 66f4b4f..2aec692 (five commits: viewer find
readout + band tracking; Restrict rest state w/ facetbar -countables + folder
tag + Model:; the thirteen list-side items; the general-open verb residual;
the review-findings close). Every floor item and both master decisions landed.
S-p resolved as SKIP (no live binding backs either accelerator; the keyboard
gap is #53). Surfaced and filed: #48 tool any/all, #49 search-terms hint,
#50 macOS refusal modal, #51 Ctrl-F set sync, #52 subagent double-render,
#53 keyboard open, #54 scan "and counting". The under-cwd preset was dropped,
not filed (the 003b838 revert is the decision). test-sort-path's fixtures now
age relative to now (calendar dates crossed the 30d window overnight and the
suite failed by itself).

## BEHAVIORAL (confirmed)
- B1 Single click on a search result jumps to first match, not session start.
  Design states 3x in section 1 (app.jsx:252,218; screens.jsx:1163). Code:
  open_session defaults to first_lineno seeded from the first match's lineoff
  (ui/sessions.tcl:675,2050); viewer scroll_to_line jumps (ui/viewer.tcl:263).
  Browse correct; search-mode plain click inverts. FIX plan item 1.
- B2 "N active" counts facet types incl. time+turn anchors; design counts chip
  VALUES over content criteria only (screens.jsx:335; anchors live outside
  _groups :403,:430). facetbar-1.0.tm active_count. DECIDED at plan review:
  align (M1). FIX plan item 18 (-countables option).
- B3 Cancel button never disables (design screens.jsx:546 disabled={!cancellable};
  code ui/sessions.tcl:316 always enabled; idle click stamps "Cancelled.").
  FIX plan item 2.
- B4 Restrict box opens expanded; design screens.jsx:304 restrictExpanded=false
  (collapsed chip summary; expanded only mid-edit, app.jsx:230 vs :263). DECIDED:
  align (M1). FIX plan item 17 (host calls collapse after setup).
- B5 Find bar lacks "N of M" readout (screens.jsx:1370; ui/viewer.tcl:684,1797).
  FIX plan item 3.
- B6 No "+N more matches - open to see all" overflow line under capped snippets
  (screens.jsx:1058,1078; cap 3 at ui/sessions.tcl:686, config snippets_per_session).
  FIX plan item 4.

## COSMETIC (confirmed)
- C1 Cut banner "outside your search" when time/folder/min-turns cut; next sentence
  names the real cause, self-contradicting (ui/sessions.tcl:2694,2869). Design says
  "criteria"/names it (view-toggle-clarity.jsx:169,164,184; bookmarks-view.jsx:212).
  FIX item 5.
- C2 Folder tag "under"; design section 3.5 renamed to "folder", conn "ran under"
  kept (criteria-reconsidered.jsx:163; ui/toolbar.tcl:786). FIX item 6.
- C3 High-cost cells: colour only; design colour AND bolder weight (screens.jsx:31,
  cost-analytics section 6.2 note H; ui/sessions.tcl:421). FIX item 7.
- C4 "and counting..." scan suffix dropped (screens.jsx:540; refresh_status
  ui/sessions.tcl:3007). FIX item 8.
- C5 Sort arrows small ▾/▴ vs design ▼/▲ (screens.jsx:556; streamtree-1.0.2.tm:639,648).
  Adopted default: change module default glyphs. FIX item 14.
- C6 Size units K/M vs design KB/MB (screens.jsx:12; fmt_size ui/sessions.tcl:3022;
  width sample :31). Adopted default: adopt. FIX item 15.
- C7 Snippet badges "USER"/"TOOL USE" vs "user text"/"tool call" (SNIPPET_LABELS
  screens.jsx:991; ui/sessions.tcl:861). FIX item 9.
- C8 On a hit both "Copy this snippet" AND "Copy last assistant output" show;
  design single slot (screens.jsx:1102 ternary; session_actions.tcl:74,78).
  FIX item 10.
- C9 Case-B "no match in this session" line: design = own muted italic line below
  row + dimmed subject + "N match(es) below in a subagent/subagents"
  (screens.jsx:824,744,830). Code inlines as subject tail, no muting, "N in
  subagents below" (ui/sessions.tcl:1508,1551,1493). FIX item 11.
- C10 "+N in subagents" pip plain text always plural; design pill + singular
  (screens.jsx:753; ui/sessions.tcl:1507). Adopted: singularise only (item 12);
  pill stays text (default kept).

## SUSPECTED - defaults adopted at floor-and-fork (no code unless noted)
- S-a View toggle glyphs (green dot Running / gold star Bookmarked in the control):
  DECLINED (M2 skip). Rows keep their glyphs.
- S-b Model control "model any model" vs "Model:"+"Any"+dot: label capitalised to
  "Model:" (item 19); dot DECLINED (M2).
- S-c Cut banner per-lens accent glyph: DECLINED (M2).
- S-d Rail word "Add filter" vs design "add:": KEEP (names the action).
- S-e Literal "or" between same-type chips: KEEP (OR legibility).
- S-f Aa font button vs the ... menu: KEEP in menu (deliberate consolidation).
- S-g Band highlight does not track Ctrl-F/Next (screens.jsx:1285;
  ui/viewer.tcl:2095,1797,2116): FIX, floor item 13.
- S-h Ctrl-F entry unseeded: KEEP (seeding clobbers the rarity-ordered shared set).
- S-i Model as right-pinned column not inline chip: KEEP (user-requested column).
- S-j Subject sortable by path (design says not sortable): KEEP (additive).
- S-k Browse strip shows only cost, count on app bar: KEEP (two-strip split).
- S-l/m/n Scan accent dot / cost pulse / folder-cost tier colour: KEEP.
- S-o Subagent leader bold agent_type vs generic "task" badge: KEEP (real data).
- S-p Menu accelerators (Return on Open, copy-resume): add ONLY where a live
  binding exists (item 16); a hint with no binding lies.

## KNOWN DECISIONS (excluded, decided before this audit)
Segmented All/Running/Bookmarked -> independent toggles (vetoed segment);
complete-lens pause-on-entry ("accepted, not yet shipped" in the design itself);
docked match band w/ tabs, not float; model column; H% column; expand-all;
no-default-folder-scope.

## OUT OF CLASS (missing features, not roaches) - FILED 2026-07-14
Tool any/all toggle = #48. Search-terms hint line = #49. macOS refusal modal = #50
(with a corrected mechanism: exec_ok backgrounds every launch, so an unauthorized
osascript returns APPARENT SUCCESS silently; the modal needs synchronous exit-status
capture first, not a redirect of a stderr line that does not exist).
The auto-preset under-cwd chip (design cwdOnly=true) was DROPPED, not filed: commit
003b838 built and then deliberately removed exactly this (a shell in $HOME presets a
chip that is a parent of everything, and OR-within-facet lets that default silently
mask any narrower scope added after it). The design is stale here; the revert is the
decision, as the known-decisions list above already records.

## CLEAN (checked, match)
The ... actions cell (fade->bright on hover AND selection; left-click = right-click
menu); #42's match-conditional entries + unresolvable disabling; region dropdown;
Aa toggle; the whole section 3.6 since row; file merge front door + op pill;
default sort date desc; folder cost re-rank; cost format/tiers; onboarding
dismiss persistence; empty viewer no-reflow; per-turn fold defaults; shared
Ctrl-F match set.
