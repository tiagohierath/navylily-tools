#!/usr/bin/env python3
"""
lessons.py, helper for record_lessons.sh.

Knows how to enumerate the Navy Lily wiki articles, work out which ones have
already been recorded, extract the exact article title, turn a title into a
filesystem-safe slug, and render an article to a clean, readable HTML page you
open in the browser while you narrate.

It writes NOTHING permanent except the temp HTML page it renders; all the
"has this been recorded?" state is derived from the files on disk (an audio wav
in AUDIO_DIR or a finished mp4 in OUTPUT_DIR), so there is no state file to
drift.

Subcommands (paths come from env: WIKI_DIR, AUDIO_DIR, OUTPUT_DIR):
  next [search]   Pick a lesson and print a TAB-separated line:
                      slug <TAB> title <TAB> md_path <TAB> html_path
                  With no search: a RANDOM not-yet-recorded lesson (so similar
                  articles aren't narrated back to back), minus any slugs in
                  $SKIP_SLUGS (space separated, the recorder's per-session skip
                  list).
                  With a search: the first lesson whose title/slug/filename
                  matches, recorded or not (used to re-record one on purpose).
                  Exit code 3 (and no output) when there is nothing to pick.
  list            Print every lesson as:  [x|_] <TAB> slug <TAB> title
  slug <title>    Print the slug for a title (utility).
"""
from __future__ import annotations

import hashlib
import html
import os
import re
import sys
import tempfile
import unicodedata
from pathlib import Path


def env_dir(name: str, default: Path) -> Path:
    v = os.environ.get(name)
    return Path(v) if v else default


HERE = Path(__file__).resolve().parent
WIKI_DIR = env_dir("WIKI_DIR", HERE.parent / "navylily-private" / "content" / "WIKI")
AUDIO_DIR = env_dir("AUDIO_DIR", HERE / "videos" / "audio")
OUTPUT_DIR = env_dir("OUTPUT_DIR", HERE / "videos" / "output")


def slugify(s: str) -> str:
    s = unicodedata.normalize("NFKD", s).encode("ascii", "ignore").decode()
    s = re.sub(r"[^a-zA-Z0-9]+", "_", s).strip("_").lower()
    return s or "lesson"


def article_title(md: Path) -> str:
    """The article's display title: its first '# ' heading, else the filename.
    Whitespace is collapsed so the recorder's TAB-separated output stays safe."""
    try:
        for line in md.read_text(encoding="utf-8").splitlines():
            m = re.match(r"^#\s+(.+?)\s*$", line)
            if m:
                return re.sub(r"\s+", " ", m.group(1)).strip()
    except OSError:
        pass
    return md.stem


class Lesson:
    def __init__(self, md: Path):
        self.md = md
        # Slug is derived from the FILENAME (unique across the wiki), so two
        # articles can never collide on their output name. The title we
        # show/publish is the nicer in-file heading.
        self.slug = slugify(md.stem)
        self.title = article_title(md)

    @property
    def recorded(self) -> bool:
        return (OUTPUT_DIR / f"{self.slug}.mp4").exists() or \
               (AUDIO_DIR / f"{self.slug}.wav").exists()


def all_lessons() -> list[Lesson]:
    if not WIKI_DIR.is_dir():
        sys.exit(f"WIKI_DIR does not exist: {WIKI_DIR}")
    lessons = [Lesson(p) for p in sorted(WIKI_DIR.glob("*.md"))]
    # Two filenames melting into one slug would make the second lesson look
    # recorded the moment the first is done. Refuse loudly instead.
    by_slug: dict[str, list[str]] = {}
    for L in lessons:
        by_slug.setdefault(L.slug, []).append(L.md.name)
    dups = {s: names for s, names in by_slug.items() if len(names) > 1}
    if dups:
        pairs = "; ".join(f"{s} <- {', '.join(n)}" for s, n in dups.items())
        sys.exit(f"slug collision, rename one file of each pair: {pairs}")
    return lessons


# ---------------------------------------------------------------------------
# Minimal, forgiving Markdown -> HTML, tuned for reading one article aloud.
# ---------------------------------------------------------------------------
def inline(text: str) -> str:
    text = html.escape(text)
    # Images are useless while narrating; links read as their text only.
    text = re.sub(r"!\[[^\]]*\]\([^)]*\)", "", text)
    text = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", text)
    text = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"(?<!\*)\*(?!\s)(.+?)(?<!\s)\*(?!\*)", r"<em>\1</em>", text)
    return text


def render_html(lesson: Lesson) -> str:
    raw = lesson.md.read_text(encoding="utf-8")
    lines = raw.splitlines()

    # The wiki convention: an optional category on line 1, then the '# Title'.
    category = ""
    body_start = 0
    for i, line in enumerate(lines):
        if re.match(r"^#\s+", line):
            body_start = i + 1
            break
        if line.strip() and not category:
            category = line.strip()

    blocks: list[str] = []
    buf: list[str] = []

    def flush():
        if buf:
            blocks.append("<p>" + inline(" ".join(buf)) + "</p>")
            buf.clear()

    list_items: list[str] = []

    def flush_list():
        if list_items:
            blocks.append("<ul>" + "".join(f"<li>{inline(x)}</li>"
                                            for x in list_items) + "</ul>")
            list_items.clear()

    for line in lines[body_start:]:
        s = line.strip()
        if not s:
            flush(); flush_list(); continue
        m = re.match(r"^(#{2,6})\s+(.+)$", s)
        if m:
            flush(); flush_list()
            lvl = min(len(m.group(1)), 6)
            blocks.append(f"<h{lvl}>{inline(m.group(2))}</h{lvl}>")
            continue
        mi = re.match(r"^[-*]\s+(.+)$", s)
        if mi:
            flush()
            list_items.append(mi.group(1))
            continue
        flush_list()
        buf.append(s)
    flush(); flush_list()

    # Minimal reading page: just the script (title + the whole article body),
    # clean serif typography sized for reading aloud. No category kicker, no
    # instructional bar — nothing but the words you narrate.
    body = "\n".join(blocks)
    return f"""<!doctype html>
<html lang="pt-BR"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{html.escape(lesson.title)}</title>
<style>
  :root {{ color-scheme: light dark; }}
  body {{ font-family: Georgia, "Times New Roman", serif; line-height: 1.75;
         max-width: 42rem; margin: 0 auto; padding: 3rem 1.5rem 5rem;
         font-size: 1.35rem; }}
  h1 {{ font-size: 2.3rem; line-height: 1.15; margin: 0 0 1.5rem; }}
  h2 {{ font-size: 1.6rem; margin: 2rem 0 .6rem; }}
  h3 {{ font-size: 1.3rem; margin: 1.6rem 0 .5rem; }}
  p {{ margin: 0 0 1.15rem; }}
  ul {{ margin: 0 0 1.15rem 1.2rem; }}
  li {{ margin: 0 0 .4rem; }}
</style></head>
<body>
  <h1>{html.escape(lesson.title)}</h1>
  {body}
</body></html>"""


def pick_next(search: str | None) -> Lesson | None:
    lessons = all_lessons()
    if search:
        q = search.lower()
        for L in lessons:
            if q in L.title.lower() or q in L.slug or q in L.md.stem.lower():
                return L
        return None
    # Un-recorded lessons, minus SKIP_SLUGS (the recorder's set of lessons
    # already recorded / declined / permanently skipped this session).
    skip = set(os.environ.get("SKIP_SLUGS", "").split())
    candidates = [L for L in lessons if not L.recorded and L.slug not in skip]
    # Stable scramble: order by a hash of the slug, so it is ONE fixed random
    # order you progress through (not re-rolled on every call). As lessons get
    # recorded/skipped they drop out; the rest keep their scrambled positions,
    # so you never narrate a run of near-identical articles back to back.
    candidates.sort(key=lambda L: hashlib.md5(L.slug.encode()).hexdigest())
    return candidates[0] if candidates else None


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__.strip())
        return 2
    cmd = argv[0]

    if cmd == "next":
        search = argv[1] if len(argv) > 1 else None
        L = pick_next(search)
        if L is None:
            return 3  # nothing to record
        fd, path = tempfile.mkstemp(prefix=f"lesson_{L.slug}_", suffix=".html")
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(render_html(L))
        print("\t".join([L.slug, L.title, str(L.md), path]))
        return 0

    if cmd == "list":
        lessons = all_lessons()
        done = sum(1 for L in lessons if L.recorded)
        for L in lessons:
            mark = "x" if L.recorded else "_"
            print(f"[{mark}]\t{L.slug}\t{L.title}")
        print(f"\n{done}/{len(lessons)} recorded", file=sys.stderr)
        return 0

    if cmd == "count":
        # For the recorder's progress bar: "<total>\t<recorded>". Note the
        # recorder ADDS its own just-committed takes on top of this, because a
        # take's on-disk marker (the wav) is written by a background job that may
        # not have run yet when this is queried.
        lessons = all_lessons()
        done = sum(1 for L in lessons if L.recorded)
        print(f"{len(lessons)}\t{done}")
        return 0

    if cmd == "slug":
        print(slugify(" ".join(argv[1:])))
        return 0

    sys.exit(f"unknown command: {cmd}")


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
