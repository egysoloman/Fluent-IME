#ifndef FLUENT_RIME_BRIDGE_H
#define FLUENT_RIME_BRIDGE_H
#include <stdint.h>
#include <stdbool.h>

typedef uintptr_t FIMSession;
typedef struct {
    char *preedit;
    char *input;
    int cursor_utf8;
    int page;
    int page_size;
    bool last_page;
    int highlighted;
    int count;
    char *candidates[9];
    char *comments[9];
} FIMContext;

typedef struct {
    int count;
    bool has_more;
    char **texts;
    char **comments;
} FIMCandidateBatch;

bool FIMInitialize(const char *shared_dir, const char *user_dir, bool full_check);
void FIMFinalize(void);
const char *FIMVersion(void);
bool FIMHasGrammar(void);
FIMSession FIMCreateSession(void);
bool FIMSelectSchema(FIMSession session, const char *schema);
void FIMDestroySession(FIMSession session);
bool FIMProcessKey(FIMSession session, int key, int modifiers);
bool FIMSelectCandidate(FIMSession session, int index);
bool FIMSelectAbsoluteCandidate(FIMSession session, int index);
bool FIMHighlightAbsoluteCandidate(FIMSession session, int index);
int FIMGetCaretPosition(FIMSession session);
void FIMSetCaretPosition(FIMSession session, int position);
FIMCandidateBatch *FIMReadCandidates(FIMSession session, int start, int limit);
void FIMFreeCandidates(FIMCandidateBatch *batch);
void FIMSetOption(FIMSession session, const char *name, bool value);
void FIMClear(FIMSession session);
void FIMCommit(FIMSession session);
char *FIMTakeCommit(FIMSession session);
FIMContext *FIMGetContext(FIMSession session);
void FIMFreeContext(FIMContext *context);
void FIMFreeString(char *string);
#endif
