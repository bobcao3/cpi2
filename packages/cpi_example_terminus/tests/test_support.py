from pathlib import Path
import os
import uuid


def configure_ghostmux_socket(package_dir: Path) -> None:
    if "CPI_TERMINUS_TEST_SOCKET" in os.environ:
        os.environ["CPI_GHOSTMUX_SOCKET"] = os.environ["CPI_TERMINUS_TEST_SOCKET"]
        return

    socket_dir = package_dir / ".zig-cache" / f"ghostmux-{uuid.uuid4().hex[:12]}"
    socket_dir.mkdir(mode=0o700, parents=True)
    os.environ["CPI_GHOSTMUX_SOCKET"] = str(socket_dir / "control.sock")
