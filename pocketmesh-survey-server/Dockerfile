# Build stage
FROM swift:6.0-noble AS build
WORKDIR /build
COPY Package.swift Package.resolved ./
RUN swift package resolve
COPY Sources/ Sources/
COPY Public/ Public/
RUN swift build -c release && cp -a .build/release/App /tmp/App

# Runtime stage - use swift image to avoid apt-get (includes SQLite + Swift runtime)
FROM swift:6.0-noble-slim
WORKDIR /app
COPY --from=build /tmp/App .
COPY --from=build /build/Public ./Public
RUN mkdir -p /app/data
EXPOSE 8080
ENTRYPOINT ["./App", "serve", "--hostname", "0.0.0.0", "--port", "8080"]
