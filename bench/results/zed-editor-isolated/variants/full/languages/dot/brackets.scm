("{" @open "}" @close)
("[" @open "]" @close)

; The DOT wrapper is separate from the injected HTML tag delimiters.
((html_string "<" @open ">" @close)
 (#set! rainbow.exclude))
