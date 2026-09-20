#!/usr/bin/env bash
# subagentStart hard gate: deny Claude/Sonnet/Opus models and
# computerUse/browser subagents. Fail closed if the payload cannot be read.
set -eu

input=$(cat || true)
if [ -z "${input}" ]; then
  printf '%s\n' '{"permission":"deny","user_message":"Blocked: empty subagentStart payload (fail closed)."}'
  exit 0
fi

lower=$(printf '%s' "$input" | tr '[:upper:]' '[:lower:]')

json_get() {
  key=$1
  printf '%s' "$lower" | tr '\n' ' ' | sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" | head -n 1
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

# Catch model names that appear anywhere in the payload even if the key differs.
if printf '%s' "$lower" | grep -Eq '"model"[[:space:]]*:[[:space:]]*"[^"]*(claude|sonnet|opus|gpt-|chatgpt|gemini)'; then
  deny "Blocked: non-Grok model requested. Only Grok 4.6 or an omitted/inherit model is allowed."
fi

printf '%s\n' '{"permission":"allow"}'
exit 0
