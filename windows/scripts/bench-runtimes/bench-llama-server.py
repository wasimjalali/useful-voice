# Runtime comparison, llama-server side (llama.cpp release b11669, the build the cleanup eval used).
# Writes the raw latencies to $OUT. Median and p95 are sorted[n//2] and sorted[int(0.95*n)].
# LLAMA_DIR=<unpacked release> MODEL=<s1-mini-q4_k_m.gguf> CASES=<evals/cleanup/cases.json> python3 bench-llama-server.py
import json,subprocess,time,urllib.request,sys,os,signal
SYS='You are a text normalizer for speech-to-text transcripts. The input begins with a control line specifying the styling, structure, and context settings; clean the transcript to match those settings and output only the cleaned text.'
L=os.environ['LLAMA_DIR']
env=dict(os.environ,LD_LIBRARY_PATH=L)
t0=time.time()
p=subprocess.Popen([L+'/llama-server','-m',os.environ['MODEL'],'--jinja','--chat-template-kwargs','{"enable_thinking":false}','--temp','0','-c','2048','-np','1','--port','18099','-t','4'],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
while True:
    try: urllib.request.urlopen('http://127.0.0.1:18099/health',timeout=1); break
    except Exception: time.sleep(0.05)
load=(time.time()-t0)*1000
def rss(): 
    for l in open(f'/proc/{p.pid}/status'):
        if l.startswith('VmRSS'): return int(l.split()[1])//1024
cases=json.load(open(os.environ['CASES']))[:40]
lat=[]
for i in range(len(cases)+3):
    c=cases[i%len(cases)]
    body=json.dumps({'messages':[{'role':'system','content':SYS},{'role':'user','content':'[Styling: semi-formal] [Structure: prose] [Context: general]\n'+c['input']}],'temperature':0,'seed':0,'chat_template_kwargs':{'enable_thinking':False}}).encode()
    t=time.time()
    urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:18099/v1/chat/completions',body,{'Content-Type':'application/json'})).read()
    d=(time.time()-t)*1000
    if i>=3: lat.append(d)
raw=list(lat)
lat.sort()
out=dict(load_ms=round(load),rss_after_mb=rss(),n=len(lat),median=round(lat[len(lat)//2]),p95=round(lat[int(.95*len(lat))]),max=round(lat[-1]),latencies_ms=[round(x) for x in raw],ctx=2048,loadavg_start=os.environ.get('LOADAVG'))
print(json.dumps({k:v for k,v in out.items() if k!='latencies_ms'}))
if os.environ.get('OUT'): json.dump(out,open(os.environ['OUT'],'w'),indent=1)
p.send_signal(signal.SIGTERM)
