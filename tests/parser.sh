#!/usr/bin/env bash
# Prüft den in install.sh eingebetteten Parser (PARSER) gegen Beispielausgaben von Claude Code.
# Die Beispiele unter tests/fixtures stammen aus Claude Code 2.1.314 (stream-json, gekürzt), aufgenommen
# gegen einen lokalen Stub-Server statt der echten API.
set -euo pipefail
cd "$(dirname "$0")/.."

parser=$(sed -n "/^PARSER=\$(cat <<'PY'\$/,/^PY\$/p" install.sh | sed '1d;$d')
[[ -n $parser ]] || { echo "PARSER in install.sh nicht gefunden" >&2; exit 1; }

fail=0
for expected in tests/fixtures/*.expected; do
  input=${expected%.expected}.jsonl
  got=$(python3 -I -c "$parser" "$input")
  if [[ $got == "$(<"$expected")" ]]; then
    echo "ok      ${input##*/}"
  else
    echo "FEHLER  ${input##*/}"
    diff <(printf '%s\n' "$got") "$expected" || true
    fail=1
  fi
done
exit "$fail"
