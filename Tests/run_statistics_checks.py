"""Run model calculations and legacy-store migration checks without a simulator."""
import subprocess
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="PhotoSweep-statistics-checks-") as directory:
    executable = Path(directory) / "StatisticsChecks"
    store = Path(directory) / "statistics.store"
    subprocess.run(
        [
            "xcrun", "swiftc", "-parse-as-library",
            str(root / "PhotoSweep/Models/ReviewRecord.swift"),
            str(root / "PhotoSweep/Models/CleanupStatistics.swift"),
            str(root / "Tests/StatisticsChecks.swift"),
            "-o", str(executable),
        ],
        check=True,
    )
    for phase in ["calculations", "seed", "migrate", "verify"]:
        subprocess.run([str(executable), phase, str(store)], check=True)
