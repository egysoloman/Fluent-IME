#include "CRimeBridge.h"
#include <assert.h>
#include <stdio.h>

int main(int argc, char **argv) {
    assert(argc == 3);
    for (int pass = 0; pass < 2; ++pass) {
        assert(FIMInitialize(argv[1], argv[2], false));
        assert(FIMHasGrammar());
        FIMSession session = FIMCreateSession();
        assert(FIMSelectSchema(session, "fluent_pinyin_a1_c1_l0_g1"));
        for (const char *key = "nihao"; *key; ++key) assert(FIMProcessKey(session, *key, 0));
        if (pass == 0) FIMFinalize();
    }
    // Deliberately leave a live grammar session, as the app's Runtime singleton
    // does at process exit. The exit handler must run before plugin unloading.
    puts("Live-session shutdown and reinitialization ready");
    return 0;
}
