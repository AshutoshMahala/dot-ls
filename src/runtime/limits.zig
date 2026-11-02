//! Existing runtime admission budgets. Feature-format and wire limits stay below.
pub const source = 200 * 1024 * 1024;
pub const sources = 512 * 1024 * 1024;
pub const documents = 128;
pub const uri = 8192;
pub const pending_requests = 64;
pub const request_id = 8192;
pub const findings = 1000;
pub const completion_total = 128 * 1024 * 1024;
pub const references_total = 256 * 1024 * 1024;
pub const html_cache_total = 32 * 1024 * 1024;
pub const intake_priority = 64 * 1024;
pub const worker_stack = 512 * 1024;
pub fn admitsSource(text_bytes: usize, retained: usize, current: usize) bool {
    return text_bytes <= source and current <= sources and retained <= sources - current;
}
