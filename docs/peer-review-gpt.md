# Peer Review — GPT-4

> **Summary:** Core analysis is solid. The code-splitting diagnosis is convincing, and a `globalThis`-based singleton is a defensible and likely effective workaround. Two important nuances: (1) the file list appears incomplete — a 7th copy exists in `plugin-sdk/thread-bindings-SYAnWHuW.js`; (2) the patch works but `Symbol.for(...)` would be technically cleaner. Verdict: patch all 7 copies, not just 6.

---

## Executive Summary

The core analysis is substantively strong and I largely reach the same conclusion: this does indeed look like a classic bundler/code-splitting bug where `src/web/active-listener.ts` ends up in the output more than once, causing multiple module-local `Map` instances to be created. A `globalThis`-based singleton is a defensible and likely effective workaround as a monkey-patch.

However, I see two important nuances:

1. **The file list appears incomplete.** In the installed `dist/` of OpenClaw 2026.3.13, I find **7** copies of `src/web/active-listener.ts`, not 6. In addition to the 6 files listed, there is also a copy in:
   - `plugin-sdk/thread-bindings-SYAnWHuW.js`

2. **The proposed patch is functionally correct but could be slightly cleaner/safer.** `globalThis.__openclaw_wa_listeners ??= new Map()` works, but a slightly less collision-prone variant like `globalThis[Symbol.for("openclaw.web.activeListeners")] ??= new Map()` would be technically more elegant. As a pure monkey-patch on minified/bundled dist, the string-key variant is the most practical.

**Short verdict: yes, the fix direction is correct, but patch all relevant copies, not just 6.**

---

## What I Validated

I scanned the installed OpenClaw `dist/` for `//#region src/web/active-listener.ts` and for the error text `No active WhatsApp Web listener`.

In this build I find exactly these files with their own copy of `active-listener.ts`:

1. `auth-profiles-DDVivXkv.js`
2. `auth-profiles-DRjqKE3G.js`
3. `discord-CcCLMjHw.js`
4. `model-selection-46xMp11W.js`
5. `model-selection-CU2b7bN6.js`
6. `reply-Bm8VrLQh.js`
7. `plugin-sdk/thread-bindings-SYAnWHuW.js`

I also confirmed that:
- `entry.js` also contains a `const listeners = new Map()`,
- but there it pertains to signal listeners inside `attachChildProcessBridge(...)`, not WhatsApp listeners.

I also observed that:
- `web-B73xP3XL.js` uses `setActiveWebListener` and imports from `./model-selection-46xMp11W.js`
- `web-Cz_8x_nz.js` uses `setActiveWebListener` and imports from `./model-selection-CU2b7bN6.js`
- `outbound-D7dWdMso.js` uses `requireActiveWebListener` and imports from `./model-selection-46xMp11W.js`
- `outbound-DgkEpLB5.js` uses `requireActiveWebListener` and imports from `./model-selection-CU2b7bN6.js`

This supports the description of at least two separated bundler worlds.

---

## Question 1: Same conclusion? Is `globalThis` the right fix?

**Verdict: yes, largely.**

The root cause analysis is technically plausible and fits perfectly with the symptom:
- inbound works,
- auto-reply works,
- outbound via the tool fails with an empty registry,
- and the same source module appears multiple times in different chunks.

This is exactly the kind of error you get when a module-local singleton is no longer actually a singleton after bundling.

The `globalThis` solution is a logical choice for a **dist-level monkey-patch** because it moves state from module scope to process-global scope. This makes the registry explicitly shared across all chunks within the same Node.js process.

Why this likely works:
- all involved chunks run in the same JS runtime / same Node process;
- `globalThis` is process-wide shared;
- `setActiveWebListener()` and `requireActiveWebListener()` will then look at the same `Map` regardless of chunk.

So yes: **as a temporary patch on bundled output, this is the correct category of fix.**

### Minor note
If this were solved at the source level, the actual structural fix would not necessarily require `globalThis`. There I would prefer ensuring `active-listener.ts` cannot be duplicated, or that the registry lives in a dedicated runtime module that the bundler can only load once. But for a monkey-patch on `dist/`, that is not realistic. In that context, `globalThis` is precisely the pragmatic choice.

---

## Question 2: Potential problems — memory leaks, race conditions, side effects?

**Verdict: low risk, but not zero.**

### Memory leaks
My judgment: **no new substantial leak risk beyond what the current design already has**.

The registry holds listener objects. It already did. The only difference is that the registry is now process-global instead of chunk-local. As long as `setActiveWebListener(accountId, null)` or equivalent is called on disconnect/cleanup, this stays clean.

Even if cleanup is imperfect, the impact is limited:
- one `Map` per process,
- usually one or a few accounts,
- entries are overwritten on reconnect.

The risk is therefore more of an existing lifecycle bug in cleanup, not something fundamentally worsened by `globalThis`.

### Race conditions
My judgment: **practically negligible in Node's single-threaded event loop model**.

`Map` access here is synchronous. There is no shared-memory concurrency as in multithreaded runtimes. There can be interleavings between async flows, but the code only does simple `get/set/delete` operations. That is fine.

The only semantic risk is last-write-wins:
- if two connect/reconnect flows for the same account run concurrently,
- then the last `setActiveWebListener()` overwrites the previous listener.

But that is already the existing behavior. The singleton does not make it worse; it only makes it consistent across chunks.

### Unexpected side effects
The main side effect is namespace collision on `globalThis`.

For example:
- if another patch or plugin happens to also use `__openclaw_wa_listeners`,
- or if someone manipulates that property,
- your state could be corrupted.

This is unlikely in practice, but not impossible. That is why a `Symbol.for(...)` key would be technically cleaner.

Two more small considerations:

1. **Cross-context expectations**  
   If anything implicitly relied on separate listener registries per chunk, you are changing behavior. But that appears to be precisely the bug, so this is not a real objection.

2. **Hot reload / partial reload scenarios**  
   On a soft reload or module reload, `globalThis` state persists as long as the process lives. In a daemon/process model this is exactly what you want. Only in exotic dev scenarios could this be surprising.

**Summary: low risks, and clearly lower than the current bug impact.**

---

## Question 3: Would I approach it differently? A better monkey-patch?

**Verdict: your patch is good enough, but I would consider two small improvements.**

### Option A — your patch as proposed
```js
const listeners = globalThis.__openclaw_wa_listeners ??= new Map();
```
Simple, readable, and likely sufficient.

### Option B — slightly cleaner: `Symbol.for`
If you are willing to patch slightly more code:

```js
const listeners = globalThis[Symbol.for("openclaw.web.activeListeners")] ??= new Map();
```

Advantages:
- much smaller chance of property-name collision;
- semantically clear singleton key;
- still process-global.

Disadvantage:
- slightly larger textual patch;
- less "surgical" if you want to replace exactly 1 line.

### Option C — object wrapper with versioned namespace
Also reasonable:

```js
const listeners = (globalThis.__openclaw ??= {}).waListeners ??= new Map();
```

This avoids some global pollution, but is slightly more cumbersome.

### What I would NOT do as a monkey-patch
- Do not try to rewire imports across multiple chunks.
- Do not try to have one chunk export and other chunks manually import.
- Do not patch callsites (`requireActiveWebListener` or `setActiveWebListener`) with all kinds of per-chunk fallback logic.

That kind of patching is more fragile than simply centralizing the shared state.

### My recommendation
For maximum simplicity: **keep your patch**.

For maximum technical cleanliness: **use `Symbol.for("openclaw.web.activeListeners")`**.

---

## Question 4: Is excluding `entry.js` correct?

**Verdict: yes, correct. Do not patch `entry.js`.**

I reviewed `entry.js`. It contains:
- a `const listeners = new Map()` inside `attachChildProcessBridge(child, { signals, onSignal })`
- that `Map` stores signal handlers per OS signal (`SIGTERM`, `SIGINT`, etc.)
- it is used to later detach listeners from `process`

This is functionally completely different from the WhatsApp registry.

That code lives in `src/process/child-process-bridge.ts`, not in `src/web/active-listener.ts`.

So yes, excluding `entry.js` is correct. That `listeners` variable is only nominally the same, not semantically related.

---

## Question 5: Reconnect/failover risks?

**Verdict: the singleton should work correctly on reconnect.**

Based on the code quoted and verified in dist:
- `setActiveWebListener(accountId, listener)` effectively does `set` for a new listener,
- and `delete` when listener is falsy/null.

This means:
- on reconnect with a new listener, the entry is overwritten;
- on disconnect/cleanup, the entry can be removed;
- on multiple reconnects for the same account, last-write-wins applies.

That is exactly what you want.

### Possible nuance
If old sockets/listeners are not properly closed elsewhere in the code, an old listener could still fire events while a new one is already in the map. But that is not a problem of the singleton itself — that is a lifecycle/socket-cleanup issue elsewhere.

### Failover between accounts
Also fine, because the key is account-id based. The singleton map can contain multiple accounts simultaneously.

### Edge case: stale listener in global map
If disconnect cleanup is ever not called, a stale listener can remain in the global map. But again: that risk already existed, and the original code had the exact same lifecycle dependency. The singleton only changes the visibility of the state, not the cleanup semantics.

My practical judgment: **no blocker. Reconnect behavior appears fully compatible with this fix.**

---

## Question 6: Are files missing?

**Verdict: yes, probably. At least one file is missing.**

In my scan of this exact version I see **7** files with a copy of `src/web/active-listener.ts`:

1. `auth-profiles-DDVivXkv.js`
2. `auth-profiles-DRjqKE3G.js`
3. `discord-CcCLMjHw.js`
4. `model-selection-46xMp11W.js`
5. `model-selection-CU2b7bN6.js`
6. `reply-Bm8VrLQh.js`
7. `plugin-sdk/thread-bindings-SYAnWHuW.js`

That seventh is important, as it also contains `setActiveWebListener`, `requireActiveWebListener`, `getActiveWebListener`, and WhatsApp runtime-related code.

### Important nuance
Whether you **operationally** need that 7th copy to fix your concrete bug depends on which executable path you are using.

- If your failing flow only runs through the main CLI/runtime, your 6 files may happen to be sufficient.
- But if there are code paths via the plugin SDK / thread bindings, that 7th copy could again create a separate registry.

My advice is therefore simple: **if you are monkey-patching anyway, patch all 7 copies of `src/web/active-listener.ts`.** This is more consistent and prevents half-fixes.

### How to verify this robustly
The best scan rule is not to search only on `const listeners = new Map()`, but on the region marker or error text:
- `//#region src/web/active-listener.ts`
- `No active WhatsApp Web listener`

This avoids false positives like `entry.js`.

---

## Additional Observations

### 1. The fix must live in the same process
This patch only resolves duplication **within a single Node process**. If connect and outbound run in different processes, `globalThis` will not help. But the symptom description and the bundler analysis point specifically to a single-process, multi-chunk problem. So that is not an objection here.

### 2. `??=` syntax requires a modern runtime
Not an issue in OpenClaw's current Node runtime. On Node 25.x this is self-evidently supported.

### 3. `/* @__PURE__ */` disappears
This makes no functional difference. That annotation is only a bundler/minifier hint. In patched dist it is irrelevant.

### 4. The empty `if (id === "default") {}`
I see in the dist a somewhat different `setActiveWebListener` than in the simplified snippet, with an overload-like path and an empty `if (id === "default") {}`. This changes nothing about the main conclusion, but it does confirm that you should patch the actual dist code, not a simplified reconstruction.

---

## Final Verdict per Question

| Question | Verdict |
|----------|---------|
| Same conclusion? Right fix? | **Yes.** The code-splitting analysis is convincing and a process-global singleton via `globalThis` is a sound monkey-patch. |
| Problems with this approach? | **Limited risk.** No major additional leak or race risks. Main downside is possible global namespace collision, but small in practice. |
| Would I do it differently? | **Only marginally.** Optionally use `Symbol.for(...)` for a cleaner global key. Otherwise your approach is the best pragmatic monkey-patch. |
| Excluding `entry.js` correct? | **Yes.** That `listeners` map belongs to process signal handlers in `child-process-bridge`, not WhatsApp. |
| Reconnect/failover risk? | **Low.** Reconnect should work correctly; `set/delete/get` semantics remain logical under a singleton. |
| Missing files? | **Yes, probably at least one.** `plugin-sdk/thread-bindings-SYAnWHuW.js` also contains its own copy of `src/web/active-listener.ts` and should be included in a complete patch. |

---

## Practical Recommendation

If you are going to apply this monkey-patch:

1. Patch **all 7** copies of `src/web/active-listener.ts` in `dist/`.
2. Leave `entry.js` untouched.
3. Use a unique global key. Simple:
   ```js
   const listeners = globalThis.__openclaw_wa_listeners ??= new Map();
   ```
   or cleaner:
   ```js
   const listeners = globalThis[Symbol.for("openclaw.web.activeListeners")] ??= new Map();
   ```
4. Then test at minimum these scenarios:
   - receiving an inbound message
   - auto-reply on inbound
   - outbound `message.send`
   - reconnect of a WhatsApp session
   - multiple accounts if relevant

**Final conclusion: the patch is substantively correct, but I would only call it "complete" once `plugin-sdk/thread-bindings-SYAnWHuW.js` is also included.**
