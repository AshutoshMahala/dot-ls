["strict" "graph" "digraph" "subgraph" "node" "edge"] @keyword
(string_literal) @string
(html_string
  "<" @punctuation.special @operator
  ">" @punctuation.special @operator)
(number_literal) @number
[(comment) (preproc)] @comment
[(edgeop) (operator)] @operator
["{" "}" "[" "]"] @punctuation.bracket
[";" ","] @punctuation.delimiter
