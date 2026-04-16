#!/bin/zsh
# statusline.zsh — Phase A+B+C: Rows 1–4 text-parity port of statusline.sh
# No colors; sl_style is a no-op join.

emulate -L zsh
setopt pipefail no_ksh_arrays

# ── Hard runtime dependencies ────────────────────────────────────────────────
# jq ships with macOS 14+ at /usr/bin/jq. Linux users install via their
# package manager (apt/dnf/pacman/etc.). Exit 0 on missing jq so Claude Code
# renders nothing rather than an error banner; print the reason to stderr so
# anyone tailing logs sees why.
if ! command -v jq >/dev/null 2>&1; then
    print -u2 "statusline.zsh: jq not found in PATH. Install jq to enable the statusline."
    exit 0
fi

# ── Config ───────────────────────────────────────────────────────────────────
AUTOCOMPACT_BUFFER=""
DEFAULT_BRANCH=""
local _conf_file="${HOME}/.claude/statusline.conf"
[[ -f "$_conf_file" ]] && source "$_conf_file" 2>/dev/null
# Validate AUTOCOMPACT_BUFFER is numeric
if [[ -n "$AUTOCOMPACT_BUFFER" ]] && ! [[ "$AUTOCOMPACT_BUFFER" =~ ^[0-9]+$ ]]; then
    AUTOCOMPACT_BUFFER=""
fi

# ── Global state bus ─────────────────────────────────────────────────────────
typeset -gA SL=()

# ── Phase D: Global scratch vars for color pipeline ─────────────────────────
# These avoid subshell overhead and are set by helper functions.
typeset -g _sl_irp_r=0 _sl_irp_g=0 _sl_irp_b=0   # interpolate_rgb output
typeset -g _sl_styled=""                             # style_segment output
typeset -g _sl_ratio=0                               # piecewise_overflow_ratio output

# 4-stop segment palette (used by _sl_style_segment for git_seg/tool_seg/task_seg
# cycling). These are DIFFERENT from the per-bar gradient constants in sl_layout
# (SL[rate7d.grad_*] etc.) which are fill-color endpoints for individual bars.
typeset -ga _sl_pal_r=(34  96  168 217)
typeset -ga _sl_pal_g=(211 165 85  70 )
typeset -ga _sl_pal_b=(216 250 247 239)

# ── Helper: calc_fill ─────────────────────────────────────────────────────────
# Mirrors bash calc_fill. filled = (100-pct)*total/100; empty = total-filled.
# Writes SL[<prefix>.filled], SL[<prefix>.empty].
sl_calc_fill() {
    local prefix=$1
    local pct=$2
    local total=$3
    (( pct > 100 )) && pct=100
    local remaining_pct=$(( 100 - pct ))
    SL[${prefix}.filled]=$(( remaining_pct * total / 100 ))
    SL[${prefix}.empty]=$(( total - SL[${prefix}.filled] ))
}

# ── Helper: calc_suffix ───────────────────────────────────────────────────────
# Mirrors bash calc_suffix. Prints "↻ Xd Yh" / "↻ XhYm" / "↻ Xm".
# Sets SL[<key>] = suffix string (empty if no resets_at or already reset).
sl_calc_suffix() {
    local key=$1
    local resets_at=$2
    SL[$key]=""
    [[ -z "$resets_at" ]] && return
    local now_ts
    now_ts=$(date +%s)
    local remaining_secs=$(( resets_at - now_ts ))
    (( remaining_secs <= 0 )) && return
    local days=$(( remaining_secs / 86400 ))
    local hrs=$(( (remaining_secs % 86400) / 3600 ))
    local mins=$(( (remaining_secs % 3600) / 60 ))
    if (( days > 0 )); then
        SL[$key]="↻ ${days}d${hrs}h"
    elif (( hrs > 0 )); then
        SL[$key]="↻ ${hrs}h${mins}m"
    else
        SL[$key]="↻ ${mins}m"
    fi
}

# ── Helper: calc_format_tokens ───────────────────────────────────────────────
# Mirrors bash calc_format_tokens. Writes SL[<key>] = formatted string.
sl_calc_format_tokens() {
    local key=$1
    local tokens=$2
    local is_negative=false
    if (( tokens < 0 )); then
        is_negative=true
        tokens=$(( tokens * -1 ))
    fi
    local result
    if (( tokens >= 1000000 )); then
        local scaled=$(( tokens / 10000 ))
        local major=$(( scaled / 100 ))
        local minor=$(( scaled % 100 ))
        result="${major}.$(printf '%02d' $minor)M"
    elif (( tokens >= 1000 )); then
        local scaled=$(( tokens / 100 ))
        local major=$(( scaled / 10 ))
        local minor=$(( scaled % 10 ))
        result="${major}.${minor}K"
    else
        result="${tokens}"
    fi
    [[ "$is_negative" == true ]] && result="-${result}"
    SL[$key]="$result"
}

# ── Helper: calc_context_icon ────────────────────────────────────────────────
# Mirrors bash calc_context_icon.
sl_calc_context_icon() {
    local key=$1
    local pct=$2
    local remaining=$3
    if (( remaining < 0 )); then
        SL[$key]="⊙"
    elif (( pct < 20 )); then
        SL[$key]="○"
    elif (( pct < 40 )); then
        SL[$key]="◔"
    elif (( pct < 60 )); then
        SL[$key]="◑"
    elif (( pct < 80 )); then
        SL[$key]="◕"
    else
        SL[$key]="●"
    fi
}

# ── Stage 1: sl_input ────────────────────────────────────────────────────────
# Reads stdin JSON and populates SL[_raw.*].
sl_input() {
    local json
    json=$(cat)

    # Parse fields via jq (mirrors bash fetch_stdin / jq_stdin_*). If jq
    # fails here (malformed JSON, jq crash, etc.) the layout stage still
    # runs with empty state and produces empty output rather than leaking
    # jq's stderr into Claude Code's display.
    local parsed
    parsed=$(printf '%s' "$json" | jq -r '[
        (.workspace.current_dir // ""),
        (.workspace.git_worktree // ""),
        (.model.display_name // "Claude"),
        (if .context_window.current_usage then "yes" else "no" end),
        (((.context_window.current_usage.input_tokens // 0) +
          (.context_window.current_usage.cache_creation_input_tokens // 0) +
          (.context_window.current_usage.cache_read_input_tokens // 0)) | tostring),
        ((.context_window.context_window_size // 0) | tostring),
        (((.rate_limits.five_hour.used_percentage // "") | if type == "number" then floor | tostring else . end)),
        ((.rate_limits.five_hour.resets_at // "") | tostring),
        (((.rate_limits.seven_day.used_percentage // "") | if type == "number" then floor | tostring else . end)),
        ((.rate_limits.seven_day.resets_at // "") | tostring),
        (.transcript_path // ""),
        (.session.id // ""),
        ((.cost.total_cost_usd // "") | tostring),
        ((.cost.total_duration_ms // "") | tostring)
    ] | join("|")' 2>/dev/null)
    [[ -z "$parsed" ]] && return

    # Split by | into fields
    local -a fields
    IFS='|' read -rA fields <<< "$parsed"

    SL[_raw.current_dir]="${fields[1]}"
    SL[_raw.git_worktree]="${fields[2]}"
    SL[_raw.model_name]="${fields[3]}"
    SL[_raw.usage_exists]="${fields[4]}"
    SL[_raw.current_tokens]="${fields[5]}"
    SL[_raw.context_size]="${fields[6]}"
    SL[_raw.five_hour_pct]="${fields[7]}"
    SL[_raw.five_hour_resets_at]="${fields[8]}"
    SL[_raw.seven_day_pct]="${fields[9]}"
    SL[_raw.seven_day_resets_at]="${fields[10]}"
    SL[_raw.transcript_path]="${fields[11]}"
    SL[_raw.session_id]="${fields[12]}"
    SL[_raw.cost_usd]="${fields[13]}"
    SL[_raw.cost_duration_ms]="${fields[14]}"

    local current_dir="${SL[_raw.current_dir]}"
    SL[_raw.dir_name]="${current_dir##*/}"
    SL[_raw.dir_name]="${SL[_raw.dir_name]:-~}"
}

# ── Agent tokens: parse transcript ───────────────────────────────────────────
# Mirrors bash extract_agent_stats → process_agent_tokens.
sl_input_transcript() {
    local transcript_path="${SL[_raw.transcript_path]}"
    [[ -n "$transcript_path" && -f "$transcript_path" ]] || return 0

    local total_tokens=0
    local total_tool_count=0
    local stats
    stats=$(jq -r 'select(.toolUseResult.agentId) |
        "\(.toolUseResult.totalTokens // 0)\t\(.toolUseResult.totalToolUseCount // 0)"' \
        "$transcript_path" 2>/dev/null) || true

    if [[ -n "$stats" ]]; then
        local line tokens tool_count
        while IFS=$'\t' read -r tokens tool_count; do
            [[ -z "$tokens" ]] && continue
            (( total_tokens += tokens ))
            (( total_tool_count += tool_count ))
        done <<< "$stats"
    fi

    SL[_raw.agent_total_tokens]="$total_tokens"
    SL[_raw.agent_total_tool_count]="$total_tool_count"
}

# ── Stage 1d: sl_input_transcript_events ─────────────────────────────────────
# Parse tool_use/tool_result events from transcript + track task groups.
# Mirrors bash: fetch_transcript → parse_tool_events + aggregate_tools + track_tasks.
# Split into three helpers; see below. The shared parallel arrays
# (_sl_tool_order, _sl_tool_names, _sl_tool_targets, _sl_tool_results,
# _sl_tool_is_agent) are declared typeset -g[aA] in the parse helper so they
# cross into the aggregation and task-group passes.

# Run the jq extract and deserialize events into shared parallel arrays.
# Returns 1 if the transcript is missing or yields no events (caller should
# short-circuit the downstream passes).
_sl_parse_transcript_events() {
    # Always initialise the shared parallel arrays so the downstream stages
    # can safely iterate even when the transcript is missing, unreadable, or
    # partially parsed. This is what prevents the TOOLS and TASKS rows from
    # disappearing during long-running MCP tool calls — a transient jq
    # failure no longer wipes the rest of the pipeline.
    typeset -gA _sl_tool_results=()
    typeset -gA _sl_tool_names=()
    typeset -gA _sl_tool_targets=()
    typeset -gA _sl_tool_is_agent=()
    typeset -ga _sl_tool_order=()

    local transcript_path="${SL[_raw.transcript_path]}"
    [[ -n "$transcript_path" && -f "$transcript_path" ]] || return 0

    # Per-line parse: slurp the file as raw text, split on newlines, and
    # let each line parse independently via `try fromjson catch empty`.
    # A truncated mid-write line, a rewritten file mid-read, or a single
    # malformed event no longer aborts the whole extract — valid events
    # keep flowing through.
    local transcript_data
    transcript_data=$(jq --raw-input --slurp --raw-output '
        split("\n")
        | map(select(length > 0) | . as $line | try fromjson catch empty)
        | .[]
        | .message.content[]?
        | if .type == "tool_use" then
              .name as $name |
              .id as $id |
              (
                  if $name == "TaskUpdate" then
                      [(.input.taskId // ""), (.input.status // "")] | join(":")
                  elif $name == "TaskCreate" then
                      .input.subject // ""
                  elif .input.file_path then .input.file_path | split("/") | last
                  elif .input.command then (.input.command | split("\n") | first | .[0:40])
                  elif .input.pattern then .input.pattern
                  elif .input.prompt then (.input.prompt | .[0:30])
                  else ""
                  end
              ) as $target |
              "use\t\($id)\t\($name)\t\($target)"
          elif .type == "tool_result" then
              "result\t\(.tool_use_id)\t\(.is_error // false)"
          else empty end
    ' "$transcript_path" 2>/dev/null) || true

    [[ -n "$transcript_data" ]] || return 0

    local ttype tid tfield1 tfield2
    while IFS=$'\t' read -r ttype tid tfield1 tfield2; do
        if [[ "$ttype" == "result" ]]; then
            _sl_tool_results[$tid]="$tfield1"
        elif [[ "$ttype" == "use" ]]; then
            _sl_tool_names[$tid]="$tfield1"
            _sl_tool_targets[$tid]="$tfield2"
            _sl_tool_order+=("$tid")
            [[ "$tfield1" == "Agent" ]] && _sl_tool_is_agent[$tid]=1
        fi
    done <<< "$transcript_data"
}

# Aggregate tool counts into SL[_raw.tools.*]. Consumes the parallel arrays
# populated by _sl_parse_transcript_events.
_sl_aggregate_tool_states() {
    typeset -gA _sl_completed_counts=()
    local _running_tool_name="" _running_tool_target="" _running_agents=""

    local _id _name _target
    for _id in "${_sl_tool_order[@]}"; do
        _name="${_sl_tool_names[$_id]}"
        _target="${_sl_tool_targets[$_id]}"

        if [[ -z "${_sl_tool_results[$_id]+x}" ]]; then
            # No result yet — running
            if [[ -n "${_sl_tool_is_agent[$_id]+x}" ]]; then
                _running_agents="${_running_agents}${_target:0:30}|"
            else
                _running_tool_name="$_name"
                _running_tool_target="$_target"
            fi
        else
            # Completed — exclude task-related tools
            case "$_name" in
                TaskCreate|TaskUpdate|TaskGet|TaskList|TaskOutput|TaskStop|TaskAwait) ;;
                *) _sl_completed_counts[$_name]=$(( ${_sl_completed_counts[$_name]:-0} + 1 )) ;;
            esac
        fi
    done

    # Sort completed counts ascending and build "name:count|..." string
    local _counts_str="" _total=0
    local _sorted_counts _n
    _sorted_counts=$(
        for _n in "${(@k)_sl_completed_counts}"; do
            printf '%d\t%s\n' "${_sl_completed_counts[$_n]}" "$_n"
        done | sort -n
    )
    local _cnt _nm
    while IFS=$'\t' read -r _cnt _nm; do
        [[ -z "$_nm" ]] && continue
        _counts_str="${_counts_str}${_nm}:${_cnt}|"
        (( _total += _cnt ))
    done <<< "$_sorted_counts"

    # Add subagent internal tool counts to total
    local _agent_tool_total="${SL[_raw.agent_total_tool_count]:-0}"
    (( _total += _agent_tool_total ))

    SL[_raw.tools.total_count]="$_total"
    SL[_raw.tools.completed_counts]="$_counts_str"
    SL[_raw.tools.running_name]="$_running_tool_name"
    SL[_raw.tools.running_target]="$_running_tool_target"
    SL[_raw.tools.running_agents]="$_running_agents"
}

# Replay Task* events to reconstruct the current task group state and fill
# SL[_raw.tasks.*]. Consumes the same parallel arrays populated above.
_sl_build_task_group_state() {
    # Task group state — declare ALL loop-internal locals here to avoid zsh
    # printing previous values when re-declaring inside a loop body.
    local _tg_total=0 _tg_total_all=0 _tg_completed_all=0 _tg_group_offset=0
    local _ename="" _edata="" _all_terminal="" _gi=0 _gstatus=""
    local _update_id="" _update_status="" _adjusted_id=0 _prev=""
    local _id
    typeset -A _tg_status=()
    typeset -a _tg_names=()

    # Process events in order (replay_task_events)
    for _id in "${_sl_tool_order[@]}"; do
        _ename="${_sl_tool_names[$_id]}"
        _edata="${_sl_tool_targets[$_id]}"

        if [[ "$_ename" == "TaskCreate" ]]; then
            # assign_to_group "create": check if current group is terminal
            if (( _tg_total > 0 )); then
                _all_terminal=true
                for (( _gi=1; _gi<=_tg_total; _gi++ )); do
                    _gstatus="${_tg_status[$_gi]:-pending}"
                    if [[ "$_gstatus" != "completed" && "$_gstatus" != "deleted" ]]; then
                        _all_terminal=false
                        break
                    fi
                done
                if [[ "$_all_terminal" == "true" ]]; then
                    (( _tg_group_offset += _tg_total ))
                    _tg_total=0
                    _tg_status=()
                    _tg_names=()
                fi
            fi
            (( _tg_total++ ))
            (( _tg_total_all++ ))
            [[ -n "$_edata" ]] && _tg_names+=("$_edata")
            _tg_status[$_tg_total]="pending"

        elif [[ "$_ename" == "TaskUpdate" ]]; then
            # assign_to_group "update"
            _update_id="${_edata%%:*}"
            _update_status="${_edata#*:}"
            if [[ -n "$_update_id" && -n "$_update_status" ]]; then
                _adjusted_id=$(( _update_id - _tg_group_offset ))
                if (( _adjusted_id >= 1 && _adjusted_id <= _tg_total )); then
                    _prev="${_tg_status[$_adjusted_id]:-pending}"
                    _tg_status[$_adjusted_id]="$_update_status"
                    if [[ "$_update_status" == "completed" && "$_prev" != "completed" ]]; then
                        (( _tg_completed_all++ ))
                    fi
                fi
            fi
        fi
    done

    SL[_raw.tasks.group_total]="$_tg_total"
    SL[_raw.tasks.total_all]="$_tg_total_all"
    SL[_raw.tasks.completed_all]="$_tg_completed_all"

    local _i=0 _names_str="" _n=""
    for (( _i=1; _i<=_tg_total; _i++ )); do
        SL[_raw.tasks.status_${_i}]="${_tg_status[$_i]:-pending}"
    done
    for _n in "${_tg_names[@]}"; do
        _names_str="${_names_str}${_n}|"
    done
    SL[_raw.tasks.names]="$_names_str"
}

sl_input_transcript_events() {
    # Always run every stage. _sl_parse_transcript_events guarantees the
    # shared parallel arrays are initialised even when the transcript
    # cannot be parsed, so aggregation and task-group replay degrade to
    # "no tools, no tasks" instead of wiping the whole SL[_raw.tools.*]
    # and SL[_raw.tasks.*] namespaces out from under sl_build_tools /
    # sl_build_tasks.
    _sl_parse_transcript_events
    _sl_aggregate_tool_states
    _sl_build_task_group_state
}

# ── Stage 2: sl_build ────────────────────────────────────────────────────────

# Build: model name segment
sl_build_model() {
    SL[model.text]="${SL[_raw.model_name]}"
    SL[model.visible]=true
}

# _sl_build_rate <seg> <pct_key> <resets_key> <window_secs> <segments> <badge>
# Shared engine for sl_build_rate7d / sl_build_rate5h. Mirrors process_rate +
# calc_fill + calc_suffix. <seg> is the public namespace prefix (e.g. rate7d);
# the internal calc_fill prefix is _<seg>.
_sl_build_rate() {
    local seg=$1 pct_key=$2 resets_key=$3 window_secs=$4 segments=$5 badge=$6
    local resets_at="${SL[$resets_key]}"
    local pct="${SL[$pct_key]}"

    # Time-based pct override (mirrors process_rate)
    if [[ -n "$resets_at" && "$resets_at" -gt 0 ]] 2>/dev/null; then
        local now_ts
        now_ts=$(date +%s)
        local remaining_secs=$(( resets_at - now_ts ))
        if (( remaining_secs <= 0 )); then
            pct=100
        else
            pct=$(( (window_secs - remaining_secs) * 100 / window_secs ))
            (( pct < 0 )) && pct=0
            (( pct > 100 )) && pct=100
        fi
    fi

    [[ -n "$pct" ]] || return 0
    (( pct >= 0 )) 2>/dev/null || return 0

    SL[${seg}.visible]=true
    SL[${seg}.pct]="$pct"
    SL[${seg}.badge_text]="$badge"

    sl_calc_fill "_${seg}" "$pct" "$segments"
    SL[${seg}.filled]="${SL[_${seg}.filled]}"
    SL[${seg}.empty]="${SL[_${seg}.empty]}"

    sl_calc_suffix "_${seg}.suffix" "$resets_at"
    SL[${seg}.suffix]="${SL[_${seg}.suffix]}"
}

# Build: 7d rate bar — mirrors process_rate + calc_fill + calc_suffix
sl_build_rate7d() {
    _sl_build_rate rate7d _raw.seven_day_pct _raw.seven_day_resets_at 604800 7 "7d"
}

# Build: 5h rate bar — mirrors process_rate
sl_build_rate5h() {
    _sl_build_rate rate5h _raw.five_hour_pct _raw.five_hour_resets_at 18000 10 "5h"
}

# Build: context window bar — mirrors process_context
sl_build_context() {
    [[ "${SL[_raw.usage_exists]}" == "yes" ]] || return 0
    local size="${SL[_raw.context_size]}"
    (( size > 0 )) 2>/dev/null || return 0

    local usable_limit
    local autocompact="${AUTOCOMPACT_BUFFER:-}"
    if [[ -n "$autocompact" ]] && (( autocompact > 0 )) 2>/dev/null; then
        usable_limit=$(( size - autocompact ))
    else
        usable_limit=$size
    fi

    local current="${SL[_raw.current_tokens]}"
    local remaining=$(( usable_limit - current ))
    local pct=$(( current * 100 / usable_limit ))
    (( pct > 150 )) && pct=150

    SL[context.pct]="$pct"
    SL[context.remaining]="$remaining"
    SL[context.visible]=true

    sl_calc_format_tokens "context.remaining_formatted" "$remaining"
    sl_calc_context_icon "context.icon" "$pct" "$remaining"

    local segments=10
    if (( remaining < 0 )); then
        local overflow_pct=$(( pct - 100 ))
        local gradient_count=$(( overflow_pct * segments / 25 ))
        (( gradient_count > segments )) && gradient_count=$segments
        SL[context.filled]="$gradient_count"
        SL[context.empty]=$(( segments - gradient_count ))
        SL[context.overflow]=true
    else
        sl_calc_fill "_ctx" "$pct" "$segments"
        SL[context.filled]="${SL[_ctx.filled]}"
        SL[context.empty]="${SL[_ctx.empty]}"
        SL[context.overflow]=false
    fi

    SL[context.badge_text]="${SL[context.icon]}"
    SL[context.suffix]="↻ ${SL[context.remaining_formatted]}"
}

# Build: agent tokens — mirrors process_agent_tokens
sl_build_agent_tokens() {
    local total="${SL[_raw.agent_total_tokens]:-0}"
    (( total > 0 )) 2>/dev/null || return 0
    SL[agent_tokens.visible]=true
    sl_calc_format_tokens "agent_tokens.formatted" "$total"
}

# Build: cost — mirrors process_cost
sl_build_cost() {
    local cost_usd="${SL[_raw.cost_usd]}"
    [[ -n "$cost_usd" && "$cost_usd" != "0" ]] || return 0
    SL[cost.visible]=true
    SL[cost.formatted]=$(LC_ALL=C printf "%.2f" "$cost_usd" 2>/dev/null || printf '%s' "$cost_usd")
}

# ── Stage 1b: sl_input_git ───────────────────────────────────────────────────
# Fetches branch, sync, changes, ancestry — mirrors fetch_git_branch/sync/changes/ancestry.
sl_input_git() {
    local dir="${SL[_raw.current_dir]}"
    [[ -z "$dir" ]] && return

    # branch + upstream (mirrors fetch_git_branch)
    local _git_info
    _git_info=$(git -C "$dir" rev-parse --git-dir --abbrev-ref HEAD --abbrev-ref "@{upstream}" 2>/dev/null)
    [[ -z "$_git_info" ]] && return

    local _git_dir _branch _upstream
    { read -r _git_dir; read -r _branch; read -r _upstream; } <<< "$_git_info"
    [[ -z "$_git_dir" ]] && return

    SL[_raw.git.is_repo]=true
    SL[_raw.git.branch]="$_branch"
    SL[_raw.git.upstream_ref]="$_upstream"

    # default branch (mirrors fetch_git_branch: DEFAULT_BRANCH config or symbolic-ref)
    local _symref
    _symref=$(git -C "$dir" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null)
    if [[ -n "$DEFAULT_BRANCH" ]]; then
        SL[_raw.git.default_branch]="$DEFAULT_BRANCH"
    elif [[ -n "$_symref" ]]; then
        SL[_raw.git.default_branch]="${_symref#refs/remotes/origin/}"
    else
        SL[_raw.git.default_branch]=""
    fi

    # sync: ahead/behind (mirrors fetch_git_sync)
    local _rev_counts=""
    if [[ -n "$_upstream" ]]; then
        _rev_counts=$(git -C "$dir" --no-optional-locks rev-list --left-right --count "HEAD...@{upstream}" 2>/dev/null)
    else
        local _default_branch="${SL[_raw.git.default_branch]}"
        local _main_ref=""
        for _mb in "$_default_branch" develop main master; do
            [[ -z "$_mb" ]] && continue
            git -C "$dir" --no-optional-locks rev-parse --verify "origin/$_mb" >/dev/null 2>&1 && _main_ref="origin/$_mb" && break
        done
        [[ -n "$_main_ref" ]] && _rev_counts=$(git -C "$dir" --no-optional-locks rev-list --left-right --count "HEAD...$_main_ref" 2>/dev/null)
    fi
    if [[ -n "$_rev_counts" ]]; then
        local _ahead _behind
        read -r _ahead _behind <<< "$_rev_counts"
        SL[_raw.git.ahead]="$_ahead"
        SL[_raw.git.behind]="$_behind"
    fi
    SL[_raw.git.ahead]="${SL[_raw.git.ahead]:-0}"
    SL[_raw.git.behind]="${SL[_raw.git.behind]:-0}"

    # changes: added/deleted/changed (mirrors fetch_git_changes)
    local _numstat
    _numstat=$(git -C "$dir" --no-optional-locks diff --numstat HEAD 2>/dev/null)
    local _added=0 _deleted=0 _changed=0
    if [[ -n "$_numstat" ]]; then
        read -r _added _deleted _changed < <(
            printf '%s\n' "$_numstat" | awk '
                $1 != "-" && $2 != "-" { a+=$1; d+=$2; if($1>0||$2>0) c++ }
                END { print a+0, d+0, c+0 }
            '
        )
    fi
    SL[_raw.git.added]="${_added:-0}"
    SL[_raw.git.deleted]="${_deleted:-0}"
    SL[_raw.git.changed]="${_changed:-0}"

    # conflict detection (purely local — no network required)
    # 1. Active conflict: MERGE_HEAD, rebase in progress, or unmerged index entries
    # 2. Predictive: git merge-tree --write-tree (in-memory merge, no working tree changes)
    SL[_raw.git.conflict]=false
    local _git_dir_abs
    _git_dir_abs=$(git -C "$dir" rev-parse --git-dir 2>/dev/null)
    if [[ -n "$_git_dir_abs" ]]; then
        [[ "$_git_dir_abs" == /* ]] || _git_dir_abs="${dir}/${_git_dir_abs}"
        if [[ -f "${_git_dir_abs}/MERGE_HEAD" ]] || \
           [[ -d "${_git_dir_abs}/rebase-merge" ]] || \
           [[ -d "${_git_dir_abs}/rebase-apply" ]]; then
            SL[_raw.git.conflict]=true
        elif [[ -n "$(git -C "$dir" --no-optional-locks ls-files --unmerged 2>/dev/null)" ]]; then
            SL[_raw.git.conflict]=true
        fi
    fi
    # predictive conflict: merge-tree against default branch (only when behind)
    if [[ "${SL[_raw.git.conflict]}" != "true" ]]; then
        local _behind="${SL[_raw.git.behind]:-0}"
        if (( _behind > 0 )); then
            local _default_branch="${SL[_raw.git.default_branch]}"
            local _merge_target=""
            for _mb in "$_default_branch" develop main master; do
                [[ -z "$_mb" ]] && continue
                git -C "$dir" --no-optional-locks rev-parse --verify "origin/$_mb" >/dev/null 2>&1 && _merge_target="origin/$_mb" && break
            done
            if [[ -n "$_merge_target" ]]; then
                if ! git -C "$dir" merge-tree --write-tree HEAD "$_merge_target" >/dev/null 2>&1; then
                    SL[_raw.git.conflict]=true
                fi
            fi
        fi
    fi

    # ancestry: based_off (mirrors fetch_git_ancestry)
    local _branch="${SL[_raw.git.branch]}"
    local _default_branch="${SL[_raw.git.default_branch]}"
    SL[_raw.git.based_off]=""
    if [[ -n "$_branch" && "$_branch" != "$_default_branch" ]]; then
        local _reflog
        _reflog=$(git -C "$dir" reflog show "$_branch" --format="%gs" 2>/dev/null)
        local _creation_entry
        _creation_entry=$(printf '%s\n' "$_reflog" | tail -1)
        local _based_off=""
        if [[ "$_creation_entry" == *"Created from refs/heads/"* ]]; then
            _based_off="${_creation_entry#*Created from refs/heads/}"
        elif [[ "$_creation_entry" == *"Created from HEAD"* ]]; then
            local _branch_to_search="$_branch"
            local _rename_entry
            _rename_entry=$(printf '%s\n' "$_reflog" | grep -i "renamed" | head -1)
            if [[ -n "$_rename_entry" ]]; then
                local _old_name
                _old_name=$(printf '%s\n' "$_rename_entry" | sed 's/.*renamed refs\/heads\/\(.*\) to .*/\1/')
                [[ -n "$_old_name" ]] && _branch_to_search="$_old_name"
            fi
            _based_off=$(git -C "$dir" reflog --format="%gs" 2>/dev/null | grep -E "checkout: moving from .* to ${_branch_to_search}$" | tail -1 | sed 's/checkout: moving from \(.*\) to .*/\1/')
        else
            # Standard checkout entry: "checkout: moving from <base> to <branch>"
            _based_off=$(printf '%s\n' "$_creation_entry" | sed -n 's/checkout: moving from \(.*\) to .*/\1/p')
        fi
        SL[_raw.git.based_off]="$_based_off"
    fi
}

# ── Stage 1c: sl_input_pr ─────────────────────────────────────────────────────
# Fetches PR data via gh — mirrors fetch_pr.
sl_input_pr() {
    [[ "${SL[_raw.git.is_repo]:-}" == "true" ]] || return
    local _branch="${SL[_raw.git.branch]}"
    local _default_branch="${SL[_raw.git.default_branch]}"
    local _dir="${SL[_raw.current_dir]}"

    [[ -n "$_branch" ]] || return
    [[ "$_branch" != "$_default_branch" ]] || return

    # Only fetch if branch is pushed to remote (mirrors fetch_pr)
    git -C "$_dir" rev-parse --verify "origin/$_branch" >/dev/null 2>&1 || return

    local _pr_json
    _pr_json=$(cd "$_dir" && gh pr view --json number,isDraft,mergeable,reviewDecision,statusCheckRollup,comments 2>/dev/null)
    [[ -z "$_pr_json" ]] && return

    # Parse fields (mirrors jq_pr_fields)
    local _parsed
    _parsed=$(printf '%s' "$_pr_json" | jq -r '[
        .number,
        .isDraft,
        .mergeable,
        (.reviewDecision // ""),
        (.comments | length),
        (.statusCheckRollup | length),
        ([.statusCheckRollup[]? | select(.conclusion == "SUCCESS")] | length),
        ([.statusCheckRollup[]? | select(.conclusion == "FAILURE")] | length),
        ([.statusCheckRollup[]? | select(.status != "COMPLETED")] | length)
    ] | join("|")')

    local -a _fields
    IFS='|' read -rA _fields <<< "$_parsed"

    SL[_raw.pr.number]="${_fields[1]}"
    SL[_raw.pr.is_draft]="${_fields[2]}"
    SL[_raw.pr.mergeable]="${_fields[3]}"
    SL[_raw.pr.review_decision]="${_fields[4]}"
    SL[_raw.pr.comments_count]="${_fields[5]}"
    SL[_raw.pr.checks_total]="${_fields[6]}"
    SL[_raw.pr.checks_success]="${_fields[7]}"
    SL[_raw.pr.checks_failure]="${_fields[8]}"
    SL[_raw.pr.checks_pending]="${_fields[9]}"

    # skipped = total - success - failure - pending
    local _skipped=$(( SL[_raw.pr.checks_total] - SL[_raw.pr.checks_success] - SL[_raw.pr.checks_failure] - SL[_raw.pr.checks_pending] ))
    (( _skipped < 0 )) && _skipped=0
    SL[_raw.pr.checks_skipped]="$_skipped"

    [[ "${SL[_raw.pr.number]}" == "null" ]] && { SL[_raw.pr.number]=""; return; }
}

# ── Build: tools row ─────────────────────────────────────────────────────────
# Mirrors bash process_tools. Just passes raw data through for layout.
sl_build_tools() {
    local _total="${SL[_raw.tools.total_count]:-0}"
    (( _total > 0 )) 2>/dev/null || return 0
    SL[tools.visible]=true
    SL[tools.total_count]="$_total"
    SL[tools.completed_counts]="${SL[_raw.tools.completed_counts]}"
    SL[tools.running_name]="${SL[_raw.tools.running_name]}"
    SL[tools.running_target]="${SL[_raw.tools.running_target]}"
}

# ── Build: tasks row ──────────────────────────────────────────────────────────
# Mirrors bash process_tasks_and_agents + count_by_status + find_* helpers.
sl_build_tasks() {
    local _nl=$'\n'
    local _group_total="${SL[_raw.tasks.group_total]:-0}"
    local _agent_count=0

    # Count running agents (mirrors process_tasks_and_agents agent_count logic)
    local _agents="${SL[_raw.tools.running_agents]:-}"
    if [[ -n "$_agents" ]]; then
        local _adesc
        while IFS='|' read -r _adesc; do
            [[ -z "$_adesc" ]] && continue
            (( _agent_count++ ))
        done <<< "${_agents//|/${_nl}}"
    fi

    (( _group_total > 0 || _agent_count > 0 )) || return 0
    SL[tasks.visible]=true
    SL[tasks.total_all]="${SL[_raw.tasks.total_all]:-0}"
    SL[tasks.completed_all]="${SL[_raw.tasks.completed_all]:-0}"
    SL[tasks.running_agents]="$_agents"
    SL[tasks.agent_count]="$_agent_count"

    # count_by_status for active group — declare all loop-internal locals upfront
    local _completed=0 _in_progress=0 _pending=0
    local _i=0 _st="" _ni=0 _nval=""
    for (( _i=1; _i<=_group_total; _i++ )); do
        _st="${SL[_raw.tasks.status_${_i}]:-pending}"
        case "$_st" in
            completed)   (( _completed++ )) ;;
            in_progress) (( _in_progress++ )) ;;
            deleted)     ;;
            *)           (( _pending++ )) ;;
        esac
    done
    SL[tasks.completed]="$_completed"
    SL[tasks.in_progress]="$_in_progress"
    SL[tasks.pending]="$_pending"

    # find_last_completed: last completed task's name
    local _names="${SL[_raw.tasks.names]:-}"
    local -a _name_arr=()
    local _n=""
    while IFS='|' read -r _n; do
        _name_arr+=("$_n")
    done <<< "${_names//|/${_nl}}"

    local _last_completed="" _in_progress_name="" _first_pending=""
    for (( _i=1; _i<=_group_total; _i++ )); do
        _st="${SL[_raw.tasks.status_${_i}]:-pending}"
        _nval="${_name_arr[$_i]:-}"   # zsh arrays are 1-based; task _i → index _i
        if [[ "$_st" == "completed" && -n "$_nval" ]]; then
            _last_completed="$_nval"
        fi
    done
    # find_in_progress: first in_progress
    for (( _i=1; _i<=_group_total; _i++ )); do
        _st="${SL[_raw.tasks.status_${_i}]:-pending}"
        _nval="${_name_arr[$_i]:-}"
        if [[ "$_st" == "in_progress" && -n "$_nval" ]]; then
            _in_progress_name="$_nval"
            break
        fi
    done
    # find_first_pending: first non-completed non-deleted non-in_progress
    for (( _i=1; _i<=_group_total; _i++ )); do
        _st="${SL[_raw.tasks.status_${_i}]:-pending}"
        _nval="${_name_arr[$_i]:-}"
        if [[ "$_st" != "completed" && "$_st" != "deleted" && "$_st" != "in_progress" && -n "$_nval" ]]; then
            _first_pending="$_nval"
            break
        fi
    done

    SL[tasks.last_completed_name]="$_last_completed"
    SL[tasks.in_progress_name]="$_in_progress_name"
    SL[tasks.first_pending_name]="$_first_pending"
}

# ── Segment list ─────────────────────────────────────────────────────────────
typeset -ga SL_SEGMENTS=(model rate7d rate5h context agent_tokens cost)
typeset -ga SL_REPO_SEGMENTS=(project branch worktree pr_number pr_state pr_review pr_comments git_sync pr_mergeable pr_checks git_dirty)

# ── Row order ────────────────────────────────────────────────────────────────
# Single source of truth for which rows exist and their display/priority order.
# Edit this array (or override it before `sl_layout` runs) to add, remove, or
# re-order rows. Each name XYZ implies a helper `_sl_layout_XYZ` that populates
# the parallel arrays _SL_<UPPERCASE>_TEXTS/ROLES/METAS/LINKS.
#
#   - Index 1 is the irreducible-minimum row: it is NEVER removed by
#     sl_layout_responsive under budget pressure (currently `meta`).
#   - Indexes 2..N are removable in reverse-index order when the 6-line
#     budget is exceeded (last element → first to go).
typeset -ga SL_LAYOUT_ORDER=(meta repo tools tasks)

sl_run_build() {
    sl_input_transcript
    sl_input_transcript_events
    sl_input_git
    sl_input_pr
    local seg
    for seg in "${SL_SEGMENTS[@]}"; do
        sl_build_${seg}
    done
    for seg in "${SL_REPO_SEGMENTS[@]}"; do
        sl_build_repo_${seg}
    done
    sl_build_tools
    sl_build_tasks
}

# ── Stage 2b: repo segment builders ──────────────────────────────────────────

# Build: project name
sl_build_repo_project() {
    [[ "${SL[_raw.git.is_repo]:-}" == "true" ]] || return
    SL[repo.project.text]="${SL[_raw.dir_name]}"
    SL[repo.project.visible]=true
}

# Build: branch name (mirrors _seg_render_branch)
sl_build_repo_branch() {
    [[ "${SL[_raw.git.is_repo]:-}" == "true" ]] || return
    local _branch="${SL[_raw.git.branch]}"
    [[ -n "$_branch" ]] || return

    local _default_branch="${SL[_raw.git.default_branch]}"
    local _based_off="${SL[_raw.git.based_off]}"
    local _text
    if [[ "$_branch" == "$_default_branch" ]]; then
        _text=" ${_branch}"
    elif [[ -n "$_based_off" && "$_based_off" != "$_default_branch" && "$_based_off" != "$_branch" ]]; then
        _text=" ⎇ ${_based_off} ⎇ ${_branch}"
    else
        _text=" ⎇ ${_branch}"
    fi
    SL[repo.branch.text]="$_text"
    SL[repo.branch.visible]=true
}

# Build: worktree indicator (mirrors process_git worktree heuristic)
sl_build_repo_worktree() {
    [[ "${SL[_raw.git.is_repo]:-}" == "true" ]] || return
    local _wt="${SL[_raw.git_worktree]}"
    local _branch="${SL[_raw.git.branch]}"
    [[ -n "$_wt" ]] || return
    # Hide if worktree name is a substring of the branch name
    [[ "$_branch" == *"$_wt"* ]] && return
    SL[repo.worktree.text]=" ⎇ ${_wt}"
    SL[repo.worktree.visible]=true
}

# Build: PR number
sl_build_repo_pr_number() {
    local _num="${SL[_raw.pr.number]:-}"
    [[ -n "$_num" ]] || return
    SL[repo.pr_number.text]=" #${_num}"
    SL[repo.pr_number.visible]=true
}

# Build: PR state (draft indicator)
sl_build_repo_pr_state() {
    local _num="${SL[_raw.pr.number]:-}"
    [[ -n "$_num" ]] || return
    if [[ "${SL[_raw.pr.is_draft]}" == "true" ]]; then
        SL[repo.pr_state.text]=" ✎"
        SL[repo.pr_state.visible]=true
    fi
    # non-draft: visible but empty — omit (bash layout skips empty renders)
}

# Build: PR review decision
sl_build_repo_pr_review() {
    local _num="${SL[_raw.pr.number]:-}"
    [[ -n "$_num" ]] || return
    local _decision="${SL[_raw.pr.review_decision]:-}"
    [[ -n "$_decision" ]] || return
    local _text=""
    case "$_decision" in
        APPROVED)           _text=" ✓" ;;
        CHANGES_REQUESTED)  _text=" ✗" ;;
        REVIEW_REQUIRED)    _text=" ⋯" ;;
        *)                  return ;;
    esac
    SL[repo.pr_review.text]="$_text"
    SL[repo.pr_review.visible]=true
}

# Build: PR comments
sl_build_repo_pr_comments() {
    local _num="${SL[_raw.pr.number]:-}"
    [[ -n "$_num" ]] || return
    local _cnt="${SL[_raw.pr.comments_count]:-0}"
    (( _cnt > 0 )) 2>/dev/null || return
    SL[repo.pr_comments.text]=" ✉ ${_cnt}"
    SL[repo.pr_comments.visible]=true
}

# Build: git sync (ahead/behind)
sl_build_repo_git_sync() {
    [[ "${SL[_raw.git.is_repo]:-}" == "true" ]] || return
    local _a="${SL[_raw.git.ahead]:-0}" _b="${SL[_raw.git.behind]:-0}"
    (( _a > 0 || _b > 0 )) 2>/dev/null || return
    local _text=""
    (( _a > 0 )) && _text="${_text} ↑${_a}"
    (( _b > 0 )) && _text="${_text} ↓${_b}"
    SL[repo.git_sync.text]="$_text"
    SL[repo.git_sync.visible]=true
}

# Build: PR mergeable / local conflict
# Fires when GitHub reports CONFLICTING *or* when a local merge/rebase/unmerged
# state is detected — whichever is available first.  The local check means the
# indicator appears even without a PR open or when gh is unreachable.
sl_build_repo_pr_mergeable() {
    local _show=false
    [[ "${SL[_raw.pr.mergeable]:-}" == "CONFLICTING" ]] && _show=true
    [[ "${SL[_raw.git.conflict]:-}" == "true" ]]        && _show=true
    [[ "$_show" == "true" ]] || return
    SL[repo.pr_mergeable.text]=" ⚠"
    SL[repo.pr_mergeable.visible]=true
}

# Build: PR checks
sl_build_repo_pr_checks() {
    local _num="${SL[_raw.pr.number]:-}"
    [[ -n "$_num" ]] || return
    local _total="${SL[_raw.pr.checks_total]:-0}"
    (( _total > 0 )) 2>/dev/null || return

    local _pending="${SL[_raw.pr.checks_pending]:-0}"
    local _failure="${SL[_raw.pr.checks_failure]:-0}"
    local _success="${SL[_raw.pr.checks_success]:-0}"
    local _text=""
    # Pure success: compact ✓N
    if (( _pending == 0 && _failure == 0 && _success > 0 )); then
        _text=" ✓${_success}"
    else
        (( _pending > 0 )) && _text="${_text} ○${_pending}"
        (( _failure > 0 )) && _text="${_text} ✗${_failure}"
        (( _success > 0 )) && _text="${_text} ✓${_success}"
    fi
    [[ -z "$_text" ]] && return
    SL[repo.pr_checks.text]="$_text"
    SL[repo.pr_checks.visible]=true
}

# Build: git dirty (added/deleted/changed files)
sl_build_repo_git_dirty() {
    [[ "${SL[_raw.git.is_repo]:-}" == "true" ]] || return
    local _a="${SL[_raw.git.added]:-0}" _d="${SL[_raw.git.deleted]:-0}" _c="${SL[_raw.git.changed]:-0}"
    (( _a > 0 || _d > 0 || _c > 0 )) 2>/dev/null || return
    local _text=""
    (( _a > 0 )) && _text="${_text} +${_a}"
    (( _d > 0 )) && _text="${_text} -${_d}"
    (( _c > 0 )) && _text="${_text} ~${_c}"
    SL[repo.git_dirty.text]="$_text"
    SL[repo.git_dirty.visible]=true
}

# ── Stage 3: sl_layout ───────────────────────────────────────────────────────
# Parallel arrays per row: texts, roles, metas, links.
# Row suffixes: META, REPO, TOOLS, TASKS.
# _SL_{ROW}_TEXTS  — text content
# _SL_{ROW}_ROLES  — styling role
# _SL_{ROW}_METAS  — meta reference (proc name for bars, index for git/tool/task)
# _SL_{ROW}_LINKS  — OSC 8 URL (empty if none)

# Helper: push one entry to a row's parallel arrays.
# Usage: _sl_push_seg <ROW> <text> <role> [meta] [link]
_sl_push_seg() {
    local row=$1 text=$2 role=$3 meta=${4:-""} link=${5:-""}
    [[ -n "$text" ]] || return 0
    eval "_SL_${row}_TEXTS+=(\"\$text\")"
    eval "_SL_${row}_ROLES+=(\"\$role\")"
    eval "_SL_${row}_METAS+=(\"\$meta\")"
    eval "_SL_${row}_LINKS+=(\"\$link\")"
}

# Compose bar segments into parallel arrays.
# Mirrors bash compose_bar_segments: spacer + filled + badge + empty+suffix.
# Stores proc data needed by color functions into SL[<proc>.color.*].
_sl_compose_bar_segs() {
    local seg=$1   # e.g. "rate7d" → proc prefix
    local row=$2   # ROW name e.g. META
    [[ "${SL[${seg}.visible]:-}" == "true" ]] || return 0

    local filled_n="${SL[${seg}.filled]}"
    local empty_n="${SL[${seg}.empty]}"
    local badge="${SL[${seg}.badge_text]}"
    local suffix="${SL[${seg}.suffix]:-}"

    # Build filled chars
    local filled_text="" i
    for (( i=0; i<filled_n; i++ )); do filled_text="${filled_text}█"; done

    # Build empty chars
    local empty_text=""
    for (( i=0; i<empty_n; i++ )); do empty_text="${empty_text}▁"; done

    # Spacer
    _sl_push_seg "$row" " " "spacer" "" ""

    # Filled (only if non-empty)
    if [[ -n "$filled_text" ]]; then
        _sl_push_seg "$row" "$filled_text" "bar_filled" "$seg" ""
    fi

    # Badge
    _sl_push_seg "$row" " ${badge} " "bar_badge" "$seg" ""

    # Empty + suffix
    if [[ -n "$empty_text" || -n "$suffix" ]]; then
        local tail="${empty_text}"
        [[ -n "$suffix" ]] && tail="${tail} ${suffix} "
        _sl_push_seg "$row" "$tail" "bar_empty" "$seg" ""
    fi
}

# Initialise parallel arrays and reset shrink-phase state. Also seeds the
# per-bar gradient constants used by the style stage (kept in SL[<bar>.grad_*]
# so _sl_color_bar_filled / _sl_color_bar_badge can read them directly).
_sl_layout_init() {
    typeset -ga _SL_META_TEXTS=()  _SL_META_ROLES=()  _SL_META_METAS=()  _SL_META_LINKS=()
    typeset -ga _SL_REPO_TEXTS=()  _SL_REPO_ROLES=()  _SL_REPO_METAS=()  _SL_REPO_LINKS=()
    typeset -ga _SL_TOOLS_TEXTS=() _SL_TOOLS_ROLES=() _SL_TOOLS_METAS=() _SL_TOOLS_LINKS=()
    typeset -ga _SL_TASKS_TEXTS=() _SL_TASKS_ROLES=() _SL_TASKS_METAS=() _SL_TASKS_LINKS=()

    # Reset shrink state so layout is idempotent across calls.
    # META uses a flat step counter into _SL_META_SHRINK_SEQUENCE; the other
    # rows still use the phase/sub cascade (see each _sl_shrink_* function).
    SL[_shrink.meta.step]=0
    SL[_shrink.repo.phase]=0; SL[_shrink.repo.sub]=0
    SL[_shrink.tools.phase]=0; SL[_shrink.tools.sub]=0
    SL[_shrink.tasks.phase]=0; SL[_shrink.tasks.sub]=0

    # Propagate bar proc data needed by color functions
    # rate7d
    SL[rate7d.total_segments]=7
    SL[rate7d.overflow]=false
    SL[rate7d.grad_r1]=192; SL[rate7d.grad_g1]=132; SL[rate7d.grad_b1]=252
    SL[rate7d.grad_r2]=100; SL[rate7d.grad_g2]=50;  SL[rate7d.grad_b2]=150
    # rate5h
    SL[rate5h.total_segments]=10
    SL[rate5h.overflow]=false
    SL[rate5h.grad_r1]=34;  SL[rate5h.grad_g1]=211; SL[rate5h.grad_b1]=238
    SL[rate5h.grad_r2]=15;  SL[rate5h.grad_g2]=140; SL[rate5h.grad_b2]=150
    # context — mirrors process_context (overflow flag set by sl_build_context)
    SL[context.total_segments]=10
}

# Row 1: META — model name, three bars, agent tokens, cost.
_sl_layout_meta() {
    SL[_layout.meta.model_idx]=1
    _sl_push_seg META "${SL[model.text]}" "model_name" "" ""

    # Track bar index ranges for shrink functions
    SL[_layout.meta.rate7d_start]=$(( ${#_SL_META_TEXTS[@]} + 1 ))
    _sl_compose_bar_segs rate7d META
    SL[_layout.meta.rate7d_end]=${#_SL_META_TEXTS[@]}

    SL[_layout.meta.rate5h_start]=$(( ${#_SL_META_TEXTS[@]} + 1 ))
    _sl_compose_bar_segs rate5h META
    SL[_layout.meta.rate5h_end]=${#_SL_META_TEXTS[@]}

    SL[_layout.meta.context_start]=$(( ${#_SL_META_TEXTS[@]} + 1 ))
    _sl_compose_bar_segs context META
    SL[_layout.meta.context_end]=${#_SL_META_TEXTS[@]}

    SL[_layout.meta.agent_tokens_idx]=""
    if [[ "${SL[agent_tokens.visible]:-}" == "true" ]]; then
        _sl_push_seg META " ⚡${SL[agent_tokens.formatted]}" "agent_tokens" "" ""
        SL[_layout.meta.agent_tokens_idx]=${#_SL_META_TEXTS[@]}
    fi
    SL[_layout.meta.cost_idx]=""
    if [[ "${SL[cost.visible]:-}" == "true" ]]; then
        _sl_push_seg META " \$${SL[cost.formatted]}" "cost" "" ""
        SL[_layout.meta.cost_idx]=${#_SL_META_TEXTS[@]}
    fi
}

# Row: REPO — emits nothing when not a git repo. This used to signal the
# orchestrator to skip all downstream rows too; that coupling was a latent
# bug waiting for a row re-order to expose it and has been removed.
_sl_layout_repo() {
    [[ "${SL[_raw.git.is_repo]:-}" == "true" ]] || return 0

    local _dir_url="file://${SL[_raw.current_dir]}"
    local _wt_url="file://${SL[_raw.git_worktree]}"

    local _gi=0
    local _seg
    SL[_layout.repo.project_idx]=""
    SL[_layout.repo.branch_idx]=""
    SL[_layout.repo.worktree_idx]=""
    for _seg in "${SL_REPO_SEGMENTS[@]}"; do
        # Worktree is emitted inline after branch — skip in the normal loop
        [[ "$_seg" == "worktree" ]] && continue
        [[ "${SL[repo.${_seg}.visible]:-}" == "true" ]] || continue
        local _t="${SL[repo.${_seg}.text]}"
        [[ -n "$_t" ]] || continue

        local _link=""
        case "$_seg" in
            project|branch) _link="$_dir_url" ;;
        esac
        _sl_push_seg REPO "$_t" "git_seg" "$_gi" "$_link"
        (( _gi++ ))

        # Record layout indices for shrink functions
        case "$_seg" in
            project) SL[_layout.repo.project_idx]=${#_SL_REPO_TEXTS[@]} ;;
            branch)  SL[_layout.repo.branch_idx]=${#_SL_REPO_TEXTS[@]} ;;
        esac

        # Worktree indicator immediately follows branch (bash layout_row_repo line 1551)
        if [[ "$_seg" == "branch" && "${SL[repo.worktree.visible]:-}" == "true" ]]; then
            local _wt_text="${SL[repo.worktree.text]}"
            if [[ -n "$_wt_text" ]]; then
                _sl_push_seg REPO "$_wt_text" "git_seg" "$_gi" "${_wt_url}"
                (( _gi++ ))
                SL[_layout.repo.worktree_idx]=${#_SL_REPO_TEXTS[@]}
            fi
        fi
    done
}

# Row 3: TOOLS — total count + completed chips + running tool.
_sl_layout_tools() {
    local _nl=$'\n'
    SL[_layout.tools.chip_start]=""
    SL[_layout.tools.chip_end]=""
    [[ "${SL[tools.visible]:-}" == "true" ]] || return 0

    _sl_push_seg TOOLS "${SL[tools.total_count]}" "tool_total" "" ""

    local _counts="${SL[tools.completed_counts]}"
    local _chip_name _chip_count _ti=0
    local _chips_started=false
    while IFS=':' read -r _chip_name _chip_count; do
        [[ -z "$_chip_name" ]] && continue
        _sl_push_seg TOOLS " " "spacer" "" ""
        if (( _chip_count > 1 )); then
            _sl_push_seg TOOLS " ${_chip_name} ${_chip_count} " "tool_seg" "$_ti" ""
        else
            _sl_push_seg TOOLS " ${_chip_name} " "tool_seg" "$_ti" ""
        fi
        if [[ "$_chips_started" == "false" ]]; then
            SL[_layout.tools.chip_start]=${#_SL_TOOLS_TEXTS[@]}
            _chips_started=true
        fi
        SL[_layout.tools.chip_end]=${#_SL_TOOLS_TEXTS[@]}
        (( _ti++ ))
    done <<< "${_counts//|/${_nl}}"

    local _running="${SL[tools.running_name]:-}"
    if [[ -n "$_running" ]]; then
        local _rtarget="${SL[tools.running_target]:-}"
        _sl_push_seg TOOLS " " "spacer" "" ""
        if [[ -n "$_rtarget" ]]; then
            _sl_push_seg TOOLS " ◐ ${_running}: ${_rtarget}" "tool_seg" "$_ti" ""
        else
            _sl_push_seg TOOLS " ◐ ${_running}" "tool_seg" "$_ti" ""
        fi
        if [[ "$_chips_started" == "false" ]]; then
            SL[_layout.tools.chip_start]=${#_SL_TOOLS_TEXTS[@]}
        fi
        SL[_layout.tools.chip_end]=${#_SL_TOOLS_TEXTS[@]}
        (( _ti++ ))
    fi
}

# Row 4: TASKS — counts + completed/in-progress/pending/agent segments.
_sl_layout_tasks() {
    local _nl=$'\n'
    SL[_layout.tasks.completed_name_idx]=""
    SL[_layout.tasks.in_progress_idx]=""
    SL[_layout.tasks.pending_idx]=""
    SL[_layout.tasks.agents_start]=""
    SL[_layout.tasks.agents_end]=""
    SL[_layout.tasks.glyphs_idx]=""
    [[ "${SL[tasks.visible]:-}" == "true" ]] || return 0

    local _display_total=$(( ${SL[tasks.total_all]:-0} + ${SL[tasks.agent_count]:-0} ))
    local _display_completed="${SL[tasks.completed_all]:-0}"
    local _tsi=0

    if (( _display_total > 0 )); then
        _sl_push_seg TASKS "${_display_completed}/${_display_total}" "task_seg" "$_tsi" ""
        (( _tsi++ ))
    fi

    local _completed="${SL[tasks.completed]:-0}"
    if (( _completed > 0 )); then
        local _icons="" _ci
        for (( _ci=0; _ci<_completed; _ci++ )); do _icons="${_icons}✓"; done
        local _comp_label="$_icons"
        [[ -n "${SL[tasks.last_completed_name]}" ]] && _comp_label="${_icons} ${SL[tasks.last_completed_name]}"
        _sl_push_seg TASKS " ${_comp_label} " "task_seg" "$_tsi" ""
        SL[_layout.tasks.glyphs_idx]=${#_SL_TASKS_TEXTS[@]}
        # completed_name_idx: only meaningful if there's actually a name
        [[ -n "${SL[tasks.last_completed_name]}" ]] && SL[_layout.tasks.completed_name_idx]=${#_SL_TASKS_TEXTS[@]}
        (( _tsi++ ))
    fi

    local _in_progress="${SL[tasks.in_progress]:-0}"
    if (( _in_progress > 0 )); then
        local _prog_label="◐"
        [[ -n "${SL[tasks.in_progress_name]}" ]] && _prog_label="◐ ${SL[tasks.in_progress_name]}"
        _sl_push_seg TASKS " ${_prog_label} " "task_seg" "$_tsi" ""
        SL[_layout.tasks.in_progress_idx]=${#_SL_TASKS_TEXTS[@]}
        (( _tsi++ ))
    fi

    local _pending="${SL[tasks.pending]:-0}"
    if (( _pending > 0 )); then
        local _picons="" _pi
        for (( _pi=0; _pi<_pending; _pi++ )); do _picons="${_picons}○"; done
        local _pend_label="$_picons"
        [[ -n "${SL[tasks.first_pending_name]}" ]] && _pend_label="${_picons} ${SL[tasks.first_pending_name]}"
        _sl_push_seg TASKS " ${_pend_label} " "task_seg" "$_tsi" ""
        SL[_layout.tasks.pending_idx]=${#_SL_TASKS_TEXTS[@]}
        (( _tsi++ ))
    fi

    local _agents="${SL[tasks.running_agents]:-}"
    if [[ -n "$_agents" ]]; then
        local _agents_started=false
        local _adesc
        while IFS='|' read -r _adesc; do
            [[ -z "$_adesc" ]] && continue
            _sl_push_seg TASKS " ◐ ${_adesc}" "task_seg" "$_tsi" ""
            if [[ "$_agents_started" == "false" ]]; then
                SL[_layout.tasks.agents_start]=${#_SL_TASKS_TEXTS[@]}
                _agents_started=true
            fi
            SL[_layout.tasks.agents_end]=${#_SL_TASKS_TEXTS[@]}
            (( _tsi++ ))
        done <<< "${_agents//|/${_nl}}"
    fi
}

sl_layout() {
    _sl_layout_init
    local _row
    for _row in "${SL_LAYOUT_ORDER[@]}"; do
        "_sl_layout_${_row}"
    done
}

# ── Stage 4: sl_style ────────────────────────────────────────────────────────
# Phase D: Apply ANSI colors, OSC 8 hyperlinks, emit rows.

# Interpolate RGB at position pos of len total steps.
# Writes to globals _sl_irp_r, _sl_irp_g, _sl_irp_b.
_sl_interp_rgb() {
    local _ir1=$1 _ig1=$2 _ib1=$3 _ir2=$4 _ig2=$5 _ib2=$6 _ipos=$7 _ilen=$8
    if (( _ilen <= 1 )); then
        _sl_irp_r=$_ir1; _sl_irp_g=$_ig1; _sl_irp_b=$_ib1
        return
    fi
    local _ipct=$(( _ipos * 100 / (_ilen - 1) ))
    _sl_irp_r=$(( _ir1 + (_ir2 - _ir1) * _ipct / 100 ))
    _sl_irp_g=$(( _ig1 + (_ig2 - _ig1) * _ipct / 100 ))
    _sl_irp_b=$(( _ib1 + (_ib2 - _ib1) * _ipct / 100 ))
}

# Per-character gradient foreground (no background).
# Mirrors bash apply_fg. Output written to variable named by $1.
_sl_apply_fg() {
    local _out_var=$1 text=$2
    local r1=$3 g1=$4 b1=$5 r2=$6 g2=$7 b2=$8
    local len=${#text}
    if (( len <= 0 )); then
        printf -v "$_out_var" '%s' ''; return
    fi
    if (( r1 == r2 && g1 == g2 && b1 == b2 )); then
        printf -v "$_out_var" '%b' "\033[38;2;${r1};${g1};${b1}m${text}\033[0m"
        return
    fi
    local result="" i ch
    for (( i=0; i<len; i++ )); do
        ch="${text:$i:1}"
        _sl_interp_rgb "$r1" "$g1" "$b1" "$r2" "$g2" "$b2" "$i" "$len"
        result="${result}\033[38;2;${_sl_irp_r};${_sl_irp_g};${_sl_irp_b}m${ch}"
    done
    printf -v "$_out_var" '%b' "${result}\033[0m"
}

# Solid fg + solid bg (no gradient).
# Mirrors bash apply_fg_bg.
_sl_apply_fg_bg() {
    local _out_var=$1 text=$2
    local fr=$3 fg=$4 fb=$5 br=$6 bg=$7 bb=$8
    printf -v "$_out_var" '%b' "\033[38;2;${fr};${fg};${fb}m\033[48;2;${br};${bg};${bb}m${text}\033[0m"
}

# Per-character gradient fg on solid bg.
# Mirrors bash apply_gradient_bg.
_sl_apply_gradient_bg() {
    local _out_var=$1 text=$2
    local r1=$3 g1=$4 b1=$5 r2=$6 g2=$7 b2=$8
    local bg_r=$9 bg_g=${10} bg_b=${11}
    local len=${#text}
    if (( len <= 1 )); then
        printf -v "$_out_var" '%b' "\033[38;2;${r1};${g1};${b1}m\033[48;2;${bg_r};${bg_g};${bg_b}m${text}\033[0m"
        return
    fi
    local result="\033[48;2;${bg_r};${bg_g};${bg_b}m" i ch
    for (( i=0; i<len; i++ )); do
        ch="${text:$i:1}"
        _sl_interp_rgb "$r1" "$g1" "$b1" "$r2" "$g2" "$b2" "$i" "$len"
        result="${result}\033[38;2;${_sl_irp_r};${_sl_irp_g};${_sl_irp_b}m${ch}"
    done
    printf -v "$_out_var" '%b' "${result}\033[0m"
}

# _sl_piecewise_overflow_ratio <tokens> → sets global _sl_ratio (0-100).
# Piecewise linear over thresholds 1000 / 2000 / 4000 / 8000.
_sl_piecewise_overflow_ratio() {
    local t=$1
    if   (( t < 1000 )); then _sl_ratio=$(( t * 25 / 1000 ))
    elif (( t < 2000 )); then _sl_ratio=$(( 25 + (t - 1000) * 25 / 1000 ))
    elif (( t < 4000 )); then _sl_ratio=$(( 50 + (t - 2000) * 25 / 2000 ))
    elif (( t < 8000 )); then _sl_ratio=$(( 75 + (t - 4000) * 25 / 4000 ))
    else                      _sl_ratio=100
    fi
}

# _sl_gyr_ramp <pct> <out_r> <out_g> <out_b>
# Green (34,197,94) @ 0% → Yellow (250,204,21) @ 50% → Red (239,68,68) @ 100%.
_sl_gyr_ramp() {
    local pct=$1 or=$2 og=$3 ob=$4
    local ratio r g b
    if (( pct <= 50 )); then
        ratio=$(( pct * 2 ))
        r=$(( 34 + (250 - 34) * ratio / 100 ))
        g=$(( 197 + (204 - 197) * ratio / 100 ))
        b=$(( 94 + (21 - 94) * ratio / 100 ))
    else
        ratio=$(( (pct - 50) * 2 ))
        r=$(( 250 + (239 - 250) * ratio / 100 ))
        g=$(( 204 + (68 - 204) * ratio / 100 ))
        b=$(( 21 + (68 - 21) * ratio / 100 ))
    fi
    printf -v "$or" '%d' "$r"
    printf -v "$og" '%d' "$g"
    printf -v "$ob" '%d' "$b"
}

# Color bar filled segment. proc_prefix is e.g. "rate7d".
# Output written to variable named by $1.
_sl_color_bar_filled() {
    local _out_var=$1 text=$2 proc=$3
    local total="${SL[${proc}.total_segments]}"
    local filled="${SL[${proc}.filled]}"
    local overflow="${SL[${proc}.overflow]:-false}"
    local len=${#text}
    local result="" i ch seg_tokens seg_pct cr cg cb
    local gr1 gg1 gb1 gr2 gg2 gb2
    local overflow_tokens="${SL[${proc}.overflow_tokens]:-0}"

    if [[ "$overflow" == "true" ]]; then
        for (( i=0; i<len; i++ )); do
            ch="${text:$i:1}"
            if (( filled > 1 )); then
                seg_tokens=$(( overflow_tokens * (i + 1) / filled ))
            else
                seg_tokens=$overflow_tokens
            fi
            _sl_piecewise_overflow_ratio "$seg_tokens"
            seg_pct=$(( 100 + _sl_ratio / 4 ))
            _sl_interp_rgb 239 68 68 168 85 247 "$(( seg_pct - 100 ))" 25
            result="${result}\033[38;2;${_sl_irp_r};${_sl_irp_g};${_sl_irp_b}m${ch}"
        done
    elif [[ -n "${SL[${proc}.grad_r1]:-}" ]]; then
        gr1="${SL[${proc}.grad_r1]}" gg1="${SL[${proc}.grad_g1]}" gb1="${SL[${proc}.grad_b1]}"
        gr2="${SL[${proc}.grad_r2]}" gg2="${SL[${proc}.grad_g2]}" gb2="${SL[${proc}.grad_b2]}"
        for (( i=0; i<len; i++ )); do
            ch="${text:$i:1}"
            _sl_interp_rgb "$gr1" "$gg1" "$gb1" "$gr2" "$gg2" "$gb2" "$i" "$len"
            result="${result}\033[38;2;${_sl_irp_r};${_sl_irp_g};${_sl_irp_b}m${ch}"
        done
    else
        # Multi-stop green→yellow→red (context bar)
        for (( i=0; i<len; i++ )); do
            ch="${text:$i:1}"
            seg_pct=$(( (total - 1 - i) * 100 / total ))
            _sl_gyr_ramp "$seg_pct" cr cg cb
            result="${result}\033[38;2;${cr};${cg};${cb}m${ch}"
        done
    fi
    printf -v "$_out_var" '%b' "${result}\033[0m"
}

# Color bar badge. Auto-contrast fg. Output to variable named by $1.
_sl_color_bar_badge() {
    local _out_var=$1 text=$2 proc=$3
    local pct="${SL[${proc}.pct]}"
    local overflow="${SL[${proc}.overflow]:-false}"
    local bg_r bg_g bg_b seg_pct overflow_tokens

    overflow_tokens="${SL[${proc}.overflow_tokens]:-0}"

    if [[ "$overflow" == "true" ]]; then
        _sl_piecewise_overflow_ratio "$overflow_tokens"
        seg_pct=$(( 100 + _sl_ratio / 4 ))
        _sl_interp_rgb 239 68 68 168 85 247 "$(( seg_pct - 100 ))" 25
        bg_r=$_sl_irp_r; bg_g=$_sl_irp_g; bg_b=$_sl_irp_b
    elif [[ -n "${SL[${proc}.grad_r1]:-}" ]]; then
        bg_r="${SL[${proc}.grad_r2]}"; bg_g="${SL[${proc}.grad_g2]}"; bg_b="${SL[${proc}.grad_b2]}"
    else
        _sl_gyr_ramp "$pct" bg_r bg_g bg_b
    fi

    # Auto-contrast fg (calc_badge_fg)
    local lum=$(( (299 * bg_r + 587 * bg_g + 114 * bg_b) / 1000 ))
    local fg_r fg_g fg_b
    if (( lum > 128 )); then
        fg_r=0; fg_g=0; fg_b=0
    else
        fg_r=255; fg_g=255; fg_b=255
    fi
    _sl_apply_fg_bg "$_out_var" "$text" "$fg_r" "$fg_g" "$fg_b" "$bg_r" "$bg_g" "$bg_b"
}

# Color bar empty segment. Mirrors bash color_bar_empty.
_sl_color_bar_empty() {
    local _out_var=$1 text=$2
    local empty_run="" suffix_run="" in_suffix=false
    local i len=${#text} ch
    for (( i=0; i<len; i++ )); do
        ch="${text:$i:1}"
        if [[ "$ch" == "▁" && "$in_suffix" == "false" ]]; then
            empty_run="${empty_run}${ch}"
        else
            in_suffix=true
            suffix_run="${suffix_run}${ch}"
        fi
    done
    local result="\033[48;2;20;22;32m"
    [[ -n "$empty_run" ]] && result="${result}\033[38;2;55;58;72m${empty_run}"
    [[ -n "$suffix_run" ]] && result="${result}\033[38;2;130;135;152m${suffix_run}"
    printf -v "$_out_var" '%b' "${result}\033[0m"
}

# OSC 8 hyperlink wrap. Mirrors bash style_segment link wrapping.
# Bash strips trailing \033[0m (as literal chars) before wrapping.
# In our zsh port the stored string has actual ESC bytes from printf %b.
# We strip the trailing ESC[0m bytes and wrap with OSC 8.
_sl_osc8_wrap() {
    local _out_var=$1 link=$2 styled=$3
    # ESC[0m as literal bytes: ESC = $'\033', then [0m
    local _esc_reset=$'\033[0m'
    # Strip trailing reset if present
    if [[ "$styled" == *"${_esc_reset}" ]]; then
        styled="${styled%${_esc_reset}}"
    fi
    # Build OSC 8 wrapped string: ESC]8;;URL BEL text ESC]8;; BEL ESC[0m
    printf -v "$_out_var" '%s' $'\033]8;;'"${link}"$'\007'"${styled}"$'\033]8;;\007'$'\033[0m'
}

# Style one segment. Output to global _sl_styled.
_sl_style_segment() {
    local text=$1 role=$2 meta=$3 link=$4
    _sl_styled=""   # reset global output

    case "$role" in
        model_name)
            _sl_apply_fg _sl_styled "$text" 34 211 216 168 85 247 ;;
        git_seg)
            # Continuous cycle starting at stop 1 (blue); meta is _gi index.
            # Palette is 0-indexed in bash; zsh arrays are 1-indexed (no_ksh_arrays).
            local _gi="${meta:-0}"
            local _fi=$(( ((_gi + 1) % 4) + 1 ))
            local _ti=$(( ((_gi + 2) % 4) + 1 ))
            _sl_apply_fg _sl_styled "$text" \
                "${_sl_pal_r[$_fi]}" "${_sl_pal_g[$_fi]}" "${_sl_pal_b[$_fi]}" \
                "${_sl_pal_r[$_ti]}" "${_sl_pal_g[$_ti]}" "${_sl_pal_b[$_ti]}" ;;
        agent_tokens)
            _sl_apply_fg _sl_styled "$text" 130 135 152 130 135 152 ;;
        cost)
            _sl_apply_fg _sl_styled "$text" 130 135 152 130 135 152 ;;
        bar_filled)
            _sl_color_bar_filled _sl_styled "$text" "$meta" ;;
        bar_badge)
            _sl_color_bar_badge _sl_styled "$text" "$meta" ;;
        bar_empty)
            _sl_color_bar_empty _sl_styled "$text" ;;
        tool_total)
            _sl_apply_fg _sl_styled "$text" 168 85 247 168 85 247 ;;
        tool_seg)
            # Tools row: cycle starting at stop 2 (pink); meta is _ti index.
            local _ti="${meta:-0}"
            local _fi=$(( ((_ti + 2) % 4) + 1 ))
            local _tii=$(( ((_ti + 3) % 4) + 1 ))
            _sl_apply_gradient_bg _sl_styled "$text" \
                "${_sl_pal_r[$_fi]}" "${_sl_pal_g[$_fi]}" "${_sl_pal_b[$_fi]}" \
                "${_sl_pal_r[$_tii]}" "${_sl_pal_g[$_tii]}" "${_sl_pal_b[$_tii]}" \
                20 22 32 ;;
        task_seg)
            # Tasks row: cycle starting at stop 3 (orange); meta is _tsi index.
            local _tsi="${meta:-0}"
            local _fi=$(( ((_tsi + 3) % 4) + 1 ))
            local _tii=$(( ((_tsi + 4) % 4) + 1 ))
            _sl_apply_fg _sl_styled "$text" \
                "${_sl_pal_r[$_fi]}" "${_sl_pal_g[$_fi]}" "${_sl_pal_b[$_fi]}" \
                "${_sl_pal_r[$_tii]}" "${_sl_pal_g[$_tii]}" "${_sl_pal_b[$_tii]}" ;;
        warning_title)
            _sl_apply_fg _sl_styled "$text" 251 191 36 251 191 36 ;;
        warning_body)
            _sl_apply_fg _sl_styled "$text" 110 110 110 110 110 110 ;;
        spacer|*)
            _sl_styled="$text" ;;
    esac

    # OSC 8 hyperlink (mirrors bash: strip trailing reset, wrap, re-add reset)
    if [[ -n "$link" ]]; then
        _sl_osc8_wrap _sl_styled "$link" "$_sl_styled"
    fi
}

# Emit one complete row from its parallel arrays.
# Usage: _sl_emit_row <ROW> <is_last>
# is_last=true → no trailing newline (bash render_output uses printf '%b' for last)
_sl_emit_row() {
    local row=$1 is_last=${2:-false}
    local -a texts roles metas links
    eval "texts=(\"\${_SL_${row}_TEXTS[@]}\")"
    eval "roles=(\"\${_SL_${row}_ROLES[@]}\")"
    eval "metas=(\"\${_SL_${row}_METAS[@]}\")"
    eval "links=(\"\${_SL_${row}_LINKS[@]}\")"
    local n=${#texts[@]}
    (( n > 0 )) || return 0

    local wrap_at="${SL[_layout.${row}.wrap_at]:-}"
    local line_buf="" i=""

    for (( i=1; i<=n; i++ )); do
        # Insert line break at wrap point
        if [[ -n "$wrap_at" ]] && (( i == wrap_at + 1 )); then
            printf '%b\n' "$line_buf"
            line_buf=""
        fi
        _sl_style_segment "${texts[$i]}" "${roles[$i]}" "${metas[$i]}" "${links[$i]}"
        line_buf="${line_buf}${_sl_styled}"
    done

    if [[ "$is_last" == "true" ]]; then
        printf '%b' "$line_buf"
    else
        printf '%b\n' "$line_buf"
    fi
}

sl_style() {
    # Determine which rows have content — iterate SL_LAYOUT_ORDER so the
    # visual order follows the configured row list.
    local -a active_rows=()
    local _row _uc _count
    for _row in "${SL_LAYOUT_ORDER[@]}"; do
        _uc="${(U)_row}"
        eval "_count=\${#_SL_${_uc}_TEXTS[@]}"
        (( _count > 0 )) && active_rows+=("$_uc")
    done

    local nrows=${#active_rows[@]}
    local ri
    for (( ri=1; ri<=nrows; ri++ )); do
        local is_last=false
        (( ri == nrows )) && is_last=true
        _sl_emit_row "${active_rows[$ri]}" "$is_last"
    done
}

# ── Width detection ──────────────────────────────────────────────────────────
# Detect terminal width and store in SL[_raw.tty_cols].
# 1. $COLUMNS if set and numeric
# 2. Process-tree walk: climb ppid up to 8 levels, find real TTY, stty size
# 3. Default 9999
# 4. Subtract CC padding (4) + statusLine.padding from settings.json
# Probe terminal width. Sets SL[_raw.tty_cols] to the raw column count
# (before padding adjustments). Tries, in order: $COLUMNS → process-tree walk
# up to 8 ancestors to find a real TTY → default 9999.
_sl_detect_terminal_width() {
    local cols=""

    # 1. $COLUMNS if set, numeric, and > 0
    if [[ -n "${COLUMNS:-}" ]] && [[ "$COLUMNS" =~ ^[0-9]+$ ]] && (( COLUMNS > 0 )); then
        cols="$COLUMNS"
    fi

    # 2. Process-tree walk
    if [[ -z "$cols" ]]; then
        local pid=$$
        local i=""
        for (( i=0; i<8; i++ )); do
            pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
            [[ -z "$pid" || "$pid" == "0" || "$pid" == "1" ]] && break
            local tty_name
            tty_name=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')
            [[ -z "$tty_name" || "$tty_name" == "??" || "$tty_name" == "?" ]] && continue
            local width
            width=$(stty size < "/dev/$tty_name" 2>/dev/null | awk '{print $2}')
            if [[ -n "$width" ]] && (( width > 0 )); then
                cols="$width"
                break
            fi
        done
    fi

    # 3. Default 9999
    SL[_raw.tty_cols]="${cols:-9999}"
}

# Read statusLine.padding from user settings files (one jq pass each).
# Sets SL[_raw.tty_padding] to the last non-empty value found (local wins).
_sl_read_padding_from_settings() {
    local cc_padding=0 _sp _p
    for _sp in "${HOME}/.claude/settings.json" "${HOME}/.claude/settings.local.json"; do
        [[ -f "$_sp" ]] || continue
        _p=$(jq -r '.statusLine.padding // empty' "$_sp" 2>/dev/null)
        [[ -n "$_p" ]] && cc_padding="$_p"
    done
    SL[_raw.tty_padding]="$cc_padding"
}

sl_detect_width() {
    _sl_detect_terminal_width
    _sl_read_padding_from_settings
    # Subtract CC padding (4) + user statusLine.padding.
    SL[_raw.tty_cols]=$(( SL[_raw.tty_cols] - 4 - SL[_raw.tty_padding] ))
}

# ── Text truncation helpers ───────────────────────────────────────────────────
# sl_truncate_right <text> <max_len>
# Truncates text from right with "..." suffix if it exceeds max_len.
# Stores result in _sl_trunc_out.
typeset -g _sl_trunc_out=""
sl_truncate_right() {
    local text=$1
    local max_len=$2
    local len=${#text}

    if (( max_len <= 0 )); then
        _sl_trunc_out=""
    elif (( len <= max_len )); then
        _sl_trunc_out="$text"
    elif (( max_len == 1 )); then
        _sl_trunc_out="${text[1]}"
    else
        # max_len >= 2: keep max_len-1 chars + "…" (U+2026, single-char ellipsis)
        _sl_trunc_out="${text[1,$(( max_len - 1 ))]}…"
    fi
}

# sl_truncate_left <text> <max_len>
# Truncates text from left with "..." prefix if it exceeds max_len.
# Stores result in _sl_trunc_out.
sl_truncate_left() {
    local text=$1
    local max_len=$2
    local len=${#text}

    if (( max_len <= 0 )); then
        _sl_trunc_out=""
    elif (( len <= max_len )); then
        _sl_trunc_out="$text"
    elif (( max_len == 1 )); then
        _sl_trunc_out="${text[$len]}"
    else
        # max_len >= 2: "…" (U+2026) + rightmost max_len-1 chars
        _sl_trunc_out="…${text[$(( len - max_len + 2 )),$len]}"
    fi
}

# ── Row measurement ───────────────────────────────────────────────────────────
# sl_display_width <text>
# Returns display column count, accounting for wide characters.
# Characters like ⚡ (U+26A1) and ⚠ (U+26A0) render as 2 columns in most terminals.
# Stores result in _sl_dw.
typeset -g _sl_dw=0
sl_display_width() {
    local text=$1
    local len=${#text}
    # Count known wide characters and add 1 per occurrence
    local wide="${text//[^⚡⚠]/}"
    _sl_dw=$(( len + ${#wide} ))
}

# sl_measure_row <ROW>
# Sums display column widths of all segments in a row's TEXTS array.
# Stores result in _sl_row_width.
typeset -g _sl_row_width=0
sl_measure_row() {
    local row=$1
    local -a texts
    eval "texts=(\"\${_SL_${row}_TEXTS[@]}\")"
    local total=0
    local t
    for t in "${texts[@]}"; do
        sl_display_width "$t"
        (( total += _sl_dw ))
    done
    _sl_row_width=$total
}

# ── Per-row shrink functions ──────────────────────────────────────────────────
# Each function applies ONE atomic shrink step (removes/truncates by 1 char or 1 phase).
# Returns 0 on success, 1 if no more steps available.
# State is maintained in SL[_shrink.<row>.phase] and SL[_shrink.<row>.sub].
#
# Helpers below mutate the META/REPO parallel arrays but DO NOT touch
# SL[_shrink.*] — phase management stays in the caller. Each helper returns
# 0 if it did work, non-zero otherwise, so the caller can decide whether to
# advance the phase with a re-measure (return 0) or fall through.

# _sl_shrink_compact_bar_range <rs> <re> <suffix>
# Clears bar_filled texts; replaces bar_empty text with " $suffix " (or "" if
# empty). Returns 0 if the range was valid and non-empty, else 1.
_sl_shrink_compact_bar_range() {
    local rs=$1 re=$2 suffix=$3 i role
    [[ -n "$rs" && -n "$re" && "$rs" -le "$re" ]] || return 1
    for (( i=rs; i<=re; i++ )); do
        role="${_SL_META_ROLES[$i]}"
        if [[ "$role" == "bar_filled" ]]; then
            _SL_META_TEXTS[$i]=""
        elif [[ "$role" == "bar_empty" ]]; then
            if [[ -n "$suffix" ]]; then
                _SL_META_TEXTS[$i]=" ${suffix} "
            else
                _SL_META_TEXTS[$i]=""
            fi
        fi
    done
    return 0
}

# _sl_shrink_strip_badge_space_in_range <rs> <re>
# Strips a single leading space from the first bar_badge that has one.
# Returns 0 if a strip happened, else 1.
_sl_shrink_strip_badge_space_in_range() {
    local rs=$1 re=$2 i
    [[ -n "$rs" && -n "$re" ]] || return 1
    for (( i=rs; i<=re; i++ )); do
        if [[ "${_SL_META_ROLES[$i]}" == "bar_badge" && "${_SL_META_TEXTS[$i]}" == " "* ]]; then
            _SL_META_TEXTS[$i]="${_SL_META_TEXTS[$i]# }"
            return 0
        fi
    done
    return 1
}

# _sl_shrink_clear_badge_text_in_range <rs> <re>
# Clears the text of the first non-empty bar_badge. Returns 0 if cleared.
_sl_shrink_clear_badge_text_in_range() {
    local rs=$1 re=$2 i
    [[ -n "$rs" && -n "$re" ]] || return 1
    for (( i=rs; i<=re; i++ )); do
        if [[ "${_SL_META_ROLES[$i]}" == "bar_badge" && -n "${_SL_META_TEXTS[$i]}" ]]; then
            _SL_META_TEXTS[$i]=""
            return 0
        fi
    done
    return 1
}

# _sl_shrink_strip_icon_in_range <rs> <re> <icon>
# Strips "<icon> " from the first bar_empty text that contains it.
# Returns 0 if stripped.
_sl_shrink_strip_icon_in_range() {
    local rs=$1 re=$2 icon=$3 i
    [[ -n "$rs" && -n "$re" ]] || return 1
    for (( i=rs; i<=re; i++ )); do
        if [[ "${_SL_META_ROLES[$i]}" == "bar_empty" && "${_SL_META_TEXTS[$i]}" == *"${icon}"* ]]; then
            _SL_META_TEXTS[$i]="${_SL_META_TEXTS[$i]//${icon} /}"
            return 0
        fi
    done
    return 1
}

# _sl_shrink_clear_range <rs> <re>
# Clears every text in the range. Returns 0 if any text was non-empty before.
_sl_shrink_clear_range() {
    local rs=$1 re=$2 i any=1
    [[ -n "$rs" && -n "$re" ]] || return 1
    for (( i=rs; i<=re; i++ )); do
        [[ -n "${_SL_META_TEXTS[$i]}" ]] && any=0
        _SL_META_TEXTS[$i]=""
    done
    return $any
}

# _sl_shrink_truncate_prefixed_name <idx>
# Splits _SL_REPO_TEXTS[$idx] on " ⎇ " (or leading space) to preserve the
# prefix, truncates the trailing name by one char. Writes result back.
# Returns 0 if truncated.
_sl_shrink_truncate_prefixed_name() {
    local idx=$1
    [[ -n "$idx" ]] || return 1
    local cur="${_SL_REPO_TEXTS[$idx]}"
    local prefix="" name_part=""
    if [[ "$cur" == *" ⎇ "* ]]; then
        prefix="${cur% ⎇ *} ⎇ "
        name_part="${cur##* ⎇ }"
    elif [[ "$cur" == " "* ]]; then
        prefix=" "
        name_part="${cur# }"
    else
        prefix=""
        name_part="$cur"
    fi
    local namelen=${#name_part}
    (( namelen > 1 )) || return 1
    sl_truncate_right "$name_part" $(( namelen - 1 ))
    _SL_REPO_TEXTS[$idx]="${prefix}${_sl_trunc_out}"
    return 0
}

# ── META-specific shrink helpers (data-table actions) ────────────────────────

# Truncate the META model segment by one char right-to-left, down to the
# "first-word second-word" minimum. Iterative: returns 0 while a char can
# still be removed, 1 when the minimum is reached (caller advances step).
_sl_shrink_truncate_model() {
    local model_idx="${SL[_layout.meta.model_idx]:-1}"
    local cur="${_SL_META_TEXTS[$model_idx]}"
    local curlen=${#cur}
    # Compute minimum = original name up to the second space (or whole if <2 spaces).
    local orig_model="${SL[model.text]}"
    local first_space="${orig_model%% *}"
    local after_first="${orig_model#* }"
    local second_word="${after_first%% *}"
    local model_min
    if [[ "$orig_model" == *" "* && "$after_first" == *" "* ]]; then
        model_min="${first_space} ${second_word}"
    else
        model_min="$orig_model"
    fi
    local min_len=${#model_min}
    (( min_len < 1 )) && min_len=1
    (( curlen > min_len )) || return 1
    sl_truncate_right "$cur" $(( curlen - 1 ))
    _SL_META_TEXTS[$model_idx]="$_sl_trunc_out"
    return 0
}

# Find the context bar_badge, strip its leading space, and flip its role to
# "spacer" (the badge survives visually a bit longer than the rate-bar
# badges because the context glyph conveys info on its own). One-shot.
_sl_shrink_context_badge_to_spacer() {
    local rcs="${SL[_layout.meta.context_start]:-}" rce="${SL[_layout.meta.context_end]:-}"
    [[ -n "$rcs" && -n "$rce" ]] || return 1
    local i
    for (( i=rcs; i<=rce; i++ )); do
        if [[ "${_SL_META_ROLES[$i]}" == "bar_badge" && "${_SL_META_TEXTS[$i]}" == " "* ]]; then
            _SL_META_TEXTS[$i]="${_SL_META_TEXTS[$i]# }"
            _SL_META_ROLES[$i]="spacer"
            return 0
        fi
    done
    return 1
}

# Drop the remaining context-progress glyph (◔ ◕ ◑ ○ ● ⊙) from the context
# badge/spacer. Note: the original code's combined role+glyph precedence is
# preserved verbatim; `&&` binds tighter than `||` so the role check only
# gates the ◔ match. Any of the other five glyphs matches regardless of
# role. In practice every context glyph lives in a bar_badge/spacer so the
# distinction never surfaces.
_sl_shrink_drop_context_glyph() {
    local rcs="${SL[_layout.meta.context_start]:-}" rce="${SL[_layout.meta.context_end]:-}"
    [[ -n "$rcs" && -n "$rce" ]] || return 1
    local i
    for (( i=rcs; i<=rce; i++ )); do
        if [[ ("${_SL_META_ROLES[$i]}" == "bar_badge" || "${_SL_META_ROLES[$i]}" == "spacer") && "${_SL_META_TEXTS[$i]}" == *"◔"* || "${_SL_META_TEXTS[$i]}" == *"◕"* || "${_SL_META_TEXTS[$i]}" == *"◑"* || "${_SL_META_TEXTS[$i]}" == *"○"* || "${_SL_META_TEXTS[$i]}" == *"●"* || "${_SL_META_TEXTS[$i]}" == *"⊙"* ]]; then
            _SL_META_TEXTS[$i]=""
            return 0
        fi
    done
    return 1
}

# Generic single-index removal for segments recorded as SL[_layout.meta.<target>_idx].
# Used for model, agent_tokens, cost. Returns 0 if a non-empty text was cleared.
_sl_shrink_clear_index() {
    local target=$1
    local idx="${SL[_layout.meta.${target}_idx]:-}"
    [[ -n "$idx" && -n "${_SL_META_TEXTS[$idx]:-}" ]] || return 1
    _SL_META_TEXTS[$idx]=""
    return 0
}

# Resolve a bar name (e.g. "rate7d") to its META-row start/end indices.
# Writes to the two output variables named by $2 / $3.
_sl_range_for_bar() {
    local bar=$1 rs_var=$2 re_var=$3
    printf -v "$rs_var" '%s' "${SL[_layout.meta.${bar}_start]:-}"
    printf -v "$re_var" '%s' "${SL[_layout.meta.${bar}_end]:-}"
}

# ── Meta-row shrink action dispatcher ─────────────────────────────────────────
# Parses a "action" / "action:target" / "action:target:arg" spec from
# _SL_META_SHRINK_SEQUENCE and calls the matching helper. Returns what the
# helper returned (0 = mutated, 1 = nothing to do).
_sl_shrink_exec() {
    local spec=$1
    local action="${spec%%:*}"
    local rest=""
    [[ "$spec" == *:* ]] && rest="${spec#*:}"
    local target="${rest%%:*}"
    local arg=""
    [[ "$rest" == *:* ]] && arg="${rest#*:}"
    local rs re

    case "$action" in
        compact_bar)
            _sl_range_for_bar "$target" rs re
            _sl_shrink_compact_bar_range "$rs" "$re" "${SL[${target}.suffix]:-}" ;;
        strip_badge_space)
            _sl_range_for_bar "$target" rs re
            _sl_shrink_strip_badge_space_in_range "$rs" "$re" ;;
        clear_badge_text)
            _sl_range_for_bar "$target" rs re
            _sl_shrink_clear_badge_text_in_range "$rs" "$re" ;;
        context_badge_to_spacer)
            _sl_shrink_context_badge_to_spacer ;;
        drop_context_glyph)
            _sl_shrink_drop_context_glyph ;;
        strip_icon)
            _sl_range_for_bar "$target" rs re
            _sl_shrink_strip_icon_in_range "$rs" "$re" "$arg" ;;
        clear_range)
            _sl_range_for_bar "$target" rs re
            _sl_shrink_clear_range "$rs" "$re" ;;
        drop_index)
            _sl_shrink_clear_index "$target" ;;
        *)
            return 1 ;;
    esac
}

# ── Meta-row shrink sequence ──────────────────────────────────────────────────
# The order of shrink operations for the META row. Edit this array to
# customise priority, swap segments, or add new actions. Each entry is
# dispatched via _sl_shrink_exec.
#
# Step 0 is implicit (iterative model-name truncation); the table starts at
# step 1. To add an iterative action other than model truncation, extend
# _sl_shrink_meta directly — the table is for one-shot steps.
typeset -ga _SL_META_SHRINK_SEQUENCE=(
    "compact_bar:rate7d"
    "compact_bar:rate5h"
    "strip_badge_space:rate7d"
    "strip_badge_space:rate5h"
    "compact_bar:context"
    "clear_badge_text:rate7d"
    "clear_badge_text:rate5h"
    "context_badge_to_spacer"
    "drop_context_glyph"
    "strip_icon:rate7d:↻"
    "strip_icon:rate5h:↻"
    "strip_icon:context:↻"
    "clear_range:rate7d"
    "clear_range:rate5h"
    "drop_index:agent_tokens"
    "drop_index:cost"
    "drop_index:model"
)

# ─── Meta row shrink ──────────────────────────────────────────────────────────
# Dispatches to _sl_shrink_exec using _SL_META_SHRINK_SEQUENCE. Returns 0
# when a step did work (caller re-measures) and 1 when fully exhausted.
#
# State: SL[_shrink.meta.step]. Step 0 is the iterative model-name
# truncation (re-runs until minimum reached); steps 1..N walk the sequence
# table once each. Between calls, the step index persists in SL[] so
# sl_layout_responsive can loop without redoing work.
_sl_shrink_meta() {
    local step="${SL[_shrink.meta.step]:-0}"

    # Step 0: iterative model-name truncation.
    if (( step == 0 )); then
        if _sl_shrink_truncate_model; then
            return 0
        fi
        step=1
        SL[_shrink.meta.step]=1
    fi

    # Steps 1..N: data-driven walk through _SL_META_SHRINK_SEQUENCE.
    local total=${#_SL_META_SHRINK_SEQUENCE[@]}
    while (( step <= total )); do
        if _sl_shrink_exec "${_SL_META_SHRINK_SEQUENCE[$step]}"; then
            SL[_shrink.meta.step]=$(( step + 1 ))
            return 0
        fi
        (( step++ ))
    done
    SL[_shrink.meta.step]=$step
    return 1
}

# ─── Repo row shrink ──────────────────────────────────────────────────────────
# Phases:
#  0: truncate project name char by char, min 1
#  1: truncate branch name char by char, min 1 (only the branch-name part after ⎇ )
#  2: truncate worktree name char by char, min 1
#  3: remove project segment
#  4: remove branch segment
#  5: remove worktree segment
_sl_shrink_repo() {
    local phase="${SL[_shrink.repo.phase]:-0}"

    # Phase 0: truncate project name
    if (( phase == 0 )); then
        local pidx="${SL[_layout.repo.project_idx]:-}"
        if [[ -n "$pidx" ]]; then
            local cur="${_SL_REPO_TEXTS[$pidx]}"
            local curlen=${#cur}
            if (( curlen > 1 )); then
                sl_truncate_right "$cur" $(( curlen - 1 ))
                _SL_REPO_TEXTS[$pidx]="$_sl_trunc_out"
                return 0
            fi
        fi
        SL[_shrink.repo.phase]=1
        phase=1
    fi

    # Phase 1: truncate branch name (keep " ⎇ " prefix, truncate only the name part)
    if (( phase == 1 )); then
        if _sl_shrink_truncate_prefixed_name "${SL[_layout.repo.branch_idx]:-}"; then
            return 0
        fi
        SL[_shrink.repo.phase]=2
        phase=2
    fi

    # Phase 2: truncate worktree name
    if (( phase == 2 )); then
        if _sl_shrink_truncate_prefixed_name "${SL[_layout.repo.worktree_idx]:-}"; then
            return 0
        fi
        SL[_shrink.repo.phase]=3
        phase=3
    fi

    # Phase 3: remove project segment
    if (( phase == 3 )); then
        local pidx="${SL[_layout.repo.project_idx]:-}"
        if [[ -n "$pidx" && -n "${_SL_REPO_TEXTS[$pidx]:-}" ]]; then
            _SL_REPO_TEXTS[$pidx]=""
            SL[_shrink.repo.phase]=4
            return 0
        fi
        SL[_shrink.repo.phase]=4
        phase=4
    fi

    # Phase 4: remove branch segment
    if (( phase == 4 )); then
        local bidx="${SL[_layout.repo.branch_idx]:-}"
        if [[ -n "$bidx" && -n "${_SL_REPO_TEXTS[$bidx]:-}" ]]; then
            _SL_REPO_TEXTS[$bidx]=""
            SL[_shrink.repo.phase]=5
            return 0
        fi
        SL[_shrink.repo.phase]=5
        phase=5
    fi

    # Phase 5: remove worktree segment
    if (( phase == 5 )); then
        local widx="${SL[_layout.repo.worktree_idx]:-}"
        if [[ -n "$widx" && -n "${_SL_REPO_TEXTS[$widx]:-}" ]]; then
            _SL_REPO_TEXTS[$widx]=""
            SL[_shrink.repo.phase]=6
            return 0
        fi
        SL[_shrink.repo.phase]=6
        phase=6
    fi

    return 1
}

# ─── Tools row shrink ─────────────────────────────────────────────────────────
# Chip entries alternate spacer/chip. Chips have role "tool_seg".
# Phases:
#  0: MCP chips: strip "mcp__" prefix from leftmost MCP chip
#  1: MCP chips: truncate from left with "...", leftmost first
#  2: Regular chips (>4 chars): truncate right with "...", leftmost first
#  3: Regular chips: shorten "..." → ".." → "." → letter only
#  4: 4-char chips: truncate to 1 char, leftmost first
_sl_shrink_tools() {
    local phase="${SL[_shrink.tools.phase]:-0}"

    local cs="${SL[_layout.tools.chip_start]:-}"
    local ce="${SL[_layout.tools.chip_end]:-}"
    [[ -n "$cs" && -n "$ce" ]] || return 1

    # Inline chip iteration: iterate cs..ce, pick tool_seg roles.
    # For each phase, scan from left and apply the first applicable shrink.
    local _idx _txt _trimmed _name_part _count_suffix _namelen

    # Phase 0: strip "mcp__" prefix from leftmost MCP chip
    if (( phase == 0 )); then
        for (( _idx=cs; _idx<=ce; _idx++ )); do
            [[ "${_SL_TOOLS_ROLES[$_idx]}" == "tool_seg" ]] || continue
            _txt="${_SL_TOOLS_TEXTS[$_idx]}"
            _trimmed="${_txt# }"   # strip leading space
            if [[ "$_trimmed" == "mcp__"* ]]; then
                _SL_TOOLS_TEXTS[$_idx]=" ${_trimmed#mcp__}"
                return 0
            fi
        done
        SL[_shrink.tools.phase]=1
        phase=1
    fi

    # Phase 1: MCP chips left-truncation with "...", leftmost first
    if (( phase == 1 )); then
        for (( _idx=cs; _idx<=ce; _idx++ )); do
            [[ "${_SL_TOOLS_ROLES[$_idx]}" == "tool_seg" ]] || continue
            _txt="${_SL_TOOLS_TEXTS[$_idx]}"
            _trimmed="${_txt# }"
            if [[ "$_trimmed" == "__"* || "$_trimmed" == "..."*"__"* ]]; then
                _name_part="${_trimmed% }"
                _count_suffix=""
                if [[ "$_name_part" =~ " [0-9]+$" ]]; then
                    _count_suffix=" ${_name_part##* }"
                    _name_part="${_name_part% *}"
                fi
                _namelen=${#_name_part}
                if (( _namelen > 2 )); then
                    sl_truncate_left "$_name_part" $(( _namelen - 1 ))
                    _SL_TOOLS_TEXTS[$_idx]=" ${_sl_trunc_out}${_count_suffix} "
                    return 0
                fi
            fi
        done
        SL[_shrink.tools.phase]=2
        phase=2
    fi

    # Phase 2: Regular chips (>4 chars): truncate right with "...", leftmost first
    if (( phase == 2 )); then
        for (( _idx=cs; _idx<=ce; _idx++ )); do
            [[ "${_SL_TOOLS_ROLES[$_idx]}" == "tool_seg" ]] || continue
            _txt="${_SL_TOOLS_TEXTS[$_idx]}"
            _trimmed="${_txt# }"
            _name_part="${_trimmed% }"
            _count_suffix=""
            if [[ "$_name_part" =~ " [0-9]+$" ]]; then
                _count_suffix=" ${_name_part##* }"
                _name_part="${_name_part% *}"
            fi
            _namelen=${#_name_part}
            if (( _namelen > 4 )); then
                sl_truncate_right "$_name_part" $(( _namelen - 1 ))
                _SL_TOOLS_TEXTS[$_idx]=" ${_sl_trunc_out}${_count_suffix} "
                return 0
            fi
        done
        SL[_shrink.tools.phase]=3
        phase=3
    fi

    # Phase 3: Remove dots from "..." → ".." → "." suffix, leftmost first
    if (( phase == 3 )); then
        for (( _idx=cs; _idx<=ce; _idx++ )); do
            [[ "${_SL_TOOLS_ROLES[$_idx]}" == "tool_seg" ]] || continue
            _txt="${_SL_TOOLS_TEXTS[$_idx]}"
            _trimmed="${_txt# }"
            _name_part="${_trimmed% }"
            _count_suffix=""
            if [[ "$_name_part" =~ " [0-9]+$" ]]; then
                _count_suffix=" ${_name_part##* }"
                _name_part="${_name_part% *}"
            fi
            if [[ "$_name_part" == *"..." || "$_name_part" == *".." ]]; then
                _name_part="${_name_part%.}"
                _SL_TOOLS_TEXTS[$_idx]=" ${_name_part}${_count_suffix} "
                return 0
            fi
        done
        SL[_shrink.tools.phase]=4
        phase=4
    fi

    # Phase 4: 4-char and shorter chips: truncate to min 1 char, leftmost first
    if (( phase == 4 )); then
        for (( _idx=cs; _idx<=ce; _idx++ )); do
            [[ "${_SL_TOOLS_ROLES[$_idx]}" == "tool_seg" ]] || continue
            _txt="${_SL_TOOLS_TEXTS[$_idx]}"
            _trimmed="${_txt# }"
            _name_part="${_trimmed% }"
            _count_suffix=""
            if [[ "$_name_part" =~ " [0-9]+$" ]]; then
                _count_suffix=" ${_name_part##* }"
                _name_part="${_name_part% *}"
            fi
            _namelen=${#_name_part}
            if (( _namelen > 1 )); then
                _SL_TOOLS_TEXTS[$_idx]=" ${_name_part[1]}${_count_suffix} "
                return 0
            fi
        done
        SL[_shrink.tools.phase]=5
        phase=5
    fi

    # All chips at minimum — no more steps
    return 1
}

# ─── Tasks row shrink ─────────────────────────────────────────────────────────
# Phases:
#  0: truncate completed task name right-to-left, min 1 char
#  1: truncate agent descriptions leftmost first, min 1 char
#  2: truncate in-progress task name right-to-left
#  3: truncate pending task name right-to-left
#  4: collapse N checkmarks to single "✓"
_sl_shrink_tasks() {
    local phase="${SL[_shrink.tasks.phase]:-0}"
    local sub="${SL[_shrink.tasks.sub]:-0}"

    # Phase 0: truncate completed name
    if (( phase == 0 )); then
        local cidx="${SL[_layout.tasks.completed_name_idx]:-}"
        if [[ -n "$cidx" ]]; then
            local cur="${_SL_TASKS_TEXTS[$cidx]}"
            # Text is " ✓✓ Name " — find the part after the checkmarks
            # Strip leading " ", trailing " ", find " " after glyphs
            local trimmed="${cur# }"
            trimmed="${trimmed% }"
            # Find position of first space after glyphs (✓ chars)
            local glyph_end=0
            while [[ "${trimmed[$((glyph_end+1))]}" == "✓" ]]; do
                (( glyph_end++ ))
            done
            local prefix="${trimmed[1,$glyph_end]}"  # the ✓ part
            local name_part="${trimmed[$((glyph_end+2)),-1]}"  # skip space after glyphs
            local namelen=${#name_part}
            if (( namelen > 1 )); then
                sl_truncate_right "$name_part" $(( namelen - 1 ))
                _SL_TASKS_TEXTS[$cidx]=" ${prefix} ${_sl_trunc_out} "
                return 0
            fi
        fi
        SL[_shrink.tasks.phase]=1; SL[_shrink.tasks.sub]=0
        phase=1; sub=0
    fi

    # Phase 1: truncate agent descriptions, leftmost first
    if (( phase == 1 )); then
        local as="${SL[_layout.tasks.agents_start]:-}" ae="${SL[_layout.tasks.agents_end]:-}"
        if [[ -n "$as" && -n "$ae" && "$as" -le "$ae" ]]; then
            local i=""
            for (( i=as; i<=ae; i++ )); do
                local txt="${_SL_TASKS_TEXTS[$i]}"
                # Text is " ◐ desc" — prefix is " ◐ "
                if [[ "$txt" == " ◐ "* ]]; then
                    local desc="${txt#" ◐ "}"
                    local desclen=${#desc}
                    if (( desclen > 1 )); then
                        sl_truncate_right "$desc" $(( desclen - 1 ))
                        _SL_TASKS_TEXTS[$i]=" ◐ ${_sl_trunc_out}"
                        SL[_shrink.tasks.sub]=$(( i - as ))
                        return 0
                    fi
                fi
            done
        fi
        SL[_shrink.tasks.phase]=2; SL[_shrink.tasks.sub]=0
        phase=2; sub=0
    fi

    # Phase 2: truncate in-progress task name
    if (( phase == 2 )); then
        local iidx="${SL[_layout.tasks.in_progress_idx]:-}"
        if [[ -n "$iidx" ]]; then
            local cur="${_SL_TASKS_TEXTS[$iidx]}"
            # Text is " ◐ Name " or " ◐ "
            if [[ "$cur" == " ◐ "* ]]; then
                local suffix="${cur#" ◐ "}"
                suffix="${suffix% }"
                local slen=${#suffix}
                if (( slen > 1 )); then
                    sl_truncate_right "$suffix" $(( slen - 1 ))
                    _SL_TASKS_TEXTS[$iidx]=" ◐ ${_sl_trunc_out} "
                    return 0
                fi
            fi
        fi
        SL[_shrink.tasks.phase]=3; SL[_shrink.tasks.sub]=0
        phase=3; sub=0
    fi

    # Phase 3: truncate pending task name
    if (( phase == 3 )); then
        local pidx="${SL[_layout.tasks.pending_idx]:-}"
        if [[ -n "$pidx" ]]; then
            local cur="${_SL_TASKS_TEXTS[$pidx]}"
            # Text is " ○○ Name " or " ○ "
            local trimmed="${cur# }"
            trimmed="${trimmed% }"
            # find glyph prefix (○ chars)
            local glyph_end=0
            while [[ "${trimmed[$((glyph_end+1))]}" == "○" ]]; do
                (( glyph_end++ ))
            done
            local gprefix="${trimmed[1,$glyph_end]}"
            local name_part=""
            if (( glyph_end < ${#trimmed} )); then
                name_part="${trimmed[$((glyph_end+2)),-1]}"
            fi
            local namelen=${#name_part}
            if (( namelen > 1 )); then
                sl_truncate_right "$name_part" $(( namelen - 1 ))
                _SL_TASKS_TEXTS[$pidx]=" ${gprefix} ${_sl_trunc_out} "
                return 0
            fi
        fi
        SL[_shrink.tasks.phase]=4; SL[_shrink.tasks.sub]=0
        phase=4; sub=0
    fi

    # Phase 4: collapse N checkmarks to single "✓"
    if (( phase == 4 )); then
        local gidx="${SL[_layout.tasks.glyphs_idx]:-}"
        if [[ -n "$gidx" ]]; then
            local cur="${_SL_TASKS_TEXTS[$gidx]}"
            local trimmed="${cur# }"
            trimmed="${trimmed% }"
            # Count leading ✓ glyphs
            local nc=0
            while [[ "${trimmed[$((nc+1))]}" == "✓" ]]; do (( nc++ )); done
            if (( nc > 1 )); then
                local rest="${trimmed[$((nc+1)),-1]}"
                _SL_TASKS_TEXTS[$gidx]=" ✓${rest} "
                SL[_shrink.tasks.phase]=5
                return 0
            fi
        fi
        SL[_shrink.tasks.phase]=5
        phase=5
    fi

    return 1
}

# Zero out all parallel arrays for a given row.
_sl_remove_row() {
    local row=$1
    eval "_SL_${row}_TEXTS=()"
    eval "_SL_${row}_ROLES=()"
    eval "_SL_${row}_METAS=()"
    eval "_SL_${row}_LINKS=()"
}

# Try to wrap a row into 2 output lines at a segment boundary.
# Finds the last segment boundary where line 1 fits within term_cols.
# If both halves fit, stores the split index in SL[_layout.<ROW>.wrap_at].
_sl_try_wrap() {
    local row=$1 tc=$2
    local -a texts roles
    eval "texts=(\"\${_SL_${row}_TEXTS[@]}\")"
    eval "roles=(\"\${_SL_${row}_ROLES[@]}\")"
    local n=${#texts[@]}
    (( n < 2 )) && return 1

    # Walk segments. Only allow splits at "clean" boundaries —
    # never split inside a bar group (bar_filled, bar_badge, bar_empty).
    # A valid split point is after segment i where segment i+1 is NOT bar_filled/badge/empty.
    local cum=0 best_split=0
    for (( _tw_i=1; _tw_i<=n; _tw_i++ )); do
        sl_display_width "${texts[$_tw_i]}"
        (( cum += _sl_dw ))
        if (( cum <= tc && _tw_i < n )); then
            local _next_role="${roles[$(( _tw_i + 1 ))]}"
            # Only allow split if next segment isn't mid-bar
            if [[ "$_next_role" != "bar_filled" && "$_next_role" != "bar_badge" && "$_next_role" != "bar_empty" ]]; then
                best_split=$_tw_i
            fi
        fi
    done

    (( best_split == 0 )) && { SL[_layout.${row}.wrap_at]=""; return 1; }

    local second_half=0
    for (( _tw_i=best_split+1; _tw_i<=n; _tw_i++ )); do
        sl_display_width "${texts[$_tw_i]}"
        (( second_half += _sl_dw ))
    done
    if (( second_half <= tc )); then
        SL[_layout.${row}.wrap_at]="$best_split"
        return 0
    fi

    SL[_layout.${row}.wrap_at]=""
    return 1
}

# ── Responsive layout engine ──────────────────────────────────────────────────
# Called after sl_layout, before sl_style.
#
# Algorithm: shrink first, wrap as fallback, budget enforcement last.
#   1. Shrink all rows to fit in 1 line (widest-first).
#   2. If a row can't shrink to 1 line but CAN wrap to 2: wrap it.
#   3. Enforce 6-line budget: un-wrap or remove lowest-priority rows.
#   Priority: META > REPO > TOOLS > TASKS. META never removed.
sl_layout_responsive() {
    local term_cols="${SL[_raw.tty_cols]:-9999}"
    local -A _step_counters=()

    # Priority order (index 1 = highest, kept longest) and budget-removal
    # order (reverse, excluding the protected index-1 row) are derived from
    # SL_LAYOUT_ORDER so a single config edit reorders display AND shrink
    # priority. Override both here (or split into two arrays) if they need
    # to diverge.
    local -a prio_rows=()
    local _rr
    for _rr in "${SL_LAYOUT_ORDER[@]}"; do
        prio_rows+=("${(U)_rr}")
    done
    local -a reverse_prio=()
    local _ri
    for (( _ri = ${#prio_rows[@]}; _ri >= 2; _ri-- )); do
        reverse_prio+=("${prio_rows[$_ri]}")
    done

    for _rr in "${prio_rows[@]}"; do
        _step_counters[$_rr]=0
        SL[_layout.${_rr}.wrap_at]=""
    done

    # PHASE 1: WRAP any row that exceeds term_cols (all rows can wrap).
    for _rr in "${prio_rows[@]}"; do
        sl_measure_row "$_rr"
        (( _sl_row_width == 0 || _sl_row_width <= term_cols )) && continue
        _sl_try_wrap "$_rr" "$term_cols"
    done

    # PHASE 2: ENFORCE 6-LINE BUDGET.
    # Count total lines. Un-wrap lowest-priority first, then remove.
    # reverse_prio is derived from SL_LAYOUT_ORDER above (index 1 is protected).
    local _total=0
    for _rr in "${prio_rows[@]}"; do
        sl_measure_row "$_rr"
        (( _sl_row_width == 0 )) && continue
        [[ -n "${SL[_layout.${_rr}.wrap_at]:-}" ]] && (( _total += 2 )) || (( _total += 1 ))
    done
    for _rr in "${reverse_prio[@]}"; do
        (( _total <= 6 )) && break
        [[ -n "${SL[_layout.${_rr}.wrap_at]:-}" ]] || continue
        SL[_layout.${_rr}.wrap_at]=""
        (( _total -= 1 ))
    done
    for _rr in "${reverse_prio[@]}"; do
        (( _total <= 6 )) && break
        sl_measure_row "$_rr"
        (( _sl_row_width == 0 )) && continue
        _sl_remove_row "$_rr"
        (( _total -= 1 ))
    done

    # PHASE 3: SHRINK rows that still exceed their allocated width.
    # Wrapped = 2×term_cols, unwrapped = term_cols.
    local _max_iters=500
    while (( _max_iters-- > 0 )); do
        local widest_row="" widest_excess=0
        for _rr in "${prio_rows[@]}"; do
            sl_measure_row "$_rr"
            (( _sl_row_width == 0 )) && continue
            local _limit=$term_cols
            [[ -n "${SL[_layout.${_rr}.wrap_at]:-}" ]] && _limit=$(( term_cols * 2 ))
            local _exc=$(( _sl_row_width - _limit ))
            if (( _exc > 0 && _exc > widest_excess )); then
                widest_excess=$_exc
                widest_row="$_rr"
            fi
        done
        [[ -z "$widest_row" ]] && break

        local _step=${_step_counters[$widest_row]}
        if ! _sl_shrink_${widest_row:l} $_step; then
            if [[ "$widest_row" != "META" ]]; then
                _sl_remove_row "$widest_row"
            else
                break
            fi
        else
            _step_counters[$widest_row]=$(( _step + 1 ))
            # If shrunk to fit in 1 line, clear wrap
            sl_measure_row "$widest_row"
            if (( _sl_row_width <= term_cols )); then
                SL[_layout.${widest_row}.wrap_at]=""
            elif [[ -n "${SL[_layout.${widest_row}.wrap_at]:-}" ]]; then
                _sl_try_wrap "$widest_row" "$term_cols"
            fi
        fi
    done

    # If the protected row (index 1 of SL_LAYOUT_ORDER, conventionally META)
    # can't fit even after wrapping, remove everything else.
    local _protected="${prio_rows[1]}"
    sl_measure_row "$_protected"
    local _meta_limit=$term_cols
    [[ -n "${SL[_layout.${_protected}.wrap_at]:-}" ]] && _meta_limit=$(( term_cols * 2 ))
    if (( _sl_row_width > _meta_limit )); then
        for _rr in "${reverse_prio[@]}"; do
            _sl_remove_row "$_rr"
        done
    fi

    # Diagnostic: log responsive decisions when STATUSLINE_DEBUG is set
    if [[ -n "${STATUSLINE_DEBUG:-}" ]]; then
        {
            local _diag_r
            printf 'cols=%s ' "$term_cols"
            for _diag_r in META REPO TOOLS TASKS; do
                sl_measure_row "$_diag_r"
                printf '%s=%d ' "$_diag_r" "$_sl_row_width"
            done
            printf '\n'
        } >> /tmp/statusline-responsive.log
    fi
}

# ── Pipeline ─────────────────────────────────────────────────────────────────
sl_detect_width
sl_input
sl_run_build
sl_layout
sl_layout_responsive
sl_style
