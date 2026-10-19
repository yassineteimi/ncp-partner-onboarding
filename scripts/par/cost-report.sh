#!/usr/bin/env bash
#
# Report what the billed node sessions have cost so far, on every site, from
# the session log that the up and down scripts maintain.
#
# The log is a local record of when nodes were actually up, not an invoice.
# Scaleway and Verda are the authority on what was billed. This exists so that
# a window never ends with a vague sense that it was probably fine.
#

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

load_env_optional

if [ ! -f "$SESSION_LOG" ]; then
  log "no session log yet at $SESSION_LOG. No CPU worker or GPU node has been started."
else
  printf '\n  %-4s %-16s %-21s %-21s %8s  %12s\n' "site" "node" "started" "ended" "duration" "cost"
  printf '  %s\n' "------------------------------------------------------------------------------------------"

  # LC_ALL=C keeps the decimal point a point. awk follows the locale, so on a
  # machine set to French it printed 0,39 h beside EUR 0.79/h on the same line.
  LC_ALL=C awk -F, -v now="$(date -u +%s)" '
    function to_epoch(ts,   cmd, out) {
      cmd = "date -u -d \"" ts "\" +%s 2>/dev/null || date -u -j -f %Y-%m-%dT%H:%M:%SZ \"" ts "\" +%s"
      cmd | getline out
      close(cmd)
      return out + 0
    }

    NR == 1 { next }
    $2 == "" { next }

    {
      started = to_epoch($2)
      if ($3 == "") { ended = now; open_rows += 1; label = " (still up)" } else { ended = to_epoch($3); label = "" }
      hours = (ended - started) / 3600.0
      cost = hours * $6
      total[$7] += cost
      printf "  %-4s %-16s %-21s %-21s %6.2f h  %s %7.2f%s\n", $1, $4, $2, ($3 == "" ? "open" : $3), hours, $7, cost, label
    }

    END {
      printf "\n"
      for (c in total) printf "  total %s %.2f\n", c, total[c]
      if (open_rows) printf "\n  %d node(s) still up. Run the matching down target when the window is over.\n", open_rows
    }
  ' "$SESSION_LOG"
fi

cat <<EOF

  Not in the log, because they bill continuously:
    par control plane  about EUR $PAR_CONTROL_PLANE_HOURLY_EUR/h, plus its disk and IP
    par CPU worker     about EUR 0.02/h for its disk and IP while powered off
  The providers' consoles are the authority on what was actually charged.

EOF
