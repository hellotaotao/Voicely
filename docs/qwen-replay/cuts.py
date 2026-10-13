import json,sys
FR=0.036
rows=[json.loads(l) for l in open(sys.argv[1])]
cuts=[]
for r in rows:
    p=r['probabilities']; s=r['start']; e=r['end']; pos=0.0; dur=e-s
    # Mirrors the old-dev Qwen slicing: 14 s chunks, VAD cut no earlier than 7 s.
    while dur-pos>14:
        lo=int((pos+7)/FR); hi=min(len(p)-1,int((pos+14)/FR))
        k=min(range(lo,hi+1),key=lambda i:(p[i],-i))
        cut=(k+0.5)*FR
        cuts.append([round(s+pos,3),round(s+cut,3)]); pos=cut
    cuts.append([round(s+pos,3),round(e,3)])
json.dump(cuts,open(sys.argv[2],'w'))
d=[c[1]-c[0] for c in cuts]; print(len(cuts),'cuts, max',max(d),'min',min(d))
