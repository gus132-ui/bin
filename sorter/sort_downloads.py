#!/usr/bin/env python3
"""
Downloads Folder Sorter
Rules are loaded from rules.toml — edit that file to add keywords/categories.
Content match takes priority over filename match.
Requires Python 3.11+ (uses built-in tomllib).
"""

import sys
import shutil
import tomllib
import argparse
from pathlib import Path

# ── Optional deps (graceful fallback) ────────────────────────────────────────
try:
    import pdfplumber
    HAS_PDF = True
except ImportError:
    HAS_PDF = False

try:
    from docx import Document
    HAS_DOCX = True
except ImportError:
    HAS_DOCX = False

try:
    import openpyxl
    HAS_XLSX = True
except ImportError:
    HAS_XLSX = False

try:
    from odf import teletype
    from odf.opendocument import load as odf_load
    HAS_ODT = True
except ImportError:
    HAS_ODT = False

# ── Config loading ────────────────────────────────────────────────────────────

def load_config(config_path: Path) -> dict:
    if not config_path.exists():
        print(f"Error: Config file not found: {config_path}")
        print("Make sure rules.toml is in the same folder as this script.")
        sys.exit(1)
    with open(config_path, "rb") as f:
        config = tomllib.load(f)
    return config

def validate_config(config: dict):
    if "categories" not in config or not config["categories"]:
        print("Error: 'categories' is missing or empty in rules.toml")
        sys.exit(1)
    for cat in config["categories"]:
        if "name" not in cat:
            print("Error: A category in rules.toml is missing a 'name' field.")
            sys.exit(1)

# ── Text extraction ───────────────────────────────────────────────────────────

def extract_text_pdf(path: Path) -> str:
    if not HAS_PDF:
        return ""
    try:
        with pdfplumber.open(path) as pdf:
            return "\n".join(page.extract_text() or "" for page in pdf.pages)
    except Exception:
        return ""

def extract_text_docx(path: Path) -> str:
    if not HAS_DOCX:
        return ""
    try:
        doc = Document(path)
        return "\n".join(p.text for p in doc.paragraphs)
    except Exception:
        return ""

def extract_text_xlsx(path: Path) -> str:
    if not HAS_XLSX:
        return ""
    try:
        wb = openpyxl.load_workbook(path, read_only=True, data_only=True)
        parts = []
        for ws in wb.worksheets:
            for row in ws.iter_rows(values_only=True):
                parts.append(" ".join(str(c) for c in row if c is not None))
        return "\n".join(parts)
    except Exception:
        return ""

def extract_text_odt(path: Path) -> str:
    if not HAS_ODT:
        return ""
    try:
        doc = odf_load(path)
        return teletype.extractText(doc.text)
    except Exception:
        return ""

def extract_text_plain(path: Path) -> str:
    for enc in ("utf-8", "utf-16", "latin-1"):
        try:
            return path.read_text(encoding=enc)
        except Exception:
            continue
    return ""

def extract_text(path: Path) -> str:
    ext = path.suffix.lower()
    if ext == ".pdf":
        return extract_text_pdf(path)
    elif ext in (".docx", ".doc"):
        return extract_text_docx(path)
    elif ext in (".xlsx", ".xls"):
        return extract_text_xlsx(path)
    elif ext == ".odt":
        return extract_text_odt(path)
    elif ext in (".txt", ".md"):
        return extract_text_plain(path)
    return ""

# ── Classification ────────────────────────────────────────────────────────────

def classify(text: str, filename: str, categories: list, fallback: str) -> tuple:
    """
    Returns (destination_folder, match_reason).
    Content keywords checked first, then filename keywords.
    Categories are evaluated in order — first match wins.
    """
    text_low = text.lower()
    name_low = filename.lower()

    for cat in categories:
        for kw in cat.get("content_keywords", []):
            if str(kw).lower() in text_low:
                return cat["name"], f"content: '{kw}'"

    for cat in categories:
        for kw in cat.get("filename_keywords", []):
            if str(kw).lower() in name_low:
                return cat["name"], f"filename: '{kw}'"

    return fallback, "no match"

# ── Core ──────────────────────────────────────────────────────────────────────

def collect_files(downloads: Path, extensions: set) -> list:
    files = []
    for entry in downloads.iterdir():
        if entry.is_file() and entry.suffix.lower() in extensions:
            files.append(entry)
    return sorted(files)

def plan_moves(files: list, downloads: Path, config: dict) -> list:
    categories = config["categories"]
    fallback   = config.get("fallback_folder", "Other")
    moves = []
    for f in files:
        print(f"  Scanning: {f.name} ...", end=" ", flush=True)
        text = extract_text(f)
        dest_folder, reason = classify(text, f.name, categories, fallback)
        dest_path = downloads / dest_folder / f.name
        moves.append((f, dest_path, reason))
        print(f"-> {dest_folder}/  ({reason})")
    return moves

def print_plan(moves: list, downloads: Path):
    print("\n" + "=" * 70)
    print("  DRY-RUN PREVIEW")
    print("=" * 70)
    col_w = max(len(src.name) for src, _, _ in moves) + 2
    for src, dst, reason in moves:
        rel = dst.relative_to(downloads)
        print(f"  {src.name:<{col_w}} ->  {rel}   [{reason}]")
    print("=" * 70)

def execute_moves(moves: list, downloads: Path) -> list:
    errors = []
    for src, dst, _ in moves:
        try:
            dst.parent.mkdir(parents=True, exist_ok=True)
            final_dst = dst
            counter = 1
            while final_dst.exists():
                final_dst = dst.with_stem(f"{dst.stem}_{counter}")
                counter += 1
            shutil.move(str(src), str(final_dst))
            print(f"  OK   {src.name}  ->  {final_dst.relative_to(downloads)}")
        except Exception as e:
            errors.append((src, e))
            print(f"  ERR  {src.name}  ->  {e}")
    return errors

def check_deps() -> list:
    missing = []
    if not HAS_PDF:
        missing.append("pdfplumber")
    if not HAS_DOCX:
        missing.append("python-docx")
    if not HAS_XLSX:
        missing.append("openpyxl")
    if not HAS_ODT:
        missing.append("odfpy")
    return missing

# ── Entry point ───────────────────────────────────────────────────────────────

def main():
    if sys.version_info < (3, 11):
        print("Error: Python 3.11 or newer is required (for built-in tomllib).")
        print(f"       You have Python {sys.version}")
        sys.exit(1)

    parser = argparse.ArgumentParser(
        description="Sort ~/downloads using rules defined in rules.toml"
    )
    parser.add_argument(
        "--dir",
        default=str(Path.home() / "downloads"),
        help="Path to Downloads folder (default: ~/Downloads)",
    )
    parser.add_argument(
        "--config",
        default=None,
        help="Path to rules.toml (default: same folder as this script)",
    )
    parser.add_argument(
        "--yes", "-y",
        action="store_true",
        help="Skip confirmation prompt and move immediately",
    )
    parser.add_argument(
        "--list-rules",
        action="store_true",
        help="Print loaded categories and keywords, then exit",
    )
    args = parser.parse_args()

    script_dir  = Path(__file__).parent
    config_path = Path(args.config) if args.config else script_dir / "rules.toml"
    config      = load_config(config_path)
    validate_config(config)

    extensions = set(config.get("supported_extensions", [
        ".pdf", ".docx", ".doc", ".txt", ".xlsx", ".xls", ".md", ".odt"
        ".sh", ".py", ".js", ".ts", ".html", ".css", ".json", ".yaml", ".toml"
    ]))

    if args.list_rules:
        print(f"\nConfig: {config_path}\n")
        for cat in config["categories"]:
            print(f"  [folder] {cat['name']}")
            if cat.get("description"):
                print(f"           {cat['description']}")
            if cat.get("content_keywords"):
                kws = ", ".join(str(k) for k in cat["content_keywords"])
                print(f"           content : {kws}")
            if cat.get("filename_keywords"):
                kws = ", ".join(str(k) for k in cat["filename_keywords"])
                print(f"           filename: {kws}")
            print()
        print(f"  [folder] {config.get('fallback_folder', 'Other')}  (catch-all)\n")
        return

    downloads = Path(args.dir).expanduser().resolve()
    if not downloads.is_dir():
        print(f"Error: '{downloads}' is not a directory.")
        sys.exit(1)

    missing = check_deps()
    if missing:
        print("Warning: some content-extraction libraries are missing.")
        print("         Install them for full content scanning:")
        for m in missing:
            print(f"           pip install {m}")
        print()

    print(f"Scanning: {downloads}")
    print(f"Rules:    {config_path}\n")

    files = collect_files(downloads, extensions)
    if not files:
        print("No supported files found.")
        sys.exit(0)

    print(f"Found {len(files)} file(s). Classifying...\n")
    moves = plan_moves(files, downloads, config)

    print_plan(moves, downloads)

    if not args.yes:
        answer = input("\nProceed with moving files? [y/N] ").strip().lower()
        if answer != "y":
            print("Aborted. No files were moved.")
            sys.exit(0)

    print("\nMoving files...\n")
    errors = execute_moves(moves, downloads)

    print()
    if errors:
        print(f"Done with {len(errors)} error(s).")
    else:
        print("All files moved successfully.")

if __name__ == "__main__":
    main()
