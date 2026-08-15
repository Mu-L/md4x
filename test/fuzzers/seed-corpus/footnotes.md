Text with a footnote[^1] and the same one again[^1].

A second one[^note] and one that is never defined[^missing].

[^1]: The first note, with **bold**, `code` and a [link](/u).
[^note]: A multi-line body.
Second line of the same body.
[^unused]: Consumed but never emitted.

Nested references[^outer] resolve inside a footnote body too.

[^outer]: This body itself refers to[^inner].
[^inner]: The innermost note.

Odd shapes: [^], [^ ], [^a[b], [^a]b], [^A b], [^ünï], [^*x*], [^1-2_3].

[^ünï]: unicode label
[^*x*]: label made of punctuation

Inside other constructs:

- list item[^1]
- > quoted[^note]

| head[^1] |
| -------- |
| cell     |

> [!NOTE]
> alert body[^1]

:badge[[^1]] and [link with [^1] inside](/u) and ![img [^1]](/i).

Swallowed by a link destination: [x]([^a) b]
