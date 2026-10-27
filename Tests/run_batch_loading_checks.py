"""Exercise the production view model and preloader with an in-memory photo library.

Only unavailable iOS imports are replaced; no simulator, photos or app data are used.
"""
import subprocess
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="PhotoSweep-batch-checks-") as directory:
    directory = Path(directory)
    sources = []
    for relative in [
        "PhotoSweep/Services/MediaPreloadService.swift",
        "PhotoSweep/ViewModels/ReviewViewModel.swift",
    ]:
        source = (root / relative).read_text()
        source = "\n".join(line for line in source.splitlines() if line not in {
            "import Photos", "import UIKit", "import AVFoundation",
        })
        destination = directory / Path(relative).name
        destination.write_text("import Foundation\n" + source)
        sources.append(str(destination))
    library = (root / "PhotoSweep/Services/PhotoLibraryService.swift").read_text()
    types = directory / "LibraryTypes.swift"
    types.write_text(library.split("final class PhotoLibraryService")[0].replace("import Photos", ""))
    offline = (root / "PhotoSweep/Services/OfflineCacheService.swift").read_text()
    snapshot = directory / "OfflineSnapshot.swift"
    snapshot.write_text(offline.split("private struct OfflineCacheEntry")[0].replace("import Photos", "").replace("import UIKit", ""))
    executable = directory / "BatchLoadingChecks"
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
        *sources, str(types), str(snapshot),
        str(root / "PhotoSweep/Models/ReviewRecord.swift"),
        str(root / "PhotoSweep/Models/CleanupStatistics.swift"),
        str(root / "Tests/BatchLoadingStubs.swift"),
        str(root / "Tests/BatchLoadingChecks.swift"),
        "-o", str(executable),
    ], check=True)
    subprocess.run([str(executable)], check=True)
