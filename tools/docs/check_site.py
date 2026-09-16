"""Check the static site's local links and its canonical repository doc targets."""

from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urlsplit
import re
import sys


ROOT = Path(__file__).resolve().parents[2]
SITE = ROOT / "website"


class Page(HTMLParser):
    def __init__(self, body):
        super().__init__(convert_charrefs=True)
        self.ids = set()
        self.duplicates = []
        self.links = []
        self.tags = []
        self.title = False
        self.in_title = False
        self.feed(body)
        self.close()

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        self.tags.append(tag)
        self.in_title = tag == "title" or self.in_title
        if "id" in attrs:
            value = attrs["id"]
            if value in self.ids:
                self.duplicates.append(value)
            self.ids.add(value)
        for key in ("href", "src"):
            if key in attrs:
                self.links.append(attrs[key])

    def handle_endtag(self, tag):
        if tag == "title":
            self.in_title = False

    def handle_data(self, value):
        if self.in_title and value.strip():
            self.title = True


def main():
    errors = []
    pages = sorted(SITE.glob("*.html"))
    if not pages:
        errors.append("No website HTML pages found")
    checked = 0
    for path in pages:
        page = Page(path.read_text())
        if page.duplicates:
            errors.append(f"{path.name}: duplicate IDs {page.duplicates}")
        if not page.title or page.tags.count("h1") != 1 or page.tags.count("main") != 1:
            errors.append(f"{path.name}: needs a title, one h1, and one main landmark")
        for raw in page.links:
            if not raw:
                errors.append(f"{path.name}: empty link")
                continue
            url = urlsplit(raw)
            if url.scheme or url.netloc:
                if url.netloc != "github.com" or not url.path.startswith("/bharathvbcr/MarkDev/blob/main/"):
                    continue
                target = ROOT / unquote(url.path.removeprefix("/bharathvbcr/MarkDev/blob/main/"))
            else:
                target = path.parent / unquote(url.path) if url.path else path
            target = target.resolve()
            checked += 1
            if not target.is_relative_to(ROOT) or not target.is_file():
                errors.append(f"{path.name}: missing or out-of-repository target {raw}")
                continue
            if url.fragment:
                fragment = unquote(url.fragment)
                if target.suffix == ".html":
                    ids = Page(target.read_text()).ids
                elif target.suffix == ".md":
                    # Current linked Markdown headings are plain text and unique.
                    headings = re.findall(r"^#{1,6} +(.+)$", target.read_text(), re.M)
                    ids = {re.sub(r"[^\w\- ]", "", heading.lower()).replace(" ", "-") for heading in headings}
                else:
                    errors.append(f"{path.name}: cannot verify fragment in {raw}")
                    continue
                if fragment not in ids:
                    errors.append(f"{path.name}: missing fragment {raw}")
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print(f"Website: {len(pages)} page(s), {checked} local/repository targets checked; passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
