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

// Quality level index (1-5) for signal bars
function qualityLevel(quality) {
    switch (quality) {
        case 'excellent': return 5;
        case 'good': return 4;
        case 'fair': return 3;
        case 'poor': return 2;
        case 'veryPoor': return 1;
        default: return 0;
    }
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

// Consolidate hex IDs — group IDs that are prefixes of each other, keep longest
function consolidateHexIDs(hexIDs) {
    const upper = hexIDs.map(id => id.toUpperCase());
    const result = [];
    for (const id of upper) {
        // Skip if a longer version already in result
        if (result.some(r => r.startsWith(id) && r.length > id.length)) continue;
        // Remove shorter prefixes from result
        for (let i = result.length - 1; i >= 0; i--) {
            if (id.startsWith(result[i]) && id.length > result[i].length) {
                result.splice(i, 1);
            }
        }
        if (!result.includes(id)) result.push(id);
    }
    return result;
}

// Coverage filter: 'all', 'active', 'passive'
let coverageFilter = 'all';

// Repeater filter: null means all repeaters, otherwise a hex ID string
let repeaterFilter = null;

// State
let map = null;
let currentOverlays = [];
let selectedHighlightOverlay = null;
let selectedCellData = null;
let currentRepeaterAnnotations = [];
let loadingTimeout = null;
let lastCellData = [];
let repeaterNames = {}; // hexID -> name mapping from repeater annotations

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
            selectCell(event.overlay, event.overlay._cellData);
        }
    });

    map.addEventListener('deselect', function() {
        deselectCell();
    });

    // Initial load
    loadCells();
    loadRepeaters();
    loadStats();

    // Auto-refresh: cells and repeaters every 15s, stats every 60s
    setInterval(() => { loadCells(); loadRepeaters(); }, 15000);
    setInterval(loadStats, 60000);
}

// Select a cell — highlight on map + show popup
function selectCell(overlay, cellData) {
    deselectCell();
    selectedCellData = cellData;

    // Add highlight overlay with white stroke
    const vertices = hexVerticesAtCenter(cellData.latitude, cellData.longitude, cellData.referenceLatitude);
    const highlightStyle = new mapkit.Style({
        fillColor: snrColor(cellData.snrQuality || snrQuality(cellData.averageSNR)),
        fillOpacity: 0.5,
        strokeColor: '#ffffff',
        strokeOpacity: 1.0,
        lineWidth: 3
    });
    selectedHighlightOverlay = new mapkit.PolygonOverlay(vertices, {
        style: highlightStyle,
        enabled: false,
        visible: true
    });
    map.addOverlay(selectedHighlightOverlay);

    showCellPopup(cellData);
}

// Deselect current cell
function deselectCell() {
    if (selectedHighlightOverlay) {
        map.removeOverlay(selectedHighlightOverlay);
        selectedHighlightOverlay = null;
    }
    selectedCellData = null;
    dismissPopup();
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
        lastCellData = data.cells;
        renderCells(data.cells);
        updateRepeaterDropdown(data.cells);
    } catch (e) {
        console.error('Failed to load cells:', e);
    }
}

// Apply coverage filter and re-render
function applyCoverageFilter(filter) {
    coverageFilter = filter;
    // Update button states
    document.querySelectorAll('.filter-btn').forEach(btn => {
        btn.classList.toggle('active', btn.dataset.filter === filter);
    });
    renderCells(lastCellData);
}

// Apply repeater filter and re-render
function applyRepeaterFilter(hexID) {
    repeaterFilter = hexID || null;
    renderCells(lastCellData);
}

// Update the repeater dropdown with available repeaters from cell data
function updateRepeaterDropdown(cells) {
    const select = document.getElementById('repeater-select');
    if (!select) return;

    // Collect all unique repeater hex IDs and consolidate prefixes
    const allIDs = [];
    cells.forEach(c => {
        if (c.repeaterHexIDs) {
            c.repeaterHexIDs.forEach(id => allIDs.push(id));
        }
    });

    const repeaters = consolidateHexIDs(allIDs).sort();

    // Preserve current selection
    const current = select.value;

    // Rebuild options
    select.innerHTML = '<option value="">All Repeaters</option>';
    repeaters.forEach(hexID => {
        const option = document.createElement('option');
        option.value = hexID;
        // Prefix-aware name lookup: check exact, then prefix matches
        const name = repeaterNames[hexID] || Object.entries(repeaterNames).find(([k, _]) => {
            const uk = k.toUpperCase(), uh = hexID.toUpperCase();
            return uk.startsWith(uh) || uh.startsWith(uk);
        })?.[1];
        option.textContent = name ? `${name} (${hexID})` : hexID;
        if (hexID === current || (current && hexID.toUpperCase().startsWith(current.toUpperCase()))) {
            option.selected = true;
        }
        select.appendChild(option);
    });

    // Update count label
    const countLabel = document.getElementById('repeater-count');
    if (countLabel) {
        countLabel.textContent = `${repeaters.length} found`;
    }
}

// Render hex cells on map
function renderCells(cells) {
    // Remove old overlays
    if (currentOverlays.length > 0) {
        map.removeOverlays(currentOverlays);
    }
    currentOverlays = [];

    // Also clear selection highlight if cells are reloaded
    if (selectedHighlightOverlay) {
        map.removeOverlay(selectedHighlightOverlay);
        selectedHighlightOverlay = null;
    }

    // Apply coverage filter
    let filtered = cells;
    if (coverageFilter === 'active') {
        filtered = cells.filter(c => c.activePacketCount && c.activePacketCount > 0);
    } else if (coverageFilter === 'passive') {
        filtered = cells.filter(c => c.passivePacketCount && c.passivePacketCount > 0);
    }

    // Apply repeater filter (prefix-aware: "0C" matches "0C13" and vice versa)
    if (repeaterFilter) {
        const rf = repeaterFilter.toUpperCase();
        filtered = filtered.filter(c => c.repeaterHexIDs && c.repeaterHexIDs.some(id => {
            const uid = id.toUpperCase();
            return uid === rf || uid.startsWith(rf) || rf.startsWith(uid);
        }));
    }

    const overlays = filtered.map(cell => {
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

    // Re-select the previously selected cell if it's still in the filtered set
    if (selectedCellData) {
        const key = `${selectedCellData.hexQ}_${selectedCellData.hexR}`;
        const match = filtered.find(c => `${c.hexQ}_${c.hexR}` === key);
        if (match) {
            selectCell(null, match);
        } else {
            selectedCellData = null;
            dismissPopup();
        }
    }
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

        // Build name lookup for repeater dropdown
        data.repeaters.forEach(r => {
            repeaterNames[r.hexID] = r.name;
        });

        // Refresh dropdown labels with names
        updateRepeaterDropdown(lastCellData);
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
    const level = qualityLevel(quality);
    const snrText = cell.averageSNR !== null && cell.averageSNR !== undefined
        ? cell.averageSNR.toFixed(1) + ' dB'
        : 'N/A';

    // Signal quality bars HTML
    let barsHTML = '<div class="signal-bar">';
    for (let i = 1; i <= 5; i++) {
        const filled = i <= level;
        const barColor = filled ? color : 'rgba(255,255,255,0.1)';
        barsHTML += `<div class="signal-segment" style="background:${barColor};height:${8 + i * 4}px;"></div>`;
    }
    barsHTML += '</div>';

    let repeatersHTML = '';
    if (cell.repeaterHexIDs && cell.repeaterHexIDs.length > 0) {
        repeatersHTML = `
            <div class="repeaters">
                <div class="detail-label">Repeaters:</div>
                ${cell.repeaterHexIDs.map(id => {
                    const name = repeaterNames[id];
                    const label = name ? `${name}` : id;
                    return `<span class="repeater-tag" onclick="event.stopPropagation(); applyRepeaterFilter('${id}'); document.getElementById('repeater-select').value='${id}';" title="Click to filter by this repeater">${label}</span>`;
                }).join('')}
            </div>
        `;
    }

    // Active/passive breakdown
    let modeHTML = '';
    const hasActive = cell.activePacketCount && cell.activePacketCount > 0;
    const hasPassive = cell.passivePacketCount && cell.passivePacketCount > 0;
    if (hasActive || hasPassive) {
        modeHTML = '<div class="detail-row">';
        if (hasActive) {
            modeHTML += `<span class="mode-tag mode-active">Active: ${cell.activePacketCount}</span>`;
        }
        if (hasPassive) {
            modeHTML += `<span class="mode-tag mode-passive">Passive: ${cell.passivePacketCount}</span>`;
        }
        modeHTML += '</div>';
    }

    popupElement = document.createElement('div');
    popupElement.className = 'cell-popup-overlay';
    popupElement.innerHTML = `
        <div class="cell-popup">
            <div class="popup-header">
                <h3 style="color: ${color}">Signal: ${quality}</h3>
                <button class="popup-close" onclick="event.stopPropagation(); deselectCell();">&times;</button>
            </div>
            ${barsHTML}
            <div class="detail-row">
                <span class="detail-label">Avg SNR</span>
                <span class="detail-value">${snrText}</span>
            </div>
            <div class="detail-row">
                <span class="detail-label">Packets</span>
                <span class="detail-value">${cell.packetCount.toLocaleString()}</span>
            </div>
            ${modeHTML}
            <div class="detail-row">
                <span class="detail-label">Contributions</span>
                <span class="detail-value">${cell.contributionCount}</span>
            </div>
            ${repeatersHTML}
        </div>
    `;

    popupElement.addEventListener('click', function(e) {
        e.stopPropagation();
        deselectCell();
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
