# Downloads Sorter

A Python script that automatically sorts files from your `~/Downloads` folder into organised subdirectories based on filename keywords and — more importantly — the **actual text content** of each file.

Built for Debian Linux, Polish and English documents, Python 3.11+.

---

## How it works

When you run the script it does the following:

1. Scans every supported file in `~/Downloads` (not subdirectories)
2. Extracts the full text content from each file
3. Checks that text against the keyword rules in `rules.toml`
4. Falls back to checking the filename if no content match is found
5. Shows you a **dry-run preview** of where each file would go
6. Asks for confirmation before moving anything

Content always beats filename — so a file called `scan001.pdf` that contains an Arc of Asia invoice will correctly go to `Work/ARC`, even though the filename gives no hint.

### Supported file types

`.pdf` `.docx` `.doc` `.txt` `.xlsx` `.xls` `.md` `.odt`

You can add more in `rules.toml` (see below).

---

## Files

```
sorter/
├── sort_downloads.sh   # Run this — installs deps, then calls the Python script
├── sort_downloads.py   # The actual logic
└── rules.toml          # Your rules — edit this to add keywords and categories
```

Keep all three files in the same directory.

---

## Daily use

```bash
cd ~/.local/bin/sorter
./sort_downloads.sh
```

That's it. The script will show a preview, then ask:

```
Proceed with moving files? [y/N]
```

Type `y` to move, or just press Enter to cancel without touching anything.

### Useful flags

```bash
# Skip the confirmation prompt and move immediately
./sort_downloads.sh --yes

# Preview rules without scanning any files
./sort_downloads.sh --list-rules

# Sort a different folder instead of ~/Downloads
./sort_downloads.sh --dir /path/to/folder

# Use a different rules file
./sort_downloads.sh --config /path/to/other-rules.toml
```

### Output folders

Subfolders are created automatically inside `~/Downloads` the first time a file routes there. Based on the default rules you will get:

```
~/Downloads/
├── Work/
│   ├── ARC/
│   └── LKIT/
├── AKW/
└── Other/
```

If two files would land on the same destination path, the script appends `_1`, `_2` etc. rather than overwriting.

---

## How to extend it

Everything is controlled by `rules.toml`. You never need to touch the Python script to add new keywords or categories.

### Adding a keyword to an existing category

Open `rules.toml` and add a line to the relevant list:

```toml
[[categories]]
name = "Work/ARC"
content_keywords = [
    "arc of asia",
    "9571181577",
    "your new keyword here",   # ← add here
]
filename_keywords = [
    "arc",
    "new_filename_hint",       # ← or here
]
```

`content_keywords` are matched against the full extracted text of the file.
`filename_keywords` are matched against the filename only, and only used if no content match was found first.

Both are case-insensitive and partial — `"kasprzak"` will match `"Łukasz Kasprzak International Trade"`.

### Adding a new category

Append a new `[[categories]]` block anywhere in the list:

```toml
[[categories]]
name        = "Finance/Banking"
description = "Bank statements and account exports"
content_keywords = [
    "revolut",
    "account statement",
    "wyciąg bankowy",
    "mbank",
]
filename_keywords = [
    "revolut",
    "statement",
    "wyciag",
]
```

The folder path (`Finance/Banking`, `Personal/Tax`, or any depth you like) will be created automatically inside `~/Downloads`.

**Order matters** — categories are checked top to bottom and the first match wins. Put more specific categories above broader ones.

### Adding a new file extension

Add it to `supported_extensions` in `rules.toml`:

```toml
supported_extensions = [
    ".pdf",
    ".docx",
    ".txt",
    # ... existing entries ...
    ".log",    # plain text — works out of the box
    ".csv",    # plain text — works out of the box
]
```

Plain text formats (`.log`, `.csv`, `.json`, `.xml`, `.ini`, `.conf`) work immediately with no code changes. Binary formats that need a dedicated parser (e.g. `.pptx`, `.ods`) would require a small addition to `sort_downloads.py`.

### Changing the catch-all folder

Files that match no category go here:

```toml
fallback_folder = "Other"
```

Change it to anything you like, e.g. `"Unsorted"` or `"Inbox"`.

---

## Keyword tips

- **NIP / REGON / KRS numbers** are the most reliable content keywords — they are unique per company and appear on every invoice and document
- Put **broad keywords** (like `"invoice"`) lower in the list so they don't accidentally catch documents that should match a more specific category above
- If a bank statement matches the wrong category because a supplier's address appears as a payee, move that supplier's address out of `content_keywords` and rely on the NIP/REGON instead
- Polish characters work fine in both content and filename keywords (`ł`, `ó`, `ą`, `ś`, `ź`, etc.)
- Run `./sort_downloads.sh --list-rules` after editing to confirm your changes loaded correctly

---

## Dependencies

| Library | Purpose | Installed by |
|---|---|---|
| `pdfplumber` | Read text from PDF files | `sort_downloads.sh` automatically |
| `python-docx` | Read text from .docx/.doc files | `sort_downloads.sh` automatically |
| `openpyxl` | Read text from .xlsx/.xls files | `sort_downloads.sh` automatically |
| `odfpy` | Read text from .odt files | `sort_downloads.sh` automatically |
| `tomllib` | Parse rules.toml | Built into Python 3.11+ — nothing to install |

The bash wrapper (`sort_downloads.sh`) checks for and installs any missing libraries automatically on each run using `pip install --break-system-packages`.

**Python 3.11 or newer is required.** On Debian 12+ this is the default.

---

## Troubleshooting

**A file landed in the wrong folder**
Run `--list-rules` to check what keywords are loaded. The preview also shows the match reason in brackets, e.g. `[content: 'wiercany 60a']` — use this to identify which keyword caused the misroute and either remove it or move a more specific category above it in `rules.toml`.

**A file ended up in Other**
The script found no matching keyword in the file's content or filename. Open the file, find a unique phrase or number, and add it as a `content_keyword` to the appropriate category.

**PDF content is not being read**
Check that `pdfplumber` is installed (`pip show pdfplumber`). Some PDFs are image-only scans with no embedded text — these cannot be read without OCR, which is not currently supported.

**TOML syntax error on startup**
TOML is strict about quoting — all strings must be in double quotes. Numbers like NIP/REGON must also be quoted (`"9571181577"`, not `9571181577`) to be treated as text for matching.
