# Mer regression suite

```
./Scripts/regression.sh [--scratch DIR] [--keep] [--mer PATH] [-k substr] [--list] [-j N] [-v]
```
- Builds the CLI itself (`swift build --product mer --scratch-path /tmp/mer-build-regression`), unless `--mer <binary>`.
- Generates every fixture from scratch (PNG bytes, `say` audio, AVAssetWriter mp4, md/csv/srt/svg/docx/xlsx ...) under
  `--scratch` (default `/tmp/mer-regression`); the compiled Swift helper is cached there in `helpers/`. `--keep` leaves
  the run folder (fixtures + every output) for inspection.
- Verifies real output (magic bytes, pixels, PDF text via PDFKit, zip/XML/EPUB/DOCX structure, durations, ...), plus
  negative tests that must fail with exit 1 and a readable message. Prints PASS/FAIL/SKIP + timing, a summary line, exits 1 on any FAIL.
- `--list` prints check names; `-k` filters (case-insensitive substring, repeatable); `-j` = parallel checks (default 4).
- Optional engines (ffmpeg, pandoc, qpdf, ImageMagick, LibreOffice) SKIP with "SKIPPED (engine not installed)".
- Needs: macOS, Xcode CLT (`swift`, `swiftc`), python3 (stdlib only). No network.
- The CLI ranks actions by usage (`defaults` domain `mer`); the suite resets that counter for the run and restores it afterwards.

## Adding a check (Scripts/regression.py)
Table-driven one-liners:
```python
conv("image.png>jpg", "photo.png", "jpg", v_magic(b"\xff\xd8\xff"), v_img(96, 64), v_px(10, 10, RED))   # mer convert
tool("pdf.rotate", "text2.pdf", "tool.pdf.rotate", v_pdf(pages=2), params=("k=v",), extra_fx=("other.pdf",))  # mer run <id>
```
Custom logic:
```python
@check("area.what it proves")
def _(t):                       # t.fx("name") copies a fixture into the check's own work dir
    out = t.ok("run", "tool.x", t.fx("photo.png"))[0]      # asserts exit 0 + existing outputs, returns paths
    t.fails("convert", t.fx("a.md"), "--to", "md", has=("no matching action",))   # asserts clean failure + message
    expect(cond, "message")     # raise Fail;  t.need_engine("ffmpeg") / t.need_action(f, ".webp") raise Skip
```
New fixture: `@fixture("name.ext") def _(S, path): ...` (write the file; use `S.fixture("other")`, `S.helper("cmd", ...)`
for the Swift helper whose commands live in `HELPER_SWIFT`). Verifiers are small `(t, outs)` callables (`v_*`).
Mark a known product bug `check(..., xfail="reason")` to keep the suite green but visible (XFAIL / XPASS).
