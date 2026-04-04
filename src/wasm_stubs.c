// Minimal setjmp/longjmp stubs for WASM builds.
//
// The M68K core (rocket68) uses setjmp/longjmp for bus/address error
// recovery. On WASM, musl libc does not provide these functions.
// These stubs allow compilation; setjmp always returns 0 (no error),
// and longjmp traps since bus errors are rare in normal ROM execution.

#include <stddef.h>

typedef long jmp_buf[8];

int setjmp(jmp_buf env) {
    (void)env;
    return 0;
}

_Noreturn void longjmp(jmp_buf env, int val) {
    (void)env;
    (void)val;
    __builtin_trap();
}

// WASI CRT expects main but we use --no-entry.
int main(void) { return 0; }
