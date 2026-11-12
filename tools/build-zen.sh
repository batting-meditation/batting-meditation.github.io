#!/bin/sh
# zen.html is index.html with the zen-mode marker and its own title; regenerate it after every change to index.html
cd "$(dirname "$0")/.." || exit 1
sed -e '1a <meta name="batting-mode" content="zen">' -e 's|<title>타격 연습장</title>|<title>타격 명상</title>|' index.html > zen.html
grep -c 'name="batting-mode"' zen.html
