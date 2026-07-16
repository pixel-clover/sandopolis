/* A minimal setjmp.h for WASM builds, shadowing musl's header.
 * musl's setjmp.h #errors without wasm exception-handling support, and
 * Zig 0.16.0's bundled clang crashes compiling musl's EH-based setjmp
 * runtime (libc-top-half/musl/src/setjmp/wasm32/rt.c). The actual
 * implementations are the no-op stubs in src/wasm_stubs.c. */
#ifndef _SETJMP_H
#define _SETJMP_H
typedef long jmp_buf[8];
int setjmp(jmp_buf env);
_Noreturn void longjmp(jmp_buf env, int val);
#endif
