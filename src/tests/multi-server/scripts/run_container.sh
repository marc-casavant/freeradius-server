#!/bin/bash

docker run -it --rm -v "$(pwd)/prof-results:/etc/prof-results" --name freeradius-radenv-container freeradius-prof:latest
