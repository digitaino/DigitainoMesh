//
//  SurveyUploadService.swift
//  MC1
//
//  Created by Rafa Pesquera on 3/15/26.
//


Crowdsourced Signal Survey Map: iOS Upload + Web Server

 Context

 Build a system where PocketMesh iOS users can upload anonymized signal survey data to a self-hosted server, which
  displays an aggregated coverage heatmap on a web map. The server runs in Docker on an iMac Pro. Only
 authenticated PocketMesh clients can upload data.

 ---
 PLAN A: iOS Client Changes (for Claude in Xcode)

 Overview

 Add an "Upload to Community Map" button to the survey export flow. The app sends anonymized, grid-aggregated cell
  data to a REST API. Authentication uses an embedded API key that only the PocketMesh app knows.

 What exists today

 - SurveyExportService.swift (MC1/Services/SurveyExportService.swift): Already generates anonymized
 grid-aggregated JSON with CellData structs (cell center lat/lon, avg/min/max SNR, avg RSSI, packet count, route
 breakdown, time range). No contact names, no exact GPS, no device IDs.
 - SignalSurveyExportView.swift (MC1/Views/Tools/SignalSurvey/SignalSurveyExportView.swift): Export UI with
 ShareLink. Currently file-share only.
 - HexGrid.swift (MC1/Utilities/HexGrid.swift): Hex grid math (size=0.0005 degrees, ~100m cells, flat-top, axial
 coordinates with Mercator correction via referenceLatitude).
 - ElevationService.swift (MC1/Services/ElevationService.swift): Existing HTTP pattern using
 URLSession.shared.data(from:) with retry logic — good template for the upload service.
 - KeychainService.swift (MC1Services/Sources/MC1Services/Services/KeychainService.swift): Existing Keychain
 pattern for credential storage.

 Current export CellData format (from SurveyExportService.swift)

 {
   "latitude": 30.1234,
   "longitude": -97.5678,
   "averageSNR": 12.5,
   "averageRSSI": -85.0,
   "minSNR": 5.2,
   "maxSNR": 18.1,
   "packetCount": 7,
   "routeTypeBreakdown": { "flood": 5, "direct": 2 },
   "timeRange": { "earliest": "2026-03-15T10:30:00Z", "latest": "2026-03-15T10:45:00Z" }
 }

 Changes needed

 1. Enhance CellData for community upload

 Add fields the current export is missing but the server needs for aggregation:

 // In SurveyExportService.swift CellData struct, add:
 let repeaterHexIDs: [String]    // Repeater pubkey prefixes seen in this cell (already in
 GridCell.uniqueRelayNodes)
 let hexQ: Int                    // Axial hex coordinate q (for server-side cell merging)
 let hexR: Int                    // Axial hex coordinate r
 let referenceLatitude: Double    // Mercator correction reference (needed to reconstruct grid)

 The repeaterHexIDs are public key prefixes (3 bytes, e.g. "80 5D 8C") — not PII, they identify mesh
 infrastructure.

 Remove timeRange from community upload (not needed for aggregation, adds temporal fingerprinting risk). Keep it
 for local file export.

 2. Create SurveyUploadService

 New file: MC1/Services/SurveyUploadService.swift

 actor SurveyUploadService {
     // Server URL — hardcode for now, could be configurable later
     static let serverURL = URL(string: "https://mesh.digitaino.com/api/v1/survey")!

     // Embedded API key (compile-time, same for all clients)
     // This authenticates that the request comes from a genuine PocketMesh app
     static let apiKey = "YOUR_API_KEY_HERE"  // Generate a strong random key

     struct UploadPayload: Codable {
         let version: String           // Format version
         let contributorID: String     // Random UUID, generated once per app install, stored in Keychain
         let gridType: String          // "hex"
         let cellSizeDegrees: Double   // HexGrid.size
         let referenceLatitude: Double  // For Mercator correction
         let cells: [CellData]         // Anonymized cell data
     }

     struct UploadResponse: Codable {
         let accepted: Int             // Number of cells accepted
         let message: String?
     }

     func upload(sessionID: UUID, dataStore: PersistenceStore) async throws -> UploadResponse {
         // 1. Generate cell data (reuse SurveyExportService aggregation logic)
         // 2. Build UploadPayload
         // 3. POST to serverURL with:
         //    - Header: "X-API-Key: <apiKey>"
         //    - Header: "Content-Type: application/json"
         //    - Body: JSON-encoded UploadPayload
         // 4. Parse response
     }
 }

 Follow the ElevationService.swift pattern for URLSession usage, error handling, and retry logic.

 Contributor UUID

 Generate a random UUID on first upload attempt. Store it in Keychain using the existing KeychainService pattern
 (service: "com.pocketmesh.community", account: "contributorID"). Reuse on subsequent uploads. This is NOT the
 device's existing deviceID — it's a separate opaque identifier solely for community map data management. If the
 app is reinstalled, a new UUID is generated (old data can still be purged by old UUID via admin API).

 3. Update export UI

 In SignalSurveyExportView.swift, add an "Upload to Community Map" button alongside the existing ShareLink:

 Button("Upload to Community Map") {
     Task { await uploadToCommunity() }
 }
 .buttonStyle(.bordered)

 Add upload state tracking (isUploading, uploadResult, uploadError). Show success/failure feedback.

 4. API key storage

 Option A (simplest): Embed API key as a string constant in SurveyUploadService. It's compiled into the binary.
 Not perfect security but prevents casual abuse.

 Option B (better): Store in the app's Info.plist or xcconfig as a build setting, excluded from version control.

 The key is shared across all clients — it authenticates "this is the PocketMesh app" not "this is a specific
 user."

 5. Files to create/modify

 ┌───────────────────────────────────────────────────────────┬─────────────────────────────────────────────────┐
 │                           File                            │                     Action                      │
 ├───────────────────────────────────────────────────────────┼─────────────────────────────────────────────────┤
 │ MC1/Services/SurveyUploadService.swift                    │ CREATE — HTTP upload service                    │
 ├───────────────────────────────────────────────────────────┼─────────────────────────────────────────────────┤
 │                                                           │ MODIFY — Add repeaterHexIDs, hexQ, hexR,        │
 │ MC1/Services/SurveyExportService.swift                    │ referenceLatitude to CellData; extract shared   │
 │                                                           │ aggregation logic                               │
 ├───────────────────────────────────────────────────────────┼─────────────────────────────────────────────────┤
 │ MC1/Views/Tools/SignalSurvey/SignalSurveyExportView.swift │ MODIFY — Add upload button + state              │
 └───────────────────────────────────────────────────────────┴─────────────────────────────────────────────────┘

 ---
 PLAN B: Server Implementation (for Claude Code)

 Overview

 A lightweight REST API server with a web frontend that displays aggregated signal survey data on an interactive
 map. Runs in Docker on an iMac Pro. Accepts uploads only from authenticated PocketMesh clients.

 Tech stack

 - Backend: Swift (Vapor 4) — same language as iOS app, can share HexGrid code directly
 - Database: SQLite via Fluent ORM (FluentSQLiteDriver) — simple, no separate container needed
 - Web map: Leaflet.js with OpenStreetMap tiles — free, no API key needed, good hex polygon support
 - Docker: Single container (Swift runtime + SQLite + static frontend)
 - Consistency: Same HexGrid math in Swift on both client and server ensures hex cells line up exactly. Web
 frontend uses identical SNR color scale as the iOS app.

 API Design

 POST /api/v1/survey

 Upload anonymized cell data from the iOS app.

 Headers:
 X-API-Key: <shared_api_key>
 Content-Type: application/json

 Request body (from iOS UploadPayload):
 {
   "version": "1.1",
   "contributorID": "550e8400-e29b-41d4-a716-446655440000",
   "gridType": "hex",
   "cellSizeDegrees": 0.0005,
   "referenceLatitude": 30.0,
   "cells": [
     {
       "latitude": 30.1234,
       "longitude": -97.5678,
       "hexQ": 5,
       "hexR": -3,
       "averageSNR": 12.5,
       "averageRSSI": -85,
       "minSNR": 5.2,
       "maxSNR": 18.1,
       "packetCount": 7,
       "routeTypeBreakdown": { "flood": 5, "direct": 2 },
       "repeaterHexIDs": ["80 5D 8C", "A3 12 FF"]
     }
   ]
 }

 Response:
 { "accepted": 15, "message": "ok" }

 Auth: Reject with 401 if X-API-Key header missing or doesn't match server's configured key.

 Validation:
 - Max 10,000 cells per upload
 - Lat/lon within valid ranges
 - SNR within reasonable range (-30 to +30 dB)
 - Rate limit: 10 uploads per minute per IP

 GET /api/v1/cells

 Retrieve aggregated cell data for the web map.

 Query params:
 - minLat, maxLat, minLon, maxLon — bounding box (required)
 - limit — max cells to return (default 5000)

 Response:
 {
   "cells": [
     {
       "latitude": 30.1234,
       "longitude": -97.5678,
       "averageSNR": 11.8,
       "packetCount": 23,
       "contributionCount": 4,
       "repeaterHexIDs": ["80 5D 8C", "A3 12 FF"],
       "snrQuality": "excellent",
       "vertices": [[30.12, -97.56], [30.12, -97.57], ...]
     }
   ],
   "totalCells": 1523
 }

 No auth required (public read).

 GET /api/v1/stats

 Basic statistics for the dashboard.
 {
   "totalCells": 15234,
   "totalContributions": 89,
   "uniqueRepeaters": 47,
   "uniqueContributors": 12,
   "lastUpload": "2026-03-15T14:30:00Z"
 }

 DELETE /api/v1/contributor/{contributorID}

 Admin endpoint to purge all data from a specific contributor. Requires API key auth.

 Logic:
 1. Find all cell_contributions for this contributor
 2. For each affected cell: subtract this contributor's packet_count, snr_weighted, etc. from the cell totals
 3. If cell's total_packet_count reaches 0, delete the cell entirely
 4. Delete the contributor's contributions and upload log entries
 5. Return count of affected cells

 { "deleted_contributions": 23, "cells_removed": 5, "cells_updated": 18 }

 Database schema (SQLite)

 -- Aggregated cell data (one row per unique geographic cell)
 CREATE TABLE cells (
     id INTEGER PRIMARY KEY,
     -- Grid position (for merging overlapping uploads)
     hex_q INTEGER NOT NULL,
     hex_r INTEGER NOT NULL,
     reference_latitude REAL NOT NULL,
     -- Center coordinates (for quick bounding box queries)
     latitude REAL NOT NULL,
     longitude REAL NOT NULL,
     -- Aggregated signal metrics (weighted by packet count across contributions)
     total_snr_weighted REAL DEFAULT 0,     -- sum(avgSNR * packetCount) for running weighted average
     total_rssi_weighted REAL DEFAULT 0,
     total_packet_count INTEGER DEFAULT 0,  -- sum of all packet counts
     min_snr REAL,
     max_snr REAL,
     -- Routing stats
     flood_count INTEGER DEFAULT 0,
     direct_count INTEGER DEFAULT 0,
     -- Metadata
     contribution_count INTEGER DEFAULT 1,  -- number of uploads that contributed to this cell
     first_seen TEXT NOT NULL,
     last_updated TEXT NOT NULL,
     UNIQUE(hex_q, hex_r, reference_latitude)
 );

 -- Repeaters observed in each cell (many-to-many)
 CREATE TABLE cell_repeaters (
     cell_id INTEGER NOT NULL REFERENCES cells(id),
     repeater_hex_id TEXT NOT NULL,
     PRIMARY KEY (cell_id, repeater_hex_id)
 );

 -- Upload log (for rate limiting, audit, and contributor data deletion)
 CREATE TABLE uploads (
     id INTEGER PRIMARY KEY,
     contributor_id TEXT NOT NULL,    -- UUID from iOS app, for batch deletion
     uploaded_at TEXT NOT NULL,
     cell_count INTEGER NOT NULL,
     client_ip TEXT,
     accepted BOOLEAN DEFAULT 1
 );

 -- Contributor-to-cell mapping (tracks which contributor contributed to which cell)
 -- Enables purging a contributor's data without losing other contributors' data
 CREATE TABLE cell_contributions (
     id INTEGER PRIMARY KEY,
     cell_id INTEGER NOT NULL REFERENCES cells(id),
     contributor_id TEXT NOT NULL,
     packet_count INTEGER NOT NULL,       -- this contributor's packet count for this cell
     snr_weighted REAL NOT NULL,          -- this contributor's avgSNR * packetCount
     rssi_weighted REAL,
     flood_count INTEGER DEFAULT 0,
     direct_count INTEGER DEFAULT 0,
     contributed_at TEXT NOT NULL
 );

 -- Spatial index for bounding box queries
 CREATE INDEX idx_cells_location ON cells(latitude, longitude);

 Cell merging logic: When a new upload contains a cell with the same (hex_q, hex_r, reference_latitude) as an
 existing cell, merge by:
 - Incrementing contribution_count
 - Adding packetCount to total_packet_count
 - Updating weighted SNR/RSSI: total_snr_weighted += avgSNR * packetCount
 - Updating min_snr = min(existing.min_snr, new.minSNR), same for max
 - Merging repeaterHexIDs (union of sets)
 - Updating last_updated
 - Average SNR for display = total_snr_weighted / total_packet_count
 - Insert a cell_contributions row linking this cell to the contributor (stores their individual contribution for
 reversible deletion)

 Note on reference_latitude: Different users in different regions will use different reference latitudes. Cells
 are only mergeable if they share the same reference latitude (within tolerance, e.g., round to 1 decimal place).
 The server should normalize this.

 Web Frontend

 Single-page app served from the same container.

 Map (Leaflet.js + OpenStreetMap)

 - Full-screen map with hex cell overlays
 - Color cells by SNR quality (same scale as iOS app):
   - Excellent (>10 dB): green
   - Good (>5 dB): yellow
   - Fair (>0 dB): orange
   - Poor (>-10 dB): red
   - Very Poor: dark red
 - Cell opacity based on contribution count (more data = more opaque)
 - Click cell to show detail popup: avg SNR, packet count, contributions, repeaters
 - Repeater markers (antenna icon) at approximate locations (if derivable from cell data)
 - Auto-load cells for current map viewport via GET /api/v1/cells

 Stats sidebar

 - Total cells mapped
 - Total contributions
 - Unique repeaters seen
 - Last upload time

 Hex rendering in Leaflet

 Port the HexGrid.vertices() logic to JavaScript:
 function hexVertices(q, r, refLat, size = 0.0005) {
     const lonScale = Math.cos(refLat * Math.PI / 180);
     const scaledLon = size * 1.5 * q;
     const lat = size * Math.sqrt(3) * (r + q / 2);
     const lon = scaledLon / lonScale;

     return Array.from({length: 6}, (_, i) => {
         const angle = (60 * i) * Math.PI / 180;
         return [
             lat + size * Math.sin(angle),
             lon + (size * Math.cos(angle)) / lonScale
         ];
     });
 }

 Swift/Vapor project structure

 pocketmesh-survey-server/
 ├── Package.swift             # Vapor + Fluent + FluentSQLiteDriver
 ├── Dockerfile
 ├── docker-compose.yml
 ├── Sources/
 │   └── App/
 │       ├── entrypoint.swift  # @main entry point
 │       ├── configure.swift   # App configuration (DB, middleware, routes)
 │       ├── routes.swift      # API route registration
 │       ├── Controllers/
 │       │   └── SurveyController.swift   # POST /survey, GET /cells, GET /stats
 │       ├── Models/
 │       │   ├── CellModel.swift          # Fluent model for cells table
 │       │   ├── CellRepeater.swift       # Fluent model for cell_repeaters
 │       │   ├── UploadLog.swift          # Fluent model for uploads table
 │       │   └── DTOs.swift               # Codable request/response types (shared with iOS CellData format)
 │       ├── Migrations/
 │       │   └── CreateSchema.swift       # Initial DB migration
 │       ├── Middleware/
 │       │   └── APIKeyMiddleware.swift   # X-API-Key validation
 │       └── Utilities/
 │           └── HexGrid.swift            # Copied from iOS app (identical math, no CoreLocation dependency)
 ├── Public/                   # Static web frontend (served by Vapor's FileMiddleware)
 │   ├── index.html
 │   ├── app.js               # Leaflet map + API calls
 │   └── style.css
 └── data/                    # Mounted volume for SQLite DB persistence

 Package.swift

 // swift-tools-version:6.0
 import PackageDescription

 let package = Package(
     name: "pocketmesh-survey-server",
     platforms: [.macOS(.v14)],
     dependencies: [
         .package(url: "https://github.com/vapor/vapor.git", from: "4.99.0"),
         .package(url: "https://github.com/vapor/fluent.git", from: "4.11.0"),
         .package(url: "https://github.com/vapor/fluent-sqlite-driver.git", from: "4.7.0"),
     ],
     targets: [
         .executableTarget(
             name: "App",
             dependencies: [
                 .product(name: "Vapor", package: "vapor"),
                 .product(name: "Fluent", package: "fluent"),
                 .product(name: "FluentSQLiteDriver", package: "fluent-sqlite-driver"),
             ]
         ),
     ]
 )

 docker-compose.yml

 version: '3.8'
 services:
   survey-server:
     build: .
     ports:
       - "8420:8080"
     environment:
       - SURVEY_API_KEY=<generate_a_strong_random_key>
     volumes:
       - ./data:/app/data
     restart: unless-stopped

 Dockerfile

 # Build stage
 FROM swift:6.0-jammy AS build
 WORKDIR /build
 COPY Package.swift Package.resolved ./
 RUN swift package resolve
 COPY Sources/ Sources/
 COPY Public/ Public/
 RUN swift build -c release

 # Runtime stage
 FROM ubuntu:22.04
 RUN apt-get update && apt-get install -y libsqlite3-0 && rm -rf /var/lib/apt/lists/*
 WORKDIR /app
 COPY --from=build /build/.build/release/App .
 COPY --from=build /build/Public ./Public
 RUN mkdir -p /app/data
 EXPOSE 8080
 ENTRYPOINT ["./App", "serve", "--hostname", "0.0.0.0", "--port", "8080"]

 Shared HexGrid code

 Copy MC1/Utilities/HexGrid.swift into Sources/App/Utilities/HexGrid.swift with one change: remove the import
 CoreLocation and replace CLLocationCoordinate2D with a simple (latitude: Double, longitude: Double) tuple in the
 vertices() method. All math stays identical — this guarantees hex cells line up exactly between iOS and web.

 Authentication flow

 iOS App                           Server
   |                                 |
   |  POST /api/v1/survey            |
   |  X-API-Key: <shared_key>       |
   |  Body: { cells: [...] }        |
   |------------------------------->|
   |                                 |  1. Check X-API-Key header
   |                                 |  2. Validate against SURVEY_API_KEY env var
   |                                 |  3. If mismatch → 401 Unauthorized
   |                                 |  4. If match → validate + store cells
   |  { accepted: 15 }             |
   |<-------------------------------|

 The API key is:
 - Server side: Set via SURVEY_API_KEY environment variable in docker-compose.yml
 - Client side: Embedded in the compiled app binary as a string constant
 - Same key for all clients: Authenticates "this is PocketMesh" not a specific user
 - Rotation: Change the env var + ship an app update

 Privacy considerations

 All data uploaded is already anonymized by the export service:
 - Cell centers only (~100m resolution), not exact GPS
 - No contact names, device IDs, or session IDs
 - No message content
 - Repeater hex IDs are public infrastructure identifiers, not PII
 - No user accounts or tracking
 - Timestamps removed from community upload (only in local export)

 ---
 Verification

 iOS client

 1. Export a completed survey → verify JSON includes new fields (repeaterHexIDs, hexQ, hexR, referenceLatitude)
 2. Upload button → verify POST request sent with correct headers and body
 3. Test with wrong API key → should get 401
 4. Test with no network → should show error message gracefully

 Server

 1. docker-compose up --build → server builds Swift and starts on port 8420
 2. curl -X POST -H "X-API-Key: <key>" -H "Content-Type: application/json" -d @test.json
 http://localhost:8420/api/v1/survey → returns accepted count
 3. Open http://localhost:8420 → see Leaflet map with uploaded hex cells (same colors as iOS app)
 4. Upload same data twice → cells merge (contribution count increases, weighted averages update)
 5. POST without API key → 401
 6. POST with garbage data → validation error
 7. Verify hex cells on web map align with iOS app map at same coordinates


we should also be able to access the data from the ios client by pressing a button to show all the aggregate data without having to go to the website. hopefully we can reuse as most code as possible.
