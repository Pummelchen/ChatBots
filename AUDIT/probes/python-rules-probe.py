"""Deliberate violations for the audit's tool-coverage proof (AUDIT-0030).

Ruff must reject every one of these under the committed `ruff.toml`.
"""

import datetime

import pytest


def mutable_default(x=[]):
    return x


def assert_for_validation(value):
    assert value


def naive_time():
    return datetime.datetime.now()


def unencoded_read(path):
    with open(path) as handle:
        return handle.read()


def test_raises_too_broadly():
    with pytest.raises(ValueError):
        int("x")
