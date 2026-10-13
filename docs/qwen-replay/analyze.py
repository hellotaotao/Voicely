import json, sys, re, collections
rows=[json.loads(l) for l in open(sys.argv[1])]
FR=0.036
def clean(t): return re.sub(r'\s+','',t or '')
def stats(r):
    p=r['probabilities']
    return dict(mx=max(p) if p else 0, s55=sum(x>=0.55 for x in p)*FR, s40=sum(x>0.40 for x in p)*FR, dur=r['end']-r['start'])
for r in rows: r.update(stats(r))
tot=sum(r['dur'] for r in rows)
print(f"slices {len(rows)}, audio {tot:.0f}s, decode prompted {sum(r['promptedSeconds'] for r in rows):.0f}s, prompt-free {sum(r['promptFreeSeconds'] or 0 for r in rows):.0f}s")
print("verdicts:", dict(collections.Counter(r['promptedVerdict'] for r in rows)), " current gate skips:", sum(not r['currentGateAdmits'] for r in rows))
usable=[r for r in rows if r['promptedVerdict']=='usable']
totchars=sum(len(clean(r['promptedText'])) for r in usable)
bad=[r for r in rows if r['promptedVerdict']!='usable']
print(f"usable chars total {totchars}")
print("\nT(s of p>=0.55) | skipped | bad caught/of | usable lost | chars lost (%) | decode s saved")
for T in [0.036,0.25,0.5,1,1.5,2,3,5,8]:
    sk=[r for r in rows if r['s55']<T]
    bc=[r for r in sk if r['promptedVerdict']!='usable']
    ul=[r for r in sk if r['promptedVerdict']=='usable']
    cl=sum(len(clean(r['promptedText'])) for r in ul)
    sv=sum(r['promptedSeconds'] for r in sk)
    print(f"{T:6.2f} | {len(sk):3d} | {len(bc):2d}/{len(bad):2d} | {len(ul):3d} | {cl:5d} ({100*cl/max(totchars,1):.1f}%) | {sv:.0f}")
print("\nnon-usable slices:")
for r in bad:
    print(f"#{r['index']:3d} {r['start']:6.0f}s dur {r['dur']:4.1f} mx {r['mx']:.2f} s55 {r['s55']:5.2f} s40 {r['s40']:5.2f} {r['promptedVerdict']:10s} P[{(r['promptedText'] or '')[:40]!r}] F[{(r['promptFreeText'] or '')[:50]!r}]")
print("\nusable slices with least speech (s55 ascending):")
for r in sorted(usable,key=lambda r:r['s55'])[:25]:
    print(f"#{r['index']:3d} {r['start']:6.0f}s dur {r['dur']:4.1f} mx {r['mx']:.2f} s55 {r['s55']:5.2f} s40 {r['s40']:5.2f} chars {len(clean(r['promptedText'])):3d} P[{(r['promptedText'] or '')[:60]!r}]")
