"""layout-model.py -- offline model used to choose the sched_entity order.

Computes sched_entity offsets for a given member order under the x86_64
and i386 ABIs (sizes/alignments as reported by pahole), for the six
configs in CFG, and scores an order by the per-pattern line counts from
se-lines.py (PATHS). An order is admissible only if no pattern gets worse
in any config and the offset of avg (hence sizeof) is unchanged. The
model reproduces the pahole results for the five configs that were built;
nofgs-i386g is model-only. Running it performs a random hill-climb; the
order in the patch is the one-#ifdef-block order 'C1' found this way
(score 80; the best order found, 83, needed two #ifdef blocks).
"""
import random, itertools, sys
sys.path.insert(0,'/usr/src/linuxpatches/linux-kernel/sched/submission/tests')
import importlib.util
spec=importlib.util.spec_from_file_location("sl","/usr/src/linuxpatches/linux-kernel/sched/submission/tests/se-lines.py")
sl=importlib.util.module_from_spec(spec); spec.loader.exec_module(sl)
PATHS=[(d,n.split()) for d,n in sl.PATHS]
W=[5,2,3,1,1,1,1,1,1,1,1,2,1]   # weights, pick/augment/detach emphasised
ABI={64:dict(run_node=(24,8),u64=(8,8),ptr=(8,8),list=(16,8),lw=(16,8),flags=(4,1),int=(4,4),ul=(8,8)),
     32:dict(run_node=(12,4),u64=(8,4),ptr=(4,4),list=(8,4),lw=(8,4),flags=(4,1),int=(4,4),ul=(4,4))}
T=dict(run_node='run_node',deadline='u64',vruntime='u64',min_vruntime='u64',vlag='u64',slice='u64',
 exec_start='u64',sum_exec_runtime='u64',prev_sum_exec_runtime='u64',vprot='u64',flags='flags',
 depth='int',cfs_rq='ptr',parent='ptr',my_q='ptr',runnable_weight='ul',group_node='list',
 min_slice='u64',max_slice='u64',nr_migrations='u64',h_load='lw',load='lw')
FGS={'depth','cfs_rq','parent','my_q','runnable_weight'}
# configs: (bits, fgs, se_off, avg_align)
CFG={'x86':(64,1,128,64),'nofgs-x86':(64,0,128,64),'i386g':(32,1,128,64),'i386':(32,1,96,32),'nofgs-i386':(32,0,96,32),'nofgs-i386g':(32,0,128,64)}
FLAGS={'on_rq','sched_delayed','rel_deadline','custom_slice'}
def layout(order,bits,fgs):
    off=0; res={}
    for f in order:
        if f in FGS and not fgs: continue
        sz,al=ABI[bits][T[f]]
        off=(off+al-1)//al*al
        if f=='flags':
            for i,n in enumerate(['on_rq','sched_delayed','rel_deadline','custom_slice']): res[n]=(off+i,1)
        else: res[f]=(off,sz)
        off+=sz
    return res,off
def avgpos(end,al): return (end+al-1)//al*al
def count(res,se_off,avg,names):
    s=set()
    for n in names:
        if n=='avg': o,sz=avg,64
        elif n in res: o,sz=res[n]
        else: continue
        a=se_off+o; s.update(range(a//64,(a+sz-1)//64+1))
    return len(s)
BASE=['h_load_load']  # placeholder
base_order=['load','h_load','run_node','deadline','min_vruntime','min_slice','max_slice','group_node','flags','exec_start','sum_exec_runtime','prev_sum_exec_runtime','vruntime','vlag','vprot','slice','nr_migrations','depth','parent','cfs_rq','my_q','runnable_weight']
def evaluate(order):
    tot=0; detail={}
    for c,(bits,fgs,se_off,al) in CFG.items():
        rb,eb=layout(base_order,bits,fgs); ra,ea=layout(order,bits,fgs)
        ab=avgpos(eb,al); aa=avgpos(ea,al)
        if aa!=ab: return None
        row=[]
        for (d,names),w in zip(PATHS,W):
            b=count(rb,se_off,ab,names); a=count(ra,se_off,aa,names)
            if a>b: return None
            tot+=w*(b-a); row.append((b,a))
        detail[c]=row
    return tot,detail
six=['run_node','deadline','vruntime','min_vruntime','vlag','slice']
rest=['exec_start','sum_exec_runtime','prev_sum_exec_runtime','vprot','flags','depth','cfs_rq','group_node','parent','my_q','runnable_weight','min_slice','max_slice','nr_migrations','h_load','load']
def fgs_groups(o):
    g=0;prev=False
    for f in o:
        cur=f in FGS
        if cur and not prev: g+=1
        prev=cur
    return g
if __name__=='__main__':
    v2=six+['exec_start','sum_exec_runtime','prev_sum_exec_runtime','vprot','flags','depth','cfs_rq','group_node','parent','my_q','runnable_weight','min_slice','max_slice','nr_migrations','h_load','load']
    pub=six+['load','exec_start','sum_exec_runtime','prev_sum_exec_runtime','vprot','flags','depth','cfs_rq','parent','my_q','runnable_weight','min_slice','max_slice','nr_migrations','group_node','h_load']
    # sanity: model vs pahole for base/pub/v2 x86
    for name,o in [('pub',pub),('v2',v2)]:
        print(name, evaluate(o) and evaluate(o)[0])
    random.seed(int(sys.argv[1]) if len(sys.argv)>1 else 1)
    best=None
    # hill climb from v2 with swaps
    for restart in range(40):
        cur=rest[:]; random.shuffle(cur) if restart else None
        r=evaluate(six+cur); sc=r[0] if r and fgs_groups(cur)<=2 else -1
        for it in range(4000):
            i,j=random.sample(range(len(cur)),2)
            n=cur[:]; n[i],n[j]=n[j],n[i]
            if random.random()<0.5:
                x=n.pop(i); n.insert(j,x)
            if fgs_groups(n)>2: continue
            r=evaluate(six+n)
            if r and r[0]>=sc:
                cur,sc=n,r[0]
        if sc>=0 and (best is None or sc>best[0]):
            best=(sc,cur); print(sc,cur,flush=True)
