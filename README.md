# AtomUniverse – iOS-Build

Dieses öffentliche Repo baut aus einem Unity-iOS-Xcode-Export eine **unsignierte `.ipa`** für iPhone und iPad. Es enthält nur den Workflow, zwei Skripte und eine Mini-App zum Testen, keinen Spielcode, keine Zugangsdaten und keine Secrets. Das Spiel selbst liegt in einem privaten Repo.

Öffentlich ist es, weil GitHub-gehostete Runner (auch macOS) in öffentlichen Repos nichts kosten. Darum sind hier **Logs, Eingaben und Artefakte für alle sichtbar**, auch der Download-Link zum Xcode-Export.

## Starten

GitHub → **Actions** → **ios-ipa** → **Run workflow**, oder per CLI:

```sh
gh workflow run ios-ipa.yml -R MedusaV9/AtomUniverse-iOS-Build \
  -f export_url=https://…/AtomUniverse-0.2.0-b42-ios.tar.zst -f export_sha256=<sha256> -f version=0.2.0
```

| Eingabe | Pflicht | Bedeutung |
|---|---|---|
| `export_url` | nein | Direkter https-Link zum Archiv des Xcode-Exports (`.tar.zst`, `.zip`, `.tar.gz`, `.tar.xz`). Das Archiv muss genau ein `Unity-iPhone.xcodeproj` enthalten. **Leer = Pipeline-Test** mit der Mini-App aus `pipeline-test/`. |
| `export_sha256` | nein | SHA-256 des Archivs. Stimmt er nicht, bricht der Lauf ab. |
| `version` | ja (Standard `0.0.0`) | Version im Dateinamen. Erlaubt: `A–Z a–z 0–9 . _ -`. |

Der Link muss die Datei direkt liefern (`curl -L` lädt sie). Eine HTML-Seite, z. B. die Seite eines Download-Dienstes, erkennt das Skript und bricht ab. Release-Assets des privaten Repos gehen nicht, weil sie ohne Token nicht ladbar sind.

## Ergebnis

- Artifact **`AtomUniverse-<version>-unsigned.ipa`** (beim Pipeline-Test `AtomUniverse-<version>-pipelinetest-unsigned.ipa`). Es ist eine einzelne Datei, kein ZIP drumherum, und bleibt 14 Tage liegen.
- Größe, SHA-256 und Dauer stehen in der Zusammenfassung des Laufs.
- Wenn der Build scheitert, liegt das vollständige xcodebuild-Log als Artifact `xcodebuild-log-<run-id>` bei.

## Ablauf

1. macOS-Runner `macos-26`, Xcode fest auf 26.3 (`XCODE_APP` im Workflow).
2. Pipeline-Test: XcodeGen 2.46.0 (Download mit geprüfter SHA-256) erzeugt `pipeline-test/AtomUniversePipelineTest.xcodeproj`. Mit Export: `scripts/fetch-export.sh` lädt, prüft und entpackt das Archiv.
3. `scripts/build-unsigned-ipa.sh`: `xcodebuild archive` für „generic iOS device“ mit `CODE_SIGNING_ALLOWED=NO`, `CODE_SIGNING_REQUIRED=NO` und leerem `CODE_SIGN_IDENTITY`, danach `Payload/<App>.app` als `.ipa` gepackt.
4. Upload als Artifact.

Wie die unsignierte `.ipa` aufs iPad oder iPhone kommt, steht im Spiel-Repo unter `unity/docs/build/ios-installieren.md`.
