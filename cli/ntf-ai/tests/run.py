#!/usr/bin/env python3
"""Run the complete CLI gate, optionally mutations, sharing one disposable Docker ntfy."""
import argparse
import os
from pathlib import Path
import subprocess
import sys
import unittest
import test_e2e

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--mutate',action='store_true',help='also kill every CLI mutant')
a=p.parse_args()
here=Path(__file__).resolve().parent
# Own cleanup here; individual unittest modules must not remove the shared server.
test_e2e.setUpModule()
container=test_e2e.CONTAINER
test_e2e.CONTAINER=None
os.environ['NTF_E2E_SERVER']=test_e2e.SERVER
try:
    result=unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.discover(str(here)))
    if not result.wasSuccessful():
        raise SystemExit(1)
    if a.mutate:
        raise SystemExit(subprocess.call([sys.executable,str(here/'mutate.py')]))
finally:
    if container:
        subprocess.run(['docker','rm','-f',container],capture_output=True)
