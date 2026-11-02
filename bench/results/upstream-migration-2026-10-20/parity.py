import sys,ast,json,pathlib
sys.path.insert(0,str(pathlib.Path(__file__).parent/'tests'))
import lsp,outline
root=pathlib.Path(__file__).parent
cases=[]
for n in ast.walk(ast.parse((root/'tests/outline.py').read_text())):
 if isinstance(n,ast.Call) and isinstance(n.func,ast.Name) and n.func.id=='check':
  try:s=ast.literal_eval(n.args[0])
  except:continue
  cases.append(s)
cases+=['digraph G { a [','digraph G { a [label=','digraph G { a ->','digraph G { a; broken -> ; later; }','digraph G { a [x=1]; b; }']
rows=[]
for s in cases:
 row={'source':s}
 for label,path in [('before',root/'baseline-build/zig-out/bin/dot-ls'),('after',root/'zig-out/bin/dot-ls')]:
  lsp.BIN=str(path);c=lsp.Client();outline.init(c);c.open(s);reply=outline.ask(c);c.stop();row[label]=reply.get('result',reply)
 row['same_names']=outline.tree(row['before'])==outline.tree(row['after']);row['same_ranges']=row['before']==row['after'];rows.append(row)
 print(row['same_names'],repr(s),outline.tree(row['before']),outline.tree(row['after']))
(root/'parity.json').write_text(json.dumps(rows,indent=2))
