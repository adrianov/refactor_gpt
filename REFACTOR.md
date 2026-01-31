# General coding rules

1. **Correctness & Robustness**
   - Identify and fix bugs or obvious mistakes.
   - Improve error handling where it is clearly insufficient or unsafe.
   - Prefer failing fast with clear messages over silent failures.

2. **Readability & Naming**
   - Use clear, descriptive names for variables, methods, and classes.
   - Avoid unnecessary abbreviations unless they are domain-standard.

3. **Structure & Size**
   - Prefer small, focused methods. Keep methods under 25 lines.
   - Where it improves clarity, extract helper methods instead of enforcing
     an arbitrary line limit.
   - Keep lines reasonably short (aim for <= 100 characters), but do not
     harm readability just to satisfy a strict width.
   - Keep modules and classes under a reasonable size (e.g. 500 lines). If a
     module exceeds that, first remove unused and dead code; then extract a new
     module or class and integrate it (e.g. via dependency injection).

4. **Simplicity**
   - Simplify complex conditionals and branching where possible.
   - Remove dead code and unnecessary indirection.
   - Inline variables that are used only once when it improves clarity.

5. **Style & Consistency**
   - Follow idiomatic [LANGUAGE] style and community conventions.
   - Maintain consistent formatting with the surrounding codebase.

6. **Comments & Documentation**
   - Preserve all existing comments verbatim unless they refer to code you
     significantly change or a TODO you implement.
   - Do not add new comments unless the user explicitly asks for them.

7. **Behavior Preservation**
   - Preserve existing business logic and external behavior unless there is
     a clear bug or the user explicitly requests a change.
   - When you must change behavior to fix a bug, keep the change as small
     and local as possible.

8. **TODOs**
   - Implement TODOs only if they are fully specified and safe to complete
     without guessing about missing requirements.
   - If a TODO is ambiguous, leave it in place and do not invent behavior.

9. **Default Behavior**
   - Do not change code behavior unless the user specifically asks for it
     or a change is required to fix a clear bug.

10. **Regression fixes**
   - When fixing a regression, consult `git log` and `git diff` when available
     to find the last known working variant of the affected code; prefer
     restoring or adapting that behavior over inventing a new fix.
   - Add an in-code comment at the fix site that explains what went wrong and
     why this code must stay as written.
   - Phrase the comment so a future editor (or tool) reading the file will
     avoid reintroducing the same bug; include the symptom or constraint
     that would be violated if the fix were reverted or "simplified" away.
