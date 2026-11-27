"""The decision queue file: parse and change the rows of its 2 tables, and keep every other line byte for byte.

Main table: the first table whose header has a "default" column (id, opened, item, scope or "rows / scope",
default if no answer, owner, status). Closed table: the first table after "## Closed" (id, ref, opened, item,
status). A cell may hold an escaped pipe (\\|). Only the row that a command changes is written again.
Standard library only; no CLI (watchdog.py is the one entry point). Not named queue.py: that is a standard module.
"""
import datetime
import re

CLOSED_AFTER_DAYS = 7
DEFAULT_AFTER_HOURS = 2
_SPLIT = re.compile(r"(?<!\\)\|")
_DONE = re.compile(r"^(decided|default taken) (\d{4}-\d{2}-\d{2})")


class QueueError(RuntimeError):
    def __init__(self, msg, code=1):
        super().__init__(msg)
        self.code = code


def _cells(line):
    inner = line.strip()
    inner = inner[1:] if inner.startswith("|") else inner
    inner = inner[:-1] if inner.endswith("|") and not inner.endswith("\\|") else inner
    return [c.strip().replace("\\|", "|") for c in _SPLIT.split(inner)]


def _line(cells):
    return "| " + " | ".join(str(c).replace("|", "\\|") for c in cells) + " |"


def _key(header):
    h = header.lower()
    for k in ("default", "scope", "opened", "owner", "status", "item", "ref", "id"):
        if k in h:
            return k
    return h


def parse_time(text):
    """A UTC datetime from "YYYY-MM-DD HH:MM UTC", "YYYY-MM-DD" (midnight) or ISO; None when no date."""
    m = re.match(r"(\d{4}-\d{2}-\d{2})(?:[ T](\d{2}):(\d{2}))?", text or "")
    if not m:
        return None
    d = datetime.datetime.strptime(m.group(1), "%Y-%m-%d").replace(tzinfo=datetime.timezone.utc)
    return d.replace(hour=int(m.group(2)), minute=int(m.group(3))) if m.group(2) else d


class Queue:
    def __init__(self, text):
        self.lines = text.splitlines()
        self.trailing_newline = text.endswith("\n")
        self.main = self._table(lambda keys: "default" in keys)
        closed_at = next((i for i, x in enumerate(self.lines) if x.strip().lower() == "## closed"), None)
        self.closed_table = self._table(lambda keys: "ref" in keys, start=closed_at) if closed_at is not None else None

    def text(self):
        return "\n".join(self.lines) + ("\n" if self.trailing_newline else "")

    # ---- tables
    def _table(self, want, start=0):
        """(header line no, keys, last row line no) of the first table from start whose keys satisfy want."""
        for i in range(start or 0, len(self.lines) - 1):
            if self.lines[i].startswith("|") and re.match(r"^\|\s*:?-{3}", self.lines[i + 1]):
                keys = [_key(c) for c in _cells(self.lines[i])]
                if not want(keys):
                    continue
                end = i + 1
                while end + 1 < len(self.lines) and self.lines[end + 1].startswith("|"):
                    end += 1
                return {"header": i, "keys": keys, "last": end}
        return None

    def _rows(self, table):
        if not table:
            return []
        out = []
        for n in range(table["header"] + 2, table["last"] + 1):
            cells = _cells(self.lines[n])
            row = dict(zip(table["keys"], cells + [""] * (len(table["keys"]) - len(cells))))
            row["_line"] = n
            out.append(row)
        return out

    def rows(self):
        if not self.main:
            raise QueueError("the queue file has no table with a 'default if no answer' column")
        return self._rows(self.main)

    def closed(self):
        return self._rows(self.closed_table)

    def row(self, rid):
        for r in self.rows():
            if r.get("id") == rid:
                return r
        raise QueueError(f"no row {rid} in the queue", 1)

    # ---- changes
    def _reindex(self):
        self.__init__(self.text())

    def add(self, values):
        self.rows()  # raises when the file has no main table
        keys = self.main["keys"]
        self.lines.insert(self.main["last"] + 1, _line([values.get(k, "") for k in keys]))
        self._reindex()

    def set(self, rid, key, value):
        r = self.row(rid)
        keys = self.main["keys"]
        cells = [r.get(k, "") for k in keys]
        cells[keys.index(key)] = value
        self.lines[r["_line"]] = _line(cells)
        self._reindex()

    def close(self, now, days=CLOSED_AFTER_DAYS):
        """Move the rows decided or defaulted more than `days` ago to the Closed table. Returns the moved D-ids."""
        if not self.closed_table:
            raise QueueError("the queue file has no '## Closed' table")
        old = []
        for r in self.rows():
            m = _DONE.match(r.get("status", ""))
            if m and (now - parse_time(m.group(2))).days > days:
                old.append(r)
        if not old:
            return []
        cnums = [int(x) for c in self.closed() for x in re.findall(r"^C(\d+)$", c.get("id", ""))]
        nxt = max(cnums, default=0) + 1
        ckeys = self.closed_table["keys"]
        new_lines = []
        for r in old:
            vals = {"id": f"C{nxt:02d}", "ref": r["id"], "opened": r.get("opened", ""), "item": r.get("item", ""),
                    "status": r.get("status", "")}
            new_lines.append(_line([vals.get(k, "") for k in ckeys]))
            nxt += 1
        at = self.closed_table["last"] + 1
        self.lines[at:at] = new_lines
        for r in sorted(old, key=lambda r: r["_line"], reverse=True):
            del self.lines[r["_line"]]
        self._reindex()
        return [r["id"] for r in old]


def age_hours(row, now):
    t = parse_time(row.get("opened", ""))
    return None if t is None else (now - t).total_seconds() / 3600


def default_refusal(row, now, hours=DEFAULT_AFTER_HOURS):
    """None when the default may be taken now, else the reason."""
    if row.get("status") != "open":
        return f"{row['id']} is not open ({row.get('status')})"
    d = row.get("default", "").strip()
    if not d or d.lower().startswith("none"):
        return f"{row['id']} has no default ({d or 'empty'}): it waits for the owner"
    age = age_hours(row, now)
    if age is None or age < hours:
        return f"{row['id']} is younger than {hours} h ({'no time' if age is None else f'{age:.1f} h'})"
    return None
