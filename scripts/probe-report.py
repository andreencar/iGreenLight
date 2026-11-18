#!/usr/bin/env python3
"""Prints probe results (one block per hypothesis) from a results.jsonl written by `iGreenLight --probe`."""
import json, sys
for line in open(sys.argv[1]):
    r = json.loads(line)
    if r.get("done"):
        continue
    if "name" not in r:
        print("ERROR:", r.get("error")); continue
    head = "ACCEPTED" if r.get("accepted") else "REJECTED"
    print(f'\n[{r["index"]}] {r["name"]}  ->  {head}  {r.get("selected","")}  ({r.get("seconds")}s, capture {r.get("capture")})')
    if r.get("error"): print("    error:", r["error"][:200])
    for n, o in enumerate(r.get("offers", [])):
        if n > 0 or o.get("label"):
            print(f'  ({n}) {o.get("label") or "re-offer"}: {"ACCEPTED " + o.get("selected","") if o.get("accepted") else "REJECTED"}')
        ans = [l for l in o.get("answerVideo", []) if "rtpmap" in l or "fmtp" in l or l.startswith("b=")]
        if ans: print("    answer video:", " | ".join(a.replace("a=", "") for a in ans))
        resp = {k: v for k, v in o.get("response", {}).items() if k not in ("messageType", "requestId", "sdpType", "_errorDetails")}
        if resp: print("    response:", resp)
        if o.get("error"): print("    offer error:", o["error"][:200])
    for k in ("sps", "seiTypes", "pixelFormats", "colorInfo", "hdrMetadataSeen", "statsResolutions", "videoMbps", "serverReportedVideoSizes", "framesDecoded", "unhandledMessages", "note",
              # Transport: what the rtx / playout / feedback / input-channel probes are compared on.
              "rtxOffered", "rtxNegotiated", "playoutDelayExtension", "rttMs", "jitterBufferMs", "decodeMs", "nackTotal", "pliTotal",
              "freezesTotal", "freezeSecondsTotal", "framesDroppedTotal", "packetsReceivedTotal", "packetsLostTotal",
              "retransmittedPacketsTotal", "retransmittedBytesTotal", "fecPacketsTotal",
              "channels", "inputError", "lastFrameSecond", "connectionState", "serverDisconnectAtSecond"):
        if k in r: print(f"    {k}: {r[k]}")
