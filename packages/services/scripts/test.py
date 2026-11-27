import os
from pathlib import Path
import sys
import unittest

root = Path(__file__).resolve().parents[3]
os.environ["CPI_SERVICES_BINARY"] = str(Path(sys.argv[1]).resolve())
os.environ["CPI_GHOSTMUX_BINARY"] = str(Path(sys.argv[2]).resolve())
os.environ["CPI_AGENT_LIBRARY"] = str(Path(sys.argv[3]).resolve())
sys.path.insert(0, str(root / "packages/services/python"))
os.environ["PYTHONPATH"] = os.pathsep.join(sys.path)
suite = unittest.defaultTestLoader.discover(
    str(Path(__file__).resolve().parents[1] / "tests")
)
raise SystemExit(not unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful())
