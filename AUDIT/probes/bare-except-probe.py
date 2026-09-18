"""Deliberate violation for the audit's tool-coverage proof: a bare except that
swallows a real failure. Ruff must reject it (E722, S110)."""


def read(path):
    try:
        with open(path, encoding="utf-8") as handle:
            return handle.read()
    except:
        pass
    return None
