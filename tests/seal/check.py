# Independent checker: does not share any code with zsign/TrustCore.
import sys, os, struct, hashlib, plistlib, base64
def be(b,o): return struct.unpack_from('>I',b,o)[0]
def slices(path):
    d=open(path,'rb').read(8)
    if struct.unpack('>I',d[:4])[0]==0xcafebabe:
        n=struct.unpack('>I',d[4:8])[0]; f=open(path,'rb'); f.seek(8); a=f.read(20*n)
        return [(struct.unpack_from('>I',a,i*20+8)[0],struct.unpack_from('>I',a,i*20+12)[0]) for i in range(n)]
    return [(0,os.path.getsize(path))]
def check_macho(path, info=None, cres=None):
    errs=[]
    f=open(path,'rb')
    for si,(off,size) in enumerate(slices(path)):
        f.seek(off); h=f.read(32); ncmds,sz=struct.unpack_from('<II',h,16); cmds=f.read(sz)
        p=0; text_vm=None; cs=None
        for _ in range(ncmds):
            cmd,cs_=struct.unpack_from('<II',cmds,p)
            if cmd==0x19 and cmds[p+8:p+24].rstrip(b'\0')==b'__TEXT': text_vm=struct.unpack_from('<Q',cmds,p+32)[0]
            if cmd==0x1d: cs=struct.unpack_from('<II',cmds,p+8)
            p+=cs_
        dataoff,datasize=cs; f.seek(off+dataoff); sig=f.read(datasize)
        assert be(sig,0)==0xfade0cc0
        cnt=be(sig,8); cds=[]
        for i in range(cnt):
            t,o=be(sig,12+i*8),be(sig,16+i*8)
            if t==0 or 0x1000<=t<0x1005: cds.append(sig[o:o+be(sig,o+4)])
        f.seek(off); code=f.read(dataoff)
        for cd in cds:
            hoff,nspec,ncode,limit=be(cd,16),be(cd,24),be(cd,28),be(cd,32); hs,ht,ps=cd[36],cd[37],cd[39]
            esl=struct.unpack_from('>Q',cd,72)[0]
            H=hashlib.sha1 if ht==1 else hashlib.sha256
            if limit!=dataoff: errs.append(f'{path} s{si}: codeLimit {limit}!={dataoff}')
            if esl!=text_vm: errs.append(f'{path} s{si}: execSegLimit {esl:#x} != own __TEXT vmsize {text_vm:#x}')
            pg=1<<ps
            bad=sum(1 for k in range(ncode) if cd[hoff+k*hs:hoff+(k+1)*hs]!=H(code[k*pg:(k+1)*pg]).digest())
            if bad: errs.append(f'{path} s{si}: {bad} bad page hashes')
            if info and cd[hoff-hs:hoff]!=H(open(info,'rb').read()).digest(): errs.append(f'{path} s{si}: Info.plist slot mismatch')
            if cres and cd[hoff-3*hs:hoff-2*hs]!=H(open(cres,'rb').read()).digest(): errs.append(f'{path} s{si}: CodeResources slot mismatch')
    return errs
def check_bundle(b, exe):
    errs=check_macho(os.path.join(b,exe), os.path.join(b,'Info.plist'), os.path.join(b,'_CodeSignature/CodeResources'))
    cr=plistlib.load(open(os.path.join(b,'_CodeSignature/CodeResources'),'rb'))
    files2=cr['files2']; ondisk=set()
    for r,ds,fs in os.walk(b):
        for n in fs:
            p=os.path.join(r,n)
            if os.path.islink(p): continue
            ondisk.add(os.path.relpath(p,b))
    ondisk-= {exe,'_CodeSignature/CodeResources','Info.plist','PkgInfo'}
    if set(files2)!=ondisk: errs.append(f'{b}: seal file list differs: extra={sorted(ondisk-set(files2))[:3]} missing={sorted(set(files2)-ondisk)[:3]}')
    for k,v in files2.items():
        hh=hashlib.sha256()
        with open(os.path.join(b,k),'rb') as fh:
            for ch in iter(lambda: fh.read(1<<20), b''): hh.update(ch)
        if v['hash2']!=hh.digest(): errs.append(f'{b}: resource hash mismatch {k}')
    return errs
app=sys.argv[1]
errs=check_bundle(os.path.join(app,'Frameworks/Foo.framework'),'Foo')
errs+=check_macho(os.path.join(app,'Frameworks/libbar.dylib'))
errs+=check_bundle(app,'Big')
print('INDEPENDENT_CHECK', 'PASS' if not errs else 'FAIL'); [print('  ',e) for e in errs[:12]]
