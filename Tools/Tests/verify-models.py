from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="offline-kit-checks-") as temporary:
    temp = Path(temporary)
    common = ["swiftc", "-parse-as-library", "-module-cache-path", str(temp / "modules")]
    sources = [root / "Sources/Core/Catalog.swift", root / "Sources/Core/Subjects.swift", root / "Tools/Tests/SubjectSearchChecks.swift"]
    subprocess.run(common + [str(p) for p in sources] + ["-o", str(temp / "subjects")], check=True)
    subprocess.run([str(temp / "subjects")], check=True)
    # Compile the actual game models, excluding the emulation and display code.
    game_models = (root / "Sources/App/GameSession.swift").read_text().split("// MARK: - Session")[0]
    (temp / "GameModels.swift").write_text(game_models)
    subprocess.run(common + [str(temp / "GameModels.swift"), str(root / "Tools/Tests/GameMetadataChecks.swift"), "-o", str(temp / "games")], check=True)
    subprocess.run([str(temp / "games")], check=True)
