; Only the inner content of a DOT HTML-like ID uses HTML highlighting.
; Quoted DOT string_literal nodes never match this rule.
((html_string (html_internal) @injection.content)
 (#set! injection.language "DOT HTML (dot-ls)"))
