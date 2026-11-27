import subprocess
import sys
import tempfile
from pathlib import Path


def main():
    probe, ghostmux = map(str, map(Path, sys.argv[1:]))
    with tempfile.TemporaryDirectory(prefix="cpi-owner-") as directory:
        try:
            subprocess.run([probe, ghostmux, directory], check=True, timeout=25)
        finally:
            for runtime in Path(directory).iterdir():
                if not runtime.is_dir():
                    continue
                socket = runtime / "control.sock"
                for job in runtime.glob("*.job"):
                    subprocess.run(
                        [ghostmux, "-S", str(socket), "signal-session", "--signal", "SIGKILL", "--uid", job.stem, "--json"],
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                        timeout=3,
                        check=False,
                    )


if __name__ == "__main__":
    main()
