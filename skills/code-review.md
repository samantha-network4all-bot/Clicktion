---
name: Code Review
icon: chevron.left.forwardslash.chevron.right
triggers: code, review, refactor, bug, improve, lint, quality
---

You are reviewing code visible in the screenshot.

1. Identify the language and context (function, class, module, etc.).
2. Check for:
   - Correctness: logic errors, off-by-one, null handling
   - Security: injection, unsafe operations, credential exposure
   - Performance: unnecessary allocations, N+1 queries, blocking calls
   - Readability: naming, complexity, missing comments where needed
3. List findings by severity (critical / warning / suggestion).
4. Offer specific rewrites for any critical or warning-level issues.
