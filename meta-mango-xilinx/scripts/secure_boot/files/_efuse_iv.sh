# shellcheck shell=bash
# The two boot-image IVs burned to eFUSE. Inputs, not bootgen output: pinned into
# the metaheader/PLM .nky between the two passes. One copy on purpose.

# shellcheck disable=SC2034  # read by whoever sources this file
SB_METAHEADER_IV0=5BB46B3A73991E3DE8997508
# shellcheck disable=SC2034
SB_PLM_IV0=896FE777F083F0263D834C6E
