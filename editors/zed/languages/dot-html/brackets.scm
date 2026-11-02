; Pair complete tags so the opener matches its closing element.
; A smaller <...> pair would hide the element pair while the cursor is in a tag.
((element (start_tag) @open (end_tag) @close)
 (#set! rainbow.exclude))
((self_closing_tag "<" @open "/>" @close)
 (#set! rainbow.exclude))
