# Edit a title and a state in place, then :w shows the summary before it saves.
Output docs/demo/edit-save.gif
Source scripts/demo/settings.tape

Hide
Type "ADO_DEMO_OPEN=area $NVIM -u scripts/demo/init.lua"
Enter
Sleep 1.5s
Type "4j0"
Show

Sleep 800ms
Type "3f│w"
Sleep 400ms
Type "ciw"
Sleep 200ms
Type "Sketch"
Escape
Sleep 800ms
Type "j02f│w"
Sleep 400ms
Type "cic"
Sleep 200ms
Type "Doing"
Escape
Sleep 1s
Type ":w"
Sleep 300ms
Enter
Sleep 3s
Type "y"
Sleep 3s
