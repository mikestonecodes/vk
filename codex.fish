#!/usr/bin/env fish
# Project-local Codex launcher with preferred defaults
# Model: gpt5, Approval policy: never (auto-approve)

exec codex --model gpt5-high --ask-for-approval untrusted $argv
