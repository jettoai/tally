#ifndef TALLY_CORE_H
#define TALLY_CORE_H
#include <stddef.h>
#include <stdint.h>

// C ABI of rust/ (tally_core). Mirrored field for field by rust/src/lib.rs; the ctxrust suite
// asserts both sides agree on every size and offset.

#define TALLY_ERR_PANIC (-1)
#define TALLY_ERR_ARGS (-2)

#define TALLY_TS_NONE 0
#define TALLY_TS_PARSED 1
#define TALLY_TS_RAW 2

/// A value inside the line: byte offset and length. len < 0 means absent.
typedef struct {
    int64_t off;
    int64_t len;
} TallySpan;

typedef struct {
    uint64_t present;        /* bit i set: needle i occurs in the line */
    int64_t context_tokens;  /* -1: no reading (contextTokens(inLine:) == nil) */
    int64_t ts_seconds;      /* TALLY_TS_PARSED: whole seconds since 1970, UTC */
    int32_t ts_millis;       /* TALLY_TS_PARSED: 0...999 */
    int32_t ts_kind;         /* TALLY_TS_* */
    int32_t utf8_valid;      /* 1 valid, 0 not (the line is then skipped, as it always was) */
    int32_t reserved;
    TallySpan ts_raw;        /* the stamp text, set for PARSED and RAW */
    TallySpan uuid, parent_uuid, model, excerpt;
} TallyLineFields;

typedef struct TallyNeedles TallyNeedles;

/// Builds one SIMD finder per needle. NULL when count > 64, a needle is empty, or on panic.
TallyNeedles *tally_needles_new(const uint8_t *const *ptrs, const size_t *lens, size_t count);
/// Reads one line (no trailing newline). 0 ok, TALLY_ERR_PANIC, TALLY_ERR_ARGS (null pointers).
int32_t tally_line_fields(const TallyNeedles *needles, const uint8_t *line, size_t len,
                          TallyLineFields *out);
/// Build marker: the release script looks for this string in both CLI slices.
const char *tally_core_version(void);
#endif
