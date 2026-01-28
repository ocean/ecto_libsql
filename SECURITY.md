# Security

## Vulnerability Mitigation

### CVE-2025-47736: libsql-sqlite3-parser UTF-8 Crash

**Status:** MITIGATED
**Severity:** Low
**Affected Component:** `libsql-sqlite3-parser` ≤ 0.13.0 (transitive dependency via `libsql`)

#### Vulnerability Description

The `libsql-sqlite3-parser` crate through version 0.13.0 can crash when processing invalid UTF-8 input in SQL queries. This vulnerability is documented in [CVE-2025-47736](https://advisories.gitlab.com/pkg/cargo/libsql-sqlite3-parser/CVE-2025-47736/).

#### Our Mitigation Strategy

**ecto_libsql is NOT vulnerable** to this CVE due to multiple layers of defence:

##### 1. **Type System Protection (Primary Defence)**
- All SQL strings in our Rust NIF code use Rust's `&str` type
- Rust's type system guarantees that `&str` contains valid UTF-8
- Any attempt to create invalid UTF-8 in Rust would fail at compile time

##### 2. **Rustler Validation (Secondary Defence)**
- Rustler (our NIF bridge) validates UTF-8 when converting Elixir binaries to Rust strings
- Invalid UTF-8 from Elixir would cause NIF conversion errors before reaching our code
- These errors are caught and returned to Elixir as error tuples

#### Why This Vulnerability Doesn't Affect Us

In our case, the vulnerability cannot be triggered because:

1. **Elixir strings are UTF-8:** Elixir enforces UTF-8 for all string literals and string operations
2. **Rustler enforces UTF-8:** Converting from Elixir to Rust `&str` validates UTF-8
3. **Type safety:** Rust's `&str` cannot contain invalid UTF-8 by definition

#### Upstream Fix Status

The vulnerability is fixed in commit `14f422a` of `libsql-sqlite3-parser`, but this fix has not been released to crates.io yet. Once a new version is published, we will:

1. Update our `libsql` dependency (which will pull in the fixed parser)
2. Update this document with the new version information

#### Testing

Our test suite includes UTF-8 validation coverage:
- All named parameter tests exercise the validation code paths
- Invalid UTF-8 would be caught by Rustler before reaching our code

#### Reporting Security Issues

If you discover a security vulnerability in ecto_libsql, please email the maintainers directly rather than opening a public issue.

## Security Best Practices

When using ecto_libsql in your applications:

1. **Use parameterised queries:** Always use Ecto's parameter binding (`?` or `:param`) instead of string interpolation
2. **Validate input:** Validate user input at application boundaries before passing to database queries
3. **Keep dependencies updated:** Regularly update ecto_libsql and Ecto to get security fixes
4. **Use encryption:** Enable encryption for sensitive data using the `:encryption_key` option
5. **Secure credentials:** Store Turso auth tokens in environment variables, not in source code

## Dependency Security

We use the following tools to monitor dependency security:

- **Dependabot:** Automated vulnerability scanning on GitHub
- **cargo audit:** Rust dependency vulnerability checking
- **mix audit:** Elixir dependency vulnerability checking

Run security audits locally:

```bash
# Rust dependencies
cd native/ecto_libsql && cargo audit

# Elixir dependencies (requires mix_audit)
mix deps.audit
```

## Changelog

- **2026-01-07:** Added explicit UTF-8 validation as defence against CVE-2025-47736
- **2025-12-30:** v0.5.0 - Eliminated all `.unwrap()` calls in production code (CVE-prevention)
