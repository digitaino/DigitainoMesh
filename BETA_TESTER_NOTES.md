Signal Survey — Beta Tester Guide (Build 9)
=============================================

WHAT IT DOES

The Signal Survey tool maps your mesh network's real-world coverage. As you move around with your MeshCore device connected, the app records every received packet alongside your GPS location and builds a hex-grid heatmap showing where your network works — and where it doesn't.

Key concept: Radio links are asymmetric. Hearing a repeater does NOT mean the repeater can hear you. The survey distinguishes between one-way reception (passive) and confirmed two-way connectivity (active).


GETTING STARTED

1. Go to Tools > Signal Survey and tap Start Survey.
2. Choose your mode in the setup sheet (see below).
3. Move around — cells appear on the map as packets arrive.
4. Tap any hex cell to see signal stats, packet counts, and which repeaters were heard.
5. Stop the survey from the toolbar when done.

You can navigate away from the survey at any time. A floating indicator appears at the top-right — tap it to return. Your probe count and data are preserved.


PASSIVE MODE (RX Only)

Listens for mesh traffic without transmitting. Proves where repeater signals reach your location but does NOT prove you can reach the repeater. Good for quietly mapping general coverage.


ACTIVE MODE (TX + RX)

Sends a channel message and listens for heard-repeat responses. A response proves the repeater heard you AND you heard it — a real bidirectional link. Locations with no response are marked as dead zones (gray dashed cells).

Probe Frequency controls how often probes fire based on distance traveled:

  Driving  — every ~15m (fast travel)
  Dense    — every ~25m (walking, slow cycling)
  Normal   — every ~50m (default)
  Sparse   — every ~100m (driving, fast cycling)

You can also tap the Probe button on the map to fire one manually.


DEEP SCAN (Experimental)

WARNING: Deep Scan is experimental and should only be used for testing. It sends additional discover and flood trace requests on top of the channel message. This uses significantly more airtime and may cause congestion on busy networks.

  - Use only at walking speed or slower
  - Best for detailed mesh depth data in a small area
  - Do not leave running during extended drives
  - Maps gateway SNR (best directly-heard repeater quality) and mesh depth beyond direct reach


READING THE MAP

  Green          Connected (2-way) — direct probe response confirmed
  Cyan           Mesh Reach — reached via multi-hop relay
  Gray (solid)   Heard (1-way) — passive reception only
  Gray (dashed)  Dead Zone — probes sent, no response received

Cell brightness reflects signal quality (SNR): green = excellent, yellow = good, orange = fair, red = poor.


COMMUNITY MAP

Toggle the globe icon on the map (or use the menu) to overlay crowd-sourced data from all contributors. Filter by coverage type (All/Active/Passive), repeater, and time range.

  - Live Upload — enable in the setup sheet to share data in real time as you survey
  - Batch Upload — use the menu after stopping to upload completed sessions
  - Data is anonymized: only hex cells (~100m), signal stats, and repeater IDs are sent


TIPS

  - Start with Active + Normal frequency for a good balance of coverage and airtime
  - Use Driving frequency when in a vehicle for denser data
  - Passive data is still valuable — it maps where repeater signals reach
  - Survey the same area multiple times for more reliable results
  - Tap How It Works in the menu for a detailed guide with hop count explanations
