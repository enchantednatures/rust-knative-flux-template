use sqlx::postgres::PgPoolOptions;
use std::time::Duration;

#[tokio::main]
async fn main() {
    let database_url = "postgresql://app:MULcae3rkwVldPKbgZaR8Pitwge3w99wL4CwlyeFkHZkLk3iCv8iBSHtg8YfLX3x@localhost:5432/app";
    
    println!("Attempting to connect to: {}", database_url);
    println!("Timeout: 5 seconds");
    
    match sqlx::postgres::PgPoolOptions::new()
        .max_connections(1)
        .acquire_timeout(Duration::from_secs(5))
        .connect(database_url)
        .await
    {
        Ok(pool) => {
            println!("✓ Connected successfully!");
            match sqlx::query("SELECT 1").fetch_one(&pool).await {
                Ok(_) => println!("✓ Query executed!"),
                Err(e) => println!("✗ Query failed: {}", e),
            }
        }
        Err(e) => {
            println!("✗ Connection failed: {}", e);
            println!("Error type: {}", std::any::type_name_of_val(&e));
        }
    }
}
