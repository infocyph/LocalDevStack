#!/usr/bin/env bash
set -euo pipefail

command -v graphify >/dev/null 2>&1 || {
  printf 'graphify-roundtrip-contract: graphify is required\n' >&2
  exit 69
}
command -v jq >/dev/null 2>&1 || {
  printf 'graphify-roundtrip-contract: jq is required\n' >&2
  exit 69
}

tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT INT TERM

cat >"$tmp/staged.json" <<'JSON'
{
  "directed": false,
  "multigraph": false,
  "graph": {},
  "nodes": [
    {
      "id": "src_runtime_php_runtime",
      "label": "Runtime",
      "file_type": "code",
      "source_file": "src/Runtime.php",
      "source_location": "L1",
      "_origin": "ast"
    },
    {
      "id": "docstruct_docs_guide_repeat_a",
      "label": "Repeated heading",
      "file_type": "document",
      "source_file": "/workspace/docs/guide.md",
      "source_location": "L2",
      "docstruct_origin": "docker-tools.docstruct/v1"
    },
    {
      "id": "docstruct_docs_guide_repeat_b",
      "label": "Repeated heading",
      "file_type": "document",
      "source_file": "/workspace/docs/guide.md",
      "source_location": "L8",
      "docstruct_origin": "docker-tools.docstruct/v1"
    }
  ],
  "links": [
    {
      "source": "src_runtime_php_runtime",
      "target": "docstruct_docs_guide_repeat_a",
      "relation": "references",
      "confidence": "EXTRACTED",
      "confidence_score": 1.0,
      "source_file": "src/Runtime.php"
    },
    {
      "source": "src_runtime_php_runtime",
      "target": "docstruct_docs_guide_repeat_b",
      "relation": "references",
      "confidence": "EXTRACTED",
      "confidence_score": 1.0,
      "source_file": "src/Runtime.php"
    }
  ],
  "hyperedges": []
}
JSON

run_roundtrip() {
  local input="$1" dir="$2"
  mkdir -p "$dir"
  cp "$input" "$dir/staged.json"
  (
    cd "$dir"
    graphify cluster-only --graph "$dir/staged.json" --no-label --no-viz >/dev/null
  )
  [[ -s "$dir/graphify-out/graph.json" ]] || {
    printf 'graphify-roundtrip-contract: no canonical graph produced\n' >&2
    exit 1
  }
}

run_roundtrip "$tmp/staged.json" "$tmp/first"
run_roundtrip "$tmp/first/graphify-out/graph.json" "$tmp/second"

raw_nodes="$(jq '.nodes | length' "$tmp/staged.json")"
first_nodes="$(jq '.nodes | length' "$tmp/first/graphify-out/graph.json")"
second_nodes="$(jq '.nodes | length' "$tmp/second/graphify-out/graph.json")"

((first_nodes <= raw_nodes)) || {
  printf 'graphify-roundtrip-contract: canonicalization unexpectedly grew nodes: %s -> %s\n' "$raw_nodes" "$first_nodes" >&2
  exit 1
}
[[ "$first_nodes" == "$second_nodes" ]] || {
  printf 'graphify-roundtrip-contract: canonical output is not idempotent: %s -> %s\n' "$first_nodes" "$second_nodes" >&2
  exit 1
}

for graph in "$tmp/first/graphify-out/graph.json" "$tmp/second/graphify-out/graph.json"; do
  jq -e '.nodes | any(.id == "src_runtime_php_runtime" and .file_type == "code")' "$graph" >/dev/null ||
    {
      printf 'graphify-roundtrip-contract: code node was lost during canonicalization\n' >&2
      exit 1
    }
done

printf 'graphify-roundtrip-contract: ok (%s -> %s -> %s nodes)\n' "$raw_nodes" "$first_nodes" "$second_nodes"
