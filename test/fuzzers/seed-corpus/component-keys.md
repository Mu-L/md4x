# Adversarial component keys

Component keys reach the HTML renderer as attribute NAMES. A name ends at
whitespace, `/`, `=` or `>`, none of which the value escape set (`& < > "`)
covers, so these shapes used to tokenize into more than one attribute.

::card

---
x onload=alert(1)//: y
a/b: slash
a=b: equals
a b: space
"a\tb": tab
"a\nb": newline
"a\rb": carriage return
"a\fb": form feed
"a\0b": nul
"a\x7fb": del
"a'b": apostrophe
"a`b": backtick
"a<b>c": angles
"a&b": ampersand
'a"b': quote
"": empty
"   ": blank
"//": punctuation only
"=": equals only
título: non-ascii
"日本語": cjk
---

body
::

::card{a/b=c a=b= a"b=c #i/d .c/l onload=x :j/k='1'}
props
::

:::card x onload=alert(1)// {a/b=c}

---
"/": v
---

titled
:::

:badge[N]{a/b=c}

**b**{a/b=c}

_u_{a/b=c}

`code`{a/b=c}

~~d~~{a/b=c}

[t]{a/b=c}

[t](u "ti"){a/b=c}

![i](p){a/b=c}

::outer

---
"a b": 1
---

::inner

---
"c/d": 2
---

::
::

#slot-a

::card

---
nested:
  "a b": 1
seq:
  - "a b"
---

::
