# Missing Test Coverage Issues - Created from TEST_AUDIT_REPORT.md

This document lists all Beads issues created based on recommendations in TEST_AUDIT_REPORT.md for missing test coverage and improvements.

## 📋 Summary

- **Total issues created**: 9
- **Medium priority (P2)**: 6 issues
- **Low priority (P3)**: 3 issues
- **Total estimated effort**: ~12-14 days across all tasks

## 🔴 P2 - Medium Priority (Should Do Soon)

### 1. **el-doo**: Test cursor streaming with large result sets
- **Type**: task
- **Effort**: 2-3 hours
- **Status**: open
- **File**: test/cursor_streaming_test.exs (new)
- **Scenarios**: Memory usage, batch fetching, cursor lifecycle, 100K-10M row streaming
- **Related**: el-aob (Implement True Streaming Cursors - feature)

### 2. **el-fd8**: Test connection pool behavior under load
- **Type**: task
- **Effort**: 2-3 hours
- **Status**: open
- **File**: test/pool_load_test.exs (new)
- **Scenarios**: Concurrent connections, exhaustion, recovery, load distribution, cleanup
- **Related**: No existing feature dependency

### 3. **el-d63**: Test connection error recovery
- **Type**: task
- **Effort**: 2-3 hours
- **Status**: open
- **File**: test/connection_recovery_test.exs (new)
- **Scenarios**: Connection loss, reconnection, retry logic, timeout, network partition
- **Related**: No existing feature dependency

### 4. **el-crt**: Test savepoint + replication interaction
- **Type**: task
- **Effort**: 3-4 hours
- **Status**: open
- **File**: test/savepoint_replication_test.exs (new)
- **Scenarios**: Savepoints in replica mode, nested savepoints, sync failures, concurrent savepoints
- **Related**: replication_integration_test.exs, savepoint_test.exs (existing)

### 5. **el-wtl**: Test JSONB binary format operations
- **Type**: task
- **Effort**: 2-3 hours
- **Status**: open
- **File**: Extend test/json_helpers_test.exs
- **Scenarios**: Round-trip, compatibility, storage size, performance, large objects, modifications
- **Related**: el-a17 (JSONB Binary Format Support - feature, closed)

### 6. **el-d3o**: Add Rust tests for error scenarios
- **Type**: task
- **Effort**: 1-2 hours
- **Status**: open
- **File**: native/ecto_libsql/src/tests/error_handling_tests.rs (new)
- **Scenarios**: Invalid IDs, constraint violations, transaction errors, syntax errors, resource exhaustion
- **Critical**: BEAM stability - verifies Rust layer doesn't panic on invalid inputs

## 🟢 P3 - Low Priority (Nice to Have)

### 7. **el-cbv**: Add performance benchmark tests
- **Type**: task
- **Effort**: 2-3 days
- **Status**: open
- **Categories**: Prepared statements, cursor streaming, concurrent connections, transactions, batch ops, statement cache, replication
- **Files**: benchmarks/*.exs (7 files)
- **Tools**: benchee (~1.3), benchee_html
- **Output**: mix bench, HTML reports, PERFORMANCE.md baselines

### 8. **el-1p2**: Document test layering strategy
- **Type**: task
- **Effort**: 1-2 hours
- **Status**: open
- **File**: TESTING.md (create/update)
- **Content**: Rust vs Elixir test strategy, decision tree for contributors

### 9. **el-v3v**: Reduce redundant parameter binding tests
- **Type**: task
- **Effort**: 30 minutes
- **Status**: open
- **Work**: Remove basic type binding tests from Elixir (Rust already covers)
- **Keep**: Named parameters, complex scenarios, Ecto-specific tests

## 📊 Breakdown by TEST_AUDIT_REPORT Recommendations

| Item | Report ID | Issue | Priority |
|------|-----------|-------|----------|
| Large result sets streaming | #9 | el-doo | P2 |
| Connection pool under load | #9 | el-fd8 | P2 |
| Recovery from errors | #9 | el-d63 | P2 |
| Savepoint + replication | #9 | el-crt | P2 |
| JSONB binary format | #9 | el-wtl | P2 |
| Rust error scenarios | #6 | el-d3o | P2 |
| Performance benchmarks | #9 | el-cbv | P3 |
| Test layering docs | #7 | el-1p2 | P3 |
| Reduce parameter binding | #8 | el-v3v | P3 |

## ✅ What's Captured

These 9 issues capture:
- ✅ All 5 under-tested areas from TEST_AUDIT_REPORT.md section "What's Under-Tested"
- ✅ Rust error handling tests (critical for BEAM stability)
- ✅ Performance benchmarking infrastructure (missing entirely)
- ✅ Contributor documentation (test layering strategy)
- ✅ Test reduction/cleanup recommendations

## 🚀 Next Steps

1. **Pick a P2 issue** to start with
2. Implement the test scenarios described
3. Move issue to in-progress when starting
4. Close issue when all tests pass

## 📚 Source Document

All issues derived from: `TEST_AUDIT_REPORT.md`
- Section: "Recommendations" (items #6-9)
- Section: "What's Under-Tested" (identified gaps)

---

**Created**: 2026-01-08  
**Branch**: consolidate-tests  
**Commit**: 5b6afe8
