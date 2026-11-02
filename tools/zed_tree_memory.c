/* Native Tree-sitter allocation probe. Not linked into the language server.
 * Counts requested allocator bytes, including hidden grammar nodes, not RSS.
 * Timing includes this allocation instrumentation and is diagnostic only. */
#include <tree_sitter/api.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <time.h>
#ifndef LANGUAGE_FUNCTION
#define LANGUAGE_FUNCTION tree_sitter_dot
#endif
extern const TSLanguage *LANGUAGE_FUNCTION(void);
typedef union { max_align_t align; struct { size_t size; } h; } Header;
static size_t live, peak, allocations;
static void *alloc(size_t n) { Header *p=malloc(sizeof(Header)+n); if(!p) abort();p->h.size=n;live+=n;if(live>peak)peak=live;allocations++;return p+1; }
static void release(void *v) { if(!v)return;Header *p=(Header*)v-1;live-=p->h.size;free(p); }
static void *zero(size_t n,size_t size) { if(size && n>SIZE_MAX/size)abort();void *p=alloc(n*size);memset(p,0,n*size);return p; }
static void *resize(void *v,size_t n) { if(!v)return alloc(n);Header *p=(Header*)v-1;size_t old=p->h.size;p=realloc(p,sizeof(Header)+n);if(!p)abort();p->h.size=n;live=live-old+n;if(live>peak)peak=live;allocations++;return p+1; }
static double now(void) { struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec*1e-9; }
int main(int argc,char **argv) {
 if(argc!=2)return 2;
 FILE *f=fopen(argv[1],"rb");if(!f)return 3;fseek(f,0,SEEK_END);long n=ftell(f);rewind(f);char *s=malloc(n+1);if(fread(s,1,n,f)!=(size_t)n)return 4;fclose(f);s[n]=0;
 if (!getenv("DOTLS_TS_NO_ACCOUNTING")) ts_set_allocator(alloc,zero,resize,release);
 TSParser *p=ts_parser_new();if(!ts_parser_set_language(p,LANGUAGE_FUNCTION()))return 5;
 size_t before=live;double start=now();TSTree *tree=ts_parser_parse_string(p,NULL,s,(uint32_t)n);double sec=now()-start;if(!tree)return 6;
 size_t parsed=live, parse_peak=peak, parse_allocations=allocations;
 size_t visible=0,named=0,html=0;TSTreeCursor c=ts_tree_cursor_new(ts_tree_root_node(tree));
 for(;;){TSNode node=ts_tree_cursor_current_node(&c);visible++;named+=ts_node_is_named(node);html+=!strcmp(ts_node_type(node),"html_string");if(ts_tree_cursor_goto_first_child(&c))continue;while(!ts_tree_cursor_goto_next_sibling(&c)){if(!ts_tree_cursor_goto_parent(&c))goto done;}}
 done: ts_tree_cursor_delete(&c);int errors=ts_node_has_error(ts_tree_root_node(tree));ts_tree_delete(tree);size_t retained=live;ts_parser_delete(p);
 printf("{\"source_bytes\":%ld,\"parse_seconds\":%.6f,\"parser_before_bytes\":%zu,\"parsed_live_bytes\":%zu,\"parse_peak_bytes\":%zu,\"parse_allocation_calls\":%zu,\"visible_nodes\":%zu,\"named_nodes\":%zu,\"html_labels\":%zu,\"has_error\":%s,\"parser_after_tree_delete_bytes\":%zu,\"final_live_bytes\":%zu}\n",n,sec,before,parsed,parse_peak,parse_allocations,visible,named,html,errors?"true":"false",retained,live);
 free(s);return errors?1:0;
}
