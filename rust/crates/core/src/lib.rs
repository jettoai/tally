//! Transcript extraction shared by every Rust layer: reads one tick of a live transcript (scan.rs)
//! and one line off its bytes (line.rs). The C ABI over it lives in tally_ffi; the types here are
//! `repr(C)` because that crate hands them across it unchanged (rust/include/tally_core.h).

mod iso;
mod line;
pub mod scan;

pub use line::{read_line, TallyNeedles};

pub const ERR_PANIC: i32 = -1;
pub const ERR_ARGS: i32 = -2;
pub const ERR_NOFILE: i32 = -3;
pub const TS_NONE: i32 = 0;
pub const TS_PARSED: i32 = 1;
pub const TS_RAW: i32 = 2;

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TallySpan {
    pub off: i64,
    pub len: i64,
}

impl TallySpan {
    pub const ABSENT: TallySpan = TallySpan { off: 0, len: -1 };
}

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TallyLineFields {
    pub present: u64,
    pub context_tokens: i64,
    pub ts_seconds: i64,
    pub ts_millis: i32,
    pub ts_kind: i32,
    pub utf8_valid: i32,
    pub reserved: i32,
    pub ts_raw: TallySpan,
    pub uuid: TallySpan,
    pub parent_uuid: TallySpan,
    pub model: TallySpan,
    pub excerpt: TallySpan,
}

impl Default for TallyLineFields {
    fn default() -> Self {
        TallyLineFields {
            present: 0,
            context_tokens: -1,
            ts_seconds: 0,
            ts_millis: 0,
            ts_kind: TS_NONE,
            utf8_valid: 0,
            reserved: 0,
            ts_raw: TallySpan::ABSENT,
            uuid: TallySpan::ABSENT,
            parent_uuid: TallySpan::ABSENT,
            model: TallySpan::ABSENT,
            excerpt: TallySpan::ABSENT,
        }
    }
}

/// One line of a scan: its fields (spans relative to the line), where it sits in the block's
/// bytes, and its `LINE_*` kind bits (scan.rs).
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct TallyScanLine {
    pub fields: TallyLineFields,
    pub off: i64,
    pub len: i64,
    pub kind: u32,
    pub reserved: i32,
}

#[repr(C)]
#[derive(Debug)]
pub struct TallyScanBlock {
    pub start_offset: u64,
    pub new_offset: u64,
    pub end: u64,
    pub at_end: i32,
    pub truncated: i32,
    pub bytes: *mut u8,
    pub bytes_len: usize,
    pub lines: *mut TallyScanLine,
    pub line_count: usize,
    pub tail: TallyScanLine,
    pub has_tail: i32,
    pub reserved: i32,
}
