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

### Test ROMs

The [testroms](testroms) directory contains public-domain and community test ROMs for hardware verification and testing.
Check [testroms/README.md](testroms/README.md) for more details.
