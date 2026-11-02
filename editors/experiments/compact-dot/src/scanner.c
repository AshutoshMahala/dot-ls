#include "tree_sitter/parser.h"
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

enum TokenType { HTML_INTERNAL, ERROR_SENTINEL };

void *tree_sitter_dot_ls_external_scanner_create(void) { return NULL; }
void tree_sitter_dot_ls_external_scanner_destroy(void *payload) { (void)payload; }
unsigned tree_sitter_dot_ls_external_scanner_serialize(void *payload, char *buffer) { (void)payload; (void)buffer; return 0; }
void tree_sitter_dot_ls_external_scanner_deserialize(void *payload, const char *buffer, unsigned length) { (void)payload; (void)buffer; (void)length; }

// The DOT wrapper is parsed by the grammar. Consume only its inner bytes.
// HTML tags stay opaque here; the editor's HTML grammar handles their structure.
bool tree_sitter_dot_ls_external_scanner_scan(void *payload, TSLexer *lexer, const bool *valid) {
  (void)payload;
  if (valid[ERROR_SENTINEL] || !valid[HTML_INTERNAL] || lexer->eof(lexer) || lexer->lookahead == '>') return false;
  uint32_t depth = 0;
  int32_t quote = 0;
  bool in_tag = false;
  while (!lexer->eof(lexer)) {
    int32_t ch = lexer->lookahead;
    if (quote) {
      lexer->advance(lexer, false);
      if (ch == quote) quote = 0;
    } else if (in_tag && (ch == '\'' || ch == '"')) {
      quote = ch;
      lexer->advance(lexer, false);
    } else if (ch == '<') {
      if (depth == UINT32_MAX) return false;
      depth++;
      in_tag = true;
      lexer->advance(lexer, false);
      // XML comments can contain unmatched angle brackets and quotes.
      if (lexer->lookahead == '!') {
        lexer->advance(lexer, false);
        if (lexer->lookahead == '[') {
          lexer->advance(lexer, false);
          const char *prefix = "CDATA[";
          bool cdata = true;
          for (unsigned i = 0; prefix[i]; ++i) {
            if (lexer->lookahead != prefix[i]) { cdata = false; break; }
            lexer->advance(lexer, false);
          }
          if (cdata) {
            unsigned brackets = 0;
            while (!lexer->eof(lexer)) {
              int32_t c = lexer->lookahead;
              lexer->advance(lexer, false);
              if (c == '>' && brackets >= 2) { depth--; in_tag = false; break; }
              brackets = c == ']' ? brackets + (brackets < 2) : 0;
            }
          }
        } else if (lexer->lookahead == '-') {
          lexer->advance(lexer, false);
          if (lexer->lookahead == '-') {
            lexer->advance(lexer, false);
            unsigned dashes = 0;
            while (!lexer->eof(lexer)) {
              int32_t c = lexer->lookahead;
              lexer->advance(lexer, false);
              if (c == '>' && dashes >= 2) { depth--; in_tag = false; break; }
              dashes = c == '-' ? dashes + (dashes < 2) : 0;
            }
          }
        }
      }
    } else if (ch == '>') {
      if (!depth) break;
      depth--;
      in_tag = false;
      lexer->advance(lexer, false);
    } else {
      lexer->advance(lexer, false);
    }
    lexer->mark_end(lexer);
  }
  lexer->result_symbol = HTML_INTERNAL;
  return true;
}
