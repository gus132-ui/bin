#!/bin/bash
# =============================================================================
# officium_curses.sh — Liturgy of the Hours viewer using bashsimplecurses
#
# Full-screen TUI inspired by bashmount:
#
#   ┌─ <liturgical day title> ──────────────────────────────────────────────┐
#   │  1) Laudes  2) Prima  3) Tertia  4) Sexta  5) Nona  6) Vesperae      │
#   └───────────────────────────────────────────────────────────────────────┘
#   ┌─ <Hora> ───────────────────────────────────────────────────────────────┐
#   │  Prayer text ...                                                        │
#   └───────────────────────────────────────────────────────────────────────┘
#   ┌─ Commands ─────────────────────────────────────────────────────────────┐
#   │  [1-6]: select hora    [Enter]: refresh    [q]: quit                   │
#   └───────────────────────────────────────────────────────────────────────┘
#   Command: _
#
# Authors : Adam Gomułka, Łukasz Kasprzak
# Created : 2026-03-05
# Version : 0.2
# =============================================================================

set -eo pipefail

# ── Library ───────────────────────────────────────────────────────────────────

BSC_LIB="${HOME}/.local/lib/bashsimplecurses/simple_curses.sh"

if [ ! -f "$BSC_LIB" ]; then
  echo "Error: bashsimplecurses not found at $BSC_LIB"
  echo "Expected path: $BSC_LIB"
  exit 1
fi

source "$BSC_LIB"

# ── Configuration ─────────────────────────────────────────────────────────────

BASE_URL="https://www.divinumofficium.com/cgi-bin/horas/officium.pl"
HORAS=(Laudes Prima Tertia Sexta Nona Vesperae)

# Word-wrap width: full terminal width minus window border/padding
TERM_WIDTH=$(tput cols 2>/dev/null || echo 80)
WRAP="${WRAP:-$((TERM_WIDTH - 6))}"

# ── State ─────────────────────────────────────────────────────────────────────

SELECTED=1          # currently selected hora (0-based index into HORAS)
DIES=""             # liturgical day title (from purple font tag)
STATUS=""           # shown in the commands bar
declare -a PRAYER   # prayer text, pre-split into lines for BSC

HTML_TMP="$(mktemp)"
trap 'rm -f "$HTML_TMP"' EXIT

# ── Fetch and extract ─────────────────────────────────────────────────────────

# Fetch the HTML for a given hora, extract the day title and prayer text,
# and populate the DIES and PRAYER globals.
fetch_hora() {
  local hora="$1"
  local url="${BASE_URL}?command=pray${hora}"

  STATUS="Fetching ${hora}..."

  if ! curl -s --max-time 30 "$url" -o "$HTML_TMP" 2>/dev/null; then
    STATUS="Error: curl failed"
    PRAYER=("Could not reach divinumofficium.com." "Check your network connection.")
    DIES=""
    return 1
  fi
  if [ ! -s "$HTML_TMP" ]; then
    STATUS="Error: empty response"
    PRAYER=("Server returned an empty response.")
    DIES=""
    return 1
  fi

  # Extract the liturgical day title from the purple font tag near the top
  DIES=$(grep -o '<FONT COLOR="purple">[^<]*</FONT>' "$HTML_TMP" \
         | sed 's/<[^>]*>//g; s/\r//')

  # Extract and clean the Latin prayer text using the same pipeline as officium.sh
  local raw_text
  raw_text=$(awk '
    /COLOR="red"><B><I>Incipit<\/I><\/B><\/FONT>/ { printing=1 }
    printing {
      if (/COLOR=.?green.?>[0-9]/) td_col=2
      if (/<\/TD>/ && td_col==2)   td_col=0
      if (/<\/TR>/)                { td_col=0; print "" }
      if (td_col != 2) print
    }
    /<\/TABLE>/ && printing { exit }
  ' "$HTML_TMP" \
  | sed 's/<[^>]*>//g'           \
  | sed 's/\r$//'                \
  | sed 's/[[:space:]]*$//'      \
  | sed -E 's/^[0-9]+:[0-9]+[[:space:]]*//' \
  | sed 's/&nbsp;/ /g'           \
  | sed 's/&ensp;/ /g'           \
  | sed 's/&lt;/</g'             \
  | sed 's/&gt;/>/g'             \
  | sed 's/&amp;/\&/g'           \
  | sed 's/&#[0-9]*;//g'         \
  | sed 's/&#x[0-9a-fA-F]*;//g'  \
  | sed -E 's/^(Psalmus[[:space:]]+[0-9]+)\([^)]*\)/\1/' \
  | cat -s                        \
  | grep -vE "^(Top[[:space:]]+Next|Top|Next)$" \
  | grep -vE "^[A-Z][a-z]+ [A-Z][a-z]+\{"       \
  | grep -v "^[0-9]$")

  # Word-wrap long lines and load into the PRAYER array.
  # BSC's append takes one line at a time and does not wrap, so we must
  # pre-wrap here before rendering.
  PRAYER=()
  while IFS= read -r line; do
    if [ -z "$line" ]; then
      PRAYER+=("")
    elif [ "${#line}" -gt "$WRAP" ]; then
      while IFS= read -r wrapped; do
        PRAYER+=("$wrapped")
      done < <(echo "$line" | fold -s -w "$WRAP")
    else
      PRAYER+=("$line")
    fi
  done <<< "$raw_text"

  STATUS="$(date '+%A, %d %B %Y')  —  ${#PRAYER[@]} lines"
}

# ── BSC layout ────────────────────────────────────────────────────────────────

main() {
  local hora="${HORAS[$SELECTED]}"

  # ── Window 1: Hora selector ──────────────────────────────────────────────
  # Spans the full width; shows the liturgical day title and numbered hora list.

  local win_title="Divinum Officium"
  [ -n "$DIES" ] && win_title="$DIES"

  window "$win_title" "red" "100%"
    # Build one line of numbered hora buttons; selected hora is wrapped in []
    local hora_line="  "
    for i in "${!HORAS[@]}"; do
      local n=$((i + 1))
      if [ "$i" -eq "$SELECTED" ]; then
        hora_line+="${n}) [${HORAS[$i]}]   "
      else
        hora_line+="${n}) ${HORAS[$i]}   "
      fi
    done
    append "$hora_line"
  endwin

  # ── Window 2: Prayer text ────────────────────────────────────────────────

  window "$hora" "blue" "100%"
    for line in "${PRAYER[@]}"; do
      # BSC collapses truly empty appends in some versions, so use a single
      # space for blank lines to preserve paragraph spacing
      if [ -z "$line" ]; then
        append " "
      else
        append "$line"
      fi
    done
  endwin

  # ── Window 3: Commands ───────────────────────────────────────────────────

  window "Commands" "green" "100%"
    append "  [1-6]: select hora      [Enter]: refresh      [q]: quit"
    addsep
    append "  $STATUS"
  endwin
}

# ── Interactive loop ──────────────────────────────────────────────────────────

# Fetch the default hora (Prima) before showing the UI for the first time
fetch_hora "${HORAS[$SELECTED]}"

while true; do
  # Render the current state using BSC
  main_loop

  # Print the command prompt below the BSC windows (outside any window frame)
  printf "\nCommand: "

  # Read one character without requiring Enter; -s suppresses echo.
  # Timeout of 0.5s so the loop stays responsive.
  IFS= read -r -s -n1 -t 0.5 key 2>/dev/null || true

  case "$key" in
    1|2|3|4|5|6)
      # Select hora by number (1-6) and fetch it
      SELECTED=$(( key - 1 ))
      fetch_hora "${HORAS[$SELECTED]}"
      ;;
    "")
      # Enter (empty string from -n1) — refresh current hora
      fetch_hora "${HORAS[$SELECTED]}"
      ;;
    q|Q)
      clear
      echo "Finis."
      exit 0
      ;;
    # Any other key: just redraw without re-fetching
  esac
done
