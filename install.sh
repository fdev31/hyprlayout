#!/bin/sh
mkdir -p ~/.local/share/applications/
sed "s#path/to/hyprlayout#$PWD#" <./hyprlayout.desktop >~/.local/share/applications/hyprlayout.desktop
mkdir -p ~/.local/bin/
FNAME="$HOME/.local/bin/hyprlayout"
cat >${FNAME} <<EOF
#!/bin/sh
love $PWD/src
EOF
chmod +x "${FNAME}"
