# vxlan-tracer exit codes

## Contract

| Code | Meaning |
|------|---------|
| 0 | Ran to completion. A diagnostic verdict was produced (any verdict). Check the verdict field in the output. |
| 2 | Tool/runtime error. The binary could not complete the run: missing BPF objects, attachment failure, map open error, etc. No verdict was produced. |

## Why not exit 1 for adverse verdicts?

Exit code 0 for every successful run (including adverse verdicts like
`PTB_SUPPRESSED` or `VXLAN_FRAGMENTATION_OBSERVED`) lets scripts distinguish
"the tool ran and found something" from "the tool crashed before finding
anything." Callers that want to act on a specific verdict should parse
the `--json` output:

```bash
verdict=$(vxlan-tracer --json ... | python3 -c "import sys,json; print(json.load(sys.stdin)['verdict'])")
case "$verdict" in
  PTB_SUPPRESSED) echo "Action: remove iptables DROP rule" ;;
  VXLAN_FRAGMENTATION_OBSERVED) echo "Action: lower overlay MTU" ;;
  *) echo "Verdict: $verdict" ;;
esac
```

## Exit code 2 triggers

- `--bpf-dir` path missing or BPF objects not found
- `loader.Attach()` failure (TC filter, kprobe, or qdisc error)
- `bpfmap.OpenPinned()` failure during the read phase
- Flag parse error

## Exit code 0 does NOT mean "healthy"

A run that exits 0 with verdict `PTB_SUPPRESSED` indicates a real network
problem. Exit 0 means only that vxlan-tracer completed its observation window
and produced a verdict — not that the network is healthy.

## Automation notes

The `scripts/run-scenarios.sh` runner asserts `exit_code -ne 0` as a test
failure, separate from the verdict assertion. A tool error (exit 2) causes
an explicit `[FAIL] Binary exited with code 2` before the verdict check.

## History

Before Day 7, tool errors used `os.Exit(1)`. This was ambiguous: exit 1 could
mean "tool failed" or (in other tools) "adverse result found." Changed to
`os.Exit(2)` in Day 7 commit 3 to make the distinction unambiguous.
