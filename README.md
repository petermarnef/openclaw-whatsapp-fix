# OpenClaw WhatsApp Outbound Fix

**Version:** 2026.3.13 (61d171a)  
**Bug type:** Rollup code-splitting duplicates module state  
**Fix type:** Post-build monkey-patch (globalThis singleton)

---

## Problem Summary

OpenClaw 2026.3.13 contains a code-splitting bug in the Rollup bundler output. The WhatsApp listener registry (`src/web/active-listener.ts`) is duplicated across multiple JavaScript chunks, resulting in **two parallel "worlds"** in the `dist/` output — each with its own independent `listeners = new Map()`.

**World A** (anchored at `model-selection-46xMp11W.js`):
- `web-B73xP3XL.js`, `outbound-D7dWdMso.js`, `extensionAPI.js`, ...

**World B** (anchored at `model-selection-CU2b7bN6.js`):
- `web-Cz_8x_nz.js`, `outbound-DgkEpLB5.js`, `agent-BeieZAG2.js`, ...

At gateway startup, OpenClaw selects one world for the WhatsApp provider (`setActiveWebListener`), but tool calls may execute through the other world (`requireActiveWebListener`). The result: Map A is populated while Map B is empty, or vice versa.

**Symptom:**
- ✅ Inbound messages work (uses `msg.reply()` with a direct socket reference — Map not consulted)
- ✅ Auto-replies work (same path as inbound)
- ❌ Outbound via the `message` tool fails with: `No active WhatsApp Web listener`
- ❌ Cron jobs sending WhatsApp messages fail silently

---

## The Fix

Replace the module-local Map with a `globalThis` singleton so all chunks share the same registry regardless of which bundler world they belong to.

### Before (original, in 6 files):
```javascript
const listeners = /* @__PURE__ */ new Map();
```

### After (patched):
```javascript
const listeners = globalThis.__openclaw_wa_listeners ??= new Map();
```

The `??=` operator (nullish coalescing assignment) creates the Map only once — whichever chunk runs first. All subsequent chunks reuse the same Map. This is safe in Node.js because it is single-threaded and Map operations are synchronous.

---

## Affected Files (OpenClaw 2026.3.13)

Location: `/opt/homebrew/Cellar/openclaw-cli/2026.3.13/libexec/lib/node_modules/openclaw/dist/`

| # | File | Notes |
|---|------|-------|
| 1 | `auth-profiles-DDVivXkv.js` | Contains `active-listener.ts` region |
| 2 | `auth-profiles-DRjqKE3G.js` | Contains `active-listener.ts` region |
| 3 | `discord-CcCLMjHw.js` | Contains `active-listener.ts` region |
| 4 | `model-selection-46xMp11W.js` | Contains `active-listener.ts` region — **World A** |
| 5 | `model-selection-CU2b7bN6.js` | Contains `active-listener.ts` region — **World B** |
| 6 | `reply-Bm8VrLQh.js` | Contains `active-listener.ts` region |

> ⚠️ **GPT peer review notes a potential 7th file:** `plugin-sdk/thread-bindings-SYAnWHuW.js` may also contain a copy of `src/web/active-listener.ts`. Use the `detect` subcommand in `patch/apply-fix.sh` to verify your installation and patch all copies. See [docs/peer-review-gpt.md](docs/peer-review-gpt.md) for details.

### ⚠️ Do NOT patch `entry.js`

`entry.js` also contains `const listeners = new Map()` but this is a **completely different Map** used for process signal handlers (`SIGTERM`, `SIGINT`) inside `attachChildProcessBridge()`. Patching `entry.js` would break process lifecycle management. It must be excluded.

---

## Repository Structure

```
.
├── README.md
├── docs/
│   ├── root-cause-analysis.md     # Full technical root cause analysis
│   ├── peer-review-gemini.md      # Peer review by Gemini
│   ├── peer-review-gpt.md         # Peer review by GPT-4
│   └── security-analysis.md      # Security analysis of inbound messaging
└── patch/
    └── apply-fix.sh               # Shell script: apply / revert / verify / detect
```

---

## How to Apply

```bash
cd patch
chmod +x apply-fix.sh

# Apply the patch and restart gateway
./apply-fix.sh apply

# Verify all 6 files are patched and entry.js is untouched
./apply-fix.sh verify

# Detect all active-listener copies (useful after upgrade)
./apply-fix.sh detect
```

## How to Revert

```bash
./apply-fix.sh revert
```

Restores all files from backup and restarts the gateway.

---

## After `brew upgrade openclaw-cli`

The patch does **not** survive an OpenClaw upgrade. After upgrading:

1. The dist files are replaced with new hashes.
2. The fix must be re-applied.
3. File names (hashes) change per version, so files must be re-identified.

```bash
# Find the new version
NEW_VER=$(openclaw --version | awk '{print $2}')
DIST="/opt/homebrew/Cellar/openclaw-cli/$NEW_VER/libexec/lib/node_modules/openclaw/dist"

# Identify files to patch in the new version
grep -rl "No active WhatsApp Web listener" "$DIST"/*.js "$DIST"/plugin-sdk/*.js 2>/dev/null

# Or use the detect subcommand (update OPENCLAW_VERSION first)
OPENCLAW_VERSION=$NEW_VER ./patch/apply-fix.sh detect
```

Then update the file list in `apply-fix.sh` and re-run `apply`.

---

## Disclaimer

This is a **post-build monkey-patch**, not a source-level fix. It directly modifies the compiled output in the Homebrew Cellar. This approach is:

- ✅ Effective as a temporary workaround
- ✅ Safe in a single-process Node.js environment
- ✅ Reversible via the `revert` subcommand
- ⚠️ Not guaranteed to survive package upgrades
- ⚠️ Not an official fix — the proper fix should come from the OpenClaw maintainers at the Rollup bundling level

---

## Related Issues

- [openclaw/openclaw #14406](https://github.com/openclaw/openclaw/issues/14406) — Root cause analysis (exact code analysis of the duplicate Maps)
- [openclaw/openclaw #30177](https://github.com/openclaw/openclaw/issues/30177) — Bug report
- [openclaw/openclaw #50208](https://github.com/openclaw/openclaw/issues/50208) — Confirmation on version 2026.3.13

---

*Analysis and patch by [Data 🖖](https://github.com/petermarnef) — OpenClaw AI assistant running on Claude*
