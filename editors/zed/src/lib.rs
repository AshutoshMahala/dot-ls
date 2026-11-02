use zed::settings::LspSettings;
use zed_extension_api::{self as zed, LanguageServerId, Worktree};
mod resolver;

struct Dotls;

impl zed::Extension for Dotls {
    fn new() -> Self {
        Self
    }

    fn language_server_command(
        &mut self,
        language_server_id: &LanguageServerId,
        worktree: &Worktree,
    ) -> zed::Result<zed::Command> {
        let binary = LspSettings::for_worktree(language_server_id.as_ref(), worktree)?.binary;
        let local = binary
            .as_ref()
            .and_then(|binary| binary.path.clone())
            .or_else(|| worktree.which("dot-ls"))
            .or_else(|| worktree.which("dotls"));
        let command = if let Some(path) = local {
            if path.trim().is_empty() {
                return Err("The configured dot-ls binary path is empty.".into());
            }
            path
        } else {
            let (os, arch) = zed::current_platform();
            let target = match (os, arch) {
                (zed::Os::Mac, zed::Architecture::Aarch64) => "aarch64-macos",
                (zed::Os::Mac, zed::Architecture::X8664) => "x86_64-macos",
                (zed::Os::Linux, zed::Architecture::Aarch64) => "aarch64-linux-musl",
                (zed::Os::Linux, zed::Architecture::X8664) => "x86_64-linux-musl",
                _ => return Err("Packaged dot-ls supports macOS and Linux on ARM64 and x86-64. Windows is not supported yet.".into()),
            };
            let root = std::env::current_dir().map_err(|e| e.to_string())?;
            let managed = resolver::managed(&root, target, |name, stage| {
                zed::set_language_server_installation_status(
                    language_server_id,
                    &zed::LanguageServerInstallationStatus::CheckingForUpdate,
                );
                let release = zed::github_release_by_tag_name(
                    resolver::REPOSITORY,
                    &format!("v{}", resolver::VERSION),
                )?;
                let asset = release
                    .assets
                    .iter()
                    .find(|a| a.name == name)
                    .ok_or_else(|| format!("Release v{} has no asset {name}", resolver::VERSION))?;
                zed::set_language_server_installation_status(
                    language_server_id,
                    &zed::LanguageServerInstallationStatus::Downloading,
                );
                zed::download_file(
                    &asset.download_url,
                    stage.to_str().ok_or("Invalid cache path")?,
                    zed::DownloadedFileType::GzipTar,
                )?;
                zed::make_file_executable(
                    stage.join("dot-ls").to_str().ok_or("Invalid binary path")?,
                )
            });
            match managed {
                Ok(path) => {
                    zed::set_language_server_installation_status(
                        language_server_id,
                        &zed::LanguageServerInstallationStatus::None,
                    );
                    path.to_string_lossy().into_owned()
                }
                Err(error) => {
                    let error = format!("Cannot install dot-ls: {error}. For an offline install, set lsp.dotls.binary.path to an extracted release binary.");
                    zed::set_language_server_installation_status(
                        language_server_id,
                        &zed::LanguageServerInstallationStatus::Failed(error.clone()),
                    );
                    return Err(error);
                }
            }
        };
        let args = binary
            .as_ref()
            .and_then(|binary| binary.arguments.clone())
            .unwrap_or_else(|| vec!["lsp".into()]);
        let env = binary
            .and_then(|binary| binary.env)
            .unwrap_or_default()
            .into_iter()
            .collect();
        Ok(zed::Command { command, args, env })
    }
}

zed::register_extension!(Dotls);
