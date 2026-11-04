#include <dlfcn.h>
#include <stdio.h>

int main(int argc, const char *argv[], const char *envp[]) {
    if (argc < 2) {
        fprintf(stderr, "usage: qemu-loader QEMU_DYLIB [QEMU_ARGS...]\n");
        return 2;
    }

    void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!library) {
        fprintf(stderr, "loading QEMU: %s\n", dlerror());
        return 1;
    }

    int (*init)(int, const char *[], const char *[]) = dlsym(library, "qemu_init");
    void (*loop)(void) = dlsym(library, "qemu_main_loop");
    void (*cleanup)(void) = dlsym(library, "qemu_cleanup");
    if (!init || !loop || !cleanup) {
        fprintf(stderr, "the UTM QEMU library does not export its entry points\n");
        return 1;
    }

    init(argc - 1, argv + 1, envp);
    loop();
    cleanup();
    return 0;
}
