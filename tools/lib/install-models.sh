#!/bin/bash
#
# Fetching and verifying the default checkpoint, for `tools/install.sh`.
#
# Sourced, not executed: it uses the installer's output helpers and `die`, and the download
# functions stay in one place because the integrity rules (a size for every file, resumed
# transfers) only hold if every download goes through them.

# Set by `tools/install.sh`; the guard says where it comes from and fails loudly if this file is
# ever sourced without it.
MODELS_DIR="${MODELS_DIR:?MODELS_DIR is set by tools/install.sh}"

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

# ── Models ──────────────────────────────────────────────────────────────────────────
# The checkpoint comes from the source rather than from a copy of it. `AgentSpec.defaultModelID`
# is what the app looks up when it loads a model, and this installer has to download the same one into
# the directory the app will look in: `ModelStore.localCheckpoint` tries the tail of the repo id under
# `models/` (`ModelStore.swift`), so the directory name is derived from the id rather than written down
# beside it. The macOS minimum used to be duplicated here in exactly this way, and the copy was removed
# rather than adding a check that policed it; this is the same fact in a place where a mismatch
# costs a 3 GB download the app can never see.
#
# Resumable and verified: each file is checked against the size the server reports, so an
# interrupted download is detected and continued rather than silently accepted. A file whose
# size cannot be learned is refused rather than recorded as 0 and then waved through — see
# `file_list_is_complete` and `download_file` below.
step "Downloading the models"
MODEL_ID="$(sed -n 's/.*static let defaultModelID = "\([^"]*\)".*/\1/p' \
  "$ROOT/Sources/ChatBotsCore/Room/AgentSpec.swift" | head -1)"
if [ -z "$MODEL_ID" ]; then
  die "Could not read the default checkpoint from Sources/ChatBotsCore/Room/AgentSpec.swift.

Its \`AgentSpec.defaultModelID\` is the model this installer downloads, so without it there is
nothing to fetch — the declaration may have been renamed or moved. Nothing was downloaded."
fi
MODEL_DIR_NAME="${MODEL_ID##*/}"
info "Checkpoint: $MODEL_ID"
mkdir -p "$MODELS_DIR"
MODEL_DIR="$MODELS_DIR/$MODEL_DIR_NAME"
mkdir -p "$MODEL_DIR"

API_URL="https://huggingface.co/api/models/$MODEL_ID"
FILE_LIST="$MODELS_DIR/.huggingface-file-list.txt"

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

FAILED_DOWNLOADS=0
while IFS=$'\t' read -r name expected; do
  [ -z "$name" ] && continue
  download_file "$name" "$expected" || FAILED_DOWNLOADS=$((FAILED_DOWNLOADS + 1))
done < "$FILE_LIST"

if [ "$FAILED_DOWNLOADS" -gt 0 ]; then
  die "$FAILED_DOWNLOADS file(s) could not be downloaded.

The files that did arrive are kept, so running this script again continues from here rather
than starting over."
fi

# The loader refuses a checkpoint that is missing these, so say so now rather than at the
# first conversation.
for required in config.json tokenizer.json; do
  if [ ! -f "$MODEL_DIR/$required" ]; then
    die "The checkpoint is missing $required, so the model cannot be loaded."
  fi
done
if [ ! -f "$MODEL_DIR/model.safetensors" ] && [ ! -f "$MODEL_DIR/model-00001-of-00001.safetensors" ]; then
  die "The checkpoint has no weights file, so the model cannot be loaded."
fi
ok "Model ready at $MODEL_DIR"
