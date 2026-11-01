#include "CRimeBridge.h"
#include <rime_api.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>

#define FIM_DISTRIBUTION_VERSION "0.6.2"

static RimeApi *api;
static char *shared_path;
static char *user_path;
static char *staging_path;

bool FIMInitialize(const char *shared_dir, const char *user_dir, bool full_check) {
    if (api) return true;
    api = rime_get_api();
    shared_path = strdup(shared_dir);
    user_path = strdup(user_dir);
    RIME_STRUCT(RimeTraits, traits);
    traits.shared_data_dir = shared_path;
    traits.user_data_dir = user_path;
    traits.distribution_name = "Fluent IME";
    traits.distribution_code_name = "fluent_ime";
    traits.distribution_version = FIM_DISTRIBUTION_VERSION;
    // A prism encodes syllable IDs from its matching table. Old user/build
    // prisms must never shadow a new bundled table. Isolate compiled caches
    // by release while retaining the same user_data_dir and learned database.
    // Source deployments still use the standard build directory.
    char *prebuilt_table = NULL;
    if (asprintf(&prebuilt_table, "%s/build/fluent_pinyin.table.bin", shared_dir) >= 0) {
        if (access(prebuilt_table, F_OK) == 0 &&
            asprintf(&staging_path, "%s/build-%s", user_dir, FIM_DISTRIBUTION_VERSION) >= 0)
            traits.staging_dir = staging_path;
        free(prebuilt_table);
    }
    traits.app_name = "rime.fluent_ime";
    traits.min_log_level = 2;
    traits.log_dir = "";
    api->setup(&traits);
    api->initialize(&traits);
    if (api->start_maintenance(full_check)) api->join_maintenance_thread();
    // Exit callbacks run in reverse order. Register after module setup so live
    // sessions are destroyed before C++ singletons and plugin code unload.
    // Reinitialization needs a new callback; older callbacks safely see api=NULL.
    atexit(FIMFinalize);
    return true;
}

void FIMFinalize(void) {
    if (api) api->finalize();
    api = NULL;
    free(shared_path); shared_path = NULL;
    free(user_path); user_path = NULL;
    free(staging_path); staging_path = NULL;
}
const char *FIMVersion(void) { return api ? api->get_version() : "uninitialized"; }
FIMSession FIMCreateSession(void) {
    if (!api) return 0;
    FIMSession session = api->create_session();
    if (session && !api->select_schema(session, "fluent_pinyin")) {
        api->destroy_session(session);
        return 0;
    }
    return session;
}
void FIMDestroySession(FIMSession session) { if (api && session) api->destroy_session(session); }
bool FIMSelectSchema(FIMSession session, const char *schema) { return api && session && api->select_schema(session, schema); }
bool FIMProcessKey(FIMSession session, int key, int modifiers) { return api && session && api->process_key(session, key, modifiers); }
bool FIMSelectCandidate(FIMSession session, int index) {
    if (!api || !session || index < 0 || index >= 9) return false;
    return RIME_API_AVAILABLE(api, select_candidate_on_current_page) && api->select_candidate_on_current_page(session, (size_t)index);
}
void FIMSetOption(FIMSession session, const char *name, bool value) { if (api && session) api->set_option(session, name, value); }
bool FIMSelectAbsoluteCandidate(FIMSession session, int index) {
    return api && session && index >= 0 && api->select_candidate(session, (size_t)index);
}
bool FIMHighlightAbsoluteCandidate(FIMSession session, int index) {
    return api && session && index >= 0 && RIME_API_AVAILABLE(api, highlight_candidate) && api->highlight_candidate(session, (size_t)index);
}
int FIMGetCaretPosition(FIMSession session) { return api && session ? (int)api->get_caret_pos(session) : 0; }
void FIMSetCaretPosition(FIMSession session, int position) {
    if (api && session && position >= 0 && RIME_API_AVAILABLE(api, set_caret_pos)) api->set_caret_pos(session, (size_t)position);
}
FIMCandidateBatch *FIMReadCandidates(FIMSession session, int start, int limit) {
    if (!api || !session || start < 0 || limit < 1 || limit > 256 || !RIME_API_AVAILABLE(api, candidate_list_from_index)) return NULL;
    FIMCandidateBatch *batch = calloc(1, sizeof(FIMCandidateBatch));
    batch->texts = calloc((size_t)limit, sizeof(char *));
    batch->comments = calloc((size_t)limit, sizeof(char *));
    RimeCandidateListIterator iterator = {0};
    if (api->candidate_list_from_index(session, &iterator, start)) {
        while (batch->count < limit && api->candidate_list_next(&iterator)) {
            batch->texts[batch->count] = strdup(iterator.candidate.text ? iterator.candidate.text : "");
            batch->comments[batch->count] = strdup(iterator.candidate.comment ? iterator.candidate.comment : "");
            batch->count++;
        }
        batch->has_more = api->candidate_list_next(&iterator);
        api->candidate_list_end(&iterator);
    }
    return batch;
}
void FIMFreeCandidates(FIMCandidateBatch *batch) {
    if (!batch) return;
    for (int i = 0; i < batch->count; i++) { free(batch->texts[i]); free(batch->comments[i]); }
    free(batch->texts); free(batch->comments); free(batch);
}
void FIMClear(FIMSession session) { if (api && session) api->clear_composition(session); }
void FIMCommit(FIMSession session) { if (api && session) api->commit_composition(session); }
char *FIMTakeCommit(FIMSession session) {
    RIME_STRUCT(RimeCommit, commit);
    if (!api || !session || !api->get_commit(session, &commit)) return NULL;
    char *text = strdup(commit.text ? commit.text : "");
    api->free_commit(&commit);
    return text;
}
FIMContext *FIMGetContext(FIMSession session) {
    if (!api || !session) return NULL;
    RIME_STRUCT(RimeContext, context);
    if (!api->get_context(session, &context)) return NULL;
    FIMContext *result = calloc(1, sizeof(FIMContext));
    result->preedit = strdup(context.composition.preedit ? context.composition.preedit : "");
    const char *input = api->get_input(session);
    result->input = strdup(input ? input : "");
    result->cursor_utf8 = context.composition.cursor_pos;
    result->page = context.menu.page_no;
    result->page_size = context.menu.page_size;
    result->last_page = context.menu.is_last_page;
    result->highlighted = context.menu.highlighted_candidate_index;
    result->count = context.menu.num_candidates < 9 ? context.menu.num_candidates : 9;
    for (int i = 0; i < result->count; ++i) {
        result->candidates[i] = strdup(context.menu.candidates[i].text ? context.menu.candidates[i].text : "");
        result->comments[i] = strdup(context.menu.candidates[i].comment ? context.menu.candidates[i].comment : "");
    }
    api->free_context(&context);
    return result;
}
void FIMFreeContext(FIMContext *context) {
    if (!context) return;
    free(context->preedit); free(context->input);
    for (int i = 0; i < context->count; ++i) { free(context->candidates[i]); free(context->comments[i]); }
    free(context);
}
void FIMFreeString(char *string) { free(string); }

bool FIMHasGrammar(void) { return api && api->find_module("grammar") != NULL; }
