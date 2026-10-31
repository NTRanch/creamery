# Creamery — task recipes. Preflight replaces the stub recipes with the
# week's real toolchain commands and records them in the book (Build chapter).

# Assemble the single-file jam entry (stub until preflight)
build:
    @echo "preflight: wire the Zig build chain here"

# Run the week's gates (stub until preflight)
check:
    @echo "preflight: wire tests + conformance here"

# Build the planning book
book:
    mdbook build book
