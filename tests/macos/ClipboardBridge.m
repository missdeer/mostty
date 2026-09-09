#import <Metal/Metal.h>
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#include <assert.h>
#include <string.h>
#include "ClipboardBridge.h"

// Replace only the C bridge: the tests run the production AppKit handlers.
static uint8_t written[4096];
static size_t written_count;
static uint8_t tabs[8];
static size_t tab_count;
static MosttyScrollbar scrollbars[8];
static MosttyTab *write_tab;
static bool bracketed_paste;
static bool application_keypad;
static size_t keypad_queries;
static bool selection_active;
static uint32_t selection_end;
static bool word_selection;
static uint32_t word_col;
static id<MTLDevice> device;
static NSString *url_text;
static NSString *opened_url;
static bool hovered_url;
static bool url_open_success;
static IMP original_open_url;
static bool mouse_enabled;
static uint32_t mouse_count, mouse_action, mouse_button;
static int32_t mouse_x, mouse_y;

void clipboard_test_mouse_mode(bool enabled) { mouse_enabled = enabled; mouse_count = 0; }
uint32_t clipboard_test_mouse_count(void) { return mouse_count; }
uint32_t clipboard_test_mouse_action(void) { return mouse_action; }
uint32_t clipboard_test_mouse_button(void) { return mouse_button; }
int32_t clipboard_test_mouse_x(void) { return mouse_x; }
int32_t clipboard_test_mouse_y(void) { return mouse_y; }
bool mostty_tab_mouse_enabled(MosttyTab *tab) { return mouse_enabled; }
void mostty_tab_mouse(MosttyTab *tab, uint32_t action, uint32_t button, uint32_t mods, int32_t x, int32_t y) {
    write_tab = tab;
    mouse_count += 1; mouse_action = action; mouse_button = button; mouse_x = x; mouse_y = y;
}

static BOOL recordOpenURL(id workspace, SEL selector, NSURL *url) {
    opened_url = url.absoluteString;
    return url_open_success;
}

void clipboard_test_url(const char *url, bool open_success) {
    if (!original_open_url) {
        Method method = class_getInstanceMethod(NSWorkspace.class, @selector(openURL:));
        original_open_url = method_setImplementation(method, (IMP)recordOpenURL);
    }
    url_text = url ? [NSString stringWithUTF8String:url] : nil;
    opened_url = nil;
    url_open_success = open_success;
}
const char *clipboard_test_opened_url(void) { return opened_url.UTF8String; }
bool clipboard_test_hovered_url(void) { return hovered_url; }
void clipboard_test_restore_url_open(void) {
    if (original_open_url) {
        Method method = class_getInstanceMethod(NSWorkspace.class, @selector(openURL:));
        method_setImplementation(method, original_open_url);
        original_open_url = NULL;
    }
}

void clipboard_test_reset(bool bracketed) { written_count = 0; bracketed_paste = bracketed; }
void clipboard_test_keypad_mode(bool enabled) {
    application_keypad = enabled;
    keypad_queries = 0;
}
size_t clipboard_test_keypad_queries(void) { return keypad_queries; }
size_t clipboard_test_written(uint8_t *buf, size_t cap) {
    assert(written_count <= cap);
    memcpy(buf, written, written_count);
    return written_count;
}

MosttyTab *mostty_tab_create(uint32_t w, uint32_t h, float scale) {
    assert(tab_count < sizeof(tabs));
    scrollbars[tab_count] = (MosttyScrollbar){h / 20, 0, h / 20};
    return (MosttyTab *)&tabs[tab_count++];
}
MosttyTab *mostty_tab_create_with_launcher(uint32_t w, uint32_t h, float scale,
                                         const char *command, const char *directory) {
    return mostty_tab_create(w, h, scale);
}
MosttyTab *clipboard_test_created_tab(void) { return tab_count ? (MosttyTab *)&tabs[tab_count - 1] : NULL; }
MosttyTab *clipboard_test_write_tab(void) { return write_tab; }
void mostty_tab_destroy(MosttyTab *tab) {}
float mostty_config_background_opacity(void) { return 1; }
uint32_t mostty_config_render_interval_ms(void) { return 16; }
bool mostty_tab_apply_config(MosttyTab *tab) { return false; }
void *mostty_tab_metal_device(MosttyTab *tab) {
    if (!device) device = MTLCreateSystemDefaultDevice();
    return (__bridge void *)device;
}
intptr_t mostty_tab_read(MosttyTab *tab, uint8_t *buf, size_t cap) { return 0; }
void mostty_tab_feed(MosttyTab *tab, const uint8_t *ptr, size_t len) {}
void mostty_tab_write(MosttyTab *tab, const uint8_t *ptr, size_t len) {
    write_tab = tab;
    assert(len <= sizeof(written) - written_count);
    memcpy(written + written_count, ptr, len);
    written_count += len;
}
bool mostty_tab_set_surface(MosttyTab *tab, uint32_t w, uint32_t h, float scale, uint32_t *cols, uint32_t *rows) {
    *cols = w / 10; *rows = h / 20; return true;
}
void *mostty_tab_render(MosttyTab *tab, bool cursor, uint32_t *cols, uint32_t *rows) { return NULL; }
size_t mostty_tab_title(MosttyTab *tab, uint8_t *buf, size_t cap) { return 0; }
bool mostty_tab_poll_exit(MosttyTab *tab, int32_t *code) { return false; }
void mostty_tab_cell_size(MosttyTab *tab, uint32_t *w, uint32_t *h) { *w = 10; *h = 20; }
void mostty_tab_cursor(MosttyTab *tab, uint32_t *col, uint32_t *row) { *col = 0; *row = 0; }
bool mostty_tab_app_cursor_keys(MosttyTab *tab) { return false; }
bool mostty_tab_app_keypad(MosttyTab *tab) { keypad_queries += 1; return application_keypad; }
bool mostty_tab_bracketed_paste(MosttyTab *tab) { return bracketed_paste; }
MosttyScrollbar mostty_tab_scrollbar(MosttyTab *tab) {
    return tab ? scrollbars[(uint8_t *)tab - tabs] : (MosttyScrollbar){0};
}
void clipboard_test_scrollback(MosttyTab *tab, uint64_t total, uint64_t offset, uint64_t visible) {
    scrollbars[(uint8_t *)tab - tabs] = (MosttyScrollbar){total, offset, visible};
}
void mostty_tab_scroll_to_row(MosttyTab *tab, uint64_t row) {
    if (!tab) return;
    MosttyScrollbar *state = &scrollbars[(uint8_t *)tab - tabs];
    uint64_t max_offset = state->total > state->visible ? state->total - state->visible : 0;
    state->offset = MIN(row, max_offset);
}
void mostty_tab_scroll(MosttyTab *tab, int32_t rows) {
    MosttyScrollbar state = mostty_tab_scrollbar(tab);
    mostty_tab_scroll_to_row(tab, MAX(0, (int64_t)state.offset + rows));
}
void mostty_tab_scroll_to_bottom(MosttyTab *tab) { mostty_tab_scroll_to_row(tab, UINT64_MAX); }
void mostty_tab_set_selection(MosttyTab *tab, bool active, uint32_t sc, uint32_t sr, uint32_t ec, uint32_t er) {
    selection_active = active; selection_end = ec; word_selection = false;
}
bool mostty_tab_select_word(MosttyTab *tab, uint32_t col, uint32_t row) {
    selection_active = true; word_selection = true; word_col = col;
    return true;
}
bool mostty_tab_hover_url(MosttyTab *tab, bool active, uint32_t col, uint32_t row) {
    hovered_url = active && url_text != nil && col >= 10 && col < 30 && row == 0;
    return hovered_url;
}
size_t mostty_tab_url_at(MosttyTab *tab, uint32_t col, uint32_t row, uint8_t *buf, size_t cap) {
    if (!url_text || col < 10 || col >= 30 || row != 0) return 0;
    const char *text = url_text.UTF8String;
    size_t len = strlen(text);
    if (len > cap) return 0;
    memcpy(buf, text, len);
    return len;
}
size_t mostty_tab_selection_text(MosttyTab *tab, uint8_t *buf, size_t cap) {
    assert(selection_active);
    const char *text = word_selection ? (word_col == 8 ? "x" : "hello") : (selection_end == 4 ? "hello" : "hel");
    size_t len = strlen(text);
    if (cap == 0) return len;
    assert(len <= cap);
    memcpy(buf, text, len);
    return len;
}

@interface ClipboardDragInfo : NSObject <NSDraggingInfo>
@property(strong) NSPasteboard *draggingPasteboard;
@property NSDragOperation draggingSourceOperationMask;
@property NSDraggingFormation draggingFormation;
@property BOOL animatesToDestination;
@property NSInteger numberOfValidItemsForDrop;
@end

@implementation ClipboardDragInfo
- (NSWindow *)draggingDestinationWindow { return nil; }
- (NSPoint)draggingLocation { return NSZeroPoint; }
- (NSPoint)draggedImageLocation { return NSZeroPoint; }
- (NSImage *)draggedImage { return nil; }
- (id)draggingSource { return nil; }
- (NSInteger)draggingSequenceNumber { return 0; }
- (NSSpringLoadingHighlight)springLoadingHighlight { return NSSpringLoadingHighlightNone; }
- (void)resetSpringLoading {}
- (void)slideDraggedImageTo:(NSPoint)point {}
- (NSArray<NSString *> *)namesOfPromisedFilesDroppedAtDestination:(NSURL *)destination { return nil; }
- (void)enumerateDraggingItemsWithOptions:(NSDraggingItemEnumerationOptions)options
                                forView:(NSView *)view classes:(NSArray<Class> *)classes
                          searchOptions:(NSDictionary<NSPasteboardReadingOptionKey, id> *)searchOptions
                             usingBlock:(void (^)(NSDraggingItem *, NSInteger, BOOL *))block {}
@end

id<NSDraggingInfo> clipboard_test_drag(NSPasteboard *pasteboard, NSDragOperation operation) {
    ClipboardDragInfo *info = [ClipboardDragInfo new];
    info.draggingPasteboard = pasteboard;
    info.draggingSourceOperationMask = operation;
    return info;
}
