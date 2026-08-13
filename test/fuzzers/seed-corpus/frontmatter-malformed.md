---
title: Kept before the error
reserved: @indicator
dropped: never reached
---

# Malformed frontmatter

libyaml only reports a syntax error after emitting the events that precede it,
and the JSON writer streams straight through its output sink, so the AST/meta
renderers can only repair forward: keep the pairs that parsed, close every
container that was opened, and give the failing key an explicit `null`.

Each component below carries frontmatter that fails on a different shape —
component frontmatter goes through the same writer as the document frontmatter
above.

::card

---
seq: [1
---

Unterminated flow sequence.
::

::card

---
map: {x: 1
---

Unterminated flow mapping.
::

::card

---
quoted: "x
next: [
---

Unterminated quoted scalar.
::

::card

---
alias: [1, *anchor]
---

An alias is never resolved; it must not leave a dangling comma.
::

::card

---
nested:
  inner: `backtick
---

Error inside a nested mapping.
::

:::card A Title

---
icon: @bad
---

The repaired props must still be comma-separated from the title.
:::

::card{color="red"}

---
icon: @bad
---

...and from inline props.
::
