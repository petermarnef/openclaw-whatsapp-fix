# Peer Review — Gemini

> **Summary:** The analysis is spot-on. The bundler splits the module state, which causes the listeners Map to be duplicated. The outbound tool therefore reads from an empty Map. The `globalThis` fix is the perfect, pragmatic solution for a post-build monkey-patch to re-centralize that state.

---

## Full Review

Your analysis is spot-on. The bundler splits the module state, causing the listeners Map to be duplicated. The outbound tool therefore reads from an empty Map. Your fix using `globalThis` is, for a post-build monkey-patch, the perfect and pragmatic solution to re-centralize that state.

There are no noteworthy risks with this approach. Memory leaks are not an issue because `setActiveWebListener` explicitly removes the old connection (`delete(id)`) before setting the new one. Since the key remains the same per account, the Map does not grow larger and the garbage collector can cleanly reclaim old listeners. Race conditions are not a concern because Node.js is single-threaded and Map operations execute synchronously. On a reconnect, the reference in the shared global Map is simply overwritten, so all chunks immediately use the new working connection. Reconnects and failovers work exactly as they should.

Regarding execution: it is absolutely critical that you leave `entry.js` untouched. If you put the WhatsApp connections and signal handlers (SIGINT/SIGTERM) in the same Map, you break the lifecycle management of the Node process.

Without scanning your full dist folder, it is impossible to say with 100% certainty whether you are missing any files, since Rollup distributes chunks dynamically. To avoid missing a chunk now or after a minor update, I recommend having your patch script detect files dynamically (e.g., via `grep -rl "function requireActiveWebListener" dist/`) instead of using hardcoded filenames.

**Bottom line:** tight root cause analysis. The monkey-patch is safe, effective, and ready to go.
