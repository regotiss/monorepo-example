#!/bin/sh

set -eo pipefail

ROOT=./packages
REPOSITORY_TYPE=gh
CIRCLE_API=https://circleci.com/api
# npm i -g npm@8.19.2
npm -v

# TODO: move to base image
apk --no-cache add curl jq git openssh

# Produces the json body for a circle API request
# makeBodyData(PARAMS json)
function makeBodyData {

    [[ -n "${CIRCLE_TAG}" ]] && CIRCLE_BRANCH=master

    DATA="{ \"branch\": \"${CIRCLE_BRANCH}\", \"parameters\": { $1 } }"

}

# Sends a circle api request with the passed body
# startPipeline(BODY json)
function startPipeline {

    local BODY=$1

    echo "Triggering pipeline with data:"
    echo -e "  $BODY"

    URL="${CIRCLE_API}/v2/project/${REPOSITORY_TYPE}/${CIRCLE_PROJECT_USERNAME}/${CIRCLE_PROJECT_REPONAME}/pipeline"
    HTTP_RESPONSE=$(curl -s -u "${CIRCLE_TOKEN}:" -o response.txt -w "%{http_code}" -X POST --header "Content-Type: application/json" -d "$BODY" "$URL")

    checkResponse

    ID=$(cat response.txt|jq -r '.id')

}

# Waits for a pipeline run triggered via the api to finish
# waitForPipeline(ID string)
function waitForPipeline {

    local ID=$1

    local STATUS=pending

    until [ "x$STATUS" != "xpending" ] && [ "x$STATUS" != "xrunning" ]; do

        sleep 5s  # need to give circle a second to create the job, so may as well have the delay at the start

        URL="${CIRCLE_API}/v2/pipeline/${ID}/workflow"
        HTTP_RESPONSE=$(curl -s -u "${CIRCLE_TOKEN}:" -o response.txt -w "%{http_code}" -X GET --header "Accept: application/json" "$URL")

        checkResponse

        STATUS=$(cat response.txt|jq -r '.items[].status')
        echo "STATUS=$STATUS"

    done

}

# Checks whether we got an error back from the circle API and exits with code 1 if so
# checkResponse()
function checkResponse {

    if [ "$HTTP_RESPONSE" -ge "200" ] && [ "$HTTP_RESPONSE" -lt "300" ]; then
        echo "API call succeeded."
        echo "Response:"
        cat response.txt
    else
        echo -e "\e[93mReceived status code: ${HTTP_RESPONSE}\e[0m"
        echo "Response:"
        cat response.txt
        exit 1
    fi

}

declare -a PACKAGES=("simple-express-server" "simple-react-app")

# Iterate through all the packages
for PACKAGE in "${PACKAGES[@]}"; do

    # Compute package name, version, and string to use for publishing
    echo "PACKAGE=$PACKAGE"

    VERSION=$(cat packages/${PACKAGE}/package.json|jq -r '.version')

    PUB_STRING="${PUB_STRING}${PACKAGE}@${VERSION} "

    # Skip this package if build disabled
    [ -f "packages/${PACKAGE}/cicd_config/no_build" ] && continue

    # Create Circle API body params payload
    PARAMS="\\\"package-name\\\": \\\"${PACKAGE}\\\", \\\"version\\\": \\\"${VERSION}\\\""

    # Work out if we should be deploying
    [[ -n "${CIRCLE_TAG}" ]] && DEPLOY=true
    [[ "${CIRCLE_BRANCH}" == "testing" ]] && DEPLOY=true
    [ -f "packages/${PACKAGE}/cicd_config/no_deploy" ] && DEPLOY=false

    # Turn on publishing if requested
    [ -f "packages/${PACKAGE}/cicd_config/publish" ] && PUBLISH_PACKAGE=true

    # Add deploy and publish to body params as required
    [[ -n "${DEPLOY}" ]] && PARAMS="${PARAMS}, \\\"deploy\\\": ${DEPLOY}"
    [[ -n "${PUBLISH_PACKAGE}" ]] && [[ -n "${CIRCLE_TAG}" ]] && PARAMS="${PARAMS}, \\\"publish\\\": ${PUBLISH_PACKAGE}"

    # If this is a prod build, set the prodution param to true
    [[ -n "${CIRCLE_TAG}" ]] && PROD=true
    [[ -n "${PROD}" ]] && PARAMS="${PARAMS}, \\\"production\\\": ${PROD}"

    # Create the body with the parameters
    PARAMETERS="\"configure\":false, \"name\": \"${PACKAGE}\", \"params\": \"{ ${PARAMS} }\""
    makeBodyData "${PARAMETERS}"

    # Launch the pipeline
    startPipeline "${DATA}"

done

