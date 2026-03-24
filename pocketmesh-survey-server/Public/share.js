// DigitainoMesh Shared Route & Repeater Map Viewer

// SNR quality helpers — matches iOS app thresholds
function snrQualityClass(snr) {
    if (snr === null || snr === undefined) return 'snr-unknown';
    if (snr > 10) return 'snr-excellent';
    if (snr > 5) return 'snr-good';
    if (snr > 0) return 'snr-fair';
    if (snr > -10) return 'snr-poor';
    return 'snr-verypoor';
}

function snrQualityColor(snr) {
    if (snr === null || snr === undefined) return '#666666';
    if (snr > 10) return '#22c55e';
    if (snr > 5) return '#eab308';
    if (snr > 0) return '#f97316';
    if (snr > -10) return '#ef4444';
    return '#991b1b';
}

// Add a marker at the user's shared location with their name (or "User" as fallback).
// Returns the coordinate for line-drawing purposes.
function addUserMarker(lat, lon, color, name) {
    const coord = new mapkit.Coordinate(lat, lon);
    const displayName = name || 'User';
    const annotation = new mapkit.MarkerAnnotation(coord, {
        title: displayName,
        color: color,
        glyphText: '📱'
    });
    map.addAnnotation(annotation);
    currentMapAnnotations.push(annotation);
    return coord;
}

// Get the sharer's display name from SHARE_DATA, falling back to "User".
function sharerName() {
    return (SHARE_DATA && SHARE_DATA.userName) ? SHARE_DATA.userName : 'User';
}

// Hex grid math — matches app.js and iOS client
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

// SNR quality from value — matches app.js
function snrQuality(snr) {
    if (snr === null || snr === undefined) return 'unknown';
    if (snr > 10) return 'excellent';
    if (snr > 5) return 'good';
    if (snr > 0) return 'fair';
    if (snr > -10) return 'poor';
    return 'veryPoor';
}

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

let map = null;

// Repeater map state for repeat navigation
let repeatMapData = null;     // SHARE_DATA reference
let selectedRepeat = null;    // null = "All", 0..N-1 = specific repeat index
let currentMapOverlays = [];  // polylines on the map
let currentMapAnnotations = []; // annotations on the map

// Cell overlay state
let cellOverlayEnabled = true;
let cellOverlays = [];
let cellOverlaysByKey = {};
let cellLoadingTimeout = null;

// ---- Map position hash utilities ----

function parseHashPosition() {
    const hash = window.location.hash;
    if (!hash || hash.length < 2) return null;
    const params = new URLSearchParams(hash.substring(1));
    const lat = parseFloat(params.get('lat'));
    const lon = parseFloat(params.get('lon'));
    const z = parseFloat(params.get('z'));
    if (isNaN(lat) || isNaN(lon) || isNaN(z)) return null;
    if (lat < -90 || lat > 90 || lon < -180 || lon > 180 || z < 100) return null;
    return { lat, lon, z };
}

let hashUpdateTimer = null;
function updateHashPosition() {
    clearTimeout(hashUpdateTimer);
    hashUpdateTimer = setTimeout(() => {
        if (!map) return;
        const center = map.center;
        const z = Math.round(map.cameraDistance);
        const lat = center.latitude.toFixed(5);
        const lon = center.longitude.toFixed(5);
        const newHash = `#lat=${lat}&lon=${lon}&z=${z}`;
        if (window.location.hash !== newHash) {
            history.replaceState(null, '', newHash);
        }
    }, 500);
}

async function copyMapLink() {
    try {
        await navigator.clipboard.writeText(window.location.href);
        showCopyToast('Link copied!');
    } catch {
        const input = document.createElement('input');
        input.value = window.location.href;
        document.body.appendChild(input);
        input.select();
        document.execCommand('copy');
        input.remove();
        showCopyToast('Link copied!');
    }
}

function showCopyToast(msg) {
    let toast = document.getElementById('copy-toast');
    if (!toast) {
        toast = document.createElement('div');
        toast.id = 'copy-toast';
        document.body.appendChild(toast);
    }
    toast.textContent = msg;
    toast.style.opacity = '1';
    setTimeout(() => { toast.style.opacity = '0'; }, 2000);
}

function togglePanel() {
    document.getElementById('share-panel').classList.toggle('expanded');
}

// Prevent touch events on the panel body from reaching the map underneath.
// MapKit JS intercepts touch events for panning, which blocks scrolling
// inside the panel on mobile Safari.
document.addEventListener('DOMContentLoaded', function() {
    const panelBody = document.getElementById('panel-body');
    if (panelBody) {
        panelBody.addEventListener('touchmove', function(e) {
            e.stopPropagation();
        }, { passive: true });
    }
});

function initShareMap() {
    mapkit.init({
        authorizationCallback: function(done) {
            fetch('/api/v1/mapkit-token')
                .then(res => res.text())
                .then(token => done(token))
                .catch(() => console.error('Failed to fetch MapKit JS token'));
        }
    });

    map = new mapkit.Map('map', {
        colorScheme: mapkit.Map.ColorSchemes.Dark,
        mapType: mapkit.Map.MapTypes.MutedStandard,
        showsCompass: mapkit.FeatureVisibility.Adaptive,
        showsZoomControl: true,
        showsMapTypeControl: false,
        isRotationEnabled: true,
        isZoomEnabled: true,
        isScrollEnabled: true
    });

    if (SHARE_TYPE === 'route') {
        renderRoute(SHARE_DATA);
    } else if (SHARE_TYPE === 'repeaterMap') {
        repeatMapData = SHARE_DATA;
        renderRepeaterMap(SHARE_DATA);
    }

    // Override auto-fit with hash position if present (after a brief delay
    // to let showItems animation settle)
    const hashPos = parseHashPosition();
    if (hashPos) {
        setTimeout(() => {
            map.center = new mapkit.Coordinate(hashPos.lat, hashPos.lon);
            map.cameraDistance = hashPos.z;
        }, 600);
    }

    // Load community signal cell overlay and refresh on pan/zoom
    map.addEventListener('region-change-end', function() {
        clearTimeout(cellLoadingTimeout);
        cellLoadingTimeout = setTimeout(() => { loadCellOverlay(); }, 300);
        updateHashPosition();
    });
    loadCellOverlay();

    // Share button overlay
    const shareBtn = document.createElement('button');
    shareBtn.id = 'copy-link-btn';
    shareBtn.innerHTML = '&#x1F517; Copy Link';
    shareBtn.title = 'Copy a shareable link to this map view';
    shareBtn.onclick = copyMapLink;
    document.body.appendChild(shareBtn);
}

// MARK: - Route Rendering

function renderRoute(data) {
    const summaryEl = document.getElementById('route-summary');
    const hopListEl = document.getElementById('hop-list');

    // Summary stats
    let summaryHTML = `
        <div class="summary-stat">
            <span class="value">${data.hopCount}</span>
            <span class="label">Hop${data.hopCount === 1 ? '' : 's'}</span>
        </div>
    `;
    if (data.distanceText) {
        summaryHTML += `
            <div class="summary-stat">
                <span class="value">${data.distanceText}</span>
                <span class="label">Distance</span>
            </div>
        `;
    }
    const locatedHops = data.hops.filter(h => h.latitude != null && h.longitude != null);
    summaryHTML += `
        <div class="summary-stat">
            <span class="value">${locatedHops.length}</span>
            <span class="label">Located</span>
        </div>
    `;
    summaryEl.innerHTML = summaryHTML;

    // Hop list
    let hopHTML = '';
    data.hops.forEach((hop, i) => {
        const located = hop.latitude != null && hop.longitude != null;
        if (i > 0) {
            hopHTML += `<div class="hop-connector${located ? '' : ' unlocated'}"><div class="line"></div></div>`;
        }
        const name = hop.name || hop.hexID;
        hopHTML += `
            <div class="hop-item${located ? '' : ' unlocated'}">
                <div class="hop-index">${i + 1}</div>
                <div class="hop-details">
                    <div class="hop-name">${escapeHTML(name)}</div>
                    <div class="hop-hex">${hop.hexID}${located ? '' : ' · no location'}</div>
                </div>
            </div>
        `;
    });

    // Add sharer at the end if user location is available
    if (data.userLatitude != null && data.userLongitude != null) {
        hopHTML += '<div class="hop-connector"><div class="line"></div></div>';
        hopHTML += `
            <div class="hop-item">
                <div class="hop-index" style="background: rgba(59,130,246,0.2); color: #3b82f6">📱</div>
                <div class="hop-details">
                    <div class="hop-name">${escapeHTML(sharerName())}</div>
                    <div class="hop-hex">receiver</div>
                </div>
            </div>
        `;
    }
    hopListEl.innerHTML = hopHTML;

    // Map: add annotations and polyline for located hops

    if (locatedHops.length === 0) {
        map.center = new mapkit.Coordinate(30.27, -97.74);
        map.cameraDistance = 50000;
        return;
    }

    // Annotations
    const annotations = locatedHops.map((hop, i) => {
        const coord = new mapkit.Coordinate(hop.latitude, hop.longitude);
        return new mapkit.MarkerAnnotation(coord, {
            title: hop.name || hop.hexID,
            subtitle: `Hop ${data.hops.indexOf(hop) + 1}`,
            color: '#22d3ee',
            glyphText: `${data.hops.indexOf(hop) + 1}`
        });
    });
    map.addAnnotations(annotations);
    const allAnnotations = [...annotations];

    // User location marker and lines
    const hasUserLoc = data.userLatitude != null && data.userLongitude != null;
    if (hasUserLoc) {
        const userCoord = addUserMarker(data.userLatitude, data.userLongitude, '#3b82f6', sharerName());
        allAnnotations.push(currentMapAnnotations[currentMapAnnotations.length - 1]);

        // Dashed line: user → first located hop
        const firstHopLine = new mapkit.PolylineOverlay(
            [userCoord, new mapkit.Coordinate(locatedHops[0].latitude, locatedHops[0].longitude)],
            {
                style: new mapkit.Style({
                    strokeColor: '#3b82f6',
                    strokeOpacity: 0.6,
                    lineWidth: 3,
                    lineDash: [8, 4]
                })
            }
        );
        map.addOverlay(firstHopLine);

        // Solid line: last located hop → user
        const lastHop = locatedHops[locatedHops.length - 1];
        const lastHopLine = new mapkit.PolylineOverlay(
            [new mapkit.Coordinate(lastHop.latitude, lastHop.longitude), userCoord],
            {
                style: new mapkit.Style({
                    strokeColor: '#22d3ee',
                    strokeOpacity: 0.9,
                    lineWidth: 4
                })
            }
        );
        map.addOverlay(lastHopLine);
    }

    // Polyline between located hops (in order of appearance in the route)
    if (locatedHops.length >= 2) {
        const coords = locatedHops.map(h => new mapkit.Coordinate(h.latitude, h.longitude));
        const polyline = new mapkit.PolylineOverlay(coords, {
            style: new mapkit.Style({
                strokeColor: '#22d3ee',
                strokeOpacity: 0.8,
                lineWidth: 3,
                lineDash: [8, 4]
            })
        });
        map.addOverlay(polyline);
    }

    // Fit map to show all points (including user marker if present)
    const padding = new mapkit.Padding(60, 40, 100, 40);
    map.showItems(allAnnotations, { padding: padding, animate: true });
}

// MARK: - Repeater Map Rendering

function renderRepeaterMap(data) {
    // Render with current selection (null = All)
    renderRepeatView(data, selectedRepeat);
}

// Navigate to previous repeat (wraps: All → last → ... → first → All)
function prevRepeat() {
    if (!repeatMapData || !repeatMapData.paths || repeatMapData.paths.length === 0) return;
    const count = repeatMapData.paths.length;
    if (selectedRepeat === null) {
        selectedRepeat = count - 1;
    } else if (selectedRepeat === 0) {
        selectedRepeat = null;
    } else {
        selectedRepeat--;
    }
    renderRepeatView(repeatMapData, selectedRepeat);
}

// Navigate to next repeat (wraps: All → first → ... → last → All)
function nextRepeat() {
    if (!repeatMapData || !repeatMapData.paths || repeatMapData.paths.length === 0) return;
    const count = repeatMapData.paths.length;
    if (selectedRepeat === null) {
        selectedRepeat = 0;
    } else if (selectedRepeat >= count - 1) {
        selectedRepeat = null;
    } else {
        selectedRepeat++;
    }
    renderRepeatView(repeatMapData, selectedRepeat);
}

// Core rendering function — shows either all repeats or a single repeat
function renderRepeatView(data, repeatIndex) {
    const summaryEl = document.getElementById('route-summary');
    const hopListEl = document.getElementById('hop-list');
    const navEl = document.getElementById('repeat-nav');

    const hasPaths = data.paths && data.paths.length > 0;
    const repeatCount = hasPaths ? data.paths.length : 0;
    const repeaterCount = data.repeaterCount;

    // Build repeater lookup by hexID
    const repeaterByHex = {};
    data.repeaters.forEach(r => {
        repeaterByHex[r.hexID.toUpperCase()] = r;
    });

    // Show/hide navigation arrows
    if (navEl) {
        navEl.style.display = repeatCount > 1 ? 'flex' : 'none';
    }

    if (repeatIndex === null) {
        // ── ALL view ──
        renderAllRepeatsView(data, summaryEl, hopListEl, navEl, repeaterByHex, repeatCount, repeaterCount);
    } else {
        // ── Single repeat view ──
        renderSingleRepeatView(data, summaryEl, hopListEl, navEl, repeaterByHex, repeatIndex, repeatCount);
    }
}

// Render the "All repeats" aggregated view
function renderAllRepeatsView(data, summaryEl, hopListEl, navEl, repeaterByHex, repeatCount, repeaterCount) {
    // Navigation label
    const navLabel = document.getElementById('repeat-nav-label');
    if (navLabel) {
        navLabel.innerHTML = `<span class="nav-count">${repeatCount} repeat${repeatCount === 1 ? '' : 's'}</span> · <span class="nav-count">${repeaterCount} repeater${repeaterCount === 1 ? '' : 's'}</span>`;
    }

    // Summary: repeats · repeaters · located
    const locatedCount = data.repeaters.filter(r => r.latitude != null && r.longitude != null).length;
    let summaryHTML = `
        <div class="summary-stat">
            <span class="value">${repeatCount}</span>
            <span class="label">Repeat${repeatCount === 1 ? '' : 's'}</span>
        </div>
        <div class="summary-stat">
            <span class="value">${repeaterCount}</span>
            <span class="label">Repeater${repeaterCount === 1 ? '' : 's'}</span>
        </div>
        <div class="summary-stat">
            <span class="value">${locatedCount}</span>
            <span class="label">Located</span>
        </div>
    `;
    summaryEl.innerHTML = summaryHTML;

    // Build hop numbers across all paths (1-indexed, first-appearance order)
    const hopNumberByHex = {};
    let nextHopNumber = 1;
    if (data.paths) {
        data.paths.forEach(path => {
            if (!path.hops) return;
            path.hops.forEach(hexID => {
                const key = hexID.toUpperCase();
                if (hopNumberByHex[key] === undefined) {
                    hopNumberByHex[key] = nextHopNumber++;
                }
            });
        });
    }

    // Repeater list: hop-numbered first (path order), then others by heard count
    const sorted = [...data.repeaters].sort((a, b) => {
        const hopA = hopNumberByHex[a.hexID.toUpperCase()];
        const hopB = hopNumberByHex[b.hexID.toUpperCase()];
        if (hopA != null && hopB != null) return hopA - hopB;
        if (hopA != null) return -1;
        if (hopB != null) return 1;
        return (b.heardCount || 0) - (a.heardCount || 0);
    });

    let listHTML = '';
    let prevHadHop = false;
    sorted.forEach(repeater => {
        const hopNum = hopNumberByHex[repeater.hexID.toUpperCase()];
        if (hopNum != null && prevHadHop) {
            listHTML += '<div class="hop-connector"><div class="line"></div></div>';
        }
        prevHadHop = hopNum != null;
        listHTML += buildRepeaterItem(repeater, hopNum);
    });
    hopListEl.innerHTML = listHTML;

    // Map: all repeaters and all path lines
    clearMapContent();
    renderMapForAllRepeats(data, repeaterByHex, hopNumberByHex);
}

// Render a single repeat's path view
function renderSingleRepeatView(data, summaryEl, hopListEl, navEl, repeaterByHex, repeatIndex, repeatCount) {
    const path = data.paths[repeatIndex];
    const hops = path.hops || [];

    // Navigation label: "Repeat X of Y"
    const navLabel = document.getElementById('repeat-nav-label');
    if (navLabel) {
        const snrText = path.snr != null ? ` · ${path.snr.toFixed(1)} dB` : '';
        const hopText = ` · ${hops.length} hop${hops.length === 1 ? '' : 's'}`;
        navLabel.innerHTML = `Repeat ${repeatIndex + 1} of ${repeatCount}${snrText}${hopText}`;
    }

    // Summary: SNR bar + per-path stats
    const snrClass = snrQualityClass(path.snr);
    const snrColor = snrQualityColor(path.snr);
    let summaryHTML = `
        <div class="summary-stat">
            <span class="value" style="color: ${snrColor}">${path.snr != null ? path.snr.toFixed(1) : '—'}</span>
            <span class="label">SNR (dB)</span>
        </div>
        <div class="summary-stat">
            <span class="value">${hops.length}</span>
            <span class="label">Hop${hops.length === 1 ? '' : 's'}</span>
        </div>
    `;
    summaryEl.innerHTML = summaryHTML;

    // Hop list for this single repeat's path
    let listHTML = '';
    hops.forEach((hexID, i) => {
        const key = hexID.toUpperCase();
        const repeater = repeaterByHex[key];

        if (i > 0) {
            listHTML += '<div class="hop-connector"><div class="line"></div></div>';
        }

        if (repeater) {
            listHTML += buildRepeaterItem(repeater, i + 1);
        } else {
            // Unknown repeater — just show hex ID with hop number
            listHTML += `
                <div class="hop-item">
                    <div class="hop-index" style="background: rgba(59,130,246,0.2); color: #3b82f6">${i + 1}</div>
                    <div class="hop-details">
                        <div class="hop-name">${hexID}</div>
                        <div class="hop-hex">${hexID} · no location</div>
                    </div>
                </div>
            `;
        }
    });

    // Add sharer at the end if we have user location
    if (data.userLatitude != null && data.userLongitude != null) {
        listHTML += '<div class="hop-connector"><div class="line" style="background: ' + snrColor + '40"></div></div>';
        listHTML += `
            <div class="hop-item">
                <div class="hop-index" style="background: rgba(59,130,246,0.2); color: #3b82f6">📱</div>
                <div class="hop-details">
                    <div class="hop-name">${escapeHTML(sharerName())}</div>
                    <div class="hop-hex ${snrClass}">${path.snr != null ? path.snr.toFixed(1) + ' dB SNR' : 'received'}</div>
                </div>
            </div>
        `;
    }
    hopListEl.innerHTML = listHTML;

    // Map: only this repeat's path
    clearMapContent();
    renderMapForSingleRepeat(data, path, repeaterByHex);
}

// Build a repeater list item HTML
function buildRepeaterItem(repeater, hopNum) {
    const name = repeater.name || repeater.hexID;
    const located = repeater.latitude != null && repeater.longitude != null;
    const snrClass = snrQualityClass(repeater.avgSNR);

    let signalHTML = '';
    if (repeater.heardCount && repeater.heardCount > 1) {
        signalHTML += `<div class="count">${repeater.heardCount}×</div>`;
    }
    if (repeater.avgSNR != null) {
        signalHTML += `<div class="snr ${snrClass}">${repeater.avgSNR.toFixed(1)} dB</div>`;
    }
    if (repeater.avgRSSI != null) {
        signalHTML += `<div class="rssi">${repeater.avgRSSI.toFixed(0)} dBm</div>`;
    }

    const isHop = hopNum != null;
    const bgColor = isHop ? 'rgba(59,130,246,0.2)' : (repeater.avgSNR != null ? snrQualityColor(repeater.avgSNR) + '33' : 'rgba(34,211,238,0.2)');
    const fgColor = isHop ? '#3b82f6' : (repeater.avgSNR != null ? snrQualityColor(repeater.avgSNR) : '#22d3ee');

    return `
        <div class="hop-item">
            <div class="hop-index" style="background: ${bgColor}; color: ${fgColor}">
                ${isHop ? hopNum : '📡'}
            </div>
            <div class="hop-details">
                <div class="hop-name">${escapeHTML(name)}</div>
                <div class="hop-hex">${repeater.hexID}${located ? '' : ' · no location'}</div>
            </div>
            <div class="hop-signal">
                ${signalHTML}
            </div>
        </div>
    `;
}

// Clear all map annotations and overlays
function clearMapContent() {
    if (currentMapOverlays.length > 0) {
        map.removeOverlays(currentMapOverlays);
    }
    if (currentMapAnnotations.length > 0) {
        map.removeAnnotations(currentMapAnnotations);
    }
    currentMapOverlays = [];
    currentMapAnnotations = [];
}

// Render map for "All" view — all repeaters + all path lines
function renderMapForAllRepeats(data, repeaterByHex, hopNumberByHex) {
    const located = data.repeaters.filter(r => r.latitude != null && r.longitude != null);

    if (located.length === 0) {
        map.center = new mapkit.Coordinate(30.27, -97.74);
        map.cameraDistance = 50000;
        return;
    }

    // Coordinate lookup
    const coordByHex = {};
    located.forEach(r => {
        coordByHex[r.hexID.toUpperCase()] = new mapkit.Coordinate(r.latitude, r.longitude);
    });

    // Repeater annotations
    const annotations = located.map(repeater => {
        const coord = new mapkit.Coordinate(repeater.latitude, repeater.longitude);
        const color = snrQualityColor(repeater.avgSNR);
        const hopNum = hopNumberByHex[repeater.hexID.toUpperCase()];
        return new mapkit.MarkerAnnotation(coord, {
            title: repeater.name || repeater.hexID,
            subtitle: hopNum != null ? `Hop ${hopNum}` : (repeater.heardCount ? `${repeater.heardCount}× heard` : repeater.hexID),
            color: hopNum != null ? '#3b82f6' : color,
            glyphText: hopNum != null ? `${hopNum}` : '📡'
        });
    });
    map.addAnnotations(annotations);
    currentMapAnnotations = [...annotations];

    // Path lines
    if (data.paths && data.paths.length > 0) {
        const userCoord = (data.userLatitude != null && data.userLongitude != null)
            ? new mapkit.Coordinate(data.userLatitude, data.userLongitude)
            : null;

        // User location marker
        let userMapCoord = null;
        if (userCoord) {
            userMapCoord = addUserMarker(
                data.userLatitude, data.userLongitude, '#3b82f6', sharerName()
            );
        }

        data.paths.forEach(path => {
            if (!path.hops || path.hops.length === 0) return;

            const hopCoords = path.hops
                .map(h => coordByHex[h.toUpperCase()])
                .filter(c => c != null);

            if (hopCoords.length === 0) return;

            // Dashed user → first hop line (outbound first leg)
            if (userMapCoord) {
                const firstHopLine = new mapkit.PolylineOverlay(
                    [userMapCoord, hopCoords[0]],
                    {
                        style: new mapkit.Style({
                            strokeColor: '#3b82f6',
                            strokeOpacity: 0.6,
                            lineWidth: 3,
                            lineDash: [8, 4]
                        })
                    }
                );
                map.addOverlay(firstHopLine);
                currentMapOverlays.push(firstHopLine);
            }

            // Dashed outbound chain between consecutive hops
            if (hopCoords.length >= 2) {
                const outboundLine = new mapkit.PolylineOverlay(hopCoords, {
                    style: new mapkit.Style({
                        strokeColor: '#3b82f6',
                        strokeOpacity: 0.6,
                        lineWidth: 3,
                        lineDash: [8, 4]
                    })
                });
                map.addOverlay(outboundLine);
                currentMapOverlays.push(outboundLine);
            }

            // Solid SNR-colored last-hop line (last repeater → user)
            if (userMapCoord) {
                const lastHopCoord = hopCoords[hopCoords.length - 1];
                const lastHopColor = snrQualityColor(path.snr);
                const lastHopLine = new mapkit.PolylineOverlay(
                    [lastHopCoord, userMapCoord],
                    {
                        style: new mapkit.Style({
                            strokeColor: lastHopColor,
                            strokeOpacity: 0.9,
                            lineWidth: 4
                        })
                    }
                );
                map.addOverlay(lastHopLine);
                currentMapOverlays.push(lastHopLine);
            }
        });
    }

    // Fit to show all points
    const padding = new mapkit.Padding(60, 40, 160, 40);
    map.showItems(currentMapAnnotations, { padding: padding, animate: true });
}

// Render map for a single repeat — only that path's hops + lines
function renderMapForSingleRepeat(data, path, repeaterByHex) {
    const hops = path.hops || [];

    // Coordinate lookup for all located repeaters (we need them all for context)
    const coordByHex = {};
    data.repeaters.forEach(r => {
        if (r.latitude != null && r.longitude != null) {
            coordByHex[r.hexID.toUpperCase()] = new mapkit.Coordinate(r.latitude, r.longitude);
        }
    });

    // Add faded annotations for all repeaters not in this path (context)
    const pathHexSet = new Set(hops.map(h => h.toUpperCase()));
    const locatedAll = data.repeaters.filter(r => r.latitude != null && r.longitude != null);

    locatedAll.forEach(repeater => {
        const key = repeater.hexID.toUpperCase();
        if (pathHexSet.has(key)) return; // skip — will be added as path hop below
        const coord = new mapkit.Coordinate(repeater.latitude, repeater.longitude);
        const annotation = new mapkit.MarkerAnnotation(coord, {
            title: repeater.name || repeater.hexID,
            subtitle: repeater.hexID,
            color: '#444',
            glyphText: '📡'
        });
        map.addAnnotation(annotation);
        currentMapAnnotations.push(annotation);
    });

    // Add highlighted annotations for this path's hops
    const pathAnnotations = [];
    hops.forEach((hexID, i) => {
        const key = hexID.toUpperCase();
        const coord = coordByHex[key];
        if (!coord) return;
        const repeater = repeaterByHex[key];
        const annotation = new mapkit.MarkerAnnotation(coord, {
            title: repeater ? (repeater.name || repeater.hexID) : hexID,
            subtitle: `Hop ${i + 1}`,
            color: '#3b82f6',
            glyphText: `${i + 1}`
        });
        map.addAnnotation(annotation);
        currentMapAnnotations.push(annotation);
        pathAnnotations.push(annotation);
    });

    // Resolve hop coordinates for lines
    const hopCoords = hops
        .map(h => coordByHex[h.toUpperCase()])
        .filter(c => c != null);

    // User location
    const userCoord = (data.userLatitude != null && data.userLongitude != null)
        ? new mapkit.Coordinate(data.userLatitude, data.userLongitude)
        : null;

    let userMapCoord = null;
    if (userCoord) {
        // User location marker
        userMapCoord = addUserMarker(
            data.userLatitude, data.userLongitude, '#3b82f6', sharerName()
        );
        // The sharer marker was added to currentMapAnnotations by addUserMarker
        // — include it in pathAnnotations for showItems fitting
        pathAnnotations.push(currentMapAnnotations[currentMapAnnotations.length - 1]);
    }

    if (hopCoords.length > 0) {
        // Dashed user → first hop line (outbound first leg)
        if (userMapCoord) {
            const firstHopLine = new mapkit.PolylineOverlay(
                [userMapCoord, hopCoords[0]],
                {
                    style: new mapkit.Style({
                        strokeColor: '#3b82f6',
                        strokeOpacity: 0.8,
                        lineWidth: 3,
                        lineDash: [8, 4]
                    })
                }
            );
            map.addOverlay(firstHopLine);
            currentMapOverlays.push(firstHopLine);
        }

        // Dashed outbound chain between consecutive hops
        if (hopCoords.length >= 2) {
            const outboundLine = new mapkit.PolylineOverlay(hopCoords, {
                style: new mapkit.Style({
                    strokeColor: '#3b82f6',
                    strokeOpacity: 0.8,
                    lineWidth: 3,
                    lineDash: [8, 4]
                })
            });
            map.addOverlay(outboundLine);
            currentMapOverlays.push(outboundLine);
        }

        // Solid SNR-colored last-hop line (last repeater → user)
        if (userMapCoord) {
            const lastHopCoord = hopCoords[hopCoords.length - 1];
            const lastHopColor = snrQualityColor(path.snr);
            const lastHopLine = new mapkit.PolylineOverlay(
                [lastHopCoord, userMapCoord],
                {
                    style: new mapkit.Style({
                        strokeColor: lastHopColor,
                        strokeOpacity: 0.9,
                        lineWidth: 4
                    })
                }
            );
            map.addOverlay(lastHopLine);
            currentMapOverlays.push(lastHopLine);
        }
    }

    // Fit to show the path's annotations (not the faded context ones)
    const itemsToShow = pathAnnotations.length > 0 ? pathAnnotations : currentMapAnnotations;
    if (itemsToShow.length > 0) {
        const padding = new mapkit.Padding(60, 40, 160, 40);
        map.showItems(itemsToShow, { padding: padding, animate: true });
    }
}

// MARK: - Cell Overlay

// Load community signal cells for current viewport
async function loadCellOverlay() {
    if (!cellOverlayEnabled || !map) return;

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
        const response = await fetch(`/api/v1/cells?${params}`);
        if (!response.ok) return;
        const data = await response.json();
        renderCellOverlay(data.cells);
    } catch (e) {
        console.error('Failed to load cells:', e);
    }
}

// Render cell overlay using diff-based approach (add/remove only what changed)
function renderCellOverlay(cells) {
    const newCellsByKey = {};
    cells.forEach(cell => {
        const key = `${cell.hexQ}_${cell.hexR}`;
        newCellsByKey[key] = cell;
    });

    // Remove overlays no longer in viewport
    const toRemove = [];
    for (const key in cellOverlaysByKey) {
        if (!newCellsByKey[key]) {
            toRemove.push(cellOverlaysByKey[key]);
            delete cellOverlaysByKey[key];
        }
    }

    // Add new cells
    const toAdd = [];
    for (const key in newCellsByKey) {
        if (!cellOverlaysByKey[key]) {
            const cell = newCellsByKey[key];
            const overlay = createCellOverlay(cell);
            toAdd.push(overlay);
            cellOverlaysByKey[key] = overlay;
        }
    }

    if (toRemove.length > 0) map.removeOverlays(toRemove);
    if (toAdd.length > 0) map.addOverlays(toAdd);

    cellOverlays = Object.values(cellOverlaysByKey);
}

// Create a single hex polygon overlay for a cell
function createCellOverlay(cell) {
    const quality = cell.snrQuality || snrQuality(cell.averageSNR);
    const color = snrColor(quality);
    const opacity = 0.15 + 0.4 * Math.min(1, cell.contributionCount / 5);

    const vertices = hexVerticesAtCenter(cell.latitude, cell.longitude, cell.referenceLatitude);
    const style = new mapkit.Style({
        fillColor: color,
        fillOpacity: opacity,
        strokeColor: color,
        strokeOpacity: 0.4,
        lineWidth: 0.5
    });

    return new mapkit.PolygonOverlay(vertices, {
        style: style,
        enabled: false,
        visible: true
    });
}

// Toggle cell overlay visibility
function toggleCellOverlay() {
    cellOverlayEnabled = !cellOverlayEnabled;
    const btn = document.getElementById('cell-toggle');
    if (btn) btn.classList.toggle('active', cellOverlayEnabled);

    if (cellOverlayEnabled) {
        loadCellOverlay();
    } else {
        if (cellOverlays.length > 0) map.removeOverlays(cellOverlays);
        cellOverlays = [];
        cellOverlaysByKey = {};
    }
}

// Utility
function escapeHTML(str) {
    const div = document.createElement('div');
    div.textContent = str;
    return div.innerHTML;
}
