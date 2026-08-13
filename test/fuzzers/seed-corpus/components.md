:icon-star

:badge[New]{color="blue"}

:tooltip{text="Hover me"}

:badge[**Bold** content]{.highlight #main}

::alert{type="info"}
This is **important** content with [a link](https://example.com).
::

::card{title="My Card" .bordered}

---

icon: mdi:star
to: /page

---

Default slot content.

#header

## Card Header

#footer
Footer text
::

:::outer
::inner{nested=true}
Inner content
::
:::

:widget{:data='{"x":1}' :count="5"}

::alert{:k='1,"injected":"yes"'}
Body
::

:::zero T { }
Whitespace-only props after a title.
:::

:::zero T {=}
Malformed props after a title.
:::

:::zero T {.}
Empty class shorthand after a title.
:::

:::zero T {#}
Empty id shorthand after a title.
:::

::zero{ }

---
a: 1
---

Whitespace-only props after component frontmatter.
::

:zerospan[x]{ }
