import json,sys,re,difflib,zlib
W=[json.loads(l) for l in open(sys.argv[1])]; Q=[json.loads(l) for l in open(sys.argv[2])]
norm=lambda t: re.sub(r'[\W_]+','',t or '').lower()
cjk=lambda t: sum('一'<=c<='鿿' for c in t); lat=lambda t: sum(c.isascii() and c.isalpha() for c in t)
ratio=lambda t: len(t.encode())/max(1,len(zlib.compress(t.encode())))
for w in W:
    qs=[q for q in Q if q['start']>=w['start']-1e-3 and q['end']<=w['end']+1e-3]
    w['qp']=''.join(q['plain'] for q in qs); w['qh']=''.join(q['hinted'] for q in qs); w['s55']=sum(x>=0.55 for x in w['probabilities'])*0.036
aud=sum(w['end']-w['start'] for w in W)
print(f"audio {aud:.0f}s | whisper prompted {sum(w['promptedSeconds'] for w in W):.0f}s, prompt-free {sum(w['promptFreeSeconds'] for w in W):.0f}s | qwen plain {sum(q['plainSeconds'] for q in Q):.0f}s, hinted {sum(q['hintedSeconds'] for q in Q):.0f}s  ({len(Q)} qwen cuts)")
print('slowest qwen cut:',round(max(q['plainSeconds'] for q in Q),1),'s; slowest whisper prompt-free slice:',round(max(w['promptFreeSeconds'] for w in W),1))
for name,key in [('whisper+prompt','promptedText'),('whisper','promptFreeText'),('qwen','qp'),('qwen+context','qh')]:
    T=[norm(w[key]) for w in W]
    print(f"{name:15s} chars {sum(map(len,T)):6d} | empty slices {sum(not t for t in T):3d} | mostly-latin {sum(lat(t)>cjk(t) and len(t)>5 for t in T):3d} | compress>2.4 {sum(ratio(w[key] or '')>2.4 and len(t)>40 for w,t in zip(W,T)):3d} | 'claude' {sum(t.count('claude') for t in T):3d} 'code' {sum(t.count('code') for t in T):3d}")
sim=lambda a,b: difflib.SequenceMatcher(None,norm(a),norm(b)).ratio()
qq=[sim(w['qp'],w['qh']) for w in W]; wq=[sim(w['promptFreeText'],w['qp']) for w in W]
print('qwen plain vs qwen+context: slices sim>=0.9:',sum(x>=0.9 for x in qq),'of',len(W),'; <0.6:',[w['index'] for w,x in zip(W,qq) if x<0.6])
print('whisper(prompt-free) vs qwen: sim>=0.6:',sum(x>=0.6 for x in wq),'; <0.3:',[w['index'] for w,x in zip(W,wq) if x<0.3])
show=[int(x) for x in sys.argv[3].split(',')] if len(sys.argv)>3 else []
for i in show:
    w=W[i-1]; print(f"\n#{i} {w['start']:.0f}-{w['end']:.0f}s speech {w['s55']:.1f}s\n  W+p: {w['promptedText'][:150]!r}\n  W  : {(w['promptFreeText'] or '')[:150]!r}\n  Q  : {w['qp'][:150]!r}\n  Q+c: {w['qh'][:150]!r}")
