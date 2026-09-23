import sys,subprocess,re
obj,func,src=sys.argv[1:4]
srcl=open(src).read().split('\n')
out=subprocess.run(['objdump','-dlr','--no-show-raw-insn','--disassemble='+func,obj],capture_output=True,text=True).stdout
loc=None
for l in out.split('\n'):
    m=re.match(r'^/\S+/(\S+):(\d+)',l)
    if m:
        f,n=m.group(1),int(m.group(2))
        loc = (f'{n}: '+srcl[n-1].strip()[:60]) if f=='namei.c' else f'{f}:{n}'
        continue
    if re.match(r'^\s+[0-9a-f]+:\s',l):
        print(f'{l.strip():60s} | {loc}')
    elif 'R_X86' in l:
        print('      '+l.strip())
