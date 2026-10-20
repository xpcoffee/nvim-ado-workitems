# Browse an area, open an item beneath it, then list my work items.
Output docs/demo/hero.gif
Source scripts/demo/settings.tape

Hide
Type "$NVIM -u scripts/demo/init.lua"
Enter
Sleep 1.5s
Show

Sleep 500ms
Type ':lua require("ado").area_view()'
Sleep 300ms
Enter
Sleep 800ms
Type "1"
Enter
Sleep 1.5s
Type "jjj"
Sleep 500ms
Enter
Sleep 2.5s
Type ':lua require("ado").my_items()'
Sleep 300ms
Enter
Sleep 2.5s
