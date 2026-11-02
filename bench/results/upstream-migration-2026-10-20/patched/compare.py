import sys,pathlib,json,statistics,re,hashlib
p=pathlib.Path(__file__).parent;sys.path.insert(0,str(p/'tools'));import server_compare as b
b.FIXTURES=p/'fixtures';b.INIT=b.packet('initialize',{'capabilities':{'general':{'positionEncodings':['utf-16']},'textDocument':{'documentSymbol':{'hierarchicalDocumentSymbolSupport':True}}}},1)
rows=[];out=p/'performance.json'
for mb in map(int,sys.argv[1:] or ['5']):
 for kind in ['plain','html','quoted']:
  if kind=='quoted':
   line=b'    "node with spaces 0000000000000000" -> "other node 00000000000000000000";\n'
   count=(mb*1000000-16)//len(line);source=b'digraph G {\n'+line*count+b'}\n';positions=[];meta={'source_bytes':len(source)}
  else:source,positions,meta=b.fixture(kind,mb)
  # Alternating order limits warm-cache/order bias.
  for trial in range(3):
   for label in (['before','after'] if trial%2==0 else ['after','before']):
    binary=p/('baseline-build/zig-out/bin/dot-ls' if label=='before' else 'zig-out/bin/dot-ls');b.SERVERS['dot-ls']=[str(binary),'lsp'];c=None;ok=False
    try:
     c=b.Client('dot-ls');idle=c.quiet(); phases=[]
     texts=[source,b.damage(source,positions,1).encode(),source] if positions else [source,source,source]
     for version,text in enumerate(texts,1):phases.append(c.measure(b.message(text.decode(),version),version,'html' if kind=='html' else 'plain','open' if version==1 else 'edit',1 if version==2 and positions else 0))
     ok=True
    finally:
     resources=c.close(ok) if c else {}
    assert ok and resources['exit_code']==0 and not resources['safety_stop'],resources
    ticks=list(map(int,re.findall(r'REF_INDEX_TICKS (\d+)',resources['stderr'])))
    row={'mb':mb,'kind':kind,'label':label,'trial':trial,'source_bytes':len(source),'startup_ms':c.startup_ms,'idle':idle,'phases':phases,'resources':resources,'reference_phase_ms':[v*b.TB.numer/b.TB.denom/1e6 for v in ticks]};rows.append(row);out.write_text(json.dumps(rows,indent=2))
    print(mb,kind,label,trial,'diag',round(statistics.median(x['final_diagnostics_ms'] for x in phases),2),'index',list(map(lambda v:round(v,2),row['reference_phase_ms'])),'peakMB',round(resources['actual_peak_rss_bytes']/1e6,2),flush=True)
