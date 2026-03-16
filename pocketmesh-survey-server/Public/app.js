// MeshCore Community Map — Apple MapKit JS

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

// Hex grid math — renders hex polygon centered on actual GPS coordinates
const HEX_SIZE = 0.0005;

function hexVerticesAtCenter(centerLat, centerLon, refLat) {
    const lonScale = Math.cos(refLat * Math.PI / 180);

    const vertices = [];
    for (let i = 0; i < 6; i++) {
        const angle = (60 * i) * Math.PI / 180;
        vertices.push(
            new mapkit.Coordinate(
                centerLat + HEX_SIZE * Math.sin(angle),
                centerLon + (HEX_SIZE * Math.cos(angle)) / lonScale
            )
        );
    }
    return vertices;
}

// State
let map = null;
let currentOverlays = [];
let currentRepeaterAnnotations = [];
let loadingTimeout = null;

// MapKit JS initialization callback
function initMapKit() {
    mapkit.init({
        authorizationCallback: function(done) {
            // Fetch the MapKit JS token from the server
            fetch('/api/v1/mapkit-token')
                .then(res => res.text())
                .then(token => done(token))
                .catch(() => {
                    console.error('Failed to fetch MapKit JS token');
                });
        }
    });

    map = new mapkit.Map('map', {
        center: new mapkit.Coordinate(30.27, -97.74),
        cameraDistance: 15000,
        colorScheme: mapkit.Map.ColorSchemes.Dark,
        mapType: mapkit.Map.MapTypes.MutedStandard,
        showsCompass: mapkit.FeatureVisibility.Adaptive,
        showsZoomControl: true,
        showsMapTypeControl: false,
        isRotationEnabled: true,
        isZoomEnabled: true,
        isScrollEnabled: true
    });

    // Load cells and repeaters when map region changes
    map.addEventListener('region-change-end', function() {
        clearTimeout(loadingTimeout);
        loadingTimeout = setTimeout(() => {
            loadCells();
            loadRepeaters();
        }, 300);
    });

    // Handle overlay selection for popups
    map.addEventListener('select', function(event) {
        if (event.overlay && event.overlay._cellData) {
            showCellPopup(event.overlay._cellData);
        }
    });

    map.addEventListener('deselect', function() {
        dismissPopup();
    });

    // Initial load
    loadCells();
    loadRepeaters();
    loadStats();

    // Auto-refresh: cells and repeaters every 15s, stats every 60s
    setInterval(() => { loadCells(); loadRepeaters(); }, 15000);
    setInterval(loadStats, 60000);
}

// Load cells for current viewport
async function loadCells() {
    if (!map) return;

    const region = map.region;
    const center = region.center;
    const span = region.span;
    const minLat = center.latitude - span.latitudeDelta / 2;
    const maxLat = center.latitude + span.latitudeDelta / 2;
    const minLon = center.longitude - span.longitudeDelta / 2;
    const maxLon = center.longitude + span.longitudeDelta / 2;

    const params = new URLSearchParams({
        minLat: minLat,
        maxLat: maxLat,
        minLon: minLon,
        maxLon: maxLon,
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
    // Remove old overlays
    if (currentOverlays.length > 0) {
        map.removeOverlays(currentOverlays);
    }
    currentOverlays = [];

    const overlays = cells.map(cell => {
        const vertices = hexVerticesAtCenter(cell.latitude, cell.longitude, cell.referenceLatitude);
        const quality = cell.snrQuality || snrQuality(cell.averageSNR);
        const color = snrColor(quality);
        const opacity = 0.2 + 0.5 * Math.min(1, cell.contributionCount / 5);

        const style = new mapkit.Style({
            fillColor: color,
            fillOpacity: opacity,
            strokeColor: color,
            strokeOpacity: 0.6,
            lineWidth: 0.5
        });

        const polygon = new mapkit.PolygonOverlay(vertices, {
            style: style,
            enabled: true,
            visible: true
        });

        // Attach cell data for popup on select
        polygon._cellData = cell;
        polygon._quality = quality;
        polygon._color = color;

        return polygon;
    });

    if (overlays.length > 0) {
        map.addOverlays(overlays);
    }
    currentOverlays = overlays;
}

// Load repeaters for current viewport
async function loadRepeaters() {
    if (!map) return;

    const region = map.region;
    const center = region.center;
    const span = region.span;
    const minLat = center.latitude - span.latitudeDelta / 2;
    const maxLat = center.latitude + span.latitudeDelta / 2;
    const minLon = center.longitude - span.longitudeDelta / 2;
    const maxLon = center.longitude + span.longitudeDelta / 2;

    const params = new URLSearchParams({
        minLat: minLat,
        maxLat: maxLat,
        minLon: minLon,
        maxLon: maxLon
    });

    try {
        const response = await fetch(`${API_BASE}/repeaters?${params}`);
        if (!response.ok) return;
        const data = await response.json();
        renderRepeaters(data.repeaters);
    } catch (e) {
        console.error('Failed to load repeaters:', e);
    }
}

// Render repeater annotations on map
function renderRepeaters(repeaters) {
    // Remove old annotations
    if (currentRepeaterAnnotations.length > 0) {
        map.removeAnnotations(currentRepeaterAnnotations);
    }
    currentRepeaterAnnotations = [];

    const annotations = repeaters.map(repeater => {
        const coord = new mapkit.Coordinate(repeater.latitude, repeater.longitude);
        const annotation = new mapkit.MarkerAnnotation(coord, {
            title: repeater.name,
            subtitle: repeater.hexID,
            color: '#22d3ee',
            glyphText: '📡'
        });
        return annotation;
    });

    if (annotations.length > 0) {
        map.addAnnotations(annotations);
    }
    currentRepeaterAnnotations = annotations;
}

// Popup element
let popupElement = null;

function showCellPopup(cell) {
    dismissPopup();

    const quality = cell.snrQuality || snrQuality(cell.averageSNR);
    const color = snrColor(quality);
    const snrText = cell.averageSNR !== null && cell.averageSNR !== undefined
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

    popupElement = document.createElement('div');
    popupElement.className = 'cell-popup-overlay';
    popupElement.innerHTML = `
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
    `;

    popupElement.addEventListener('click', function(e) {
        e.stopPropagation();
        dismissPopup();
    });

    document.body.appendChild(popupElement);
}

function dismissPopup() {
    if (popupElement) {
        popupElement.remove();
        popupElement = null;
    }
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
