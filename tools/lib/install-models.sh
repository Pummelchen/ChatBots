#!/bin/bash
#
# Fetching and verifying checkpoints, for `tools/install.sh`.
#
# Sourced, not executed: it uses the installer's output helpers and `die`, and the download
# functions stay in one place because the integrity rules (a size for every file, resumed
# transfers) only hold if every download goes through them.
#
# Which checkpoints: the one `AgentSpec.defaultModelID` names is always installed — the app's
# first run uses it and the installer's own verification loads it — and the rest of
# `ModelCatalog.choices` is opt-in, through `--model <alias>` / `--models all` or through the
# menu this file prints when it runs on a terminal and was told nothing. The catalogue is read
# out of the Swift source rather than copied here, for the same reason the default is: a second
# copy of a fact is how the two come to disagree.

# Set by `tools/install.sh`; the guard says where it comes from and fails loudly if this file is
# ever sourced without it.
MODELS_DIR="${MODELS_DIR:?MODELS_DIR is set by tools/install.sh}"
CATALOGUE_FILE="$ROOT/Sources/ChatBotsCore/Models/ModelCatalog.swift"

# A connection that stalls *once established* is the failure `--retry` cannot see: curl keeps waiting
# for the next byte and the install looks hung — the outcome the model-loading step below calls the
# worst for someone who just wants the app, and guards against with its own timeout.
# `--max-time` is not the answer: a 3 GB checkpoint on a slow line is slow, not stalled,
# and a total-time cap would abort a download that is still making progress. `--speed-limit` and
# `--speed-time` abort only a transfer that has stopped moving — curl's own definition, slower than
# the limit for that many seconds — which `--retry` then retries and the resume path continues from
# the bytes already on disk. `--connect-timeout` bounds the handshake, which a stall mid-transfer
# does not cover.
CURL_TRANSFER_OPTIONS=(--connect-timeout 20 --speed-limit 1024 --speed-time 30)

# ── The catalogue ───────────────────────────────────────────────────────────────────

# `ModelCatalog.choices`, one entry per line, tab-separated:
# repository id, display name, approximate bytes (empty when unknown), aliases.
#
# Read from the Swift source by shape rather than by compiling it: the installer runs before
# anything is built, and the alternative — a second copy of the three names and sizes — is the
# duplication the rest of this repository goes out of its way to avoid. The shape it reads is the
# one `swift-format` writes, and it fails loudly below if it finds nothing at all.
catalogue_entries() {
  awk '
    /ModelChoice\(/ { id = ""; name = ""; bytes = ""; aliases = ""; block = 1 }
    block && /^[[:space:]]*id:/ {
      id = $0; sub(/^[[:space:]]*id:[[:space:]]*/, "", id); sub(/,?[[:space:]]*$/, "", id)
      gsub(/"/, "", id)
      if (id == "AgentSpec.defaultModelID") { id = "DEFAULT" }
    }
    block && /^[[:space:]]*name:[[:space:]]*"/ {
      name = $0; sub(/^[[:space:]]*name:[[:space:]]*"/, "", name); sub(/",?[[:space:]]*$/, "", name)
    }
    block && /^[[:space:]]*aliases:/ {
      aliases = $0; sub(/^[[:space:]]*aliases:[[:space:]]*\[/, "", aliases)
      sub(/\].*$/, "", aliases); gsub(/"/, "", aliases); gsub(/,/, " ", aliases)
    }
    block && /^[[:space:]]*approximateBytes:/ {
      bytes = $0; sub(/^[[:space:]]*approximateBytes:[[:space:]]*/, "", bytes)
      gsub(/_/, "", bytes); sub(/,?[[:space:]]*$/, "", bytes)
    }
    block && /^[[:space:]]*\),?[[:space:]]*$/ { print id "\t" name "\t" bytes "\t" aliases; block = 0 }
  ' "$CATALOGUE_FILE" 2>/dev/null | sed "s|^DEFAULT|$DEFAULT_CHECKPOINT|"
}

# The checkpoint the app ships with, from the source rather than from a copy of it.
#
# `AgentSpec.defaultModelID` is what the app looks up when it loads a model, and this installer
# has to download the same one into the directory the app will look in: `ModelStore.localCheckpoint`
# tries the tail of the repo id under `models/`, so the directory name is derived from the id rather
# than written down beside it. The macOS minimum used to be duplicated here in exactly this way, and
# the copy was removed rather than adding a check that policed it; this is the same fact in a place
# where a mismatch costs a 3 GB download the app can never see.
default_checkpoint() {
  local id
  id="$(sed -n 's/.*static let defaultModelID = "\([^"]*\)".*/\1/p' \
    "$ROOT/Sources/ChatBotsCore/Room/AgentSpec.swift" | head -1)"
  if [ -z "$id" ]; then
    die "Could not read the default checkpoint from Sources/ChatBotsCore/Room/AgentSpec.swift.

Its \`AgentSpec.defaultModelID\` is the model this installer downloads, so without it there is
nothing to fetch — the declaration may have been renamed or moved. Nothing was downloaded."
  fi
  printf '%s\n' "$id"
}

DEFAULT_CHECKPOINT="$(default_checkpoint)"

# Bytes as a person reads them, in the same decimal units the app's own menu uses.
human_size() {
  case "${1:-}" in
    ''|*[!0-9]*) printf 'size unknown' ;;
    *) awk -v b="$1" 'BEGIN { printf "%.1f GB", b / 1000000000 }' ;;
  esac
}

# An alias, an id tail, a repository id or a catalogue number becomes a repository id.
resolve_checkpoint() {
  local want entry_id entry_name entry_bytes entry_aliases
  want="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  while IFS=$'\t' read -r entry_id entry_name entry_bytes entry_aliases; do
    [ -n "$entry_id" ] || continue
    local lower_id lower_aliases
    lower_id="$(printf '%s' "$entry_id" | tr '[:upper:]' '[:lower:]')"
    lower_aliases="$(printf '%s' "$entry_aliases" | tr '[:upper:]' '[:lower:]')"
    if [ "$lower_id" = "$want" ]; then printf '%s\n' "$entry_id"; return 0; fi
    case " $lower_aliases " in *" $want "*) printf '%s\n' "$entry_id"; return 0 ;; esac
    case "$lower_id" in */"$want") printf '%s\n' "$entry_id"; return 0 ;; esac
  done < <(catalogue_entries)
  # Any repository id works — the catalogue is a set of known-good names, not an allow-list — so a
  # value with a namespace in it is taken as written.
  case "$1" in
    */*) printf '%s\n' "$1"; return 0 ;;
  esac
  return 1
}

catalogue_ids() {
  catalogue_entries | awk -F'\t' 'NF { print $1 }'
}

# The checkpoints to install: the shipped one plus whatever was asked for, in the order asked.
choose_checkpoints() {
  local chosen="$DEFAULT_CHECKPOINT"
  local item entry_id entry_name entry_bytes entry_aliases answer index stable

  if [ "${MODELS_ALL:-0}" -eq 1 ]; then
    while IFS= read -r entry_id; do
      [ -n "$entry_id" ] && chosen="$chosen $entry_id"
    done < <(catalogue_ids)
  fi

  for item in ${MODEL_REQUEST:-}; do
    if ! stable="$(resolve_checkpoint "$item")"; then
      die "There is no checkpoint called '$item'.

Known names: $(catalogue_ids | tr '\n' ' ')
Any other Hugging Face repository id also works, written in full (owner/name)."
    fi
    chosen="$chosen $stable"
  done

  # The menu, only when nothing was asked for, the run is attached to a terminal, and `--yes` was
  # not given. Anything else — a pipe, a script, a repeat run from the launcher — installs the
  # shipped checkpoint and nothing else, which is what this installer has always done.
  if [ -z "${MODEL_REQUEST:-}" ] && [ "${MODELS_ALL:-0}" -eq 0 ] \
    && [ "${INSTALL_ASSUME_YES:-0}" -eq 0 ] && [ -t 0 ]; then
    printf '\n'
    info "This project offers ${BOLD}$(catalogue_ids | wc -l | tr -d ' ')${OFF} checkpoints. The first is installed either way;"
    info "the others are a download you can skip."
    printf '\n'
    index=0
    while IFS=$'\t' read -r entry_id entry_name entry_bytes entry_aliases; do
      [ -n "$entry_id" ] || continue
      index=$((index + 1))
      if [ "$entry_id" = "$DEFAULT_CHECKPOINT" ]; then
        printf '    %s%d)%s %s — %s %s[installed anyway]%s\n' \
          "$BOLD" "$index" "$OFF" "$entry_name" "$(human_size "$entry_bytes")" "$DIM" "$OFF"
      else
        printf '    %s%d)%s %s — %s\n' "$BOLD" "$index" "$OFF" "$entry_name" "$(human_size "$entry_bytes")"
      fi
      dim "        ${entry_aliases:-$entry_id}"
    done < <(catalogue_entries)
    printf '\n'
    printf '    Download which as well? [none] ' >&2
    read -r answer || answer=""
    answer="$(printf '%s' "$answer" | tr ',' ' ')"
    for item in $answer; do
      case "$item" in
        ''|none|no|n) continue ;;
        all)
          while IFS= read -r entry_id; do
            [ -n "$entry_id" ] && chosen="$chosen $entry_id"
          done < <(catalogue_ids)
          ;;
        *[!0-9]*)
          if ! stable="$(resolve_checkpoint "$item")"; then
            warn "'$item' is not one of the numbers or names above; skipping it"
            continue
          fi
          chosen="$chosen $stable"
          ;;
        *)
          stable="$(catalogue_ids | sed -n "${item}p")"
          if [ -z "$stable" ]; then
            warn "There is no checkpoint number $item; skipping it"
            continue
          fi
          chosen="$chosen $stable"
          ;;
      esac
    done
  fi

  # The same checkpoint named twice is downloaded once, and the shipped one keeps its place.
  local deduped="" seen_id
  for seen_id in $chosen; do
    case " $deduped " in
      *" $seen_id "*) continue ;;
    esac
    deduped="$deduped $seen_id"
  done
  printf '%s\n' "$deduped" | tr ' ' '\n' | awk 'NF'
}

# ── One checkpoint ──────────────────────────────────────────────────────────────────

# Downloads `$1` into its own directory under `models/`, verifying every file against the size the
# server reports. Shared by every checkpoint: the resume, the integrity rules and the required-file
# check are the same work whatever the repository is.
install_checkpoint() {
  local MODEL_ID="$1"
  local MODEL_DIR_NAME="${MODEL_ID##*/}"
  # Only the last component of a repository id becomes a directory name, and it has to be one
  # ordinary component. `--model 'x/..'` resolved to the checkout root and would have downloaded
  # into it; `model-target-path.sh` refuses `..` and absolute names for hub-supplied files, and
  # this is the same rule applied to the value the caller supplied.
  case "$MODEL_DIR_NAME" in
    "" | "." | "..")
      warn "refusing the model id '$MODEL_ID': '$MODEL_DIR_NAME' is not a directory name"
      return 1
      ;;
  esac
  local MODEL_DIR="$MODELS_DIR/$MODEL_DIR_NAME"
  local FILE_LIST="$MODELS_DIR/.hf-file-list-$MODEL_DIR_NAME.txt"
  local API_URL="https://huggingface.co/api/models/$MODEL_ID"

  if [ -d "$MODEL_DIR" ]; then
    info "$MODEL_ID (already in $MODELS_DIR)"
  else
    info "$MODEL_ID"
  fi
  mkdir -p "$MODELS_DIR" "$MODEL_DIR"

  # The list is only trusted when every row carries a positive integer size. A zero used to
  # mean "unknown — accept any size", which made the integrity check a no-op: a truncated
  # transfer, or an error page written by `curl -o` without `--fail`, was recorded as a
  # complete model. A list an older installer left with a zero in it is rebuilt, not trusted.
  file_list_is_complete() {
    [ -s "$FILE_LIST" ] || return 1
    ! awk -F'\t' '$2 !~ /^[0-9]+$/ || $2 + 0 == 0 { bad = 1 } END { exit bad ? 0 : 1 }' "$FILE_LIST"
  }

  # Reads the size of every listed file with a HEAD request. The size is what proves a download
  # finished rather than stopping part-way, so when it cannot be read the lookup fails and the
  # installer says so; recording 0 and continuing would remove the check entirely. `--fail`
  # keeps an HTTP error out of the size calculation too.
  #
  # The result is written to a temporary file and moved into place only after every size has
  # been read, so a lookup that stops half-way can never leave a short list that a re-run would
  # treat as complete.
  read_file_sizes() {
    local names_file="$1" name size attempt
    local building="$FILE_LIST.building"
    : > "$building"
    while IFS= read -r name; do
      [ -z "$name" ] && continue
      size=""
      for attempt in 1 2 3; do
        size="$(curl -fsIL --max-time 60 \
          "https://huggingface.co/$MODEL_ID/resolve/main/$name" \
          | tr -d '\r' \
          | awk 'tolower($1) == "content-length:" { value = $2 } END { print value }')" || size=""
        case "$size" in
          ''|*[!0-9]*) size="" ;;
          *) if [ "$size" -gt 0 ]; then break; fi ;;
        esac
        if [ "$attempt" -lt 3 ]; then sleep 3; fi
      done
      if [ -z "$size" ]; then
        rm -f "$building"
        return 1
      fi
      printf "%s\t%s\n" "$name" "$size" >> "$building"
    done < "$names_file"
    mv "$building" "$FILE_LIST"
  }

  if ! file_list_is_complete; then
    if [ ! -s "$FILE_LIST.names" ]; then
      dim "Asking huggingface.co which files this checkpoint has…"
      if ! curl -sSfL --max-time 60 "$API_URL" -o "$MODELS_DIR/.hf-model.json"; then
        die "Could not look up the model files. The connection may have dropped."
      fi

      if ! python3 "$SCRIPT_DIR/hf-file-list.py" "$MODELS_DIR/.hf-model.json" > "$FILE_LIST.names"; then
        die "The checkpoint did not come back with a usable file list. This usually means the
model name is wrong or the repository has moved."
      fi
    fi

    dim "Reading file sizes from the server…"
    if ! read_file_sizes "$FILE_LIST.names"; then
      die "The size of one or more model files could not be read from huggingface.co, so the
download cannot be verified and was not started.

This is usually a dropped connection or a rate limit, and running the script again retries
it. It is deliberately fatal: without the size there is nothing to check the download
against, and this installer will not record a model it cannot verify as complete."
    fi
    rm -f "$FILE_LIST.names"
  fi

  local TOTAL_FILES
  TOTAL_FILES="$(wc -l < "$FILE_LIST" | tr -d ' ')"
  info "This checkpoint has $TOTAL_FILES files."

  download_file() {
    local name="$1" expected="$2"
    local url="https://huggingface.co/$MODEL_ID/resolve/main/$name"
    # Where it belongs, and the directory it needs. The list comes from the hub, so the name may be a
    # nested path (`original/config.json`) — which `curl -o` cannot write into a directory that does not
    # exist — and it may not be trusted to stay inside the model directory.
    local target
    if ! target="$(bash "$SCRIPT_DIR/model-target-path.sh" "$MODEL_DIR" "$name" 2>&1)"; then
      fail "refusing to download $name"
      dim "$target"
      return 1
    fi

    # A zero or non-numeric size is not "unknown, so accept anything": it means this file
    # cannot be verified, and an unverifiable model file is not recorded as complete. The size
    # list is validated before it is used, so this only fires on a corrupt or hand-edited list.
    case "$expected" in
      ''|*[!0-9]*|0)
        fail "$name has no size to verify against — refusing to download it"
        return 1
        ;;
    esac

    if [ -f "$target" ]; then
      # A file whose size matches is complete; one that is short was interrupted.
      local actual
      actual="$(stat -f%z "$target" 2>/dev/null || echo 0)"
      if [ "$actual" = "$expected" ]; then
        ok "$name (already downloaded)"
        return 0
      fi
      dim "$name is incomplete ($actual of $expected bytes) — continuing it"
      # `-C -` resumes from where it stopped, which matters for a 3 GB file. `--fail` keeps an
      # error response out of the file, so a 404 page is never resumed into model bytes. The deadline
      # options are `CURL_TRANSFER_OPTIONS` above: a stall fails here instead of hanging, and the
      # retry resumes it.
      if curl -fsSL -C - "${CURL_TRANSFER_OPTIONS[@]}" --retry 5 --retry-delay 3 --retry-all-errors \
          -o "$target" "$url"; then
        actual="$(stat -f%z "$target" 2>/dev/null || echo 0)"
        if [ "$actual" = "$expected" ]; then
          ok "$name (resumed)"
          return 0
        fi
      fi
      # A resume the server does not honour leaves a corrupt file; start over rather than
      # keep a file that will fail in a confusing way later.
      warn "$name could not be resumed — downloading it again from the start"
      rm -f "$target"
    fi

    local human
    human="$(awk -v b="$expected" 'BEGIN { printf "%.0f MB", b/1048576 }')"
    info "$name ($human)"
    if ! curl -fL "${CURL_TRANSFER_OPTIONS[@]}" --retry 5 --retry-delay 3 --retry-all-errors --progress-bar \
        -o "$target" "$url"; then
      fail "$name did not finish downloading"
      return 1
    fi

    local actual
    actual="$(stat -f%z "$target" 2>/dev/null || echo 0)"
    if [ "$actual" != "$expected" ]; then
      fail "$name is the wrong size ($actual of $expected bytes)"
      # An error page or a truncated transfer is not a partial download, so it is removed
      # rather than left for a resume that would build on corrupt bytes.
      rm -f "$target"
      return 1
    fi
    ok "$name"
    return 0
  }

  local FAILED_DOWNLOADS=0
  while IFS=$'\t' read -r name expected; do
    [ -z "$name" ] && continue
    download_file "$name" "$expected" || FAILED_DOWNLOADS=$((FAILED_DOWNLOADS + 1))
  done < "$FILE_LIST"

  if [ "$FAILED_DOWNLOADS" -gt 0 ]; then
    die "$FAILED_DOWNLOADS file(s) of $MODEL_ID could not be downloaded.

The files that did arrive are kept, so running this script again continues from here rather
than starting over."
  fi

  # The loader refuses a checkpoint that is missing these, so say so now rather than at the
  # first conversation.
  local required
  for required in config.json tokenizer.json; do
    if [ ! -f "$MODEL_DIR/$required" ]; then
      die "The checkpoint $MODEL_ID is missing $required, so the model cannot be loaded."
    fi
  done
  if [ ! -f "$MODEL_DIR/model.safetensors" ] && [ ! -f "$MODEL_DIR/model-00001-of-00001.safetensors" ]; then
    die "The checkpoint $MODEL_ID has no weights file, so the model cannot be loaded."
  fi
  ok "Model ready at $MODEL_DIR"
}

# "about 12.2 GB", or "at least 9.2 GB" when a catalogue entry has no recorded size.
checkpoint_size_label() {
  local want bytes total=0 unknown=0
  while IFS= read -r want; do
    [ -n "$want" ] || continue
    bytes="$(catalogue_entries | awk -F'\t' -v want="$want" '$1 == want { print $3 }')"
    case "$bytes" in
      ''|*[!0-9]*) unknown=$((unknown + 1)) ;;
      *) total=$((total + bytes)) ;;
    esac
  done < <(printf '%s\n' "$CHECKPOINTS")
  if [ "$unknown" -gt 0 ]; then
    awk -v b="$total" 'BEGIN { printf "at least %.1f GB", b / 1000000000 }'
  else
    awk -v b="$total" 'BEGIN { printf "about %.1f GB", b / 1000000000 }'
  fi
}

# ── The checkpoints this run installs ───────────────────────────────────────────────

step "Downloading the models"

CHECKPOINTS="$(choose_checkpoints)"
if [ -z "$CHECKPOINTS" ]; then
  die "No checkpoint was selected, and the installer needs one to check that the app works."
fi

CHECKPOINT_COUNT="$(printf '%s\n' "$CHECKPOINTS" | wc -l | tr -d ' ')"
if [ "$CHECKPOINT_COUNT" -gt 1 ]; then
  info "Installing $CHECKPOINT_COUNT checkpoints — $(checkpoint_size_label) of weights."
else
  info "The rest of the catalogue is optional; see 'bash tools/install.sh --help'."
fi

for checkpoint in $CHECKPOINTS; do
  install_checkpoint "$checkpoint"
done

ok "Installed: $(printf '%s\n' "$CHECKPOINTS" | tr '\n' ' ')"
