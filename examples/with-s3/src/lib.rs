pub mod config;
pub mod error;
pub mod handlers;
pub mod observability;
pub mod routes;
pub mod state;


// Re-export OpenDAL Operator for storage operations
pub use opendal::Operator;

