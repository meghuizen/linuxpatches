# like trace.py but decisions may be lists (per-visit) : {"addr":[true,false]}
import sys,re,json
ann,start,dec=sys.argv[1],sys.argv[2],json.loads(sys.argv[3])
ins={};order=[]
for l in open(ann):
    m=re.match(r'^([0-9a-f]+):\s+(\S+)\s*(.*?)\s*\|\s*(.*)$',l)
    if m and m.group(2).startswith('R_X86'):
        p=order[-1]; ins[p]=(ins[p][0],ins[p][1]+' @'+m.group(3),ins[p][2]); continue
    if m: ins[m.group(1)]=(m.group(2),m.group(3),m.group(4)); order.append(m.group(1))
idx={a:i for i,a in enumerate(order)}
visits={}
pc=start;n=0;calls=[]
while True:
    op,args,src=ins[pc];n+=1
    if op.startswith('ret') or ('__x86_return_thunk' in args): break
    if op=='call': calls.append(args.split('@')[-1].strip() if '@' in args else args.split('<')[-1].rstrip('>'))
    if op=='jmp':
        if '@' in args and 'return_thunk' not in args: calls.append(args.split('@')[-1].strip()); break
        t=re.search(r'^([0-9a-f]+) <',args); 
        if t.group(1) not in ins: calls.append('tail:'+args); break
        pc=t.group(1); continue
    if op.startswith('j'):
        t=re.search(r'^([0-9a-f]+) <',args).group(1)
        d=dec.get(pc)
        if isinstance(d,list):
            v=visits.get(pc,0); visits[pc]=v+1
            d=d[v] if v<len(d) else None
        if d is None:
            print(f'UNDECIDED {pc}: {op} {args} | {src}')
            j=idx[pc]
            for a in order[max(0,j-4):j+1]: print('   ',a,ins[a])
            nxt=order[j+1]; print('   fallthrough:',nxt,ins[nxt]); print('   target:',t,ins[t])
            break
        pc = t if d else order[idx[pc]+1]; continue
    pc=order[idx[pc]+1]
print('insns',n,'calls',calls)
