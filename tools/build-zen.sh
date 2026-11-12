#!/bin/sh
# index.html (타격 명상) is practice.html with the zen-mode marker and its own title; regenerate it after every change to practice.html
cd "$(dirname "$0")/.." || exit 1
sed -e '1a <meta name="batting-mode" content="zen">\
<script>document.documentElement.classList.add("zen")</script>' -e 's|<title>타격 연습장</title>|<title>타격 명상</title>|' -e 's|id="startBtn">연습 시작</button>|id="startBtn">시작</button>|' practice.html > index.html
grep -c 'name="batting-mode"' index.html
