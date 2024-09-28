#!/bin/bash
# make sure to install jq, aws cli and coreutils in mac os which can be checked in gtimeout command
TIMEOUT=$(command -v timeout || command -v gtimeout)

if ! command -v fzf &>/dev/null; then
	echo "fzf could not be found please install it first and run this script again"
	exit 1
fi

if ! command -v aws &>/dev/null; then
	echo "aws cli could not be found please install it first and run this script again"
	exit 1
fi

if ! command -v jq &>/dev/null; then
	echo "jq command not found please install it from this site: https://jqlang.github.io/jq/download/ "
	exit 0
fi

if ! command -v gtimeout &>/dev/null; then
	echo "coreutils could not be found please install it first and run this script again"
	exit 1
fi

PROGRAM_DIR="$HOME/.local/share/sshman"
# Check if the directory exists
if [ ! -d "$PROGRAM_DIR" ]; then
	# If the directory does not exist, create it
	mkdir -p "$PROGRAM_DIR"
	echo "Program executed for the first time, creating the program directory"
fi

INSTANCE_CERTIFICATES_KEYS_DIR="$HOME/.local/share/sshman/certificates"
if [ ! -d "$INSTANCE_CERTIFICATES_KEYS_DIR" ]; then
	mkdir -p "$INSTANCE_CERTIFICATES_KEYS_DIR"
	# put your bucket with keys address here 
	aws s3 sync s3://<org_name>/security/instanceKeys/ "$INSTANCE_CERTIFICATES_KEYS_DIR" 2>/dev/null
	find "$INSTANCE_CERTIFICATES_KEYS_DIR" -mindepth 2 -type f -exec mv {} "$INSTANCE_CERTIFICATES_KEYS_DIR" \;
	find "$INSTANCE_CERTIFICATES_KEYS_DIR" -type d -empty -delete
fi

ENV_LIST=('eu-central-1' 'eu-west-1' 'eu-west-2')

fetch_instances() {
	# shellcheck disable=SC2317
	local region="$1"
	# shellcheck disable=SC2317
	local dir="$2"
	# shellcheck disable=SC2317
	aws --region "$region" ec2 describe-instances 2>/dev/null | jq -r '[.Reservations[].Instances[] | {InstanceId, ImageId, PrivateDnsName, PrivateIpAddress, PublicDnsName, PublicIpAddress, KeyName,  Name: (.Tags  // [] | map(select(.Key == "Name")) | .[0].Value), State: (.State.Name), AvailabilityZone: (.Placement.AvailabilityZone) } | select( .State == "running")]' >"$dir/$region"_instances.json
}

export -f fetch_instances
export PROGRAM_DIR

printf "%s\n" "${ENV_LIST[@]}" | xargs -I{} -P 4 bash -c "fetch_instances \"\$@\" \"$PROGRAM_DIR\"" _ {}

find "$PROGRAM_DIR" -name "*_instances.json" -exec jq -s 'reduce .[] as $item ([]; . + $item)' {} + >"$PROGRAM_DIR/instances.json"

NAMES=$(jq -r '.[] | "\(.InstanceId)__\(.Name)"' "$PROGRAM_DIR/instances.json")

CONFIG=$(printf "%s\n" "${NAMES[@]}" | fzf --prompt="Select instance " --layout=reverse --border --exit-0)

INSTANCE_ID=$(echo "$CONFIG" | awk -F '__' '{print $1}')
INSTANCE_NAME=$(echo "$CONFIG" | awk -F '__' '{print $2}')

echo "Selected instance: $INSTANCE_ID with name: $INSTANCE_NAME"

KEY_NAME=$(jq --arg id "$INSTANCE_ID" -r '(.[] |  select(.InstanceId == $id).KeyName)' "$PROGRAM_DIR/instances.json")

KEY_FILENAME=$KEY_NAME.pem

echo "Selected key: $KEY_NAME"

availabilityZone=$(jq --arg id "$INSTANCE_ID" -r '(.[] |  select(.InstanceId == $id).AvailabilityZone)' "$PROGRAM_DIR/instances.json")

region=${availabilityZone%?}

imageId=$(jq --arg id "$INSTANCE_ID" -r '(.[] |  select(.InstanceId == $id).ImageId)' "$PROGRAM_DIR/instances.json")

rawName=$(aws --region "$region" ec2 describe-images --image-ids "$imageId" | jq -r '.Images[0].Name')

login=""
case "$rawName" in
*debian*)
	login="admin"
	;;
*ubuntu*)
	login="ubuntu"
	;;
*)
	login="ec2-user"
	;;
esac

private_ip=$(jq --arg id "$INSTANCE_ID" -r '(.[] |  select(.InstanceId == $id).PrivateIpAddress)' "$PROGRAM_DIR/instances.json")
public_ip=$(jq --arg id "$INSTANCE_ID" -r '(.[] |  select(.InstanceId == $id).PublicIpAddress)' "$PROGRAM_DIR/instances.json")

connection_timeout=3

# Function to try connecting to an IP address
try_connect() {
	echo "Attempting to connect as $login@$private_ip"
	if $TIMEOUT "$connection_timeout" nc -z "$private_ip" 22; then
		TERM=xterm-256color ssh -o StrictHostKeyChecking=no -i "$HOME"/.ssh/connection_keys/"$KEY_FILENAME" "$login@$private_ip"
		exit 0
	else
		echo "Attempting to connect as $login@$public_ip"
		if $TIMEOUT "$connection_timeout" nc -z "$public_ip" 22; then
			TERM=xterm-256color ssh -o StrictHostKeyChecking=no -i "$HOME"/.ssh/connection_keys/"$KEY_FILENAME" "$login@$public_ip"
		else
			echo "Failed to connect to $private_ip and $public_ip"
			exit 1
		fi
	fi
}

try_connect

echo "Both connections failed"
exit 1
