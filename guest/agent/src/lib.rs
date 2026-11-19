//! GpuVM guest agent (docs/agents/protocol.md). `proto` and `hv` are shared with the host-side lab harness.
pub mod util;
pub mod proto;
pub mod hv;
pub mod token;
pub mod secret;
pub mod session;
pub mod service;
pub mod capture;
pub mod display;
pub mod state;
pub mod input;
pub mod uia;
pub mod exec;
pub mod files;
pub mod helper;
