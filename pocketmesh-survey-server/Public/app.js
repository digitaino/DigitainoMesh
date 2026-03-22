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

// Format a Date as relative time ago (e.g. "3h ago", "2d ago")
function formatTimeAgo(date) {
    const now = Date.now();
    const diff = now - date.getTime();
    const seconds = Math.floor(diff / 1000);
    if (seconds < 60) return 'just now';
    const minutes = Math.floor(seconds / 60);
    if (minutes < 60) return `${minutes}m ago`;
    const hours = Math.floor(minutes / 60);
    if (hours < 24) return `${hours}h ago`;
    const days = Math.floor(hours / 24);
    if (days < 30) return `${days}d ago`;
    const months = Math.floor(days / 30);
    if (months < 12) return `${months}mo ago`;
    return `${Math.floor(months / 12)}y ago`;
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

// Time filter: 'all', '1h', '1d', '1w', '1m'
let timeFilter = 'all';

// Repeater filter: null means all repeaters, otherwise a hex ID string
let repeaterFilter = null;

// State
let map = null;
let currentOverlays = [];
let currentOverlaysByKey = {}; // hexQ_hexR -> overlay, for diff-based updates
let selectedHighlightOverlay = null;
let selectedCellData = null;
let currentRepeaterAnnotations = [];
let currentRepeatersByHex = {}; // hexID -> annotation, for diff-based updates
let loadingTimeout = null;
let cellsAbortController = null; // AbortController for in-flight cell requests
let repeatersAbortController = null; // AbortController for in-flight repeater requests
let lastCellData = [];
let repeaterNames = {}; // hexID -> name mapping from repeater annotations
let viewportRepeaterHexIDs = new Set(); // hex IDs of repeaters with locations in the current viewport
let eventSource = null; // SSE connection

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

    // Load cells and repeaters when map region changes.
    // Uses diff-based rendering — existing overlays/annotations that are still
    // in the new viewport are kept; only new ones are added and out-of-viewport
    // ones removed. No full redraw needed on pan/zoom.
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

    // Connect to server-sent events for real-time push updates.
    // Falls back to 30s polling if SSE is unavailable.
    connectSSE();
    setInterval(loadStats, 60000);
}

// Server-Sent Events: receive push notifications when new data is uploaded
function connectSSE() {
    if (eventSource) {
        eventSource.close();
    }

    eventSource = new EventSource(`${API_BASE}/events`);

    eventSource.addEventListener('upload', function() {
        // New survey data was uploaded — refresh cells, repeaters, and stats
        loadCells();
        loadRepeaters();
        loadStats();
    });

    eventSource.addEventListener('connected', function() {
        console.log('SSE connected');
    });

    eventSource.onerror = function() {
        // SSE disconnected — fall back to polling until reconnect
        // EventSource auto-reconnects, but poll in the meantime
        if (!eventSource._fallbackInterval) {
            eventSource._fallbackInterval = setInterval(() => {
                if (eventSource.readyState === EventSource.OPEN) {
                    clearInterval(eventSource._fallbackInterval);
                    eventSource._fallbackInterval = null;
                } else {
                    loadCells();
                    loadRepeaters();
                }
            }, 30000);
        }
    };
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

// Load cells for current viewport.
// Uses diff-based rendering: fetches cells in the viewport and diffs against
// the existing overlay cache to add/remove/update only what changed.
async function loadCells() {
    if (!map) return;

    // Cancel any in-flight request so we don't render stale data
    if (cellsAbortController) {
        cellsAbortController.abort();
    }
    cellsAbortController = new AbortController();
    const signal = cellsAbortController.signal;

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
        limit: 5000,
        names: 'true'
    });

    // Pass active filters to server for pre-filtering
    if (coverageFilter !== 'all') {
        params.set('coverage', coverageFilter);
    }
    const maxAgeSecs = getMaxAgeSeconds();
    if (maxAgeSecs !== null) {
        params.set('maxAge', maxAgeSecs);
    }
    if (repeaterFilter) {
        params.set('repeater', repeaterFilter);
    }

    try {
        const response = await fetch(`${API_BASE}/cells?${params}`, { signal });
        if (!response.ok) return;
        const data = await response.json();
        lastCellData = data.cells;
        renderCells(data.cells);
        updateRepeaterDropdown(data.cells);
    } catch (e) {
        if (e.name === 'AbortError') return; // Superseded by a newer request
        console.error('Failed to load cells:', e);
    }
}

// Apply coverage filter — re-fetch from server with new filter
function applyCoverageFilter(filter) {
    coverageFilter = filter;
    document.querySelectorAll('.filter-btn').forEach(btn => {
        btn.classList.toggle('active', btn.dataset.filter === filter);
    });
    loadCells();
}

// Apply repeater filter — re-fetch from server with new filter
function applyRepeaterFilter(hexID) {
    repeaterFilter = hexID || null;
    loadCells();
}

// Apply time filter — re-fetch from server with new filter
function applyTimeFilter(filter) {
    timeFilter = filter;
    document.querySelectorAll('[data-time]').forEach(btn => {
        btn.classList.toggle('active', btn.dataset.time === filter);
    });
    loadCells();
}

// Get the max age in seconds for the current time filter (for server-side filtering)
function getMaxAgeSeconds() {
    switch (timeFilter) {
        case '1h': return 3600;
        case '1d': return 86400;
        case '1w': return 604800;
        case '1m': return 2592000;
        default: return null;
    }
}

// Get the cutoff date for the current time filter
function getTimeCutoff() {
    if (timeFilter === 'all') return null;
    const now = Date.now();
    switch (timeFilter) {
        case '1h': return new Date(now - 60 * 60 * 1000);
        case '1d': return new Date(now - 24 * 60 * 60 * 1000);
        case '1w': return new Date(now - 7 * 24 * 60 * 60 * 1000);
        case '1m': return new Date(now - 30 * 24 * 60 * 60 * 1000);
        default: return null;
    }
}

// Update the repeater dropdown with repeaters that are both referenced in
// viewport cells AND have their physical location within the current viewport.
// This ensures zooming in narrows the list to only locally relevant repeaters.
function updateRepeaterDropdown(cells) {
    const select = document.getElementById('repeater-select');
    if (!select) return;

    // Collect all unique repeater hex IDs from cells and consolidate prefixes
    const allIDs = [];
    cells.forEach(c => {
        if (c.repeaterHexIDs) {
            c.repeaterHexIDs.forEach(id => allIDs.push(id));
        }
    });

    let repeaters = consolidateHexIDs(allIDs).sort();

    // Filter to only repeaters whose physical location is in the current viewport
    // (prefix-aware: cell hex "0C13" matches viewport repeater "0C" and vice versa)
    if (viewportRepeaterHexIDs.size > 0) {
        repeaters = repeaters.filter(hexID => {
            const uh = hexID.toUpperCase();
            for (const vh of viewportRepeaterHexIDs) {
                if (uh === vh || uh.startsWith(vh) || vh.startsWith(uh)) return true;
            }
            return false;
        });
    }

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

    // If the active filter is no longer in the dropdown, clear it
    if (current && select.value !== current) {
        const stillPresent = repeaters.some(id => {
            return id === current || (id.toUpperCase().startsWith(current.toUpperCase()));
        });
        if (!stillPresent && repeaterFilter) {
            applyRepeaterFilter(null);
        }
    }

    // Update count label
    const countLabel = document.getElementById('repeater-count');
    if (countLabel) {
        countLabel.textContent = `${repeaters.length} found`;
    }
}

// Build a fingerprint for a cell to detect changes
function cellFingerprint(cell) {
    const quality = cell.snrQuality || snrQuality(cell.averageSNR);
    return `${quality}_${cell.packetCount}_${cell.contributionCount}_${cell.activePacketCount || 0}_${cell.passivePacketCount || 0}`;
}

// Render hex cells on map — diff-based: only add/remove/update what changed.
// Preserves selected cell highlight and popup across refreshes.
function renderCells(cells) {
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

    // Apply time filter — keep cells surveyed after the cutoff
    const timeCutoff = getTimeCutoff();
    if (timeCutoff) {
        filtered = filtered.filter(c => {
            if (!c.lastUpdated) return false;
            return new Date(c.lastUpdated) >= timeCutoff;
        });
    }

    // Build new cell set keyed by hex coordinates
    const newCellsByKey = {};
    filtered.forEach(cell => {
        const key = `${cell.hexQ}_${cell.hexR}`;
        newCellsByKey[key] = cell;
    });

    // Diff: find cells to remove, add, or update
    const toRemove = [];
    const toAdd = [];
    let selectedCellUpdated = false;
    const selectedKey = selectedCellData ? `${selectedCellData.hexQ}_${selectedCellData.hexR}` : null;

    // Remove overlays for cells no longer in the filtered set
    for (const key in currentOverlaysByKey) {
        if (!newCellsByKey[key]) {
            toRemove.push(currentOverlaysByKey[key]);
            delete currentOverlaysByKey[key];
        }
    }

    // Add or update cells
    for (const key in newCellsByKey) {
        const cell = newCellsByKey[key];
        const existing = currentOverlaysByKey[key];

        if (existing) {
            // Cell exists — check if its data changed
            const oldFP = existing._fingerprint;
            const newFP = cellFingerprint(cell);
            if (oldFP !== newFP) {
                // Data changed — remove old, add new
                toRemove.push(existing);
                const overlay = createCellOverlay(cell);
                toAdd.push(overlay);
                currentOverlaysByKey[key] = overlay;

                // Update selected cell data if this is the selected cell
                if (key === selectedKey) {
                    selectedCellData = cell;
                    selectedCellUpdated = true;
                }
            } else {
                // No change — keep existing overlay, just update cell data reference
                existing._cellData = cell;
            }
        } else {
            // New cell — create and add
            const overlay = createCellOverlay(cell);
            toAdd.push(overlay);
            currentOverlaysByKey[key] = overlay;
        }
    }

    // Batch map operations
    if (toRemove.length > 0) {
        map.removeOverlays(toRemove);
    }
    if (toAdd.length > 0) {
        map.addOverlays(toAdd);
    }

    // Rebuild flat array for compatibility
    currentOverlays = Object.values(currentOverlaysByKey);

    // Handle selected cell
    if (selectedCellData) {
        if (!newCellsByKey[selectedKey]) {
            // Selected cell was filtered out
            deselectCell();
        } else if (selectedCellUpdated) {
            // Selected cell data changed — update popup content in place
            showCellPopup(selectedCellData);
        }
        // Otherwise: selected cell is unchanged, leave popup and highlight alone
    }
}

// Create a single cell overlay polygon
function createCellOverlay(cell) {
    const vertices = hexVerticesAtCenter(cell.latitude, cell.longitude, cell.referenceLatitude);
    const isDeadZone = cell.packetCount === 0 && cell.probesSent && cell.probesSent > 0;
    const quality = cell.snrQuality || snrQuality(cell.averageSNR);
    const color = isDeadZone ? '#888' : snrColor(quality);
    const opacity = isDeadZone ? 0.45 : 0.2 + 0.5 * Math.min(1, cell.contributionCount / 5);

    const style = new mapkit.Style({
        fillColor: color,
        fillOpacity: opacity,
        strokeColor: color,
        strokeOpacity: isDeadZone ? 0.8 : 0.6,
        lineWidth: isDeadZone ? 1 : 0.5,
        lineDash: isDeadZone ? [4, 3] : []
    });

    const polygon = new mapkit.PolygonOverlay(vertices, {
        style: style,
        enabled: true,
        visible: true
    });

    polygon._cellData = cell;
    polygon._quality = quality;
    polygon._color = color;
    polygon._fingerprint = cellFingerprint(cell);

    return polygon;
}

// Load repeaters for current viewport.
// Uses diff-based rendering: only adds/removes annotations that changed.
async function loadRepeaters() {
    if (!map) return;

    // Cancel any in-flight repeater request
    if (repeatersAbortController) {
        repeatersAbortController.abort();
    }
    repeatersAbortController = new AbortController();
    const signal = repeatersAbortController.signal;

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
        const response = await fetch(`${API_BASE}/repeaters?${params}`, { signal });
        if (!response.ok) return;
        const data = await response.json();
        renderRepeaters(data.repeaters);

        // Rebuild name lookup and viewport set from current viewport repeaters
        repeaterNames = {};
        viewportRepeaterHexIDs = new Set();
        data.repeaters.forEach(r => {
            repeaterNames[r.hexID] = r.name;
            viewportRepeaterHexIDs.add(r.hexID.toUpperCase());
        });

        // Refresh dropdown with viewport-scoped repeaters
        updateRepeaterDropdown(lastCellData);
    } catch (e) {
        if (e.name === 'AbortError') return; // Superseded by a newer request
        console.error('Failed to load repeaters:', e);
    }
}

// Render repeater annotations — diff-based to avoid flicker
function renderRepeaters(repeaters) {
    const newByHex = {};
    repeaters.forEach(r => { newByHex[r.hexID] = r; });

    // Remove annotations for repeaters no longer in the set
    const toRemove = [];
    for (const hexID in currentRepeatersByHex) {
        if (!newByHex[hexID]) {
            toRemove.push(currentRepeatersByHex[hexID]);
            delete currentRepeatersByHex[hexID];
        }
    }

    // Add annotations for new repeaters
    const toAdd = [];
    for (const hexID in newByHex) {
        if (!currentRepeatersByHex[hexID]) {
            const repeater = newByHex[hexID];
            const coord = new mapkit.Coordinate(repeater.latitude, repeater.longitude);
            const annotation = new mapkit.MarkerAnnotation(coord, {
                title: repeater.name,
                subtitle: repeater.hexID,
                color: '#22d3ee',
                glyphText: '📡'
            });
            toAdd.push(annotation);
            currentRepeatersByHex[hexID] = annotation;
        }
    }

    if (toRemove.length > 0) {
        map.removeAnnotations(toRemove);
    }
    if (toAdd.length > 0) {
        map.addAnnotations(toAdd);
    }

    currentRepeaterAnnotations = Object.values(currentRepeatersByHex);
}

// Popup element
let popupElement = null;

function showCellPopup(cell) {
    dismissPopup();

    // When a repeater filter is active, try to show per-repeater metrics
    let displaySNR = cell.averageSNR;
    let displayPackets = cell.packetCount;
    let displayLastHeard = null;
    let headerSuffix = '';
    let repeaterMetricFound = false;
    let noRepeaterData = false;

    if (repeaterFilter) {
        const rf = repeaterFilter.toUpperCase();
        const filterName = repeaterNames[repeaterFilter] || Object.entries(repeaterNames).find(([k, _]) => {
            const uk = k.toUpperCase();
            return uk.startsWith(rf) || rf.startsWith(uk);
        })?.[1] || repeaterFilter;

        if (cell.repeaterMetrics && cell.repeaterMetrics.length > 0) {
            const match = cell.repeaterMetrics.find(m => {
                const mh = m.hexID.toUpperCase();
                return mh === rf || mh.startsWith(rf) || rf.startsWith(mh);
            });
            if (match) {
                displaySNR = match.averageSNR;
                displayPackets = match.packetCount;
                displayLastHeard = match.lastHeard;
                headerSuffix = ` · via ${filterName}`;
                repeaterMetricFound = true;
            } else {
                noRepeaterData = true;
                headerSuffix = ` · via ${filterName}`;
            }
        } else {
            noRepeaterData = true;
            headerSuffix = ` · via ${filterName}`;
        }
    }

    const isDeadZone = cell.packetCount === 0 && cell.probesSent && cell.probesSent > 0;
    const quality = noRepeaterData || isDeadZone ? 'unknown' : snrQuality(displaySNR);
    const color = isDeadZone ? '#888' : snrColor(quality);
    const level = qualityLevel(quality);
    const headerLabel = isDeadZone ? 'No Response' : `Signal: ${quality}`;
    const snrText = noRepeaterData || isDeadZone
        ? 'No data'
        : (displaySNR !== null && displaySNR !== undefined ? displaySNR.toFixed(1) + ' dB' : 'N/A');

    // Signal quality bars HTML
    let barsHTML = '<div class="signal-bar">';
    for (let i = 1; i <= 5; i++) {
        const filled = !noRepeaterData && i <= level;
        const barColor = filled ? color : 'rgba(255,255,255,0.1)';
        barsHTML += `<div class="signal-segment" style="background:${barColor};height:${8 + i * 4}px;"></div>`;
    }
    barsHTML += '</div>';

    let repeatersHTML = '';
    if (cell.repeaterHexIDs && cell.repeaterHexIDs.length > 0) {
        // Build lookup for per-repeater last heard
        const metricsByID = {};
        if (cell.repeaterMetrics) {
            for (const m of cell.repeaterMetrics) {
                metricsByID[m.hexID.toUpperCase()] = m;
            }
        }
        repeatersHTML = `
            <div class="repeaters">
                <div class="detail-label">Repeaters:</div>
                ${cell.repeaterHexIDs.map(id => {
                    const name = repeaterNames[id];
                    const label = name ? `${name}` : id;
                    const metric = metricsByID[id.toUpperCase()];
                    let tooltip = 'Click to filter by this repeater';
                    if (metric && metric.lastHeard) {
                        const ago = formatTimeAgo(new Date(metric.lastHeard));
                        tooltip = `Last heard: ${ago} · Click to filter`;
                    }
                    return `<span class="repeater-tag" onclick="event.stopPropagation(); applyRepeaterFilter('${id}'); document.getElementById('repeater-select').value='${id}';" title="${tooltip}">${label}</span>`;
                }).join('')}
            </div>
        `;
    }

    // Active/passive breakdown (only shown when not in per-repeater view)
    let modeHTML = '';
    if (!repeaterFilter) {
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
    }

    // Probe success rate (when probes were sent for this cell)
    let successRateHTML = '';
    if (cell.probesSent && cell.probesSent > 0) {
        if (cell.packetCount === 0) {
            // Dead zone: probes sent but no responses
            successRateHTML = `
                <div class="detail-row">
                    <span class="detail-label">Probe Result</span>
                    <span class="detail-value" style="color:#888">${cell.probesSent} sent, 0 responses</span>
                </div>
            `;
        } else {
            const active = cell.activePacketCount || 0;
            const rate = Math.min(1.0, active / cell.probesSent);
            const pct = Math.round(rate * 100);
            const rateColor = pct >= 75 ? '#4ade80' : pct >= 40 ? '#facc15' : '#f87171';
            successRateHTML = `
                <div class="detail-row">
                    <span class="detail-label">Probe Success</span>
                    <span class="detail-value" style="color:${rateColor}">${pct}% <span style="color:#666;font-size:10px">(${active}/${cell.probesSent})</span></span>
                </div>
            `;
        }
    }

    // Packets display: per-repeater count when available, cell total as fallback
    let packetsHTML;
    if (noRepeaterData) {
        packetsHTML = `<span class="detail-value">${cell.packetCount.toLocaleString()} <span style="color:#666;font-size:10px">(cell total)</span></span>`;
    } else {
        packetsHTML = `<span class="detail-value">${displayPackets.toLocaleString()}</span>`;
    }

    // Surveyed timestamp row
    let surveyedHTML = '';
    if (repeaterMetricFound && displayLastHeard) {
        // Per-repeater last heard when filter is active
        const date = new Date(displayLastHeard);
        const timeAgo = formatTimeAgo(date);
        surveyedHTML = `
            <div class="detail-row">
                <span class="detail-label">Surveyed</span>
                <span class="detail-value">${timeAgo}</span>
            </div>
        `;
    } else if (noRepeaterData) {
        surveyedHTML = `
            <div class="detail-row">
                <span class="detail-label">Surveyed</span>
                <span class="detail-value" style="color:#666">No data</span>
            </div>
        `;
    } else if (cell.lastUpdated) {
        // Cell-level last updated when no repeater filter
        const date = new Date(cell.lastUpdated);
        const timeAgo = formatTimeAgo(date);
        surveyedHTML = `
            <div class="detail-row">
                <span class="detail-label">Surveyed</span>
                <span class="detail-value">${timeAgo}</span>
            </div>
        `;
    } else {
        surveyedHTML = `
            <div class="detail-row">
                <span class="detail-label">Surveyed</span>
                <span class="detail-value" style="color:#666">Not available</span>
            </div>
        `;
    }

    popupElement = document.createElement('div');
    popupElement.className = 'cell-popup-overlay';
    popupElement.innerHTML = `
        <div class="cell-popup">
            <div class="popup-header">
                <h3 style="color: ${color}">${headerLabel}${headerSuffix}</h3>
                <button class="popup-close" onclick="event.stopPropagation(); deselectCell();">&times;</button>
            </div>
            ${barsHTML}
            <div class="detail-row">
                <span class="detail-label">Avg SNR</span>
                <span class="detail-value">${snrText}</span>
            </div>
            <div class="detail-row">
                <span class="detail-label">Packets</span>
                ${packetsHTML}
            </div>
            ${surveyedHTML}
            ${modeHTML}
            ${successRateHTML}
            <div class="detail-row">
                <span class="detail-label">Contributions</span>
                <span class="detail-value">${cell.contributionCount}</span>
            </div>
            ${cell.contributorNames && cell.contributorNames.length > 0 ? `
            <div class="detail-row">
                <span class="detail-label">Contributors</span>
                <span class="detail-value">${cell.contributorNames.join(', ')}</span>
            </div>` : ''}
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
