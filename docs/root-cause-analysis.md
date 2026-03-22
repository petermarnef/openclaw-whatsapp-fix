# WhatsApp Outbound Fix — Listener Map Singleton Patch

## Problem

OpenClaw 2026.3.13 has a code-splitting bug (Rollup bundler) where the WhatsApp listener registry (`src/web/active-listener.ts`) is duplicated across multiple JavaScript chunks. There are two parallel "worlds" in the dist output, each with their own `listeners = new Map()`.

**World A** (model-selection-46xMp11W.js): web-B73xP3XL.js, outbound-D7dWdMso.js, extensionAPI.js, etc.  
**World B** (model-selection-CU2b7bN6.js): web-Cz_8x_nz.js, outbound-DgkEpLB5.js, agent-BeieZAG2.js, etc.

At gateway startup, OpenClaw selects one world for the WhatsApp provider (`setActiveWebListener`), but tool calls may execute via the other world (`requireActiveWebListener`). Result: Map A is empty while Map B is populated, or vice versa.

**Result:** inbound + auto-reply works (uses `msg.reply()` with a direct socket reference), but proactive `message` tool sends fail with "No active WhatsApp Web listener".

**GitHub issues:** #14406 (root cause analysis), #30177, #50208 (confirmed on 2026.3.13)

---

## In-Depth Impact Analysis

### What the fix does

Replaces `const listeners = /* @__PURE__ */ new Map()` with `const listeners = globalThis.__openclaw_wa_listeners ??= new Map()` in 6 files. This ensures ALL chunks point to exactly the same Map via a process-global variable.

### What is affected

- **WhatsApp outbound via message tool**: DIRECTLY FIXED. `requireActiveWebListener()` will now always find the listener that `setActiveWebListener()` registered, regardless of which chunk calls it.
- **WhatsApp inbound**: NO IMPACT. Inbound uses `msg.reply()` on the message object, which has a direct socket reference. The listeners Map is not consulted.
- **WhatsApp auto-reply**: NO IMPACT. Same path as inbound.
- **Discord, Telegram, email**: NO IMPACT. These channels have their own systems, unrelated to the WhatsApp listeners Map.
- **Cron jobs**: INDIRECTLY FIXED. Cron jobs that send WhatsApp messages (morning messages, discovery drops) use the message tool — they will work again.

### Risks

1. **Do NOT patch entry.js**: `entry.js` also has `const listeners = new Map()` but this is a DIFFERENT Map for process signal handlers (SIGTERM, SIGINT). Patching `entry.js` would break signal handling. **ENTRY.JS MUST BE EXCLUDED.**

2. **OpenClaw update overwrites the patch**: When running `brew upgrade openclaw-cli`, the dist files are replaced. The patch must be re-applied. File names (hashes) change per version, so files must be re-identified.

3. **No side effects expected**: The `??=` operator (nullish coalescing assignment) creates a new Map only if `globalThis.__openclaw_wa_listeners` does not yet exist. The first chunk to execute the line creates the Map. All subsequent chunks reuse the same Map. This is thread-safe in Node.js (single-threaded).

4. **No memory leaks**: The Map contains at most N entries (one per WhatsApp account, typically 1: "default"). There is no difference in memory usage.

5. **Failover/reconnect**: On a WhatsApp reconnect, `setActiveWebListener()` calls `listeners.delete(id)` followed by `listeners.set(id, newListener)`. Because all chunks now point to the same Map, all chunks automatically receive the new listener. This is BETTER than the original behavior where only the chunk handling the reconnect received the update.

### Confidence that this solves the problem

**High (95%+)**. The root cause is definitively identified and confirmed by:
- GitHub issue #14406 (exact code analysis of the duplicate Maps)
- GitHub issue #50208 (confirmation on the same version 2026.3.13)
- Own log analysis: `subsystem-CDcEQtQK.js` logs "Listening" (inbound works), `subsystem-D2xHvZZd.js` via `gateway/ws` returns "No active listener" (outbound fails)
- The two model-selection chunks (46xMp11W vs CU2b7bN6) each with their own Map are the direct cause

The only reason not to say 100%: there could theoretically be a timing issue at startup where the singleton Map is not yet populated when the first outbound call arrives. This is the same window the original (working) design had, so no regression.

---

## The Fix (6 files, NOT entry.js)

### Before (original):
```javascript
const listeners = /* @__PURE__ */ new Map();
```

### After (patched):
```javascript
const listeners = globalThis.__openclaw_wa_listeners ??= new Map();
```

### Files (OpenClaw 2026.3.13)

Location: `/opt/homebrew/Cellar/openclaw-cli/2026.3.13/libexec/lib/node_modules/openclaw/dist/`

1. `auth-profiles-DDVivXkv.js` (contains active-listener.ts region)
2. `auth-profiles-DRjqKE3G.js` (contains active-listener.ts region)
3. `discord-CcCLMjHw.js` (contains active-listener.ts region)
4. `model-selection-46xMp11W.js` (contains active-listener.ts region — World A)
5. `model-selection-CU2b7bN6.js` (contains active-listener.ts region — World B)
6. `reply-Bm8VrLQh.js` (contains active-listener.ts region)

**⚠️ DO NOT PATCH: `entry.js`** — has the same variable name but for process signal handlers, not WhatsApp.

---

## Applying the Fix

```bash
DIST="/opt/homebrew/Cellar/openclaw-cli/2026.3.13/libexec/lib/node_modules/openclaw/dist"

# Create backup
mkdir -p ~/.openclaw/backups/dist-2026.3.13-pre-wa-fix
for f in auth-profiles-DDVivXkv.js auth-profiles-DRjqKE3G.js discord-CcCLMjHw.js model-selection-46xMp11W.js model-selection-CU2b7bN6.js reply-Bm8VrLQh.js; do
  cp "$DIST/$f" ~/.openclaw/backups/dist-2026.3.13-pre-wa-fix/
done

# Apply fix (6 files, NOT entry.js)
for f in auth-profiles-DDVivXkv.js auth-profiles-DRjqKE3G.js discord-CcCLMjHw.js model-selection-46xMp11W.js model-selection-CU2b7bN6.js reply-Bm8VrLQh.js; do
  sed -i '' 's|const listeners = /\* @__PURE__ \*/ new Map();|const listeners = globalThis.__openclaw_wa_listeners ??= new Map();|g' "$DIST/$f"
done

# Restart gateway
openclaw gateway restart
```

---

## Reverting

```bash
DIST="/opt/homebrew/Cellar/openclaw-cli/2026.3.13/libexec/lib/node_modules/openclaw/dist"

for f in auth-profiles-DDVivXkv.js auth-profiles-DRjqKE3G.js discord-CcCLMjHw.js model-selection-46xMp11W.js model-selection-CU2b7bN6.js reply-Bm8VrLQh.js; do
  cp ~/.openclaw/backups/dist-2026.3.13-pre-wa-fix/"$f" "$DIST/$f"
done

openclaw gateway restart
```

---

## Verification After Applying

```bash
DIST="/opt/homebrew/Cellar/openclaw-cli/2026.3.13/libexec/lib/node_modules/openclaw/dist"

# Check all 6 files are patched
echo "Patched (should show 1 per file):"
for f in auth-profiles-DDVivXkv.js auth-profiles-DRjqKE3G.js discord-CcCLMjHw.js model-selection-46xMp11W.js model-selection-CU2b7bN6.js reply-Bm8VrLQh.js; do
  count=$(grep -c "globalThis.__openclaw_wa_listeners" "$DIST/$f")
  echo "  $f: $count"
done

# Check entry.js is NOT patched
echo ""
echo "entry.js NOT patched (should show 0):"
grep -c "globalThis.__openclaw_wa_listeners" "$DIST/entry.js"

# Check original pattern is gone from the 6 files
echo ""
echo "Original removed (should show 0 per file):"
for f in auth-profiles-DDVivXkv.js auth-profiles-DRjqKE3G.js discord-CcCLMjHw.js model-selection-46xMp11W.js model-selection-CU2b7bN6.js reply-Bm8VrLQh.js; do
  count=$(grep -c 'const listeners = /\* @__PURE__ \*/ new Map();' "$DIST/$f")
  echo "  $f: $count"
done
```

---

## Re-applying After an OpenClaw Update

After `brew upgrade openclaw-cli`:

```bash
# 1. Find the new version
NEW_VER=$(openclaw --version | awk '{print $2}')
DIST="/opt/homebrew/Cellar/openclaw-cli/$NEW_VER/libexec/lib/node_modules/openclaw/dist"

# 2. Identify files (names change per version)
echo "Files to patch:"
grep -l "const listeners = /\* @__PURE__ \*/ new Map();" "$DIST"/*.js | while read f; do
  # Check for active-listener region (not entry.js)
  if grep -q "active-listener" "$f"; then
    echo "  PATCH: $(basename $f)"
  else
    echo "  SKIP: $(basename $f) (no active-listener region)"
  fi
done

# 3. Apply the fix to the identified files (update names accordingly)
```

---

## Date

Documented: 2026-03-22  
Version: OpenClaw 2026.3.13 (61d171a)  
Analysis by: Data 🖖
