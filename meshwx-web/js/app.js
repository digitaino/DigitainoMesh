/**
 * MeshWX Web Client — SPA controller.
 * Connects to a MeshCore radio via Web Serial, listens for weather broadcasts,
 * decodes them, and renders a live dashboard.
 */

import WebSerialConnection from '../vendor/meshcore/connection/web_serial_connection.js';
import Constants from '../vendor/meshcore/constants.js';
import * as Decoder from './decoder.js';
import { renderRadarThumbnail, renderRadarSmooth, regionLabel, formatRadarTime } from './radar.js';

// ============================================================================
// App State
// ============================================================================

const state = {
    connection: null,
    connected: false,
    connecting: false,
    selfInfo: null,
    channels: [],
    discoverChannelIdx: null,
    dataChannelIdx: null,

    // Discovery
    discoveredBots: new Map(),  // keyed by channelName
    discoveryState: 'idle',     // idle | scanning | done
    joinedDataChannel: null,    // channel name we joined

    // Weather data store
    observations: new Map(),  // keyed by locationID string
    forecasts: new Map(),
    tafs: new Map(),
    warnings: new Map(),      // keyed by dedupKey
    radar: new Map(),         // keyed by regionID
    notAvailable: [],

    // Message log
    log: [],
    messageCount: 0,

    // Active tab
    activeTab: 'setup',

    // Map
    map: null,
    mapReady: false,         // true after map 'load' event + layers created
    zoneGeoJSON: null,       // lazy-loaded zones.geojson FeatureCollection
    stateCodes: null,        // lazy-loaded state_index.json
};

// ============================================================================
// DOM References
// ============================================================================

const $ = (sel) => document.querySelector(sel);
const $$ = (sel) => document.querySelectorAll(sel);

// ============================================================================
// Connection
// ============================================================================

async function connect() {
    if (state.connecting || state.connected) return;
    state.connecting = true;
    updateConnectionUI();
    addLog('Requesting serial port...', 'info');

    try {
        const connection = await WebSerialConnection.open();
        if (!connection) {
            state.connecting = false;
            updateConnectionUI();
            return;
        }
        state.connection = connection;

        // Event handlers
        connection.on('connected', onConnected);
        connection.on('disconnected', onDisconnected);
        connection.on(Constants.PushCodes.MsgWaiting, onMsgWaiting);
    } catch (err) {
        addLog(`Connection failed: ${err.message}`, 'error');
        state.connecting = false;
        state.connection = null;
        updateConnectionUI();
    }
}

async function disconnect() {
    if (!state.connection) return;
    try {
        await state.connection.close();
    } catch {}
    onDisconnected();
}

async function onConnected() {
    addLog('Connected to radio', 'success');
    state.connecting = false;
    state.connected = true;
    updateConnectionUI();

    try {
        // Get device info
        const selfInfo = await state.connection.getSelfInfo(5000);
        state.selfInfo = selfInfo;
        addLog(`Node: ${selfInfo.name}`, 'info');
        updateConnectionUI();

        // Scan channels to find the MeshWX data channel
        await scanChannels();

        // Sync time
        await state.connection.syncDeviceTime();
        addLog('Device time synced', 'info');

        // Drain any waiting messages
        await onMsgWaiting();

        // Periodic message poll (backup for MsgWaiting push)
        state.pollTimer = setInterval(() => {
            if (state.connected && !syncing) onMsgWaiting();
        }, 5000);

    } catch (err) {
        addLog(`Setup error: ${err.message || err}`, 'error');
    }
}

function onDisconnected() {
    state.connected = false;
    state.connecting = false;
    state.connection = null;
    state.selfInfo = null;
    state.dataChannelIdx = null;
    if (state.pollTimer) {
        clearInterval(state.pollTimer);
        state.pollTimer = null;
    }
    addLog('Disconnected', 'error');
    updateConnectionUI();
}

async function scanChannels() {
    try {
        const channels = await state.connection.getChannels();
        state.channels = channels;

        for (const ch of channels) {
            if (!ch.name) continue;
            addLog(`  ch ${ch.channelIdx}: ${ch.name}`, 'info');
            const lower = ch.name.toLowerCase();

            // Identify discovery channel
            if (lower.endsWith('meshwx-discover')) {
                state.discoverChannelIdx = ch.channelIdx;
                addLog(`Discovery channel found: ${ch.name} (ch ${ch.channelIdx})`, 'success');
            }
            // Identify data channel (e.g. #aus-meshwx-v4)
            if (lower.endsWith('-meshwx-v4') || lower === 'meshwx' || lower === '#meshwx') {
                state.dataChannelIdx = ch.channelIdx;
                state.joinedDataChannel = ch.name;
                addLog(`Data channel found: ${ch.name} (ch ${ch.channelIdx})`, 'success');
            }
        }

        // Auto-provision #meshwx-discover if missing
        if (state.discoverChannelIdx === null) {
            const created = await provisionChannel('#meshwx-discover');
            if (created !== null) {
                state.discoverChannelIdx = created;
                addLog(`Created discovery channel #meshwx-discover on slot ${created}`, 'success');
            } else {
                addLog('Could not create discovery channel — no free slots', 'error');
            }
        }

        updateSetupUI();
    } catch (err) {
        addLog(`Channel scan failed: ${err}`, 'error');
    }
}

/**
 * Create a channel on the first free slot (skipping slot 0).
 * Uses the channel name as the passphrase (same as iOS app).
 * Returns the slot index, or null if no free slot.
 */
async function provisionChannel(name) {
    const channels = await state.connection.getChannels();
    // Only count slots with a non-empty name as occupied (getChannels returns all slots including empty ones)
    const usedSlots = new Set(channels.filter(c => c.name && c.name.trim()).map(c => c.channelIdx));
    // Find free slot (1-7)
    for (let slot = 1; slot < 8; slot++) {
        if (!usedSlots.has(slot)) {
            try {
                // Generate secret from channel name (SHA-256 of name, first 16 bytes)
                const nameBytes = new TextEncoder().encode(name);
                const hash = await crypto.subtle.digest('SHA-256', nameBytes);
                const secret = new Uint8Array(hash).slice(0, 16);
                await state.connection.setChannel(slot, name, secret);
                return slot;
            } catch (err) {
                addLog(`Failed to create channel on slot ${slot}: ${err}`, 'error');
            }
        }
    }
    return null;
}

/**
 * Send a discovery ping on #meshwx-discover to find weather bots.
 * Bots respond with a 0xF0 beacon containing their data channel name.
 */
async function sendDiscoveryPing() {
    if (!state.connected || state.discoverChannelIdx === null) {
        addLog('Cannot ping: no discovery channel', 'error');
        return;
    }

    state.discoveryState = 'scanning';
    state.discoveredBots.clear();
    updateSetupUI();

    try {
        await state.connection.sendChannelTextMessage(state.discoverChannelIdx, 'PING');
        addLog(`Discovery ping sent on ch ${state.discoverChannelIdx}`, 'info');
    } catch (err) {
        addLog(`Discovery ping failed: ${err}`, 'error');
    }

    // Poll for messages every 2s while scanning (bot responds 1-5s after ping)
    const pollInterval = setInterval(() => {
        if (state.connected && !syncing) onMsgWaiting();
    }, 2000);

    // Wait 15 seconds for beacons, then mark done
    setTimeout(() => {
        clearInterval(pollInterval);
        state.discoveryState = 'done';
        updateSetupUI();
        if (state.discoveredBots.size === 0) {
            addLog('No weather bots found. Make sure a MeshWX bot is in range.', 'error');
        } else {
            addLog(`Found ${state.discoveredBots.size} bot(s)`, 'success');
        }
    }, 15000);
}

/**
 * Join a bot's data channel — provision it on the radio and start listening.
 */
async function joinBotChannel(channelName) {
    const name = channelName.startsWith('#') ? channelName : `#${channelName}`;

    // Check if already on the radio
    const channels = await state.connection.getChannels();
    const existing = channels.find(c => c.name && c.name.toLowerCase() === name.toLowerCase());
    if (existing) {
        state.dataChannelIdx = existing.channelIdx;
        state.joinedDataChannel = existing.name;
        addLog(`Already on ${name} (ch ${existing.channelIdx})`, 'success');
        updateSetupUI();
        return;
    }

    const slot = await provisionChannel(name);
    if (slot !== null) {
        state.dataChannelIdx = slot;
        state.joinedDataChannel = name;
        addLog(`Joined ${name} on slot ${slot}`, 'success');
    } else {
        addLog(`Could not join ${name} — no free slots`, 'error');
    }
    updateSetupUI();
}

// ============================================================================
// Message Handling
// ============================================================================

let syncing = false;

async function onMsgWaiting() {
    if (syncing) return;
    syncing = true;
    try {
        while (true) {
            const msg = await state.connection.syncNextMessage();
            if (!msg) break;

            if (msg.channelData) {
                processChannelData(msg.channelData);
            } else if (msg.channelMessage) {
                processChannelTextMsg(msg.channelMessage);
            }
        }
    } catch (err) {
        addLog(`Sync error: ${err}`, 'error');
    }
    syncing = false;
}

function onNoMoreMessages() {
    syncing = false;
}

function onChannelData(msg) {
    processChannelData(msg);
}

function processChannelData(msg) {
    // msg.data is Uint8Array — raw binary from the channel
    const raw = msg.data;
    if (!raw || raw.length < 2) return;

    const decoded = Decoder.decode(raw);
    if (decoded) {
        handleDecodedMessage(decoded);
    }
}

function processChannelTextMsg(msg) {
    // Channel messages may contain binary data (e.g. beacons, weather broadcasts).
    // The companion radio prepends "SenderName: " to the raw payload.
    // Use raw bytes (msg.data) when available to avoid UTF-8 corruption of binary.
    // If raw bytes not available, fall back to text-based extraction.

    const rawData = msg.data || null;
    if (rawData && rawData.length > 1) {
        if (tryDecodeRawChannelMsg(rawData)) return;
    }

    // Fallback: text-only processing (may lose binary data to UTF-8 encoding)
    const text = msg.text || '';
    if (!text) return;

    // Strip "SenderName: " prefix
    let payload = text;
    if (payload.includes(': ')) {
        payload = payload.split(': ').slice(1).join(': ');
    }

    // Try hex-encoded data
    const hexBytes = hexToBytes(payload.trim());
    if (hexBytes && hexBytes.length > 1) {
        const decoded = Decoder.decode(hexBytes);
        if (decoded) {
            handleDecodedMessage(decoded);
            return;
        }
    }

    // Last resort: try re-encoding the stripped text payload back to bytes
    // (lossy for non-UTF-8, but catches some payloads)
    try {
        const textBytes = new TextEncoder().encode(payload);
        if (textBytes.length > 1) {
            const decoded = Decoder.decode(textBytes);
            if (decoded) {
                handleDecodedMessage(decoded);
            }
        }
    } catch {}
}

/**
 * Try to decode raw binary channel message data (with "SenderName: " prefix).
 * Returns true if successfully decoded.
 */
function tryDecodeRawChannelMsg(rawData) {
    // Find the ": " separator (0x3A 0x20) to strip sender prefix
    let payloadStart = 0;
    for (let i = 0; i < Math.min(rawData.length - 1, 40); i++) {
        if (rawData[i] === 0x3A && rawData[i + 1] === 0x20) {
            payloadStart = i + 2;
            break;
        }
    }
    const payload = rawData.slice(payloadStart);
    if (payload.length < 2) return false;

    // Try COBS-encoded binary decode
    const decoded = Decoder.decode(payload);
    if (decoded) {
        handleDecodedMessage(decoded);
        return true;
    }
    // Try hex-encoded payload
    const hexStr = new TextDecoder().decode(payload).trim();
    const hexBytes = hexToBytes(hexStr);
    if (hexBytes && hexBytes.length > 1) {
        const hexDecoded = Decoder.decode(hexBytes);
        if (hexDecoded) {
            handleDecodedMessage(hexDecoded);
            return true;
        }
    }
    return false;
}

function hexToBytes(hex) {
    hex = hex.replace(/\s/g, '');
    if (!/^[0-9a-fA-F]+$/.test(hex) || hex.length % 2 !== 0) return null;
    const bytes = new Uint8Array(hex.length / 2);
    for (let i = 0; i < hex.length; i += 2) {
        bytes[i / 2] = parseInt(hex.substr(i, 2), 16);
    }
    return bytes;
}

function handleDecodedMessage(msg) {
    state.messageCount++;
    $('#msg-count').textContent = state.messageCount;

    switch (msg.type) {
        case 'observation':
            const obsKey = locationKey(msg);
            state.observations.set(obsKey, msg);
            addLog(`Observation: ${obsKey} ${msg.tempF}°F`, 'success');
            break;

        case 'forecast':
            const fcstKey = locationKey(msg);
            state.forecasts.set(fcstKey, msg);
            addLog(`Forecast: ${fcstKey} (${msg.periods.length} periods)`, 'success');
            break;

        case 'taf':
            state.tafs.set(msg.icao, msg);
            addLog(`TAF: ${msg.icao} ${msg.tempF}°F`, 'success');
            break;

        case 'warning':
            const wKey = warningDedupKey(msg);
            state.warnings.set(wKey, msg);
            addLog(`Warning: ${Decoder.warningTitle(msg)}`, 'success');
            break;

        case 'radar':
        case 'qpf':
            state.radar.set(msg.regionID, msg);
            const rName = msg.region ? msg.region.name : `Region ${msg.regionID}`;
            addLog(`${msg.type === 'qpf' ? 'QPF' : 'Radar'}: ${rName} ${msg.gridSize}x${msg.gridSize}`, 'success');
            break;

        case 'notAvailable':
            state.notAvailable.push(msg);
            addLog(`Not Available: ${msg.dataTypeName} — ${msg.reasonName}`, 'error');
            break;

        case 'beacon':
            if (msg.channelName) {
                state.discoveredBots.set(msg.channelName, msg);
                addLog(`Beacon: ${msg.displayName} — ch #${msg.channelName} (${msg.coverageRadiusKm}km range)`, 'success');
                updateSetupUI();
            } else {
                addLog('Beacon received (no channel info)', 'info');
            }
            break;
    }

    renderDashboard();
}

function locationKey(msg) {
    if (typeof msg.locationID === 'string') return msg.locationID;
    if (typeof msg.locationID === 'number') return `pfm:${msg.locationID}`;
    if (msg.locationID && msg.locationID.stateIdx !== undefined) {
        return `zone:${msg.locationID.stateIdx}-${msg.locationID.zoneNum}`;
    }
    return `loc:${msg.locationType}`;
}

function warningDedupKey(w) {
    if (w.office && w.etn) {
        return `${w.phenomenaIndex}-${w.vtecSignificance}-${w.office}-${w.etn}`;
    }
    if (w.zones.length > 0) {
        const z = w.zones[0];
        return `${w.phenomenaIndex}-${w.vtecSignificance}-${z.stateIdx}-${z.zoneNum}-${w.expiryUnixMinutes}`;
    }
    if (w.vertices.length > 0) {
        const v = w.vertices[0];
        return `${w.phenomenaIndex}-${w.vtecSignificance}-${Math.round(v.lat*10000)}-${Math.round(v.lng*10000)}-${w.expiryUnixMinutes}`;
    }
    return `warning-${Date.now()}`;
}

// ============================================================================
// Rendering
// ============================================================================

function updateConnectionUI() {
    const statusDot = $('.status-dot');
    const statusText = $('.status-text');
    const connectBtn = $('#connect-btn');
    const disconnectBtn = $('#disconnect-btn');
    const nodeName = $('#node-name');

    if (state.connected) {
        statusDot.className = 'status-dot connected';
        statusText.textContent = 'Connected';
        connectBtn.style.display = 'none';
        disconnectBtn.style.display = 'inline-block';
        nodeName.textContent = state.selfInfo ? state.selfInfo.name : '';
        // Show dashboard, hide connect screen
        $('#connect-screen').style.display = 'none';
        $('#dashboard').style.display = 'block';
    } else if (state.connecting) {
        statusDot.className = 'status-dot connecting';
        statusText.textContent = 'Connecting...';
        connectBtn.disabled = true;
        disconnectBtn.style.display = 'none';
    } else {
        statusDot.className = 'status-dot';
        statusText.textContent = 'Disconnected';
        connectBtn.style.display = 'inline-block';
        connectBtn.disabled = false;
        disconnectBtn.style.display = 'none';
        nodeName.textContent = '';
        $('#connect-screen').style.display = 'flex';
        $('#dashboard').style.display = 'none';
    }

    $('#msg-count').textContent = state.messageCount;
}

function updateSetupUI() {
    const container = $('#setup-content');
    if (!container) return;

    let html = '';

    // Channel status
    html += '<div class="card"><div class="card-header"><h3>Channels</h3></div>';
    html += `<div style="font-size:0.85rem; color:var(--text-secondary); margin-bottom:8px">`;
    html += `Discovery: ${state.discoverChannelIdx !== null
        ? `<span style="color:var(--green)">ch ${state.discoverChannelIdx}</span>`
        : '<span style="color:var(--red)">not found</span>'}`;
    html += ` &nbsp; Data: ${state.joinedDataChannel
        ? `<span style="color:var(--green)">${state.joinedDataChannel} (ch ${state.dataChannelIdx})</span>`
        : '<span style="color:var(--text-muted)">none — discover a bot first</span>'}`;
    html += '</div></div>';

    // Discovery section
    html += '<div class="card"><div class="card-header"><h3>Discover Weather Bots</h3>';
    const scanning = state.discoveryState === 'scanning';
    html += `<button id="discover-btn" class="btn-primary btn-sm" ${scanning ? 'disabled' : ''}>`;
    html += scanning ? 'Scanning...' : 'Send Ping';
    html += '</button></div>';

    if (state.discoveredBots.size > 0) {
        for (const [chName, bot] of state.discoveredBots) {
            const isJoined = state.joinedDataChannel &&
                state.joinedDataChannel.toLowerCase() === `#${chName}`.toLowerCase();
            html += `<div style="display:flex; align-items:center; justify-content:space-between; padding:8px 0; border-top:1px solid var(--border)">`;
            html += `<div>`;
            html += `<div style="font-weight:600">${bot.displayName}</div>`;
            html += `<div style="font-size:0.8rem; color:var(--text-secondary)">`;
            html += `#${chName} &middot; ${bot.coverageRadiusKm}km range`;
            if (bot.hasRadar) html += ' &middot; Radar';
            if (bot.hasForecasts) html += ' &middot; Forecasts';
            if (bot.hasWarnings) html += ' &middot; Warnings';
            html += `</div></div>`;
            if (isJoined) {
                html += `<span class="badge badge-green">Joined</span>`;
            } else {
                html += `<button class="btn-primary btn-sm join-bot-btn" data-channel="${chName}">Join</button>`;
            }
            html += '</div>';
        }
    } else if (state.discoveryState === 'done') {
        html += '<div style="padding:8px 0; color:var(--text-muted); font-size:0.85rem">No bots found. Ensure a MeshWX weather bot is in range.</div>';
    } else if (state.discoveryState === 'idle') {
        html += '<div style="padding:8px 0; color:var(--text-muted); font-size:0.85rem">Click "Send Ping" to search for nearby weather bots.</div>';
    }
    html += '</div>';

    container.innerHTML = html;

    // Wire button handlers
    $('#discover-btn')?.addEventListener('click', sendDiscoveryPing);
    container.querySelectorAll('.join-bot-btn').forEach(btn => {
        btn.addEventListener('click', () => joinBotChannel(btn.dataset.channel));
    });
}

function renderDashboard() {
    renderObservations();
    renderForecasts();
    renderWarnings();
    renderRadarSection();
    renderLog();
    updateMapWarnings();
    updateMapRadar();
}

function renderObservations() {
    const container = $('#observations-content');
    if (!container) return;
    if (state.observations.size === 0) {
        container.innerHTML = '<div class="empty-state"><div class="icon">--</div>Waiting for observations...</div>';
        return;
    }

    let html = '';
    for (const [key, obs] of state.observations) {
        const feelsLike = obs.tempF + obs.feelsLikeDelta;
        html += `
        <div class="card">
            <div class="card-header">
                <h3>${key}</h3>
                <span class="badge badge-green">${timeAgo(obs.receivedAt)}</span>
            </div>
            <div class="obs-grid">
                <div class="obs-item">
                    <span class="label">Temperature</span>
                    <span class="value">${obs.tempF}<span class="unit">°F</span></span>
                </div>
                <div class="obs-item">
                    <span class="label">Feels Like</span>
                    <span class="value">${feelsLike}<span class="unit">°F</span></span>
                </div>
                <div class="obs-item">
                    <span class="label">Dewpoint</span>
                    <span class="value">${obs.dewpointF}<span class="unit">°F</span></span>
                </div>
                <div class="obs-item">
                    <span class="label">Wind</span>
                    <span class="value">${Decoder.windDirName(obs.windDir)} ${obs.windSpeedKts}<span class="unit"> kts</span></span>
                </div>
                <div class="obs-item">
                    <span class="label">Sky</span>
                    <span class="value" style="font-size:1rem">${Decoder.skyConditionName(obs.skyCode)}</span>
                </div>
                <div class="obs-item">
                    <span class="label">Pressure</span>
                    <span class="value" style="font-size:1rem">${Decoder.formatPressure(obs.pressureRaw)}<span class="unit"> inHg</span></span>
                </div>
                <div class="obs-item">
                    <span class="label">Visibility</span>
                    <span class="value">${obs.visibilityMi}<span class="unit"> mi</span></span>
                </div>
                ${obs.windGustKts > 0 ? `
                <div class="obs-item">
                    <span class="label">Gusts</span>
                    <span class="value">${obs.windGustKts}<span class="unit"> kts</span></span>
                </div>` : ''}
            </div>
        </div>`;
    }
    container.innerHTML = html;
}

function renderForecasts() {
    const container = $('#forecasts-content');
    if (!container) return;
    if (state.forecasts.size === 0) {
        container.innerHTML = '<div class="empty-state"><div class="icon">--</div>Waiting for forecasts...</div>';
        return;
    }

    const PERIOD_NAMES = [
        "","Today","Tonight","Mon","Mon Night","Tue","Tue Night",
        "Wed","Wed Night","Thu","Thu Night","Fri","Fri Night",
        "Sat","Sat Night","Sun","Sun Night",
    ];

    let html = '';
    for (const [key, fcst] of state.forecasts) {
        html += `
        <div class="card">
            <div class="card-header">
                <h3>${key}</h3>
                <span class="badge badge-blue">${fcst.issuedHoursAgo}h ago</span>
            </div>
            <div class="forecast-strip">`;

        for (const p of fcst.periods) {
            const name = PERIOD_NAMES[p.periodID] || `P${p.periodID}`;
            const isNight = p.periodID % 2 === 0;
            const temp = p.highF !== null ? p.highF : p.lowF;
            const tempLabel = p.highF !== null ? 'H' : 'L';
            html += `
                <div class="forecast-period" style="${isNight ? 'opacity:0.7' : ''}">
                    <div class="day">${name}</div>
                    <div class="temp">${temp !== null ? temp + '°' : '--'}</div>
                    <div class="precip">${p.precipPct > 0 ? p.precipPct + '%' : ''}</div>
                </div>`;
        }

        html += `</div></div>`;
    }
    container.innerHTML = html;
}

function renderWarnings() {
    // Filter expired
    const now = Date.now() / 60000;
    const active = [...state.warnings.values()].filter(w => w.expiryUnixMinutes > now);

    const emptyHtml = '<div class="empty-state"><div class="icon">--</div>No active warnings</div>';
    let html = '';

    if (active.length > 0) {
        for (const w of active) {
            const sig = w.vtecSignificance;
            const cls = sig === 0 ? '' : sig === 1 ? 'watch' : sig === 2 ? 'advisory' : 'statement';
            const expiry = new Date(w.expiryUnixMinutes * 60000);
            const zones = (w.zones || []).map(z => `${z.stateIdx}-${z.zoneNum}`).join(', ');
            const vertices = (w.vertices || []).length;
            html += `
            <div class="card warning-card ${cls}">
                <div class="card-header">
                    <h3>${Decoder.warningTitle(w)}</h3>
                    <span class="badge ${sig === 0 ? 'badge-red' : sig === 1 ? 'badge-orange' : 'badge-blue'}">
                        ${Decoder.significanceName(sig)}
                    </span>
                </div>
                ${w.headline ? `<div class="headline">${w.headline}</div>` : ''}
                <div class="expiry">Expires: ${expiry.toLocaleString()}</div>
                ${zones ? `<div style="font-size:0.75rem; color:var(--text-muted); margin-top:4px">Zones: ${zones}</div>` : ''}
                ${vertices > 0 ? `<div style="font-size:0.75rem; color:var(--text-muted); margin-top:2px">${vertices} polygon vertices</div>` : ''}
            </div>`;
        }
    }

    // Update both Dashboard warnings section and dedicated Warnings tab
    const dashContainer = $('#warnings-content');
    if (dashContainer) dashContainer.innerHTML = active.length > 0 ? html : emptyHtml;
    const tabContainer = $('#warnings-tab-content');
    if (tabContainer) tabContainer.innerHTML = active.length > 0 ? html : emptyHtml;
}

function renderRadarSection() {
    const container = $('#radar-content');
    if (!container) return;
    if (state.radar.size === 0) {
        container.innerHTML = '<div class="empty-state"><div class="icon">--</div>Waiting for radar data...</div>';
        return;
    }

    let html = '';
    for (const [regionID, frame] of state.radar) {
        const canvasId = `radar-canvas-${regionID}`;
        html += `
        <div class="card radar-container">
            <div class="card-header">
                <h3>${regionLabel(regionID)}</h3>
                <span class="badge badge-green">${frame.gridSize}x${frame.gridSize}</span>
            </div>
            <canvas id="${canvasId}"></canvas>
            <div class="radar-info">${formatRadarTime(frame.timestamp)}</div>
        </div>`;
    }
    container.innerHTML = html;

    // Render canvases after DOM update
    requestAnimationFrame(() => {
        for (const [regionID, frame] of state.radar) {
            const canvas = $(`#radar-canvas-${regionID}`);
            if (canvas) renderRadarThumbnail(canvas, frame);
        }
    });
}

function renderLog() {
    const container = $('#log-content');
    if (!container) return;
    // Show last 50 entries
    const entries = state.log.slice(-50);
    container.innerHTML = entries.map(e =>
        `<div class="log-entry ${e.level}"><span class="time">${e.time}</span>${e.text}</div>`
    ).join('');
    container.scrollTop = container.scrollHeight;
}

// ============================================================================
// Utilities
// ============================================================================

function addLog(text, level = '') {
    const now = new Date();
    const time = now.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' });
    state.log.push({ time, text, level });
    if (state.log.length > 200) state.log.shift();
    renderLog();
}

function timeAgo(timestamp) {
    const seconds = Math.floor((Date.now() - timestamp) / 1000);
    if (seconds < 60) return 'just now';
    if (seconds < 3600) return `${Math.floor(seconds / 60)}m ago`;
    return `${Math.floor(seconds / 3600)}h ago`;
}

// ============================================================================
// Tab Switching
// ============================================================================

function switchTab(tabName) {
    state.activeTab = tabName;
    $$('.tab').forEach(t => t.classList.toggle('active', t.dataset.tab === tabName));
    $$('.tab-content').forEach(c => c.style.display = c.id === `tab-${tabName}` ? 'block' : 'none');
    // Initialize map when Map tab first shown
    if (tabName === 'radar' && !state.map) {
        initMap();
    }
    if (tabName === 'radar' && state.map) {
        state.map.resize();
        // Refresh overlays when switching to map tab (data may have arrived while hidden)
        if (state.mapReady) {
            updateMapWarnings();
            updateMapRadar();
        }
    }
}

// ============================================================================
// Map (MapLibre GL)
// ============================================================================

const WARNING_COLORS = {
    0: '#e11d48', 1: '#f59e0b', 2: '#06b6d4', 3: '#3b82f6',
    4: '#a855f7', 5: '#f97316', 6: '#dc2626', 7: '#0891b2',
    8: '#fbbf24', 9: '#9ca3af',
};

async function loadZoneData() {
    if (state.zoneGeoJSON) return;
    try {
        const [zonesResp, stateResp] = await Promise.all([
            fetch('data/zones.geojson'),
            fetch('data/state_index.json'),
        ]);
        state.zoneGeoJSON = await zonesResp.json();
        const stateIndex = await stateResp.json();
        state.stateCodes = stateIndex.states;
        addLog(`Loaded ${state.zoneGeoJSON.features.length} zone polygons`, 'info');
    } catch (e) {
        addLog('Failed to load zone data: ' + e.message, 'error');
    }
}

function zoneCode(stateIdx, zoneNum) {
    if (!state.stateCodes || stateIdx >= state.stateCodes.length) return null;
    return `${state.stateCodes[stateIdx]}Z${String(zoneNum).padStart(3, '0')}`;
}

function findZoneFeatures(zones) {
    if (!state.zoneGeoJSON || !zones || zones.length === 0) return [];
    const codes = new Set(zones.map(z => zoneCode(z.stateIdx, z.zoneNum)).filter(Boolean));
    if (codes.size === 0) return [];
    return state.zoneGeoJSON.features.filter(f => codes.has(f.properties.code));
}

function initMap() {
    if (typeof maplibregl === 'undefined') {
        addLog('MapLibre GL not loaded', 'error');
        return;
    }
    const map = new maplibregl.Map({
        container: 'map-container',
        style: {
            version: 8,
            name: 'MeshWX Weather',
            sources: {
                countries: { type: 'geojson', data: 'geo/countries.geojson' },
                states: { type: 'geojson', data: 'geo/states.geojson' },
                cities: { type: 'geojson', data: 'geo/cities.geojson' },
            },
            layers: [
                { id: 'background', type: 'background', paint: { 'background-color': '#1b2636' } },
                { id: 'countries-fill', type: 'fill', source: 'countries', paint: { 'fill-color': '#2a3546' } },
                {
                    id: 'states-fill', type: 'fill', source: 'states',
                    filter: ['==', ['get', 'admin'], 'United States of America'],
                    paint: { 'fill-color': '#334259' },
                },
                {
                    id: 'states-line', type: 'line', source: 'states',
                    paint: { 'line-color': '#5a6a80', 'line-width': ['interpolate', ['linear'], ['zoom'], 3, 0.3, 6, 0.7, 10, 1.2] },
                },
                {
                    id: 'countries-line', type: 'line', source: 'countries',
                    paint: { 'line-color': '#8fa3bd', 'line-width': ['interpolate', ['linear'], ['zoom'], 3, 0.5, 6, 1.0, 10, 1.6] },
                },
                {
                    id: 'city-dots', type: 'circle', source: 'cities',
                    filter: ['>', ['get', 'pop'], 100000],
                    paint: {
                        'circle-radius': ['interpolate', ['linear'], ['zoom'], 3, 1.5, 6, 3, 10, 5],
                        'circle-color': '#f5f5f7', 'circle-opacity': 0.7,
                        'circle-stroke-color': '#0a1220', 'circle-stroke-width': 0.5,
                    },
                },
            ],
        },
        center: [-96, 38],
        zoom: 3.5,
        attributionControl: false,
    });
    map.addControl(new maplibregl.NavigationControl({ showCompass: false }), 'top-right');
    state.map = map;

    map.on('load', async () => {
        console.log('[Map] load event fired');
        // Create warning source + layers up front so radar can reference 'warnings-fill'
        map.addSource('warnings', { type: 'geojson', data: { type: 'FeatureCollection', features: [] } });
        map.addLayer({
            id: 'warnings-fill', type: 'fill', source: 'warnings',
            paint: { 'fill-color': ['get', 'color'], 'fill-opacity': 0.3 },
        });
        map.addLayer({
            id: 'warnings-line', type: 'line', source: 'warnings',
            paint: { 'line-color': ['get', 'color'], 'line-width': 2 },
        });
        map.on('click', 'warnings-fill', (e) => {
            const f = e.features[0];
            const html = `<div style="font-size:13px;">
                <strong style="color:${f.properties.color}">${f.properties.title}</strong>
                <div style="font-size:11px;color:#9ca3af;margin-top:2px">${f.properties.significance}</div>
                ${f.properties.headline ? `<div style="margin-top:4px">${f.properties.headline}</div>` : ''}
            </div>`;
            new maplibregl.Popup().setLngLat(e.lngLat).setHTML(html).addTo(map);
        });
        map.on('mouseenter', 'warnings-fill', () => { map.getCanvas().style.cursor = 'pointer'; });
        map.on('mouseleave', 'warnings-fill', () => { map.getCanvas().style.cursor = ''; });

        state.mapReady = true;
        console.log('[Map] ready, radar regions:', state.radar.size, 'warnings:', state.warnings.size);

        // Load zone polygons for zone-based warnings (0x21)
        await loadZoneData();

        updateMapWarnings();
        updateMapRadar();
    });
}

function updateMapWarnings() {
    const map = state.map;
    if (!map || !state.mapReady) return;

    const now = Date.now() / 60000;
    const active = [...state.warnings.values()].filter(w => w.expiryUnixMinutes > now);

    const features = [];
    for (const w of active) {
        const sigColor = WARNING_COLORS[w.vtecSignificance] || '#9ca3af';
        const props = {
            color: sigColor,
            title: Decoder.warningTitle(w),
            significance: Decoder.significanceName(w.vtecSignificance),
            headline: w.headline || '',
        };

        if (w.vertices && w.vertices.length >= 3) {
            // Polygon-based warning (0x20)
            const ring = w.vertices.map(v => [v.lng, v.lat]);
            // Close the ring if needed
            const first = ring[0], last = ring[ring.length - 1];
            if (first[0] !== last[0] || first[1] !== last[1]) ring.push([...first]);
            features.push({
                type: 'Feature', properties: props,
                geometry: { type: 'Polygon', coordinates: [ring] },
            });
        } else if (w.zones && w.zones.length > 0) {
            // Zone-based warning (0x21) — look up zone polygons from geojson
            const zoneFeatures = findZoneFeatures(w.zones);
            for (const zf of zoneFeatures) {
                features.push({
                    type: 'Feature', properties: props,
                    geometry: zf.geometry,
                });
            }
        }
    }

    map.getSource('warnings').setData({ type: 'FeatureCollection', features });
}

function updateMapRadar() {
    const map = state.map;
    if (!map || !state.mapReady) { console.log('[MapRadar] map not ready'); return; }
    if (state.radar.size === 0) { console.log('[MapRadar] no radar data'); return; }

    console.log(`[MapRadar] Processing ${state.radar.size} radar region(s)`);

    for (const [regionID, frame] of state.radar) {
        console.log(`[MapRadar] Region ${regionID}: region=${!!frame.region}, grid=${frame.grid?.length}, gridSize=${frame.gridSize}`);
        if (!frame.region) { console.log(`[MapRadar] Region ${regionID} has no bounds, skipping`); continue; }
        const { north, south, west, east } = frame.region;
        const sourceId = `radar-${regionID}`;

        // Render smooth radar to offscreen canvas
        const canvas = document.createElement('canvas');
        renderRadarSmooth(canvas, frame, 512);
        console.log(`[MapRadar] Canvas after render: ${canvas.width}x${canvas.height}`);
        if (canvas.width === 0) { console.warn(`[MapRadar] ${sourceId}: empty canvas`); continue; }

        const dataUrl = canvas.toDataURL('image/png');
        console.log(`[MapRadar] dataURL length: ${dataUrl.length}, starts: ${dataUrl.substring(0, 40)}`);
        const coords = [[west, north], [east, north], [east, south], [west, south]];
        console.log(`[MapRadar] coords:`, coords);

        try {
            const exists = !!map.getSource(sourceId);
            console.log(`[MapRadar] source ${sourceId} exists: ${exists}`);
            if (exists) {
                map.getSource(sourceId).updateImage({ url: dataUrl, coordinates: coords });
                console.log(`[MapRadar] Updated ${sourceId}`);
            } else {
                map.addSource(sourceId, { type: 'image', url: dataUrl, coordinates: coords });
                console.log(`[MapRadar] Added source ${sourceId}`);
                const hasWarnings = !!map.getLayer('warnings-fill');
                console.log(`[MapRadar] warnings-fill layer exists: ${hasWarnings}`);
                map.addLayer({
                    id: sourceId, type: 'raster', source: sourceId,
                    paint: { 'raster-opacity': 0.7 },
                }, hasWarnings ? 'warnings-fill' : undefined);
                console.log(`[MapRadar] Added layer ${sourceId}`);
            }
        } catch (e) {
            console.error(`[MapRadar] ERROR for ${sourceId}:`, e);
        }
    }
}

// ============================================================================
// Location Search & Data Requests
// ============================================================================

let pfmPoints = null;  // lazy-loaded
let stations = null;   // lazy-loaded

async function loadSearchData() {
    if (!pfmPoints) {
        try {
            const resp = await fetch('data/pfm_points.json');
            const json = await resp.json();
            pfmPoints = json.points; // [["name", "wfo", lat, lon, "zone"], ...]
        } catch { pfmPoints = []; }
    }
    if (!stations) {
        try {
            const resp = await fetch('data/stations.json');
            stations = await resp.json(); // {"ICAO": {"name", "state", "lat", "lon"}}
        } catch { stations = {}; }
    }
}

function searchLocations(query) {
    if (!query || query.length < 2) return [];
    const q = query.toLowerCase();
    const results = [];

    // Search stations by ICAO code or name
    for (const [icao, info] of Object.entries(stations || {})) {
        if (results.length >= 10) break;
        if (icao.toLowerCase().includes(q) || info.name.toLowerCase().includes(q)) {
            results.push({
                type: 'station',
                id: icao,
                name: info.name,
                detail: `${icao} - ${info.state}`,
                lat: info.lat,
                lon: info.lon,
            });
        }
    }

    // Search PFM points by name
    for (let i = 0; i < (pfmPoints || []).length; i++) {
        if (results.length >= 10) break;
        const p = pfmPoints[i];
        if (p[0].toLowerCase().includes(q)) {
            results.push({
                type: 'pfm',
                id: i,
                name: p[0],
                detail: `WFO: ${p[1]} | ${p[4]}`,
                lat: p[2],
                lon: p[3],
            });
        }
    }

    return results;
}

function renderSearchResults(results) {
    const container = $('#search-results');
    if (!container) return;
    if (results.length === 0) {
        container.innerHTML = '<div style="font-size:0.8rem; color:var(--text-muted); padding:4px 0">No results found</div>';
        return;
    }

    let html = '';
    for (const r of results) {
        html += `<div class="search-result">
            <div>
                <div class="result-name">${r.name}</div>
                <div class="result-detail">${r.detail}</div>
            </div>
            <div style="display:flex; gap:4px">`;
        if (r.type === 'station') {
            html += `<button class="btn-primary btn-sm req-btn" data-type="metar" data-id="${r.id}">METAR</button>`;
            html += `<button class="btn-secondary btn-sm req-btn" data-type="taf" data-id="${r.id}">TAF</button>`;
        }
        if (r.type === 'pfm') {
            html += `<button class="btn-primary btn-sm req-btn" data-type="forecast" data-id="${r.id}">Forecast</button>`;
        }
        // Find nearest station for PFM points to offer METAR
        if (r.type === 'pfm') {
            const nearest = findNearestStation(r.lat, r.lon);
            if (nearest) {
                html += `<button class="btn-secondary btn-sm req-btn" data-type="metar" data-id="${nearest}">METAR (${nearest})</button>`;
            }
        }
        html += `</div></div>`;
    }
    container.innerHTML = html;

    // Wire request buttons
    container.querySelectorAll('.req-btn').forEach(btn => {
        btn.addEventListener('click', () => sendDataRequest(btn.dataset.type, btn.dataset.id));
    });
}

function findNearestStation(lat, lon) {
    if (!stations) return null;
    let best = null, bestDist = Infinity;
    for (const [icao, info] of Object.entries(stations)) {
        const dlat = info.lat - lat;
        const dlon = info.lon - lon;
        const dist = dlat * dlat + dlon * dlon;
        if (dist < bestDist) {
            bestDist = dist;
            best = icao;
        }
    }
    return best;
}

async function sendDataRequest(type, id) {
    if (!state.connected || state.dataChannelIdx === null) {
        addLog('Cannot send request: not connected to a data channel', 'error');
        return;
    }

    let payload;
    switch (type) {
        case 'forecast':
            payload = Decoder.buildForecastRequest(parseInt(id));
            break;
        case 'metar':
            payload = Decoder.buildMetarRequest(id);
            break;
        case 'taf':
            payload = Decoder.buildTAFRequest(id);
            break;
        default:
            return;
    }

    // Send as "WXQ" + hex on the data channel
    const hexStr = [...payload].map(b => b.toString(16).padStart(2, '0')).join('');
    const requestText = 'WXQ' + hexStr;

    try {
        await state.connection.sendChannelTextMessage(state.dataChannelIdx, requestText);
        addLog(`Request sent: ${type} for ${id}`, 'success');

        // Show pending indicator
        const container = $('#pending-requests');
        if (container) {
            const el = document.createElement('span');
            el.className = 'pending-badge';
            el.textContent = `${type}: ${id}...`;
            el.id = `pending-${type}-${id}`;
            container.appendChild(el);
            // Auto-remove after 30s
            setTimeout(() => el.remove(), 30000);
        }
    } catch (err) {
        addLog(`Request failed: ${err}`, 'error');
    }
}

async function onSearchInput() {
    await loadSearchData();
    const query = $('#search-input')?.value || '';
    if (query.length < 2) {
        const container = $('#search-results');
        if (container) container.innerHTML = '';
        return;
    }
    const results = searchLocations(query);
    renderSearchResults(results);
}

// ============================================================================
// Init
// ============================================================================

export function init() {
    // Button handlers
    $('#connect-btn')?.addEventListener('click', connect);
    $('#disconnect-btn')?.addEventListener('click', disconnect);
    $('#connect-btn-hero')?.addEventListener('click', connect);

    // Tab handlers
    $$('.tab').forEach(tab => {
        tab.addEventListener('click', () => switchTab(tab.dataset.tab));
    });

    // Search handlers
    let searchTimer = null;
    $('#search-input')?.addEventListener('input', () => {
        clearTimeout(searchTimer);
        searchTimer = setTimeout(onSearchInput, 200);
    });
    $('#search-btn')?.addEventListener('click', onSearchInput);
    $('#search-input')?.addEventListener('keydown', (e) => {
        if (e.key === 'Enter') onSearchInput();
    });

    // Check Web Serial support
    if (!navigator.serial) {
        addLog('Web Serial API not supported. Use Chrome or Edge.', 'error');
        const heroBtn = $('#connect-btn-hero');
        if (heroBtn) {
            heroBtn.disabled = true;
            heroBtn.textContent = 'Web Serial Not Supported';
        }
    }

    updateConnectionUI();
    addLog('MeshWX Web Client ready', 'info');
}

// Auto-init when DOM is ready
if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
} else {
    init();
}
