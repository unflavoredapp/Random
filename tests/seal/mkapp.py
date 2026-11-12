import os, struct, sys, plistlib
def macho(path, code_size, text_vm, filetype=2, sig_space=None, seed=1):
    """Synthetic arm64 Mach-O: __TEXT(0..code_size) + __LINKEDIT holding the signature space."""
    page=4096
    pages=(code_size+page-1)//page
    if sig_space is None: sig_space=((pages*52+65536+page-1)//page)*page
    ncmds=3; seg=72; sect=80
    cmds=b''
    # __TEXT with one __text section starting at 0x4000 (free space for an extra load command)
    cmds+=struct.pack('<II16sQQQQiiII',0x19,seg+sect,b'__TEXT',0,text_vm,0,code_size,5,5,1,0)
    cmds+=struct.pack('<16s16sQQIIIIIIII',b'__text',b'__TEXT',0x4000,code_size-0x4000,0x4000,4,0,0,0x80000400,0,0,0)
    cmds+=struct.pack('<II16sQQQQiiII',0x19,seg,b'__LINKEDIT',text_vm,(sig_space+0x3fff)//0x4000*0x4000,code_size,sig_space,1,1,0,0)
    cmds+=struct.pack('<IIII',0x1d,16,code_size,sig_space)
    hdr=struct.pack('<IiiIIIII',0xfeedfacf,0x0100000c,0,filetype,ncmds,len(cmds),0x200085,0)
    with open(path,'wb') as f:
        f.write(hdr+cmds)
        rnd=__import__('random').Random(seed)
        left=code_size-len(hdr)-len(cmds)
        f.write(b'\x00'*(0x4000-len(hdr)-len(cmds))); left-= 0x4000-len(hdr)-len(cmds)
        while left>0:
            n=min(left,1<<22); f.write(os.urandom(n) if n>4096 else rnd.randbytes(n)); left-=n
        f.write(b'\x00'*sig_space)
def fat(path, slices):
    datas=[open(s,'rb').read() for s in slices]
    hdr=struct.pack('>II',0xcafebabe,len(datas)); off=0x4000; arch=b''
    for i,d in enumerate(datas):
        arch+=struct.pack('>iiIII',0x0100000c,i,off,len(d),14); off+=(len(d)+0x3fff)//0x4000*0x4000
    with open(path,'wb') as f:
        f.write(hdr+arch); off=0x4000
        for d in datas:
            f.seek(off); f.write(d); off+=(len(d)+0x3fff)//0x4000*0x4000
def info(dirp, bid, exe):
    plistlib.dump({'CFBundleIdentifier':bid,'CFBundleExecutable':exe,'CFBundleName':exe,'CFBundleVersion':'1','CFBundleShortVersionString':'1.0'},open(os.path.join(dirp,'Info.plist'),'wb'))

root=sys.argv[1]; main_mb=int(sys.argv[2]); assets_mb=int(sys.argv[3]); fatmain=sys.argv[4]=='fat'; tight=len(sys.argv)>5 and sys.argv[5]=='tight'
app=os.path.join(root,'Payload','Big.app'); fw=os.path.join(app,'Frameworks','Foo.framework')
os.makedirs(fw,exist_ok=True)
info(app,'com.test.big','Big'); info(fw,'com.test.foo','Foo')
open(os.path.join(app,'embedded.mobileprovision'),'wb').write(b'x')
if fatmain:
    macho(root+'/s0',main_mb<<20,(main_mb<<20)+0x8000,seed=1)
    macho(root+'/s1',(main_mb<<20)//2,((main_mb<<20)//2)+0x20000,seed=2)   # different __TEXT size per slice
    fat(os.path.join(app,'Big'),[root+'/s0',root+'/s1']); os.remove(root+'/s0'); os.remove(root+'/s1')
else:
    macho(os.path.join(app,'Big'),main_mb<<20,(main_mb<<20)+0x8000,sig_space=(16384 if tight else None))
macho(os.path.join(fw,'Foo'),20<<20,(20<<20)+0x4000,filetype=6)
macho(os.path.join(app,'Frameworks','libbar.dylib'),8<<20,(8<<20)+0x4000,filetype=6)
for i in range(40): open(os.path.join(app,f'res{i}.dat'),'wb').write(os.urandom(4096*(i+1)))
os.makedirs(os.path.join(app,'en.lproj'),exist_ok=True); open(os.path.join(app,'en.lproj','InfoPlist.strings'),'wb').write(b'"a"="b";')
with open(os.path.join(app,'assets.bin'),'wb') as f:
    for _ in range(assets_mb//64): f.write(os.urandom(64<<20))
print('built',app)
