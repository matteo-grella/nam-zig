/* Window shim for non-Apple targets. Linux: a GTK 3 window hosting a
 * WebKitGTK view on the app's local page, both libraries loaded at
 * runtime (no link-time dependency; a system without them reports
 * unsupported and the Zig side opens the default browser instead).
 * Windows: unsupported (browser fallback). The microphone queries have
 * no system permission model here and report authorized. */

#include <stddef.h>

#if defined(__linux__)
#include <dlfcn.h>

typedef void* gpointer;
typedef void (*nam_gtk_init_check_t)(int*, char***);
typedef void* (*nam_gtk_window_new_t)(int);
typedef void (*nam_gtk_window_set_title_t)(void*, const char*);
typedef void (*nam_gtk_window_set_default_size_t)(void*, int, int);
typedef void (*nam_gtk_container_add_t)(void*, void*);
typedef void* (*nam_webkit_web_view_new_t)(void);
typedef void (*nam_webkit_web_view_load_uri_t)(void*, const char*);
typedef void (*nam_gtk_widget_show_all_t)(void*);
typedef unsigned long (*nam_g_signal_connect_data_t)(gpointer, const char*, void (*)(void), gpointer, gpointer, int);
typedef void (*nam_gtk_main_t)(void);
typedef void (*nam_gtk_main_quit_t)(void);
typedef unsigned int (*nam_g_idle_add_t)(int (*)(gpointer), gpointer);

static nam_gtk_main_quit_t nam_quit_fn = NULL;
static nam_g_idle_add_t nam_idle_add_fn = NULL;

static int nam_quit_idle(gpointer user) {
    (void)user;
    if (nam_quit_fn != NULL) nam_quit_fn();
    return 0;
}

static void* nam_load_libs(void** gtk_out) {
    void* gtk = dlopen("libgtk-3.so.0", RTLD_NOW | RTLD_GLOBAL);
    if (gtk == NULL) return NULL;
    void* webkit = dlopen("libwebkit2gtk-4.1.so.0", RTLD_NOW | RTLD_GLOBAL);
    if (webkit == NULL) webkit = dlopen("libwebkit2gtk-4.0.so.37", RTLD_NOW | RTLD_GLOBAL);
    if (webkit == NULL) {
        dlclose(gtk);
        return NULL;
    }
    *gtk_out = gtk;
    return webkit;
}

int nam_window_supported(void) {
    void* gtk = NULL;
    void* webkit = nam_load_libs(&gtk);
    if (webkit == NULL) return 0;
    dlclose(webkit);
    dlclose(gtk);
    return 1;
}

int nam_window_open(const char* url, const char* title, int width, int height) {
    void* gtk = NULL;
    void* webkit = nam_load_libs(&gtk);
    if (webkit == NULL) return -1;

    nam_gtk_init_check_t gtk_init_check = (nam_gtk_init_check_t)dlsym(gtk, "gtk_init_check");
    nam_gtk_window_new_t gtk_window_new = (nam_gtk_window_new_t)dlsym(gtk, "gtk_window_new");
    nam_gtk_window_set_title_t gtk_window_set_title = (nam_gtk_window_set_title_t)dlsym(gtk, "gtk_window_set_title");
    nam_gtk_window_set_default_size_t gtk_window_set_default_size = (nam_gtk_window_set_default_size_t)dlsym(gtk, "gtk_window_set_default_size");
    nam_gtk_container_add_t gtk_container_add = (nam_gtk_container_add_t)dlsym(gtk, "gtk_container_add");
    nam_gtk_widget_show_all_t gtk_widget_show_all = (nam_gtk_widget_show_all_t)dlsym(gtk, "gtk_widget_show_all");
    nam_g_signal_connect_data_t g_signal_connect_data = (nam_g_signal_connect_data_t)dlsym(gtk, "g_signal_connect_data");
    nam_gtk_main_t gtk_main = (nam_gtk_main_t)dlsym(gtk, "gtk_main");
    nam_gtk_main_quit_t gtk_main_quit = (nam_gtk_main_quit_t)dlsym(gtk, "gtk_main_quit");
    nam_g_idle_add_t g_idle_add = (nam_g_idle_add_t)dlsym(gtk, "g_idle_add");
    nam_webkit_web_view_new_t webkit_web_view_new = (nam_webkit_web_view_new_t)dlsym(webkit, "webkit_web_view_new");
    nam_webkit_web_view_load_uri_t webkit_web_view_load_uri = (nam_webkit_web_view_load_uri_t)dlsym(webkit, "webkit_web_view_load_uri");
    if (!gtk_init_check || !gtk_window_new || !gtk_window_set_title || !gtk_window_set_default_size ||
        !gtk_container_add || !gtk_widget_show_all || !g_signal_connect_data || !gtk_main || !gtk_main_quit ||
        !webkit_web_view_new || !webkit_web_view_load_uri) {
        return -1;
    }

    nam_quit_fn = gtk_main_quit;
    nam_idle_add_fn = g_idle_add;
    int argc = 0;
    char** argv = NULL;
    gtk_init_check(&argc, &argv);
    void* window = gtk_window_new(0); /* GTK_WINDOW_TOPLEVEL */
    gtk_window_set_title(window, title);
    gtk_window_set_default_size(window, width, height);
    void* view = webkit_web_view_new();
    gtk_container_add(window, view);
    webkit_web_view_load_uri(view, url);
    g_signal_connect_data(window, "destroy", (void (*)(void))gtk_main_quit, NULL, NULL, 0);
    gtk_widget_show_all(window);
    gtk_main();
    return 0;
}

/* Closes the window from any thread (the Quit button's request). */
void nam_window_close(void) {
    if (nam_idle_add_fn != NULL) nam_idle_add_fn(nam_quit_idle, NULL);
}

#else

int nam_window_supported(void) {
    return 0;
}

void nam_window_close(void) {}

int nam_window_open(const char* url, const char* title, int width, int height) {
    (void)url;
    (void)title;
    (void)width;
    (void)height;
    return -1;
}

#endif

int nam_mic_status(void) {
    return 1;
}

int nam_mic_request(unsigned int timeout_ms) {
    (void)timeout_ms;
    return 1;
}
