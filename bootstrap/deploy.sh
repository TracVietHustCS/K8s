#!/bin/bash

# Print a message
echo "Starting the deployment ..."

# Input variables
ZIP_FILE="build.zip"                # Replace with your ZIP file path
BUILD_DIR="build"                   # Replace with your build directory name
DEST_DIR="/usr/share/nginx/html/"   # Replace with your target directory
HTTP_URL="http://example.com"       # Replace with the HTTP address you want to fetch

# Create a temporary directory
TEMP_DIR=$(mktemp -d)

# Check if the ZIP file exists
if [[ ! -f "$ZIP_FILE" ]]; then
  echo "Error: $ZIP_FILE could not be found."
  exit 1
fi

# Unzip the file to the temporary directory
echo "Unzipping $ZIP_FILE to $TEMP_DIR..."
unzip "$ZIP_FILE" -d "$TEMP_DIR" > /dev/null
mv "$TEMP_DIR"/"$BUILD_DIR"/* "$TEMP_DIR"/
rm -rf "$TEMP_DIR"/"$BUILD_DIR"/

if [[ $? -ne 0 ]]; then
  echo "Error: Failed to unzip $ZIP_FILE."
  exit 1
fi

# Copy the content to the destination directory
echo "Copying files to $DEST_DIR..."
rsync -rv --delete "$TEMP_DIR"/ "$DEST_DIR"

if [[ $? -ne 0 ]]; then
  echo "Error: Failed to copy files to $DEST_DIR."
  exit 1
fi

# Cleanup the temporary directory
echo "Cleaning up temporary files..."
rm -rf "$TEMP_DIR"

# Fetch the HTTP address and search for "GitLab"
echo "Fetching content from $HTTP_URL and searching for 'GitLab'..."
if curl -fs "$HTTP_URL" | grep -iq "GitLab"; then
  echo "Found 'GitLab' in the response!"
else
  echo "Error: Could not find 'GitLab' or fetch content from $HTTP_URL."
  exit 1
fi

echo "Deployment completed successfully!"