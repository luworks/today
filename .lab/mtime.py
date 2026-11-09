#!/usr/bin/env python3
"""Lab: every tracked/generated file's mtime is a pure function of its content."""
import hashlib,os,subprocess
T0=946684800
files=[f for f in subprocess.check_output(['git','ls-files','-z'],text=True).split('\0') if f and os.path.isfile(f)]
for r,_,n in os.walk('ios/Today.xcodeproj'): files+=[os.path.join(r,x) for x in n]
for f in files:
    t=T0-int(hashlib.sha256(open(f,'rb').read()).hexdigest()[:12],16)%(1<<29)
    os.utime(f,(t,t))
for d in sorted({os.path.dirname(f) for f in files},key=len,reverse=True):
    if d: os.utime(d,(T0,T0))
print('mtime:',len(files))
