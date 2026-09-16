#!/bin/sh
mkdir -p ~/.local/share/applications/
sed "s#path/to/hyprlayout#$PWD#" < ./hyprlayout.desktop > ~/.local/share/applications/hyprlayout.desktop
