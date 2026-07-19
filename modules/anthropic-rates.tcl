# anthropic-rates.tcl - Claude model token rates, as a tallyman rates dict.
#
# DERIVED from the anthropic-rates.csv table in the questlog repository's
# data/, the source of truth for these figures. There is no generator
# script: when a rate changes there, the dict below is retyped from the
# table by hand, and copies vendored beside coachman elsewhere are
# refreshed from this file, then diffed. Do not edit a rate here alone:
# a figure that disagrees with the CSV is a silent mispricing.
#
# Shape: model -> sorted list of {effective_from input output cache_write
# cache_read}, each rate a price per million tokens, rows ordered by
# effective_from so the row whose date is <= the session's own date is the one
# that billed. `source` this file to obtain the dict:
#     set rates [source [file join $vendor anthropic-rates.tcl]]

dict create \
    claude-fable-5               {{2026-06-09 10 50 12.50 1.00}} \
    claude-haiku-3-5             {{2024-11-04 0.80 4 1.00 0.08}} \
    claude-haiku-4-5             {{2025-10-15 1 5 1.25 0.10}} \
    claude-haiku-4-5-20251001    {{2025-10-15 1 5 1.25 0.10}} \
    claude-opus-4-1              {{2025-08-05 15 75 18.75 1.50}} \
    claude-opus-4-5              {{2025-11-24 5 25 6.25 0.50}} \
    claude-opus-4-6              {{2026-02-05 5 25 6.25 0.50}} \
    claude-opus-4-7              {{2026-04-16 5 25 6.25 0.50}} \
    claude-opus-4-8              {{2026-05-28 5 25 6.25 0.50}} \
    claude-sonnet-4-5            {{2025-09-29 3 15 3.75 0.30}} \
    claude-sonnet-4-6            {{2026-02-17 3 15 3.75 0.30}}
