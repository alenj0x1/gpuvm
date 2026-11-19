//! `gpuvm.exe --mcp`: GpuVM's MCP server, started by an agent client (Claude Code: `claude mcp add gpuvm --
//! "C:\Program Files\GpuVM\gpuvm.exe" --mcp`). It is the installed gpuvm.exe, so the GpuVM service trusts its
//! pipe connection like the app's; every action goes through the service's agent broker, which owns the
//! policy (machines taken, pause, budgets, kill switch, approvals) and the audit log.

pub mod broker;
pub mod fake;
pub mod geometry;
pub mod server;
pub mod tools;

#[cfg(test)]
mod tests;

pub use server::run;
