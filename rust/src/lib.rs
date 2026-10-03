//! C ABI of tally_core: reads one tick of a live transcript (`tally_scan_read`, scan.rs) and one
//! line off its bytes for the supervisor's scan (TallyCLI/TranscriptLineRust.swift). Every export runs inside `catch_unwind`, so a panic becomes
//! TALLY_ERR_PANIC instead of unwinding into Swift. Types mirror rust/include/tally_core.h.
//!
//! Only extraction lives here. Every decision about a line stays in Swift (`scanLine`), and the
//! needle strings come from Swift too (`LineNeedle.table`), so no transcript marker has two homes.

mod iso;
mod line;
mod scan;

use std::ffi::{c_char, CStr};
use std::panic::{catch_unwind, AssertUnwindSafe};

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

fn leak<T>(v: Vec<T>) -> (*mut T, usize) {
    let len = v.len();
    (Box::into_raw(v.into_boxed_slice()).cast(), len)
}

/// # Safety
/// `line_needles` and `history_needles` must come from `tally_needles_new`, `path` be a
/// NUL-terminated string, `since_key` valid for `since_key_len` bytes, `out` writable. A block
/// this returns 0 for must be released with `tally_scan_block_free`.
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn tally_scan_read(
    line_needles: *const TallyNeedles,
    history_needles: *const TallyNeedles,
    path: *const c_char,
    offset: u64,
    budget_bytes: u64,
    block_bytes: u64,
    since_reference: f64,
    since_key: *const u8,
    since_key_len: usize,
    out: *mut TallyScanBlock,
) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        if line_needles.is_null()
            || history_needles.is_null()
            || path.is_null()
            || out.is_null()
            || since_key.is_null()
        {
            return ERR_ARGS;
        }
        let history = unsafe { &*history_needles };
        // sidechain, type assistant, type user, then at least one full-path needle.
        if history.flags.len() < 4 {
            return ERR_ARGS;
        }
        let Ok(path) = unsafe { CStr::from_ptr(path) }.to_str() else { return ERR_ARGS };
        let key = unsafe { std::slice::from_raw_parts(since_key, since_key_len) };
        let since = scan::Since { reference: since_reference, key };
        let needles = unsafe { &*line_needles };
        let Ok(s) = scan::scan(path, offset, budget_bytes, block_bytes, needles, history, &since)
        else {
            return ERR_NOFILE;
        };
        let (bytes, bytes_len) = leak(s.bytes);
        let (lines, line_count) = leak(s.lines);
        unsafe {
            out.write(TallyScanBlock {
                start_offset: s.start,
                new_offset: s.new_offset,
                end: s.end,
                at_end: i32::from(s.at_end),
                truncated: i32::from(s.truncated),
                bytes,
                bytes_len,
                lines,
                line_count,
                tail: s.tail.unwrap_or_default(),
                has_tail: i32::from(s.tail.is_some()),
                reserved: 0,
            })
        };
        0
    }))
    .unwrap_or(ERR_PANIC)
}

/// # Safety
/// `block` must be one `tally_scan_read` filled (returned 0), or zeroed; freed at most once.
#[no_mangle]
pub unsafe extern "C" fn tally_scan_block_free(block: *mut TallyScanBlock) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        let Some(b) = (unsafe { block.as_mut() }) else { return };
        if !b.bytes.is_null() {
            drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(b.bytes, b.bytes_len)) });
        }
        if !b.lines.is_null() {
            drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(b.lines, b.line_count)) });
        }
        b.bytes = std::ptr::null_mut();
        b.lines = std::ptr::null_mut();
        b.bytes_len = 0;
        b.line_count = 0;
    }));
}

/// # Safety
/// `ptrs` and `lens` must be valid for `count` reads, and each `ptrs[i]` for `lens[i]` bytes.
#[no_mangle]
pub unsafe extern "C" fn tally_needles_new(
    ptrs: *const *const u8,
    lens: *const usize,
    count: usize,
) -> *mut TallyNeedles {
    catch_unwind(AssertUnwindSafe(|| {
        if ptrs.is_null() || lens.is_null() || count > 64 {
            return std::ptr::null_mut();
        }
        let ptrs = unsafe { std::slice::from_raw_parts(ptrs, count) };
        let lens = unsafe { std::slice::from_raw_parts(lens, count) };
        let mut needles = Vec::with_capacity(count);
        for (&ptr, &len) in ptrs.iter().zip(lens) {
            if ptr.is_null() || len == 0 {
                return std::ptr::null_mut();
            }
            needles.push(unsafe { std::slice::from_raw_parts(ptr, len) });
        }
        Box::into_raw(Box::new(TallyNeedles::new(&needles)))
    }))
    .unwrap_or(std::ptr::null_mut())
}

/// # Safety
/// `needles` must come from `tally_needles_new`, `line` be valid for `len` bytes, `out` writable.
#[no_mangle]
pub unsafe extern "C" fn tally_line_fields(
    needles: *const TallyNeedles,
    line: *const u8,
    len: usize,
    out: *mut TallyLineFields,
) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        if needles.is_null() || line.is_null() || out.is_null() {
            return ERR_ARGS;
        }
        let bytes = unsafe { std::slice::from_raw_parts(line, len) };
        #[cfg(feature = "panic-probe")]
        if bytes == b"__tally_panic_probe__" {
            panic!("panic-probe");
        }
        let fields = read_line(unsafe { &*needles }, bytes);
        unsafe { out.write(fields) };
        0
    }))
    .unwrap_or(ERR_PANIC)
}

#[no_mangle]
pub extern "C" fn tally_core_version() -> *const c_char {
    b"tally_core ctx-v1\0".as_ptr().cast()
}

#[cfg(test)]
mod abi {
    use super::*;
    use std::mem::{offset_of, size_of};

    // The same numbers tests/ctxrust/main.swift asserts with MemoryLayout.
    #[test]
    fn layout() {
        assert_eq!(size_of::<TallySpan>(), 16);
        assert_eq!(size_of::<TallyLineFields>(), 120);
        assert_eq!(offset_of!(TallyLineFields, context_tokens), 8);
        assert_eq!(offset_of!(TallyLineFields, ts_seconds), 16);
        assert_eq!(offset_of!(TallyLineFields, ts_millis), 24);
        assert_eq!(offset_of!(TallyLineFields, ts_kind), 28);
        assert_eq!(offset_of!(TallyLineFields, utf8_valid), 32);
        assert_eq!(offset_of!(TallyLineFields, ts_raw), 40);
        assert_eq!(offset_of!(TallyLineFields, uuid), 56);
        assert_eq!(offset_of!(TallyLineFields, parent_uuid), 72);
        assert_eq!(offset_of!(TallyLineFields, model), 88);
        assert_eq!(offset_of!(TallyLineFields, excerpt), 104);
        assert_eq!(size_of::<TallyScanLine>(), 144);
        assert_eq!(offset_of!(TallyScanLine, off), 120);
        assert_eq!(offset_of!(TallyScanLine, kind), 136);
        assert_eq!(size_of::<TallyScanBlock>(), 216);
        assert_eq!(offset_of!(TallyScanBlock, at_end), 24);
        assert_eq!(offset_of!(TallyScanBlock, bytes), 32);
        assert_eq!(offset_of!(TallyScanBlock, lines), 48);
        assert_eq!(offset_of!(TallyScanBlock, tail), 64);
        assert_eq!(offset_of!(TallyScanBlock, has_tail), 208);
    }

    #[test]
    fn rejects_bad_tables() {
        let a = b"x";
        let ptrs = [a.as_ptr()];
        let zero = [0usize];
        assert!(unsafe { tally_needles_new(ptrs.as_ptr(), zero.as_ptr(), 1) }.is_null());
        let many_p = vec![a.as_ptr(); 65];
        let many_l = vec![1usize; 65];
        assert!(unsafe { tally_needles_new(many_p.as_ptr(), many_l.as_ptr(), 65) }.is_null());
        let one = [1usize];
        let n = unsafe { tally_needles_new(ptrs.as_ptr(), one.as_ptr(), 1) };
        assert!(!n.is_null());
        let mut out = TallyLineFields::default();
        assert_eq!(unsafe { tally_line_fields(n, std::ptr::null(), 0, &mut out) }, ERR_ARGS);
        let line = b"axb";
        assert_eq!(unsafe { tally_line_fields(n, line.as_ptr(), 3, &mut out) }, 0);
        assert_eq!(out.present, 1);
    }
}
