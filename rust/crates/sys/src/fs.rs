//! Filesystem predicates whose answer depends on the platform: what Foundation calls hidden, and
//! how it spells a resolved path. The token statistics walk (tally_core::tokenstats) has to agree
//! with the Swift engine it replaced on both.
use std::ffi::OsStr;
use std::fs::Metadata;

/// Whether a directory entry is hidden the way FileManager's `.skipsHiddenFiles` means it: a
/// leading dot, or the platform's own hidden flag. `meta` must not follow symlinks
/// (`DirEntry::metadata`), so a link is judged by itself.
pub fn is_hidden(name: &OsStr, meta: &Metadata) -> bool {
    name.as_encoded_bytes().first() == Some(&b'.') || flag_hidden(meta)
}

#[cfg(target_os = "macos")]
fn flag_hidden(meta: &Metadata) -> bool {
    use std::os::macos::fs::MetadataExt;
    const UF_HIDDEN: u32 = 0x8000;
    meta.st_flags() & UF_HIDDEN != 0
}

#[cfg(windows)]
fn flag_hidden(meta: &Metadata) -> bool {
    use std::os::windows::fs::MetadataExt;
    const FILE_ATTRIBUTE_HIDDEN: u32 = 0x2;
    meta.file_attributes() & FILE_ATTRIBUTE_HIDDEN != 0
}

#[cfg(not(any(target_os = "macos", windows)))]
fn flag_hidden(_meta: &Metadata) -> bool {
    false
}

/// `realpath(3)`, or the path unchanged when it does not resolve.
pub fn realpath_or_same(path: &str) -> String {
    match std::fs::canonicalize(path) {
        Ok(p) => p.to_string_lossy().into_owned(),
        Err(_) => path.to_string(),
    }
}

/// `URL.resolvingSymlinksInPath()`: the resolved path, with a leading `/private` dropped on macOS
/// when the path without it exists. A path that does not resolve comes back unchanged.
pub fn resolve_like_foundation(path: &str) -> String {
    let resolved = realpath_or_same(path);
    if cfg!(target_os = "macos") {
        if let Some(rest) = resolved.strip_prefix("/private") {
            if rest.starts_with('/') && std::path::Path::new(rest).exists() {
                return rest.to_string();
            }
        }
    }
    resolved
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dot_names_are_hidden() {
        let meta = std::fs::metadata(".").unwrap();
        assert!(is_hidden(OsStr::new(".DS_Store"), &meta));
        assert!(!is_hidden(OsStr::new("a.jsonl"), &meta));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn the_hidden_flag_hides_a_plain_name() {
        let dir = std::env::temp_dir().join(format!("tally-sys-hidden-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("plain.jsonl");
        std::fs::write(&file, b"x").unwrap();
        assert!(!is_hidden(OsStr::new("plain.jsonl"), &std::fs::symlink_metadata(&file).unwrap()));
        let ok = std::process::Command::new("chflags").arg("hidden").arg(&file).status().unwrap();
        assert!(ok.success());
        assert!(is_hidden(OsStr::new("plain.jsonl"), &std::fs::symlink_metadata(&file).unwrap()));
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn private_tmp_resolves_to_tmp_like_foundation() {
        assert_eq!(resolve_like_foundation("/tmp"), "/tmp");
        assert_eq!(realpath_or_same("/tmp"), "/private/tmp");
        assert_eq!(resolve_like_foundation("/no/such/dir"), "/no/such/dir");
    }
}
