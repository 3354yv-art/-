#!/bin/bash
# Retries creating an OCI Ampere A1 instance (2 OCPU / 12GB, falling back to 1 OCPU / 6GB) about every 2 minutes.
# The server gets a 200GB disk (the Always Free maximum) and, if cloud-init.sh sits next to this script,
# runs it on first boot (installs the maze-pages website on port 80).
# Optional env: SSH_PUBLIC_KEY (use this key instead of generating one), MAX_SECONDS (stop after this long).

COMPARTMENT_ID="ocid1.tenancy.oc1..aaaaaaaa4kvrhyup67paovpq2tulihj6miktcnlzxgtuy2faqkht7olgursq"
AD="oXzQ:IL-JERUSALEM-1-AD-1"
NAME="ampere-server"
SHAPE="VM.Standard.A1.Flex"
OCPUS=2
MEMORY_GB=12
FALLBACK_OCPUS=1
FALLBACK_MEMORY_GB=6
SLEEP=120
BOOT_GB=200
USER_DATA="$(dirname "$0")/cloud-init.sh"
EXTRA_ARGS=()
[ -f "$USER_DATA" ] && EXTRA_ARGS=(--user-data-file "$USER_DATA")
MAX_SECONDS="${MAX_SECONDS:-0}"

if [ -n "${SSH_PUBLIC_KEY:-}" ]; then
    PUB_KEY_FILE="$(mktemp)"
    printf '%s\n' "$SSH_PUBLIC_KEY" > "$PUB_KEY_FILE"
else
    KEY="$HOME/.ssh/oci_ampere"
    mkdir -p "$HOME/.ssh"
    [ -f "$KEY" ] || ssh-keygen -t rsa -b 4096 -N "" -f "$KEY" -q
    cp "$KEY" "$HOME/oci_ampere.key"
    PUB_KEY_FILE="$KEY.pub"
fi

show_result() {
    echo "[*] ממתין שהשרת יעלה..."
    oci compute instance get --instance-id "$1" --wait-for-state RUNNING >/dev/null 2>&1
    echo
    echo "=============================================="
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
        # Public repo: logs are public, so don't print the IP here.
        echo "[+] השרת מוכן! את ה-IP רואים בקונסולה של אורקל (Compute -> Instances)"
    else
        IP=$(oci compute instance list-vnics --instance-id "$1" --query 'data[0]."public-ip"' --raw-output)
        echo "[+] השרת מוכן!  IP: $IP"
        echo "[+] להורדת המפתח: Menu -> Download -> oci_ampere.key"
        echo "[+] התחברות:  ssh -i oci_ampere.key ubuntu@$IP"
    fi
    echo "=============================================="
    [ -n "${GITHUB_OUTPUT:-}" ] && echo "done=true" >> "$GITHUB_OUTPUT"
    exit 0
}

if ! AUTH_ERR=$(oci iam availability-domain list -c "$COMPARTMENT_ID" 2>&1 >/dev/null); then
    echo "[!] ההתחברות לאורקל נכשלה - בדוק את פרטי ה-API Key:"
    echo "$AUTH_ERR"
    exit 1
fi

EXISTING=$(oci compute instance list -c "$COMPARTMENT_ID" --display-name "$NAME" \
    --query 'data[?"lifecycle-state"!=`"TERMINATED"` && "lifecycle-state"!=`"TERMINATING"`] | [0].id' --raw-output 2>/dev/null)
[ -n "$EXISTING" ] && { echo "[+] השרת כבר קיים"; show_result "$EXISTING"; }

for v in 24.04 22.04; do
    IMAGE_ID=$(oci compute image list -c "$COMPARTMENT_ID" --operating-system "Canonical Ubuntu" \
        --operating-system-version "$v" --shape "$SHAPE" --sort-by TIMECREATED --sort-order DESC \
        --query 'data[0].id' --raw-output 2>/dev/null)
    [ -n "$IMAGE_ID" ] && { echo "[+] Image: Ubuntu $v"; break; }
done
[ -z "$IMAGE_ID" ] && { echo "[!] לא נמצא Image של Ubuntu ל-ARM"; exit 1; }

SUBNET_ID=$(oci network subnet list -c "$COMPARTMENT_ID" \
    --query 'data[?"prohibit-public-ip-on-vnic"==`false`] | [0].id' --raw-output 2>/dev/null)

if [ -z "$SUBNET_ID" ]; then
    echo "[*] אין subnet ציבורי - יוצר רשת חדשה..."
    VCN_ID=$(oci network vcn create -c "$COMPARTMENT_ID" --cidr-blocks '["10.0.0.0/16"]' \
        --display-name ampere-vcn --wait-for-state AVAILABLE --query 'data.id' --raw-output)
    IGW_ID=$(oci network internet-gateway create -c "$COMPARTMENT_ID" --vcn-id "$VCN_ID" \
        --is-enabled true --display-name ampere-igw --wait-for-state AVAILABLE --query 'data.id' --raw-output)
    RT_ID=$(oci network vcn get --vcn-id "$VCN_ID" --query 'data."default-route-table-id"' --raw-output)
    oci network route-table update --rt-id "$RT_ID" --force \
        --route-rules "[{\"destination\":\"0.0.0.0/0\",\"destinationType\":\"CIDR_BLOCK\",\"networkEntityId\":\"$IGW_ID\"}]" >/dev/null
    SUBNET_ID=$(oci network subnet create -c "$COMPARTMENT_ID" --vcn-id "$VCN_ID" --cidr-block 10.0.0.0/24 \
        --display-name ampere-subnet --wait-for-state AVAILABLE --query 'data.id' --raw-output)
fi
echo "[+] Subnet נמצא"

attempt=0
while true; do
    attempt=$((attempt + 1))
    echo "[*] ניסיון #$attempt - $(date '+%H:%M:%S')"
    # Another runner (e.g. Cloud Shell) may have created it meanwhile; avoid a duplicate.
    EXISTING=$(oci compute instance list -c "$COMPARTMENT_ID" --display-name "$NAME" \
        --query 'data[?"lifecycle-state"!=`"TERMINATED"` && "lifecycle-state"!=`"TERMINATING"`] | [0].id' --raw-output 2>/dev/null)
    [ -n "$EXISTING" ] && { echo "[+] השרת כבר קיים"; show_result "$EXISTING"; }
    WAIT=$SLEEP
    # Alternate full and smaller shape across attempts: smaller shapes fit busy hosts more often
    # (resizable later), and Oracle throttles a second launch sent right after the first.
    if [ $((attempt % 2)) -eq 1 ]; then
        C_OCPUS=$OCPUS; C_MEM=$MEMORY_GB
    else
        C_OCPUS=$FALLBACK_OCPUS; C_MEM=$FALLBACK_MEMORY_GB
    fi
    # --no-retry: the CLI otherwise re-sends up to 7 launches per attempt, which triggers TooManyRequests.
    OUT=$(oci --no-retry compute instance launch -c "$COMPARTMENT_ID" --availability-domain "$AD" \
        --shape "$SHAPE" --shape-config "{\"ocpus\":$C_OCPUS,\"memoryInGBs\":$C_MEM}" \
        --image-id "$IMAGE_ID" --subnet-id "$SUBNET_ID" --assign-public-ip true \
        --display-name "$NAME" --ssh-authorized-keys-file "$PUB_KEY_FILE" \
        --boot-volume-size-in-gbs "$BOOT_GB" "${EXTRA_ARGS[@]}" \
        --query 'data.id' --raw-output 2>&1)
    if [[ "$OUT" == ocid1.instance* ]]; then
        echo "[+] הצלחה! השרת נוצר ($C_OCPUS ליבות, ${C_MEM}GB)"
        [ -n "${GITHUB_OUTPUT:-}" ] && echo "created=true" >> "$GITHUB_OUTPUT"
        show_result "$OUT"
    elif echo "$OUT" | grep -qi "capacity"; then
        echo "[-] אין מקום פנוי לשרת של $C_OCPUS ליבות"
    elif echo "$OUT" | grep -qi "TooManyRequests"; then
        echo "[-] יותר מדי בקשות, ממתין יותר זמן"
        WAIT=$((SLEEP * 2))
    elif echo "$OUT" | grep -qi "LimitExceeded"; then
        echo "[!] עברת את מכסת ה-Free Tier (כנראה כבר יש לך שרת Ampere). עוצר."
        exit 1
    else
        echo "[!] שגיאה: $OUT"
    fi
    if [ "$MAX_SECONDS" -gt 0 ] && [ "$SECONDS" -ge "$MAX_SECONDS" ]; then
        echo "[*] נגמר זמן הריצה הזה, הריצה הבאה תמשיך"
        exit 0
    fi
    sleep "$WAIT"
done
