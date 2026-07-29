import re,sys,os
STORAGE={'dispute-proofs','supplier-bills','whatsapp-media','customer-bills','bills','voice-clips'}
WRITE=re.compile(r"\.(insert|update|upsert|delete)\s*\(")
FROM=re.compile(r"(?<!storage)\.from\('([^']+)'\)")
# CHANGE #603: also catch a VARIABLE table name — .from(table) — which the
# quoted-literal pattern above slips past. admin_alert_overlay hid an approval
# write behind exactly that for the whole sweep.
# Only a Supabase client .from(var) counts — List.from/Map.from/Set.from are
# Dart constructors, not table access.
FROM_VAR=re.compile(r"client\s*\.from\(\s*[A-Za-z_][A-Za-z0-9_]*\s*\)")
writes=[];reads=[]
for root,_,files in os.walk('lib'):
    for f in files:
        if not f.endswith('.dart'): continue
        p=os.path.join(root,f); lines=open(p).read().split('\n')
        for i,l in enumerate(lines):
            m=FROM.search(l)
            mv=FROM_VAR.search(l) if not m else None
            if not m and not mv: continue
            # skip comments — a comment naming .from() is not a call
            if l.lstrip().startswith('//') or l.lstrip().startswith('///'): continue
            if 'storage.from(' in l: continue
            if m and m.group(1) in STORAGE: continue
            window='\n'.join(lines[i:i+6])
            (writes if WRITE.search(window) else reads).append(f"{p}:{i+1}: {l.strip()[:90]}")
print("=== TABLE WRITES:",len(writes),"===")
for w in writes: print(" ",w)
print("=== TABLE READS:",len(reads),"===")
