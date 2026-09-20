// Required so that sqlx::migrate! re-embeds migration files when they change.
fn main() {
    println!("cargo:rerun-if-changed=migrations");
}
