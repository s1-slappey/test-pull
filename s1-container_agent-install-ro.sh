#!/bin/bash
# ------------------------------------------------------------
# Script: S1 Containerized Agent Installer - RO 
# Purpose: This script pulls a user-specified tag of a
#          image for the SentinelOne agent, logs into a user-specified registry,
#          and runs the agent container with a user-specified configuration file.
#
# ------------------------------------------------------------

REGISTRY_BASE="containers.sentinelone.net" #Base URL of the registry
S1_REPOSITORY_USERNAME=""
S1_REPOSITORY_PASSWORD=""
IMAGE_PATH="cws-agent/s1agent" # Path to the Docker image in the registry
IMAGE_TAG="latest" # Tag of the image
SITE_TOKEN=""
HOST_AGENT_DIR="/s1" # Specifies the directory where s1 agent configuration and logs are stored on host.
HOST_AGENT_CONFIG="/s1/config" # Path to local.conf file used to change agent features.

# Check if HOST_AGENT_DIR is set and present on the machine
if [[ -z "$HOST_AGENT_DIR" ]]; then
    echo "ERROR: HOST_AGENT_DIR is not set."
    exit 1
fi

if [[ ! -d "$HOST_AGENT_DIR" ]]; then
    echo "INFO: $HOST_AGENT_DIR does not exist."
    read -p "Would you like to create $HOST_AGENT_DIR? (y/n): " create_dir
    if [[ "$create_dir" == "y" || "$create_dir" == "Y" ]]; then
        mkdir -p "$HOST_AGENT_DIR"
        echo "INFO: Directory $HOST_AGENT_DIR created."
    else
        echo "ERROR: $HOST_AGENT_DIR is required for the agent to operate. Exiting."
        exit 1
    fi
fi

# Ask the user if they want to add a read-only configuration file
read -p "Would you like to create a local.conf file with read-only options? (y/n): " create_config
if [[ "$create_config" == "y" || "$create_config" == "Y" ]]; then
    # Define local.conf options for restricted agent capabilities
    declare -A config_options=(
        ["addons_enabled"]=false
        ["appinventory_enabled"]=false
        ["auto_file_upload_enabled"]=false
        ["cis_enabled"]=false
        ["config_override_enabled"]=false
        ["config_reset_local_enabled"]=false
        ["file_fetch_enabled"]=false
        ["glads_enabled"]=false
        ["log_min-level"]=1
        ["mitigation_enabled"]=true
        ["network_control_enabled"]=false
        ["ranger_enabled"]=false
        ["remote_shell_enabled"]=false
        ["rso_enabled"]=false
        ["threat_fetch_enabled"]=false
    )

    echo "Please select true or false for the following options:"

    # Prompt the user for each option
    for key in "${!config_options[@]}"; do
        read -p "$key (current: ${config_options[$key]}): " user_choice
        if [[ "$user_choice" == "true" || "$user_choice" == "false" ]]; then
            config_options[$key]=$user_choice
        fi
    done

    # Write the configuration file
    echo "INFO: Writing selected options to $HOST_AGENT_CONFIG"
    {
        echo "{"
        for key in "${!config_options[@]}"; do
            echo "  \"$key\": ${config_options[$key]},"
        done
        echo "}"
    } > "$HOST_AGENT_CONFIG"

    echo "INFO: Configuration file created at $HOST_AGENT_CONFIG"
fi

# Verify necessary variables are set
if [[ -z "$REGISTRY_BASE" || -z "$IMAGE_PATH" || -z "$IMAGE_TAG" ]]; then
    echo "ERROR: One or more required variables (REGISTRY_BASE, IMAGE_PATH, IMAGE_TAG) are not set."
    exit 1
fi

IMAGE_TAG=$(curl -su "$S1_REPOSITORY_USERNAME:$S1_REPOSITORY_PASSWORD" \
    "https://$REGISTRY_BASE/v2/$IMAGE_PATH/tags/list" | \
    jq -r '.tags[]' | grep 'ga$' | grep -vE 'x86|aarch' | sort -Vr | head -n1)

echo "INFO: tag is $IMAGE_TAG"

# Login to container registry
echo "INFO: Logging into SentinelOne Repository..."
if sudo docker login "$REGISTRY_BASE" -u "$S1_REPOSITORY_USERNAME" -p "$S1_REPOSITORY_PASSWORD" &>/dev/null; then
    echo "INFO: Successfully logged into $REGISTRY_BASE."
else
    echo "ERROR: Failed to log into $REGISTRY_BASE."
    exit 1
fi

echo "INFO: Pulling the latest agent image: $REGISTRY_BASE/$IMAGE_PATH:$IMAGE_TAG"
sudo docker pull "$REGISTRY_BASE/$IMAGE_PATH:$IMAGE_TAG"
IMAGE="$REGISTRY_BASE/$IMAGE_PATH:$IMAGE_TAG"

# Start the agent container with specified options
echo "INFO: Starting the s1agent with local.conf"
sudo docker run -d \
    --pid=host \
    --network=host \
    --uts=host \
    --cap-add DAC_OVERRIDE \
    --cap-add DAC_READ_SEARCH \
    --cap-add FOWNER \
    --cap-add KILL \
    --cap-add SETGID \
    --cap-add SETUID \
    --cap-add SYS_RESOURCE \
    --cap-add SYS_PTRACE \
    --cap-add SYSLOG \
    --cap-add SYS_CHROOT \
    --cap-add SYS_MODULE \
    --cap-add CHOWN \
    --cap-add SYS_ADMIN \
    --security-opt apparmor=unconfined \
    --security-opt seccomp=unconfined \
    --name s1agent \
    -e S1_CONTAINER_NAME=s1agent \
    -e S1_AGENT_HOST_MOUNT_PATH=/host \
    --mount type=bind,source=/,target=/host \
    -e S1_PERSISTENT_DIR=$HOST_AGENT_DIR \
    -e CONFIG_FILE=$HOST_AGENT_CONFIG \
    --mount type=bind,source=$HOST_AGENT_CONFIG,target=/s1config \
    -e S1_HELPER_ADDRESS="http://localhost:/var/run/docker.sock" \
    --mount type=bind,source=/var/run/docker.sock,target=/var/run/docker.sock,readonly=true \
    -e S1_AGENT_TYPE=containerized \
    -e SITE_TOKEN="$SITE_TOKEN" \
    -e S1_LOG_LEVEL=info \
    "$IMAGE"
