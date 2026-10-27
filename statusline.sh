#!/bin/bash
# Claude Code status line: https://github.com/01-1/statusline
input=$(cat)
IFS=$'\x1f' read -r cwd model effort used ctx version style dur api_dur added removed \
  tok_in tok_out hit fast rl5 rl5_at rl7 rl7_at <<<"$(echo "$input" | jq -r '[
  .workspace.current_dir // .cwd, .model.display_name, .effort.level, .context_window.used_percentage,
  (.context_window.current_usage | if . == null then null
    else (.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0) end),
  .version, .output_style.name,
  .cost.total_duration_ms, .cost.total_api_duration_ms,
  .cost.total_lines_added, .cost.total_lines_removed,
  .context_window.total_input_tokens, .context_window.total_output_tokens,
  .prompt_cache.hit_ratio, .fast_mode,
  .rate_limits.five_hour.used_percentage, .rate_limits.five_hour.resets_at,
  .rate_limits.seven_day.used_percentage, .rate_limits.seven_day.resets_at
  ] | map(if . == null then "" else tostring end) | join("\u001f")')"

dir="${cwd/#$HOME/\~}"
c() { printf '\033[38;5;%sm' "$1"; }
r=$(printf '\033[0m')

fmt_ms() {
  local s=$(( $1 / 1000 ))
  if (( s >= 86400 )); then printf '%dd%02dh' $((s / 86400)) $((s % 86400 / 3600))
  elif (( s >= 3600 )); then printf '%dh%02dm' $((s / 3600)) $((s % 3600 / 60))
  elif (( s >= 60 )); then printf '%dm%02ds' $((s / 60)) $((s % 60))
  else printf '%ds' "$s"; fi
}
fmt_tok() {
  if (( $1 >= 1000000 )); then awk -v n="$1" 'BEGIN { printf "%.1fM", n / 1000000 }'
  elif (( $1 >= 1000 )); then awk -v n="$1" 'BEGIN { printf "%.1fk", n / 1000 }'
  else printf '%d' "$1"; fi
}
onoff() { [ "$1" = true ] && printf on || printf off; }
# Green at 0% through yellow to red at 100%
used_color() {
  local g=(46 82 118 154 190 226 220 214 208 202 196) p
  p=$(printf '%.0f' "$1"); (( p < 0 )) && p=0; (( p > 100 )) && p=100
  c "${g[(p + 5) / 10]}"
}
# Purple to red as effort rises
effort_color() {
  case "$1" in
    low) c 93 ;; medium) c 177 ;; high) c 168 ;; xhigh) c 197 ;; max) c 196 ;; *) c 15 ;;
  esac
}

# "Opus 5.5" -> "O5.5"
[ -n "$model" ] && model=$(awk '{ print substr($1, 1, 1) $2 }' <<<"$model")
ctx_k=""
[ -n "$ctx" ] && ctx_k=$(awk -v n="$ctx" 'BEGIN { printf "%.0fk", n / 1000 }')

segs=()
[ -n "$model" ] && segs+=("$(c 183)${model}${effort:+ $(effort_color "$effort")$effort}")
if [ -n "$ctx_k" ] || [ -n "$used" ]; then
  uc=$(c 15); [ -n "$used" ] && uc=$(used_color "$used")
  s="$(c 8)conx ${uc}${ctx_k}"
  [ -n "$used" ] && s="$s${ctx_k:+$(c 8)/}${uc}$(printf '%.0f' "$used")%"
  segs+=("$s")
fi
now=$(date +%s)
until_reset() { [ -n "$1" ] && fmt_ms $(( $1 > now ? ($1 - now) * 1000 : 0 )); }
# Burn rate: a time-weighted EMA of %/s, kept across runs (and sessions) in a
# state file per window. Prints a 0-100 risk from (time until 100%) / (time
# until reset): 2x or more of headroom is 0, exactly on pace is 50, out is 100.
burn_risk() {
  local name=$1 at=$2 pct=$3 window=$4 tau=$5 dir=$HOME/.cache/claude-statusline
  local pat="" pt="" pp="" pe="" out
  [ -r "$dir/$name" ] && read -r pat pt pp pe < "$dir/$name"
  out=$(awk -v now="$now" -v at="$at" -v pct="$pct" -v W="$window" -v tau="$tau" \
    -v pat="$pat" -v pt="$pt" -v pp="$pp" -v pe="$pe" 'BEGIN {
    write = 1; t = now; p = pct
    if (pat == "" || at - pat > 600 || pat - at > 600) {
      el = now - (at - W); ema = el > 0 ? pct / el : 0
    } else if ((dt = now - pt) >= 60) {
      inst = (pct - pp) / dt; if (inst < 0) inst = 0
      ema = pe + (1 - exp(-dt / tau)) * (inst - pe)
    } else { ema = pe; write = 0 }
    left = at - now
    if (pct >= 100) risk = 100
    else if (ema <= 0 || left <= 0) risk = 0
    else { r = (100 - pct) / ema / left; if (r > 2) r = 2; risk = (1 - r / 2) * 100 }
    print (write ? at " " t " " p " " ema : "-"); print risk
  }')
  if [ "${out%%$'\n'*}" != "-" ]; then
    mkdir -p "$dir" && printf '%s\n' "${out%%$'\n'*}" > "$dir/$name.$$" && mv -f "$dir/$name.$$" "$dir/$name"
  fi
  printf '%s' "${out##*$'\n'}"
}
left5=$(until_reset "$rl5_at")
left7=$(until_reset "$rl7_at")
risk5=0; [ -n "$rl5" ] && [ -n "$rl5_at" ] && risk5=$(burn_risk 5h "$rl5_at" "$rl5" 18000 1800)
risk7=0; [ -n "$rl7" ] && [ -n "$rl7_at" ] && risk7=$(burn_risk 7d "$rl7_at" "$rl7" 604800 86400)
[ -n "$rl5" ] && segs+=("$(c 8)5h $(used_color "$rl5")${rl5}%${left5:+$(c 8)/$(used_color "$risk5")$left5}")
[ -n "$rl7" ] && segs+=("$(c 8)7d $(used_color "$rl7")${rl7}%${left7:+$(c 8)/$(used_color "$risk7")$left7}")

run=()
[ -n "$dur" ] && run+=("$(c 8)up $(c 183)$(fmt_ms "$dur")")
run+=("$(c 183)[$(c 177)$(date +%H:%M:%S)$(c 183)]")
[ -n "$added" ] && run+=("$(c 118)+${added} $(c 203)-${removed:-0}")
[ -n "$hit" ] && run+=("$(c 8)cache $(c 183)$(awk -v h="$hit" 'BEGIN { printf "%.0f%%", h * 100 }')")
[ -n "$api_dur" ] && run+=("$(c 8)api $(c 183)$(fmt_ms "$api_dur")")
[ -n "$tok_in" ] && run+=("$(c 8)in $(c 183)$(fmt_tok "$tok_in") $(c 8)out $(c 183)$(fmt_tok "${tok_out:-0}")")
segs+=("${run[*]}")

[ -n "$style" ] && segs+=("$(c 8)style $(c 183)${style}")
[ -n "$fast" ] && segs+=("$(c 8)fast $(c 183)$(onoff "$fast")")
[ -n "$version" ] && segs+=("$(c 8)v$(c 183)${version}")

join() { local IFS=$'\x1e'; local s="$*"; printf '%s' "${s//$'\x1e'/$(c 8), }"; }
printf '%s %s%s %s %s%s' "$(c 118)${dir}" "$(c 183)" "$(whoami)@$(hostname -s)" "$(c 8)|" "$(join "${segs[@]}")" "$r"
