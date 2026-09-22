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
    claude-2.0                   {{2023-07-11 8 24 10.00 0.80}} \
    claude-2.1                   {{2023-11-21 8 24 10.00 0.80}} \
    claude-3-5-haiku-20241022    {{2024-11-04 0.80 4 1.00 0.08}} \
    claude-3-5-sonnet-20240620   {{2024-06-20 3 15 3.75 0.30}} \
    claude-3-5-sonnet-20241022   {{2024-10-22 3 15 3.75 0.30}} \
    claude-3-7-sonnet-20250219   {{2025-02-19 3 15 3.75 0.30}} \
    claude-3-haiku-20240307      {{2024-03-07 0.25 1.25 0.30 0.03}} \
    claude-3-opus-20240229       {{2024-02-29 15 75 18.75 1.50}} \
    claude-3-sonnet-20240229     {{2024-02-29 3 15 3.75 0.30}} \
    claude-fable-5               {{2026-06-09 10 50 12.50 1.00}} \
    claude-fable-5-1             {{2026-09-01 10 50 12.50 0.25}} \
    claude-haiku-3-5             {{2024-11-04 0.80 4 1.00 0.08}} \
    claude-haiku-4-5             {{2025-10-15 1 5 1.25 0.10}} \
    claude-haiku-4-5-20251001    {{2025-10-15 1 5 1.25 0.10}} \
    claude-instant-1.2           {{2023-08-09 0.80 2.40 1.00 0.08}} \
    claude-mythos-5              {{2026-06-09 10 50 12.50 1.00}} \
    claude-mythos-5-1            {{2026-09-01 10 50 12.50 0.25}} \
    claude-opus-4-0              {{2025-05-14 15 75 18.75 1.50}} \
    claude-opus-4-1              {{2025-08-05 15 75 18.75 1.50}} \
    claude-opus-4-1-20250805     {{2025-08-05 15 75 18.75 1.50}} \
    claude-opus-4-20250514       {{2025-05-14 15 75 18.75 1.50}} \
    claude-opus-4-5              {{2025-11-24 5 25 6.25 0.50}} \
    claude-opus-4-5-20251101     {{2025-11-24 5 25 6.25 0.50}} \
    claude-opus-4-6              {{2026-02-05 5 25 6.25 0.50}} \
    claude-opus-4-7              {{2026-04-16 5 25 6.25 0.50}} \
    claude-opus-4-8              {{2026-05-28 5 25 6.25 0.50}} \
    claude-opus-5                {{2026-07-24 5 25 6.25 0.50}} \
    claude-opus-5-5              {{2026-09-22 4 20 5.00 0.20}} \
    claude-sonnet-4-0            {{2025-05-14 3 15 3.75 0.30}} \
    claude-sonnet-4-20250514     {{2025-05-14 3 15 3.75 0.30}} \
    claude-sonnet-4-5            {{2025-09-29 3 15 3.75 0.30}} \
    claude-sonnet-4-5-20250929   {{2025-09-29 3 15 3.75 0.30}} \
    claude-sonnet-4-6            {{2026-02-17 3 15 3.75 0.30}} \
    claude-sonnet-5              {{2026-06-24 2 10 2.50 0.20}}
