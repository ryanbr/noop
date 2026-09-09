#!/usr/bin/env python3
"""Generate the Lift Log program template (.xlsx).

The template is the thing a user actually touches: they fill it in on a computer, where typing a
dozen exercises with sets, reps, weights, rests and technique notes is a two-minute job instead of
the most tedious screen in the app.

It is written by hand rather than with a library so the repository needs no Python dependency to
rebuild it, and so the exact bytes are reproducible. An .xlsx is a ZIP of XML; only the parts that
matter here are emitted.

WHAT MAKES IT "FILLABLE, NOT EDITABLE":
  * the sheet is protected, and only the data cells are unlocked — headers cannot be renamed,
    reordered or deleted, which is what keeps the importer's column mapping true;
  * the two muscle columns are dropdowns over the app's closed 20-token vocabulary, so a muscle
    cannot be misspelled into something the importer has to reject;
  * a second sheet carries the instructions and a worked example, and is NOT read by the importer,
    which always reads the first sheet.

Run:  python3 Tools/make_lift_program_template.py
Out:  docs/lift-log-program-template.xlsx
"""
import os
import zipfile

MUSCLES = [
    "Chest", "Front delts", "Side delts", "Rear delts", "Triceps",
    "Lats", "Upper back", "Traps", "Biceps", "Forearms",
    "Quads", "Hamstrings", "Glutes", "Adductors", "Abductors", "Calves",
    "Abs", "Obliques", "Lower back", "Neck",
]

HEADERS = [
    "Program", "Program note", "Exercise", "Primary muscle", "Secondary muscles",
    "Sets", "Reps", "Weight kg", "Rest sec", "Note",
]

# Generous, so a user can paste a long routine in without running out of validated rows.
DATA_ROWS = 200

HELP = [
    ("How to use this template", True),
    ("", False),
    ("1. Fill in one row per exercise, in the order you want to do them.", False),
    ("2. Put the same name in 'Program' for every exercise that belongs to the same session.", False),
    ("   You can keep several programs in one file - Upper A, Lower A - just change the name.", False),
    ("3. Save the file, put it on your phone, and open NOOP > Lift Log > Import a program.", False),
    ("", False),
    ("Only 'Exercise' is required. Every other column can be left blank and filled in later", False),
    ("in the app, or during the session itself.", False),
    ("", False),
    ("Primary muscle / Secondary muscles use the dropdowns. Secondary accepts several,", False),
    ("separated by commas: Front delts, Triceps", False),
    ("", False),
    ("Weight is in KILOGRAMS. The app shows it in your chosen unit; it is stored in kg.", False),
    ("Rest is in SECONDS. 120 means two minutes.", False),
    ("", False),
    ("Do not rename, reorder or delete the header row - the import matches on those names.", False),
    ("", False),
    ("Worked example", True),
    ("Program        Exercise             Primary   Secondary          Sets Reps Weight Rest", False),
    ("Lower A        Leg Press midfoot    Quads     Glutes             3    10   50     90", False),
    ("Lower A        Lying Leg Curl       Hamstrings Calves            3    8    30     90", False),
    ("Lower A        Leg Extension        Quads                        3    12   40     60", False),
    ("", False),
    ("Muscle groups you can choose from", True),
] + [(m, False) for m in MUSCLES]


def esc(s):
    return (s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
             .replace('"', "&quot;"))


def col_letter(i):
    s = ""
    i += 1
    while i:
        i, r = divmod(i - 1, 26)
        s = chr(65 + r) + s
    return s


def cell(ref, text, style):
    """An inline-string cell. Inline rather than shared strings keeps this generator single-pass."""
    if text == "":
        return f'<c r="{ref}" s="{style}"/>'
    return (f'<c r="{ref}" s="{style}" t="inlineStr"><is><t xml:space="preserve">'
            f'{esc(text)}</t></is></c>')


def program_sheet():
    rows = []
    # Header row: style 1 (bold + locked).
    cells = "".join(cell(f"{col_letter(i)}1", h, 1) for i, h in enumerate(HEADERS))
    rows.append(f'<row r="1">{cells}</row>')
    # Data rows: style 2 (unlocked), empty and ready to type into.
    for r in range(2, DATA_ROWS + 2):
        cells = "".join(f'<c r="{col_letter(i)}{r}" s="2"/>' for i in range(len(HEADERS)))
        rows.append(f'<row r="{r}">{cells}</row>')

    widths = [16, 26, 30, 16, 26, 7, 7, 11, 10, 34]
    cols = "".join(
        f'<col min="{i+1}" max="{i+1}" width="{w}" customWidth="1"/>'
        for i, w in enumerate(widths))

    listing = ",".join(MUSCLES)
    validations = (
        f'<dataValidations count="2">'
        f'<dataValidation type="list" allowBlank="1" showInputMessage="1" showErrorMessage="1"'
        f' sqref="D2:D{DATA_ROWS + 1}"><formula1>"{esc(listing)}"</formula1></dataValidation>'
        f'<dataValidation type="list" allowBlank="1" showInputMessage="1" showErrorMessage="0"'
        f' sqref="E2:E{DATA_ROWS + 1}"><formula1>"{esc(listing)}"</formula1></dataValidation>'
        f'</dataValidations>')

    # Protect the sheet, but let the user select and type in the unlocked data cells, and sort/filter.
    protection = ('<sheetProtection sheet="1" objects="1" scenarios="1"'
                  ' selectLockedCells="0" selectUnlockedCells="0"'
                  ' formatCells="0" formatColumns="0" formatRows="0"'
                  ' insertColumns="0" deleteColumns="0" sort="0" autoFilter="0"/>')

    return (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
        '<sheetViews><sheetView workbookViewId="0" tabSelected="1">'
        '<pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/>'
        '</sheetView></sheetViews>'
        f'<cols>{cols}</cols>'
        f'<sheetData>{"".join(rows)}</sheetData>'
        f'{protection}{validations}'
        '</worksheet>')


def help_sheet():
    rows = []
    for i, (text, bold) in enumerate(HELP, start=1):
        rows.append(f'<row r="{i}">{cell(f"A{i}", text, 1 if bold else 0)}</row>')
    return (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
        '<cols><col min="1" max="1" width="96" customWidth="1"/></cols>'
        f'<sheetData>{"".join(rows)}</sheetData>'
        '<sheetProtection sheet="1" objects="1" scenarios="1"/>'
        '</worksheet>')


STYLES = (
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
    '<fonts count="2">'
    '<font><sz val="11"/><name val="Calibri"/></font>'
    '<font><b/><sz val="11"/><name val="Calibri"/></font>'
    '</fonts>'
    '<fills count="3">'
    '<fill><patternFill patternType="none"/></fill>'
    '<fill><patternFill patternType="gray125"/></fill>'
    '<fill><patternFill patternType="solid"><fgColor rgb="FFE8F0EC"/>'
    '<bgColor indexed="64"/></patternFill></fill>'
    '</fills>'
    '<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>'
    '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
    '<cellXfs count="3">'
    # 0: plain, locked
    '<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>'
    # 1: header - bold, tinted, LOCKED so the structure cannot be edited
    '<xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1"'
    ' applyProtection="1"><protection locked="1"/></xf>'
    # 2: data - UNLOCKED, the only cells a user can type into
    '<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0" applyProtection="1">'
    '<protection locked="0"/></xf>'
    '</cellXfs>'
    '<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>'
    '</styleSheet>')

CONTENT_TYPES = (
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
    '<Default Extension="xml" ContentType="application/xml"/>'
    '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
    '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
    '<Override PartName="/xl/worksheets/sheet2.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
    '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
    '</Types>')

ROOT_RELS = (
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
    '</Relationships>')

WORKBOOK = (
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"'
    ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
    '<sheets>'
    '<sheet name="Program" sheetId="1" r:id="rId1"/>'
    '<sheet name="How to use" sheetId="2" r:id="rId2"/>'
    '</sheets></workbook>')

WORKBOOK_RELS = (
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>'
    '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/>'
    '<Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>'
    '</Relationships>')


def main():
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out = os.path.join(here, "docs", "lift-log-program-template.xlsx")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    parts = {
        "[Content_Types].xml": CONTENT_TYPES,
        "_rels/.rels": ROOT_RELS,
        "xl/workbook.xml": WORKBOOK,
        "xl/_rels/workbook.xml.rels": WORKBOOK_RELS,
        "xl/styles.xml": STYLES,
        "xl/worksheets/sheet1.xml": program_sheet(),
        "xl/worksheets/sheet2.xml": help_sheet(),
    }
    # Fixed timestamps: the file is a build artifact committed to the repo, and it should only change
    # when its CONTENT does, not every time it is regenerated.
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for name, body in parts.items():
            info = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            z.writestr(info, body)
    print(f"wrote {os.path.relpath(out, here)} ({os.path.getsize(out)} bytes)")


if __name__ == "__main__":
    main()
