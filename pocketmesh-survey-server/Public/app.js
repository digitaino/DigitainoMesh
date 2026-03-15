// PocketMesh Community Signal Map

const API_BASE = '/api/v1';

// SNR quality colors — matches iOS app
function snrColor(quality) {
    switch (quality) {
        case 'excellent': return '#22c55e';
        case 'good': return '#eab308';
        case 'fair': return '#f97316';
        case 'poor': return '#ef4444';
        case 'veryPoor': return '#991b1b';
        default: return '#666666';
    }
}

// SNR quality from value — matches iOS app thresholds
function snrQuality(snr) {
    if (snr === null || snr === undefined) return 'unknown';
    if (snr > 10) return 'excellent';
    if (snr > 5) return 'good';
    if (snr > 0) return 'fair';
    if (snr > -10) return 'poor';
    return 'veryPoor';
}

// Hex grid math — matches iOS HexGrid.swift exactly
const HEX_SIZE = 0.0005;

function hexVertices(q, r, refLat) {
    const lonScale = Math.cos(refLat * Math.PI / 180);
    const scaledLon = HEX_SIZE * 1.5 * q;
    const lat = HEX_SIZE * Math.sqrt(3) * (r + q / 2);
    const lon = scaledLon / lonScale;

    const vertices = [];
    for (let i = 0; i < 6; i++) {
        const angle = (60 * i) * Math.PI / 180;
        vertices.push([
            lat + HEX_SIZE * Math.sin(angle),
            lon + (HEX_SIZE * Math.cos(angle)) / lonScale
        ]);
    }
    return vertices;
}

// Initialize map
const map = L.map('map', {
    center: [30.27, -97.74], // Austin, TX default
    zoom: 13,
    zoomControl: true,
    attributionControl: true
});

// Dark tile layer
L.tileLayer('https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png', {
    attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OSM</a> &copy; <a href="https://carto.com/">CARTO</a>',
    subdomains: 'abcd',
    maxZoom: 20
}).addTo(map);

// Layer for hex cells
let cellLayer = L.layerGroup().addTo(map);
let loadingTimeout = null;

// Load cells for current viewport
async function loadCells() {
    const bounds = map.getBounds();
    const params = new URLSearchParams({
        minLat: bounds.getSouth(),
        maxLat: bounds.getNorth(),
        minLon: bounds.getWest(),
        maxLon: bounds.getEast(),
        limit: 5000
    });

    try {
        const response = await fetch(`${API_BASE}/cells?${params}`);
        if (!response.ok) return;
        const data = await response.json();
        renderCells(data.cells);
    } catch (e) {
        console.error('Failed to load cells:', e);
    }
}

// Render hex cells on map
function renderCells(cells) {
    cellLayer.clearLayers();

    cells.forEach(cell => {
        const vertices = hexVertices(cell.hexQ, cell.hexR, cell.referenceLatitude);
        const quality = cell.snrQuality || snrQuality(cell.averageSNR);
        const color = snrColor(quality);
        const opacity = 0.2 + 0.5 * Math.min(1, cell.contributionCount / 5);

        const polygon = L.polygon(vertices, {
            color: color,
            weight: 0.5,
            opacity: 0.6,
            fillColor: color,
            fillOpacity: opacity
        });

        // Popup on click
        polygon.on('click', () => {
            const snrText = cell.averageSNR !== null
                ? cell.averageSNR.toFixed(1) + ' dB'
                : 'N/A';

            let repeatersHTML = '';
            if (cell.repeaterHexIDs && cell.repeaterHexIDs.length > 0) {
                repeatersHTML = `
                    <div class="repeaters">
                        <div class="detail-label">Repeaters:</div>
                        ${cell.repeaterHexIDs.map(id =>
                            `<span class="repeater-tag">${id}</span>`
                        ).join('')}
                    </div>
                `;
            }

            const popup = L.popup()
                .setLatLng([cell.latitude, cell.longitude])
                .setContent(`
                    <div class="cell-popup">
                        <h3 style="color: ${color}">Signal: ${quality}</h3>
                        <div class="detail-row">
                            <span class="detail-label">Avg SNR</span>
                            <span class="detail-value">${snrText}</span>
                        </div>
                        <div class="detail-row">
                            <span class="detail-label">Packets</span>
                            <span class="detail-value">${cell.packetCount.toLocaleString()}</span>
                        </div>
                        <div class="detail-row">
                            <span class="detail-label">Contributions</span>
                            <span class="detail-value">${cell.contributionCount}</span>
                        </div>
                        ${repeatersHTML}
                    </div>
                `);

            popup.openOn(map);
        });

        cellLayer.addLayer(polygon);
    });
}

// Load stats
async function loadStats() {
    try {
        const response = await fetch(`${API_BASE}/stats`);
        if (!response.ok) return;
        const stats = await response.json();

        document.getElementById('stat-cells').textContent =
            stats.totalCells.toLocaleString();
        document.getElementById('stat-uploads').textContent =
            stats.totalContributions.toLocaleString();
        document.getElementById('stat-repeaters').textContent =
            stats.uniqueRepeaters.toLocaleString();
        document.getElementById('stat-contributors').textContent =
            stats.uniqueContributors.toLocaleString();

        if (stats.lastUpload) {
            const date = new Date(stats.lastUpload);
            document.getElementById('stat-last-upload').textContent =
                `Last upload: ${date.toLocaleString()}`;
        }
    } catch (e) {
        console.error('Failed to load stats:', e);
    }
}

// Debounced cell loading on map move
map.on('moveend', () => {
    clearTimeout(loadingTimeout);
    loadingTimeout = setTimeout(loadCells, 300);
});

// Initial load
loadCells();
loadStats();

// Refresh stats periodically
setInterval(loadStats, 60000);
