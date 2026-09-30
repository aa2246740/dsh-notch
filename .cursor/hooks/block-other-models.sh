#!/usr/bin/env bash
# subagentStart hard gate: deny Claude/Sonnet/Opus models and
# computerUse/browser subagents. Fail closed if the payload cannot be read.
set -eu

# Cursor on Windows may launch hooks without Git's usr/bin on PATH.
if ! command -v sed >/dev/null 2>&1 || ! command -v tr >/dev/null 2>&1; then
  if [ -n "${LOCALAPPDATA:-}" ] && [ -d "${LOCALAPPDATA}/AI-Air-Helper/MinGit/usr/bin" ]; then
    PATH="${LOCALAPPDATA}/AI-Air-Helper/MinGit/usr/bin:/usr/bin:/bin:${PATH:-}"
  else
    PATH="/usr/bin:/bin:${PATH:-}"
  fi
  export PATH
fi

# Slurp stdin without cat so a missing coreutils still fail-closed on empty.
input=""
while IFS= read -r line || [ -n "${line:-}" ]; do
  if [ -n "$input" ]; then
    input="${input}
${line}"
  else
    input="$line"
  fi
done

if [ -z "${input}" ]; then
  printf '%s\n' '{"permission":"deny","user_message":"Blocked: empty subagentStart payload (fail closed)."}'
  exit 0
fi

to_lower() {
  if command -v tr >/dev/null 2>&1; then
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
  elif command -v sed >/dev/null 2>&1; then
    printf '%s' "$1" | sed 'y/ABCDEFGHIJKLMNOPQRSTUVWXYZ/abcdefghijklmnopqrstuvwxyz/'
  else
    printf '%s' "$1"
  fi
}

lower=$(to_lower "$input")

json_get() {
  key=$1
  if command -v sed >/dev/null 2>&1; then
    printf '%s' "$lower" | tr '\n' ' ' | sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" | sed -n '1p'
  else
    printf ''
  fi
}

model=$(json_get model)
subagent_type=$(json_get subagent_type)
if [ -z "$subagent_type" ]; then
  subagent_type=$(json_get subagentType)
fi
if [ -z "$subagent_type" ]; then
  subagent_type=$(json_get type)
fi
composer=$(json_get composer)
if [ -z "$composer" ]; then
  composer=$(json_get composer_mode)
fi

deny() {
  printf '%s\n' "{\"permission\":\"deny\",\"user_message\":\"$1\"}"
  exit 0
}

case "$subagent_type" in
  *computeruse*|*computer-use*|*computer_use*|*browser*)
    deny "Blocked: computerUse/browser subagents are not allowed. Stay on the parent Grok agent."
    ;;
esac

case "$composer" in
  *computeruse*|*computer-use*|*browser*)
    deny "Blocked: computerUse/browser composer modes are not allowed. Stay on the parent Grok agent."
    ;;
esac

case "$model" in
  *claude*|*sonnet*|*opus*)
    deny "Blocked: Claude/Sonnet/Opus models are not allowed. Inherit the parent Grok 4.6 model."
    ;;
  *gpt*|*gemini*|*chatgpt*)
    deny "Blocked: GPT/Gemini models are not allowed. Inherit the parent Grok 4.6 model."
    ;;
esac

case "$lower" in
  *'"model":'*claude*|*'"model":'*sonnet*|*'"model":'*opus*|*'"model":'*gpt-*|*'"model":'*chatgpt*|*'"model":'*gemini*)
    deny "Blocked: non-Grok model requested. Only Grok 4.6 or an omitted/inherit model is allowed."
    ;;
esac

printf '%s\n' '{"permission":"allow"}'
exit 0
