---
title: Deep YAML nesting
shallow: [[[[[a, {b: [c]}]]]]]
deep_seq: [[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]
after: dropped with the rest of the document
---

# Deep YAML nesting

The YAML-to-JSON writer (`json_write_yaml_*` in
`src/renderers/md4x-json.zig`) walks libyaml's event stream recursively, so a
frontmatter block's nesting depth is the native recursion depth. libyaml has no
nesting limit of its own and the markdown parser hands frontmatter over as
opaque bytes, so deeply nested flow collections used to exhaust the stack.
`YAML_MAX_DEPTH` stops at 256 levels: the position that overflowed gets `null`
and the walk unwinds without reading another event, so the cost of a deep
document no longer depends on how deep it goes -- and the keys after the
overflowing one are dropped, as `after` above is.

Reached by `md_ast` (`--format=json`), `md_meta` and `md_yaml`. Each shape needs
its own frontmatter block, since the first overflow ends that block's parse;
component frontmatter goes through the same writer.

::card

---
deep_map: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: {a: }}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}
---

The mapping arm of the cap.
::

::card

---
deep_alt: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: [{a: }]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]}]
---

Sequences and mappings alternating into the cap.
::

::card

---
unterminated: [[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[
---

Deep and unterminated: the cap is reached before libyaml reports the syntax
error, and every container the writer opened is still closed.
::

::card

---
shallow: [[[a, {b: [c]}]]]
sibling: emitted
---

Nesting under the cap is untouched.
::
