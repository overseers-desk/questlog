/*
 * Custom wish for the self-contained questlog image.
 *
 * A stock wish loads Tk and Thread as shared objects at runtime, and zipfs
 * cannot serve a .so to load(). So both are linked into this interpreter and
 * registered as static libraries: Tcl_StaticLibrary records their init
 * functions, and package require resolves against the in-binary code instead
 * of a dlopen. The pure-Tcl json package travels in the image's embedded
 * tcl_library and needs no C glue.
 *
 * Thread's own NewThread() calls Tcl_Init() then Thread_Init() on each worker
 * interp it spawns (generic/threadCmd.c), so worker threads created by
 * thread::create pick up Thread with no package ifneeded entry.
 */
#include <tcl.h>
#include <tk.h>

extern int Thread_Init(Tcl_Interp *interp);

static int Questlog_AppInit(Tcl_Interp *interp) {
    if (Tcl_Init(interp) != TCL_OK) {
        return TCL_ERROR;
    }
    if (Tk_Init(interp) != TCL_OK) {
        return TCL_ERROR;
    }
    Tcl_StaticLibrary(interp, "Tk", Tk_Init, Tk_SafeInit);

    if (Thread_Init(interp) != TCL_OK) {
        return TCL_ERROR;
    }
    Tcl_StaticLibrary(interp, "Thread", Thread_Init, NULL);

    return TCL_OK;
}

int main(int argc, char **argv) {
    /*
     * Mount the appended zip and rewrite argv to source its main.tcl. Without
     * this hook the stubbed image finds no startup script and drops into an
     * interactive wish.
     */
    TclZipfs_AppHook(&argc, &argv);
    Tk_Main(argc, argv, Questlog_AppInit);
    return 0;
}
