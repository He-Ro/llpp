#!/usr/bin/env python
import os, sys, subprocess, socket

fields = sys.stdin.read ().split ('\x00')

while len (fields) > 1:
    opath, atime = fields[0:2]
    fields = fields[2:]
    npath = ""
    if not os.path.exists (opath):
        try:
            npath = subprocess.check_output (
                "locate -b -l 1 -e '/%s$'" % opath,
                shell = False
            )
        except:
            pass
        npath = npath[:-1]
        sys.stdout.write (opath + "\000" + npath + "\000")
    elif os.path.isdir (opath):
            sys.stdout.write (opath + "\000\000")

sys.stdout.flush ()
socket.fromfd (sys.stdout.fileno (),
               socket.AF_UNIX,
               socket.SOCK_STREAM).shutdown (socket.SHUT_RDWR)
sys.stderr.write ("gc.py done\n")
os._exit (0)
