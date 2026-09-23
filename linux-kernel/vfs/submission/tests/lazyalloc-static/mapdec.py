import sys,re,json,difflib
def load(p):
    out=[]
    for l in open(p):
        m=re.match(r'^([0-9a-f]+):\s+(\S+)\s*(.*?)\s*\|\s*(.*)$',l)
        if m and not m.group(2).startswith('R_X86'):
            args=re.sub(r'[0-9a-f]+ <path_openat\+0x[0-9a-f]+>','T',m.group(3))
            src=re.sub(r'^\d+: ','',m.group(4))
            out.append((m.group(1), m.group(2)+' '+args+' |'+src))
    return out
a=load(sys.argv[1]); b=load(sys.argv[2]); dec=json.load(open(sys.argv[3]))
sm=difflib.SequenceMatcher(None,[x[1] for x in a],[x[1] for x in b],autojunk=False)
amap={}
for i,j,n in sm.get_matching_blocks():
    for k in range(n): amap[a[i+k][0]]=b[j+k][0]
new={}
for k,v in dec.items():
    if k in amap: new[amap[k]]=v
    else: print('unmapped',k,file=sys.stderr)
print(json.dumps(new))
