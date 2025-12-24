# Contributing Guide

Guide for contributing to example-app.

## Table of Contents

- [Getting Started](#getting-started)
- [Code of Conduct](#code-of-conduct)
- [Development Workflow](#development-workflow)
- [Pull Request Process](#pull-request-process)
- [Coding Standards](#coding-standards)
- [Testing Requirements](#testing-requirements)
- [Documentation](#documentation)

---

## Getting Started

### Fork and Clone

```bash
# Fork repository on GitHub
# Clone your fork
git clone https://github.com/YOUR_USERNAME/example-app.git
cd example-app

# Add upstream remote
git remote add upstream https://github.com/ORIGINAL_ORG/example-app.git
```

### Setup Development Environment

```bash
# Install Rust toolchain
rustup install stable
rustup default stable

# Install development tools
cargo install cargo-watch
cargo install cargo-edit
cargo install cargo-audit

# Start local services
docker-compose up -d

# Run tests
cargo test
```

---

## Code of Conduct

### Our Pledge

In the interest of fostering an open and welcoming environment, we as contributors and maintainers pledge to making participation in our project and our community a harassment-free experience for everyone.

### Our Standards

**Positive behavior**:
- Using welcoming and inclusive language
- Being respectful of differing viewpoints and experiences
- Gracefully accepting constructive criticism
- Focusing on what is best for the community
- Showing empathy towards other community members

**Unacceptable behavior**:
- Sexualized language or imagery
- Trolling or insulting comments
- Personal/political attacks
- Public or private harassment
- Publishing private information without permission
- Unprofessional conduct

### Reporting Issues

Report violations to: `security@example.com`

---

## Development Workflow

### Create a Branch

```bash
# Sync with upstream
git fetch upstream
git checkout main
git merge upstream/main

# Create feature branch
git checkout -b feature/my-feature

# Or bugfix branch
git checkout -b fix/issue-123
```

### Make Changes

```bash
# Make your changes
# ... edit files ...

# Format code
cargo fmt

# Run linter
cargo clippy -- -D warnings

# Run tests
cargo test
```

### Commit Changes

```bash
# Stage changes
git add .

# Commit with conventional message
git commit -m "feat: add new API endpoint"
```

**Commit Message Format**:
```
<type>(<scope>): <subject>

<body>

<footer>
```

Types:
- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation
- `style`: Code style
- `refactor`: Refactoring
- `test`: Test additions
- `chore`: Build/tooling

Examples:
```
feat(api): add user endpoint

Add GET /api/user/:id endpoint to retrieve user information.

Closes #123
```

### Sync and Push

```bash
# Sync with upstream
git fetch upstream
git rebase upstream/main

# Push to your fork
git push origin feature/my-feature
```

---

## Pull Request Process

### Create PR

```bash
# Push your branch
git push origin feature/my-feature

# Go to GitHub and create PR
# https://github.com/YOUR_USERNAME/example-app/compare/feature/my-feature
```

### PR Title Format

Same as commit message:
```
feat(api): add user endpoint
fix(storage): resolve S3 timeout
docs(api): update endpoint documentation
```

### PR Description

```markdown
## Description
Brief description of changes

## Type of Change
- [ ] Bug fix
- [ ] New feature
- [ ] Breaking change
- [ ] Documentation update

## Testing
- [ ] Unit tests added/updated
- [ ] Integration tests pass
- [ ] Manual testing performed

## Checklist
- [ ] Code follows style guidelines
- [ ] Self-review completed
- [ ] Comments added for complex logic
- [ ] Documentation updated
- [ ] No new warnings generated
- [ ] Tests added/updated
- [ ] All tests passing
```

### PR Review Process

1. **Automated Checks**:
   - CI/CD pipeline must pass
   - All tests must pass
   - Code formatting validated
   - Linting checks passed
   - Security audit passed

2. **Code Review**:
   - At least one maintainer approval required
   - Address review comments
   - Update PR as needed

3. **Merge**:
   - Squash merge to main branch
   - Maintainer merges
   - Automatic deletion of feature branch

### Updating PR

After review comments:

```bash
# Make changes
# ... edit files ...

# Commit changes
git add .
git commit -m "fix: address review comments"

# Rebase if needed
git rebase upstream/main

# Force push (rewrites history)
git push origin feature/my-feature --force
```

---

## Coding Standards

### Rust Style

Follow **Rust API Guidelines**:
```rust
// Good: Use Option<T> for optional values
pub fn get_user(id: &str) -> Option<User> {
    // ...
}

// Bad: Use null/empty values
pub fn get_user(id: &str) -> User {
    // ...
}
```

### Naming Conventions

- **Types**: `PascalCase` - `struct UserData {}`
- **Functions**: `snake_case` - `fn get_user_data() {}`
- **Constants**: `SCREAMING_SNAKE_CASE` - `const MAX_RETRIES: u32 = 3;`
- **Modules**: `snake_case` - `mod api_handlers {}`

### Error Handling

```rust
// Use Result<T, E> for fallible operations
pub fn read_file(path: &str) -> Result<String, io::Error> {
    fs::read_to_string(path)
}

// Use ? for propagation
pub fn process_file(path: &str) -> Result<(), io::Error> {
    let content = fs::read_to_string(path)?;
    // ...
    Ok(())
}

// Use custom error type
#[derive(Debug, thiserror::Error)]
pub enum AppError {
    #[error("Not found: {0}")]
    NotFound(String),
    
    #[error("Internal error: {0}")]
    Internal(#[from] io::Error),
}
```

### Documentation

```rust
/// Uploads a file to S3 storage
///
/// # Arguments
///
/// * `key` - The object key in the bucket
/// * `data` - Binary data to upload
///
/// # Returns
///
/// Returns `Ok(())` on success, `Err(AppError)` on failure
///
/// # Example
///
/// ```ignore
/// let result = upload_file("test.txt", b"hello").await;
/// ```
pub async fn upload_file(key: &str, data: &[u8]) -> Result<(), AppError> {
    // ...
}
```

### Comments

```rust
// Good: Explain WHY, not WHAT
// Use exponential backoff to avoid overwhelming S3
let delay = 2u64.pow(retry_count);

// Bad: Restates code
// Set delay to 2^retry_count
let delay = 2u64.pow(retry_count);
```

---

## Testing Requirements

### Unit Tests

```rust
#[cfg(test)]
mod tests {
    use super::*;
    
    #[test]
    fn test_function() {
        assert_eq!(add(2, 2), 4);
    }
    
    #[tokio::test]
    async fn test_async_function() {
        let result = async_function().await;
        assert!(result.is_ok());
    }
}
```

### Integration Tests

```rust
#[tokio::test]
#[ignore]  // Ignored by default
async fn test_endpoint() {
    let client = Client::new();
    let response = client.get("http://localhost:8080/health/live")
        .send()
        .await
        .expect("Request failed");
    
    assert_eq!(response.status(), 200);
}
```

### Test Coverage

```bash
# Generate coverage
cargo tarpaulin --out Html

# View coverage
open tarpaulin-report.html

# Required coverage:
# - New code: > 80%
# - Modified code: > 80%
```

---

## Documentation

### Code Documentation

- Document all public APIs
- Include examples
- Explain edge cases
- Link to related functions

### README Updates

Update `README.md` for:
- New features
- Configuration changes
- API changes
- Breaking changes

### API Documentation

Update `docs/API.md` for:
- New endpoints
- Modified endpoints
- Removed endpoints

### Changelog

Add entry to `CHANGELOG.md` for:
- User-facing changes
- API changes
- Breaking changes
- Security fixes

---

## Getting Help

### Questions

- **Slack/Discord**: Community channel
- **GitHub Issues**: Use `question` label
- **Email**: `help@example.com`

### Bug Reports

1. Check existing issues
2. Create new issue with:
   - Description
   - Steps to reproduce
   - Expected behavior
   - Actual behavior
   - Environment details
   - Logs/error messages

### Feature Requests

1. Check existing requests
2. Create issue with:
   - Use case
   - Proposed solution
   - Alternatives considered

---

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](../LICENSE).

---

## Additional Resources

- [Rust API Guidelines](https://rust-lang.github.io/api-guidelines/)
- [Conventional Commits](https://www.conventionalcommits.org/)
- [Semantic Versioning](https://semver.org/)
- [Keep a Changelog](https://keepachangelog.com/)
- [Code Review Checklist](https://github.com/kubernetes/community/blob/master/contributors/guide/codereviews.md)
