#!/bin/bash

# Your npub (can be npub or hex, we'll detect and convert if needed)
YOUR_NPUB="npub1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"

# IFTTT Event Names
IFTTT_NOTE_EVENT="note_event"
IFTTT_MENTION_EVENT="mention_event"
IFTTT_ZAP_EVENT="zap_event"
IFTTT_KEY="your_ifttt_webhook_key"

# Relays to listen to
RELAYS=(
  "wss://relay.damus.io"
  "wss://relay.notoshi.win"
  "wss://relay.siamstr.com"
)

# Converts npub to hex manually (bech32 decoding)
npub_to_hex() {
  npub=$1
  decoded=$(echo "$npub" | tr -d '\n' | sed 's/^npub1//')
  # Decode base32 (bech32) using Python inline
  python3 -c "import bech32; hrp, data = bech32.bech32_decode('$npub'); print(''.join([f'{x:02x}' for x in bech32.convertbits(data, 5, 8, False)]))" 2>/dev/null
}

# Trigger IFTTT webhook
trigger_ifttt() {
  event="$1"
  payload="$2"
  curl -s -X POST -H "Content-Type: application/json" -d "$payload" \
    "https://maker.ifttt.com/trigger/$event/with/key/$IFTTT_KEY"
}

# Ensure hex pubkey
if [[ "$YOUR_NPUB" == npub1* ]]; then
  PUBKEY_HEX=$(npub_to_hex "$YOUR_NPUB")
else
  PUBKEY_HEX="$YOUR_NPUB"
fi

# Start listening to all relays
for relay in "${RELAYS[@]}"; do
  {
    echo "[+] Connecting to $relay"

    since=$(date +%s)
    sub='["REQ", "all_notes", {"kinds": [1, 9735], "since": '$since' }]'
    echo "$sub" | websocat "$relay" -n -t |
    while read -r line; do
      kind=$(echo "$line" | jq -r '.[2].kind // empty')
      if [[ -z "$kind" ]]; then continue; fi

      if [[ "$kind" == "1" ]]; then
        content=$(echo "$line" | jq -r '.[2].content')
        mentions=$(echo "$line" | jq -r '.[2].tags[]? | select(.[0] == "p") | .[1]' | grep -i "$PUBKEY_HEX")
        if [[ -n "$mentions" ]]; then
          payload="{\"value1\":\"mention\",\"value2\":\"$content\"}"
          trigger_ifttt "$IFTTT_MENTION_EVENT" "$payload"
          echo "[📢] Mention found on $relay"
        elif [[ $(echo "$line" | jq -r '.[2].pubkey') == "$PUBKEY_HEX" ]]; then
          payload="{\"value1\":\"note\",\"value2\":\"$content\"}"
          trigger_ifttt "$IFTTT_NOTE_EVENT" "$payload"
          echo "[✏️] Note by you on $relay"
        fi

      elif [[ "$kind" == "9735" ]]; then
        # Extract the 'description' tag value from the tags array
        raw_desc=$(echo "$line" | jq -r '.[2].tags[]? | select(.[0] == "description") | .[1]')

        if [[ -z "$raw_desc" ]]; then
          echo "[WARN] No zap 'description' tag found"
          continue
        fi

        # Try to parse the stringified JSON description
        inner_json=$(echo "$raw_desc" | jq -Rr 'fromjson?')
        if [[ -z "$inner_json" ]]; then
          echo "[WARN] Failed to parse zap description JSON (unescaped: $raw_desc)"
          continue
        fi

        # Check if our pubkey appears in the zap's description
        mentioned=$(echo "$inner_json" | jq -r --arg pk "$PUBKEY_HEX" '.tags[]? | select(.[0]=="p" and .[1]==$pk)')
        if [[ -n "$mentioned" ]]; then
          amount=$(echo "$line" | jq -r '.[2].tags[]? | select(.[0]=="amount") | .[1]')
          payload="{\"value1\":\"zap\",\"value2\":\"${amount:-unknown} sats\"}"
          trigger_ifttt "$IFTTT_ZAP_EVENT" "$payload"
          echo "[⚡] Zap found on $relay for $PUBKEY_HEX"
        else
          echo "[INFO] Zap received, but not for us"
        fi
      fi
    done
  } &
done

wait