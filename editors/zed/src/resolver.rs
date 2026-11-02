//! Managed native binaries live in Zed's extension work directory, not a worktree.
use std::{
    fs,
    io::Read,
    path::{Path, PathBuf},
};

pub const VERSION: &str = "0.0.1";
pub const REPOSITORY: &str = "AshutoshMahala/dot-ls";
pub const TARGETS: [&str; 4] = [
    "aarch64-macos",
    "x86_64-macos",
    "aarch64-linux-musl",
    "x86_64-linux-musl",
];

pub fn asset(target: &str) -> Result<String, String> {
    if !TARGETS.contains(&target) {
        return Err(format!("dot-ls has no packaged binary for {target}. Supported systems: macOS and Linux, ARM64 and x86-64."));
    }
    Ok(format!("dot-ls-{VERSION}-{target}.tar.gz"))
}

pub fn valid_binary(path: &Path, target: &str) -> Result<(), String> {
    let mut header = [0; 32];
    fs::File::open(path)
        .and_then(|mut f| f.read_exact(&mut header))
        .map_err(|e| format!("Cannot read dot-ls at {}: {e}", path.display()))?;
    let valid = match target {
        "aarch64-macos" => header[..8] == [0xcf, 0xfa, 0xed, 0xfe, 12, 0, 0, 1],
        "x86_64-macos" => header[..8] == [0xcf, 0xfa, 0xed, 0xfe, 7, 0, 0, 1],
        "aarch64-linux-musl" => {
            header[..6] == [127, b'E', b'L', b'F', 2, 1] && header[18..20] == [183, 0]
        }
        "x86_64-linux-musl" => {
            header[..6] == [127, b'E', b'L', b'F', 2, 1] && header[18..20] == [62, 0]
        }
        _ => false,
    };
    if valid {
        Ok(())
    } else {
        Err(format!(
            "Invalid dot-ls binary for {target}: {}",
            path.display()
        ))
    }
}

/// A valid versioned cache is entirely offline. Downloads stage separately;
/// failures never install a partial binary or erase a working cached version.
pub fn managed(
    root: &Path,
    target: &str,
    download: impl FnOnce(&str, &Path) -> Result<(), String>,
) -> Result<PathBuf, String> {
    let name = asset(target)?;
    let directory = root.join(format!("dot-ls-{VERSION}-{target}"));
    let binary = directory.join("dot-ls");
    if directory.exists() {
        valid_binary(&binary, target)?;
        return Ok(binary);
    }
    let stage = root.join(format!(".dot-ls-{VERSION}-{target}.partial"));
    if stage.exists() {
        fs::remove_dir_all(&stage).map_err(|e| e.to_string())?;
    }
    fs::create_dir_all(&stage).map_err(|e| e.to_string())?;
    let result = download(&name, &stage)
        .and_then(|()| valid_binary(&stage.join("dot-ls"), target))
        .and_then(|()| fs::rename(&stage, &directory).map_err(|e| e.to_string()));
    if let Err(e) = result {
        let _ = fs::remove_dir_all(&stage);
        return Err(e);
    }
    Ok(binary)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    static NEXT: AtomicUsize = AtomicUsize::new(0);
    struct Temporary(PathBuf);
    impl Temporary {
        fn new() -> Self {
            let p = std::env::temp_dir().join(format!(
                "dot-ls-resolver-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir_all(&p).unwrap();
            Self(p)
        }
    }
    impl Drop for Temporary {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    fn mac(path: &Path) {
        let mut bytes = [0; 32];
        bytes[..8].copy_from_slice(&[0xcf, 0xfa, 0xed, 0xfe, 12, 0, 0, 1]);
        fs::write(path.join("dot-ls"), bytes).unwrap();
    }
    #[test]
    fn cache_is_offline_and_does_not_use_project_paths() {
        let t = Temporary::new();
        let first = managed(&t.0, "aarch64-macos", |name, dir| {
            assert_eq!(name, "dot-ls-0.0.1-aarch64-macos.tar.gz");
            mac(dir);
            Ok(())
        })
        .unwrap();
        let second = managed(&t.0, "aarch64-macos", |_, _| {
            panic!("warm cache must not use network")
        })
        .unwrap();
        assert_eq!(first, second);
    }
    #[test]
    fn failed_and_wrong_arch_downloads_leave_no_cache() {
        let t = Temporary::new();
        assert!(managed(&t.0, "aarch64-macos", |_, dir| {
            mac(dir);
            Err("interrupted".into())
        })
        .is_err());
        assert!(fs::read_dir(&t.0).unwrap().next().is_none());
        assert!(managed(&t.0, "x86_64-macos", |_, dir| {
            mac(dir);
            Ok(())
        })
        .is_err());
        assert!(fs::read_dir(&t.0).unwrap().next().is_none());
    }
    #[test]
    fn unsupported_and_corrupt_cache_are_explicit_errors() {
        assert!(asset("x86_64-windows").is_err());
        let t = Temporary::new();
        fs::create_dir(t.0.join("dot-ls-0.0.1-aarch64-macos")).unwrap();
        assert!(managed(&t.0, "aarch64-macos", |_, _| panic!(
            "do not silently replace a corrupt cache"
        ))
        .is_err());
    }
}
