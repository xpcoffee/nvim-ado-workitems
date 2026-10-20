# Pick a state from a menu, then search people for the assignee.
Output docs/demo/menus.gif
Source scripts/demo/settings.tape

Hide
Type "ADO_DEMO_OPEN=area $NVIM -u scripts/demo/init.lua"
Enter
Sleep 1.5s
Type "6j0"
Show

Sleep 800ms
Type "2f│w"
Sleep 300ms
Type "cic"
Sleep 300ms
Ctrl+Space
Sleep 1.2s
Type "Ac"
Sleep 800ms
Ctrl+N
Sleep 500ms
Ctrl+Y
Escape
Sleep 800ms
Type "04f│ll"
Sleep 300ms
Type "cic"
Sleep 300ms
Ctrl+Space
Sleep 1.2s
Type@150ms "pri"
Sleep 2.5s
Ctrl+N
Sleep 400ms
Ctrl+N
Sleep 500ms
Ctrl+Y
Escape
Sleep 2s
