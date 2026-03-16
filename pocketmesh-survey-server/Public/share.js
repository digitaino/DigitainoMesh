// PocketMesh Shared Route & Repeater Map Viewer

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

let map = null;

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
        renderRepeaterMap(SHARE_DATA);
    }
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
    summaryHTML += `
        <div class="summary-stat">
            <span class="value">${data.hops.length}</span>
            <span class="label">Located</span>
        </div>
    `;
    summaryEl.innerHTML = summaryHTML;

    // Hop list
    let hopHTML = '';
    data.hops.forEach((hop, i) => {
        if (i > 0) {
            hopHTML += '<div class="hop-connector"><div class="line"></div></div>';
        }
        const name = hop.name || hop.hexID;
        const located = hop.latitude != null && hop.longitude != null;
        hopHTML += `
            <div class="hop-item">
                <div class="hop-index">${i + 1}</div>
                <div class="hop-details">
                    <div class="hop-name">${escapeHTML(name)}</div>
                    <div class="hop-hex">${hop.hexID}${located ? '' : ' · no location'}</div>
                </div>
            </div>
        `;
    });
    hopListEl.innerHTML = hopHTML;

    // Map: add annotations and polyline for located hops
    const locatedHops = data.hops.filter(h => h.latitude != null && h.longitude != null);

    if (locatedHops.length === 0) {
        // Center on a default location if nothing is located
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

    // Fit map to show all points
    const padding = new mapkit.Padding(60, 40, 280, 40);
    map.showItems(annotations, { padding: padding, animate: true });
}

// MARK: - Repeater Map Rendering

function renderRepeaterMap(data) {
    const summaryEl = document.getElementById('route-summary');
    const hopListEl = document.getElementById('hop-list');

    // Summary
    const locatedCount = data.repeaters.filter(r => r.latitude != null && r.longitude != null).length;
    const totalHeard = data.repeaters.reduce((sum, r) => sum + (r.heardCount || 0), 0);

    let summaryHTML = `
        <div class="summary-stat">
            <span class="value">${data.repeaterCount}</span>
            <span class="label">Repeater${data.repeaterCount === 1 ? '' : 's'}</span>
        </div>
        <div class="summary-stat">
            <span class="value">${totalHeard}</span>
            <span class="label">Total Heard</span>
        </div>
        <div class="summary-stat">
            <span class="value">${locatedCount}</span>
            <span class="label">Located</span>
        </div>
    `;
    summaryEl.innerHTML = summaryHTML;

    // Repeater list sorted by heard count (descending)
    const sorted = [...data.repeaters].sort((a, b) => (b.heardCount || 0) - (a.heardCount || 0));

    let listHTML = '';
    sorted.forEach(repeater => {
        const name = repeater.name || repeater.hexID;
        const located = repeater.latitude != null && repeater.longitude != null;
        const snrClass = snrQualityClass(repeater.avgSNR);

        let signalHTML = '';
        if (repeater.heardCount) {
            signalHTML += `<div class="count">${repeater.heardCount}×</div>`;
        }
        if (repeater.avgSNR != null) {
            signalHTML += `<div class="snr ${snrClass}">${repeater.avgSNR.toFixed(1)} dB</div>`;
        }
        if (repeater.avgRSSI != null) {
            signalHTML += `<div class="rssi">${repeater.avgRSSI.toFixed(0)} dBm</div>`;
        }

        listHTML += `
            <div class="hop-item">
                <div class="hop-index" style="background: ${repeater.avgSNR != null ? snrQualityColor(repeater.avgSNR) + '33' : 'rgba(34,211,238,0.2)'}; color: ${repeater.avgSNR != null ? snrQualityColor(repeater.avgSNR) : '#22d3ee'}">
                    📡
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
    });
    hopListEl.innerHTML = listHTML;

    // Map annotations for located repeaters
    const located = data.repeaters.filter(r => r.latitude != null && r.longitude != null);

    if (located.length === 0) {
        map.center = new mapkit.Coordinate(30.27, -97.74);
        map.cameraDistance = 50000;
        return;
    }

    const annotations = located.map(repeater => {
        const coord = new mapkit.Coordinate(repeater.latitude, repeater.longitude);
        const color = snrQualityColor(repeater.avgSNR);
        return new mapkit.MarkerAnnotation(coord, {
            title: repeater.name || repeater.hexID,
            subtitle: repeater.heardCount ? `${repeater.heardCount}× heard` : repeater.hexID,
            color: color,
            glyphText: '📡'
        });
    });
    map.addAnnotations(annotations);

    // Fit to show all repeaters
    const padding = new mapkit.Padding(60, 40, 280, 40);
    map.showItems(annotations, { padding: padding, animate: true });
}

// Utility
function escapeHTML(str) {
    const div = document.createElement('div');
    div.textContent = str;
    return div.innerHTML;
}
