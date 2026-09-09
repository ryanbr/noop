# Importing a Lift Log program from a spreadsheet

Filling in a program on a phone — a dozen exercises, each with a muscle group, sets, reps, a weight,
a rest period and a technique note — is the most tedious part of the Lift Log. This lets you do it
on a computer instead, in a couple of minutes, and bring the file across.

## The template

**[`lift-log-program-template.xlsx`](lift-log-program-template.xlsx)** — download it, open it in
Excel, Numbers, Google Sheets or LibreOffice, and fill in one row per exercise.

The sheet is protected: the header row cannot be renamed, reordered or deleted, because the import
matches on those names. Only the data cells accept typing. The two muscle columns are dropdowns over
the app's closed muscle vocabulary, so a muscle group cannot be misspelled into something the import
has to reject. A second sheet carries the instructions and a worked example; it is ignored on import.

## The columns

| Column | Required | Notes |
|---|---|---|
| `Program` | no | The session name — "Upper A". Every row with the same name becomes one program, so several programs can live in one file. Defaults to "Imported program". |
| `Program note` | no | Taken from whichever row of that program carries it. |
| `Exercise` | **yes** | Whatever you call the movement. NOOP ships no exercise catalogue — your name is the name. |
| `Primary muscle` | no | Dropdown. |
| `Secondary muscles` | no | Dropdown, and several can be typed separated by commas: `Front delts, Triceps`. |
| `Sets` | no | Working sets. |
| `Reps` | no | One rep count, not a range. |
| `Weight kg` | no | **Always kilograms.** The app displays it in your chosen unit; it is stored in kg. |
| `Rest sec` | no | **Seconds.** `120` is two minutes. |
| `Note` | no | Your technique cue, verbatim. |

Only `Exercise` is required. Anything left blank can be filled in later in the app, or during the
session itself — a blank stays blank rather than becoming a zero.

## Importing

**Lift Log → Import → Choose a file.** Nothing is written until you have seen what it will create:
the programs, their exercises and targets, and anything that needs checking. Then press Import.

Exercises are remembered with the muscle groups you gave them, so the picker offers them next time
and the per-muscle rollup resolves the same name the same way.

## Formats and quirks

- **`.xlsx`** (the template) and **`.csv`** both work. Everything is read from the FIRST sheet.
- **CSV delimiters** are sniffed — `,`, `;` or tab. Excel in most of Europe writes `;`, which is fine.
- **Decimal commas** are understood: `40,5` and `40.5` both mean 40.5.
- **Unit suffixes** are tolerated: `40,5 kg` reads as 40.5.
- **Blank rows** are skipped, wherever they are.
- **An unrecognised muscle** warns and leaves that line unclassified — it never guesses, and never
  throws the row away. The muscle vocabulary is a stored-data contract, so deciding that "Shoulders"
  means front delts would put sets in a bucket you did not choose.
- The template's dropdowns are in **English**, since the file is authored on a computer. The import
  also accepts the stored tokens (`frontDelts`), and is insensitive to case, spaces and hyphens.

## Rebuilding the template

`python3 Tools/make_lift_program_template.py` — no third-party Python packages needed. The file is a
committed build artifact; regenerate it if the columns or the muscle vocabulary ever change, and note
that `LiftProgramSheetImporterTests` parses the shipped template and will fail if a column goes
missing.
