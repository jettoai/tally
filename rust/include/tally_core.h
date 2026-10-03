#ifndef TALLY_CORE_H
#define TALLY_CORE_H
#include <stddef.h>
#include <stdint.h>

// C ABI of rust/ (tally_core). Mirrored field for field by rust/src/lib.rs; the ctxrust suite
// asserts both sides agree on every size and offset.

#define TALLY_ERR_PANIC (-1)
#define TALLY_ERR_ARGS (-2)
#define TALLY_ERR_NOFILE (-3)

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
/* TallyScanLine.kind. The history bits are set only for a line with no full-path needle. */
#define TALLY_LINE_HISTORY_CANDIDATE 1u /* stamp earlier than since */
#define TALLY_LINE_HISTORY_UNDECIDED 2u /* stamp the core does not parse: Swift asks its formatters */
#define TALLY_LINE_SIDECHAIN 4u        /* set only with a history bit: history needle 0 */
#define TALLY_LINE_TYPE_ASSISTANT 8u   /* needle 1 */
#define TALLY_LINE_TYPE_USER 16u       /* needle 2 */

typedef struct {
    TallyLineFields fields;  /* spans relative to the line */
    int64_t off;             /* the line in the block's bytes */
    int64_t len;             /* no trailing newline */
    uint32_t kind;           /* TALLY_LINE_* */
    int32_t reserved;
} TallyScanLine;

typedef struct {
    uint64_t start_offset;   /* where the read began (0 when truncated) */
    uint64_t new_offset;     /* just past the last complete newline */
    uint64_t end;            /* the file size when it was opened */
    int32_t at_end;          /* the read reached the end of the file */
    int32_t truncated;       /* end < offset: the caller resets before applying any line */
    uint8_t *bytes;          /* what this tick read; lines and tail point into it */
    size_t bytes_len;
    TallyScanLine *lines;
    size_t line_count;
    TallyScanLine tail;      /* at_end: the bytes after the last newline, when has_tail */
    int32_t has_tail;
    int32_t reserved;
} TallyScanBlock;

/// One tick of `sawCapHit`. history_needles: sidechain, type assistant, type user, then the
/// full-path needles. since_reference is `since.timeIntervalSinceReferenceDate`, since_key
/// `transcriptSecondKey(since)`. 0 ok (free the block with tally_scan_block_free),
/// TALLY_ERR_NOFILE (cannot open), TALLY_ERR_ARGS, TALLY_ERR_PANIC.
int32_t tally_scan_read(const TallyNeedles *line_needles, const TallyNeedles *history_needles,
                        const char *path, uint64_t offset, uint64_t budget_bytes,
                        uint64_t block_bytes, double since_reference, const uint8_t *since_key,
                        size_t since_key_len, TallyScanBlock *out);
void tally_scan_block_free(TallyScanBlock *block);
/// Build marker: the release script looks for this string in both CLI slices.
const char *tally_core_version(void);
#endif
