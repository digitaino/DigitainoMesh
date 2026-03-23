// Survey Route Planner — Apple MapKit JS drawing tool

const API_BASE = '/api/v1';

let map = null;
let sessionCode = '';
let polygonVertices = [];       // [{lat, lon}]
let vertexAnnotations = [];     // mapkit.Annotation[]
let polygonOverlay = null;      // mapkit.PolygonOverlay
let edgeOverlays = [];          // mapkit.PolylineOverlay[] for edges
let communityOverlays = [];     // hex cell overlays for context
let currentMode = 'code-entry'; // code-entry | draw | send | success

// Hex grid math — matches iOS HexGrid.swift
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

// SNR quality colors
function snrColor(quality) {
    switch (quality) {
        case 'excellent': return '#22c55e';
        case 'good':      return '#eab308';
        case 'fair':      return '#f97316';
        case 'poor':      return '#ef4444';
        case 'veryPoor':  return '#991b1b';
        default:          return '#666666';
    }
}

// MapKit JS initialization callback (called by data-callback on script tag)
function initPlanMap() {
    mapkit.init({
        authorizationCallback: function(done) {
            fetch('/api/v1/mapkit-token')
                .then(res => res.text())
                .then(token => done(token))
                .catch(() => console.error('Failed to fetch MapKit JS token'));
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

    // Load community cells for context when map moves
    map.addEventListener('region-change-end', function() {
        loadCommunityCells();
    });

    // Handle map clicks for polygon drawing
    map.element.addEventListener('click', function(event) {
        if (currentMode !== 'draw') return;

        const rect = map.element.getBoundingClientRect();
        const point = new DOMPoint(event.clientX - rect.left, event.clientY - rect.top);
        const coord = map.convertPointOnPageToCoordinate(point);
        if (!coord) return;

        // Check if clicking near the first vertex to close the polygon
        if (polygonVertices.length >= 3) {
            const first = polygonVertices[0];
            const dist = Math.sqrt(
                Math.pow(coord.latitude - first.lat, 2) +
                Math.pow(coord.longitude - first.lon, 2)
            );
            if (dist < 0.0003) {
                finishPolygon();
                return;
            }
        }

        addVertex(coord.latitude, coord.longitude);
    });

    // Load initial community cells
    loadCommunityCells();

    // Check for code in URL or INITIAL_CODE
    if (typeof INITIAL_CODE !== 'undefined' && INITIAL_CODE.length > 0) {
        sessionCode = INITIAL_CODE;
        validateAndConnect(sessionCode);
    } else {
        showMode('code-entry');
    }
}

// Load community hex cells for background context
function loadCommunityCells() {
    if (!map) return;
    const region = map.region;
    const minLat = region.center.latitude - region.span.latitudeDelta / 2;
    const maxLat = region.center.latitude + region.span.latitudeDelta / 2;
    const minLon = region.center.longitude - region.span.longitudeDelta / 2;
    const maxLon = region.center.longitude + region.span.longitudeDelta / 2;

    fetch(`${API_BASE}/cells?minLat=${minLat}&maxLat=${maxLat}&minLon=${minLon}&maxLon=${maxLon}`)
        .then(res => res.json())
        .then(data => {
            renderCommunityCells(data.cells || []);
        })
        .catch(() => {});
}

function renderCommunityCells(cells) {
    // Remove old overlays
    if (communityOverlays.length > 0) {
        map.removeOverlays(communityOverlays);
    }
    communityOverlays = [];

    for (const cell of cells) {
        const verts = hexVerticesAtCenter(cell.latitude, cell.longitude, cell.referenceLatitude);
        const style = new mapkit.Style({
            fillColor: snrColor(cell.snrQuality),
            fillOpacity: 0.15,
            strokeColor: snrColor(cell.snrQuality),
            strokeOpacity: 0.25,
            lineWidth: 1,
            lineDash: [3, 2]
        });
        const overlay = new mapkit.PolygonOverlay([verts], { style });
        communityOverlays.push(overlay);
    }

    if (communityOverlays.length > 0) {
        map.addOverlays(communityOverlays);
    }
}

// Mode management
function showMode(mode) {
    currentMode = mode;
    document.getElementById('code-entry').style.display = mode === 'code-entry' ? 'block' : 'none';
    document.getElementById('draw-mode').style.display = mode === 'draw' ? 'block' : 'none';
    document.getElementById('send-mode').style.display = mode === 'send' ? 'block' : 'none';
    document.getElementById('success-mode').style.display = mode === 'success' ? 'block' : 'none';
}

// Code entry
function submitCode() {
    const input = document.getElementById('code-input');
    const code = input.value.trim().toUpperCase();
    if (code.length < 4) {
        document.getElementById('code-error').textContent = 'Code must be at least 4 characters';
        return;
    }
    validateAndConnect(code);
}

function validateAndConnect(code) {
    document.getElementById('code-error').textContent = '';
    const submitBtn = document.getElementById('code-submit');
    if (submitBtn) submitBtn.disabled = true;

    fetch(`${API_BASE}/plans/sessions/${code}`)
        .then(res => {
            if (!res.ok) throw new Error(res.status === 404 ? 'Session not found' : 'Connection failed');
            return res.json();
        })
        .then(data => {
            if (data.status === 'submitted') {
                document.getElementById('code-error').textContent = 'This session already has a polygon submitted';
                if (submitBtn) submitBtn.disabled = false;
                return;
            }
            sessionCode = code;
            showMode('draw');
        })
        .catch(err => {
            document.getElementById('code-error').textContent = err.message;
            if (submitBtn) submitBtn.disabled = false;
        });
}

// Enter key on code input
document.addEventListener('DOMContentLoaded', function() {
    const input = document.getElementById('code-input');
    if (input) {
        input.addEventListener('keydown', function(e) {
            if (e.key === 'Enter') submitCode();
        });
    }
});

// Vertex management
function addVertex(lat, lon) {
    polygonVertices.push({ lat, lon });

    // Add annotation marker
    const coord = new mapkit.Coordinate(lat, lon);
    const idx = polygonVertices.length;
    const annotation = new mapkit.Annotation(coord, function(coordinate) {
        const div = document.createElement('div');
        div.style.cssText = `
            width: 24px; height: 24px; border-radius: 50%;
            background: ${idx === 1 ? '#22d3ee' : 'rgba(34, 211, 238, 0.7)'};
            border: 2px solid #fff;
            display: flex; align-items: center; justify-content: center;
            font-size: 11px; font-weight: 700; color: #000;
            cursor: ${idx === 1 && polygonVertices.length >= 3 ? 'pointer' : 'default'};
        `;
        div.textContent = idx;
        return div;
    }, { anchorOffset: new DOMPoint(0, 0) });

    vertexAnnotations.push(annotation);
    map.addAnnotation(annotation);

    updatePolygonOverlay();
    updateVertexCount();
}

function undoVertex() {
    if (polygonVertices.length === 0) return;
    polygonVertices.pop();

    const ann = vertexAnnotations.pop();
    if (ann) map.removeAnnotation(ann);

    updatePolygonOverlay();
    updateVertexCount();
}

function clearPolygon() {
    polygonVertices = [];
    if (vertexAnnotations.length > 0) {
        map.removeAnnotations(vertexAnnotations);
    }
    vertexAnnotations = [];
    removePolygonOverlay();
    updateVertexCount();
}

function updateVertexCount() {
    const el = document.getElementById('vertex-count');
    const n = polygonVertices.length;
    el.textContent = n > 0 ? `${n} point${n !== 1 ? 's' : ''} placed` : '';
    document.getElementById('done-btn').disabled = n < 3;
}

function removePolygonOverlay() {
    if (polygonOverlay) {
        map.removeOverlay(polygonOverlay);
        polygonOverlay = null;
    }
    if (edgeOverlays.length > 0) {
        map.removeOverlays(edgeOverlays);
        edgeOverlays = [];
    }
}

function updatePolygonOverlay() {
    removePolygonOverlay();

    if (polygonVertices.length < 2) return;

    // Draw edges
    const coords = polygonVertices.map(v => new mapkit.Coordinate(v.lat, v.lon));
    const edgeStyle = new mapkit.Style({
        strokeColor: '#22d3ee',
        strokeOpacity: 0.8,
        lineWidth: 2,
        lineDash: [6, 4]
    });

    for (let i = 0; i < coords.length - 1; i++) {
        const line = new mapkit.PolylineOverlay([coords[i], coords[i + 1]], { style: edgeStyle });
        edgeOverlays.push(line);
    }

    // Close the polygon visually if >= 3 vertices
    if (coords.length >= 3) {
        const closeLine = new mapkit.PolylineOverlay([coords[coords.length - 1], coords[0]], { style: edgeStyle });
        edgeOverlays.push(closeLine);

        // Fill polygon
        const fillStyle = new mapkit.Style({
            fillColor: '#22d3ee',
            fillOpacity: 0.12,
            strokeColor: '#22d3ee',
            strokeOpacity: 0.6,
            lineWidth: 2
        });
        polygonOverlay = new mapkit.PolygonOverlay([coords], { style: fillStyle });
        map.addOverlay(polygonOverlay);
    }

    map.addOverlays(edgeOverlays);
}

function finishPolygon() {
    if (polygonVertices.length < 3) return;

    const n = polygonVertices.length;
    document.getElementById('send-summary').textContent =
        `Survey area defined with ${n} corners. Ready to send to your device.`;
    showMode('send');
}

function editPolygon() {
    showMode('draw');
}

function sendPolygon() {
    const btn = document.getElementById('send-btn');
    const status = document.getElementById('send-status');
    btn.disabled = true;
    status.textContent = 'Sending…';
    status.className = '';

    const payload = {
        polygon: polygonVertices.map(v => ({ latitude: v.lat, longitude: v.lon }))
    };

    fetch(`${API_BASE}/plans/sessions/${sessionCode}/polygon`, {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload)
    })
        .then(res => {
            if (!res.ok) throw new Error('Failed to send polygon');
            return res.json();
        })
        .then(() => {
            showMode('success');
        })
        .catch(err => {
            status.textContent = err.message;
            status.className = 'error';
            btn.disabled = false;
        });
}
