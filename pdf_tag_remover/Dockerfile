# Build stage
FROM rust:1.82-slim-bookworm as builder

WORKDIR /app

# Install build dependencies
RUN apt-get update && apt-get install -y \
    pkg-config \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# Copy manifests
COPY Cargo.toml ./

# Create dummy main.rs for dependency caching
RUN mkdir -p src && echo "fn main() {}" > src/main.rs

# Build dependencies only (for caching)
RUN cargo build --release && rm -rf src

# Copy actual source
COPY src ./src

# Build the actual application
RUN touch src/main.rs && cargo build --release

# Runtime stage
FROM debian:bookworm-slim

WORKDIR /app

# Install runtime dependencies
RUN apt-get update && apt-get install -y \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Copy the built binary
COPY --from=builder /app/target/release/pdf_tag_remover /app/pdf_tag_remover

# Set environment
ENV PORT=8081
ENV RUST_LOG=info

EXPOSE 8081

CMD ["/app/pdf_tag_remover"]
