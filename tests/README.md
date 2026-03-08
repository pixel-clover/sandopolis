## Tests

This directory contains project tests that are not unit tests like integration, regression, property-based tests, etc.
Unit tests should be in the same module as the code they test.

### Running Tests

The following commands will run all tests in this directory plus any unit tests in the source modules:

```bash
make test
```

```bash
zig build test
```

### Running Tests by Category

```bash
make test-unit
make test-integration
make test-regression
make test-property
```

```bash
zig build test-unit
zig build test-integration
zig build test-regression
zig build test-property
```

`zig build test-unit` runs module-local unit tests collected through the internal `src/unit_test_root.zig` build root.

### Test ROMs

The [testroms](testroms) directory contains public-domain and community test ROMs for hardware verification and testing.
Check [testroms/README.md](testroms/README.md) for more details.

### Suite Roles

- `integration_tests.zig`: stable multi-module and public-API wiring tests using synthetic data, temporary files, or deterministic checked-in assets.
- `regression_tests.zig`: bug reproductions, timing-sensitive regressions, and ROM-backed hardware checks, especially with `tests/testroms/`.
- `property_tests.zig`: invariant and randomized coverage.

All non-unit suites import the public API from `src/api.zig`.
When they need more control than the normal `Machine` facade exposes, they should use the explicit `sandopolis.testing` API rather than importing raw core modules or structs.
