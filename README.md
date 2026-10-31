# AtomUniverse – iOS-Build

Dieses öffentliche Repo baut aus einem Unity-iOS-Xcode-Export eine **unsignierte `.ipa`** für iPhone und iPad. Es enthält nur den Workflow, zwei Skripte und eine Mini-App zum Testen, keinen Spielcode, keine Zugangsdaten und keine Secrets. Das Spiel selbst liegt in einem privaten Repo.

Öffentlich ist es, weil GitHub-gehostete Runner (auch macOS) in öffentlichen Repos nichts kosten. Darum sind hier **Logs und Artefakte für alle sichtbar**. Den Download-Link zum Xcode-Export ersetzt der Workflow im Log durch `***`. GitHub zeigt die Eingaben eines Laufs nicht öffentlich an, sichert aber auch nicht zu, dass sie geheim bleiben. Darum nur kurzlebige Links nehmen (z. B. filebin.net, löscht nach 6 Tagen).

## Starten

GitHub → **Actions** → **ios-ipa** → **Run workflow**, oder per CLI:

```sh
gh workflow run ios-ipa.yml -R MedusaV9/AtomUniverse-iOS-Build \
  -f export_url=https://…/AtomUniverse-0.2.0-b42-ios.tar.zst -f export_sha256=<sha256> -f version=0.2.0 \
  -f release_tag=<tag-eines-entwurfs>   # optional
```

| Eingabe | Pflicht | Bedeutung |
|---|---|---|
| `export_url` | nein | Direkter https-Link zum Archiv des Xcode-Exports (`.tar.zst`, `.zip`, `.tar.gz`, `.tar.xz`). Das Archiv muss genau ein `Unity-iPhone.xcodeproj` enthalten. **Leer = Pipeline-Test** mit der Mini-App aus `pipeline-test/`. |
| `export_sha256` | nein | SHA-256 des Archivs. Stimmt er nicht, bricht der Lauf ab. |
| `version` | ja (Standard `0.0.0`) | Version im Dateinamen. Erlaubt: `A–Z a–z 0–9 . _ -`. |
| `release_tag` | nein | Tag eines **Release-Entwurfs** in diesem Repo. Ist er gesetzt, hängt ein zweiter Job (`ubuntu-24.04`) die `.ipa` an den Entwurf (`gh release upload --clobber`). Veröffentlichte Releases fasst er nicht an. Nur dieser Job hat Schreibrechte (`contents: write`), der macOS-Job nicht. |

Der Link muss die Datei direkt liefern (`curl -L` lädt sie). Eine HTML-Seite, z. B. die Seite eines Download-Dienstes, erkennt das Skript und bricht ab. Gofile-Seiten gehen deshalb nicht. Getestet und brauchbar ist **filebin.net**: `curl -X POST --data-binary @<datei> https://filebin.net/<zufälliger-bin>/<dateiname>` lädt hoch, derselbe Link lädt herunter. Release-Assets des privaten Spiel-Repos gehen nicht, weil sie ohne Token nicht ladbar sind.

## Ergebnis

- Artifact **`AtomUniverse-<version>-unsigned.ipa`** (beim Pipeline-Test `AtomUniverse-<version>-pipelinetest-unsigned.ipa`). Es ist eine einzelne Datei, kein ZIP drumherum, und bleibt 14 Tage liegen.
- Größe, SHA-256 und Dauer stehen in der Zusammenfassung des Laufs.
- Mit `release_tag` zusätzlich als Asset am Release-Entwurf. Entwürfe sieht nur, wer Schreibrechte am Repo hat.
- Das Job-Log zeigt, wie oft `-ffp-contract=off` in den clang-Aufrufen von IL2CPP steht (`Log lines with -ffp-contract=off`).
- Wenn der Build scheitert, zeigt das Job-Log nur die Fehlerzeilen und die Liste der fehlgeschlagenen Befehle. Das vollständige xcodebuild-Log gibt es als Artifact `xcodebuild-log-<run-id>` (7 Tage) nur beim Pipeline-Test, weil es bei einem Unity-Export Zeilen aus dem von IL2CPP erzeugten C++ zitiert und Artefakte hier öffentlich sind.

## Ablauf

1. macOS-Runner `macos-26`, Xcode fest auf 26.3 (`XCODE_APP` im Workflow).
2. Pipeline-Test: XcodeGen 2.46.0 (Download mit geprüfter SHA-256) erzeugt `pipeline-test/AtomUniversePipelineTest.xcodeproj`. Mit Export: `scripts/fetch-export.sh` lädt, prüft und entpackt das Archiv.
3. `scripts/build-unsigned-ipa.sh`: `xcodebuild archive` für „generic iOS device“ mit `CODE_SIGNING_ALLOWED=NO`, `CODE_SIGNING_REQUIRED=NO` und leerem `CODE_SIGN_IDENTITY`, danach `Payload/<App>.app` als `.ipa` gepackt.
4. Upload als Artifact, mit `release_tag` danach an den Release-Entwurf.

Wie die unsignierte `.ipa` aufs iPad oder iPhone kommt, steht im Spiel-Repo unter `unity/docs/build/ios-installieren.md`.
