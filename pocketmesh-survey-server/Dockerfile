# Build stage
FROM swift:6.0-noble AS build
WORKDIR /build
COPY Package.swift Package.resolved ./
RUN swift package resolve
COPY Sources/ Sources/
COPY Public/ Public/
RUN swift build -c release

# Runtime stage
FROM ubuntu:24.04
RUN apt-get update && apt-get install -y libsqlite3-0 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /build/.build/release/App .
COPY --from=build /build/Public ./Public
RUN mkdir -p /app/data
EXPOSE 8080
ENTRYPOINT ["./App", "serve", "--hostname", "0.0.0.0", "--port", "8080"]
