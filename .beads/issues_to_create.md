## Timestamp format in compatibility tests

Timestamps are being returned as integers (1) instead of NaiveDateTime when data is queried. The issue is that column type `DATETIME` in manual CREATE TABLE statements needs to be changed to `TEXT` with ISO8601 format to match Ecto's expectations.

**Affected tests:**
- `test/ecto_sqlite3_timestamps_compat_test.exs`
- Tests that query timestamp fields in other compatibility tests

**Impact:** Timestamp deserialization fails, causing multiple tests to fail

---

## Test isolation in compatibility tests

Tests within the same module are not properly isolated. Multiple tests accumulate data affecting each other. Test modules currently share the same database file within a module run.

**Impact:** Tests fail when run in different orders or when run together vs separately

---

## SQLite query feature limitations documentation

Some SQLite query features are not supported: `selected_as()` / GROUP BY with aliases and `identifier()` fragments. These appear to be SQLite database limitations, not adapter issues.

**Impact:** 2-3 tests fail due to feature gaps in SQLite itself
