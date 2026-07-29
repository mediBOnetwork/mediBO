import re,sys,os
STORAGE={'dispute-proofs','supplier-bills','whatsapp-media','customer-bills','bills','voice-clips'}
WRITE=re.compile(r"\.(insert|update|upsert|delete)\s*\(")
FROM=re.compile(r"(?<!storage)\.from\('([^']+)'\)")
writes=[];reads=[]
for root,_,files in os.walk('lib'):
    for f in files:
        if not f.endswith('.dart'): continue
        p=os.path.join(root,f); lines=open(p).read().split('\n')
        for i,l in enumerate(lines):
            m=FROM.search(l)
            if not m: continue
            # skip comments — a comment naming .from() is not a call
            if l.lstrip().startswith('//') or l.lstrip().startswith('///'): continue
            if 'storage.from(' in l: continue
            if m.group(1) in STORAGE: continue
            window='\n'.join(lines[i:i+6])
            (writes if WRITE.search(window) else reads).append(f"{p}:{i+1}: {l.strip()[:90]}")
print("=== TABLE WRITES:",len(writes),"===")
for w in writes: print(" ",w)
print("=== TABLE READS:",len(reads),"===")
