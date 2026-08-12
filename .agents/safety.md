# Memory Safety & Bug Classes

Zig's bounds checks, optionals and allocator length validation kill several of these outright in
Debug/ReleaseSafe — but the **shipping artifacts are `ReleaseFast`**, where those checks are off. All
of it still deserves review when touching parser/renderer internals.

## Recurring bug classes

1. **Fixed-size stack buffers without overflow handling** — every fixed-size array (e.g.
   `deferred_comp_closers[16]`, stack-allocated `MD_LINE` arrays) needs an explicit bounds check at
   every insertion point. Silent drops are as dangerous as overflows: they corrupt downstream state.

2. **Stale pointers after realloc** — never cache a pointer into a growable buffer (`buf->data`,
   `ctx.comp_info`, …) across a call that may reallocate. Assign each `realloc` result immediately,
   before the next one. A double-realloc where the first succeeds and the second fails causes a
   double-free if intermediate results are not stored.

3. **Dynamic-component dispatch in the AST renderer** — see below.

4. **Unbalanced SAX callbacks** — renderers must be defensive against unbalanced `enter`/`leave`.
   Guard every state transition (stack pops, counter decrements) with the correct type check, and
   handle a null `current` / stack underflow gracefully. Example: `jsonLeaveSpan` must only decrement
   `image_nesting` for `.img`, not for all span types.

5. **Unchecked allocation** — every allocation must handle failure via `error{OutOfMemory}` (or the
   documented null-return arena helpers) and propagate it. Silent OOM produces corrupted output,
   dropped props, or incomplete nodes.

6. **`unreachable` on adversarial paths** — in `ReleaseFast` (what ships) `unreachable` is UB, not a
   panic, so a wrong assertion is a silent miscompile. Don't assert invariants edge-case inputs can
   violate; prefer defensive guards.

7. **Uncapped user-controlled ranges** — cap ranges from user input (e.g. highlight ranges
   `{1-99999}`) to prevent excessive allocation.

8. **`cont.ch != '>'` as a test for "is a list"** — md4c's `MD_CONTAINER` stack only ever holds `'>'`
   and the list marks `-+*.)`, so upstream freely writes that. md4x adds `':'` (block component) and
   `'#'` (template slot), so the negative test is **wrong here**, and `MD_CONTAINER` fields that only
   the list arms of `md_enter_child_containers()` initialize — notably `block_byte_off`, defaulting to
   `0` — read back as "block index 0" for them. That is a wild write into `block_bytes[0]`, the
   document's first block. **Always spell a list test positively: `ISANYOF_(cont.ch, "-+*.)")`.**
   The three remaining `ch != '>'` sites in `blocks.zig` (the `last_line_has_list_loosening_effect`
   assignment and both halves of the two-blank-lines hack) are deliberately left negative — see the
   third case in `test/regressions.txt` under "`::component` / `#slot` retroactively loosening an
   earlier list", which pins output a positive test there would break.

## Audit checklist when reviewing changes

- Fixed-size arrays → bounds check at every insertion
- `cont.ch != '>'` / any "not a block quote means a list" test → is it reading a list-only field?
- Pointer caching across a realloc/`append` → no stale pointer after growth
- AST renderer tag dispatch → `tag_is_dynamic` checked first
- `leave_block` / `leave_span` → correct type guard and underflow handling
- Allocation sites → failure path handled, freed length matches allocated length exactly
- `unreachable` → can no input violate the condition?

## AST renderer: dynamic-component dispatch

`src/renderers/md4x-ast.zig` has **structurally retired** two memory-safety failure modes:
`JsonNode.detail` is a **flat `Detail` struct** (one field per variant), so union type-confusion is
impossible; and the node tree is **arena-allocated** (`JsonCtx.arena` — built during parse, serialized
once, freed wholesale), so `jsonNodeFree` is a deliberate no-op and there is no double-free to have.

**The dispatch-order rule still applies for correctness.** A user can name a component anything
(`::alert{...}`, `::pre{...}`, `::a{...}`), so a dynamic tag name may collide with a built-in one.
`jsonWriteProps` / `jsonSerializeNode` must check `tag_is_dynamic` (and switch on `tag_kind`) **before**
any built-in-tag handling, or a component is serialized by reading the wrong flat-struct field.
`jsonEnterBlock` / `jsonEnterSpan` resolve the dynamic-component arm before any built-in tag for the
same reason.

Do **not** "modernize" the flat struct into a `union(enum)`: that reintroduces a discriminant to keep
in sync, regressing the safety the flat struct already guarantees.
